#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root/sudo' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$ROOT_DIR/cs16-panel" ]] || { echo '[ERROR] cs16-panel not found next to patch' >&2; exit 1; }
echo '[CS16 v1.2] Applying read-only state + SQL port fix...'
bash "$ROOT_DIR/update-cs16-panel.sh"
echo '[CS16 v1.2] Restarting existing game instances...'
while read -r unit _; do
  [[ -n "$unit" ]] || continue
  systemctl try-restart "$unit" >/dev/null 2>&1 || true
done < <(systemctl list-units --all 'hyper-cs16@*.service' --no-legend 2>/dev/null | awk '{print $1" x"}')
echo '[CS16 v1.2] Done.'
