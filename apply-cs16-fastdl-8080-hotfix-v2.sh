#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"

PUBLIC_IP="90.189.208.25"
LAN_IP="192.168.0.179"
FASTDL_PORT="8080"

SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
SERVER_ROOT="/srv/hyper-cs16/servers/${SID}"
CSTRIKE="$SERVER_ROOT/cstrike"
FASTDL_ROOT="/srv/hyper-cs16/fastdl/${SID}"
SERVER_CFG="$CSTRIKE/server.cfg"
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
NGINX_CONF="/etc/nginx/conf.d/00-hyper-cs16-fastdl-8080.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-8080-hotfix-v2-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -f "$SRC_CTL" ]] || { echo "[ERROR] controller missing: $SRC_CTL"; exit 2; }
[[ -d "$CSTRIKE" ]] || { echo "[ERROR] cstrike missing: $CSTRIKE"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.repo"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live"
[[ -f "$SERVER_CFG" ]] && cp -a "$SERVER_CFG" "$BACKUP/server.cfg"
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/server-state.json"
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/nginx-fastdl-8080.conf"

echo "=============================================================="
echo " HYPER-HOST FASTDL 8080 HOTFIX v2"
echo " Server: #$SID"
echo " URL:    http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID/"
echo " Backup: $BACKUP"
echo "=============================================================="

echo "[1/9] Validate source BSP..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1])
bad=[]; good=0
for p in sorted(root.glob('*.bsp')):
    raw=p.read_bytes()[:4]
    ver=struct.unpack('<I',raw)[0] if len(raw)==4 else -1
    if ver==30: good+=1
    else: bad.append((p.name,ver,raw.hex()))
print("valid BSP:",good)
print("bad BSP:",len(bad))
if bad:
    print(bad[:30])
    raise SystemExit(10)
PY

echo "[2/9] Install dedicated nginx FastDL on TCP $FASTDL_PORT..."
cat >"$NGINX_CONF" <<EOF
server {
    listen $FASTDL_PORT default_server;
    listen [::]:$FASTDL_PORT default_server;
    server_name _;

    access_log /var/log/nginx/hyper-cs16-fastdl-8080-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-8080-error.log warn;

    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        default_type application/octet-stream;
        try_files \$uri =404;
        add_header Cache-Control "public, max-age=86400" always;
        add_header X-Hyper-FastDL "8080" always;
    }

    location / {
        return 404;
    }
}
EOF
nginx -t
systemctl reload nginx

if command -v ufw >/dev/null 2>&1; then
    ufw allow "$FASTDL_PORT/tcp" >/dev/null 2>&1 || true
fi

echo "[3/9] Patch panel URL without touching the old _fastdl_url body..."
PATCHER="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cwoKY3RsID0gUGF0aChzeXMuYXJndlsxXSkKcyA9IGN0bC5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JykKCm92ZXJyaWRlID0gcg==' | base64 -d > "$PATCHER"
python3 "$PATCHER" "$SRC_CTL"
python3 -m py_compile "$SRC_CTL"
install -m 0755 "$SRC_CTL" "$LIVE_CTL"
python3 -m py_compile "$LIVE_CTL"
rm -f "$PATCHER"

echo "[4/9] Put server.cfg in order and keep ONE FastDL block..."
python3 - "$SERVER_CFG" "$PUBLIC_IP" "$FASTDL_PORT" "$SID" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1]); ip=sys.argv[2]; port=sys.argv[3]; sid=sys.argv[4]
raw=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''

if raw.count('\\n')>=5 and raw.count('\n')<=2:
    raw=raw.replace('\\r\\n','\n').replace('\\n','\n').replace('\\r','\n')

text=raw.replace('\r\n','\n').replace('\r','\n')

text=re.sub(
    r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?',
    '',
    text
)

managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
out=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\b',line)
    if m and m.group(1).lower() in managed:
        continue
    out.append(line)

url=f'http://{ip}:{port}/fastdl/{sid}/'
block=[
    '// HYPER-HOST FASTDL BEGIN',
    '// Canonical FastDL block. Do not duplicate.',
    'sv_allowdownload 1',
    'sv_allowupload 0',
    'sv_send_resources 1',
    'sv_allow_dlfile 1',
    f'sv_downloadurl "{url}"',
    '// HYPER-HOST FASTDL END',
]
clean='\n'.join(out).rstrip()+'\n\n'+'\n'.join(block)+'\n'
p.write_text(clean,encoding='utf-8')

print("server.cfg lines:",len(clean.splitlines()))
print("FastDL blocks:",clean.count('// HYPER-HOST FASTDL BEGIN'))
print("sv_downloadurl:",url)
PY

echo "[5/9] Clean-copy client resources to FastDL..."
mkdir -p "$FASTDL_ROOT"
for d in maps models sound sprites gfx resource overviews events media; do
    if [[ -d "$CSTRIKE/$d" ]]; then
        mkdir -p "$FASTDL_ROOT/$d"
        rsync -a --delete --safe-links "$CSTRIKE/$d/" "$FASTDL_ROOT/$d/"
    else
        rm -rf "$FASTDL_ROOT/$d"
    fi
done

find "$FASTDL_ROOT" -maxdepth 1 -type f -iname '*.wad' -delete 2>/dev/null || true
find "$CSTRIKE" -maxdepth 1 -type f -iname '*.wad' -exec cp -a {} "$FASTDL_ROOT/" \;

find "$FASTDL_ROOT" -type f -name '*.ztmp' -delete 2>/dev/null || true

chown -R root:www-data "$FASTDL_ROOT"
find "$FASTDL_ROOT" -type d -exec chmod 0755 {} +
find "$FASTDL_ROOT" -type f -exec chmod 0644 {} +

echo "[6/9] Verify every FastDL BSP is byte-identical to source..."
python3 - "$CSTRIKE/maps" "$FASTDL_ROOT/maps" <<'PY'
from pathlib import Path
import hashlib,struct,sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2])
bad=[]; count=0
for sp in sorted(src.glob('*.bsp')):
    dp=dst/sp.name
    if not dp.is_file():
        bad.append((sp.name,'missing'))
        continue
    a=sp.read_bytes(); b=dp.read_bytes()
    sv=struct.unpack('<I',a[:4])[0] if len(a)>=4 else -1
    dv=struct.unpack('<I',b[:4])[0] if len(b)>=4 else -1
    same=hashlib.sha256(a).digest()==hashlib.sha256(b).digest()
    if sv!=30 or dv!=30 or not same:
        bad.append((sp.name,f'source={sv} fastdl={dv} same={same}'))
    else:
        count+=1
print("verified BSP:",count)
print("bad/missing:",len(bad))
if bad:
    print(bad[:50])
    raise SystemExit(20)
PY

echo "[7/9] Verify nginx returns REAL BSP bytes on localhost:$FASTDL_PORT..."
PROBE="$FASTDL_ROOT/maps/zm_303.bsp"
if [[ ! -f "$PROBE" ]]; then
    PROBE="$(find "$FASTDL_ROOT/maps" -maxdepth 1 -type f -iname '*.bsp' -print -quit)"
fi
[[ -n "$PROBE" && -f "$PROBE" ]] || { echo "[ERROR] no BSP in FastDL"; exit 21; }

REL="${PROBE#"$FASTDL_ROOT/"}"
curl -fsS --connect-timeout 3 --max-time 15 \
  "http://127.0.0.1:$FASTDL_PORT/fastdl/$SID/$REL" \
  -o /tmp/hh-fastdl-map.bsp

python3 - /tmp/hh-fastdl-map.bsp <<'PY'
from pathlib import Path
import struct,sys
p=Path(sys.argv[1]); raw=p.read_bytes()
head=raw[:4]
ver=struct.unpack('<I',head)[0] if len(head)==4 else -1
print("HTTP bytes:",len(raw))
print("HTTP head:",head.hex())
print("HTTP BSP version:",ver)
if ver!=30:
    raise SystemExit("HTTP is not returning a GoldSrc BSP")
PY
rm -f /tmp/hh-fastdl-map.bsp

echo "[8/9] Persist URL in server state + apply runtime cvars..."
python3 - "$STATE" "$PUBLIC_IP" "$FASTDL_PORT" "$SID" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]); ip=sys.argv[2]; port=sys.argv[3]; sid=sys.argv[4]
if p.is_file():
    d=json.loads(p.read_text(encoding='utf-8'))
    d['fastdl_url']=f'http://{ip}:{port}/fastdl/{sid}'
    p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY

"$LIVE_CTL" rcon "$SID" "sv_allowdownload 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allowupload 0" || true
"$LIVE_CTL" rcon "$SID" "sv_send_resources 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allow_dlfile 1" || true
"$LIVE_CTL" rcon "$SID" "sv_downloadurl \\"http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID/\\"" || true

echo "[9/9] Public-port test..."
PUBLIC_CODE="$(curl -sS --connect-timeout 4 --max-time 12 -o /tmp/hh-public-map.bin -w '%{http_code}' \
  "http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID/$REL" || true)"
echo "Public HTTP code from server: $PUBLIC_CODE"

if [[ "$PUBLIC_CODE" == "200" && -s /tmp/hh-public-map.bin ]]; then
    python3 - /tmp/hh-public-map.bin <<'PY'
from pathlib import Path
import struct,sys
raw=Path(sys.argv[1]).read_bytes()
ver=struct.unpack('<I',raw[:4])[0] if len(raw)>=4 else -1
print("Public BSP version:",ver)
print("Public head:",raw[:4].hex())
if ver!=30:
    raise SystemExit(30)
PY
else
    echo
    echo "[WARN] Public :$FASTDL_PORT is not reachable from this host."
    echo "Your UPnP output already showed: No valid UPNP Internet Gateway Device found."
    echo "Create this rule manually on the router:"
    echo
    echo "  TCP external $FASTDL_PORT -> $LAN_IP:$FASTDL_PORT"
    echo
    echo "Without that rule Internet players cannot reach the dedicated FastDL port."
fi
rm -f /tmp/hh-public-map.bin

echo
echo "--- Final controller URL ---"
"$LIVE_CTL" fastdl-status "$SID" || true
echo
echo "--- Runtime URL ---"
"$LIVE_CTL" rcon "$SID" "sv_downloadurl" || true

echo
echo "=============================================================="
echo " [SUCCESS] FASTDL 8080 HOTFIX v2 INSTALLED LOCALLY"
echo "=============================================================="
echo "FastDL URL: http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID/"
echo "Local binary BSP test: OK (version 30)"
echo
echo "IMPORTANT:"
echo "If the public test above was not HTTP 200, add router forwarding:"
echo "TCP $FASTDL_PORT -> $LAN_IP:$FASTDL_PORT"
echo
echo "Backup: $BACKUP"
