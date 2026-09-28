#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
PUBLIC_IP="${2:-90.189.208.25}"
FASTDL_ROOT="/srv/hyper-cs16/fastdl"
FASTDL="$FASTDL_ROOT/$SID"
PROBE="$FASTDL/maps/zm_2day.bsp"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/fastdl-ip-vhost-v20-$STAMP"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$PROBE" ]] || fail "missing probe BSP: $PROBE"

mkdir -p "$BACKUP"

echo "================================================================"
echo " FASTDL IP VHOST FIX v20"
echo " Server:  #$SID"
echo " IP:      $PUBLIC_IP"
echo " FastDL:  http://$PUBLIC_IP/fastdl/$SID/"
echo " Backup:  $BACKUP"
echo " Site:    old-zombie.ru WILL NOT BE MODIFIED"
echo "================================================================"

echo "[1/7] Inspect nginx include tree..."
nginx -T >"$BACKUP/nginx-T-before.txt" 2>&1

TARGET_DIR="$(python3 - "$BACKUP/nginx-T-before.txt" <<'PY'
from pathlib import Path
import os,re,sys
txt=Path(sys.argv[1]).read_text(encoding="utf-8",errors="ignore")
loaded=[]
for m in re.finditer(r'(?m)^# configuration file (.+):$',txt):
    p=Path(m.group(1))
    try:
        rp=p.resolve()
    except Exception:
        rp=p
    if rp.is_file():
        loaded.append(rp)
preferred=[
    Path("/etc/nginx/hyper-host-managed"),
    Path("/etc/nginx/sites-enabled"),
    Path("/etc/nginx/conf.d"),
]
for d in preferred:
    if not d.is_dir() or not os.access(d,os.W_OK):
        continue
    if any(str(p).startswith(str(d)+"/") for p in loaded):
        print(d)
        raise SystemExit
for p in loaded:
    d=p.parent
    if str(d).startswith("/etc/nginx") and d.is_dir() and os.access(d,os.W_OK) and p.name!="nginx.conf":
        print(d)
        raise SystemExit
raise SystemExit("cannot find writable loaded nginx include directory")
PY
)"

echo "loaded include directory: $TARGET_DIR"
CONF="$TARGET_DIR/00-hyper-fastdl-ip-$SID.conf"

if [[ -f "$CONF" ]]; then
    cp -a "$CONF" "$BACKUP/$(basename "$CONF").before"
fi

echo "[2/7] Install exact-IP FastDL vhost only..."
cat >"$CONF" <<EOF
# FASTDL IP VHOST FIX v20
# Separate from old-zombie.ru website.

server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;

    access_log /var/log/nginx/fastdl-$SID-access.log;
    error_log  /var/log/nginx/fastdl-$SID-error.log warn;

    location = /fastdl/$SID {
        return 301 /fastdl/$SID/;
    }

    location ^~ /fastdl/$SID/ {
        alias $FASTDL/;
        autoindex on;
        sendfile on;
        tcp_nopush on;
        types { }
        default_type application/octet-stream;
        add_header X-Hyper-FastDL "ip-v20" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "public, max-age=86400" always;
        limit_except GET HEAD { deny all; }
    }

    location / { return 404; }
}
EOF

echo "[3/7] Validate nginx config..."
nginx -t

echo "[4/7] Reload nginx..."
systemctl reload nginx
sleep 1

echo "[5/7] Confirm vhost is REALLY loaded..."
nginx -T >"$BACKUP/nginx-T-after.txt" 2>&1

grep -Fq "FASTDL IP VHOST FIX v20" "$BACKUP/nginx-T-after.txt" \
  || fail "created config is still NOT loaded by nginx: $CONF"

grep -Eq "server_name[[:space:]]+$PUBLIC_IP;" "$BACKUP/nginx-T-after.txt" \
  || fail "server_name $PUBLIC_IP is not present in loaded nginx config"

grep -Fq "/fastdl/$SID/" "$BACKUP/nginx-T-after.txt" \
  || fail "/fastdl/$SID/ location is not present in loaded nginx config"

echo "loaded: OK"

echo "[6/7] Test exact IP route locally..."
HDR="$BACKUP/probe.headers"
BODY="$BACKUP/probe.body"

curl -sS \
  -H "Host: $PUBLIC_IP" \
  -H "Range: bytes=0-3" \
  -D "$HDR" \
  -o "$BODY" \
  "http://127.0.0.1/fastdl/$SID/maps/zm_2day.bsp"

head -n 20 "$HDR"
HEX="$(xxd -l 4 -p "$BODY")"
echo "HTTP BSP head: $HEX"

grep -qi '^X-Hyper-FastDL: ip-v20' "$HDR" \
  || fail "request did not hit v20 FastDL vhost"

[[ "$HEX" == "1e000000" ]] \
  || fail "wrong BSP bytes: $HEX (expected 1e000000)"

echo "[7/7] Verify full BSP byte-for-byte..."
HTTP_FILE="$BACKUP/zm_2day.http.bsp"

curl -fsS \
  -H "Host: $PUBLIC_IP" \
  -o "$HTTP_FILE" \
  "http://127.0.0.1/fastdl/$SID/maps/zm_2day.bsp"

SRC_SHA="$(sha256sum "$PROBE" | awk '{print $1}')"
HTTP_SHA="$(sha256sum "$HTTP_FILE" | awk '{print $1}')"

echo "source sha256: $SRC_SHA"
echo "http   sha256: $HTTP_SHA"

[[ "$SRC_SHA" == "$HTTP_SHA" ]] \
  || fail "HTTP BSP differs from source BSP"

echo
echo "================================================================"
echo " [SUCCESS] FASTDL IP VHOST v20"
echo "================================================================"
echo " FastDL: http://$PUBLIC_IP/fastdl/$SID/"
echo " BSP head: $HEX"
echo " Config: $CONF"
echo " Site old-zombie.ru was NOT modified."
echo "================================================================"
