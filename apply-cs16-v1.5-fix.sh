#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root/sudo' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL_SRC="$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl"
RUN_SRC="$ROOT_DIR/cs16-panel/bin/hyper-cs16-run"
UNIT_SRC="$ROOT_DIR/cs16-panel/systemd/hyper-cs16@.service"
for f in "$CTL_SRC" "$RUN_SRC" "$UNIT_SRC"; do [[ -f "$f" ]] || { echo "[ERROR] Missing patch file: $f" >&2; exit 1; }; done

echo '[CS16 v1.5] Detecting configured servers...'
mapfile -t IDS < <(find /var/lib/hyper-cs16/servers /etc/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | grep -E '^[0-9]+$' | sort -nu || true)
if ((${#IDS[@]}==0)); then echo '[CS16 v1.5] No existing server JSONs found; runtime will still be updated.'; fi

for sid in "${IDS[@]}"; do systemctl stop "hyper-cs16@${sid}.service" >/dev/null 2>&1 || true; done

echo '[CS16 v1.5] Installing required 32-bit runtime pieces...'
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386 >/dev/null 2>&1 || true
apt-get update --allow-releaseinfo-change >/dev/null
apt-get install -y lib32gcc-s1 libc6:i386 libstdc++6:i386 libgcc-s1:i386 lib32z1 >/dev/null

echo '[CS16 v1.5] Repairing service identity and mutable state permissions...'
getent group cs16 >/dev/null 2>&1 || groupadd --system cs16
if ! id cs16 >/dev/null 2>&1; then
  useradd --system --gid cs16 --create-home --home-dir /srv/hyper-cs16 --shell /usr/sbin/nologin cs16
fi
usermod -g cs16 -aG www-data cs16 >/dev/null 2>&1 || true
install -d -o root -g cs16 -m 0750 /var/lib/hyper-cs16 /var/lib/hyper-cs16/servers
find /var/lib/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -exec chown root:cs16 {} + -exec chmod 0640 {} + 2>/dev/null || true

# Migrate old configs if a previous release left them under /etc.
if [[ -d /etc/hyper-cs16/servers ]]; then
  shopt -s nullglob
  for old in /etc/hyper-cs16/servers/*.json; do
    dst="/var/lib/hyper-cs16/servers/$(basename "$old")"
    [[ -e "$dst" ]] || cp -a "$old" "$dst" || true
  done
  shopt -u nullglob
  find /var/lib/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -exec chown root:cs16 {} + -exec chmod 0640 {} + 2>/dev/null || true
fi

echo '[CS16 v1.5] Installing corrected controller, launcher and systemd unit...'
install -m 0755 "$CTL_SRC" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$RUN_SRC" /usr/local/sbin/hyper-cs16-run
install -m 0644 "$UNIT_SRC" /etc/systemd/system/hyper-cs16@.service
systemctl daemon-reload
systemctl reset-failed 'hyper-cs16@*.service' >/dev/null 2>&1 || true

echo '[CS16 v1.5] Repairing cached HLDS base and Steam runtime...'
/usr/local/sbin/hyper-cs16-ctl base-install

failed=0
for cfg in /var/lib/hyper-cs16/servers/*.json; do
  [[ -f "$cfg" ]] || continue
  sid="$(basename "$cfg" .json)"
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  echo "[CS16 v1.5] Repairing server #$sid..."
  set +e
  out="$(/usr/local/sbin/hyper-cs16-ctl repair-runtime "$sid" 2>&1)"
  rc=$?
  set -e
  if ((rc==0)); then
    echo "[OK] server #$sid: $out"
  else
    echo "[ERROR] server #$sid still failed:" >&2
    echo "$out" >&2
    failed=1
  fi
done

systemctl restart hyper-cs16-monitor.service >/dev/null 2>&1 || true

echo '[CS16 v1.5] Network sockets:'
ss -lunp | grep -E '27015|27016|27017|27018|27019|27020' || true

echo '[CS16 v1.5] Steam runtime:'
ls -l /srv/hyper-cs16/.steam/sdk32/steamclient.so 2>/dev/null || true

echo '[CS16 v1.5] Doctor:'
/usr/local/sbin/hyper-cs16-ctl doctor || true

if ((failed)); then
  echo '[CS16 v1.5] Patch code was installed, but one or more HLDS instances still fail the real UDP+A2S health check. The error printed above now contains the actual journal/debug.log instead of hiding it behind hlds_run.' >&2
  exit 2
fi

echo '[CS16 v1.5] DONE. Every configured server passed systemd + UDP + A2S checks.'
