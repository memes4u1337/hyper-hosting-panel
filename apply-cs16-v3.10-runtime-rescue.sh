#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16/ZM runtime rescue v3.10
#
# This patch is designed to run AFTER v3.8/v3.9.
# It does NOT run v3.3 and does NOT touch panel PHP/bootstrap/nginx/SQL schema.
#
# Fixes the v3.9 failed-unit discovery bug (systemctl's leading "●" was parsed
# as the unit name), restores failed CS16 instances, switches stale Classic
# start maps to a real ZM map for detected ZP builds, exposes the host /tmp to
# legacy AMXX MySQL plugins, and refreshes the stored runtime health only after
# the server is actually online.

CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
UNIT_FILE="${HYPER_UNIT:-/etc/systemd/system/hyper-cs16@.service}"
CFG_DIR="${HYPER_CFG_DIR:-/var/lib/hyper-cs16/servers}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.10-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.10-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

fail() {
  echo
  echo "[ERROR] $*" >&2
  echo "[ERROR] Log: $LOG" >&2
  echo "[ERROR] Backup: $BACKUP" >&2
  exit 1
}

echo "============================================================"
echo " HYPER-HOST CS16/ZM RUNTIME RESCUE v3.10"
echo "============================================================"
echo "Controller: $CTL"
echo "Unit:       $UNIT_FILE"
echo "Configs:    $CFG_DIR"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ -f "$CTL" ]] || fail "Controller not found: $CTL"
[[ -f "$UNIT_FILE" ]] || fail "Unit template not found: $UNIT_FILE"
[[ -d "$CFG_DIR" ]] || fail "Server config directory not found: $CFG_DIR"

cp -a "$CTL" "$BACKUP/hyper-cs16-ctl"
cp -a "$UNIT_FILE" "$BACKUP/hyper-cs16@.service"
cp -a "$CFG_DIR" "$BACKUP/servers-json"

echo "[1/7] Fixing systemd policy for legacy/ZM runtime..."
python3 - "$UNIT_FILE" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
orig=s

def set_line(text,key,value,section=None):
    rx=re.compile(rf'(?m)^{re.escape(key)}=.*$')
    line=f'{key}={value}'
    if rx.search(text):
        return rx.sub(line,text,count=1)
    if section:
        marker=f'[{section}]\n'
        if marker in text:
            return text.replace(marker,marker+line+'\n',1)
    return text+'\n'+line+'\n'

s=set_line(s,'StartLimitIntervalSec','300','Unit')
s=set_line(s,'StartLimitBurst','3','Unit')
s=set_line(s,'RestartSec','10','Service')
s=set_line(s,'PrivateTmp','false','Service')

if 'RestartPreventExitStatus=2' not in s:
    if 'Restart=on-failure\n' in s:
        s=s.replace('Restart=on-failure\n','Restart=on-failure\nRestartPreventExitStatus=2\n',1)
    else:
        marker='[Service]\n'
        if marker not in s:
            raise SystemExit('[ERROR] [Service] section not found')
        s=s.replace(marker,marker+'Restart=on-failure\nRestartPreventExitStatus=2\n',1)

p.write_text(s,encoding='utf-8')
print('[PATCHED]' if s!=orig else '[OK already patched]',p)
PY

systemctl daemon-reload

echo
echo "[2/7] Repairing stale Classic start maps on detected ZM builds..."
python3 - "$CTL" "$CFG_DIR" <<'PY'
from pathlib import Path
import runpy,sys
ctl=Path(sys.argv[1])
cfg_dir=Path(sys.argv[2])
mod=runpy.run_path(str(ctl))
changed=[]
for fp in sorted(cfg_dir.glob('*.json')):
    if not fp.stem.isdigit():
        continue
    sid=int(fp.stem)
    try:
        c=mod['load_server'](sid)
        root=Path(str(c.get('path') or ''))
        detected=mod['_detect_mod_profile_at'](root)
        if not detected.get('zp_active'):
            continue
        maps=root/'cstrike/maps'
        if not maps.is_dir():
            continue
        current=str(c.get('start_map') or '')
        if current.lower().startswith(('zm_','ze_','zp_')) and (maps/(current+'.bsp')).is_file():
            print(f'[OK] server #{sid}: ZM map already selected: {current}')
            continue
        choices=sorted(
            p.stem for p in maps.glob('*.bsp')
            if p.stem.lower().startswith(('zm_','ze_','zp_'))
        )
        if not choices:
            print(f'[WARN] server #{sid}: ZP detected but no zm_/ze_/zp_ map found; keeping {current or "(empty)"}')
            continue
        preferred=choices[0]
        c['start_map']=preferred
        mod['save_server'](c)
        try:
            mod['db_update_start_map'](sid,preferred)
        except Exception as exc:
            print(f'[WARN] server #{sid}: JSON map updated but DB update failed: {exc}')
        changed.append((sid,current,preferred))
        print(f'[PATCHED] server #{sid}: {current or "(empty)"} -> {preferred}')
    except Exception as exc:
        print(f'[WARN] server #{sid}: map check failed: {exc}')
print(f'[OK] ZM map changes: {len(changed)}')
PY

echo
echo "[3/7] Discovering failed CS16 units without parsing the systemd bullet..."
mapfile -t FAILED_UNITS < <(
  systemctl list-units --all --type=service --no-legend --plain --no-pager 'hyper-cs16@*.service' 2>/dev/null \
  | awk '$1 ~ /^hyper-cs16@[0-9]+\.service$/ && $3 == "failed" {print $1}' \
  | sort -u
)

# is-failed is used as a second independent source, so this also works on
# systemd versions whose list-units output differs slightly.
while IFS= read -r cfg; do
  sid="$(basename "$cfg" .json)"
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  unit="hyper-cs16@${sid}.service"
  if systemctl is-failed --quiet "$unit" 2>/dev/null; then
    if ! printf '%s\n' "${FAILED_UNITS[@]:-}" | grep -qxF "$unit"; then
      FAILED_UNITS+=("$unit")
    fi
  fi
done < <(find "$CFG_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)

if ((${#FAILED_UNITS[@]})); then
  printf '[INFO] failed unit: %s\n' "${FAILED_UNITS[@]}"
else
  echo "[OK] No failed CS16 units found."
fi

echo
echo "[4/7] Resetting the OLD failed state and giving each failed server one clean start..."
STARTED_UNITS=()
for unit in "${FAILED_UNITS[@]}"; do
  [[ "$unit" =~ ^hyper-cs16@([0-9]+)\.service$ ]] || continue
  sid="${BASH_REMATCH[1]}"
  echo "[INFO] reset-failed -> $unit"
  systemctl reset-failed "$unit" || true
  if systemctl start "$unit"; then
    STARTED_UNITS+=("$unit")
    echo "[OK] start requested -> $unit"
  else
    echo "[WARN] immediate systemd start failure -> $unit"
  fi
done

echo
echo "[5/7] Waiting for real UDP/A2S readiness (no auto-recover, no content rewrite)..."
FAILED_AFTER=()
ONLINE_IDS=()
for unit in "${STARTED_UNITS[@]}"; do
  sid="${unit#hyper-cs16@}"; sid="${sid%.service}"
  ready=0
  for _ in $(seq 1 30); do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" == "failed" ]]; then
      break
    fi
    OUT="$($CTL status "$sid" 2>/dev/null || true)"
    if python3 - "$OUT" <<'PY' >/dev/null 2>&1
import json,sys
try:
    d=json.loads(sys.argv[1])
    raise SystemExit(0 if d.get('service')=='active' and d.get('udp_listening') else 1)
except Exception:
    raise SystemExit(1)
PY
    then
      ready=1
      break
    fi
    sleep 3
  done
  if [[ "$ready" == "1" ]]; then
    ONLINE_IDS+=("$sid")
    echo "[OK] server #$sid: process ON + UDP ON"
  else
    FAILED_AFTER+=("$unit")
    echo "[WARN] server #$sid did not become UDP-ready. Current state: $(systemctl is-active "$unit" 2>/dev/null || true)"
  fi
done

echo
echo "[6/7] Refreshing AMXX/ZP runtime state for servers that are actually online..."
for sid in "${ONLINE_IDS[@]}"; do
  echo "--- server #$sid mods-status ---"
  MODS="$($CTL mods-status "$sid" 2>&1 || true)"
  echo "$MODS"
  python3 - "$CTL" "$sid" "$MODS" <<'PY'
from pathlib import Path
import json,runpy,sys
ctl=Path(sys.argv[1]); sid=int(sys.argv[2]); raw=sys.argv[3]
try:
    d=json.loads(raw)
except Exception:
    print('[WARN] could not parse mods-status JSON; stored health not changed')
    raise SystemExit(0)
if not d.get('ok'):
    print('[WARN] mods-status is not OK; stored health not changed')
    raise SystemExit(0)
mod=runpy.run_path(str(ctl))
c=mod['load_server'](sid)
total=int(d.get('runtime_plugin_total') or 0)
running=int(d.get('runtime_plugin_running') or 0)
mode=str(d.get('game_mode') or c.get('game_mode') or 'classic')
zpok=bool(d.get('zp_runtime')) if mode=='zp43' else True
healthy=bool(total>0 and running>0 and zpok)
c['custom_build_runtime_plugins']=total
c['custom_build_runtime_running']=running
c['custom_build_runtime_healthy']=1 if healthy else 0
mod['save_server'](c)
print(f'[OK] stored runtime: plugins={total}, running={running}, zp_runtime={zpok}, healthy={healthy}')
PY
done

echo
echo "[7/7] Final service state..."
systemctl list-units --all --type=service --no-legend --plain --no-pager 'hyper-cs16@*.service' 2>/dev/null || true

echo
if ((${#FAILED_AFTER[@]})); then
  echo "============================================================"
  echo " v3.10 APPLIED, BUT A REAL SERVER CRASH REMAINS"
  echo "============================================================"
  for unit in "${FAILED_AFTER[@]}"; do
    echo
    echo "----- $unit : last 120 journal lines -----"
    journalctl -u "$unit" -n 120 --no-pager -o cat 2>/dev/null || true
  done
  echo
  echo "The old restart loop is stopped; the log above is now the REAL engine/plugin failure."
  echo "Backup: $BACKUP"
  echo "Log:    $LOG"
  exit 2
fi

echo "============================================================"
echo " v3.10 RUNTIME RESCUE COMPLETE"
echo "============================================================"
echo " - systemd bullet parsing fixed"
echo " - failed CS16 units were reset correctly"
echo " - stale de_dust2 was changed to a real ZM map where applicable"
echo " - legacy /tmp/mysql.sock is visible to the game service (PrivateTmp=false)"
echo " - only genuinely online servers were marked runtime-healthy"
echo " - no v3.3 install, no auto-recover, no plugin disabling"
echo
 echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
