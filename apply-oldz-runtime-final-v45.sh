#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"

CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"
META="$CSTRIKE/addons/metamod/plugins.ini"
MODULES="$CSTRIKE/addons/amxmodx/configs/modules.ini"
YAPB_SO="$CSTRIKE/addons/yapb/bin/yapb.so"
YAPB_CFG="$CSTRIKE/addons/yapb/conf/yapb.cfg"
STATE="/var/lib/hyper-cs16/servers/$SID.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-runtime-final-v45-${STAMP}"
PATCH="/tmp/oldz-v45-map.py"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing controller: $CTL"
[[ -d "$CSTRIKE" ]] || fail "missing cstrike: $CSTRIKE"
[[ -f "$META" ]] || fail "missing metamod/plugins.ini"
[[ -f "$YAPB_SO" ]] || fail "YaPB binary missing: $YAPB_SO"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true
cp -a "$META" "$BACKUP/metamod-plugins.before.ini"
cp -a "$MODULES" "$BACKUP/modules.before.ini" 2>/dev/null || true
cp -a "$YAPB_CFG" "$BACKUP/yapb.before.cfg" 2>/dev/null || true
cp -a "$STATE" "$BACKUP/state.before.json" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE RUNTIME FINAL v45"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " FastDL/SQL/Admin data/AMXX plugin list/Unprecacher list: NOT MODIFIED"
echo "================================================================"

echo "[1/7] Fix map switching..."
printf '%s' 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgc3lzCgpwPVBhdGgoc3lzLmFyZ3ZbMV0pCnM9cC5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JyxlcnJvcnM9J3N0cmljdCcpCgpzdGFydD1zLmZpbmQoImRlZiBhY3RpdmF0ZV9tYXAoc2lkOmludCxtYXBfbmFtZTpzdHIpOiIpCmlmIHN0YXJ0IDwgMDoKICAgIHJhaXNlIFN5c3RlbUV4aXQoImFjdGl2YXRlX21hcCgpIG5vdCBmb3VuZCIpCmVuZD1zLmZpbmQoIlxuZGVmICIsIHN0YXJ0KzEwKQppZiBlbmQgPCAwOgogICAgZW5kPWxlbihzKQoKbmV3X2Z1bmMgPSAiIiJkZWYgYWN0aXZhdGVfbWFwKHNpZDppbnQsbWFwX25hbWU6c3RyKToKICAgIHJlcXVpcmVfcm9vdCgpCiAgICBjPWxvYWRfc2VydmVyKHNpZCkKCiAgICBpZiBub3QgU0FGRV9NQVAuZnVsbG1hdGNoKG1hcF9uYW1lKToKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ0ludmFsaWQgbWFwJykKCiAgICBic3A9UGF0aChjWydwYXRoJ10pLydjc3RyaWtlL21hcHMnLyhtYXBfbmFtZSsnLmJzcCcpCiAgICBpZiBub3QgYnNwLmlzX2ZpbGUoKToKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoZidNYXAgaXMgbm90IGluc3RhbGxlZCBvbiB0aGlzIHNlcnZlcjoge21hcF9uYW1lfScpCgogICAgX3BlcnNpc3Rfc3RhcnRfbWFwKGMsbWFwX25hbWUpCiAgICBkYl91cGRhdGVfY3VycmVudF9tYXAoc2lkLG1hcF9uYW1lKQoKICAgIHJ1bihbJ3N5c3RlbWN0bCcsJ3Jlc2V0LWZhaWxlZCcsZidoeXBlci1jczE2QHtzaWR9LnNlcnZpY2UnXSxjaGVjaz1GYWxzZSkKICAgIGNwPXJ1bihbJ3N5c3RlbWN0bCcsJy0tbm8tYmxvY2snLCdyZXN0YXJ0JyxmJ2h5cGVyLWNzMTZAe3NpZH0uc2VydmljZSddLGNoZWNrPUZhbHNlKQoKICAgIHJldHVybiB7CiAgICAgICAgJ29rJzpUcnVlLAogICAgICAgICdpZCc6c2lkLAogICAgICAgICdtYXAnOm1hcF9uYW1lLAogICAgICAgICdjdXJyZW50X21hcCc6bWFwX25hbWUsCiAgICAgICAgJ21vZGUnOidyZXN0YXJ0X25vX2Jsb2NrJywKICAgICAgICAnbG9hZGluZyc6VHJ1ZSwKICAgICAgICAnc2VydmljZV9yZXN0YXJ0X3JjJzppbnQoY3AucmV0dXJuY29kZSksCiAgICAgICAgJ21lc3NhZ2UnOidNYXAgc2VsZWN0ZWQuIFNlcnZlciBpcyByZXN0YXJ0aW5nIGRpcmVjdGx5IG9uIHRoZSBzZWxlY3RlZCBtYXAuJwogICAgfQoKIiIiCnM9c1s6c3RhcnRdK25ld19mdW5jK3NbZW5kOl0KcC53cml0ZV90ZXh0KHMsZW5jb2Rpbmc9J3V0Zi04JykKcHJpbnQoImFjdGl2YXRlX21hcCgpOiByZWxpYWJsZSBuby1ibG9jayByZXN0YXJ0IG1vZGUgaW5zdGFsbGVkIikK' | base64 -d > "$PATCH"
python3 -m py_compile "$PATCH"
python3 "$PATCH" "$CTL"
python3 -m py_compile "$CTL"

echo "[2/7] Restore Metamod chain with YaPB..."
python3 - "$META" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()

wanted=[
    ('unprecacher','linux addons/unprecacher/unprecacher_mm_i386.so'),
    ('amxmodx','linux addons/amxmodx/dlls/amxmodx_mm_i386.so'),
    ('reunion','linux addons/reunion/reunion_mm_i386.so'),
    ('yapb','linux addons/yapb/bin/yapb.so'),
]

out=[]
for line in lines:
    low=line.lower()
    if any(key in low for key,_ in wanted):
        continue
    if line.strip():
        out.append(line)

head=[entry for _,entry in wanted]
p.write_text('\n'.join(head + (['']+out if out else []))+'\n',encoding='utf-8')
print(p.read_text(encoding='utf-8'))
PY

echo "[3/7] Disable duplicate manual AMXX module loads..."
python3 - "$MODULES" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
if not p.exists():
    print("modules.ini absent: AMXX autoload only")
    raise SystemExit(0)

lines=p.read_text(encoding='utf-8',errors='ignore').splitlines()
out=[]
changed=[]
dupes={'cstrike','csx','mysql','cstrike_amxx_i386.so','csx_amxx_i386.so','mysql_amxx_i386.so'}

for line in lines:
    raw=line
    s=line.strip()
    if not s or s.startswith(';') or s.startswith('#') or s.startswith('//'):
        out.append(raw)
        continue
    token=s.split()[0].strip().lower()
    if token in dupes:
        out.append('; OLDZ v45 duplicate removed: '+raw)
        changed.append(token)
    else:
        out.append(raw)

p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print("disabled:",sorted(set(changed)))
PY

echo "[4/7] Configure YaPB..."
mkdir -p "$(dirname "$YAPB_CFG")"

read -r QUOTA DIFF < <(python3 - "$STATE" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    d={}
print(int(d.get('bots_quota') or 12), int(d.get('bots_difficulty') or 4))
PY
)

python3 - "$YAPB_CFG" "$QUOTA" "$DIFF" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
quota=max(0,min(int(sys.argv[2]),32))
diff=max(0,min(int(sys.argv[3]),4))
text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''

vals={
    'yb_quota':str(quota),
    'yb_quota_mode':'fill',
    'yb_difficulty':str(diff),
    'yb_join_after_player':'0',
    'yb_join_delay':'0.0',
    'yb_autovacate':'1',
    'yb_autovacate_keep_slots':'1',
    'yb_kick_after_player_connect':'1',
    'yb_graph_analyze_auto_start':'1',
    'yb_graph_analyze_auto_save':'1',
}

lines=text.splitlines()
used=set()
out=[]
for line in lines:
    m=re.match(r'^\s*(yb_[A-Za-z0-9_]+)\b',line,re.I)
    if m and m.group(1).lower() in vals:
        key=m.group(1).lower()
        if key not in used:
            out.append(f'{key} {vals[key]}')
            used.add(key)
        continue
    out.append(line)

for key,val in vals.items():
    if key not in used:
        out.append(f'{key} {val}')

p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print("YaPB quota:",quota,"difficulty:",diff)
PY

echo "[5/7] Install controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"
rm -f "$PATCH"

echo "[6/7] Restart server..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"

OK=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    ST="$("$LIVE" status "$SID" 2>/dev/null || true)"
    if echo "$ST" | grep -q '"running":true' && echo "$ST" | grep -q '"udp_listening":true' && echo "$ST" | grep -q '"query_ok":true'; then
        OK=1
        break
    fi
done

echo "[7/7] Final verification..."
STATUS="$("$LIVE" status "$SID" 2>/dev/null || true)"
echo "$STATUS"

if [[ "$OK" -ne 1 ]]; then
    echo "[ERROR] PROCESS/UDP/A2S not ready"
    journalctl -u "hyper-cs16@${SID}.service" -n 180 --no-pager || true
    exit 20
fi

echo "--- META LIST ---"
META_OUT="$("$LIVE" rcon "$SID" "meta list" 2>&1 || true)"
echo "$META_OUT"
echo "$META_OUT" | grep -qi "YaPB" || { echo "[ERROR] YaPB not loaded"; exit 21; }

echo "--- YAPB ---"
"$LIVE" rcon "$SID" "yb version" || true
"$LIVE" rcon "$SID" "yb_quota" || true
"$LIVE" rcon "$SID" "yb_quota_mode" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE RUNTIME FINAL v45"
echo "================================================================"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " YaPB: LOADED"
echo " Map switching: no-block restart on selected map"
echo " Panel timeout: REMOVED"
echo " FastDL/SQL/Admins/AMXX plugins/Unprecacher: PRESERVED"
echo " Backup: $BACKUP"
echo "================================================================"
