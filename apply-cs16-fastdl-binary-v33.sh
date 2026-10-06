#!/usr/bin/env bash
set -Eeuo pipefail

# ================================================================
# HYPER-HOST CS 1.6 FASTDL BINARY HARD FIX v33
#
# Fixes:
#  - FastDL NEVER falls through to panel/index.php/index.html
#  - only CS 1.6 downloadable binary resources are exposed
#  - missing resources return HTTP 404
#  - sv_downloadurl gets canonical trailing /
#  - works for ALL server IDs: /fastdl/<SID>/
#  - verifies BSP / MDL / WAV / SPR signatures over HTTP
#  - checks exact OLD ZOMBIE problem resources
# ================================================================

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "[ERROR] Run with sudo/root"
    exit 1
}

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"

SERVER="/srv/hyper-cs16/servers/${SID}"
CSTRIKE="${SERVER}/cstrike"

CTL="/usr/local/sbin/hyper-cs16-ctl"
SRC_CTL="${REPO}/cs16-panel/bin/hyper-cs16-ctl"

FASTDL_ROOT="/srv/hyper-cs16/fastdl"
NGINX_CONF="/etc/nginx/conf.d/hyper-cs16-fastdl-binary.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v33-${SID}-${STAMP}"
REPORT="/root/hyper-cs16-fastdl-v33-${SID}-${STAMP}.log"

exec > >(tee -a "$REPORT") 2>&1

echo "================================================================"
echo " HYPER-HOST CS 1.6 FASTDL BINARY HARD FIX v33"
echo " Server: #${SID}"
echo " Backup: ${BACKUP}"
echo "================================================================"

[[ "$SID" =~ ^[0-9]+$ ]] || {
    echo "[ERROR] Invalid SID: $SID"
    exit 2
}

[[ -d "$CSTRIKE" ]] || {
    echo "[ERROR] Missing $CSTRIKE"
    exit 2
}

[[ -f "$CTL" ]] || {
    echo "[ERROR] Missing $CTL"
    exit 2
}

command -v nginx >/dev/null || {
    echo "[ERROR] nginx not installed"
    exit 2
}

command -v curl >/dev/null || {
    echo "[ERROR] curl not installed"
    exit 2
}

command -v python3 >/dev/null || {
    echo "[ERROR] python3 not installed"
    exit 2
}

mkdir -p "$BACKUP"

backup_one()
{
    local F="$1"

    [[ -e "$F" ]] || return 0

    local REL="${F#/}"

    mkdir -p "$BACKUP/$(dirname "$REL")"
    cp -a "$F" "$BACKUP/$REL"
}


# ================================================================
# 1. DETECT PUBLIC IP
# ================================================================

echo
echo "[1/8] Detect public IPv4..."

PUBLIC_IP="$(
python3 <<'PY'
import json
import ipaddress
import subprocess
import re

from pathlib import Path

candidates=[]

try:
    p=Path("/etc/hyper-cs16/runtime.json")

    if p.exists():
        d=json.loads(p.read_text())

        candidates += [
            d.get("public_ip", ""),
            d.get("host_ip", ""),
        ]
except Exception:
    pass

for value in candidates:
    try:
        ip=ipaddress.ip_address(str(value).strip())

        if (
            ip.version == 4
            and not ip.is_loopback
            and not ip.is_unspecified
        ):
            print(ip)
            raise SystemExit
    except Exception:
        pass

try:
    out=subprocess.check_output(
        ["ip", "-4", "route", "get", "1.1.1.1"],
        text=True,
        stderr=subprocess.DEVNULL,
    )

    m=re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)", out)

    if m:
        print(m.group(1))
except Exception:
    pass
PY
)"

if [[ -z "$PUBLIC_IP" ]]; then
    echo "[ERROR] Public IPv4 not detected"
    echo "Set public_ip in /etc/hyper-cs16/runtime.json"
    exit 3
fi

echo "[OK] Public IP: $PUBLIC_IP"


# ================================================================
# 2. BACKUP
# ================================================================

echo
echo "[2/8] Backup..."

backup_one "$CTL"
backup_one "$SRC_CTL"
backup_one "$CSTRIKE/server.cfg"
backup_one "$NGINX_CONF"


# ================================================================
# 3. NGINX
# ================================================================

echo
echo "[3/8] Install dedicated binary FastDL nginx vhost..."

cat > "$NGINX_CONF" <<EOF
# ================================================================
# HYPER-HOST CS 1.6 FASTDL
# Binary-only FastDL v33
# ================================================================

server {

    listen 80;
    listen [::]:80;

    server_name ${PUBLIC_IP};

    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-error.log warn;


    # ------------------------------------------------------------
    # REAL CS 1.6 RESOURCES ONLY
    #
    # Example:
    #
    # URL:
    # /fastdl/25/maps/zm_ice_attack.bsp
    #
    # FILE:
    # /srv/hyper-cs16/fastdl/25/maps/zm_ice_attack.bsp
    # ------------------------------------------------------------

    location ~* ^/fastdl/[0-9]+/.+\.(?:bsp|res|wad|mdl|spr|wav|mp3|tga|bmp|pcx|nav|txt|ztmp)(?:\.bz2)?$ {

        root /srv/hyper-cs16;

        # CRITICAL:
        # nonexistent file = 404
        # NEVER index.php
        # NEVER index.html
        try_files \$uri =404;

        types { }
        default_type application/octet-stream;

        sendfile on;
        tcp_nopush on;

        gzip off;
        autoindex off;

        add_header X-Hyper-FastDL "binary-v33" always;
        add_header X-Content-Type-Options "nosniff" always;

        # Do not let an intermediary keep an old broken HTML response.
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }


    # ------------------------------------------------------------
    # BLOCK EVERYTHING ELSE INSIDE /fastdl/
    # ------------------------------------------------------------

    location /fastdl/ {

        default_type text/plain;

        return 404 "FastDL resource not found\n";
    }


    # ------------------------------------------------------------
    # THIS IP VHOST IS NOT THE PANEL
    # ------------------------------------------------------------

    location / {

        default_type text/plain;

        return 404 "Not Found\n";
    }
}
EOF


echo "--- nginx test ---"

nginx -t

echo "--- nginx reload ---"

systemctl reload nginx


# ================================================================
# 4. PATCH HYPER-CS16 CONTROLLER
# ================================================================

echo
echo "[4/8] Patch controller FastDL URL..."

patch_controller()
{
    local FILE="$1"

    [[ -f "$FILE" ]] || return 0

    python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])

s=p.read_text(
    encoding="utf-8"
)

old1="return f'http://{public}/fastdl/{sid}'"
new1="return f'http://{public}/fastdl/{sid}/'"

old2="return f'https://{FASTDL_DOMAIN}/fastdl/{sid}'"
new2="return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'"

if old1 in s:
    s=s.replace(
        old1,
        new1
    )

if old2 in s:
    s=s.replace(
        old2,
        new2
    )

p.write_text(
    s,
    encoding="utf-8"
)

print("[OK]", p)
PY

    python3 -m py_compile "$FILE"
}


patch_controller "$SRC_CTL"
patch_controller "$CTL"

chmod 0755 "$CTL"


# ================================================================
# 5. REBUILD FASTDL
# ================================================================

echo
echo "[5/8] Rebuild FastDL..."

SYNC_JSON="$("$CTL" fastdl-sync "$SID")"

echo "$SYNC_JSON"


# ================================================================
# 6. FORCE FINAL SERVER.CFG
# ================================================================

echo
echo "[6/8] Fix server.cfg FastDL block..."

python3 - \
    "$CSTRIKE/server.cfg" \
    "$PUBLIC_IP" \
    "$SID" <<'PY'

from pathlib import Path
import re
import sys

p=Path(sys.argv[1])

ip=sys.argv[2]
sid=sys.argv[3]

if p.exists():
    s=p.read_text(
        encoding="utf-8",
        errors="ignore"
    )
else:
    s=""

s=s.replace(
    "\r\n",
    "\n"
).replace(
    "\r",
    "\n"
)

begin="// HYPER-HOST FASTDL BEGIN"
end="// HYPER-HOST FASTDL END"

s=re.sub(
    r"(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$"
    r".*?"
    r"^\s*// HYPER-HOST FASTDL END\s*$\n?",
    "",
    s,
)

managed={
    "sv_downloadurl",
    "sv_allowdownload",
    "sv_allowupload",
    "sv_send_resources",
    "sv_allow_dlfile",
}

kept=[]

for line in s.splitlines():

    m=re.match(
        r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s+",
        line
    )

    if m and m.group(1).lower() in managed:
        continue

    kept.append(line)


block=[
    begin,

    "// Managed automatically by HYPER-HOST FastDL binary v33.",

    "sv_allowdownload 1",

    "sv_allowupload 1",

    "sv_send_resources 1",

    "sv_allow_dlfile 1",

    f'sv_downloadurl "http://{ip}/fastdl/{sid}/"',

    end,
]


new_content=(
    "\n".join(kept).rstrip()
    + "\n\n"
    + "\n".join(block)
    + "\n"
)

p.write_text(
    new_content,
    encoding="utf-8"
)

print(
    "sv_downloadurl =",
    f"http://{ip}/fastdl/{sid}/"
)
PY


# ================================================================
# 7. HARD HTTP VALIDATION
# ================================================================

echo
echo "[7/8] Validate actual HTTP body..."

TMP="$(mktemp -d)"

trap 'rm -rf "$TMP"' EXIT


# ------------------------------------------------
# Missing resource MUST BE 404.
# ------------------------------------------------

CODE="$(
curl \
    -sS \
    -o "$TMP/missing" \
    -w '%{http_code}' \
    -H "Host: $PUBLIC_IP" \
    "http://127.0.0.1/fastdl/$SID/__hyper_test_missing__.mdl" \
    || true
)"

if [[ "$CODE" != "404" ]]; then

    echo
    echo "[ERROR]"
    echo "Missing FastDL resource returned HTTP $CODE"
    echo "Expected: 404"
    echo

    echo "--- body ---"

    head -c 500 "$TMP/missing" || true

    echo

    exit 20
fi

echo "[OK] nonexistent .mdl -> HTTP 404"


verify_file()
{
    local EXT="$1"

    local SAMPLE

    SAMPLE="$(
        find \
            "$FASTDL_ROOT/$SID" \
            -type f \
            -name "*.$EXT" \
            -size +0c \
            2>/dev/null \
            | head -n1 \
            || true
    )"

    if [[ -z "$SAMPLE" ]]; then

        echo "[SKIP] No .$EXT sample"

        return 0
    fi

    local REL

    REL="${SAMPLE#"$FASTDL_ROOT/$SID/"}"

    local BODY="$TMP/$EXT.body"
    local HEADERS="$TMP/$EXT.headers"

    curl \
        -sS \
        --fail \
        -D "$HEADERS" \
        -o "$BODY" \
        -H "Host: $PUBLIC_IP" \
        "http://127.0.0.1/fastdl/$SID/$REL"


    if ! grep -qi '^X-Hyper-FastDL: binary-v33' "$HEADERS"; then

        echo
        echo "[ERROR]"
        echo "$REL did NOT hit binary FastDL vhost"
        echo

        cat "$HEADERS"

        exit 21
    fi


    if grep -qi '^Content-Type: *text/html' "$HEADERS"; then

        echo "[ERROR] $REL served as text/html"

        exit 22
    fi


    local HASH_DISK
    local HASH_HTTP

    HASH_DISK="$(
        sha256sum "$SAMPLE" |
        awk '{print $1}'
    )"

    HASH_HTTP="$(
        sha256sum "$BODY" |
        awk '{print $1}'
    )"


    if [[ "$HASH_DISK" != "$HASH_HTTP" ]]; then

        echo
        echo "[ERROR]"
        echo "HTTP body != FastDL disk file"
        echo "$REL"
        echo

        exit 23
    fi


    python3 - "$BODY" "$EXT" <<'PY'

from pathlib import Path
import sys

p=Path(sys.argv[1])

ext=sys.argv[2].lower()

data=p.read_bytes()

head=data[:16]


# Detect common HTML/PHP fallback immediately.

stripped=data[:128].lstrip().lower()

bad_html=(
    b"<!doctype",
    b"<html",
    b"<head",
    b"<body",
    b"<?php",
)

if any(
    stripped.startswith(x)
    for x in bad_html
):
    raise SystemExit(
        "HTTP body is HTML/PHP instead of game resource"
    )


if ext == "bsp":

    if len(head) < 4:

        raise SystemExit(
            "BSP too small"
        )

    version=int.from_bytes(
        head[:4],
        "little",
        signed=True
    )

    if version != 30:

        raise SystemExit(
            f"BSP version={version}, expected=30"
        )


elif ext == "mdl":

    if head[:4] not in (
        b"IDST",
        b"IDSQ",
    ):

        raise SystemExit(
            f"bad MDL magic: {head[:4]!r}"
        )


elif ext == "wav":

    if not (
        len(head) >= 12
        and head[:4] == b"RIFF"
        and head[8:12] == b"WAVE"
    ):

        raise SystemExit(
            "not RIFF/WAVE"
        )


elif ext == "spr":

    if head[:4] != b"IDSP":

        raise SystemExit(
            f"bad SPR magic: {head[:4]!r}"
        )

PY


    echo "[OK] .$EXT -> real binary -> $REL"
}


verify_file bsp
verify_file mdl
verify_file wav
verify_file spr


# ------------------------------------------------
# Exact OLD ZOMBIE problem files
# ------------------------------------------------

echo
echo "--- exact OLD ZOMBIE resources ---"

for REL in \
    "maps/zm_ice_attack.bsp" \
    "maps/zm_ice_attack_hd.bsp" \
    "models/player/oldz_delux_r1/oldz_delux_r1.mdl"
do

    FP="$FASTDL_ROOT/$SID/$REL"

    if [[ ! -f "$FP" ]]; then

        echo "[MISSING] $REL"

        continue
    fi


    CODE="$(
        curl \
            -sS \
            -o "$TMP/exact.bin" \
            -w '%{http_code}' \
            -H "Host: $PUBLIC_IP" \
            "http://127.0.0.1/fastdl/$SID/$REL" \
            || true
    )"


    echo "[$CODE] $REL"


    if [[ "$CODE" != "200" ]]; then

        echo "[ERROR] Resource exists but HTTP status is $CODE"

        exit 24
    fi


    DISK="$(
        sha256sum "$FP" |
        awk '{print $1}'
    )"

    HTTP="$(
        sha256sum "$TMP/exact.bin" |
        awk '{print $1}'
    )"


    if [[ "$DISK" != "$HTTP" ]]; then

        echo "[ERROR] $REL HTTP response differs from disk"

        exit 25
    fi

done


# ================================================================
# 8. RESTART + STATUS
# ================================================================

echo
echo "[8/8] Restart game server..."

systemctl restart "hyper-cs16@${SID}.service"

sleep 3


echo
echo "--- FastDL status ---"

"$CTL" fastdl-status "$SID" || true


echo
echo "--- Runtime cvars ---"

"$CTL" rcon "$SID" 'sv_downloadurl' || true

"$CTL" rcon "$SID" 'sv_allowdownload' || true

"$CTL" rcon "$SID" 'sv_allow_dlfile' || true


echo
echo "--- nginx FastDL ---"

curl \
    -sSI \
    -H "Host: $PUBLIC_IP" \
    "http://127.0.0.1/fastdl/$SID/__missing__.mdl" \
    | head -20 \
    || true


echo
echo "================================================================"
echo " [SUCCESS] FASTDL BINARY HARD FIX v33"
echo "================================================================"
echo
echo "URL:"
echo " http://${PUBLIC_IP}/fastdl/${SID}/"
echo
echo "Nginx:"
echo " ${NGINX_CONF}"
echo
echo "Backup:"
echo " ${BACKUP}"
echo
echo "Report:"
echo " ${REPORT}"
echo
echo "Result:"
echo " - FastDL no longer falls through to panel HTML"
echo " - missing files = 404"
echo " - BSP/MDL/WAV/SPR HTTP payload is verified"
echo " - HTTP payload must match file stored in FastDL"
echo " - works for /fastdl/<ANY_SERVER_ID>/"
echo " - canonical sv_downloadurl has trailing slash"
echo
echo "IMPORTANT:"
echo "An already corrupted local client file with the SAME filename"
echo "cannot be deleted remotely by the game server."
echo "For such an old cached file, either delete it once on the client"
echo "or change/version that particular resource filename."
echo
echo "================================================================"