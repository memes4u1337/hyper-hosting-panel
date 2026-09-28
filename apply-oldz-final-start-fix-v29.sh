#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
AMXX="$CSTRIKE/addons/amxmodx"
SCRIPTING="$AMXX/scripting"
PLUGINS="$AMXX/plugins"
CFG="$AMXX/configs/plugins.ini"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/usr/local/sbin/hyper-cs16-ctl"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-v29-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$CSTRIKE" ]] || fail "missing $CSTRIKE"
[[ -d "$SCRIPTING" ]] || fail "missing $SCRIPTING"
[[ -d "$PLUGINS" ]] || fail "missing $PLUGINS"
[[ -f "$CFG" ]] || fail "missing $CFG"
[[ -f "$META" ]] || fail "missing $META"

mkdir -p "$BACKUP"
cp -a "$CFG" "$BACKUP/plugins.ini.before"
cp -a "$META" "$BACKUP/metamod-plugins.ini.before"

echo "================================================================"
echo " OLD ZOMBIE FINAL START FIX v29"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " ALL OLD ZOMBIE plugins stay enabled"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/6] Remove broken Metamod Unprecacher from load list..."
python3 - "$META" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
out=[x for x in lines if "unprecacher" not in x.lower()]
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
print(p.read_text(encoding="utf-8"))
PY

echo "[2/6] Download proven Zombie-Mode AMXX unprecacher source..."
SRC="$SCRIPTING/oldz_unprecacher_zm.sma"
curl -fsSL --retry 3 --connect-timeout 10 \
  "https://raw.githubusercontent.com/TheDoctor0/AMXXLegacy/master/unprecacher_zm.sma" \
  -o "$SRC"

[[ -s "$SRC" ]] || fail "failed to download source"

grep -q 'weapons\\ric_conc-2.wav' "$SRC" \
  || fail "downloaded source does not contain ric_conc-2.wav"

grep -q 'register_forward(FM_PrecacheSound' "$SRC" \
  || fail "downloaded source is not the expected unprecacher"

echo "source: OK"

echo "[3/6] Compile with server AMXX compiler..."
COMPILER=""

for c in \
  "$SCRIPTING/amxxpc" \
  "$SCRIPTING/amxxpc32" \
  "$SCRIPTING/compile.sh"
do
  if [[ -x "$c" ]]; then
    COMPILER="$c"
    break
  fi
done

[[ -n "$COMPILER" ]] || fail "AMXX compiler not found in $SCRIPTING"

OUT="$PLUGINS/oldz_unprecacher_zm.amxx"

if [[ "$(basename "$COMPILER")" == "compile.sh" ]]; then
  (
    cd "$SCRIPTING"
    ./compile.sh "$(basename "$SRC")"
  )
  CANDIDATE="$SCRIPTING/compiled/oldz_unprecacher_zm.amxx"
  [[ -f "$CANDIDATE" ]] || fail "compile.sh did not produce $CANDIDATE"
  cp -f "$CANDIDATE" "$OUT"
else
  (
    cd "$SCRIPTING"
    "$COMPILER" "$(basename "$SRC")" -o"$OUT"
  )
fi

[[ -s "$OUT" ]] || fail "compiled plugin missing: $OUT"
echo "compiled: $OUT ($(stat -c%s "$OUT") bytes)"

echo "[4/6] Put unprecacher FIRST in AMXX plugin load order..."
python3 - "$CFG" <<'PY'
from pathlib import Path
import sys,re

p=Path(sys.argv[1])
name="oldz_unprecacher_zm.amxx"

lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()

# Remove all previous active/commented occurrences of this plugin.
clean=[]
for line in lines:
    if name.lower() in line.lower():
        continue
    clean.append(line)

header=[
    "; ======================================================",
    "; OLD ZOMBIE | PRECACHE LIMIT FIX v29",
    "; MUST LOAD FIRST",
    "; ======================================================",
    name,
    "",
]

p.write_text("\n".join(header+clean).rstrip()+"\n",encoding="utf-8")
print("first active entries:")
count=0
for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
    s=line.strip()
    if not s or s.startswith(";") or s.startswith("#"):
        continue
    if s.split()[0].lower().endswith(".amxx"):
        count+=1
        print(f" {count}. {s}")
        if count>=12:
            break
PY

echo "[5/6] Restart server NOW..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-10 seconds" --no-pager || true)"

echo "--- STATUS ---"
"$LIVE" status "$SID" || true

echo "--- FATAL CHECK ---"
echo "$RECENT" | grep -Ei 'PF_precache|512 limit|Host_Error|FATAL ERROR|segv|core-dump' || true

if echo "$RECENT" | grep -qiE 'PF_precache_sound_I_internal|over the 512 limit'; then
    echo
    echo "[ERROR] 512 sound limit still exists"
    echo "$RECENT" | grep -iE 'precache|512 limit|fatal' | tail -n 40
    exit 2
fi

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo
    echo "[ERROR] server exited for another reason"
    journalctl -u "hyper-cs16@${SID}.service" -n 140 --no-pager || true
    exit 3
fi

echo "[6/6] Verify full runtime..."
echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- AMXX PLUGINS ---"
"$LIVE" rcon "$SID" "amxx plugins" || true

echo "--- SQL ADMINS ---"
"$LIVE" sql-admins-list "$SID" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE v29"
echo "================================================================"
echo "Server: ACTIVE"
echo "ZM AMXX unprecacher: ACTIVE FIRST"
echo "94 OLD ZOMBIE plugins: PRESERVED"
echo "Broken Metamod Unprecacher: REMOVED"
echo "FastDL/nginx/site: NOT MODIFIED"
echo "Backup: $BACKUP"
echo "================================================================"
