#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS 1.6 FastDL v4.4
# Goals:
# - real HTTP FastDL on port 80
# - no silent slow HLDS fallback (sv_allow_dlfile 0)
# - gzip over HTTP for GoldSrc/Steam HTTP client
# - keep-alive + sendfile for many small resources
# - browsable /fastdl/<id>/ for diagnostics
# - apply cvars to runtime and restart target server so config is definitely active

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "[ERROR] Run as root/sudo" >&2
  exit 1
}

ROOT="${1:-/root/hyper-hosting-panel}"
SERVER_ID="${2:-25}"
SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
RUN_CTL="/usr/local/sbin/hyper-cs16-ctl"
RUNTIME="/etc/hyper-cs16/runtime.json"
NGINX_CONF="/etc/nginx/conf.d/hyper-cs16-fastdl-ip.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v44-backup-${STAMP}"

PUBLIC_IP="${CS16_PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" && -f "$RUNTIME" ]]; then
  PUBLIC_IP="$(python3 - "$RUNTIME" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
    print(str(d.get('public_ip') or '').strip())
except Exception:
    print('')
PY
)"
fi
if [[ -z "$PUBLIC_IP" ]]; then
  echo "[ERROR] public_ip is empty. Run with CS16_PUBLIC_IP=x.x.x.x" >&2
  exit 2
fi

echo "========== HYPER CS16 FASTDL v4.4 =========="
echo "[v4.4] Repo:      $ROOT"
echo "[v4.4] Server ID: $SERVER_ID"
echo "[v4.4] Public IP: $PUBLIC_IP"

[[ -f "$SRC_CTL" ]] || { echo "[ERROR] Missing $SRC_CTL" >&2; exit 3; }
[[ -f "$RUN_CTL" ]] || { echo "[ERROR] Missing $RUN_CTL" >&2; exit 3; }

mkdir -p "$BACKUP"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.source"
cp -a "$RUN_CTL" "$BACKUP/hyper-cs16-ctl.runtime"
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/" || true
echo "[v4.4] Backup: $BACKUP"

# Patch both repository source and installed runtime.
python3 - "$SRC_CTL" "$RUN_CTL" "$PUBLIC_IP" <<'PY'
from pathlib import Path
import re, sys

public_ip=sys.argv[3]

url_func = (
    "def _fastdl_url(c:dict)->str:\n"
    "    # GoldSrc FastDL: plain HTTP; trailing slash is intentional.\n"
    "    sid=int(c.get('id') or 0)\n"
    f"    return f'http://{public_ip}/fastdl/{{sid}}/'\n\n"
)

for name in sys.argv[1:3]:
    p=Path(name)
    s=p.read_text(encoding='utf-8')

    # Canonical URL.
    pattern=r'(?ms)^def _fastdl_url\(c:dict\)->str:\n.*?(?=^def _fastdl_apply_cfg\(c:dict,\s*root:Path\|None=None\)->dict:)'
    s,n=re.subn(pattern,url_func,s,count=1)
    if n != 1:
        raise SystemExit(f'[PATCH ERROR] _fastdl_url not found safely in {p}')

    # Managed server.cfg FastDL block:
    # upload is not needed; dlfile=0 blocks the slow game-socket fallback.
    s=s.replace("'sv_allowupload 1',", "'sv_allowupload 0',")
    s=s.replace("'sv_allow_dlfile 1',", "'sv_allow_dlfile 0',")

    # Runtime RCON application uses the same values.
    s=s.replace(
        "for cmd in ['sv_allowdownload 1','sv_allowupload 1','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl",
        "for cmd in ['sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 0',f'sv_downloadurl"
    )

    p.write_text(s,encoding='utf-8')
PY

python3 -m py_compile "$SRC_CTL"
python3 -m py_compile "$RUN_CTL"
chmod 0755 "$RUN_CTL"

# Remove obsolete dedicated 8088 config if still present.
rm -f /etc/nginx/conf.d/hyper-cs16-fastdl.conf

# Dedicated plain-HTTP vhost for the public IP.
# IMPORTANT: gzip is HTTP Content-Encoding, not ".bz2 file download".
cat > "$NGINX_CONF" <<EOF
# HYPER-HOST CS16 FastDL v4.4
server {
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_IP};

    access_log /var/log/nginx/hyper-cs16-fastdl-access.log combined;
    error_log  /var/log/nginx/hyper-cs16-fastdl-error.log warn;

    merge_slashes on;
    keepalive_timeout 65s;
    keepalive_requests 1000;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    open_file_cache max=20000 inactive=60s;
    open_file_cache_valid 120s;
    open_file_cache_min_uses 1;
    open_file_cache_errors on;

    # GoldSrc/Steam HTTP client advertises Accept-Encoding: gzip.
    gzip on;
    gzip_vary on;
    gzip_http_version 1.0;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_types *;

    location = /fastdl {
        return 301 /fastdl/;
    }

    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;

        # Diagnostic convenience: opening /fastdl/25/ in a browser shows files.
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;

        default_type application/octet-stream;

        limit_except GET HEAD {
            deny all;
        }

        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000" always;
        add_header X-Hyper-FastDL "v4.4" always;
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
echo "--- SYNC FASTDL SERVER #${SERVER_ID} ---"
SYNC_OUT="$("$RUN_CTL" fastdl-sync "$SERVER_ID")"
echo "$SYNC_OUT"

echo
echo "--- RESTART SERVER #${SERVER_ID} ---"
# Restart makes sure a stale in-memory sv_downloadurl cannot survive.
systemctl restart "hyper-cs16@${SERVER_ID}.service"
sleep 2

echo
echo "--- FASTDL STATUS ---"
"$RUN_CTL" fastdl-status "$SERVER_ID" || true

echo
echo "--- SERVER.CFG FASTDL BLOCK ---"
grep -nEi 'sv_downloadurl|sv_allowdownload|sv_allowupload|sv_send_resources|sv_allow_dlfile' \
  "/srv/hyper-cs16/servers/${SERVER_ID}/cstrike/server.cfg" || true

echo
echo "--- RUNTIME CVARS ---"
"$RUN_CTL" rcon "$SERVER_ID" "sv_downloadurl" || true
"$RUN_CTL" rcon "$SERVER_ID" "sv_allowdownload" || true
"$RUN_CTL" rcon "$SERVER_ID" "sv_allow_dlfile" || true
"$RUN_CTL" rcon "$SERVER_ID" "sv_allowupload" || true

echo
echo "--- DIRECTORY LISTING TEST ---"
DIR_STATUS="$(curl -sS -o /tmp/hyper-fastdl-index.$$ -w '%{http_code}' \
  -H "Host: ${PUBLIC_IP}" --max-time 10 \
  "http://127.0.0.1/fastdl/${SERVER_ID}/" || true)"
echo "HTTP /fastdl/${SERVER_ID}/ = $DIR_STATUS"
if [[ "$DIR_STATUS" == "200" ]]; then
  head -n 12 /tmp/hyper-fastdl-index.$$ || true
fi
rm -f /tmp/hyper-fastdl-index.$$

# Prefer the exact model from the reported slow client download.
TEST_REL="models/asimov/v_awp.mdl"
if [[ ! -f "/srv/hyper-cs16/fastdl/${SERVER_ID}/${TEST_REL}" ]]; then
  TEST_FILE="$(find "/srv/hyper-cs16/fastdl/${SERVER_ID}" -type f \
    \( -name '*.mdl' -o -name '*.bsp' -o -name '*.wav' -o -name '*.spr' -o -name '*.wad' \) \
    2>/dev/null | head -n 1 || true)"
  if [[ -n "$TEST_FILE" ]]; then
    TEST_REL="${TEST_FILE#/srv/hyper-cs16/fastdl/${SERVER_ID}/}"
  fi
fi

if [[ -z "${TEST_REL:-}" || ! -f "/srv/hyper-cs16/fastdl/${SERVER_ID}/${TEST_REL}" ]]; then
  echo "[ERROR] No downloadable FastDL resource found for server $SERVER_ID" >&2
  exit 4
fi

echo
echo "--- EXACT RESOURCE TEST ---"
echo "Resource: $TEST_REL"
echo "URL: http://${PUBLIC_IP}/fastdl/${SERVER_ID}/${TEST_REL}"

HEADER_FILE="/tmp/hyper-fastdl-headers.$$"
STATUS="$(curl -sS -D "$HEADER_FILE" -o /dev/null -w '%{http_code}' \
  -H "Host: ${PUBLIC_IP}" \
  -H "Accept-Encoding: gzip" \
  --max-time 15 \
  "http://127.0.0.1/fastdl/${SERVER_ID}/${TEST_REL}" || true)"
echo "HTTP status: $STATUS"
grep -iE '^(HTTP/|Content-Length:|Content-Encoding:|Connection:|X-Hyper-FastDL:|Cache-Control:)' "$HEADER_FILE" || true
GZIP_OK=0
grep -qi '^Content-Encoding: *gzip' "$HEADER_FILE" && GZIP_OK=1 || true
rm -f "$HEADER_FILE"

if [[ "$DIR_STATUS" != "200" || "$STATUS" != "200" ]]; then
  echo "[ERROR] FastDL HTTP verification failed." >&2
  echo "Run: nginx -T | grep -n -A45 -B5 'HYPER-HOST CS16 FastDL v4.4'" >&2
  exit 5
fi

echo
echo "--- RECENT FASTDL REQUESTS ---"
tail -n 10 /var/log/nginx/hyper-cs16-fastdl-access.log 2>/dev/null || true

echo
echo "========================================================"
echo "[DONE] FastDL v4.4 HTTP endpoint is working locally."
echo "Browse: http://${PUBLIC_IP}/fastdl/${SERVER_ID}/"
echo "File:   http://${PUBLIC_IP}/fastdl/${SERVER_ID}/${TEST_REL}"
echo "sv_downloadurl: http://${PUBLIC_IP}/fastdl/${SERVER_ID}/"
echo "sv_allow_dlfile: 0  (slow HLDS fallback disabled)"
if [[ "$GZIP_OK" -eq 1 ]]; then
  echo "HTTP gzip: ACTIVE"
else
  echo "HTTP gzip: response was 200, but this test response was not gzip encoded."
fi
echo
echo "PROOF WHILE A CLIENT CONNECTS:"
echo "  sudo tail -f /var/log/nginx/hyper-cs16-fastdl-access.log"
echo
echo "If the CS client is really using FastDL, every model/sound/map request"
echo "will appear in that log with HTTP 200. If no requests appear, the client"
echo "is not using sv_downloadurl and the runtime cvar/client state must be checked."
echo "========================================================"
