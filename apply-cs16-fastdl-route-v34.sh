#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "[ERROR] Run as root"
    exit 1
}

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"

CTL="/usr/local/sbin/hyper-cs16-ctl"
SRC_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"

FASTDL="/srv/hyper-cs16/fastdl"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"

SNIPPET="/etc/nginx/snippets/hyper-cs16-fastdl-v34.inc"
OLD_V33="/etc/nginx/conf.d/hyper-cs16-fastdl-binary.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/fastdl-v34-backup-$SID-$STAMP"

mkdir -p "$BACKUP"

echo "================================================================"
echo " OLD ZOMBIE / HYPER-HOST FASTDL ROUTE FIX v34"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo "================================================================"

[[ "$SID" =~ ^[0-9]+$ ]] || exit 2
[[ -d "$CSTRIKE" ]] || {
    echo "[ERROR] Missing $CSTRIKE"
    exit 2
}

PUBLIC_IP="$(
python3 <<'PY'
import json
import re
import subprocess

try:
    d=json.load(open("/etc/hyper-cs16/runtime.json"))

    ip=str(d.get("public_ip") or "").strip()

    if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ip):
        print(ip)
        raise SystemExit
except Exception:
    pass

try:
    o=subprocess.check_output(
        ["ip","-4","route","get","1.1.1.1"],
        text=True
    )

    m=re.search(
        r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)",
        o
    )

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

echo "[OK] Public IP: $PUBLIC_IP"


echo
echo "[1/8] Find nginx config producing 'Домен не настроен'..."

TARGET="$(
grep \
    -RIl \
    --include='*.conf' \
    'Домен не настроен' \
    /etc/nginx \
    2>/dev/null \
    | head -n1 \
    || true
)"

if [[ -z "$TARGET" ]]; then

    echo "[ERROR] Cannot find nginx catch-all configuration"

    echo
    echo "Run:"
    echo "grep -Rni 'Домен не настроен' /etc/nginx"

    exit 4
fi

echo "[OK] Catch-all: $TARGET"

mkdir -p "$BACKUP/$(dirname "${TARGET#/}")"
cp -a "$TARGET" "$BACKUP/${TARGET#/}"


echo
echo "[2/8] Disable failed standalone v33 vhost..."

if [[ -f "$OLD_V33" ]]; then

    cp -a "$OLD_V33" "$BACKUP/"

    mv \
        "$OLD_V33" \
        "$OLD_V33.disabled-v34"

    echo "[OK] v33 standalone vhost disabled"

else

    echo "[OK] no active v33 standalone vhost"

fi


echo
echo "[3/8] Create binary-only FastDL nginx snippet..."

mkdir -p /etc/nginx/snippets

cat > "$SNIPPET" <<'NGINX'

# ================================================================
# HYPER-HOST CS 1.6 FASTDL ROUTE v34
# ================================================================

#
# IMPORTANT:
#
# regex location is checked before generic /fastdl/
#
# Only real CS resources can receive HTTP 200.
#

location ~* ^/fastdl/[0-9]+/.+\.(bsp|res|wad|mdl|spr|wav|mp3|tga|bmp|pcx|nav|txt|ztmp|bz2)$ {

    root /srv/hyper-cs16;

    #
    # CRITICAL
    #
    # Actual file:
    #
    # /srv/hyper-cs16/fastdl/25/maps/test.bsp
    #
    # URL:
    #
    # /fastdl/25/maps/test.bsp
    #

    try_files $uri =404;

    types { }

    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;

    gzip off;
    autoindex off;

    add_header X-Hyper-FastDL "route-v34" always;
    add_header X-Content-Type-Options "nosniff" always;

    #
    # Prevent previous broken HTML response being reused.
    #

    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
}


#
# PHP / HTML / unknown extension / missing junk:
#
# NEVER panel fallback.
#

location /fastdl/ {

    default_type text/plain;

    return 404 "FastDL resource not found\n";
}

NGINX


echo
echo "[4/8] Inject FastDL DIRECTLY into real panel catch-all server{}..."

python3 - \
    "$TARGET" \
    "$SNIPPET" <<'PY'

from pathlib import Path
import sys


config=Path(sys.argv[1])

snippet=sys.argv[2]

text=config.read_text(
    encoding="utf-8",
    errors="ignore"
)

include_line=f"include {snippet};"


if include_line in text:

    print(
        "[OK] FastDL include already installed"
    )

    raise SystemExit


marker="Домен не настроен"

marker_pos=text.find(marker)


if marker_pos < 0:

    raise SystemExit(
        "[ERROR] domain marker disappeared"
    )


#
# Find every server { block.
#

servers=[]

pos=0

while True:

    start=text.find(
        "server",
        pos
    )

    if start < 0:
        break

    brace=start+len("server")

    while (
        brace < len(text)
        and text[brace].isspace()
    ):
        brace+=1

    if (
        brace < len(text)
        and text[brace] == "{"
    ):

        depth=0

        end=None

        for i in range(
            brace,
            len(text)
        ):

            if text[i] == "{":
                depth+=1

            elif text[i] == "}":

                depth-=1

                if depth == 0:

                    end=i

                    break

        if end is not None:

            servers.append(
                (
                    start,
                    brace,
                    end
                )
            )

    pos=start+6


#
# Find server{} containing
# "Домен не настроен".
#

selected=None

for item in servers:

    start,brace,end=item

    if (
        start
        <= marker_pos
        <= end
    ):

        selected=item

        break


if selected is None:

    raise SystemExit(
        "[ERROR] Cannot locate catch-all server{}"
    )


start,brace,end=selected


insert=brace+1


addition=(
    "\n"
    "    # HYPER-HOST CS16 FASTDL v34\n"
    f"    {include_line}\n"
)


text=(
    text[:insert]
    +
    addition
    +
    text[insert:]
)


config.write_text(
    text,
    encoding="utf-8"
)


print(
    "[OK] FastDL installed inside actual catch-all server{}"
)

PY


echo
echo "--- nginx test ---"

nginx -t


echo
echo "--- reload nginx ---"

systemctl reload nginx


echo
echo "[5/8] Permanently fix FastDL URL in panel controller..."

patch_ctl()
{
    local FILE="$1"

    [[ -f "$FILE" ]] || return 0

    python3 - "$FILE" <<'PY'

from pathlib import Path
import re
import sys


p=Path(sys.argv[1])

s=p.read_text(
    encoding="utf-8"
)


s,n1=re.subn(
    r"return f'http://\{public\}/fastdl/\{sid\}'",
    "return f'http://{public}/fastdl/{sid}/'",
    s
)


s,n2=re.subn(
    r"return f'https://\{FASTDL_DOMAIN\}/fastdl/\{sid\}'",
    "return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'",
    s
)


p.write_text(
    s,
    encoding="utf-8"
)


print(
    f"[OK] {p}: HTTP={n1}, HTTPS={n2}"
)

PY

    python3 -m py_compile "$FILE"
}


patch_ctl "$SRC_CTL"
patch_ctl "$CTL"

chmod 0755 "$CTL"


echo
echo "[6/8] Rebuild FastDL..."

"$CTL" fastdl-sync "$SID" || true


echo
echo "[7/8] HARD HTTP TEST..."

TMP="$(mktemp -d)"

trap 'rm -rf "$TMP"' EXIT


#
# ------------------------------------------------
# TEST 1
# Missing resource absolutely MUST return 404.
# ------------------------------------------------
#

CODE="$(
curl \
    -sS \
    -o "$TMP/missing" \
    -w '%{http_code}' \
    -H "Host: $PUBLIC_IP" \
    "http://127.0.0.1/fastdl/$SID/__not_existing__.mdl" \
    || true
)"


echo "Missing resource HTTP: $CODE"


if [[ "$CODE" != "404" ]]; then

    echo
    echo "================================================"
    echo " [ERROR] FASTDL STILL INTERCEPTED"
    echo "================================================"

    echo

    head -c 600 "$TMP/missing"

    echo
    echo

    echo "--- nginx routing ---"

    nginx -T 2>&1 \
        | grep -nE \
        'server_name|default_server|fastdl|Домен не настроен' \
        | tail -150 \
        || true

    exit 20

fi


echo "[OK] Missing resource -> HTTP 404"


#
# ------------------------------------------------
# Actual asset test.
# ------------------------------------------------
#

verify()
{
    local EXT="$1"

    local FILE

    FILE="$(
        find \
            "$FASTDL/$SID" \
            -type f \
            -name "*.$EXT" \
            -size +0c \
            2>/dev/null \
            | head -n1 \
            || true
    )"


    if [[ -z "$FILE" ]]; then

        echo "[SKIP] no .$EXT"

        return
    fi


    local REL="${FILE#"$FASTDL/$SID/"}"

    local BODY="$TMP/file-$EXT"
    local HEADER="$TMP/header-$EXT"


    curl \
        -sS \
        --fail \
        -D "$HEADER" \
        -o "$BODY" \
        -H "Host: $PUBLIC_IP" \
        "http://127.0.0.1/fastdl/$SID/$REL"


    if ! grep -qi \
        '^X-Hyper-FastDL: route-v34' \
        "$HEADER"
    then

        echo "[ERROR] .$EXT did not hit FastDL v34"

        cat "$HEADER"

        exit 21
    fi


    HASH_DISK="$(
        sha256sum "$FILE" |
        awk '{print $1}'
    )"


    HASH_HTTP="$(
        sha256sum "$BODY" |
        awk '{print $1}'
    )"


    if [[ "$HASH_DISK" != "$HASH_HTTP" ]]; then

        echo "[ERROR] HTTP data != real file"

        echo "$REL"

        exit 22
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


#
# HTML protection.
#

low=data[:256].lstrip().lower()


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
        "HTML detected instead of binary"
    )


if ext == "bsp":

    if len(head) < 4:

        raise SystemExit(
            "BSP too short"
        )

    version=int.from_bytes(
        head[:4],
        "little",
        signed=True
    )

    if version != 30:

        raise SystemExit(
            f"BSP version {version}, expected 30"
        )


elif ext == "mdl":

    if head[:4] not in (
        b"IDST",
        b"IDSQ",
    ):

        raise SystemExit(
            f"invalid MDL magic {head[:4]!r}"
        )


elif ext == "wav":

    if not (
        len(head) >= 12
        and head[:4] == b"RIFF"
        and head[8:12] == b"WAVE"
    ):

        raise SystemExit(
            "invalid RIFF/WAVE"
        )


elif ext == "spr":

    if head[:4] != b"IDSP":

        raise SystemExit(
            f"invalid SPR {head[:4]!r}"
        )

PY


    echo "[OK] .$EXT binary -> $REL"
}


verify bsp
verify mdl
verify wav
verify spr


echo
echo "--- OLD ZOMBIE PROBLEM FILES ---"


for REL in \
    "maps/zm_ice_attack.bsp" \
    "maps/zm_ice_attack_hd.bsp" \
    "models/player/oldz_delux_r1/oldz_delux_r1.mdl"
do

    FILE="$FASTDL/$SID/$REL"

    if [[ ! -f "$FILE" ]]; then

        echo "[MISSING] $REL"

        continue
    fi


    CODE="$(
        curl \
            -sS \
            -o "$TMP/exact" \
            -w '%{http_code}' \
            -H "Host: $PUBLIC_IP" \
            "http://127.0.0.1/fastdl/$SID/$REL"
    )"


    echo "[$CODE] $REL"


    [[ "$CODE" == "200" ]] || exit 23


    DISK="$(
        sha256sum "$FILE" |
        awk '{print $1}'
    )"


    HTTP="$(
        sha256sum "$TMP/exact" |
        awk '{print $1}'
    )"


    if [[ "$DISK" != "$HTTP" ]]; then

        echo "[ERROR] corrupted HTTP response: $REL"

        exit 24
    fi

done


echo
echo "[8/8] Restart CS server..."

systemctl restart \
    "hyper-cs16@$SID.service"


sleep 3


echo
echo "--- FINAL FASTDL STATUS ---"

"$CTL" fastdl-status "$SID" || true


echo
echo "--- LIVE CVAR ---"

"$CTL" rcon \
    "$SID" \
    'sv_downloadurl' \
    || true


echo
echo "================================================================"
echo " [SUCCESS] FASTDL ROUTE FIX v34"
echo "================================================================"
echo
echo "URL:"
echo "http://$PUBLIC_IP/fastdl/$SID/"
echo
echo "Catch-all nginx:"
echo "$TARGET"
echo
echo "FastDL nginx:"
echo "$SNIPPET"
echo
echo "Rules:"
echo " existing CS asset -> binary file"
echo " missing asset     -> HTTP 404"
echo " PHP/HTML fallback -> impossible under /fastdl/"
echo
echo "================================================================"