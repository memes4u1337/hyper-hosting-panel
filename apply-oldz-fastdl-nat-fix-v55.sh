#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
PUBLIC_IP="${2:-90.189.208.25}"

FASTDL="/srv/hyper-cs16/fastdl/$SID"
CS="/srv/hyper-cs16/servers/$SID/cstrike"
SERVER_CFG="$CS/server.cfg"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-v55-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
command -v nginx >/dev/null 2>&1 || fail "nginx not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
[[ -d "$FASTDL" ]] || fail "missing $FASTDL"
[[ -d "$CS" ]] || fail "missing $CS"

mkdir -p "$BACKUP/nginx"

echo "================================================================"
echo " OLD ZOMBIE FASTDL NAT FIX v55"
echo " Server: #$SID"
echo " Public IP / Host: $PUBLIC_IP"
echo " FastDL root: $FASTDL"
echo " Backup: $BACKUP"
echo "================================================================"

echo "[1/6] Locate nginx managed include..."
CONF_DIR="/etc/nginx/hyper-host-managed"
[[ -d "$CONF_DIR" ]] || CONF_DIR="/etc/nginx/conf.d"
[[ -d "$CONF_DIR" ]] || fail "managed nginx include directory not found"

TARGET="$CONF_DIR/00-oldz-fastdl-${SID}-FINAL-v55.conf"

echo "[2/6] Disable only previous OLDZ FastDL configs..."
shopt -s nullglob
for f in \
    "$CONF_DIR"/*oldz*fastdl*"$SID"*.conf \
    "$CONF_DIR"/00-oldz-fastdl-"$SID"-FINAL-v5*.conf
do
    [[ -f "$f" ]] || continue
    [[ "$f" == "$TARGET" ]] && continue

    base="$(basename "$f")"
    cp -a "$f" "$BACKUP/nginx/$base"
    mv "$f" "$f.disabled-v55-$STAMP"
    echo " disabled: $f"
done
shopt -u nullglob

echo "[3/6] Install NAT-safe FastDL vhost..."
cat > "$TARGET" <<EOF
server {
    # IMPORTANT:
    # Do NOT bind to public IP here.
    # The host is behind NAT, so nginx receives the request on a local address.
    # Match the external IP through the HTTP Host header instead.
    listen 80;
    server_name ${PUBLIC_IP};

    charset utf-8;

    location = / {
        add_header X-OLDZ-FastDL "server-${SID}-v55" always;
        return 302 /fastdl/${SID}/;
    }

    location = /fastdl/${SID} {
        add_header X-OLDZ-FastDL "server-${SID}-v55" always;
        return 301 /fastdl/${SID}/;
    }

    location ^~ /fastdl/${SID}/ {
        alias ${FASTDL}/;

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;

        sendfile on;
        tcp_nopush on;
        default_type application/octet-stream;

        add_header X-OLDZ-FastDL "server-${SID}-v55" always;
        add_header Cache-Control "public, max-age=300" always;
    }

    location / {
        add_header X-OLDZ-FastDL "server-${SID}-v55" always;
        return 404;
    }

    access_log /var/log/nginx/oldz-fastdl-${SID}.access.log;
    error_log  /var/log/nginx/oldz-fastdl-${SID}.error.log warn;
}
EOF

echo "[4/6] Validate + reload nginx..."
if ! nginx -t; then
    rm -f "$TARGET"
    fail "nginx -t failed; v55 config removed"
fi

systemctl reload nginx
ok "nginx reloaded"

echo "[5/6] Verify routing BOTH locally by Host and through public IP..."
HDR="/tmp/oldz-v55-hdr.$$"
BODY="/tmp/oldz-v55-body.$$"
trap 'rm -f "$HDR" "$BODY"' EXIT

# This is the decisive NAT-safe test:
# hit local nginx socket, but send the same Host header clients use.
curl -sS -D "$HDR" \
    -H "Host: ${PUBLIC_IP}" \
    "http://127.0.0.1/fastdl/${SID}/" \
    -o "$BODY" || fail "local Host-header test failed"

echo "--- LOCAL HOST TEST HEADERS ---"
cat "$HDR"

grep -qi "^X-OLDZ-FastDL: server-${SID}-v55" "$HDR" || {
    echo "--- BODY ---"
    head -n 40 "$BODY" || true
    fail "Host ${PUBLIC_IP} is still not routed to v55"
}

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "placeholder still returned in local Host test"
fi

ok "Host ${PUBLIC_IP} -> v55"

# Public/hairpin request should now match the same Host-based server.
curl -sS -D "$HDR" \
    "http://${PUBLIC_IP}/fastdl/${SID}/" \
    -o "$BODY" || fail "public FastDL request failed"

echo "--- PUBLIC IP TEST HEADERS ---"
cat "$HDR"

grep -qi "^X-OLDZ-FastDL: server-${SID}-v55" "$HDR" || {
    echo "--- BODY ---"
    head -n 40 "$BODY" || true
    fail "public request still not handled by v55"
}

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "public request still returns placeholder"
fi

ok "public IP request -> v55"
ok "HYPER-HOST placeholder bypassed"

# Directory listing.
grep -qiE 'Index of|<html|<pre' "$BODY" || {
    head -n 40 "$BODY" || true
    fail "FastDL directory listing is not visible"
}
ok "directory listing visible"

# Missing file must be clean 404 from v55.
MISS="__oldz_v55_missing_${RANDOM}.mdl"
CODE="$(curl -sS -D "$HDR" -o "$BODY" -w '%{http_code}' \
    "http://${PUBLIC_IP}/fastdl/${SID}/models/${MISS}" || true)"

[[ "$CODE" == "404" ]] || fail "missing resource expected 404, got $CODE"
grep -qi "^X-OLDZ-FastDL: server-${SID}-v55" "$HDR" || fail "404 not served by v55"

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "missing resource routed to placeholder"
fi

ok "missing files return real v55 404"

# Verify v3 model if present in FastDL.
MODEL="$FASTDL/models/oldz_knife_r7/v_gold_wolf_v3.mdl"
if [[ -f "$MODEL" ]]; then
    curl -fsS -D "$HDR" \
        "http://${PUBLIC_IP}/fastdl/${SID}/models/oldz_knife_r7/v_gold_wolf_v3.mdl" \
        -o "$BODY"

    grep -qi "^X-OLDZ-FastDL: server-${SID}-v55" "$HDR" || fail "v3 model not served by v55"

    MAGIC="$(dd if="$BODY" bs=1 count=4 status=none 2>/dev/null || true)"
    [[ "$MAGIC" == "IDST" ]] || {
        echo "First bytes:"
        xxd -l 32 "$BODY" || true
        fail "HTTP v_gold_wolf_v3.mdl is not RAW IDST"
    }

    ok "v_gold_wolf_v3.mdl HTTP = RAW IDST"
else
    echo "[INFO] v_gold_wolf_v3.mdl not present in FastDL, skipped"
fi

# Verify one map if available.
MAP="$(find "$FASTDL/maps" -maxdepth 1 -type f -name '*.bsp' 2>/dev/null | head -n1 || true)"
if [[ -n "$MAP" ]]; then
    NAME="$(basename "$MAP")"

    curl -fsS -D "$HDR" \
        "http://${PUBLIC_IP}/fastdl/${SID}/maps/${NAME}" \
        -o "$BODY"

    grep -qi "^X-OLDZ-FastDL: server-${SID}-v55" "$HDR" || fail "map not served by v55"

    VER="$(od -An -tu4 -N4 "$BODY" | tr -d '[:space:]')"
    [[ "$VER" == "30" ]] || {
        xxd -l 32 "$BODY" || true
        fail "HTTP map ${NAME} is not BSP version 30"
    }

    ok "map HTTP RAW BSP v30: ${NAME}"
else
    echo "[INFO] no maps in FastDL/maps; map test skipped"
fi

echo "[6/6] Normalize server.cfg FastDL URL..."
URL="http://${PUBLIC_IP}/fastdl/${SID}/"

cp -a "$SERVER_CFG" "$BACKUP/server.cfg.before" 2>/dev/null || true

python3 - "$SERVER_CFG" "$URL" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
url=sys.argv[2]

text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
out=[]

for line in text.splitlines():
    if re.match(r'^\s*sv_downloadurl\b',line,re.I):
        continue
    if re.match(r'^\s*sv_allowdownload\b',line,re.I):
        continue
    out.append(line)

out += [
    '',
    '// OLD ZOMBIE FASTDL NAT FIX v55',
    'sv_allowdownload 1',
    f'sv_downloadurl "{url}"',
]

p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print('sv_downloadurl =',url)
PY

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FASTDL NAT FIX v55"
echo "================================================================"
echo " Routing: listen 80 + server_name ${PUBLIC_IP}"
echo " FastDL: http://${PUBLIC_IP}/fastdl/${SID}/"
echo " Source: ${FASTDL}"
echo " Header: X-OLDZ-FastDL: server-${SID}-v55"
echo " Placeholder: BYPASSED"
echo " Directory listing: ON"
echo " Missing resources: REAL 404"
echo " No FastDL sync performed"
echo " Backup: $BACKUP"
echo "================================================================"
