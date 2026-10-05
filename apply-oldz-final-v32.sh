#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl"
[[ -x "$LIVE" ]] || LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-v32-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing $UNP/unprecacher_mm_i386.so"
[[ -f "$META" ]] || fail "missing $META"

mkdir -p "$BACKUP"
cp -a "$UNP" "$BACKUP/unprecacher.before" 2>/dev/null || true
cp -a "$META" "$BACKUP/metamod-plugins.before.ini"

echo "================================================================"
echo " OLD ZOMBIE FINAL v32 - PRECACHE HARD FIX"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " AMXX/DELUX plugins: NOT DISABLED"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Configure Ultimate Unprecacher..."
cat > "$UNP/config.ini" <<'EOF'
// OLD ZOMBIE v32
logger_verbosity = bcde
logger_output = 3
module_checks = abcdef
EOF

echo "[2/5] Add unused STOCK CS sounds to list.ini..."

python3 - "$CSTRIKE" "$UNP/list.ini" <<'PY'
from pathlib import Path
import sys,re

cstrike=Path(sys.argv[1])
p=Path(sys.argv[2])

existing=[]
if p.exists():
    for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        s=line.strip()
        if not s or s.startswith(("//","#",";")):
            continue
        s=s.strip().strip('"').strip("'").replace("\\","/")
        token=s.split()[0]
        if token.lower().startswith("sound/"):
            token=token[6:]
        if token:
            existing.append(token)

# Entire stock-only sound folders are safe to sacrifice on this Zombie server.
# Do NOT sweep sound/weapons: custom DELUX/VIP weapons often live there.
scan_dirs = [
    "common",
    "buttons",
    "plats",
    "doors",
    "debris",
    "hostage",
    "radio",
    "ambience",
    "events",
]

stock=[]
sound_root=cstrike/"sound"
for d in scan_dirs:
    base=sound_root/d
    if not base.is_dir():
        continue
    for f in base.rglob("*.wav"):
        try:
            rel=f.relative_to(sound_root).as_posix()
        except Exception:
            continue
        stock.append(rel)

# Stock player sounds: pain/death/wade/land/step-related.
player_dir=sound_root/"player"
player_patterns = [
    re.compile(r"^pl_.*\.wav$",re.I),
    re.compile(r"^death\d*\.wav$",re.I),
    re.compile(r"^die\d*\.wav$",re.I),
    re.compile(r"^headshot\d*\.wav$",re.I),
    re.compile(r"^bhit_.*\.wav$",re.I),
    re.compile(r"^sprayer\.wav$",re.I),
]
if player_dir.is_dir():
    for f in player_dir.glob("*.wav"):
        if any(rx.match(f.name) for rx in player_patterns):
            stock.append("player/"+f.name)

# Exact boundary sounds already seen on this server.
stock += [
    "plats/train_use1.wav",
    "common/wpn_moveselect.wav",
    "player/pl_wade2.wav",
    "player/pl_pain1.wav",
    "player/pl_pain2.wav",
    "player/pl_pain3.wav",
    "player/pl_pain4.wav",
    "player/pl_pain5.wav",
    "player/pl_pain6.wav",
    "player/pl_pain7.wav",
    "buttons/button11.wav",
    "weapons/ric_conc-1.wav",
    "weapons/ric_conc-2.wav",
    "weapons/ric_metal-1.wav",
    "weapons/ric_metal-2.wav",
    "weapons/ric1.wav",
    "weapons/ric2.wav",
    "weapons/ric3.wav",
    "weapons/ric4.wav",
    "weapons/ric5.wav",
]

seen=set()
out=[]
for x in existing+stock:
    x=x.strip().replace("\\","/")
    low=x.lower()
    if not x or low in seen:
        continue
    seen.add(low)
    out.append(x)

header=[
    "// OLD ZOMBIE v32",
    "// Ultimate Unprecacher raw paths, no quotes.",
    "// Keeps custom DELUX weapon directories untouched.",
    "// Frees GoldSrc precache slots by removing stock CS sounds not needed for ZM.",
]
p.write_text("\n".join(header+out)+"\n",encoding="utf-8")

print("total unprecache entries:",len(out))
print("new/current stock candidates:",len(set(x.lower() for x in stock)))
for critical in [
    "plats/train_use1.wav",
    "common/wpn_moveselect.wav",
    "player/pl_pain4.wav",
    "player/pl_wade2.wav",
    "buttons/button11.wav",
]:
    print(critical, "=", critical.lower() in seen)
PY

echo "[3/5] Rebuild Metamod chain with REAL newlines + YaPB enabled..."
cat > "$META" <<'EOF'
linux addons/unprecacher/unprecacher_mm_i386.so
linux addons/reunion/reunion_mm_i386.so
linux addons/amxmodx/dlls/amxmodx_mm_i386.so
linux addons/yapb/bin/yapb.so
EOF
chown cs16:www-data "$META" 2>/dev/null || true
chmod 0664 "$META"

cat -A "$META"

echo "[4/5] Restart server once..."
systemctl stop "hyper-cs16@${SID}.service" || true
systemctl reset-failed "hyper-cs16@${SID}.service" || true
systemctl start "hyper-cs16@${SID}.service"
sleep 4

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-15 seconds" --no-pager || true)"

echo "--- PRECACHE/FATAL CHECK ---"
echo "$RECENT" | grep -Ei 'Ultimate Unprecacher|PF_precache|512 limit|Host_Error|FATAL ERROR|segv|core-dump' || true

if echo "$RECENT" | grep -qiE 'PF_precache_sound_I_internal|over the 512 limit'; then
    echo
    echo "[ERROR] 512 limit is STILL present."
    echo "[NEXT OFFENDING RESOURCE]"
    echo "$RECENT" | grep -Ei 'PF_precache|512 limit|Host_Error|FATAL ERROR' | tail -n 8
    exit 2
fi

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo "[ERROR] server exited"
    journalctl -u "hyper-cs16@${SID}.service" -n 100 --no-pager
    exit 3
fi

echo "[5/5] Final runtime..."
"$LIVE" status "$SID" || true

echo "--- META LOAD ---"
echo "$RECENT" | grep -Ei "Found [0-9]+ plugins to load|Loaded plugin 'Reunion'|Loaded plugin 'AMX Mod X'|Loaded plugin 'YaPB'" || true

echo "--- DELUX ERRORS ---"
echo "$RECENT" | grep -Ei 'oldz_delux|unknown function|get_bak47p|give_weapon_m95' || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE v32"
echo " Server is ACTIVE and 512 precache crash is gone."
echo " DELUX plugins were not disabled."
echo " YaPB is enabled in Metamod."
echo " Backup: $BACKUP"
echo "================================================================"
