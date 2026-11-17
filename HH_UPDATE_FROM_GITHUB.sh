#!/usr/bin/env bash
# HYPER-HOST: update from GitHub and re-apply CS1.6/FTP/FastDL/CS2 patch.
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root: sudo bash HH_UPDATE_FROM_GITHUB.sh' >&2; exit 1; }
REPO=/root/hyper-hosting-panel
PATCH=/root/HH_CS16_SQL_FTP_FASTDL_NO_CS2.sh
[[ -f "$PATCH" ]] || { echo "Upload patch to $PATCH first" >&2; exit 1; }
if [[ ! -d "$REPO/.git" ]]; then
    git clone --branch main https://github.com/memes4u1337/hyper-hosting-panel.git "$REPO"
fi
cd "$REPO"
git fetch origin main
git checkout main
git reset --hard origin/main
# Deliberately NO 'git clean -fd' (can delete your untracked server assets).
chmod +x install.sh update.sh scripts/hhctl scripts/hyper 2>/dev/null || true
if [[ -f /etc/hyper-host/hyper-host.conf && -f /var/www/hyper-host/public/index.php ]]; then
    bash update.sh
else
    echo 'HYPER-HOST not installed; running initial install.sh'
    bash install.sh
fi
if command -v hyper >/dev/null 2>&1; then
    hyper repair
    hyper network fix hyper-host.pw 90.189.208.25
    hyper bot persist || true
fi
bash "$PATCH" apply
nginx -t
systemctl reload nginx
hyper-cs16-ctl doctor || true
hyper ftp doctor || true
if command -v hyper >/dev/null 2>&1; then hyper stats || true; fi
echo 'Update+patch completed. Review any warnings above.'
