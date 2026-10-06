#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "[ERROR] Run as root"
    exit 1
}

SID="${1:-25}"
PORT="${2:-8088}"

CTL="/usr/local/sbin/hyper-cs16-ctl"
SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"
FASTDL_ROOT="/srv/hyper-cs16/fastdl"

NGINX_CONF="/etc/nginx/conf.d/hyper-cs16-fastdl-dedicated.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-v36-$SID-$STAMP"
TMP="$(mktemp -d)"

trap 'rm -rf "$TMP"' EXIT

echo "================================================================"
echo " OLD ZOMBIE / HYPER-HOST FASTDL DEDICATED FIX v36"
echo " Server: #$SID"
echo " Port:   $PORT"
echo " Backup: $BACKUP"
echo "================================================================"

[[ "$SID" =~ ^[0-9]+$ ]] || exit 2
[[ "$PORT" =~ ^[0-9]+$ ]] || exit 2

[[ -d "$CSTRIKE" ]] || {
    echo "[ERROR] Missing $CSTRIKE"
    exit 2
}

mkdir -p "$BACKUP"

PUBLIC_IP="$(
python3 <<'PY'
import json
import re
import subprocess

try:
    d=json.load(open("/etc/hyper-cs16/runtime.json"))
    v=str(d.get("public_ip") or "").strip()

    if re.fullmatch(r"\d+\.\d+\.\d+\.\d+",v):
        print(v)
        raise SystemExit
except Exception:
    pass

try:
    out=subprocess.check_output(
        ["ip","-4","route","get","1.1.1.1"],
        text=True
    )

    m=re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)",out)

    if m:
        print(m.group(1))
except Exception:
    pass
PY
)"

[[ -n "$PUBLIC_IP" ]] || {
    echo "[ERROR] Cannot detect public IP"
    exit 3
}

echo
echo "[OK] Public IP: $PUBLIC_IP"


# ================================================================
# 1. BACKUP
# ================================================================

echo
echo "[1/9] Backup..."

[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/"
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/"


# ================================================================
# 2. REMOVE OLD EXPERIMENTAL FASTDL CONFIGS
# ================================================================

echo
echo "[2/9] Disable old experimental FastDL configs..."

for F in \
    /etc/nginx/conf.d/hyper-cs16-fastdl-binary.conf \
    /etc/nginx/conf.d/hyper-cs16-fastdl-binary.conf.disabled-v34
do

    if [[ -f "$F" ]]; then

        mv "$F" "$F.disabled-v36"

        echo "[OK] disabled $F"
    fi

done


# ================================================================
# 3. DEDICATED FASTDL NGINX
# ================================================================

echo
echo "[3/9] Create dedicated FastDL listener..."

cat > "$NGINX_CONF" <<EOF
# ================================================================
# HYPER-HOST CS 1.6 FASTDL v36
#
# Dedicated listener.
# NO PHP.
# NO panel.
# NO index.html fallback.
# ================================================================

server {

    listen ${PORT};
    listen [::]:${PORT};

    server_name _;

    access_log /var/log/nginx/hyper-cs16-fastdl-${PORT}-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-${PORT}-error.log warn;


    location ~* ^/fastdl/[0-9]+/.+\.(?:bsp|res|wad|mdl|spr|wav|mp3|tga|bmp|pcx|nav|txt|ztmp)(?:\.bz2)?\$ {

        root /srv/hyper-cs16;

        #
        # Existing file -> real binary.
        # Missing file  -> 404.
        #

        try_files \$uri =404;

        types { }
        default_type application/octet-stream;

        sendfile on;
        tcp_nopush on;

        gzip off;
        autoindex off;

        add_header X-Hyper-FastDL "dedicated-v36" always;
        add_header X-Content-Type-Options "nosniff" always;

        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }


    #
    # Any invalid /fastdl/ request must NEVER become HTML.
    #

    location /fastdl/ {

        default_type text/plain;

        add_header X-Hyper-FastDL "dedicated-v36-reject" always;

        return 404 "FastDL resource not found\n";
    }


    #
    # Nothing else is hosted here.
    #

    location / {

        default_type text/plain;

        return 404 "FastDL only\n";
    }
}
EOF


nginx -t

systemctl reload nginx


# ================================================================
# 4. VERIFY PORT IS LISTENING
# ================================================================

echo
echo "[4/9] Verify listener..."

if ! ss -lnt | grep -q ":${PORT}[[:space:]]"; then

    echo "[ERROR] nginx is not listening on port $PORT"

    ss -lntp | grep nginx || true

    exit 10
fi

echo "[OK] nginx listening on :$PORT"


# ================================================================
# 5. FIREWALL
# ================================================================

echo
echo "[5/9] Firewall..."

if command -v ufw >/dev/null 2>&1; then

    if ufw status 2>/dev/null | grep -qi '^Status: active'; then

        ufw allow "${PORT}/tcp" >/dev/null || true

        echo "[OK] UFW allow ${PORT}/tcp"

    else

        echo "[OK] UFW inactive"

    fi

else

    echo "[OK] UFW not installed"

fi


# ================================================================
# 6. SYNC FASTDL
# ================================================================

echo
echo "[6/9] Rebuild FastDL mirror..."

"$CTL" fastdl-sync "$SID" || true


# ================================================================
# 7. FORCE server.cfg
# ================================================================

echo
echo "[7/9] Set sv_downloadurl..."

python3 - \
    "$CSTRIKE/server.cfg" \
    "$PUBLIC_IP" \
    "$PORT" \
    "$SID" <<'PY'

from pathlib import Path
import re
import sys

p=Path(sys.argv[1])

ip=sys.argv[2]
port=sys.argv[3]
sid=sys.argv[4]

s=p.read_text(
    encoding="utf-8",
    errors="ignore"
) if p.exists() else ""

url=f"http://{ip}:{port}/fastdl/{sid}/"

managed={
    "sv_downloadurl",
    "sv_allowdownload",
    "sv_allowupload",
    "sv_send_resources",
    "sv_allow_dlfile",
}

out=[]

for line in s.splitlines():

    m=re.match(
        r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s+",
        line
    )

    if m and m.group(1).lower() in managed:
        continue

    out.append(line)


out += [
    "",
    "// HYPER-HOST FASTDL DEDICATED v36",
    "sv_allowdownload 1",
    "sv_allowupload 1",
    "sv_send_resources 1",
    "sv_allow_dlfile 1",
    f'sv_downloadurl "{url}"',
]


p.write_text(
    "\n".join(out).rstrip()+"\n",
    encoding="utf-8"
)

print("[OK]",url)
PY


# ================================================================
# 8. HTTP TESTS
# ================================================================

echo
echo "[8/9] Test FastDL HTTP..."


#
# Missing resource MUST be 404.
#

CODE="$(
curl \
    -sS \
    -D "$TMP/missing.headers" \
    -o "$TMP/missing.body" \
    -w '%{http_code}' \
    "http://127.0.0.1:${PORT}/fastdl/${SID}/__missing__.mdl"
)"

echo "Missing file HTTP: $CODE"

cat "$TMP/missing.headers"


if [[ "$CODE" != "404" ]]; then

    echo
    echo "[ERROR] missing file is NOT HTTP 404"

    head -c 500 "$TMP/missing.body" || true

    echo

    exit 20
fi


if grep -qiE \
    '<html|<!doctype|Домен не настроен' \
    "$TMP/missing.body"
then

    echo "[ERROR] HTML fallback detected"

    exit 21
fi


echo "[OK] missing resource -> HTTP 404"


verify_asset()
{
    local EXT="$1"

    local FILE

    FILE="$(
        find \
            "$FASTDL_ROOT/$SID" \
            -type f \
            -iname "*.$EXT" \
            -size +0c \
            2>/dev/null \
            | head -n1 \
            || true
    )"


    if [[ -z "$FILE" ]]; then

        echo "[SKIP] no .$EXT"

        return 0
    fi


    local REL="${FILE#"$FASTDL_ROOT/$SID/"}"

    local BODY="$TMP/$EXT.body"
    local HDR="$TMP/$EXT.headers"


    curl \
        -sS \
        --fail \
        -D "$HDR" \
        -o "$BODY" \
        "http://127.0.0.1:${PORT}/fastdl/${SID}/${REL}"


    if ! grep -qi \
        '^X-Hyper-FastDL: dedicated-v36' \
        "$HDR"
    then

        echo "[ERROR] .$EXT did not hit FastDL v36"

        cat "$HDR"

        exit 30
    fi


    DISK_HASH="$(
        sha256sum "$FILE" |
        awk '{print $1}'
    )"

    HTTP_HASH="$(
        sha256sum "$BODY" |
        awk '{print $1}'
    )"


    if [[ "$DISK_HASH" != "$HTTP_HASH" ]]; then

        echo "[ERROR] body mismatch: $REL"

        exit 31
    fi


    python3 - \
        "$BODY" \
        "$EXT" <<'PY'

from pathlib import Path
import sys

data=Path(
    sys.argv[1]
).read_bytes()

ext=sys.argv[2].lower()

head=data[:16]

low=data[:512].lstrip().lower()


if low.startswith(
    (
        b"<!doctype",
        b"<html",
        b"<head",
        b"<body",
        b"<?php",
    )
):

    raise SystemExit(
        "HTML detected"
    )


if ext=="bsp":

    if len(head)<4:
        raise SystemExit("BSP too short")

    version=int.from_bytes(
        head[:4],
        "little",
        signed=True
    )

    if version != 30:
        raise SystemExit(
            f"BSP version {version} != 30"
        )


elif ext=="mdl":

    if head[:4] not in (
        b"IDST",
        b"IDSQ",
    ):

        raise SystemExit(
            f"bad MDL header {head[:4]!r}"
        )


elif ext=="wav":

    if not (
        len(head)>=12
        and head[:4]==b"RIFF"
        and head[8:12]==b"WAVE"
    ):

        raise SystemExit(
            "bad WAV RIFF/WAVE"
        )


elif ext=="spr":

    if head[:4] != b"IDSP":

        raise SystemExit(
            f"bad SPR header {head[:4]!r}"
        )

PY


    echo "[OK] .$EXT binary: $REL"
}


verify_asset bsp
verify_asset mdl
verify_asset wav
verify_asset spr


echo
echo "--- EXACT OLD ZOMBIE FILES ---"


check_exact()
{
    local REL="$1"

    local FILE="$FASTDL_ROOT/$SID/$REL"

    if [[ ! -f "$FILE" ]]; then

        echo "[MISSING] $REL"

        return
    fi


    CODE="$(
        curl \
            -sS \
            -o "$TMP/exact.body" \
            -D "$TMP/exact.headers" \
            -w '%{http_code}' \
            "http://127.0.0.1:${PORT}/fastdl/${SID}/${REL}"
    )"


    if [[ "$CODE" != "200" ]]; then

        echo "[ERROR $CODE] $REL"

        exit 40
    fi


    D="$(
        sha256sum "$FILE" |
        awk '{print $1}'
    )"

    H="$(
        sha256sum "$TMP/exact.body" |
        awk '{print $1}'
    )"


    if [[ "$D" != "$H" ]]; then

        echo "[HASH ERROR] $REL"

        exit 41
    fi


    echo "[200 BINARY OK] $REL"
}


check_exact "maps/zm_ice_attack.bsp"
check_exact "maps/zm_ice_attack_hd.bsp"
check_exact "models/player/oldz_delux_r1/oldz_delux_r1.mdl"


# ================================================================
# 9. RESTART GAME SERVER
# ================================================================

echo
echo "[9/9] Restart CS 1.6 server..."

systemctl restart "hyper-cs16@${SID}.service"

sleep 3


echo
echo "--- LIVE CVARS ---"

"$CTL" rcon "$SID" "sv_downloadurl" || true
"$CTL" rcon "$SID" "sv_allowdownload" || true


echo
echo "--- PUBLIC-IP LOCAL TEST ---"

curl \
    -sS \
    -D - \
    -o /dev/null \
    "http://${PUBLIC_IP}:${PORT}/fastdl/${SID}/__missing_final__.mdl" \
    || true


echo
echo "================================================================"
echo " [SUCCESS] FASTDL DEDICATED v36"
echo "================================================================"
echo
echo "FastDL:"
echo " http://${PUBLIC_IP}:${PORT}/fastdl/${SID}/"
echo
echo "Nginx:"
echo " $NGINX_CONF"
echo
echo "Expected:"
echo " existing resource -> HTTP 200 binary"
echo " missing resource  -> HTTP 404"
echo " panel HTML        -> impossible"
echo
echo "================================================================"