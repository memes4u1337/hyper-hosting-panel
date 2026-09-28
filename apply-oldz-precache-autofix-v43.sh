#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
LIST="$UNP/list.ini"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-precache-autofix-v43-${STAMP}"
MAX_TRIES=80

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing Ultimate Unprecacher binary"
[[ -f "$LIST" ]] || fail "missing $LIST"
[[ -f "$META" ]] || fail "missing $META"
[[ -x "$LIVE" ]] || fail "missing $LIVE"

mkdir -p "$BACKUP"
cp -a "$LIST" "$BACKUP/list.ini.before"
cp -a "$META" "$BACKUP/metamod-plugins.before.ini"

echo "================================================================"
echo " OLD ZOMBIE PRECACHE AUTO-FIX FINAL v43"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " AMXX plugins/FastDL/SQL/Admins: NOT MODIFIED"
echo "================================================================"

echo "[1/4] Normalize current Ultimate Unprecacher list..."
python3 - "$LIST" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
out=[]
seen=set()

for line in p.read_text(encoding='utf-8',errors='ignore').splitlines():
    s=line.strip()
    if not s or s.startswith(('//','#',';')):
        continue
    token=s.split()[0].strip().strip('"').strip("'").replace('\\','/')
    if token.lower().startswith('sound/'):
        token=token[6:]
    if not token:
        continue
    low=token.lower()
    if low in seen:
        continue
    seen.add(low)
    out.append(token)

header=[
    '// OLD ZOMBIE v43',
    '// AUTO-GENERATED precache safety list.',
    '// Existing entries preserved. Crash-causing resources are appended automatically.',
    '// Raw paths, NO quotes.',
]
p.write_text('\n'.join(header+out)+'\n',encoding='utf-8')
print('existing entries:',len(out))
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

append_resource() {
    local resource="$1"
    python3 - "$LIST" "$resource" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
resource=sys.argv[2].strip().replace('\\','/')

if resource.lower().startswith('sound/'):
    resource=resource[6:]

lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()
existing=set()

for line in lines:
    s=line.strip()
    if not s or s.startswith(('//','#',';')):
        continue
    token=s.split()[0].strip().strip('"').strip("'").replace('\\','/')
    if token.lower().startswith('sound/'):
        token=token[6:]
    existing.add(token.lower())

if resource.lower() not in existing:
    with p.open('a',encoding='utf-8') as f:
        f.write(resource+'\n')
    print('ADDED:',resource)
else:
    print('ALREADY PRESENT:',resource)
PY
}

extract_latest_resource() {
    local log="$1"
    python3 - "$log" <<'PY'
from pathlib import Path
import re,sys

txt=Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore')

patterns=[
    r"PF_precache_sound_I_internal:\s*Sound\s+'([^']+)'\s+failed to precache because the item count is over the 512 limit",
    r'PF_precache_sound_I_internal:\s*Sound\s+"([^"]+)"\s+failed to precache because the item count is over the 512 limit',
    r"PF_precache_model_I_internal:\s*Model\s+'([^']+)'\s+failed to precache because the item count is over the 512 limit",
    r'PF_precache_model_I_internal:\s*Model\s+"([^"]+)"\s+failed to precache because the item count is over the 512 limit',
]

hits=[]
for pat in patterns:
    hits += re.findall(pat,txt,re.I)

print(hits[-1] if hits else '')
PY
}

echo "[3/4] Auto-heal precache overflow until server starts..."

for n in $(seq 1 "$MAX_TRIES"); do
    echo
    echo "----- attempt $n/$MAX_TRIES -----"

    START_TS="$(date '+%Y-%m-%d %H:%M:%S')"

    systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
    systemctl restart "hyper-cs16@${SID}.service" || true
    sleep 4

    LOGFILE="/tmp/oldz-v43-${SID}-${n}.log"
    journalctl -u "hyper-cs16@${SID}.service" --since "$START_TS" --no-pager > "$LOGFILE" || true

    # If engine is alive and answering, we're done.
    STATUS="$("$LIVE" status "$SID" 2>/dev/null || true)"
    echo "$STATUS"

    if systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
        if echo "$STATUS" | grep -q '"running":true'; then
            if ! grep -qiE 'PF_precache_(sound|model)_I_internal.*over the 512 limit' "$LOGFILE"; then
                echo "Server started without precache overflow."
                rm -f "$LOGFILE"
                break
            fi
        fi
    fi

    if grep -qiE 'PF_precache_(sound|model)_I_internal.*over the 512 limit' "$LOGFILE"; then
        RESOURCE="$(extract_latest_resource "$LOGFILE")"
        if [[ -z "$RESOURCE" ]]; then
            echo "[ERROR] Found 512-limit crash but could not parse resource."
            tail -n 80 "$LOGFILE"
            exit 20
        fi

        echo "512-limit resource: $RESOURCE"
        append_resource "$RESOURCE"
        rm -f "$LOGFILE"
        continue
    fi

    echo "[ERROR] Server failed for a reason other than the 512 precache limit."
    tail -n 120 "$LOGFILE"
    exit 21

    if [[ "$n" -eq "$MAX_TRIES" ]]; then
        fail "maximum auto-fix attempts reached"
    fi
done

echo "[4/4] Final verification..."
sleep 2

FINAL="$("$LIVE" status "$SID" 2>/dev/null || true)"
echo "$FINAL"

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo "[ERROR] server service is not active"
    journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager || true
    exit 30
fi

if ! echo "$FINAL" | grep -q '"running":true'; then
    echo "[ERROR] controller does not report running=true"
    journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager || true
    exit 31
fi

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-10 seconds" --no-pager || true)"
if echo "$RECENT" | grep -qiE 'PF_precache_(sound|model)_I_internal.*over the 512 limit'; then
    echo "[ERROR] precache overflow still exists"
    echo "$RECENT" | grep -Ei 'PF_precache|512 limit|Host_Error|FATAL ERROR' | tail -n 30
    exit 32
fi

echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- UNPRECACHER ENTRY COUNT ---"
python3 - "$LIST" <<'PY'
from pathlib import Path
import sys
n=0
for line in Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore').splitlines():
    s=line.strip()
    if s and not s.startswith(('//','#',';')):
        n+=1
print(n)
PY

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE PRECACHE AUTO-FIX v43"
echo "================================================================"
echo " Server: ACTIVE"
echo " 512 precache crash: CLEARED"
echo " Ultimate Unprecacher: FIRST in Metamod"
echo " AMXX plugin list: UNCHANGED"
echo " FastDL/SQL/Admins: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
