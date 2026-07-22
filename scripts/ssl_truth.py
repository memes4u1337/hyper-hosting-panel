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
PRIMARY_CERTBOT = Path('/opt/hyper-host/letsencrypt')
CERT_ROOTS = [PRIMARY_CERTBOT / 'live', Path('/etc/letsencrypt/live')]
ACME_ROOT = Path('/opt/hyper-host/acme-webroot')
SERVER_IP = os.environ.get('SERVER_IP', '192.168.0.179')
PUBLIC_IP = os.environ.get('PUBLIC_IP', '90.189.208.25')


def jprint(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False))


def cert_info(cert: Path) -> dict[str, Any] | None:
    """Read certificate metadata and compute a real SHA-256 DER fingerprint.

    Older builds parsed the human-readable OpenSSL fingerprint line. On some
    OpenSSL versions that line has different capitalization, so the parser
    returned an empty string for every certificate. Two empty fingerprints
    were then treated as a match, which made SSL audit report success while
    Nginx was actually serving another site's certificate.
    """
    try:
        if not cert.is_file():
            return None
        key = cert.with_name('privkey.pem')
        text = subprocess.check_output(
            ['openssl', 'x509', '-in', str(cert), '-noout', '-subject', '-issuer', '-enddate', '-ext', 'subjectAltName'],
            text=True, stderr=subprocess.DEVNULL, timeout=10,
        )
        der = subprocess.check_output(
            ['openssl', 'x509', '-in', str(cert), '-outform', 'DER'],
            stderr=subprocess.DEVNULL, timeout=10,
        )
        end = re.search(r'(?mi)^notAfter=(.+)$', text)
        exp = dt.datetime.strptime(end.group(1).strip(), '%b %d %H:%M:%S %Y %Z') if end else None
        sans = re.findall(r'DNS:([^,\s]+)', text, flags=re.I)
        if not sans:
            m = re.search(r'(?i)CN\s*=\s*([^,\n/]+)', text)
            if m:
                sans = [m.group(1).strip()]
        return {
            'cert': str(cert),
            'key': str(key),
            'domains': [x.lower().rstrip('.') for x in sans],
            'expires': exp.isoformat() + 'Z' if exp else '',
            'days_left': (exp - dt.datetime.utcnow()).days if exp else -9999,
            'fingerprint': hashlib.sha256(der).hexdigest(),
        }
    except Exception:
        return None


def cert_expiry_epoch(cert: Path) -> int:
    info = cert_info(cert)
    if not info or not info.get('expires'):
        return 0
    try:
        return int(dt.datetime.fromisoformat(str(info['expires']).replace('Z','+00:00')).timestamp())
    except Exception:
        return 0


def candidate_certbot_roots() -> list[Path]:
    roots=[PRIMARY_CERTBOT, Path('/etc/letsencrypt')]
    backups=Path('/opt/hyper-host/backups')
    if backups.exists():
        for live in backups.rglob('live'):
            root=live.parent
            if (root/'archive').is_dir():
                roots.append(root)
    out=[]; seen=set()
    for root in roots:
        try: key=str(root.resolve())
        except Exception: key=str(root)
        if key in seen: continue
        seen.add(key); out.append(root)
    return out


def rewrite_renewal(path: Path, lineage: str) -> None:
    if not path.exists(): return
    text=path.read_text('utf-8',errors='ignore')
    replacements={
        'archive_dir': str(PRIMARY_CERTBOT/'archive'/lineage),
        'cert': str(PRIMARY_CERTBOT/'live'/lineage/'cert.pem'),
        'privkey': str(PRIMARY_CERTBOT/'live'/lineage/'privkey.pem'),
        'chain': str(PRIMARY_CERTBOT/'live'/lineage/'chain.pem'),
        'fullchain': str(PRIMARY_CERTBOT/'live'/lineage/'fullchain.pem'),
    }
    for key,val in replacements.items():
        if re.search(rf'(?m)^\s*{re.escape(key)}\s*=',text):
            text=re.sub(rf'(?m)^\s*{re.escape(key)}\s*=.*$',f'{key} = {val}',text)
    text=text.replace('/etc/letsencrypt',str(PRIMARY_CERTBOT))
    path.write_text(text,'utf-8')


def merge_backup_certificates() -> list[dict[str,Any]]:
    PRIMARY_CERTBOT.mkdir(parents=True,exist_ok=True)
    for name in ('live','archive','renewal','accounts'):
        (PRIMARY_CERTBOT/name).mkdir(parents=True,exist_ok=True)
    restored=[]
    primary_resolved=PRIMARY_CERTBOT.resolve()
    for root in candidate_certbot_roots():
        try:
            if root.resolve()==primary_resolved: continue
        except Exception:
            if str(root)==str(PRIMARY_CERTBOT): continue
        live=root/'live'; archive=root/'archive'
        if not live.is_dir() or not archive.is_dir(): continue
        for lineage_dir in live.iterdir():
            if not lineage_dir.is_dir(): continue
            lineage=lineage_dir.name
            cert=lineage_dir/'fullchain.pem'; key=lineage_dir/'privkey.pem'
            info=cert_info(cert)
            if not info or int(info.get('days_left',-1)) < 0 or not key.exists(): continue
            src_epoch=cert_expiry_epoch(cert)
            dst_cert=PRIMARY_CERTBOT/'live'/lineage/'fullchain.pem'
            dst_epoch=cert_expiry_epoch(dst_cert) if dst_cert.exists() else 0
            if src_epoch <= dst_epoch: continue
            src_archive=archive/lineage
            if not src_archive.is_dir(): continue
            for target in (PRIMARY_CERTBOT/'live'/lineage, PRIMARY_CERTBOT/'archive'/lineage):
                if target.exists() or target.is_symlink():
                    if target.is_dir() and not target.is_symlink(): shutil.rmtree(target)
                    else: target.unlink()
            shutil.copytree(src_archive,PRIMARY_CERTBOT/'archive'/lineage,symlinks=True)
            shutil.copytree(lineage_dir,PRIMARY_CERTBOT/'live'/lineage,symlinks=True)
            renewal=root/'renewal'/f'{lineage}.conf'
            if renewal.exists():
                shutil.copy2(renewal,PRIMARY_CERTBOT/'renewal'/f'{lineage}.conf')
                rewrite_renewal(PRIMARY_CERTBOT/'renewal'/f'{lineage}.conf',lineage)
            restored.append({'lineage':lineage,'source':str(root),'expires':info.get('expires',''),'domains':info.get('domains',[])})
    # Copy an existing Certbot account if the primary store lost it.
    if not any((PRIMARY_CERTBOT/'accounts').rglob('regr.json')):
        for root in candidate_certbot_roots():
            src=root/'accounts'
            if src.is_dir() and any(src.rglob('regr.json')):
                shutil.copytree(src,PRIMARY_CERTBOT/'accounts',dirs_exist_ok=True,symlinks=True)
                break
    return restored


def discover_certbot_email() -> str:
    for root in candidate_certbot_roots():
        accounts=root/'accounts'
        if not accounts.exists(): continue
        for regr in accounts.rglob('regr.json'):
            try:
                data=json.loads(regr.read_text('utf-8',errors='ignore'))
                body=data.get('body',data) if isinstance(data,dict) else {}
                contacts=body.get('contact',[]) if isinstance(body,dict) else []
                for item in contacts or []:
                    if isinstance(item,str) and item.startswith('mailto:') and '@' in item:
                        return item[7:]
            except Exception:
                continue
    return ''

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


def is_public_domain(domain: str) -> bool:
    domain=(domain or '').strip().lower().rstrip('.')
    if not domain or domain.endswith(('.local','.invalid','.test','.example')):
        return False
    if re.match(r'^v(?:59|60)-(?:nginx|acme)-test-', domain):
        return False
    return bool(re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}', domain))


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
                domain=str(row.get('domain') or '').strip().lower().rstrip('.')
                if domain==panel or not is_public_domain(domain):
                    continue
                row['domain']=domain
                rows.append(row)
            con.close()
        except Exception:
            pass
    known={str(r['domain']).lower() for r in rows}
    if SITES_DIR.exists():
        for p in SITES_DIR.iterdir():
            domain=p.name.lower().rstrip('.')
            if not p.is_dir() or not (p/'public_html').is_dir() or not is_public_domain(domain) or domain in known or domain==panel:
                continue
            rows.append({'domain':p.name,'aliases':'','root_path':str(p/'public_html')})
    return rows


def site_names(row: dict[str, Any]) -> list[str]:
    out=[]
    for value in [str(row.get('domain') or '')] + re.split(r'[\s,;]+', str(row.get('aliases') or '')):
        value=value.strip().lower().rstrip('.')
        if value and value not in out: out.append(value)
    return out


def sync_db_flags(certs: list[dict[str, Any]]) -> None:
    if not SQLITE.exists(): return
    try:
        con=sqlite3.connect(SQLITE,timeout=2)
        columns={r[1] for r in con.execute('PRAGMA table_info(sites)')}
        if 'ssl_enabled' not in columns:
            con.close(); return
        for row in site_rows():
            domain=str(row.get('domain') or '')
            enabled=1 if choose_cert(domain,certs) and nginx_has_ssl_domain(domain) else 0
            con.execute('UPDATE sites SET ssl_enabled=? WHERE lower(domain)=lower(?)',(enabled,domain))
        con.commit(); con.close()
    except Exception:
        pass


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


def certificate_serves_domain(info: dict[str, Any] | None, domain: str) -> bool:
    return bool(info and info.get('fingerprint') and any(match_domain(str(name), domain) for name in info.get('domains', [])))


def certificates_identical(expected: dict[str, Any] | None, live: dict[str, Any] | None, domain: str) -> bool:
    return bool(
        certificate_serves_domain(expected, domain)
        and certificate_serves_domain(live, domain)
        and expected.get('fingerprint')
        and live.get('fingerprint')
        and expected.get('fingerprint') == live.get('fingerprint')
    )


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
    canonical_failures=[]; alias_failures=[]
    for row in site_rows():
        d=str(row['domain']).strip().lower(); name_items=[]
        for name in site_names(row):
            if not is_public_domain(name):
                continue
            cert=choose_cert(name,certs); live=remote_cert(name)
            live_matches=certificates_identical(cert, live, name)
            if live_matches:
                status='active'
            elif cert and int(cert.get('days_left',-1)) < 0:
                status='expired'
            elif cert:
                status='wrong_live_certificate' if live else 'cert_only'
            else:
                status='missing'
            name_items.append({'domain':name,'status':status,'certificate':cert or {},
                               'nginx_https':nginx_has_ssl_domain(name),'live_certificate':live or {},
                               'live_matches':live_matches})
        canonical=next((x for x in name_items if x['domain']==d),name_items[0] if name_items else {})
        missing=[x['domain'] for x in name_items if x.get('status')!='active']
        overall='active' if name_items and not missing else ('partial' if canonical.get('status')=='active' else canonical.get('status','missing'))
        if canonical.get('status')!='active':
            canonical_failures.append(d)
        alias_failures.extend([x for x in missing if x != d])
        items.append({'domain':d,'aliases':str(row.get('aliases') or ''),'status':overall,
                      'has_certificate':bool(canonical.get('certificate')),'certificate':canonical.get('certificate',{}),
                      'nginx_https':bool(canonical.get('nginx_https')),'live_certificate':canonical.get('live_certificate',{}),
                      'live_matches':bool(canonical.get('live_matches')),'names':name_items,'missing_names':missing})
    pd=panel_domain(); pc=choose_cert(pd,certs); pl=remote_cert(pd)
    pstatus='active' if certificates_identical(pc,pl,pd) else ('wrong_live_certificate' if pc and pl else ('cert_only' if pc else 'missing'))
    sync_db_flags(certs)
    return {
        'ok': not canonical_failures and pstatus=='active',
        'sites':items,
        'panel':{'domain':pd,'status':pstatus,'certificate':pc or {},'live_certificate':pl or {},
                 'live_matches':certificates_identical(pc,pl,pd)},
        'canonical_failures':canonical_failures,
        'alias_failures':sorted(set(alias_failures)),
        'certificates_found':len(certs),
    }


def restore() -> dict[str,Any]:
    """Reconnect every still-valid certificate to the generated Nginx vhosts.

    The authoritative vhost builder is nginx-reconcile-v89. It reads the site
    folders/DB read-only and automatically attaches matching certificates from
    /opt/hyper-host/letsencrypt or legacy /etc/letsencrypt.
    """
    merged = merge_backup_certificates()
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
    sync_db_flags(certs)
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
    return {'ok':True,'backup_certificates_restored':merged,'restored':restored,'skipped':skipped,
            'reconcile_output':cp.stdout.strip(),'audit':audit()}



def repair_all(email: str='') -> dict[str,Any]:
    first=restore()
    report=audit()
    email=(email or discover_certbot_email()).strip()
    issued=[]; failed=[]; skipped=[]
    needs_repair=[]
    for item in report.get('sites',[]):
        if item.get('status')!='active' or item.get('missing_names'):
            needs_repair.append(str(item.get('domain') or ''))
    panel=report.get('panel',{}) or {}
    panel_missing=panel.get('status')!='active'
    if not email:
        for domain in needs_repair: skipped.append({'domain':domain,'reason':'email для Certbot не найден'})
        if panel_missing: skipped.append({'domain':panel.get('domain',''),'reason':'email для Certbot не найден','panel':True})
        return {'ok':True,'email':'','restore':first,'issued':issued,'failed':failed,'skipped':skipped,'audit':report}
    ctl='/usr/local/sbin/hyper-host-ctl'
    for domain in needs_repair:
        if not domain: continue
        cp=subprocess.run([ctl,'ssl-site',domain,email],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=1200)
        item={'domain':domain,'output':cp.stdout.strip()[-12000:]}
        (issued if cp.returncode==0 else failed).append(item)
    if panel_missing and panel.get('domain'):
        cp=subprocess.run([ctl,'panel-ssl',str(panel['domain']),email],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=1200)
        item={'domain':panel['domain'],'panel':True,'output':cp.stdout.strip()[-12000:]}
        (issued if cp.returncode==0 else failed).append(item)
    final=restore()
    final_audit=audit()
    ok=not failed and bool(final_audit.get('ok'))
    return {'ok':ok,'email':email,'restore':first,'issued':issued,'failed':failed,'skipped':skipped,'final_restore':final,'audit':final_audit}


def main():
    ap=argparse.ArgumentParser(); ap.add_argument('command',choices=['audit','restore','repair-all']); ap.add_argument('--email',default=''); args=ap.parse_args()
    try:
        if args.command=='audit': result=audit()
        elif args.command=='restore': result=restore()
        else: result=repair_all(args.email)
        jprint(result)
    except Exception as exc:
        jprint({'ok':False,'error':str(exc)}); raise SystemExit(1)

if __name__=='__main__': main()
