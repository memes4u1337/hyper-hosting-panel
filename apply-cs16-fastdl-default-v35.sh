#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "[ERROR] Run as root"
    exit 1
}

SID="${1:-25}"

CTL="/usr/local/sbin/hyper-cs16-ctl"
SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-v35-$SID-$STAMP"
TMP="$(mktemp -d)"

trap 'rm -rf "$TMP"' EXIT

echo "================================================================"
echo " OLD ZOMBIE / HYPER-HOST FASTDL DEFAULT SERVER FIX v35"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo "================================================================"

[[ "$SID" =~ ^[0-9]+$ ]] || {
    echo "[ERROR] Invalid SID"
    exit 2
}

[[ -d "$CSTRIKE" ]] || {
    echo "[ERROR] Missing $CSTRIKE"
    exit 2
}

mkdir -p "$BACKUP"


# ================================================================
# 1. FIND REAL DEFAULT_SERVER CONFIG
# ================================================================

echo
echo "[1/9] Finding nginx HTTP default_server..."

DEFAULT_CONF="$(
nginx -T 2>&1 |
python3 -c '
import sys,re

current=None

for line in sys.stdin:

    m=re.match(
        r"^# configuration file (.+):$",
        line.rstrip()
    )

    if m:
        current=m.group(1)
        continue

    if (
        current
        and re.search(
            r"\blisten\s+80\s+default_server\s*;",
            line
        )
    ):
        print(current)
        break
'
)"

[[ -n "$DEFAULT_CONF" ]] || {
    echo "[ERROR] Could not find HTTP default_server config"
    exit 3
}

DEFAULT_REAL="$(readlink -f "$DEFAULT_CONF")"

echo "[OK] nginx source : $DEFAULT_CONF"
echo "[OK] real file    : $DEFAULT_REAL"

cp -a "$DEFAULT_REAL" "$BACKUP/default-server.conf.before"


# ================================================================
# 2. PATCH THE ACTUAL server{} BLOCK
# ================================================================

echo
echo "[2/9] Installing binary FastDL directly in default_server..."

python3 - "$DEFAULT_REAL" <<'PY'
from pathlib import Path
import re
import sys

p=Path(sys.argv[1])

s=p.read_text(
    encoding="utf-8",
    errors="ignore"
)

START="# HYPER-CS16 FASTDL V35 BEGIN"
END="# HYPER-CS16 FASTDL V35 END"

#
# Remove old v35 block if rerun.
#

s=re.sub(
    r"\n\s*# HYPER-CS16 FASTDL V35 BEGIN.*?"
    r"# HYPER-CS16 FASTDL V35 END\s*\n",
    "\n",
    s,
    flags=re.S
)

#
# Find server {} blocks.
#

blocks=[]

for m in re.finditer(r"\bserver\s*\{", s):

    brace=s.find("{",m.start())

    depth=0
    quote=None
    escape=False
    end=None

    for i in range(brace,len(s)):

        c=s[i]

        if escape:
            escape=False
            continue

        if c=="\\":
            escape=True
            continue

        if quote:
            if c==quote:
                quote=None
            continue

        if c in ("'",'"'):
            quote=c
            continue

        if c=="{":
            depth+=1

        elif c=="}":
            depth-=1

            if depth==0:
                end=i
                break

    if end is not None:
        blocks.append(
            (m.start(),brace,end)
        )


selected=None

for start,brace,end in blocks:

    body=s[brace+1:end]

    if re.search(
        r"\blisten\s+80\s+default_server\s*;",
        body
    ):
        selected=(start,brace,end)
        break


if selected is None:

    raise SystemExit(
        "[ERROR] listen 80 default_server block not found"
    )


start,brace,end=selected


fastdl=r'''

    # HYPER-CS16 FASTDL V35 BEGIN

    #
    # Valid GoldSrc downloadable files.
    #
    # IMPORTANT:
    # root + URI:
    #
    # /fastdl/25/maps/map.bsp
    #
    # becomes:
    #
    # /srv/hyper-cs16/fastdl/25/maps/map.bsp
    #

    location ~* ^/fastdl/[0-9]+/.+\.(?:bsp|res|wad|mdl|spr|wav|mp3|tga|bmp|pcx|nav|txt|ztmp)(?:\.bz2)?$ {

        root /srv/hyper-cs16;

        #
        # CRITICAL:
        # no index.html
        # no PHP
        # no panel fallback
        #

        try_files $uri =404;

        types { }
        default_type application/octet-stream;

        sendfile on;
        tcp_nopush on;
        gzip off;
        autoindex off;

        add_header X-Hyper-FastDL "v35" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }


    #
    # Anything unknown below /fastdl/
    # MUST be 404.
    #

    location /fastdl/ {

        default_type text/plain;

        add_header X-Hyper-FastDL "v35-reject" always;
        add_header X-Content-Type-Options "nosniff" always;

        return 404 "FastDL resource not found\n";
    }

    # HYPER-CS16 FASTDL V35 END

'''


insert=brace+1

s=s[:insert]+fastdl+s[insert:]

p.write_text(
    s,
    encoding="utf-8"
)

print("[OK] Patched:",p)
PY


echo
echo "--- nginx -t ---"

if ! nginx -t; then

    echo
    echo "[ERROR] nginx validation failed"
    echo "[ROLLBACK]"

    cp -a \
        "$BACKUP/default-server.conf.before" \
        "$DEFAULT_REAL"

    nginx -t || true

    exit 4
fi


echo
echo "[3/9] Reload nginx..."

systemctl reload nginx


# ================================================================
# 3. TEST THAT HTML FALLBACK IS DEAD
# ================================================================

echo
echo "[4/9] Test missing FastDL resource..."

CODE="$(
curl \
    -sS \
    -o "$TMP/missing.body" \
    -D "$TMP/missing.headers" \
    -w '%{http_code}' \
    -H 'Host: 90.189.208.25' \
    "http://127.0.0.1/fastdl/$SID/__THIS_FILE_MUST_NOT_EXIST__.mdl"
)"

echo "HTTP: $CODE"

cat "$TMP/missing.headers"

if [[ "$CODE" != "404" ]]; then

    echo
    echo "[ERROR] Missing FastDL resource still does not return 404"
    echo
    echo "--- BODY ---"

    head -c 500 "$TMP/missing.body" || true

    echo

    exit 10
fi


if grep -qi \
    '<html\|<!doctype\|Домен не настроен' \
    "$TMP/missing.body"
then

    echo "[ERROR] HTML fallback is still active"
    exit 11
fi

echo "[OK] Missing FastDL file -> clean HTTP 404"


# ================================================================
# 4. SYNC CURRENT SERVER
# ================================================================

echo
echo "[5/9] Rebuild server #$SID FastDL..."

"$CTL" fastdl-sync "$SID" || true


# ================================================================
# 5. FIX server.cfg URL
# ================================================================

echo
echo "[6/9] Fix sv_downloadurl..."

CFG="$CSTRIKE/server.cfg"

python3 - "$CFG" "$SID" <<'PY'
from pathlib import Path
import re
import sys

p=Path(sys.argv[1])
sid=sys.argv[2]

s=p.read_text(
    encoding="utf-8",
    errors="ignore"
)

url=f"http://90.189.208.25/fastdl/{sid}/"

if re.search(
    r'(?im)^\s*sv_downloadurl\s+',
    s
):

    s=re.sub(
        r'(?im)^\s*sv_downloadurl\s+.*$',
        f'sv_downloadurl "{url}"',
        s
    )

else:

    s+="\n"+f'sv_downloadurl "{url}"'+"\n"


p.write_text(
    s,
    encoding="utf-8"
)

print("[OK]",url)
PY


# ================================================================
# 6. VERIFY ACTUAL FASTDL FILES
# ================================================================

echo
echo "[7/9] Validate binary files over HTTP..."


verify_asset()
{
    local EXT="$1"

    local FILE

    FILE="$(
        find "$FASTDL" \
            -type f \
            -iname "*.$EXT" \
            -size +0c \
            2>/dev/null |
        head -n1 ||
        true
    )"


    if [[ -z "$FILE" ]]; then

        echo "[SKIP] No .$EXT file"

        return 0
    fi


    local REL="${FILE#"$FASTDL/"}"

    local BODY="$TMP/$EXT.body"
    local HDR="$TMP/$EXT.headers"


    curl \
        -sS \
        --fail \
        -D "$HDR" \
        -o "$BODY" \
        -H 'Host: 90.189.208.25' \
        "http://127.0.0.1/fastdl/$SID/$REL"


    if ! grep -qi \
        '^X-Hyper-FastDL: v35' \
        "$HDR"
    then

        echo "[ERROR] .$EXT request did not hit FastDL v35"
        cat "$HDR"
        exit 20
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

        echo "[ERROR] HTTP file differs from disk:"
        echo "$REL"

        exit 21
    fi


    python3 - "$BODY" "$EXT" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])

ext=sys.argv[2].lower()

data=p.read_bytes()

head=data[:16]

low=data[:512].lstrip().lower()


#
# Never accept a web response.
#

for x in (
    b"<!doctype",
    b"<html",
    b"<head",
    b"<body",
    b"<?php",
):

    if low.startswith(x):

        raise SystemExit(
            "HTML/PHP received as game resource"
        )


if ext=="bsp":

    if len(head)<4:
        raise SystemExit("BSP too small")

    version=int.from_bytes(
        head[:4],
        "little",
        signed=True
    )

    if version != 30:
        raise SystemExit(
            f"BSP version {version}, expected 30"
        )


elif ext=="mdl":

    if head[:4] not in (
        b"IDST",
        b"IDSQ"
    ):

        raise SystemExit(
            f"MDL bad header {head[:4]!r}"
        )


elif ext=="wav":

    if not (
        len(head)>=12
        and head[:4]==b"RIFF"
        and head[8:12]==b"WAVE"
    ):

        raise SystemExit(
            "WAV is not RIFF/WAVE"
        )


elif ext=="spr":

    if head[:4] != b"IDSP":

        raise SystemExit(
            f"SPR bad header {head[:4]!r}"
        )

PY


    echo "[OK] .$EXT: $REL"
}


verify_asset bsp
verify_asset mdl
verify_asset wav
verify_asset spr


# ================================================================
# 7. CHECK YOUR EXACT BROKEN FILES
# ================================================================

echo
echo "[8/9] Check OLD ZOMBIE problem assets..."


check_exact()
{
    local REL="$1"

    local FILE="$FASTDL/$REL"


    if [[ ! -f "$FILE" ]]; then

        echo "[MISSING] $REL"
        return
    fi


    local BODY="$TMP/exact.bin"
    local HDR="$TMP/exact.headers"


    CODE="$(
        curl \
            -sS \
            -D "$HDR" \
            -o "$BODY" \
            -w '%{http_code}' \
            -H 'Host: 90.189.208.25' \
            "http://127.0.0.1/fastdl/$SID/$REL"
    )"


    if [[ "$CODE" != "200" ]]; then

        echo "[ERROR $CODE] $REL"
        exit 30
    fi


    DISK="$(
        sha256sum "$FILE" |
        awk '{print $1}'
    )"

    HTTP="$(
        sha256sum "$BODY" |
        awk '{print $1}'
    )"


    if [[ "$DISK" != "$HTTP" ]]; then

        echo "[ERROR HASH] $REL"
        exit 31
    fi


    echo "[200 BINARY OK] $REL"
}


check_exact "maps/zm_ice_attack.bsp"
check_exact "maps/zm_ice_attack_hd.bsp"
check_exact "models/player/oldz_delux_r1/oldz_delux_r1.mdl"


# ================================================================
# 8. RESTART SERVER
# ================================================================

echo
echo "[9/9] Restart server #$SID..."

systemctl restart \
    "hyper-cs16@$SID.service"

sleep 3


echo
echo "--- FASTDL STATUS ---"

"$CTL" fastdl-status "$SID" || true


echo
echo "--- SV_DOWNLOADURL ---"

"$CTL" rcon \
    "$SID" \
    'sv_downloadurl' \
    || true


echo
echo "--- FINAL MISSING FILE TEST ---"

curl \
    -sS \
    -D - \
    -o /dev/null \
    -H 'Host: 90.189.208.25' \
    "http://127.0.0.1/fastdl/$SID/__missing_final__.mdl"


echo
echo "================================================================"
echo " [SUCCESS] FASTDL DEFAULT SERVER FIX v35"
echo "================================================================"
echo
echo "The broken routing was:"
echo
echo " /fastdl/... -> default_server -> /index.html -> HTTP 200"
echo
echo "Now:"
echo
echo " existing asset  -> HTTP 200 binary"
echo " missing asset   -> HTTP 404"
echo " html/php         -> NEVER used as FastDL fallback"
echo
echo "FastDL:"
echo " http://90.189.208.25/fastdl/$SID/"
echo
echo "Nginx file:"
echo " $DEFAULT_REAL"
echo
echo "Backup:"
echo " $BACKUP"
echo
echo "================================================================"