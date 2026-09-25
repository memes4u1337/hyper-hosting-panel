#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
SRC="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
NGINX_CONF="/etc/nginx/conf.d/00-hyper-cs16-fastdl-ip.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-final-v61-hotfix-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -f "$SRC" ]] || { echo "[ERROR] missing controller: $SRC"; exit 2; }
[[ -d "$CSTRIKE" ]] || { echo "[ERROR] missing server cstrike: $CSTRIKE"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/hyper-cs16-ctl.repo"
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live"
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg"

echo "=============================================================="
echo " HYPER-HOST FASTDL FINAL v6.1 HOTFIX"
echo " Server: #$SID"
echo " URL:    http://90.189.208.25/fastdl/$SID/"
echo " Backup: $BACKUP"
echo "=============================================================="

echo "[1/8] Fix controller globals/copy helper..."
PATCHER="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cwoKY3RsPVBhdGgoc3lzLmFyZ3ZbMV0pCnM9Y3RsLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnKQoKIyAxKSBSZXN0b3JlIHRoZSBnbG9iYWwgZm9yIGFueSBvbGQgY29kZSB0aGF0IHN0aWxsIHJlZmVyZW5jZXMgaXQuCmlmIG5vdCByZS5zZWFyY2gocicoP20pXkZBU1RETF9ESVJTXHMqPScsIHMpOgogICAgbGluZT0iRkFTVERMX0RJUlM9KCdtYXBzJywnbW9kZWxzJywnc291bmQnLCdzcHJpdGVzJywnZ2Z4JywncmVzb3VyY2UnLCdvdmVydmlld3MnLCdldmVudHMnLCdtZWRpYScpIgogICAgbT1yZS5zZWFyY2gocicoP20pXkZBU1RETF9ST09UXHMqPS4qJCcsIHMpCiAgICBpZiBtOgogICAgICAgIHM9c1s6bS5lbmQoKV0rIlxuIitsaW5lK3NbbS5lbmQoKTpdCiAgICBlbHNlOgogICAgICAgIG09cmUuc2VhcmNoKHInKD9tKV5mcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGhccyokJywgcykKICAgICAgICBpZiBub3QgbToKICAgICAgICAgICAgcmFpc2UgU3lzdGVtRXhpdCgnW1BBVENIIEVSUk9SXSBjYW5ub3QgbG9jYXRlIFBhdGggaW1wb3J0IGZvciBGQVNUREwgZmFsbGJhY2snKQogICAgICAgIHM9c1s6bS5lbmQoKV0rIlxuRkFTVERMX1JPT1Q9UGF0aCgnL3Nydi9oeXBlci1jczE2L2Zhc3RkbCcpXG4iK2xpbmUrc1ttLmVuZCgpOl0KCiMgMikgSW5qZWN0IG91ciBvd24gY29weSBoZWxwZXIuIFRoaXMgYXZvaWRzIGV2ZXJ5IHByZXZpb3VzIF9mYXN0ZGxfY29weV90cmVlIHNpZ25hdHVyZS4KaGVscGVyID0gcicnJwpkZWYgX2hoX2Zhc3RkbF9jb3B5X3RyZWVfdjYxKHNyYzpQYXRoLGRzdDpQYXRoKToKICAgIGlmIG5vdCBzcmMuaXNfZGlyKCk6CiAgICAgICAgaWYgZHN0LmV4aXN0cygpOgogICAgICAgICAgICBzaHV0aWwucm10cmVlKGRzdCxpZ25vcmVfZXJyb3JzPVRydWUpCiAgICAgICAgcmV0dXJuCiAgICBkc3QubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCiAgICBjcD1ydW4oWydyc3luYycsJy1hJywnLS1kZWxldGUnLCctLXNhZmUtbGlua3MnLHN0cihzcmMpKycvJyxzdHIoZHN0KSsnLyddLGNoZWNrPUZhbHNlLHRpbWVvdXQ9MTIwMCkKICAgIGlmIGNwLnJldHVybmNvZGUhPTA6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdGYXN0REwgcnN5bmMgZmFpbGVkIGZvciAnK3N0cihzcmMpKyc6ICcrKGNwLnN0ZG91dCBvciAnJylbLTI1MDA6XSkKCgonJycKaWYgJ2RlZiBfaGhfZmFzdGRsX2NvcHlfdHJlZV92NjEoJyBub3QgaW4gczoKICAgIG09cmUuc2VhcmNoKHInKD9tKV5kZWYgZmFzdGRsX3N5bmNcYicscykKICAgIGlmIG5vdCBtOgogICAgICAgIHJhaXNlIFN5c3RlbUV4aXQoJ1tQQVRDSCBFUlJPUl0gZmFzdGRsX3N5bmMgZnVuY3Rpb24gbm90IGZvdW5kJykKICAgIHM9c1s6bS5zdGFydCgpXStoZWxwZXIrc1ttLnN0YXJ0KCk6XQoKIyAzKSBQYXRjaCBvbmx5IHRoZSBib2R5IG9mIGZhc3RkbF9zeW5jLgptPXJlLnNlYXJjaChyJyg/bXMpXmRlZiBmYXN0ZGxfc3luY1xiLio/KD89XmRlZiBbQS1aYS16X11bQS1aYS16MC05X10qXGIpJyxzKQppZiBub3QgbToKICAgIHJhaXNlIFN5c3RlbUV4aXQoJ1tQQVRDSCBFUlJPUl0gZmFzdGRsX3N5bmMgZnVuY3Rpb24gcmFuZ2Ugbm90IGZvdW5kJykKYm9keT1tLmdyb3VwKDApCgojIE5ldmVyIGRlcGVuZCBvbiB0aGUgZ2xvYmFsIGFnYWluIGluc2lkZSB0aGlzIGZ1bmN0aW9uLgpib2R5PWJvZHkucmVwbGFjZSgKICAgICdmb3IgbmFtZSBpbiBGQVNURExfRElSUzonLAogICAgImZvciBuYW1lIGluICgnbWFwcycsJ21vZGVscycsJ3NvdW5kJywnc3ByaXRlcycsJ2dmeCcsJ3Jlc291cmNlJywnb3ZlcnZpZXdzJywnZXZlbnRzJywnbWVkaWEnKToiCikKCiMgSGFuZGxlIGJvdGggMi1hcmcgYW5kIG9sZCAzLWFyZyBfZmFzdGRsX2NvcHlfdHJlZSB2YXJpYW50cy4KYm9keT1yZS5zdWIoCiAgICByJ19mYXN0ZGxfY29weV90cmVlXChccypzcmNccyosXHMqZGRccyooPzosW14pXSopP1wpJywKICAgICdfaGhfZmFzdGRsX2NvcHlfdHJlZV92NjEoc3JjLGRkKScsCiAgICBib2R5CikKCnM9c1s6bS5zdGFydCgpXStib2R5K3NbbS5lbmQoKTpdCmN0bC53cml0ZV90ZXh0KHMsZW5jb2Rpbmc9J3V0Zi04JykK' | base64 -d >"$PATCHER"
python3 "$PATCHER" "$SRC"
python3 -m py_compile "$SRC"
install -m 0755 "$SRC" "$LIVE"
python3 -m py_compile "$LIVE"
rm -f "$PATCHER"

echo "[2/8] Put server.cfg in order..."
python3 - "$CSTRIKE/server.cfg" "$SID" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); sid=int(sys.argv[2])
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
kept=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\b',line)
    if m and m.group(1).lower() in managed:
        continue
    kept.append(line)

url=f'http://90.189.208.25/fastdl/{sid}/'
block=[
    '// HYPER-HOST FASTDL BEGIN',
    '// Managed automatically. One canonical FastDL block.',
    'sv_allowdownload 1',
    'sv_allowupload 0',
    'sv_send_resources 1',
    'sv_allow_dlfile 1',
    f'sv_downloadurl "{url}"',
    '// HYPER-HOST FASTDL END',
]
content='\n'.join(kept).rstrip()+'\n\n'+'\n'.join(block)+'\n'
p.write_text(content,encoding='utf-8')

helper='// HYPER-HOST canonical FastDL\n'+'\n'.join(block[2:-1])+'\n'
for name in ('fastdl.cfg','server_download_fix.cfg','SAFE_DOWNLOAD_MODE.cfg','ENABLE_FASTDL_AFTER_VERIFY.cfg'):
    try:
        (p.parent/name).write_text(helper,encoding='utf-8')
    except Exception:
        pass

print('server.cfg lines:',len(content.splitlines()))
print('FastDL blocks:',content.count('// HYPER-HOST FASTDL BEGIN'))
print('sv_downloadurl entries:',len(re.findall(r'(?im)^\s*sv_downloadurl\b',content)))
PY

echo "[3/8] Reinstall exact-IP nginx FastDL on port 80..."
for f in /etc/nginx/conf.d/*fastdl*8080*.conf; do
  [[ -e "$f" ]] || continue
  mv "$f" "$f.disabled.$STAMP"
done

cat >"$NGINX_CONF" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name 90.189.208.25;

    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-error.log warn;

    location ^~ /fastdl/ {
        root /srv/hyper-cs16;
        try_files $uri =404;
        default_type application/octet-stream;
        add_header Cache-Control "public, max-age=86400" always;
        add_header X-Hyper-FastDL "1" always;
    }

    location / {
        return 404;
    }
}
EOF
nginx -t
systemctl reload nginx

echo "[4/8] Validate source BSP..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); good=0; bad=[]
for p in sorted(root.glob('*.bsp')):
    try:
        with p.open('rb') as f: v=int.from_bytes(f.read(4),'little')
    except Exception: v=-1
    if v==30: good+=1
    else: bad.append((p.name,v))
print('valid BSP:',good)
print('bad BSP:',len(bad))
for x in bad: print('BAD',x)
if bad: raise SystemExit(20)
PY

echo "[5/8] Run full FastDL sync..."
"$LIVE" fastdl-sync "$SID"

echo "[6/8] Validate mirrored BSP..."
python3 - "$CSTRIKE/maps" "$FASTDL/maps" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2])
bad=[]; missing=[]
for p in sorted(src.glob('*.bsp')):
    q=dst/p.name
    if not q.is_file():
        missing.append(p.name); continue
    with q.open('rb') as f: v=int.from_bytes(f.read(4),'little')
    if v!=30: bad.append((p.name,v))
print('source BSP:',len(list(src.glob('*.bsp'))))
print('fastdl BSP:',len(list(dst.glob('*.bsp'))) if dst.exists() else 0)
print('missing:',len(missing))
print('bad mirror:',len(bad))
for x in missing[:20]: print('MISSING',x)
for x in bad[:20]: print('BAD',x)
if missing or bad: raise SystemExit(21)
PY

echo "[7/8] Verify real HTTP bytes using zm_303.bsp..."
TESTMAP="zm_303.bsp"
[[ -f "$FASTDL/maps/$TESTMAP" ]] || TESTMAP="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname '*.bsp' -printf '%f\n' | head -n1)"
rm -f /tmp/hh-fastdl-test.bsp
CODE="$(curl -sS --connect-timeout 3 --max-time 15 -H 'Host: 90.189.208.25' -o /tmp/hh-fastdl-test.bsp -w '%{http_code}' "http://127.0.0.1/fastdl/$SID/maps/$TESTMAP" || true)"
echo "HTTP code: $CODE"
echo "Probe map: $TESTMAP"
python3 - /tmp/hh-fastdl-test.bsp <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
b=p.read_bytes()[:4] if p.exists() else b''
print('head:',b.hex())
print('BSP version:',int.from_bytes(b,'little') if len(b)==4 else None)
if len(b)!=4 or int.from_bytes(b,'little')!=30: raise SystemExit(22)
PY
[[ "$CODE" == "200" ]] || { echo "[ERROR] nginx did not return HTTP 200"; exit 23; }
rm -f /tmp/hh-fastdl-test.bsp

echo "[8/8] Restart server + runtime check..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
"$LIVE" fastdl-status "$SID" || true
"$LIVE" rcon "$SID" "sv_downloadurl" || true
"$LIVE" rcon "$SID" "sv_allowdownload" || true

echo
echo "=============================================================="
echo " [SUCCESS] FASTDL FINAL v6.1 HOTFIX INSTALLED"
echo "=============================================================="
echo "URL: http://90.189.208.25/fastdl/$SID/"
echo "Backup: $BACKUP"
