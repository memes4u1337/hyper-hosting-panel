#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-precache-v42-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing Ultimate Unprecacher binary"
[[ -f "$UNP/list.ini" ]] || fail "missing $UNP/list.ini"
[[ -f "$META" ]] || fail "missing $META"

mkdir -p "$BACKUP"
cp -a "$UNP/list.ini" "$BACKUP/list.ini.before"
cp -a "$META" "$BACKUP/metamod-plugins.before.ini"

echo "================================================================"
echo " OLD ZOMBIE PRECACHE LIMIT FIX v42"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " AMXX plugins/FastDL/SQL/Admins: NOT MODIFIED"
echo "================================================================"

echo "[1/4] Add safe stock player/geiger sounds to Ultimate Unprecacher..."
python3 - "$UNP/list.ini" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()

existing=[]
seen=set()
for line in lines:
    s=line.strip()
    if not s or s.startswith(('//','#',';')):
        continue
    token=s.split()[0].strip().strip('"').strip("'").replace('\\','/')
    if token.lower().startswith('sound/'):
        token=token[6:]
    low=token.lower()
    if low not in seen:
        seen.add(low)
        existing.append(token)

extra=[f'player/geiger{i}.wav' for i in range(1,31)]

added=[]
for token in extra:
    low=token.lower()
    if low not in seen:
        seen.add(low)
        existing.append(token)
        added.append(token)

header=[
    '// OLD ZOMBIE v42',
    '// Ultimate Unprecacher: raw resource paths, NO quotes.',
    '// Existing entries preserved; stock geiger sounds added.',
]
p.write_text('\n'.join(header+existing)+'\n',encoding='utf-8')

print('total entries:',len(existing))
print('added:',len(added))
print('player/geiger3.wav present:', 'player/geiger3.wav' in seen)
PY

echo "[2/4] Ensure Ultimate Unprecacher is FIRST in Metamod..."
python3 - "$META" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
needle='linux addons/unprecacher/unprecacher_mm_i386.so'
lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()
lines=[ln for ln in lines if 'unprecacher' not in ln.lower()]
body='\n'.join(lines).strip()
p.write_text(needle+'\n'+(body+'\n' if body else ''),encoding='utf-8')
print('first line:',p.read_text(encoding='utf-8').splitlines()[0])
PY

echo "[3/4] Restart server once..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"
sleep 5

echo "[4/4] Verify startup..."
RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-15 seconds" --no-pager || true)"

echo "--- STATUS ---"
"$LIVE" status "$SID" || true

echo "--- PRECACHE CHECK ---"
echo "$RECENT" | grep -Ei 'PF_precache|512 limit|Host_Error|FATAL ERROR|core-dump|segv' || true

if echo "$RECENT" | grep -qiE 'PF_precache_sound_I_internal|over the 512 limit'; then
    echo "[ERROR] 512 limit still present; latest failing resource:"
    echo "$RECENT" | grep -Ei 'PF_precache_sound_I_internal|over the 512 limit' | tail -n 5
    exit 2
fi

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo "[ERROR] server is not active"
    journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager || true
    exit 3
fi

echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE PREcache v42"
echo "================================================================"
echo " Server: ACTIVE"
echo " player/geiger3.wav: blocked by Ultimate Unprecacher"
echo " AMXX plugin list: UNCHANGED"
echo " FastDL/SQL/Admins: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
