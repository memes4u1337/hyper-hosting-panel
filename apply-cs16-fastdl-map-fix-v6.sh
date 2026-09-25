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
FASTDL="/srv/hyper-cs16/fastdl/${SID}"
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
NGINX_CONF="/etc/nginx/conf.d/00-hyper-cs16-fastdl-8080.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v6-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -f "$SRC_CTL" ]] || { echo "[ERROR] missing $SRC_CTL"; exit 2; }
[[ -d "$CSTRIKE/maps" ]] || { echo "[ERROR] missing $CSTRIKE/maps"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.repo"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live"
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg"
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/nginx.conf"
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/server-state.json"

echo "================================================================"
echo " HYPER-HOST FASTDL MAP FIX v6"
echo " Server: #$SID"
echo " URL:    http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID/"
echo " Backup: $BACKUP"
echo "================================================================"

echo "[1/8] Validate SOURCE BSP files..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1])
bad=[]; good=0
for p in sorted(root.glob('*.bsp')):
    h=p.read_bytes()[:4]
    v=struct.unpack('<I',h)[0] if len(h)==4 else None
    if v==30: good+=1
    else: bad.append((p.name,v,h.hex()))
print("valid BSP:",good)
print("bad BSP:",len(bad))
for x in bad[:20]: print(" BAD",x)
if bad: raise SystemExit(20)
PY

echo "[2/8] Install dedicated nginx FastDL on TCP $FASTDL_PORT..."
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
        add_header Cache-Control "public, max-age=86400" always;
        add_header X-Hyper-FastDL "v6" always;
    }

    location / {
        return 404;
    }
}
EOF
nginx -t
systemctl reload nginx

echo "[3/8] Firewall / router mapping..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$FASTDL_PORT/tcp" >/dev/null 2>&1 || true
fi

if command -v upnpc >/dev/null 2>&1; then
  upnpc -e "HYPER-FASTDL-$FASTDL_PORT" -a "$LAN_IP" "$FASTDL_PORT" "$FASTDL_PORT" TCP || true
else
  echo "[INFO] upnpc not installed."
  echo "[INFO] Router rule required: TCP $FASTDL_PORT -> $LAN_IP:$FASTDL_PORT"
fi

echo "[4/8] Patch panel FastDL URL..."
PATCHER="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cwoKY3RsPVBhdGgoc3lzLmFyZ3ZbMV0pCnM9Y3RsLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnKQoKYm9keSA9ICJkZWYgX2Zhc3RkbF91cmwoYzpkaWN0KS0+c3RyOlxuICAgIHNpZD1pbnQoYy5nZXQoJ2lkJykgb3IgMClcbiAgICByZXR1cm4gZidodHRwOi8vOTAuMTg5LjIwOC4yNTo4MDgwL2Zhc3RkbC97c2lkfSdcbiIKCnBhdD1yZS5jb21waWxlKHInKD9tcyleZGVmIF9mYXN0ZGxfdXJsXFxiLio/KD89XmRlZiBfZmFzdGRsX2FwcGx5X2NmZ1xcYiknKQptPXBhdC5zZWFyY2gocykKaWYgbm90IG06CiAgICByYWlzZSBTeXN0ZW1FeGl0KCdbUEFUQ0ggRVJST1JdIF9mYXN0ZGxfdXJsIGZ1bmN0aW9uIHJhbmdlIG5vdCBmb3VuZCcpCnM9c1s6bS5zdGFydCgpXStib2R5LnJzdHJpcCgpKyJcXG5cXG4iK3NbbS5lbmQoKTpdCmN0bC53cml0ZV90ZXh0KHMsZW5jb2Rpbmc9J3V0Zi04JykK' | base64 -d > "$PATCHER"
python3 "$PATCHER" "$SRC_CTL"
python3 -m py_compile "$SRC_CTL"
install -m 0755 "$SRC_CTL" "$LIVE_CTL"
python3 -m py_compile "$LIVE_CTL"
rm -f "$PATCHER"

echo "[5/8] Clean-copy maps to FastDL..."
mkdir -p "$FASTDL/maps"
rsync -a --delete --safe-links "$CSTRIKE/maps/" "$FASTDL/maps/"
find "$FASTDL/maps" -type f -name '*.ztmp' -delete || true
chown -R root:www-data "$FASTDL"
find "$FASTDL" -type d -exec chmod 0755 {} +
find "$FASTDL" -type f -exec chmod 0644 {} +

echo "[6/8] Repair server.cfg FastDL block + state..."
python3 - "$CSTRIKE/server.cfg" "$STATE" "$SID" "$PUBLIC_IP" "$FASTDL_PORT" <<'PY'
from pathlib import Path
import json,re,sys
cfg=Path(sys.argv[1]); state=Path(sys.argv[2])
sid=int(sys.argv[3]); ip=sys.argv[4]; port=int(sys.argv[5])
url=f'http://{ip}:{port}/fastdl/{sid}'

text=cfg.read_text(encoding='utf-8',errors='ignore') if cfg.exists() else ''
if text.count('\\n')>=5 and text.count('\n')<=2:
    text=text.replace('\\r\\n','\n').replace('\\n','\n').replace('\\r','\n')
text=text.replace('\r\n','\n').replace('\r','\n')

text=re.sub(r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?', '', text)

managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
kept=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+',line)
    if m and m.group(1).lower() in managed:
        continue
    kept.append(line)

block=[
    '// HYPER-HOST FASTDL BEGIN',
    '// Dedicated port: never mix FastDL with websites/SSL redirects.',
    'sv_allowdownload 1',
    'sv_allowupload 0',
    'sv_send_resources 1',
    'sv_allow_dlfile 1',
    f'sv_downloadurl "{url}"',
    '// HYPER-HOST FASTDL END'
]
cfg.write_text('\n'.join(kept).rstrip()+'\n\n'+'\n'.join(block)+'\n',encoding='utf-8')

if state.is_file():
    try:
        d=json.loads(state.read_text(encoding='utf-8'))
        d['fastdl_url']=url
        state.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    except Exception as e:
        print("state warning:",e)

print("sv_downloadurl =",url)
PY

echo "[7/8] Apply runtime cvars..."
"$LIVE_CTL" rcon "$SID" "sv_allowdownload 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allowupload 0" || true
"$LIVE_CTL" rcon "$SID" "sv_send_resources 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allow_dlfile 1" || true
"$LIVE_CTL" rcon "$SID" "sv_downloadurl \"http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID\"" || true

echo "[8/8] Verify every FastDL BSP over local HTTP..."
python3 - "$FASTDL/maps" "$SID" "$FASTDL_PORT" <<'PY'
from pathlib import Path
import subprocess,struct,sys
maps=Path(sys.argv[1]); sid=int(sys.argv[2]); port=int(sys.argv[3])
bad=[]; ok=0
for p in sorted(maps.glob('*.bsp')):
    url=f'http://127.0.0.1:{port}/fastdl/{sid}/maps/{p.name}'
    cp=subprocess.run(
        ['curl','-sS','--connect-timeout','2','--max-time','8','-o','-',url],
        stdout=subprocess.PIPE,stderr=subprocess.PIPE
    )
    data=cp.stdout
    head=data[:4]
    ver=struct.unpack('<I',head)[0] if len(head)==4 else None
    if cp.returncode==0 and ver==30:
        ok+=1
    else:
        bad.append({'map':p.name,'curl_rc':cp.returncode,'version':ver,'head':head.hex()})
print("HTTP-valid BSP:",ok)
print("HTTP-bad BSP:",len(bad))
for x in bad[:20]: print(" BAD",x)
if bad: raise SystemExit(30)
PY

echo
echo "--- zm_303 local FastDL first 4 bytes ---"
curl -sS --connect-timeout 2 --max-time 8 \
  "http://127.0.0.1:$FASTDL_PORT/fastdl/$SID/maps/zm_303.bsp" \
  | head -c 4 | xxd -p

echo
echo "--- public/hairpin zm_303 first 4 bytes ---"
PUB_HEAD="$(curl -sS --connect-timeout 3 --max-time 10 \
  "http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID/maps/zm_303.bsp" 2>/dev/null \
  | head -c 4 | xxd -p || true)"
echo "public first4 hex: $PUB_HEAD"
if [[ "$PUB_HEAD" != "1e000000" ]]; then
  echo "[WARN] Public/hairpin path is not BSP yet."
  echo "       Verify router: TCP $FASTDL_PORT -> $LAN_IP:$FASTDL_PORT"
else
  echo "[OK] Public/hairpin path returns BSP v30."
fi

echo
echo "================================================================"
echo " [SUCCESS] FASTDL MAP FIX v6 INSTALLED"
echo "================================================================"
echo "FastDL URL: http://$PUBLIC_IP:$FASTDL_PORT/fastdl/$SID/"
echo
echo "IMPORTANT:"
echo "This PC already cached a broken HTML file as cstrike/maps/zm_303.bsp."
echo "Delete LOCAL client cstrike/maps/zm_303.bsp and zm_303.bsp.ztmp before reconnecting."
echo
echo "Router if UPnP did not create it:"
echo " TCP $FASTDL_PORT -> $LAN_IP:$FASTDL_PORT"
echo "Backup: $BACKUP"
