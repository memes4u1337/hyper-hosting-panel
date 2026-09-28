#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
LIST="$UNP/list.ini"
META="$CSTRIKE/addons/metamod/plugins.ini"
YAPB="$CSTRIKE/addons/yapb/bin/yapb.so"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-v47-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$LIST" ]] || fail "missing $LIST"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing Ultimate Unprecacher"
[[ -f "$META" ]] || fail "missing $META"
[[ -f "$YAPB" ]] || fail "missing YaPB binary: $YAPB"
[[ -x "$LIVE" ]] || fail "missing $LIVE"

mkdir -p "$BACKUP"
cp -a "$LIST" "$BACKUP/list.ini.before"
cp -a "$META" "$BACKUP/plugins.ini.before"

echo "================================================================"
echo " OLD ZOMBIE FINAL FIX v47"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Controller/FastDL/SQL/Admins/AMXX plugins: NOT MODIFIED"
echo "================================================================"

echo "[1/4] Add full stock debris/doors reserve to Unprecacher..."
python3 - "$LIST" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])

existing=[]
seen=set()

for line in p.read_text(encoding='utf-8',errors='ignore').splitlines():
    s=line.strip()
    if not s or s.startswith(('//','#',';')):
        continue
    token=s.split()[0].strip().strip('"').strip("'").replace('\\','/')
    if token.lower().startswith('sound/'):
        token=token[6:]
    if token and token.lower() not in seen:
        seen.add(token.lower())
        existing.append(token)

extra=[]

# GoldSrc stock debris families. Extra non-existent names are harmless:
# Ultimate Unprecacher only matches resources if the engine actually precaches them.
for stem in (
    'bustcrate','bustconcrete','bustflesh','bustglass','bustmetal',
    'busttile','bustwood','concrete','glass','metal','pushbox',
    'wood','beamstart','beamstart2'
):
    for n in range(1,21):
        extra.append(f'debris/{stem}{n}.wav')

# GoldSrc/CS stock door families.
for stem in (
    'doorstop','doormove','latchlocked','latchunlocked',
    'locked','unlocked'
):
    for n in range(1,21):
        extra.append(f'doors/{stem}{n}.wav')

# Geiger family already caused a crash earlier.
for n in range(1,31):
    extra.append(f'player/geiger{n}.wav')

# Exact resources already seen in this server's crash logs.
extra += [
    'debris/bustcrate2.wav',
    'debris/concrete2.wav',
    'debris/concrete3.wav',
    'debris/pushbox1.wav',
    'debris/pushbox2.wav',
    'debris/pushbox3.wav',
    'doors/doorstop5.wav',
]

added=[]
for token in extra:
    low=token.lower()
    if low in seen:
        continue
    seen.add(low)
    existing.append(token)
    added.append(token)

header=[
    '// OLD ZOMBIE FINAL v47',
    '// Stable precache reserve for heavy Zombie maps.',
    '// Existing entries preserved.',
    '// Stock debris/doors/geiger families blocked before they consume sound slots.',
    '// Raw paths, NO quotes.',
]

p.write_text('\n'.join(header+existing)+'\n',encoding='utf-8')

print('total entries:',len(existing))
print('new entries:',len(added))

for required in (
    'debris/pushbox1.wav',
    'debris/pushbox2.wav',
    'debris/pushbox3.wav',
    'doors/doorstop5.wav',
    'player/geiger3.wav',
):
    if required.lower() not in seen:
        raise SystemExit('missing required entry: '+required)
    print('OK:',required)
PY

echo "[2/4] Force clean ACTIVE Metamod chain with YaPB..."
python3 - "$META" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()

# Remove every active/commented occurrence of managed runtime lines,
# including '; HYPER-HOST auto-recovery: linux addons/yapb/...'
keys=('unprecacher','amxmodx_mm_i386.so','reunion_mm_i386.so','yapb')
other=[]
for line in lines:
    low=line.lower()
    if any(k in low for k in keys):
        continue
    if line.strip():
        other.append(line)

active=[
    'linux addons/unprecacher/unprecacher_mm_i386.so',
    'linux addons/amxmodx/dlls/amxmodx_mm_i386.so',
    'linux addons/reunion/reunion_mm_i386.so',
    'linux addons/yapb/bin/yapb.so',
]

text='\n'.join(active + (['']+other if other else []))+'\n'
p.write_text(text,encoding='utf-8')

check=p.read_text(encoding='utf-8',errors='ignore').splitlines()
active_yapb=[x for x in check if x.strip().lower()=='linux addons/yapb/bin/yapb.so']
if len(active_yapb)!=1:
    raise SystemExit('YaPB active line verification failed')

if check[0].strip().lower()!='linux addons/unprecacher/unprecacher_mm_i386.so':
    raise SystemExit('Unprecacher is not first')

print(p.read_text(encoding='utf-8'))
PY

echo "[3/4] Restart server once..."
START="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service" || true

echo "[4/4] Verify startup..."
OK=0
STATUS=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    STATUS="$("$LIVE" status "$SID" 2>/dev/null || true)"
    if echo "$STATUS" | grep -q '"running":true' \
       && echo "$STATUS" | grep -q '"udp_listening":true' \
       && echo "$STATUS" | grep -q '"query_ok":true'; then
        OK=1
        break
    fi
done

echo "$STATUS"

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "$START" --no-pager || true)"

if [[ "$OK" -ne 1 ]]; then
    echo "[ERROR] server did not become ready"
    echo "$RECENT" | tail -n 180
    exit 20
fi

if echo "$RECENT" | grep -qiE 'PF_precache_(sound|model)_I_internal.*over the 512 limit'; then
    echo "[ERROR] a NEW 512-limit resource still appeared"
    echo "$RECENT" | grep -Ei 'PF_precache|512 limit|Host_Error|FATAL ERROR' | tail -n 30
    exit 21
fi

META_OUT="$("$LIVE" rcon "$SID" "meta list" 2>&1 || true)"
echo "--- META LIST ---"
echo "$META_OUT"

if ! echo "$META_OUT" | grep -qi 'YaPB'; then
    echo "[ERROR] YaPB did not load"
    exit 22
fi

echo "--- YAPB ---"
"$LIVE" rcon "$SID" "yb version" || true
"$LIVE" rcon "$SID" "yb_quota" || true
"$LIVE" rcon "$SID" "yb_quota_mode" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FINAL v47"
echo "================================================================"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " YaPB: ACTIVE"
echo " 512 sound reserve: INSTALLED"
echo " Controller/FastDL/SQL/Admins/AMXX plugins: UNCHANGED"
echo " Backup: $BACKUP"
echo "================================================================"
