#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
LIST="$UNP/list.ini"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-stable-v46-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$LIST" ]] || fail "missing $LIST"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing Ultimate Unprecacher"
[[ -f "$META" ]] || fail "missing $META"
[[ -x "$LIVE" ]] || fail "missing $LIVE"

mkdir -p "$BACKUP"
cp -a "$LIST" "$BACKUP/list.ini.before"
cp -a "$META" "$BACKUP/plugins.ini.before"

echo "================================================================"
echo " OLD ZOMBIE FINAL STABLE FIX v46"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Controller/FastDL/SQL/Admins/AMXX plugins/YaPB config: NOT MODIFIED"
echo "================================================================"

echo "[1/4] Free a real precache reserve in one pass..."
python3 - "$CSTRIKE" "$LIST" <<'PY'
from pathlib import Path
import sys

cstrike=Path(sys.argv[1])
dst=Path(sys.argv[2])

existing=[]
seen=set()

for line in dst.read_text(encoding='utf-8',errors='ignore').splitlines():
    s=line.strip()
    if not s or s.startswith(('//','#',';')):
        continue
    token=s.split()[0].strip().strip('"').strip("'").replace('\\','/')
    if token.lower().startswith('sound/'):
        token=token[6:]
    if token and token.lower() not in seen:
        seen.add(token.lower())
        existing.append(token)

# Only low-value stock/environment sound groups.
# Do NOT touch custom Zombie weapon/model sounds.
roots=[
    'debris',
    'doors',
    'ambience',
    'plats',
]

added=[]

for root_name in roots:
    root=cstrike/'sound'/root_name
    if not root.is_dir():
        continue
    for p in sorted(root.rglob('*.wav')):
        rel=p.relative_to(cstrike/'sound').as_posix()
        low=rel.lower()
        if low not in seen:
            seen.add(low)
            existing.append(rel)
            added.append(rel)

# Stock Geiger sounds are also expendable and already caused one crash.
for i in range(1,31):
    rel=f'player/geiger{i}.wav'
    if rel.lower() not in seen:
        seen.add(rel.lower())
        existing.append(rel)
        added.append(rel)

# Explicit resources already observed in crash logs, in case a stock directory
# is absent from the local loose-file tree.
for rel in (
    'debris/bustcrate2.wav',
    'debris/concrete2.wav',
    'debris/concrete3.wav',
    'debris/pushbox1.wav',
    'doors/doorstop5.wav',
):
    if rel.lower() not in seen:
        seen.add(rel.lower())
        existing.append(rel)
        added.append(rel)

header=[
    '// OLD ZOMBIE FINAL v46',
    '// Stable precache reserve for heavy ZM maps.',
    '// Existing entries preserved.',
    '// Only stock environment/debris/door/plat/geiger sounds added.',
    '// Raw paths, NO quotes.',
]

dst.write_text('\n'.join(header+existing)+'\n',encoding='utf-8')

print('existing+new entries:',len(existing))
print('new reserve entries:',len(added))
for x in added[:80]:
    print(' +',x)
if len(added)>80:
    print(' ...',len(added)-80,'more')
PY

echo "[2/4] Keep Ultimate Unprecacher first, preserve YaPB..."
python3 - "$META" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()

unp='linux addons/unprecacher/unprecacher_mm_i386.so'
body=[ln for ln in lines if 'unprecacher' not in ln.lower()]
p.write_text(unp+'\n'+'\n'.join(body).strip()+'\n',encoding='utf-8')

txt=p.read_text(encoding='utf-8',errors='ignore')
if 'addons/yapb/bin/yapb.so' not in txt.lower():
    raise SystemExit('YaPB line disappeared; refusing to continue')

print(txt)
PY

echo "[3/4] Restart once..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"

echo "[4/4] Verify PROCESS + UDP + A2S + YaPB..."
OK=0
STATUS=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
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

if [[ "$OK" -ne 1 ]]; then
    echo "[ERROR] server did not become PROCESS+UDP+A2S ready"
    journalctl -u "hyper-cs16@${SID}.service" -n 180 --no-pager || true
    exit 20
fi

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-20 seconds" --no-pager || true)"
if echo "$RECENT" | grep -qiE 'PF_precache_(sound|model)_I_internal.*over the 512 limit'; then
    echo "[ERROR] 512 limit is still present"
    echo "$RECENT" | grep -Ei 'PF_precache|512 limit|Host_Error|FATAL ERROR' | tail -n 30
    exit 21
fi

META_OUT="$("$LIVE" rcon "$SID" "meta list" 2>&1 || true)"
echo "--- META LIST ---"
echo "$META_OUT"

if ! echo "$META_OUT" | grep -qi "YaPB"; then
    echo "[ERROR] YaPB not loaded"
    exit 22
fi

echo "--- YAPB ---"
"$LIVE" rcon "$SID" "yb_quota" || true
"$LIVE" rcon "$SID" "yb_quota_mode" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FINAL STABLE v46"
echo "================================================================"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " YaPB: LOADED"
echo " 512 precache overflow: CLEARED"
echo " Controller/map switching: UNCHANGED"
echo " FastDL/SQL/Admins/AMXX plugins: UNCHANGED"
echo " Backup: $BACKUP"
echo "================================================================"
