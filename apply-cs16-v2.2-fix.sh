#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" && -f "$ROOT_DIR/cs16-panel/public/index.php" ]] || { echo '[ERROR] Run this script from the patched HYPER-HOST repository root' >&2; exit 2; }

say(){ printf '\033[1;36m[CS16 v2.2]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v2.2 WARNING]\033[0m %s\n' "$*" >&2; }

SITE_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'

say 'Installing map activation controller...'
install -m 0755 "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl

if [[ -d "$SITE_PUBLIC" ]]; then
  say 'Updating CS 1.6 panel UI/API...'
  rsync -a "$ROOT_DIR/cs16-panel/public/" "$SITE_PUBLIC/"
  chown -R www-data:www-data "$SITE_PUBLIC" 2>/dev/null || true
  find "$SITE_PUBLIC" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$SITE_PUBLIC" -type f -exec chmod 0644 {} + 2>/dev/null || true
else
  warn "$SITE_PUBLIC does not exist. Run install-cs16-panel.sh first."
fi

say 'Validating files...'
python3 -m py_compile "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl"
php -l "$ROOT_DIR/cs16-panel/public/index.php" >/dev/null
php -l "$ROOT_DIR/cs16-panel/public/api.php" >/dev/null
if command -v node >/dev/null 2>&1; then node --check "$ROOT_DIR/cs16-panel/public/assets/app.js" >/dev/null; fi

grep -q "activate-map" /usr/local/sbin/hyper-cs16-ctl || { echo '[ERROR] activate-map command is missing after install' >&2; exit 3; }
systemctl reload nginx >/dev/null 2>&1 || true

say 'DONE. Existing HLDS servers were not restarted by the installer.'
say 'Selecting a map in the panel now persists it and immediately activates it.'
say 'If RCON changelevel cannot be confirmed, the controller performs one restart fallback and verifies the selected map via A2S.'
