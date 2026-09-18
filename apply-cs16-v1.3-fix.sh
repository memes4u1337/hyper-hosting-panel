#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root: sudo bash apply-cs16-v1.3-fix.sh' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel/bin"
[[ -f "$SRC/hyper-cs16-run" && -f "$SRC/hyper-cs16-ctl" && -f "$SRC/hyper-cs16-monitor" ]] || { echo '[ERROR] Patch files are incomplete' >&2; exit 1; }

echo '[CS16 v1.3] Stopping restart loops...'
mapfile -t ids < <(find /var/lib/hyper-cs16/servers /etc/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | grep -E '^[0-9]+$' | sort -nu || true)
for sid in "${ids[@]}"; do systemctl stop "hyper-cs16@${sid}.service" >/dev/null 2>&1 || true; done

echo '[CS16 v1.3] Repairing runtime state permissions...'
getent group cs16 >/dev/null 2>&1 || groupadd --system cs16
id cs16 >/dev/null 2>&1 || useradd --system --gid cs16 --create-home --home-dir /srv/hyper-cs16 --shell /usr/sbin/nologin cs16
usermod -aG www-data cs16 >/dev/null 2>&1 || true
install -d -o root -g cs16 -m 0750 /var/lib/hyper-cs16
install -d -o root -g cs16 -m 0750 /var/lib/hyper-cs16/servers
if [[ -d /etc/hyper-cs16/servers ]]; then
  for old in /etc/hyper-cs16/servers/*.json; do
    [[ -f "$old" ]] || continue
    dst="/var/lib/hyper-cs16/servers/$(basename "$old")"
    [[ -e "$dst" ]] || cp -a "$old" "$dst"
  done
fi
chown root:cs16 /var/lib/hyper-cs16 /var/lib/hyper-cs16/servers
chmod 0750 /var/lib/hyper-cs16 /var/lib/hyper-cs16/servers
find /var/lib/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -exec chown root:cs16 {} + -exec chmod 0640 {} + 2>/dev/null || true

echo '[CS16 v1.3] Installing fixed runtime...'
install -m 0755 "$SRC/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0755 "$SRC/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor

# Make existing game trees usable by the service account without changing content.
if [[ -d /srv/hyper-cs16/servers ]]; then
  chown cs16:www-data /srv/hyper-cs16 /srv/hyper-cs16/servers 2>/dev/null || true
  chmod 2775 /srv/hyper-cs16 /srv/hyper-cs16/servers 2>/dev/null || true
  for sid in "${ids[@]}"; do
    [[ -d "/srv/hyper-cs16/servers/$sid" ]] || continue
    chown -R cs16:www-data "/srv/hyper-cs16/servers/$sid"
    chmod -R u+rwX,g+rwX,o+rX "/srv/hyper-cs16/servers/$sid"
    find "/srv/hyper-cs16/servers/$sid" -type d -exec chmod g+s {} +
    [[ -f "/srv/hyper-cs16/servers/$sid/hlds_run" ]] && chmod 0775 "/srv/hyper-cs16/servers/$sid/hlds_run"
    [[ -f "/srv/hyper-cs16/servers/$sid/hlds_linux" ]] && chmod 0775 "/srv/hyper-cs16/servers/$sid/hlds_linux"
  done
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow 27015:27100/udp >/dev/null 2>&1 || true
fi
systemctl daemon-reload
systemctl restart hyper-cs16-monitor.service >/dev/null 2>&1 || true

echo '[CS16 v1.3] Verifying state access and starting servers...'
failed=0
mapfile -t ids < <(find /var/lib/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | grep -E '^[0-9]+$' | sort -nu || true)
if ((${#ids[@]}==0)); then
  echo '[CS16 v1.3][ERROR] No server JSON configs found in /var/lib/hyper-cs16/servers' >&2
  exit 2
fi
for sid in "${ids[@]}"; do
  cfg="/var/lib/hyper-cs16/servers/${sid}.json"
  if ! runuser -u cs16 -- test -x /var/lib/hyper-cs16 || ! runuser -u cs16 -- test -x /var/lib/hyper-cs16/servers || ! runuser -u cs16 -- test -r "$cfg"; then
    echo "[CS16 v1.3][ERROR] cs16 cannot read $cfg" >&2
    namei -l "$cfg" || true
    failed=1
    continue
  fi
  systemctl enable "hyper-cs16@${sid}.service" >/dev/null 2>&1 || true
  systemctl restart "hyper-cs16@${sid}.service" >/dev/null 2>&1 || true
  sleep 3
  if ! systemctl is-active --quiet "hyper-cs16@${sid}.service"; then
    echo "[CS16 v1.3][ERROR] server #$sid did not start" >&2
    journalctl -u "hyper-cs16@${sid}.service" -n 80 --no-pager || true
    failed=1
    continue
  fi
  port="$(python3 - "$cfg" <<'PY'
import json,sys
try: print(int(json.load(open(sys.argv[1],encoding='utf-8')).get('port',0)))
except Exception: print(0)
PY
)"
  if [[ "$port" =~ ^[0-9]+$ ]] && ss -lunH | awk '{print $5}' | grep -Eq "(^|:)${port}$"; then
    echo "[CS16 v1.3] server #$sid ACTIVE — UDP $port is listening"
  else
    echo "[CS16 v1.3][ERROR] server #$sid is active but UDP $port is not listening" >&2
    journalctl -u "hyper-cs16@${sid}.service" -n 80 --no-pager || true
    failed=1
  fi
done

echo '[CS16 v1.3] Diagnostics:'
/usr/local/sbin/hyper-cs16-ctl doctor || true
if ((failed)); then
  echo '[CS16 v1.3] Patch applied, but one or more servers still failed verification. See output above.' >&2
  exit 2
fi
echo '[CS16 v1.3] OK: runtime permissions fixed and game server UDP sockets are listening.'
