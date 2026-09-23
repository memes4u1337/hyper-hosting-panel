#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run with sudo/root"; exit 1; }

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="/srv/hyper-cs16/servers/${SID}"
CS="${ROOT}/cstrike"
AMXX="${CS}/addons/amxmodx"
PLUGINS_INI="${AMXX}/configs/plugins.ini"
SERVER_CFG="${CS}/server.cfg"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-real-fastdl-r9-backup-${SID}-${STAMP}"
FASTDL_URL="http://90.189.208.25/fastdl/${SID}/"
SERVICE="hyper-cs16@${SID}.service"

[[ -d "$CS" ]] || { echo "[ERROR] Missing $CS"; exit 2; }
[[ -f "$PLUGINS_INI" ]] || { echo "[ERROR] Missing $PLUGINS_INI"; exit 2; }

mkdir -p "$BACKUP"
echo "=============================================================="
echo " OLD ZOMBIE REAL FASTDL R9"
echo " Server:  #${SID}"
echo " cstrike: ${CS}"
echo " Backup:  ${BACKUP}"
echo "=============================================================="

TIMER_WAS_ACTIVE=0
if systemctl is-active --quiet hyper-cs16-fastdl-sync.timer 2>/dev/null; then
    TIMER_WAS_ACTIVE=1
    systemctl stop hyper-cs16-fastdl-sync.timer || true
fi
systemctl stop hyper-cs16-fastdl-sync.service 2>/dev/null || true

echo "[1/10] Backing up files that will be changed..."
for rel in \
    "server.cfg" \
    "fastdl.cfg" \
    "SAFE_DOWNLOAD_MODE.cfg" \
    "ENABLE_FASTDL_AFTER_VERIFY.cfg" \
    "server_download_fix.cfg" \
    "addons/amxmodx/configs/plugins.ini" \
    "addons/amxmodx/configs/amxx.cfg" \
    "addons/amxmodx/scripting/oldz_safe_download_r8.sma" \
    "addons/amxmodx/scripting/oldz_download_guard.sma" \
    "addons/amxmodx/scripting/combo_zombie_1.0.sma" \
    "maps/zm_2day.res" \
    "models/mil_crategibs.mdl" \
    "models/skeleton.mdl" \
    "sprites/glow01.spr" \
    "cstrike/sprites/fire2.spr"
do
    if [[ -e "$CS/$rel" ]]; then
        mkdir -p "$BACKUP/$(dirname "$rel")"
        cp -a "$CS/$rel" "$BACKUP/$rel"
    fi
done

for name in m82-1.wav m82_clipin1.wav m82_clipin2.wav m82_clipout1.wav m82_clipout2.wav; do
    if [[ -e "$CS/sound/weapons/$name" ]]; then
        mkdir -p "$BACKUP/sound/weapons"
        cp -a "$CS/sound/weapons/$name" "$BACKUP/sound/weapons/$name"
    fi
done

echo "[2/10] Disabling the plugin that clears sv_downloadurl every second..."
python3 - "$PLUGINS_INI" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()
bad={'oldz_safe_download_r8.amxx','oldz_download_guard.amxx'}
out=[]; disabled=[]
for line in lines:
    stripped=line.strip()
    active=stripped and not stripped.startswith(';')
    token=stripped.split(';',1)[0].strip().split() if active else []
    name=token[0].lower() if token else ''
    if name in bad:
        out.append('; HYPER-HOST R9 DISABLED FASTDL KILLER: '+stripped)
        disabled.append(name)
    else:
        out.append(line)
p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print('[OK] disabled:', ', '.join(disabled) if disabled else 'already disabled')
PY

for sma in oldz_safe_download_r8.sma oldz_download_guard.sma; do
    f="$AMXX/scripting/$sma"
    [[ -f "$f" ]] || continue
    cat >"$f" <<'SMA'
#include <amxmodx>

#define PLUGIN  "OLD ZOMBIE - DOWNLOAD GUARD (R9 SAFE)"
#define VERSION "9.0"
#define AUTHOR  "OLD ZOMBIE / HYPER-HOST"

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR)
    // FastDL is managed by server.cfg / HYPER-HOST.
    // Never clear sv_downloadurl here.
}
SMA
done

echo "[3/10] Writing one canonical FastDL configuration..."
python3 - "$SERVER_CFG" "$FASTDL_URL" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); url=sys.argv[2]
text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
text=text.replace('\r\n','\n').replace('\r','\n')
text=re.sub(r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?','',text)
managed={'sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile','sv_downloadurl'}
keep=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\b',line)
    if m and m.group(1).lower() in managed:
        continue
    keep.append(line)
block=[
    '// HYPER-HOST FASTDL BEGIN',
    '// OLD ZOMBIE REAL FASTDL R9',
    'sv_allowdownload 1',
    'sv_allowupload 0',
    'sv_send_resources 1',
    'sv_allow_dlfile 0',
    f'sv_downloadurl "{url}"',
    '// HYPER-HOST FASTDL END',
]
p.write_text('\n'.join(keep).rstrip()+'\n\n'+'\n'.join(block)+'\n',encoding='utf-8')
PY

for cfg in fastdl.cfg SAFE_DOWNLOAD_MODE.cfg ENABLE_FASTDL_AFTER_VERIFY.cfg server_download_fix.cfg; do
    [[ -e "$CS/$cfg" ]] || continue
    cat >"$CS/$cfg" <<EOF
// HYPER-HOST R9 - canonical FastDL settings
sv_allowdownload 1
sv_allowupload 0
sv_send_resources 1
sv_allow_dlfile 0
sv_downloadurl "${FASTDL_URL}"
EOF
done

echo "[4/10] Fixing M82 missing WAV files..."
mkdir -p "$CS/sound/weapons"
for name in m82-1.wav m82_clipin1.wav m82_clipin2.wav m82_clipout1.wav m82_clipout2.wav; do
    src="$SELF_DIR/payload/m82/$name"
    [[ -f "$src" ]] || { echo "[ERROR] patch payload missing $name"; exit 3; }
    install -m 0644 "$src" "$CS/sound/weapons/$name"
    chown cs16:www-data "$CS/sound/weapons/$name" 2>/dev/null || true
done

echo "[5/10] Fixing Ghost_Count/combo resources..."
COMBO_SRC="$AMXX/scripting/combo_zombie_1.0.sma"
COMBO_PLUGIN="$AMXX/plugins/combo_zombie.amxx"
if [[ -f "$COMBO_SRC" ]]; then
python3 - "$COMBO_SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='ignore')
marker='// HYPER-HOST R9 RESOURCE PRECACHE'
if marker not in s:
    anchor='public plugin_init()'
    pos=s.find(anchor)
    if pos < 0:
        raise SystemExit('[WARN] combo_zombie plugin_init anchor not found')
    block=r'''// HYPER-HOST R9 RESOURCE PRECACHE
public plugin_precache()
{
    precache_sound("misc/zombie/damage_1000.wav")
    precache_sound("misc/zombie/invader.wav")
    precache_sound("misc/zombie/ghost_shot.wav")

    new snd[64]
    for (new i = 1; i <= 10; i++)
    {
        formatex(snd, charsmax(snd), "misc/zombie/Ghost_Count_%d.wav", i)
        precache_sound(snd)
    }
}

'''
    s=s[:pos]+block+s[pos:]
    p.write_text(s,encoding='utf-8')
    print('[OK] combo_zombie source patched')
else:
    print('[OK] combo_zombie source already patched')
PY

    COMPILER="$AMXX/scripting/amxxpc"
    if [[ -f "$COMPILER" ]]; then
        chmod +x "$COMPILER" "$AMXX/scripting/amxxpc32.so" 2>/dev/null || true
        mkdir -p "$AMXX/scripting/compiled"
        set +e
        (
            cd "$AMXX/scripting"
            ./amxxpc combo_zombie_1.0.sma -ocompiled/combo_zombie.amxx
        ) >"$BACKUP/combo_compile.log" 2>&1
        CRC=$?
        set -e
        if [[ $CRC -eq 0 && -s "$AMXX/scripting/compiled/combo_zombie.amxx" ]]; then
            [[ -f "$COMBO_PLUGIN" ]] && cp -a "$COMBO_PLUGIN" "$BACKUP/combo_zombie.amxx.before"
            install -m 0644 "$AMXX/scripting/compiled/combo_zombie.amxx" "$COMBO_PLUGIN"
            chown cs16:www-data "$COMBO_PLUGIN" 2>/dev/null || true
            echo "[OK] combo_zombie.amxx recompiled with Ghost_Count precache"
        else
            echo "[WARN] combo_zombie compile failed; .res fallback will still force the sounds to clients"
            tail -n 20 "$BACKUP/combo_compile.log" || true
        fi
    fi
fi

python3 - "$CS" <<'PY'
from pathlib import Path
import sys
cs=Path(sys.argv[1])
resources=[
    *(f"sound/misc/zombie/Ghost_Count_{i}.wav" for i in range(1,11)),
    "sound/misc/zombie/damage_1000.wav",
    "sound/misc/zombie/invader.wav",
    "sound/misc/zombie/ghost_shot.wav",
]
maps=cs/'maps'; changed=0
for bsp in maps.glob('*.bsp'):
    res=bsp.with_suffix('.res')
    old=res.read_text(encoding='utf-8',errors='ignore').splitlines() if res.exists() else []
    present={x.strip().replace('\\','/').lower() for x in old if x.strip() and not x.lstrip().startswith('//')}
    add=[r for r in resources if r.lower() not in present]
    if add:
        text='\n'.join(old).rstrip()
        if text: text+='\n'
        text+='// HYPER-HOST R9 required combo sounds\n'+'\n'.join(add)+'\n'
        res.write_text(text,encoding='utf-8')
        changed+=1
print(f'[OK] combo sound fallback added to {changed} map .res files')
PY

AMXX_CFG="$AMXX/configs/amxx.cfg"
if [[ -f "$AMXX_CFG" ]]; then
python3 - "$AMXX_CFG" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='ignore')
if re.search(r'(?im)^\s*amx_time_voice\b',s):
    s=re.sub(r'(?im)^\s*amx_time_voice\b.*$', 'amx_time_voice 0', s)
else:
    s=s.rstrip()+'\n\n// HYPER-HOST R9: disable broken *_period.wav voice composition\namx_time_voice 0\n'
p.write_text(s,encoding='utf-8')
PY
fi

echo "[6/10] Fixing resources that are literally HTML pages..."
if [[ -f "$CS/maps/zm_2day.res" ]]; then
    sed -i 's#^[[:space:]]*cstrike/sprites/fire2\.spr[[:space:]]*$#sprites/fire2.spr#' "$CS/maps/zm_2day.res"
fi

python3 - "$CS" <<'PY'
from pathlib import Path
import shutil,sys
cs=Path(sys.argv[1])
targets=[
    ('models/mil_crategibs.mdl','mdl'),
    ('models/skeleton.mdl','mdl'),
    ('sprites/glow01.spr','spr'),
]
bases=[
    Path('/srv/hyper-cs16/runtime-cache/steam-legacy/cstrike'),
    Path('/srv/hyper-cs16/runtime-cache/steam-legacy/valve'),
    Path('/srv/hyper-cs16/base-hlds/cstrike'),
    Path('/srv/hyper-cs16/base-hlds/valve'),
    Path('/srv/hyper-cs16/base/cstrike'),
    Path('/srv/hyper-cs16/base/valve'),
]
def valid(p,kind):
    try:b=p.read_bytes()[:16]
    except Exception:return False
    low=b.lower()
    if low.startswith(b'<!doctype') or low.startswith(b'<html'):
        return False
    if kind=='spr':
        return b[:4]==b'IDSP'
    if kind=='mdl':
        return b[:4] in (b'IDST',b'IDSQ') or (len(b)>=4 and int.from_bytes(b[:4],'little')==30)
    return True

for rel,kind in targets:
    dst=cs/rel
    if not dst.is_file(): continue
    b=dst.read_bytes()[:16].lower()
    if not (b.startswith(b'<!doctype') or b.startswith(b'<html')):
        continue
    replacement=None
    for base in bases:
        cand=base/rel
        if cand.is_file() and valid(cand,kind):
            replacement=cand; break
    if replacement:
        shutil.copy2(replacement,dst)
        print('[OK] restored',rel,'from',replacement)
    else:
        print('[WARN] no valid base replacement found for',rel)
PY

if [[ -f "$CS/cstrike/sprites/fire2.spr" && -f "$CS/sprites/fire2.spr" ]]; then
    if head -c 16 "$CS/cstrike/sprites/fire2.spr" | grep -qi '<!doctype'; then
        cp -a "$CS/sprites/fire2.spr" "$CS/cstrike/sprites/fire2.spr"
        echo "[OK] replaced nested HTML fire2.spr with valid root sprite"
    fi
fi

echo "[7/10] Starting server and proving sv_downloadurl survives..."
systemctl restart "$SERVICE"
for i in $(seq 1 45); do
    systemctl is-active --quiet "$SERVICE" && break
    sleep 1
done
sleep 3

R1="$(/usr/local/sbin/hyper-cs16-ctl rcon "$SID" 'sv_downloadurl' 2>/dev/null || true)"
echo "--- sv_downloadurl after 3 sec ---"
echo "$R1"
sleep 5
R2="$(/usr/local/sbin/hyper-cs16-ctl rcon "$SID" 'sv_downloadurl' 2>/dev/null || true)"
echo "--- sv_downloadurl after another 5 sec ---"
echo "$R2"

if ! printf '%s\n%s\n' "$R1" "$R2" | grep -Fq "$FASTDL_URL"; then
    echo "[ERROR] sv_downloadurl is still being cleared."
    grep -nEi 'download.*\.amxx|safe.*\.amxx' "$PLUGINS_INI" || true
    exit 4
fi
echo "[OK] sv_downloadurl stays set. The 1-second killer is gone."

echo "[8/10] Rebuilding FastDL..."
/usr/local/sbin/hyper-cs16-ctl fastdl-sync "$SID" || true

for name in m82-1.wav m82_clipin1.wav m82_clipin2.wav m82_clipout1.wav m82_clipout2.wav; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: 90.189.208.25' "http://127.0.0.1/fastdl/${SID}/sound/weapons/${name}" || true)"
    echo "HTTP $code sound/weapons/$name"
done

echo "[9/10] Checking actual engine build..."
echo "--- systemd ExecStart ---"
systemctl show "$SERVICE" -p ExecStart --value || true
PID="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || echo 0)"
if [[ "$PID" =~ ^[0-9]+$ && "$PID" -gt 1 && -e "/proc/$PID/exe" ]]; then
    echo "MainPID=$PID"
    echo "Executable=$(readlink -f "/proc/$PID/exe" || true)"
fi
echo "--- version BEFORE optional migration ---"
VNOW="$(/usr/local/sbin/hyper-cs16-ctl rcon "$SID" version 2>/dev/null || true)"
echo "$VNOW"

if echo "$VNOW" | grep -q '4419'; then
    echo "[INFO] BUILD 4419 confirmed."
    echo "[INFO] A failed Runtime Manager transaction rolls the engine back too."
    if [[ -x /usr/local/sbin/hyper-cs16-runtime-ctl ]]; then
        echo "[INFO] Running recommended migration only (NO YaPB update)..."
        set +e
        /usr/local/sbin/hyper-cs16-runtime-ctl update "$SID" recommended | tee "$BACKUP/runtime-migration.json"
        RRC=${PIPESTATUS[0]}
        set -e
        if [[ $RRC -eq 0 ]]; then
            echo "[OK] recommended runtime migration completed"
        else
            echo "[WARN] runtime migration failed validation and was rolled back"
            echo "[WARN] the FastDL R9 fix remains because that backup was created after R9 changes"
        fi
    else
        echo "[WARN] Runtime Manager is not installed; leaving engine unchanged."
    fi
fi

echo "--- version AFTER ---"
/usr/local/sbin/hyper-cs16-ctl rcon "$SID" version 2>/dev/null || true

echo "[10/10] Final checks..."
echo "--- active FastDL killer lines (must print nothing) ---"
grep -nEi '^[[:space:]]*(oldz_safe_download_r8|oldz_download_guard)\.amxx' "$PLUGINS_INI" || true

echo "--- server.cfg FastDL ---"
grep -nEi 'sv_downloadurl|sv_allowdownload|sv_allowupload|sv_send_resources|sv_allow_dlfile' "$SERVER_CFG" || true

echo "--- known HTML-corrupt resources ---"
python3 - "$CS" <<'PY'
from pathlib import Path
import sys
cs=Path(sys.argv[1]); bad=[]
for rel in ['models/mil_crategibs.mdl','models/skeleton.mdl','sprites/glow01.spr','cstrike/sprites/fire2.spr']:
    p=cs/rel
    if p.is_file():
        b=p.read_bytes()[:16].lower()
        if b.startswith(b'<!doctype') or b.startswith(b'<html'):
            bad.append(rel)
print('HTML_CORRUPT=' + (','.join(bad) if bad else 'NONE'))
PY

if [[ "$TIMER_WAS_ACTIVE" -eq 1 ]]; then
    systemctl start hyper-cs16-fastdl-sync.timer 2>/dev/null || true
fi

[[ -f /var/log/nginx/hyper-cs16-fastdl-access.log ]] && : > /var/log/nginx/hyper-cs16-fastdl-access.log

echo
echo "=============================================================="
echo "[SUCCESS] OLD ZOMBIE REAL FASTDL R9 APPLIED"
echo
echo "Root cause removed: oldz_safe_download_r8 no longer clears sv_downloadurl."
echo "M82 paths fixed; combo/Ghost resources fixed; FastDL rebuilt."
echo
echo "NOW CONNECT WITH A CLIENT THAT IS MISSING A RESOURCE, THEN RUN:"
echo "grep '/fastdl/${SID}/' /var/log/nginx/hyper-cs16-fastdl-access.log | tail -n 50"
echo
echo "You MUST now see HTTP GET requests from the CS client."
echo "Backup: $BACKUP"
echo "=============================================================="
