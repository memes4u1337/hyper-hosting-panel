#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
IP="${2:-90.189.208.25}"

FASTDL="/srv/hyper-cs16/fastdl/$SID"
CS="/srv/hyper-cs16/servers/$SID/cstrike"
SERVER_CFG="$CS/server.cfg"
CTL="/usr/local/sbin/hyper-cs16-ctl"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-final-v51-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
command -v nginx >/dev/null 2>&1 || fail "nginx not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
[[ -d "$FASTDL" ]] || fail "missing FastDL root: $FASTDL"
[[ -d "$CS" ]] || fail "missing cstrike: $CS"

mkdir -p "$BACKUP"

echo "================================================================"
echo " OLD ZOMBIE FASTDL FINAL v51"
echo " Server: #$SID"
echo " IP: $IP"
echo " FastDL root: $FASTDL"
echo " cstrike: $CS"
echo " Backup: $BACKUP"
echo " NO FILE SYNC / NO FILE RESTORE"
echo "================================================================"

echo "[1/7] Detect loaded nginx include directory..."
CONF_DIR=""

if nginx -T 2>&1 | grep -qE 'include[[:space:]]+/etc/nginx/hyper-host-managed/\*\.conf'; then
    CONF_DIR="/etc/nginx/hyper-host-managed"
elif nginx -T 2>&1 | grep -qE 'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf'; then
    CONF_DIR="/etc/nginx/conf.d"
else
    # Fallback to known panel directory if it exists.
    if [[ -d /etc/nginx/hyper-host-managed ]]; then
        CONF_DIR="/etc/nginx/hyper-host-managed"
    elif [[ -d /etc/nginx/conf.d ]]; then
        CONF_DIR="/etc/nginx/conf.d"
    else
        fail "cannot find nginx include directory"
    fi
fi

ok "nginx include dir: $CONF_DIR"

echo "[2/7] Disable OLD conflicting FastDL IP vhosts only..."
mkdir -p "$BACKUP/nginx"

shopt -s nullglob
for f in \
    "$CONF_DIR"/*oldz*fastdl*"$SID"*.conf \
    "$CONF_DIR"/05-oldz-fastdl-ip-"$SID".conf \
    "$CONF_DIR"/05-oldz-fastdl*"$SID"*.conf
do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    cp -a "$f" "$BACKUP/nginx/$base"
    mv "$f" "$f.disabled-v51-$STAMP"
    echo " disabled: $f"
done
shopt -u nullglob

echo "[3/7] Install exact IP FastDL vhost using REAL FastDL directory..."
CONF="$CONF_DIR/04-oldz-fastdl-${SID}-final.conf"

cat > "$CONF" <<EOF
server {
    listen 80;
    server_name ${IP};

    charset utf-8;

    # Visiting the bare IP opens this server's FastDL browser.
    location = / {
        return 302 /fastdl/${SID}/;
    }

    location = /fastdl/${SID} {
        return 301 /fastdl/${SID}/;
    }

    # IMPORTANT:
    # Serve ONLY the real panel FastDL tree.
    # Deleting a file from /srv/hyper-cs16/fastdl/${SID}
    # immediately makes it unavailable over HTTP.
    location ^~ /fastdl/${SID}/ {
        alias ${FASTDL}/;

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;

        sendfile on;
        tcp_nopush on;

        default_type application/octet-stream;

        # Missing game resources must be a real 404.
        # Never pass them to the website/PHP "domain not configured" page.
        try_files \$uri =404;

        add_header X-OLDZ-FastDL "server-${SID}-v51" always;
        add_header Cache-Control "public, max-age=300" always;
    }

    # Nothing else is hosted on the FastDL IP vhost.
    location / {
        return 404;
    }

    access_log /var/log/nginx/oldz-fastdl-${SID}.access.log;
    error_log  /var/log/nginx/oldz-fastdl-${SID}.error.log warn;
}
EOF

cp -a "$CONF" "$BACKUP/$(basename "$CONF").installed"

echo "[4/7] Validate nginx BEFORE reload..."
if ! nginx -t; then
    rm -f "$CONF"

    # Restore old files if validation failed.
    for b in "$BACKUP/nginx"/*.conf; do
        [[ -f "$b" ]] || continue
        name="$(basename "$b")"
        cp -a "$b" "$CONF_DIR/$name"
    done

    fail "nginx -t failed; old config restored"
fi

ok "nginx syntax OK"
systemctl reload nginx
ok "nginx reloaded"

echo "[5/7] Force server to use canonical FastDL URL..."
URL="http://${IP}/fastdl/${SID}/"

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
    '// OLD ZOMBIE FASTDL FINAL v51',
    'sv_allowdownload 1',
    f'sv_downloadurl "{url}"',
]

p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print('server.cfg:',url)
PY

echo "[6/7] Verify HTTP behavior..."
HDR="/tmp/oldz-v51-hdr.$$"
BODY="/tmp/oldz-v51-body.$$"
trap 'rm -f "$HDR" "$BODY"' EXIT

# 1. /fastdl/25 -> slash redirect
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "http://${IP}/fastdl/${SID}" || true)"
[[ "$CODE" == "301" ]] || fail "/fastdl/$SID expected 301, got $CODE"
ok "/fastdl/$SID redirects correctly"

# 2. Directory listing must be visible.
curl -fsS -D "$HDR" "http://${IP}/fastdl/${SID}/" -o "$BODY" || {
    cat "$HDR" || true
    fail "FastDL directory listing request failed"
}

grep -qiE '<html|<pre|Index of' "$BODY" || {
    echo "--- BODY START ---"
    head -n 40 "$BODY" || true
    fail "FastDL root is not a directory listing"
}

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "request still reaches HYPER-HOST domain placeholder"
fi

ok "FastDL browser listing visible"
ok "\"Домен не настроен\" is gone from FastDL IP route"

# 3. Missing file must return a clean 404, not HTML site fallback.
MISS="__oldz_v51_missing_$(date +%s).mdl"
CODE="$(curl -sS -o "$BODY" -w '%{http_code}' "http://${IP}/fastdl/${SID}/models/${MISS}" || true)"
[[ "$CODE" == "404" ]] || fail "missing asset expected HTTP 404, got $CODE"

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "missing asset is still routed to website placeholder"
fi
ok "missing FastDL files return real 404"

# 4. If current gold wolf v3 exists in FastDL, verify it is RAW.
MODEL="$FASTDL/models/oldz_knife_r7/v_gold_wolf_v3.mdl"
if [[ -f "$MODEL" ]]; then
    curl -fsS "http://${IP}/fastdl/${SID}/models/oldz_knife_r7/v_gold_wolf_v3.mdl" -o "$BODY"
    MAGIC="$(dd if="$BODY" bs=1 count=4 status=none 2>/dev/null || true)"
    [[ "$MAGIC" == "IDST" ]] || {
        xxd -l 32 "$BODY" || true
        fail "v_gold_wolf_v3.mdl HTTP response is not RAW IDST"
    }
    ok "v_gold_wolf_v3.mdl HTTP = RAW IDST"
else
    echo "[INFO] v_gold_wolf_v3.mdl is not present in FastDL tree; skipped model HTTP test"
fi

# 5. Check a map if one exists in FastDL.
MAP="$(find "$FASTDL/maps" -maxdepth 1 -type f -name '*.bsp' 2>/dev/null | head -n1 || true)"
if [[ -n "$MAP" ]]; then
    NAME="$(basename "$MAP")"
    curl -fsS "http://${IP}/fastdl/${SID}/maps/$NAME" -o "$BODY"
    VER="$(od -An -tu4 -N4 "$BODY" | tr -d '[:space:]')"
    [[ "$VER" == "30" ]] || {
        xxd -l 32 "$BODY" || true
        fail "HTTP map $NAME is not BSP v30"
    }
    ok "map HTTP RAW BSP v30: $NAME"
else
    echo "[INFO] no BSP files currently present in FastDL/maps; skipped map raw test"
fi

echo "[7/7] Restart server once and verify status..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service" || true

OK=0
STATUS=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    STATUS="$("$CTL" status "$SID" 2>/dev/null || true)"
    if echo "$STATUS" | grep -q '"running":true' \
       && echo "$STATUS" | grep -q '"udp_listening":true' \
       && echo "$STATUS" | grep -q '"query_ok":true'; then
        OK=1
        break
    fi
done

echo "$STATUS"
[[ "$OK" -eq 1 ]] || fail "server did not become PROCESS+UDP+A2S ready"

echo "--- sv_downloadurl ---"
"$CTL" rcon "$SID" "sv_downloadurl" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FASTDL FINAL v51"
echo "================================================================"
echo " FastDL source: $FASTDL"
echo " Browse: http://${IP}/fastdl/${SID}/"
echo " Bare IP redirects to FastDL browser"
echo " Missing assets: HTTP 404"
echo " Website placeholder: NOT USED for FastDL"
echo " NO FILES WERE SYNCED OR RESTORED"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " Backup: $BACKUP"
echo "================================================================"
