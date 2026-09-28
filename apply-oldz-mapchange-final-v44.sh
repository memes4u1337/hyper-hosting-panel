#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-mapchange-final-v44-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE MAP CHANGE FINAL v44"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Plugins/FastDL/SQL/Admins/Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/4] Patch ONLY activate_map()..."
python3 - "$CTL" <<'PYV44'

from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')

new_func = r
PYV44

echo "[2/4] Validate controller..."
python3 -m py_compile "$CTL"

echo "[3/4] Install validated controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[4/4] Verify controller/server without changing current map..."
"$LIVE" status "$SID"

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE MAP CHANGE v44"
echo "================================================================"
echo " changelevel: fast"
echo " panel timeout: removed"
echo " slow map load: returns loading=true instead of error"
echo " generic recovery on map change: DISABLED"
echo " plugin quarantine on map change: DISABLED"
echo " automatic rollback on slow map load: DISABLED"
echo " Other server systems: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
