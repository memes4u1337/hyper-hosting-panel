#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import socket
import sqlite3
import ssl
import subprocess
import tempfile
from pathlib import Path
from typing import Any

SITES_DIR = Path('/var/www/hyper-host-sites')
PANEL_ROOT = Path('/var/www/hyper-host/public')
SQLITE = Path('/opt/hyper-host/data/hyperhost.sqlite')
NG_AVAIL = Path('/etc/nginx/sites-available')
NG_ENABLED = Path('/etc/nginx/sites-enabled')
CERT_ROOTS = [Path('/opt/hyper-host/letsencrypt/live'), Path('/etc/letsencrypt/live')]
ACME_ROOT = Path('/opt/hyper-host/acme-webroot')
SERVER_IP = os.environ.get('SERVER_IP', '192.168.0.179')
PUBLIC_IP = os.environ.get('PUBLIC_IP', '90.189.208.25')


def jprint(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False))


def cert_info(cert: Path) -> dict[str, Any] | None:
    try:
        text = subprocess.check_output(['openssl','x509','-in',str(cert),'-noout','-subject','-issuer','-enddate','-fingerprint','-sha256','-ext','subjectAltName'], text=True, stderr=subprocess.DEVNULL)
        end = re.search(r'notAfter=(.+)', text)
        exp = dt.datetime.strptime(end.group(1).strip(), '%b %d %H:%M:%S %Y %Z') if end else None
        sans = re.findall(r'DNS:([^,\s]+)', text)
        if not sans:
            m = re.search(r'CN\s*=\s*([^,\n/]+)', text)
            if m: sans = [m.group(1).strip()]
        fp = re.search(r'SHA256 Fingerprint=([0-9A-F:]+)', text)
        return {
            'cert': str(cert),
            'key': str(cert.with_name('privkey.pem')),
            'domains': sans,
            'expires': exp.isoformat()+'Z' if exp else '',
            'days_left': (exp - dt.datetime.utcnow()).days if exp else -9999,
            'fingerprint': (fp.group(1).replace(':','').lower() if fp else ''),
        }
    except Exception:
        return None


def all_certs() -> list[dict[str, Any]]:
    items=[]
    seen=set()
    for root in CERT_ROOTS:
        if not root.exists():
            continue
        for cert in root.glob('*/fullchain.pem'):
            try:
                real=str(cert.resolve())
            except Exception:
                real=str(cert)
            if real in seen: continue
            seen.add(real)
            info=cert_info(cert)
            if info and Path(info['key']).exists(): items.append(info)
    return items


def match_domain(pattern: str, domain: str) -> bool:
    pattern=pattern.lower().strip('.'); domain=domain.lower().strip('.')
    if pattern == domain: return True
    if pattern.startswith('*.'):
        suffix=pattern[1:]
        return domain.endswith(suffix) and domain.count('.') == pattern.count('.')
    return False


def choose_cert(domain: str, certs: list[dict[str, Any]]) -> dict[str, Any] | None:
    valid=[c for c in certs if c['days_left'] >= 0 and any(match_domain(p,domain) for p in c['domains'])]
    if not valid: return None
    valid.sort(key=lambda c:(c['days_left'], '/opt/hyper-host/' in c['cert']), reverse=True)
    return valid[0]


def panel_domain() -> str:
    for cfg in ['/var/www/hyper-host/app/config.php','/opt/hyper-host/app/config.php']:
        p=Path(cfg)
        if not p.exists(): continue
        text=p.read_text('utf-8',errors='ignore')
        m=re.search(r"['\"]panel_domain['\"]\s*=>\s*['\"]([^'\"]+)", text)
        if m and m.group(1) not in {'','_'}: return m.group(1).strip()
    return 'panel.hyper-host.pw'


def site_rows() -> list[dict[str, Any]]:
    rows=[]
    panel=panel_domain().strip().lower()
    if SQLITE.exists():
        try:
            con=sqlite3.connect(SQLITE)
            con.row_factory=sqlite3.Row
            for r in con.execute('SELECT domain, aliases, root_path FROM sites ORDER BY domain'):
                row=dict(r)
                if str(row.get('domain') or '').strip().lower()==panel:
                    continue
                rows.append(row)
            con.close()
        except Exception:
            pass
    known={str(r['domain']).lower() for r in rows}
    if SITES_DIR.exists():
        for p in SITES_DIR.iterdir():
            if not p.is_dir() or not (p/'public_html').is_dir() or '.' not in p.name or p.name.lower() in known or p.name.lower()==panel:
                continue
            rows.append({'domain':p.name,'aliases':'','root_path':str(p/'public_html')})
    return rows


def remote_cert(domain: str) -> dict[str, Any] | None:
    ctx=ssl.create_default_context()
    ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    for host in ('127.0.0.1', SERVER_IP):
        try:
            with socket.create_connection((host,443),timeout=3) as raw:
                with ctx.wrap_socket(raw,server_hostname=domain) as s:
                    der=s.getpeercert(binary_form=True)
            pem=ssl.DER_cert_to_PEM_cert(der)
            with tempfile.NamedTemporaryFile('w',delete=False) as f:
                f.write(pem); tmp=f.name
            info=cert_info(Path(tmp)); os.unlink(tmp)
            if info: info['connect_host']=host
            return info
        except Exception:
            continue
    return None


def nginx_has_ssl_domain(domain: str) -> bool:
    try:
        text=subprocess.check_output(['nginx','-T'],text=True,stderr=subprocess.STDOUT,timeout=15)
    except Exception:
        return False
    # Conservative block scan.
    for block in re.findall(r'server\s*\{(?:[^{}]|\{[^{}]*\})*\}', text, flags=re.S):
        if re.search(r'listen\s+[^;]*443[^;]*ssl',block) and re.search(r'\bserver_name\b[^;]*\b'+re.escape(domain)+r'\b',block):
            return True
    return False


def php_socket_from_conf(conf_text: str) -> str:
    m=re.search(r'fastcgi_pass\s+([^;]+);',conf_text)
    if m: return m.group(1).strip()
    socks=sorted(glob.glob('/run/php/php*-fpm.sock'),reverse=True)
    return 'unix:'+socks[0] if socks else 'unix:/run/php/php8.2-fpm.sock'


def remove_https_blocks(text: str) -> str:
    out=[]; i=0; n=len(text)
    while i<n:
        m=re.search(r'\bserver\s*\{',text[i:])
        if not m:
            out.append(text[i:]); break
        start=i+m.start(); brace=i+m.end()-1
        out.append(text[i:start])
        depth=0; j=brace
        while j<n:
            if text[j]=='{': depth+=1
            elif text[j]=='}':
                depth-=1
                if depth==0:
                    j+=1; break
            j+=1
        block=text[start:j]
        if re.search(r'listen\s+[^;]*443[^;]*ssl',block):
            out.append('\n')
        else:
            out.append(block)
        i=j
    return ''.join(out)


def https_block(domain: str, aliases: str, root: str, cert: dict[str,Any], panel: bool=False, php_socket: str='') -> str:
    names=' '.join([domain]+[x.strip() for x in aliases.split(',') if x.strip()])
    if panel:
        location='''
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \\.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass %s;
    }
    location ~ /\\. { deny all; }
''' % php_socket
    else:
        location='''
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \\.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass %s;
    }
''' % php_socket
    return f'''
server {{
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {names};
    root {root};
    index index.html index.htm index.php;
    ssl_certificate {cert['cert']};
    ssl_certificate_key {cert['key']};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    location ^~ /.well-known/acme-challenge/ {{
        root {ACME_ROOT};
        default_type text/plain;
    }}
{location}
    access_log {root.rsplit('/public_html',1)[0] if '/public_html' in root else '/var/log/nginx'}/logs/access.log;
    error_log {root.rsplit('/public_html',1)[0] if '/public_html' in root else '/var/log/nginx'}/logs/error.log;
}}
'''


def repair_one(domain: str, aliases: str, root: str, cert: dict[str,Any], panel: bool=False) -> dict[str,Any]:
    conf=NG_AVAIL/('hyper-host-panel.conf' if panel else f'hyper-host-site-{domain}.conf')
    enabled=NG_ENABLED/('00-hyper-host-panel.conf' if panel else f'hyper-host-site-{domain}.conf')
    if conf.exists(): text=conf.read_text('utf-8',errors='ignore')
    else:
        names=' '.join([domain]+[x.strip() for x in aliases.split(',') if x.strip()])
        text=f'''server {{\n listen 80; listen [::]:80; server_name {names}; root {root}; index index.html index.htm index.php; location ^~ /.well-known/acme-challenge/ {{ root {ACME_ROOT}; }} location / {{ try_files $uri $uri/ /index.php?$query_string; }} }}\n'''
    sock=php_socket_from_conf(text)
    text=remove_https_blocks(text).rstrip()+"\n"+https_block(domain,aliases,root,cert,panel,sock)
    conf.parent.mkdir(parents=True,exist_ok=True); enabled.parent.mkdir(parents=True,exist_ok=True)
    conf.write_text(text,'utf-8')
    if enabled.exists() or enabled.is_symlink(): enabled.unlink()
    enabled.symlink_to(conf)
    return {'domain':domain,'config':str(conf),'cert':cert['cert']}


def audit() -> dict[str,Any]:
    certs=all_certs(); items=[]
    for row in site_rows():
        d=row['domain']; cert=choose_cert(d,certs); live=remote_cert(d)
        live_matches=bool(cert and live and live.get('fingerprint')==cert.get('fingerprint'))
        status='active' if live_matches else ('cert_only' if cert else 'missing')
        if cert and cert['days_left'] < 0: status='expired'
        items.append({'domain':d,'status':status,'has_certificate':bool(cert),'certificate':cert or {},'nginx_https':nginx_has_ssl_domain(d),'live_certificate':live or {},'live_matches':live_matches})
    pd=panel_domain(); pc=choose_cert(pd,certs); pl=remote_cert(pd)
    pstatus='active' if pc and pl and pc.get('fingerprint')==pl.get('fingerprint') else ('cert_only' if pc else 'missing')
    return {'ok':True,'sites':items,'panel':{'domain':pd,'status':pstatus,'certificate':pc or {},'live_certificate':pl or {}},'certificates_found':len(certs)}


def restore() -> dict[str,Any]:
    """Reconnect every still-valid certificate to the generated Nginx vhosts.

    The authoritative vhost builder is nginx-reconcile-v89. It reads the site
    folders/DB read-only and automatically attaches matching certificates from
    /opt/hyper-host/letsencrypt or legacy /etc/letsencrypt.
    """
    reconcile = Path('/usr/local/sbin/hyper-host-nginx-reconcile')
    if not reconcile.exists():
        raise RuntimeError(f'nginx reconcile helper not found: {reconcile}')
    cp = subprocess.run([str(reconcile)], text=True, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT)
    if cp.returncode != 0:
        raise RuntimeError(cp.stdout)

    check = subprocess.run(['nginx','-t'], text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
    if check.returncode != 0:
        raise RuntimeError(check.stdout)
    subprocess.run(['systemctl','reload','nginx'], check=False)

    certs = all_certs()
    restored=[]; skipped=[]
    for row in site_rows():
        d=row['domain']; cert=choose_cert(d,certs)
        if cert:
            restored.append({'domain':d,'cert':cert['cert']})
        else:
            skipped.append({'domain':d,'reason':'certificate missing or expired'})
    pd=panel_domain(); pc=choose_cert(pd,certs)
    if pc:
        restored.append({'domain':pd,'cert':pc['cert'],'panel':True})
    else:
        skipped.append({'domain':pd,'reason':'panel certificate missing or expired','panel':True})
    return {'ok':True,'restored':restored,'skipped':skipped,
            'reconcile_output':cp.stdout.strip(),'audit':audit()}


def main():
    ap=argparse.ArgumentParser(); ap.add_argument('command',choices=['audit','restore']); args=ap.parse_args()
    try:
        jprint(audit() if args.command=='audit' else restore())
    except Exception as exc:
        jprint({'ok':False,'error':str(exc)}); raise SystemExit(1)

if __name__=='__main__': main()
