#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root/sudo' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="$ROOT_DIR/cs16-panel/systemd/hyper-cs16@.service"
RUN_SRC="$ROOT_DIR/cs16-panel/bin/hyper-cs16-run"
[[ -f "$UNIT_SRC" && -f "$RUN_SRC" ]] || { echo '[ERROR] Patch files are incomplete' >&2; exit 1; }

echo '[CS16 v1.4] Stopping CS 1.6 instances...'
mapfile -t IDS < <(find /var/lib/hyper-cs16/servers /etc/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | grep -E '^[0-9]+$' | sort -nu || true)
for sid in "${IDS[@]}"; do systemctl stop "hyper-cs16@${sid}.service" >/dev/null 2>&1 || true; done

echo '[CS16 v1.4] Repairing cs16 identity and state permissions...'
getent group cs16 >/dev/null 2>&1 || groupadd --system cs16
if ! id cs16 >/dev/null 2>&1; then
  useradd --system --gid cs16 --create-home --home-dir /srv/hyper-cs16 --shell /usr/sbin/nologin cs16
fi
usermod -g cs16 -aG www-data cs16 >/dev/null 2>&1 || true
install -d -o root -g cs16 -m 0750 /var/lib/hyper-cs16 /var/lib/hyper-cs16/servers
find /var/lib/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -exec chown root:cs16 {} + -exec chmod 0640 {} + 2>/dev/null || true

# Migrate legacy JSONs when needed.
if [[ -d /etc/hyper-cs16/servers ]]; then
  shopt -s nullglob
  for old in /etc/hyper-cs16/servers/*.json; do
    dst="/var/lib/hyper-cs16/servers/$(basename "$old")"
    [[ -e "$dst" ]] || cp -a "$old" "$dst" || true
  done
  shopt -u nullglob
  find /var/lib/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -exec chown root:cs16 {} + -exec chmod 0640 {} + 2>/dev/null || true
fi

echo '[CS16 v1.4] Installing corrected systemd unit...'
install -m 0644 "$UNIT_SRC" /etc/systemd/system/hyper-cs16@.service
install -m 0755 "$RUN_SRC" /usr/local/sbin/hyper-cs16-run
systemctl daemon-reload
systemctl reset-failed 'hyper-cs16@*.service' >/dev/null 2>&1 || true

echo '[CS16 v1.4] Verifying access as the exact systemd identity...'
for cfg in /var/lib/hyper-cs16/servers/*.json; do
  [[ -f "$cfg" ]] || continue
  sid="$(basename "$cfg" .json)"
  if ! runuser -u cs16 -g cs16 -- test -r "$cfg"; then
    echo "[ERROR] cs16:cs16 cannot read $cfg" >&2
    namei -l "$cfg" >&2 || true
    exit 2
  fi
  echo "[OK] cs16:cs16 can read server #$sid config"
done

echo '[CS16 v1.4] Starting servers...'
failed=0
for cfg in /var/lib/hyper-cs16/servers/*.json; do
  [[ -f "$cfg" ]] || continue
  sid="$(basename "$cfg" .json)"
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  systemctl enable "hyper-cs16@${sid}.service" >/dev/null 2>&1 || true
  systemctl restart "hyper-cs16@${sid}.service" || true
  sleep 3
  if ! systemctl is-active --quiet "hyper-cs16@${sid}.service"; then
    echo "[ERROR] server #$sid failed to start" >&2
    journalctl -u "hyper-cs16@${sid}.service" -n 80 --no-pager >&2 || true
    failed=1
    continue
  fi
  port="$(python3 - "$cfg" <<'PYPORT'
import json,sys
try:
    print(int(json.load(open(sys.argv[1],encoding='utf-8')).get('port',27015)))
except Exception:
    print('')
PYPORT
)"
  if [[ -n "$port" ]] && ss -lunH | awk '{print $5}' | grep -Eq "(^|:)${port}$"; then
    echo "[OK] server #$sid is ACTIVE and UDP $port is listening"
  else
    echo "[WARN] server #$sid is active but UDP ${port:-?} is not visible yet" >&2
    journalctl -u "hyper-cs16@${sid}.service" -n 80 --no-pager >&2 || true
    failed=1
  fi
done

if ((failed)); then
  echo '[CS16 v1.4] Unit/group bug is fixed, but at least one instance still has a later HLDS startup error. The log above is now the real HLDS error.' >&2
  exit 3
fi

echo '[CS16 v1.4] DONE: systemd now runs game servers as cs16:cs16 with www-data supplementary access.'
