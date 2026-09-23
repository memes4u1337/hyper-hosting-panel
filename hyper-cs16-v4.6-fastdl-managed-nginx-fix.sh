#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS 1.6 FastDL v4.6
# Real fix for this HYPER-HOST nginx layout:
# nginx loads /etc/nginx/hyper-host-managed/*.conf
# (NOT sites-enabled and NOT necessarily conf.d).

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "[ERROR] Run as root/sudo" >&2
  exit 1
}

ROOT="${1:-/root/hyper-hosting-panel}"
SERVER_ID="${2:-25}"

SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
RUN_CTL="/usr/local/sbin/hyper-cs16-ctl"
RUNTIME="/etc/hyper-cs16/runtime.json"
MANAGED_DIR="/etc/nginx/hyper-host-managed"
FASTDL_CONF="$MANAGED_DIR/00-hyper-cs16-fastdl.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v46-backup-${STAMP}"

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

[[ -n "$PUBLIC_IP" ]] || {
  echo "[ERROR] public_ip is empty. Example:"
  echo "CS16_PUBLIC_IP=90.189.208.25 sudo -E bash $0 $ROOT $SERVER_ID"
  exit 2
}

[[ -f "$SRC_CTL" ]] || { echo "[ERROR] Missing $SRC_CTL" >&2; exit 3; }
[[ -f "$RUN_CTL" ]] || { echo "[ERROR] Missing $RUN_CTL" >&2; exit 3; }

echo "========== HYPER CS16 FASTDL v4.6 =========="
echo "[v4.6] Repo:        $ROOT"
echo "[v4.6] Server ID:   $SERVER_ID"
echo "[v4.6] Public IP:   $PUBLIC_IP"
echo "[v4.6] Nginx path:  $MANAGED_DIR/*.conf"

mkdir -p "$BACKUP" "$MANAGED_DIR"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.source"
cp -a "$RUN_CTL" "$BACKUP/hyper-cs16-ctl.runtime"
[[ -f "$FASTDL_CONF" ]] && cp -a "$FASTDL_CONF" "$BACKUP/" || true

for f in \
  /etc/nginx/conf.d/hyper-cs16-fastdl.conf \
  /etc/nginx/conf.d/hyper-cs16-fastdl-ip.conf \
  /etc/nginx/sites-available/zz-hyper-cs16-fastdl-ip.conf \
  /etc/nginx/sites-enabled/zz-hyper-cs16-fastdl-ip.conf
do
  [[ -e "$f" ]] && cp -aL "$f" "$BACKUP/$(basename "$f").old" || true
done

echo "[v4.6] Backup: $BACKUP"

# Persist the correct FastDL URL + cvars in both repo source and installed runtime.
python3 - "$SRC_CTL" "$RUN_CTL" "$PUBLIC_IP" <<'PY'
from pathlib import Path
import re, sys

public_ip=sys.argv[3]

url_func = (
    "def _fastdl_url(c:dict)->str:\n"
    "    # GoldSrc FastDL: plain HTTP on port 80; trailing slash is intentional.\n"
    "    sid=int(c.get('id') or 0)\n"
    f"    return f'http://{public_ip}/fastdl/{{sid}}/'\n\n"
)

for name in sys.argv[1:3]:
    p=Path(name)
    s=p.read_text(encoding='utf-8')

    pattern=r'(?ms)^def _fastdl_url\(c:dict\)->str:\n.*?(?=^def _fastdl_apply_cfg\(c:dict,\s*root:Path\|None=None\)->dict:)'
    s,n=re.subn(pattern,url_func,s,count=1)
    if n != 1:
        raise SystemExit(f'[PATCH ERROR] _fastdl_url not found safely in {p}')

    s=s.replace("'sv_allowupload 1',", "'sv_allowupload 0',")
    s=s.replace("'sv_allow_dlfile 1',", "'sv_allow_dlfile 0',")
    s=s.replace(
        "for cmd in ['sv_allowdownload 1','sv_allowupload 1','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl",
        "for cmd in ['sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 0',f'sv_downloadurl"
    )

    p.write_text(s,encoding='utf-8')
PY

python3 -m py_compile "$SRC_CTL"
python3 -m py_compile "$RUN_CTL"
chmod 0755 "$RUN_CTL"

# Remove obsolete configs from paths nginx does not load here.
rm -f /etc/nginx/conf.d/hyper-cs16-fastdl.conf
rm -f /etc/nginx/conf.d/hyper-cs16-fastdl-ip.conf
rm -f /etc/nginx/sites-enabled/zz-hyper-cs16-fastdl-ip.conf
rm -f /etc/nginx/sites-available/zz-hyper-cs16-fastdl-ip.conf

# IMPORTANT:
# The user's nginx -T explicitly shows:
# include /etc/nginx/hyper-host-managed/*.conf;
# So FastDL must live here.
cat > "$FASTDL_CONF" <<EOF
# HYPER-HOST CS16 FastDL v4.6
server {
    listen 80;
    listen [::]:80;

    server_name ${PUBLIC_IP};

    access_log /var/log/nginx/hyper-cs16-fastdl-access.log combined;
    error_log  /var/log/nginx/hyper-cs16-fastdl-error.log warn;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    keepalive_timeout 65s;
    keepalive_requests 2000;

    open_file_cache max=20000 inactive=60s;
    open_file_cache_valid 120s;
    open_file_cache_min_uses 1;
    open_file_cache_errors on;

    # HTTP gzip is optional acceleration. The raw resource remains available.
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

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;

        default_type application/octet-stream;

        limit_except GET HEAD {
            deny all;
        }

        add_header X-Hyper-FastDL "v4.6" always;
        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000" always;
    }

    location / {
        default_type text/plain;
        return 404 "HYPER-HOST CS16 FastDL v4.6\n";
    }
}
EOF

chmod 0644 "$FASTDL_CONF"

echo
echo "--- VERIFY MANAGED INCLUDE ---"
if ! nginx -T 2>&1 | grep -Fq 'include /etc/nginx/hyper-host-managed/*.conf;'; then
  echo "[ERROR] nginx no longer includes $MANAGED_DIR/*.conf" >&2
  exit 4
fi

nginx -t

if ! nginx -T 2>&1 | grep -Fq 'HYPER-HOST CS16 FastDL v4.6'; then
  echo "[ERROR] nginx does not load $FASTDL_CONF" >&2
  exit 5
fi

systemctl reload nginx
sleep 1
echo "[OK] nginx loaded $FASTDL_CONF"

# Ensure nginx can traverse/read the mirror.
chmod 0755 /srv/hyper-cs16 2>/dev/null || true
chmod 0755 /srv/hyper-cs16/fastdl 2>/dev/null || true
chmod 0755 "/srv/hyper-cs16/fastdl/${SERVER_ID}" 2>/dev/null || true
find "/srv/hyper-cs16/fastdl/${SERVER_ID}" -type d -exec chmod 0755 {} + 2>/dev/null || true
find "/srv/hyper-cs16/fastdl/${SERVER_ID}" -type f -exec chmod 0644 {} + 2>/dev/null || true

echo
echo "--- SYNC SERVER #${SERVER_ID} ---"
"$RUN_CTL" fastdl-sync "$SERVER_ID"

echo
echo "--- RESTART SERVER #${SERVER_ID} ---"
systemctl restart "hyper-cs16@${SERVER_ID}.service"
sleep 2

echo
echo "--- FASTDL STATUS ---"
"$RUN_CTL" fastdl-status "$SERVER_ID" || true

echo
echo "--- SERVER.CFG ---"
grep -nEi 'sv_downloadurl|sv_allowdownload|sv_allowupload|sv_send_resources|sv_allow_dlfile' \
  "/srv/hyper-cs16/servers/${SERVER_ID}/cstrike/server.cfg" || true

echo
echo "--- RUNTIME CVARS ---"
"$RUN_CTL" rcon "$SERVER_ID" "sv_downloadurl" || true
"$RUN_CTL" rcon "$SERVER_ID" "sv_allowdownload" || true
"$RUN_CTL" rcon "$SERVER_ID" "sv_allow_dlfile" || true
"$RUN_CTL" rcon "$SERVER_ID" "sv_allowupload" || true

TEST_REL="models/asimov/v_awp.mdl"
REAL="/srv/hyper-cs16/fastdl/${SERVER_ID}/${TEST_REL}"

if [[ ! -f "$REAL" ]]; then
  REAL="$(find "/srv/hyper-cs16/fastdl/${SERVER_ID}" -type f \
    \( -name '*.mdl' -o -name '*.bsp' -o -name '*.wav' -o -name '*.spr' -o -name '*.wad' \) \
    2>/dev/null | head -n 1 || true)"
  [[ -n "$REAL" ]] || {
    echo "[ERROR] No FastDL resource found for verification" >&2
    exit 6
  }
  TEST_REL="${REAL#/srv/hyper-cs16/fastdl/${SERVER_ID}/}"
fi

TMP_BODY="/tmp/hyper-fastdl-v46-body.$$"
TMP_HEAD="/tmp/hyper-fastdl-v46-head.$$"
trap 'rm -f "$TMP_BODY" "$TMP_HEAD"' EXIT

echo
echo "--- DIRECTORY ROUTING TEST ---"
DIR_CODE="$(curl -sS -D "$TMP_HEAD" -o "$TMP_BODY" -w '%{http_code}' \
  -H "Host: ${PUBLIC_IP}" \
  --max-time 10 \
  "http://127.0.0.1/fastdl/${SERVER_ID}/" || true)"

echo "HTTP: $DIR_CODE"
grep -iE '^(HTTP/|Content-Type:|Content-Length:|X-Hyper-FastDL:)' "$TMP_HEAD" || true

if [[ "$DIR_CODE" != "200" ]] || ! grep -qi '^X-Hyper-FastDL: *v4\.6' "$TMP_HEAD"; then
  echo "[ERROR] Request is still hitting another HYPER-HOST vhost." >&2
  echo "--- RESPONSE BODY ---" >&2
  head -c 600 "$TMP_BODY" >&2 || true
  echo >&2
  echo "--- ACTIVE SERVER BLOCKS FOR PORT 80 ---" >&2
  nginx -T 2>/dev/null | grep -nE 'listen .*80|server_name|HYPER-HOST CS16 FastDL' >&2 || true
  exit 7
fi

echo "[OK] /fastdl/${SERVER_ID}/ is handled by FastDL v4.6"

echo
echo "--- REAL FILE SHA256 VERIFICATION ---"
rm -f "$TMP_BODY" "$TMP_HEAD"

HTTP_CODE="$(curl -sS -D "$TMP_HEAD" -o "$TMP_BODY" -w '%{http_code}' \
  -H "Host: ${PUBLIC_IP}" \
  --max-time 60 \
  "http://127.0.0.1/fastdl/${SERVER_ID}/${TEST_REL}" || true)"

REAL_SHA="$(sha256sum "$REAL" | awk '{print $1}')"
HTTP_SHA="$(sha256sum "$TMP_BODY" | awk '{print $1}')"
REAL_SIZE="$(stat -c '%s' "$REAL")"
HTTP_SIZE="$(stat -c '%s' "$TMP_BODY")"

echo "Resource:   $TEST_REL"
echo "HTTP:       $HTTP_CODE"
echo "Real size:  $REAL_SIZE"
echo "HTTP size:  $HTTP_SIZE"
echo "Real SHA:   $REAL_SHA"
echo "HTTP SHA:   $HTTP_SHA"
grep -iE '^(HTTP/|Content-Type:|Content-Length:|X-Hyper-FastDL:|Cache-Control:)' "$TMP_HEAD" || true

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "[ERROR] FastDL resource is not HTTP 200" >&2
  exit 8
fi

if ! grep -qi '^X-Hyper-FastDL: *v4\.6' "$TMP_HEAD"; then
  echo "[ERROR] Missing X-Hyper-FastDL v4.6 header" >&2
  exit 9
fi

if [[ "$REAL_SIZE" != "$HTTP_SIZE" || "$REAL_SHA" != "$HTTP_SHA" ]]; then
  echo "[ERROR] nginx response is not the real game file" >&2
  echo "--- FIRST 64 BYTES ---" >&2
  xxd -l 64 "$TMP_BODY" >&2 || true
  exit 10
fi

echo "[OK] HTTP file is byte-for-byte identical to source"

echo
echo "--- GZIP TEST ---"
rm -f "$TMP_HEAD"
GZIP_CODE="$(curl -sS -D "$TMP_HEAD" -o /dev/null -w '%{http_code}' \
  -H "Host: ${PUBLIC_IP}" \
  -H "Accept-Encoding: gzip" \
  --max-time 60 \
  "http://127.0.0.1/fastdl/${SERVER_ID}/${TEST_REL}" || true)"

echo "HTTP: $GZIP_CODE"
grep -iE '^(HTTP/|Content-Encoding:|Vary:|X-Hyper-FastDL:)' "$TMP_HEAD" || true

echo
echo "--- RECENT FASTDL ACCESS LOG ---"
tail -n 15 /var/log/nginx/hyper-cs16-fastdl-access.log 2>/dev/null || true

echo
echo "============================================================"
echo "[SUCCESS] FASTDL v4.6 VERIFIED"
echo "Config loaded from:"
echo "  $FASTDL_CONF"
echo
echo "Browse:"
echo "  http://${PUBLIC_IP}/fastdl/${SERVER_ID}/"
echo
echo "Verified resource:"
echo "  http://${PUBLIC_IP}/fastdl/${SERVER_ID}/${TEST_REL}"
echo
echo "sv_downloadurl:"
echo "  http://${PUBLIC_IP}/fastdl/${SERVER_ID}/"
echo
echo "Client proof:"
echo "  sudo tail -f /var/log/nginx/hyper-cs16-fastdl-access.log"
echo "============================================================"
