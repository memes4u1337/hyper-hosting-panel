#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "[ERROR] run as root"
    exit 1
}

[[ "$SID" =~ ^[0-9]+$ ]] || {
    echo "[ERROR] bad server id"
    exit 1
}

SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"

SRC_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"

SRC_NGINX="$REPO/scripts/nginx_recover_v89.py"
LIVE_NGINX="/opt/hyper-host/nginx_recover_v89.py"

RECONCILE="/usr/local/sbin/hyper-host-nginx-reconcile"

META="$CSTRIKE/addons/metamod/plugins.ini"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-permanent-v37-$SID-$STAMP"

mkdir -p "$BACKUP"

echo "================================================================"
echo " OLD ZOMBIE / HYPER-HOST PERMANENT FIX v37"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo "================================================================"


backup()
{
    local f="$1"

    [[ -e "$f" ]] || return 0

    local rel="${f#/}"

    mkdir -p "$BACKUP/$(dirname "$rel")"

    cp -a "$f" "$BACKUP/$rel"
}


echo
echo "[1/9] BACKUP"

backup "$SRC_CTL"
backup "$LIVE_CTL"
backup "$SRC_NGINX"
backup "$LIVE_NGINX"
backup "$META"
backup /etc/nginx/hyper-host-managed/00-default.conf


# ================================================================
# PATCH NGINX GENERATOR
# ================================================================

echo
echo "[2/9] PATCH PERMANENT NGINX GENERATOR"


patch_nginx()
{
    local F="$1"

    [[ -f "$F" ]] || {
        echo "[SKIP] $F"
        return
    }

python3 - "$F" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])

s = p.read_text(
    encoding="utf-8",
    errors="strict"
)

MARKER = "HYPER-CS16 FASTDL PERMANENT V37"


if MARKER not in s:

    anchor = (
        "def default_block(root: str, cert: str, key: str) -> str:"
    )

    if anchor not in s:
        raise SystemExit(
            f"default_block not found: {p}"
        )


    helper = r'''
def cs16_fastdl_v37() -> str:
    """
    HYPER-CS16 FASTDL PERMANENT V37

    Generated every time HYPER-HOST rebuilds nginx.
    """

    return r"""
    # HYPER-CS16 FASTDL PERMANENT V37

    location ~* ^/fastdl/[0-9]+/.+\.(?:bsp|res|wad|mdl|spr|wav|mp3|tga|bmp|pcx|nav|txt|ztmp)(?:\.bz2)?$ {

        root /srv/hyper-cs16;

        try_files $uri =404;

        types { }
        default_type application/octet-stream;

        sendfile on;
        tcp_nopush on;

        gzip off;
        autoindex off;

        add_header X-Hyper-FastDL "permanent-v37" always;
        add_header X-Content-Type-Options "nosniff" always;

        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }


    #
    # Missing/invalid FastDL request NEVER falls into index.html/PHP.
    #

    location /fastdl/ {

        default_type text/plain;

        add_header X-Hyper-FastDL "permanent-v37-reject" always;
        add_header X-Content-Type-Options "nosniff" always;

        return 404 "FastDL resource not found\n";
    }

"""

'''

    s = s.replace(
        anchor,
        helper + anchor,
        1
    )


    old = '''    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "DEFAULT_V89"; }}
    location / {{ try_files $uri /index.html =404; }}'''


    new = '''    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "DEFAULT_V89"; }}
{cs16_fastdl_v37()}    location / {{ try_files $uri /index.html =404; }}'''


    count = s.count(old)

    if count != 2:
        raise SystemExit(
            f"expected 2 default blocks, got {count}: {p}"
        )


    s = s.replace(
        old,
        new
    )


p.write_text(
    s,
    encoding="utf-8"
)

print(
    "[OK]",
    p
)
PY

    python3 -m py_compile "$F"
}


patch_nginx "$SRC_NGINX"
patch_nginx "$LIVE_NGINX"


# ================================================================
# PATCH CS CONTROLLER
# ================================================================

echo
echo "[3/9] PATCH hyper-cs16-ctl"


patch_ctl()
{
    local F="$1"

    [[ -f "$F" ]] || {
        echo "[SKIP] $F"
        return
    }


python3 - "$F" <<'PY'
from pathlib import Path
import sys


p = Path(sys.argv[1])

s = p.read_text(
    encoding="utf-8",
    errors="strict"
)


#
# ------------------------------------------------
# 1. FastDL URL ALWAYS ends with /
# ------------------------------------------------
#

s = s.replace(
    "return f'http://{public}/fastdl/{sid}'",
    "return f'http://{public}/fastdl/{sid}/'"
)

s = s.replace(
    "return f'https://{FASTDL_DOMAIN}/fastdl/{sid}'",
    "return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'"
)


#
# ------------------------------------------------
# 2. REMOVE AUTOMATIC YaPB DISABLE
# ------------------------------------------------
#

start = s.find(
    "def _disable_yapb_for_recovery(c:dict):"
)

end = s.find(
    "\ndef _disable_zp_for_recovery(c:dict):",
    start
)


if start == -1 or end == -1:
    raise SystemExit(
        f"YaPB recovery function not found: {p}"
    )


replacement = '''def _disable_yapb_for_recovery(c:dict):

    """
    HYPER-HOST v37.

    Automatic recovery MUST NOT disable YaPB.

    YaPB quota, difficulty, names and other settings remain
    controlled by the existing game-server YaPB config.

    Manual bots-disable still works normally.
    """

    return False
'''


s = (
    s[:start]
    +
    replacement
    +
    s[end+1:]
)


p.write_text(
    s,
    encoding="utf-8"
)


print(
    "[OK]",
    p
)

PY

    python3 -m py_compile "$F"
}


patch_ctl "$SRC_CTL"
patch_ctl "$LIVE_CTL"

chmod 0755 "$LIVE_CTL"


# ================================================================
# RESTORE YaPB IF OLD AUTO RECOVERY DISABLED IT
# ================================================================

echo
echo "[4/9] RESTORE YaPB"


if [[ -f "$META" ]]; then

    if grep -qi \
        'HYPER-HOST auto-recovery:.*addons/yapb/bin/yapb.so' \
        "$META"
    then

        sed -i -E \
's#^[[:space:]]*;[[:space:]]*HYPER-HOST auto-recovery:[[:space:]]*(linux[[:space:]]+addons/yapb/bin/yapb\.so)[[:space:]]*$#\1#I' \
        "$META"

        echo "[OK] YaPB restored"

    else

        echo "[OK] YaPB was not auto-disabled"

    fi

else

    echo "[WARN] plugins.ini not found"

fi


echo
echo "--- metamod/plugins.ini ---"

grep -iE \
'yapb|amxmodx|reunion|unprecacher' \
"$META" \
2>/dev/null \
|| true


# ================================================================
# REGENERATE NGINX FROM THE FIXED SOURCE
# ================================================================

echo
echo "[5/9] REGENERATE NGINX"


if [[ -x "$RECONCILE" ]]; then

    "$RECONCILE"

else

    echo "[ERROR] $RECONCILE not found"
    exit 10

fi


nginx -t


# ================================================================
# INSTALL WATCHDOG
# ================================================================

echo
echo "[6/9] INSTALL PERMANENT WATCHDOG"


cat > /usr/local/sbin/hyper-cs16-fastdl-guard <<'EOF'
#!/usr/bin/env bash

set -u

SID="${1:-25}"

CTL="/usr/local/sbin/hyper-cs16-ctl"

CONF="/etc/nginx/hyper-host-managed/00-default.conf"

META="/srv/hyper-cs16/servers/$SID/cstrike/addons/metamod/plugins.ini"

CFG="/srv/hyper-cs16/servers/$SID/cstrike/server.cfg"

FASTDL="/srv/hyper-cs16/fastdl/$SID"

GEN="/opt/hyper-host/nginx_recover_v89.py"

RECON="/usr/local/sbin/hyper-host-nginx-reconcile"

LOCK="/run/hyper-cs16-fastdl-guard-$SID.lock"


exec 9>"$LOCK"

flock -n 9 || exit 0


log()
{
    logger \
        -t "hyper-cs16-fastdl-guard[$SID]" \
        "$*" \
        2>/dev/null \
        || true
}


#
# ================================================================
# YaPB protection
# ================================================================
#

if [[ -f "$META" ]] &&
   grep -qi 'HYPER-HOST auto-recovery:.*addons/yapb/bin/yapb.so' "$META"
then

    sed -i -E \
's#^[[:space:]]*;[[:space:]]*HYPER-HOST auto-recovery:[[:space:]]*(linux[[:space:]]+addons/yapb/bin/yapb\.so)[[:space:]]*$#\1#I' \
    "$META"

    systemctl restart \
        "hyper-cs16@$SID.service" \
        >/dev/null 2>&1 \
        || true

    log "restored YaPB loader"

fi


#
# ================================================================
# Nginx generator protection
# ================================================================
#

if [[ -f "$GEN" ]] &&
   ! grep -q \
      'HYPER-CS16 FASTDL PERMANENT V37' \
      "$GEN"
then

    log "WARNING nginx generator lost v37 marker"
fi


#
# ================================================================
# Active nginx protection
# ================================================================
#

if [[ ! -f "$CONF" ]] ||
   ! grep -q \
      'HYPER-CS16 FASTDL PERMANENT V37' \
      "$CONF"
then

    if [[ -x "$RECON" ]]; then

        "$RECON" \
            >/dev/null 2>&1 \
            || true

    fi

fi


#
# ================================================================
# FastDL URL protection
# ================================================================
#

if [[ ! -f "$CFG" ]] ||
   ! grep -qE \
      "^[[:space:]]*sv_downloadurl[[:space:]]+\"?[^\"]*/fastdl/$SID/\"?" \
      "$CFG"
then

    "$CTL" fastdl-sync "$SID" \
        >/dev/null 2>&1 \
        || true

    log "repaired FastDL config"

fi


#
# ================================================================
# Missing resource MUST be 404
# ================================================================
#

CODE="$(
curl \
    -sS \
    --max-time 5 \
    -o /dev/null \
    -w '%{http_code}' \
    "http://127.0.0.1/fastdl/$SID/__hyper_guard__.mdl" \
    2>/dev/null \
    || true
)"


if [[ "$CODE" != "404" ]]; then

    log "FastDL broken HTTP=$CODE; rebuilding nginx"

    if [[ -x "$RECON" ]]; then

        "$RECON" \
            >/dev/null 2>&1 \
            || true

    fi

fi


#
# ================================================================
# Verify one BSP over HTTP
# ================================================================
#

BSP="$(
find "$FASTDL/maps" \
    -type f \
    -iname '*.bsp' \
    -size +4c \
    2>/dev/null \
    | head -n1
)"


if [[ -n "$BSP" ]]; then

    REL="${BSP#$FASTDL/}"

    HEX="$(
        curl \
            -sS \
            --max-time 5 \
            --range 0-3 \
            "http://127.0.0.1/fastdl/$SID/$REL" \
            2>/dev/null \
        | xxd -p -c4 \
        | head -n1
    )"


    if [[ "$HEX" != "1e000000" ]]; then

        log "bad BSP HTTP header: $HEX; resync"

        "$CTL" fastdl-sync "$SID" \
            >/dev/null 2>&1 \
            || true

    fi

fi


#
# ================================================================
# Verify one MDL over HTTP
# ================================================================
#

MDL="$(
find "$FASTDL/models" \
    -type f \
    -iname '*.mdl' \
    -size +4c \
    2>/dev/null \
    | head -n1
)"


if [[ -n "$MDL" ]]; then

    REL="${MDL#$FASTDL/}"

    HEX="$(
        curl \
            -sS \
            --max-time 5 \
            --range 0-3 \
            "http://127.0.0.1/fastdl/$SID/$REL" \
            2>/dev/null \
        | xxd -p -c4 \
        | head -n1
    )"


    if [[ "$HEX" != "49445354" &&
          "$HEX" != "49445351" ]]
    then

        log "bad MDL HTTP header: $HEX; resync"

        "$CTL" fastdl-sync "$SID" \
            >/dev/null 2>&1 \
            || true

    fi

fi


exit 0
EOF


chmod 0755 \
    /usr/local/sbin/hyper-cs16-fastdl-guard


cat > /etc/systemd/system/hyper-cs16-fastdl-guard@.service <<'EOF'
[Unit]
Description=HYPER-HOST CS16 permanent FastDL/YaPB guard #%i
After=nginx.service network.target
Wants=nginx.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hyper-cs16-fastdl-guard %i
EOF


cat > /etc/systemd/system/hyper-cs16-fastdl-guard@.timer <<'EOF'
[Unit]
Description=HYPER-HOST CS16 FastDL guard timer #%i

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF


cat > /etc/systemd/system/hyper-cs16-fastdl-guard@.path <<'EOF'
[Unit]
Description=Watch HYPER-HOST nginx rebuilds for CS16 FastDL #%i

[Path]
PathChanged=/etc/nginx/hyper-host-managed/00-default.conf
Unit=hyper-cs16-fastdl-guard@%i.service

[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload

systemctl enable --now \
    "hyper-cs16-fastdl-guard@$SID.timer"

systemctl enable --now \
    "hyper-cs16-fastdl-guard@$SID.path"


# ================================================================
# FASTDL SYNC
# ================================================================

echo
echo "[7/9] FASTDL SYNC"


"$LIVE_CTL" fastdl-sync "$SID"


# ================================================================
# RESTART GAME SERVER
# ================================================================

echo
echo "[8/9] RESTART SERVER"


systemctl restart \
    "hyper-cs16@$SID.service"


sleep 6


/usr/local/sbin/hyper-cs16-fastdl-guard \
    "$SID" \
    || true


# ================================================================
# FINAL TESTS
# ================================================================

echo
echo "[9/9] FINAL TESTS"


echo
echo "=== MISSING RESOURCE ==="


CODE="$(
curl \
    -sS \
    -o /tmp/v37-missing.body \
    -D /tmp/v37-missing.headers \
    -w '%{http_code}' \
    "http://127.0.0.1/fastdl/$SID/__missing_v37__.mdl"
)"


echo "HTTP=$CODE"

grep -iE \
'^(HTTP/|Content-Type:|X-Hyper-FastDL:)' \
/tmp/v37-missing.headers \
|| true


if [[ "$CODE" != "404" ]]; then

    echo "[ERROR] Missing FastDL asset must be HTTP 404"

    head -c 400 \
        /tmp/v37-missing.body \
        || true

    echo

    exit 20

fi


echo
echo "=== EXACT OLD ZOMBIE FILES ==="


for REL in \
    "maps/zm_ice_attack.bsp" \
    "maps/zm_ice_attack_hd.bsp" \
    "models/player/oldz_delux_r1/oldz_delux_r1.mdl"
do

    FILE="/srv/hyper-cs16/fastdl/$SID/$REL"

    if [[ ! -f "$FILE" ]]; then

        echo "[MISSING] $REL"

        continue

    fi


    curl \
        -sS \
        -o /tmp/v37-body \
        -D /tmp/v37-header \
        "http://127.0.0.1/fastdl/$SID/$REL"


    DISK="$(
        sha256sum "$FILE" \
        | awk '{print $1}'
    )"


    HTTP="$(
        sha256sum /tmp/v37-body \
        | awk '{print $1}'
    )"


    if [[ "$DISK" != "$HTTP" ]]; then

        echo "[ERROR HASH] $REL"

        exit 21

    fi


    echo "[200 BINARY HASH OK] $REL"

done


echo
echo "=== SV_DOWNLOADURL ==="

"$LIVE_CTL" rcon \
    "$SID" \
    'sv_downloadurl' \
    || true


echo
echo "=== METAMOD ==="

"$LIVE_CTL" rcon \
    "$SID" \
    'meta list' \
    || true


echo
echo "=== PLAYERS ==="

"$LIVE_CTL" rcon \
    "$SID" \
    'status' \
    || true


echo
echo "=== WATCHDOG ==="

systemctl is-active \
    "hyper-cs16-fastdl-guard@$SID.timer" \
    || true

systemctl is-active \
    "hyper-cs16-fastdl-guard@$SID.path" \
    || true


echo
echo "================================================================"
echo " SUCCESS - PERMANENT FIX v37"
echo "================================================================"
echo
echo "FastDL:"
echo " http://90.189.208.25/fastdl/$SID/"
echo
echo "Fixed permanently:"
echo " - nginx generator"
echo " - FastDL /index.html fallback"
echo " - FastDL trailing slash"
echo " - YaPB auto-recovery disable"
echo " - periodic FastDL watchdog"
echo " - nginx config rewrite watcher"
echo
echo "YaPB config/quota/difficulty were NOT overwritten."
echo "Existing server YaPB settings remain authoritative."
echo
echo "Backup:"
echo " $BACKUP"
echo "================================================================"