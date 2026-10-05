#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
ROOT="/srv/hyper-cs16/servers/${SID}"
PLUGINS="$ROOT/cstrike/addons/amxmodx/configs/plugins.ini"
CTL="/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-delux-boot-fix-${SID}-${STAMP}"
LOG="/root/oldz-delux-boot-fix-${SID}-${STAMP}.log"

exec > >(tee -a "$LOG") 2>&1

echo "================================================================"
echo " OLD ZOMBIE DELUX BOOT FIX v1"
echo " Server: #${SID}"
echo " Backup: ${BACKUP}"
echo "================================================================"

[[ "$EUID" -eq 0 ]] || { echo "[ERROR] Run as root"; exit 1; }
[[ -f "$PLUGINS" ]] || { echo "[ERROR] Missing $PLUGINS"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$PLUGINS" "$BACKUP/plugins.ini"

disable_plugin() {
  local p="$1"
  sed -i -E "s|^[[:space:]]*${p//./\\.}[[:space:]]*(;.*)?$|;${p}|" "$PLUGINS"
}

enable_plugin() {
  local p="$1"
  if grep -Eq "^[[:space:]]*;[[:space:]]*${p//./\\.}([[:space:]]|$)" "$PLUGINS"; then
    sed -i -E "0,/^[[:space:]]*;[[:space:]]*${p//./\\.}([[:space:]].*)?$/s//${p}/" "$PLUGINS"
  elif ! grep -Eq "^[[:space:]]*${p//./\\.}([[:space:]]|$)" "$PLUGINS"; then
    printf '%s\n' "$p" >> "$PLUGINS"
  fi
}

wait_server() {
  local i state
  for i in $(seq 1 25); do
    state="$(systemctl is-active "hyper-cs16@${SID}.service" 2>/dev/null || true)"
    echo "[WAIT ${i}/25] state=${state}"
    if [[ "$state" == "active" ]]; then
      sleep 2
      # Make sure it did not immediately crash/restart.
      state="$(systemctl is-active "hyper-cs16@${SID}.service" 2>/dev/null || true)"
      [[ "$state" == "active" ]] && return 0
    fi
    sleep 1
  done
  return 1
}

echo "[1/7] Stop restart-loop cleanly..."
systemctl stop "hyper-cs16@${SID}.service" || true
systemctl reset-failed "hyper-cs16@${SID}.service" || true
sleep 1

echo "[2/7] Keep DELUX core, disable the 3 heavy weapon packs..."
enable_plugin "oldz_account_privileges.amxx"
enable_plugin "oldz_delux_menu.amxx"
enable_plugin "oldz_delux_hook.amxx"
enable_plugin "oldz_zclass_desperado_delux.amxx"

disable_plugin "oldz_delux_starchaser.amxx"
disable_plugin "oldz_delux_bloodmoon.amxx"
disable_plugin "oldz_delux_balrog95.amxx"

echo "[INFO] DELUX block now:"
grep -nE 'oldz_account_privileges|oldz_delux_|desperado' "$PLUGINS" || true

echo "[3/7] Start server with DELUX core..."
systemctl start "hyper-cs16@${SID}.service" || true

if ! wait_server; then
  echo
  echo "[WARN] Server did not reach stable ACTIVE state."
  echo "[INFO] Recent fatal lines:"
  journalctl -u "hyper-cs16@${SID}.service" -n 160 --no-pager | \
    grep -Ei 'Host_Error|precache|512 limit|native_|Run time error|FATAL|segv|Failed' | tail -n 60 || true

  if journalctl -u "hyper-cs16@${SID}.service" -n 200 --no-pager | grep -qiE '512 limit|over the 512|PF_precache'; then
    echo
    echo "[4/7] Still hitting 512 precache -> disable Desperado only and retry."
    systemctl stop "hyper-cs16@${SID}.service" || true
    disable_plugin "oldz_zclass_desperado_delux.amxx"
    systemctl reset-failed "hyper-cs16@${SID}.service" || true
    systemctl start "hyper-cs16@${SID}.service" || true

    if ! wait_server; then
      echo
      echo "[ERROR] Server still does not boot even without DELUX weapons + Desperado."
      echo "[ERROR] This means the 512 limit is already reached by the base/core set"
      echo "        (very likely the new zm_addon_knife.amxx / Wolf Axe resources or another existing plugin)."
      echo
      journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager | tail -n 120
      echo
      echo "Backup kept at: $BACKUP"
      exit 20
    fi
  else
    echo
    echo "[ERROR] Startup failed for a reason other than precache limit."
    journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager | tail -n 120
    exit 21
  fi
fi

echo "[5/7] Server is stable ACTIVE."
systemctl --no-pager --full status "hyper-cs16@${SID}.service" | head -n 18 || true

echo "[6/7] Enable YaPB bots (12, difficulty 4)..."
if [[ -x "$CTL" ]]; then
  "$CTL" bots-enable "$SID" --quota 12 --difficulty 4 || {
    echo "[WARN] bots-enable command returned non-zero."
  }
else
  echo "[WARN] Controller not found: $CTL"
fi

sleep 3

echo "[7/7] Final checks..."
echo "Service: $(systemctl is-active "hyper-cs16@${SID}.service" 2>/dev/null || true)"
echo
echo "Active DELUX lines:"
grep -nE '^[[:space:]]*(oldz_account_privileges|oldz_delux_|oldz_zclass_desperado)' "$PLUGINS" || true
echo
echo "Disabled heavy DELUX lines:"
grep -nE '^[[:space:]]*;[[:space:]]*oldz_delux_(starchaser|bloodmoon|balrog95)' "$PLUGINS" || true
echo

if [[ -x "$CTL" ]]; then
  "$CTL" rcon "$SID" "amxx plugins" 2>/dev/null | grep -Ei 'account|delux|desperado' || true
fi

echo
echo "================================================================"
echo " [SUCCESS] SERVER BOOTED + BOTS REQUESTED"
echo "================================================================"
echo "Heavy DELUX weapons are intentionally disabled:"
echo "  oldz_delux_starchaser.amxx"
echo "  oldz_delux_bloodmoon.amxx"
echo "  oldz_delux_balrog95.amxx"
echo
echo "BloodMoon also has a separate missing native:"
echo "  native_remove_bak47p"
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
