#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-unprecacher-v27-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$UNP" ]] || fail "missing $UNP"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing unprecacher binary"
[[ -f "$UNP/list.ini" ]] || fail "missing $UNP/list.ini"
[[ -f "$META" ]] || fail "missing $META"

mkdir -p "$BACKUP"
cp -a "$UNP" "$BACKUP/unprecacher.before"
cp -a "$META" "$BACKUP/metamod-plugins.before.ini"

echo "================================================================"
echo " OLD ZOMBIE UNPRECACHER FIX v27"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Plugins: NOT CHANGED"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Write exact Unprecacher config.ini..."
cat > "$UNP/config.ini" <<'EOF'
// OLD ZOMBIE - Unprecacher config
// a - Debug
// b - Info
// c - Warning
// d - Error
// e - CriticalError
logger_verbosity = bcde

// 0 - No output
// 1 - Console
// 2 - File
// 3 - Both
logger_output = 3

// a - Set model
// b - Precache sound
// c - Precache model
// d - Emit sound
// e - Emit ambient sound
// f - Model index
module_checks = abcdef
EOF

echo "[2/5] Normalize list.ini for SOUND precache blocking..."
python3 - "$UNP/list.ini" <<'PY'
from pathlib import Path
import sys,re

p=Path(sys.argv[1])
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
out=[]
seen=set()

for line in lines:
    s=line.strip()
    if not s:
        continue
    if s.startswith("//") or s.startswith("#") or s.startswith(";"):
        continue

    # Keep first token only: for plain unprecache no flags are required.
    token=s.split()[0].strip().strip('"').strip("'").replace("\\","/")
    if not token.lower().endswith(".wav"):
        continue

    # PrecacheSound receives paths relative to sound/, e.g. weapons/foo.wav.
    if token.lower().startswith("sound/"):
        token=token[6:]

    low=token.lower()
    if low in seen:
        continue
    seen.add(low)
    out.append(f'"{token}"')

header=[
    "// OLD ZOMBIE v27",
    "// Plain WAV path = block its precache/use.",
    "// Paths are relative to cstrike/sound/.",
]
p.write_text("\n".join(header+out)+"\n",encoding="utf-8")

print("sound entries:",len(out))
for x in out[:30]:
    print(" ",x)
if len(out)<100:
    raise SystemExit("too few sound entries in list.ini")
PY

echo "[3/5] Ensure Unprecacher is first Metamod plugin..."
python3 - "$META" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
needle="linux addons/unprecacher/unprecacher_mm_i386.so"
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
lines=[x for x in lines if "unprecacher" not in x.lower()]
p.write_text(needle+"\n"+("\n".join(lines).strip())+"\n",encoding="utf-8")
print(p.read_text(encoding="utf-8"))
PY

echo "[4/5] Start full server..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

echo "--- STATUS ---"
"$LIVE" status "$SID" || true

echo "--- LAST START ERRORS ---"
journalctl -u "hyper-cs16@${SID}.service" --since "-15 seconds" --no-pager | \
  grep -Ei 'unprecach|precache|fatal|host_error|segv|runtime_error|cannot open|error' || true

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo
    echo "[ERROR] server is not active"
    journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager || true
    exit 1
fi

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-15 seconds" --no-pager || true)"
if echo "$RECENT" | grep -qiE 'over the 512 limit|PF_precache_sound_I_internal'; then
    echo
    echo "[ERROR] sound precache limit still present"
    echo "$RECENT" | grep -iE 'precache|512 limit|fatal' | tail -n 30
    exit 2
fi

echo "[5/5] Verify full plugin set..."
echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- AMXX PLUGINS ---"
"$LIVE" rcon "$SID" "amxx plugins" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE v27"
echo "================================================================"
echo "Unprecacher config.ini: OK"
echo "Unprecacher list.ini:   normalized"
echo "Server:                 ACTIVE"
echo "94-plugin config:       NOT CHANGED"
echo "FastDL/nginx/site:      NOT MODIFIED"
echo "Backup: $BACKUP"
echo "================================================================"
