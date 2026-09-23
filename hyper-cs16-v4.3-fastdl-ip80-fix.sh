#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run as root/sudo" >&2; exit 1; }

ROOT="${1:-/root/hyper-hosting-panel}"
SERVER_ID="${2:-25}"
PUBLIC_IP="${CS16_PUBLIC_IP:-90.189.208.25}"

SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
RUN_CTL="/usr/local/sbin/hyper-cs16-ctl"
NGINX_CONF="/etc/nginx/conf.d/hyper-cs16-fastdl-ip.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v43-backup-${STAMP}"

echo "========== HYPER CS16 FASTDL v4.3 =========="
echo "[v4.3] Public IP: $PUBLIC_IP"
echo "[v4.3] Server ID: $SERVER_ID"

[[ -f "$SRC_CTL" ]] || { echo "[ERROR] Missing $SRC_CTL"; exit 2; }
[[ -f "$RUN_CTL" ]] || { echo "[ERROR] Missing $RUN_CTL"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.source"
cp -a "$RUN_CTL" "$BACKUP/hyper-cs16-ctl.runtime"
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/" || true

echo "[v4.3] Backup: $BACKUP"

# 1) Use plain HTTP + public IP for GoldSrc FastDL.
python3 - "$SRC_CTL" "$RUN_CTL" "$PUBLIC_IP" <<'PY'
from pathlib import Path
import re, sys

public_ip=sys.argv[3]
replacement = (
    "def _fastdl_url(c:dict)->str:\n"
    "    # GoldSrc-compatible FastDL: plain HTTP on the public IP, port 80.\n"
    "    sid=int(c.get('id') or 0)\n"
    f"    return f'http://{public_ip}/fastdl/{{sid}}'\n\n"
)

for name in sys.argv[1:3]:
    p=Path(name)
    s=p.read_text(encoding='utf-8')
    pattern=r'(?ms)^def _fastdl_url\(c:dict\)->str:\n.*?(?=^def _fastdl_apply_cfg\(c:dict,\s*root:Path\|None=None\)->dict:)'
    new,n=re.subn(pattern,replacement,s,count=1)
    if n != 1:
        raise SystemExit(f'[PATCH ERROR] _fastdl_url not found safely in {p}')
    p.write_text(new,encoding='utf-8')
PY

python3 -m py_compile "$SRC_CTL"
python3 -m py_compile "$RUN_CTL"
chmod 0755 "$RUN_CTL"

# 2) Dedicated IP vhost on port 80. This bypasses the panel domain HTTP->HTTPS redirect.
cat > "$NGINX_CONF" <<EOF
# HYPER-HOST CS16 FastDL v4.3
server {
    listen 80;
    listen [::]:80;

    server_name ${PUBLIC_IP};

    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-error.log warn;

    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;

        autoindex off;
        sendfile on;
        tcp_nopush on;
        gzip off;
        etag on;

        default_type application/octet-stream;

        limit_except GET HEAD {
            deny all;
        }

        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
    }

    location / {
        return 404;
    }
}
EOF

nginx -t
systemctl reload nginx
sleep 0.5

echo
echo "--- REBUILD SERVER #${SERVER_ID} FASTDL ---"
"$RUN_CTL" fastdl-sync "$SERVER_ID"

echo
echo "--- FASTDL STATUS ---"
"$RUN_CTL" fastdl-status "$SERVER_ID" || true

echo
echo "--- SERVER.CFG ---"
grep -nEi 'sv_downloadurl|sv_allowdownload|sv_send_resources|sv_allow_dlfile' \
  "/srv/hyper-cs16/servers/${SERVER_ID}/cstrike/server.cfg" || true

echo
echo "--- LOCAL HTTP TEST ---"
TEST_FILE="$(find "/srv/hyper-cs16/fastdl/${SERVER_ID}" -type f \
  \( -name '*.mdl.bz2' -o -name '*.bsp.bz2' -o -name '*.wav.bz2' -o -name '*.spr.bz2' -o -name '*.wad.bz2' \) \
  2>/dev/null | head -n 1 || true)"

if [[ -z "$TEST_FILE" ]]; then
  TEST_FILE="$(find "/srv/hyper-cs16/fastdl/${SERVER_ID}" -type f 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$TEST_FILE" ]]; then
    echo "[ERROR] No FastDL files found for server $SERVER_ID"
    exit 3
fi

REL="${TEST_FILE#/srv/hyper-cs16/fastdl/}"
URL="http://${PUBLIC_IP}/fastdl/${REL}"

echo "File: $TEST_FILE"
echo "Public URL: $URL"

STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Host: ${PUBLIC_IP}" \
  --max-time 10 \
  "http://127.0.0.1/fastdl/${REL}" || true)"

echo "Local nginx HTTP status: $STATUS"

if [[ "$STATUS" != "200" ]]; then
    echo "[ERROR] FastDL still does not return HTTP 200"
    echo
    echo "--- RESPONSE HEADERS ---"
    curl -I -H "Host: ${PUBLIC_IP}" --max-time 10 \
      "http://127.0.0.1/fastdl/${REL}" || true
    echo
    echo "--- NGINX FASTDL CONFIG ---"
    nginx -T 2>/dev/null | grep -n -A35 -B5 "HYPER-HOST CS16 FastDL v4.3" || true
    exit 4
fi

echo
echo "--- INTERNET-STYLE URL TEST FROM THIS HOST ---"
curl -I --max-time 10 "$URL" || true

echo
echo "=============================================="
echo "[DONE] FastDL v4.3 is configured."
echo "FastDL URL: http://${PUBLIC_IP}/fastdl/${SERVER_ID}"
echo
echo "IMPORTANT:"
echo "  1. TCP 80 must be forwarded by the router to this Ubuntu host."
echo "  2. Reconnect the CS client after this change."
echo "  3. If the game server cached the old cvar, restart/map-change server #${SERVER_ID}."
echo "=============================================="
