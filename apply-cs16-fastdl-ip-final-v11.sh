#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
PUBLIC_IP="${3:-90.189.208.25}"

SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
SERVER_ROOT="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER_ROOT/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
STATE="/var/lib/hyper-cs16/servers/$SID.json"
RUNTIME="/etc/hyper-cs16/runtime.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v11-${STAMP}"
QUARANTINE="$BACKUP/nginx-quarantine"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$SRC_CTL" ]] || fail "missing controller: $SRC_CTL"
[[ -d "$CSTRIKE/maps" ]] || fail "missing maps directory: $CSTRIKE/maps"
python3 - "$PUBLIC_IP" <<'PY'
import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1])
if ip.version!=4 or ip.is_unspecified or ip.is_loopback:
    raise SystemExit('invalid public IPv4')
print('public IPv4:',ip)
PY

mkdir -p "$BACKUP" "$QUARANTINE"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.repo.before"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg.before" || true
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/server-state.before.json" || true
[[ -f "$RUNTIME" ]] && cp -a "$RUNTIME" "$BACKUP/runtime.before.json" || true

echo "================================================================"
echo " HYPER-HOST CS 1.6 FASTDL IP FINAL v11"
echo " Server:     #$SID"
echo " FastDL URL: http://$PUBLIC_IP/fastdl/$SID/"
echo " Backup:     $BACKUP"
echo "================================================================"

echo "[1/11] Validate SOURCE BSP files..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1]); files=sorted(root.glob('*.bsp')); bad=[]
if not files: raise SystemExit('no BSP maps found')
for p in files:
    h=p.read_bytes()[:4]; v=struct.unpack('<I',h)[0] if len(h)==4 else None
    if v!=30: bad.append((p.name,v,h.hex(),p.stat().st_size))
print('maps:',len(files),'valid:',len(files)-len(bad),'bad:',len(bad))
for x in bad[:50]: print('BAD',x)
if bad: raise SystemExit(20)
PY

echo "[2/11] Quarantine nginx backup garbage with SHORT safe names..."
python3 - "$QUARANTINE" <<'PYQ'
from pathlib import Path
import hashlib, os, re, shutil, stat, sys, time

out=Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
manifest=out/'manifest.tsv'
roots=[
    Path('/etc/nginx/sites-enabled'),
    Path('/etc/nginx/conf.d'),
    Path('/etc/nginx/hyper-host-managed'),
    Path('/etc/nginx/hyper-host-managed/sites-enabled'),
]
rx=re.compile(r'(?i)(?:\.bak(?:\.|$)|\.pre-v\d+(?:\.|$)|\.disabled-v\d+(?:\.|$)|\.ip-conflict\.pre-v\d+(?:\.|$)|\.fastdl-v\d+\.bak(?:\.|$))')

moved=[]
errors=[]
with manifest.open('a', encoding='utf-8') as mf:
    for root in roots:
        try:
            entries=list(os.scandir(root))
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError as e:
            errors.append(f'{root}\tSCAN\t{e}')
            continue

        root_tag=root.as_posix().strip('/').replace('/','__') or 'root'
        for ent in entries:
            name=ent.name
            if not rx.search(name):
                continue
            src=os.path.join(str(root), name)
            digest=hashlib.sha256(src.encode('utf-8','surrogateescape')).hexdigest()[:20]
            base=f'{root_tag}__{digest}.q'
            dst=out/base
            n=1
            while os.path.lexists(dst):
                dst=out/f'{root_tag}__{digest}.{n}.q'
                n+=1
            try:
                if ent.is_symlink():
                    link=os.readlink(src)
                    dst.write_text('SYMLINK -> '+link+'\n', encoding='utf-8')
                    os.unlink(src)
                    kind='symlink'
                else:
                    shutil.move(src, str(dst))
                    kind='file'
                mf.write(f'{time.strftime("%Y-%m-%dT%H:%M:%S")}\t{kind}\t{src}\t{dst.name}\n')
                mf.flush()
                moved.append(src)
            except FileNotFoundError:
                pass
            except OSError as e:
                errors.append(f'{src}\tMOVE\t{e}')

print('quarantined:', len(moved))
for x in moved[:100]:
    print(' ', x)
if errors:
    print('quarantine warnings:', len(errors))
    for x in errors[:50]:
        print(' WARN', x)
    # Continue only for non-fatal cleanup warnings. Any remaining active backup
    # is detected below and stops the patch before nginx is modified.

remaining=[]
for root in roots:
    try:
        for ent in os.scandir(root):
            if rx.search(ent.name):
                remaining.append(os.path.join(str(root), ent.name))
    except (FileNotFoundError, NotADirectoryError):
        pass
    except OSError as e:
        remaining.append(f'{root} [scan failed: {e}]')

if remaining:
    print('ERROR: recursive backup garbage still exists in active nginx include dirs:')
    for x in remaining[:100]:
        print(' ', x)
    raise SystemExit(21)
PYQ

echo "[3/11] Patch panel controller FastDL core..."
python3 - "$SRC_CTL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text(encoding='utf-8',errors='strict')
start=text.find('def _fastdl_url(c:dict)->str:')
end=text.find('\ndef _fastdl_apply_cfg',start)
if start<0 or end<0: raise SystemExit('cannot find _fastdl_url()')
lines=[
"def _fastdl_url(c:dict)->str:\n",
"    # Canonical GoldSrc FastDL URL. HTTP endpoint is separate from the game UDP port.\n",
"    sid=int(c.get('id') or 0)\n",
"    public=''\n",
"    try:\n",
"        rt=load_runtime(); public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()\n",
"    except Exception:\n",
"        public=str(c.get('public_ip') or '').strip()\n",
"    try:\n",
"        ip=ipaddress.ip_address(public)\n",
"        if ip.version==4 and not ip.is_unspecified and not ip.is_loopback:\n",
"            return f'http://{public}/fastdl/{sid}/'\n",
"    except Exception:\n",
"        pass\n",
"    return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'\n",
]
text=text[:start]+''.join(lines)+text[end:]
text=text.replace("'sv_allowupload 1',\n        'sv_send_resources 1',","'sv_allowupload 0',\n        'sv_send_resources 1',")
text=text.replace("['sv_allowdownload 1','sv_allowupload 1','sv_send_resources 1','sv_allow_dlfile 1',","['sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 1',")
marker='# HYPER-HOST FASTDL IP FINAL v11'
if marker not in text: text=text.replace('#!/usr/bin/env python3\n','#!/usr/bin/env python3\n'+marker+'\n',1)
p.write_text(text,encoding='utf-8')
print('patched:',p)
PY
python3 -m py_compile "$SRC_CTL"
install -m 0755 "$SRC_CTL" "$LIVE_CTL"
python3 -m py_compile "$LIVE_CTL"

echo "[4/11] Persist public IPv4 in runtime and server state..."
python3 - "$RUNTIME" "$STATE" "$PUBLIC_IP" <<'PY'
from pathlib import Path
import json,sys
runtime,state,ip=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
for p in (runtime,state):
    if not p.exists(): continue
    d=json.loads(p.read_text(encoding='utf-8')); d['public_ip']=ip
    if p==state:
        sid=int(d.get('id') or 0); d['fastdl_url']=f'http://{ip}/fastdl/{sid}/'
    t=p.with_name('.'+p.name+'.v11.tmp'); t.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); t.replace(p)
    print('updated:',p)
PY

echo "[5/11] Rebuild FastDL mirror through panel controller..."
"$LIVE_CTL" fastdl-sync "$SID"

echo "[6/11] Validate MIRROR BSP integrity..."
python3 - "$CSTRIKE/maps" "$FASTDL/maps" <<'PY'
from pathlib import Path
import struct,sys
src,dst=Path(sys.argv[1]),Path(sys.argv[2]); missing=[]; bad=[]; mismatch=[]; maps=sorted(src.glob('*.bsp'))
for p in maps:
    q=dst/p.name
    if not q.is_file(): missing.append(p.name); continue
    h=q.read_bytes()[:4]; v=struct.unpack('<I',h)[0] if len(h)==4 else None
    if v!=30: bad.append((p.name,v,h.hex()))
    if p.stat().st_size!=q.stat().st_size: mismatch.append((p.name,p.stat().st_size,q.stat().st_size))
print('source:',len(maps),'mirror:',len(list(dst.glob('*.bsp'))),'missing:',len(missing),'bad:',len(bad),'size mismatch:',len(mismatch))
if missing: print('MISSING',missing[:50])
if bad: print('BAD',bad[:50])
if mismatch: print('SIZE',mismatch[:50])
if missing or bad or mismatch: raise SystemExit(30)
PY

echo "[7/11] Patch nginx vhost that nginx -T actually loads..."
nginx -T >"$BACKUP/nginx-T-before.txt" 2>&1
python3 - "$BACKUP/nginx-T-before.txt" "$BACKUP" "$PUBLIC_IP" <<'PY'
from pathlib import Path
import re,shutil,sys

dump=Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore'); backup=Path(sys.argv[2]); ip=sys.argv[3]
domain='old-zombie.ru'; www='www.old-zombie.ru'; site_root=Path('/var/www/hyper-host-sites/old-zombie.ru/public_html')
loaded=[]
for m in re.finditer(r'(?m)^# configuration file (.+):$',dump):
    p=Path(m.group(1))
    try: p=p.resolve(strict=True)
    except Exception: pass
    if p.is_file() and p not in loaded: loaded.append(p)

def blocks(text):
    out=[]
    for m in re.finditer(r'(?m)^[ \t]*server\s*\{',text):
        start=m.start(); i=text.find('{',m.start()); depth=0; quote=None; esc=False
        while i<len(text):
            ch=text[i]
            if quote:
                if esc: esc=False
                elif ch=='\\': esc=True
                elif ch==quote: quote=None
            else:
                if ch in ("'",'"'): quote=ch
                elif ch=='#':
                    n=text.find('\n',i)
                    if n<0: break
                    i=n; continue
                elif ch=='{': depth+=1
                elif ch=='}':
                    depth-=1
                    if depth==0: out.append((start,i+1,text[start:i+1])); break
            i+=1
    return out

def oldz(b): return bool(re.search(r'(?im)^\s*server_name\b[^\n;]*old-zombie\.ru',b))
def http80(b): return bool(re.search(r'(?im)^\s*listen\s+(?:\[[^\]]+\]:)?80\b',b)) and not bool(re.search(r'(?im)^\s*listen\s+(?:\[[^\]]+\]:)?443\b',b))
def ssl(b): return bool(re.search(r'(?im)^\s*listen\s+(?:\[[^\]]+\]:)?443\b',b))

for p in loaded:
    try: txt=p.read_text(encoding='utf-8',errors='ignore')
    except Exception: continue
    for _,_,b in blocks(txt):
        if oldz(b):
            m=re.search(r'(?im)^\s*root\s+([^;]+);',b)
            if m:
                q=Path(m.group(1).strip().strip("\"'"))
                if q.is_dir(): site_root=q

# Remove direct IP from every other active server_name, so IP requests cannot land in another vhost.
for p in loaded:
    try: txt=p.read_text(encoding='utf-8',errors='ignore')
    except Exception: continue
    def sn(m):
        toks=m.group(2).split()
        if ip not in toks: return m.group(0)
        rem=[x for x in toks if x!=ip] or ['legacy-direct-ip-disabled.invalid']
        return m.group(1)+' '.join(rem)+';'
    new=re.sub(r'(?m)^(\s*server_name\s+)([^;]+);',sn,txt)
    if new!=txt:
        safe=p.as_posix().strip('/').replace('/','__'); shutil.copy2(p,backup/(safe+'.before-ip-clean')); p.write_text(new,encoding='utf-8'); print('cleaned IP conflict:',p)

patched=False
for p in loaded:
    try: txt=p.read_text(encoding='utf-8',errors='ignore')
    except Exception: continue
    reps=[]
    for a,b,blk in blocks(txt):
        if not oldz(blk): continue
        if http80(blk):
            new=f'''server {{
    listen 80;
    listen [::]:80;
    server_name {domain} {www} {ip};

    location ^~ /.well-known/acme-challenge/ {{
        root {site_root};
        try_files $uri =404;
    }}

    # HYPER-HOST FASTDL IP FINAL v11
    location ^~ /fastdl/ {{
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        sendfile on;
        tcp_nopush on;
        types {{ }}
        default_type application/octet-stream;
        add_header X-Hyper-FastDL "raw-v11" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "public, max-age=86400" always;
    }}

    location / {{ return 301 https://{domain}$request_uri; }}
}}'''
            reps.append((a,b,new))
        elif ssl(blk):
            new=re.sub(r'(?ms)\n\s*# OLDZ V9 BEGIN.*?# OLDZ V9 END\s*\n?','\n',blk)
            new=re.sub(r'(?ms)\n\s*# HYPER-HOST FASTDL IP FINAL v11 BEGIN.*?# HYPER-HOST FASTDL IP FINAL v11 END\s*\n?','\n',new)
            ins='''
    # HYPER-HOST FASTDL IP FINAL v11 BEGIN
    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        sendfile on;
        types { }
        default_type application/octet-stream;
        add_header X-Hyper-FastDL "raw-v11" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "public, max-age=86400" always;
    }
    # HYPER-HOST FASTDL IP FINAL v11 END
'''
            x=new.find('{')+1; new=new[:x]+ins+new[x:]; reps.append((a,b,new))
    if reps:
        safe=p.as_posix().strip('/').replace('/','__'); before=backup/(safe+'.before-v11')
        if not before.exists(): shutil.copy2(p,before)
        for a,b,new in sorted(reps,reverse=True): txt=txt[:a]+new+txt[b:]
        p.write_text(txt,encoding='utf-8'); print('patched:',p); patched=True
if not patched: raise SystemExit('no loaded old-zombie.ru nginx vhost found')
PY
nginx -t
systemctl reload nginx

echo "[8/11] Normalize server.cfg to one canonical FastDL block..."
"$LIVE_CTL" fastdl-sync "$SID" | tee "$BACKUP/fastdl-sync.json"
python3 - "$CSTRIKE/server.cfg" "$PUBLIC_IP" "$SID" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); expected=f'http://{sys.argv[2]}/fastdl/{sys.argv[3]}/'; text=p.read_text(encoding='utf-8',errors='ignore')
vals=re.findall(r'(?im)^\s*sv_downloadurl\s+"?([^"\r\n]+)',text); blocks=text.count('// HYPER-HOST FASTDL BEGIN')
print('FastDL blocks:',blocks); print('sv_downloadurl values:',vals)
if blocks!=1: raise SystemExit('expected exactly one FastDL block')
if not vals or vals[-1].strip().rstrip('/')!=expected.rstrip('/'): raise SystemExit('wrong sv_downloadurl')
if any(v.strip().rstrip('/')!=expected.rstrip('/') for v in vals): raise SystemExit('stale sv_downloadurl still exists')
PY

echo "[9/11] Verify RAW BSP through nginx by direct public-IP vhost..."
PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname 'zm_*.bsp' -print -quit)"
[[ -n "$PROBE" ]] || PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname '*.bsp' -print -quit)"
[[ -n "$PROBE" ]] || fail "no BSP in FastDL mirror"
REL="${PROBE#"$FASTDL/"}"
HDR="$BACKUP/ip-http.headers"; BODY="$BACKUP/ip-http.body"
curl -sS -H "Host: $PUBLIC_IP" -H 'Range: bytes=0-3' -D "$HDR" -o "$BODY" "http://127.0.0.1/fastdl/$SID/$REL"
head -n 20 "$HDR"
HEX="$(xxd -l 4 -p "$BODY")"
echo "body head: $HEX"
[[ "$HEX" == "1e000000" ]] || fail "FastDL returned non-BSP data; got $HEX instead of 1e000000"
! grep -qi '^Location:' "$HDR" || fail "FastDL is still redirecting"

echo "[10/11] Restart CS server and apply runtime FastDL cvars..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
"$LIVE_CTL" rcon "$SID" "sv_allowdownload 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allowupload 0" || true
"$LIVE_CTL" rcon "$SID" "sv_allow_dlfile 1" || true
"$LIVE_CTL" rcon "$SID" "sv_downloadurl \"http://$PUBLIC_IP/fastdl/$SID/\"" || true
"$LIVE_CTL" rcon "$SID" "sv_downloadurl" || true

echo "[11/11] Public self-test..."
set +e
PUB_HDR="$BACKUP/public.headers"; PUB_BODY="$BACKUP/public.body"
curl -sS --connect-timeout 5 --max-time 20 -H 'Range: bytes=0-3' -D "$PUB_HDR" -o "$PUB_BODY" "http://$PUBLIC_IP/fastdl/$SID/$REL"
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  head -n 20 "$PUB_HDR"
  PUB_HEX="$(xxd -l 4 -p "$PUB_BODY" 2>/dev/null || true)"
  echo "public body head: $PUB_HEX"
  [[ "$PUB_HEX" == "1e000000" ]] && echo "[OK] public FastDL returns raw BSP" || echo "[WARN] local nginx is correct, but public NAT/proxy route differs"
else
  echo "[WARN] public self-test failed; NAT hairpin may be disabled"
fi

GAME_PORT="$(python3 - "$STATE" <<'PY'
from pathlib import Path
import json,sys
try: print(int(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')).get('port') or 27015))
except Exception: print(27015)
PY
)"

echo
echo "================================================================"
echo " [SUCCESS] HYPER-HOST FASTDL IP FINAL v11"
echo "================================================================"
echo "Game server: $PUBLIC_IP:$GAME_PORT"
echo "FastDL:      http://$PUBLIC_IP/fastdl/$SID/"
echo "Probe:       $REL"
echo "Good BSP:    1e000000"
echo "Bad HTML:    3c21646f = '<!do' = 1868833084"
echo "Backup:      $BACKUP"
echo
"$LIVE_CTL" fastdl-status "$SID" || true
