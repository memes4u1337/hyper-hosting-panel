#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
PUBLIC_IP="${3:-90.189.208.25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STATE="/var/lib/hyper-cs16/servers/$SID.json"
RUNTIME="/etc/hyper-cs16/runtime.json"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
NGINX_DIR="/etc/nginx/hyper-host-managed"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-tcp-v15-$STAMP"

die(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$CTL" ]] || die "missing $CTL"
[[ -f "$STATE" ]] || die "missing $STATE"
[[ -d "$CSTRIKE" ]] || die "missing $CSTRIKE"

PORT="$(python3 - "$STATE" <<'PY'
from pathlib import Path
import json,sys
d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
print(int(d.get('port') or 27015))
PY
)"
URL="http://$PUBLIC_IP:$PORT/fastdl/$SID/"
NGINX_CONF="$NGINX_DIR/90-cs16-fastdl-$SID.conf"

mkdir -p "$BACKUP" "$NGINX_DIR"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg.before" || true
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/state.before.json" || true
[[ -f "$RUNTIME" ]] && cp -a "$RUNTIME" "$BACKUP/runtime.before.json" || true
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/nginx-fastdl.before.conf" || true

echo "================================================================"
echo " HYPER-HOST CS 1.6 FASTDL TCP/IP FINAL v15"
echo " Server:       #$SID"
echo " Game:         $PUBLIC_IP:$PORT/UDP"
echo " FastDL:       $URL (TCP)"
echo " nginx config: $NGINX_CONF"
echo " Backup:       $BACKUP"
echo "================================================================"

echo "[1/9] Patch controller FastDL URL to IP:game-port..."
python3 - "$CTL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
start=s.find('def _fastdl_url(c:dict)->str:')
end=s.find('\ndef _fastdl_apply_cfg', start)
if start < 0 or end < 0:
    raise SystemExit('cannot locate _fastdl_url')
new = """def _fastdl_url(c:dict)->str:
    sid=int(c.get('id') or 0)
    port=int(c.get('port') or 27015)
    public=''
    try:
        rt=load_runtime()
        public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()
    except Exception:
        public=str(c.get('public_ip') or '').strip()
    try:
        addr=ipaddress.ip_address(public)
        if addr.version==4 and not addr.is_unspecified and not addr.is_loopback:
            return f'http://{public}:{port}/fastdl/{sid}/'
    except Exception:
        pass
    return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'
"""
s=s[:start]+new+s[end:]
marker='# HYPER-HOST FASTDL TCP/IP FINAL v15'
if marker not in s:
    s=s.replace('#!/usr/bin/env python3\n','#!/usr/bin/env python3\n'+marker+'\n',1)
p.write_text(s,encoding='utf-8')
print('patched:',p)
PY
python3 -m py_compile "$CTL"
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[2/9] Persist public IP and canonical URL..."
python3 - "$RUNTIME" "$STATE" "$PUBLIC_IP" "$PORT" "$SID" <<'PY'
from pathlib import Path
import json,sys
runtime=Path(sys.argv[1]); state=Path(sys.argv[2])
ip=sys.argv[3]; port=int(sys.argv[4]); sid=int(sys.argv[5])
url=f'http://{ip}:{port}/fastdl/{sid}/'
for p in (runtime,state):
    if not p.exists():
        continue
    d=json.loads(p.read_text(encoding='utf-8'))
    d['public_ip']=ip
    if p == state:
        d['fastdl_url']=url
    tmp=p.with_name('.'+p.name+'.v15.tmp')
    tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    tmp.replace(p)
    print('updated:',p)
print('url:',url)
PY

echo "[3/9] Rebuild FastDL mirror..."
"$LIVE" fastdl-clean "$SID"
"$LIVE" fastdl-sync "$SID"

echo "[4/9] Validate mirrored BSP files..."
python3 - "$FASTDL/maps" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1]); maps=sorted(root.glob('*.bsp')); bad=[]
for p in maps:
    b=p.read_bytes()[:4]
    ver=struct.unpack('<I',b)[0] if len(b)==4 else None
    if ver != 30:
        bad.append((p.name,ver,b.hex()))
print('mirror maps:',len(maps),'bad:',len(bad))
for x in bad[:30]: print('BAD',x)
if not maps or bad: raise SystemExit(20)
PY

echo "[5/9] Create dedicated nginx FastDL listener on TCP $PORT..."
cat > "$NGINX_CONF" <<EOF2
# HYPER-HOST managed CS 1.6 FastDL
server {
    listen $PORT;
    listen [::]:$PORT;
    server_name _;

    access_log /var/log/nginx/hyper-cs16-fastdl-$SID-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-$SID-error.log warn;

    location ^~ /fastdl/$SID/ {
        alias /srv/hyper-cs16/fastdl/$SID/;
        autoindex off;
        sendfile on;
        tcp_nopush on;
        types { }
        default_type application/octet-stream;
        add_header X-Hyper-FastDL "tcp-v15" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "public, max-age=86400" always;
        limit_except GET HEAD { deny all; }
    }

    location / { return 404; }
}
EOF2

nginx -t
systemctl reload nginx

echo "[6/9] Open TCP $PORT in UFW if active..."
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$PORT/tcp" >/dev/null
    echo "ufw: allowed $PORT/tcp"
else
    echo "ufw: inactive/not installed"
fi

echo "[7/9] Verify nginx returns REAL BSP on TCP $PORT..."
PROBE="$FASTDL/maps/zm_2day.bsp"
[[ -f "$PROBE" ]] || PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -name '*.bsp' -print -quit)"
[[ -n "$PROBE" ]] || die "no BSP found"
REL="${PROBE#"$FASTDL/"}"
HDR="$BACKUP/local.headers"
BODY="$BACKUP/local.body"
curl -sS --connect-timeout 5 -H 'Range: bytes=0-3' -D "$HDR" -o "$BODY" "http://127.0.0.1:$PORT/fastdl/$SID/$REL"
head -n 20 "$HDR"
HEX="$(xxd -l 4 -p "$BODY")"
echo "body head: $HEX"
grep -qi '^X-Hyper-FastDL: tcp-v15' "$HDR" || die "request did not hit v15 listener"
[[ "$HEX" == "1e000000" ]] || die "bad BSP bytes: $HEX"

echo "[8/9] Enforce FastDL URL in server.cfg and restart HLDS..."
python3 - "$CSTRIKE/server.cfg" "$URL" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); url=sys.argv[2]
text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
text=text.replace('\r\n','\n').replace('\r','\n')
text=re.sub(r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?','',text)
managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
keep=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+',line)
    if m and m.group(1).lower() in managed:
        continue
    keep.append(line)
block=[
    '// HYPER-HOST FASTDL BEGIN',
    '// Managed automatically by HYPER-HOST.',
    'sv_allowdownload 1',
    'sv_allowupload 0',
    'sv_send_resources 1',
    'sv_allow_dlfile 1',
    f'sv_downloadurl "{url}"',
    '// HYPER-HOST FASTDL END',
]
p.write_text('\n'.join(keep).rstrip()+'\n\n'+'\n'.join(block)+'\n',encoding='utf-8')
print('configured:',url)
PY
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

echo "[9/9] Final checks..."
echo "TCP listener:"
ss -ltnp | grep -E ":$PORT[[:space:]]" || true
echo "UDP listener:"
ss -lunp | grep -E ":$PORT[[:space:]]" || true
echo
"$LIVE" fastdl-status "$SID" || true
echo
grep -E '^[[:space:]]*sv_(downloadurl|allowdownload|allowupload|send_resources|allow_dlfile)' "$CSTRIKE/server.cfg" || true

echo
echo "================================================================"
echo " [SUCCESS] FASTDL TCP/IP v15"
echo "================================================================"
echo " Game server: $PUBLIC_IP:$PORT (UDP)"
echo " FastDL URL:  $URL (TCP)"
echo " Local BSP:   $HEX"
echo " Expected:    1e000000"
echo " Backup:      $BACKUP"
echo "================================================================"
