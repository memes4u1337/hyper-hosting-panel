#!/usr/bin/env bash
# HYPER-HOST: update GitHub panel, apply CS1.6 shared SQL/FTP/FastDL patch,
# retire CS2, then run read-only diagnostics.
# Avoid hyper repair before CS2 retirement: it fails on stale CS2 FTP homes.
set -Eeuo pipefail

log(){ printf '\n[HH-UPDATE] %s\n' "$*"; }
warn(){ printf '[HH-UPDATE WARN] %s\n' "$*" >&2; }
die(){ printf '[HH-UPDATE ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die 'Run as root (sudo bash HH_UPDATE_FROM_GITHUB_FIXED_v2.sh)'
: "${CS16_SHARED_FROM_ID:=25}"
export CS16_SHARED_FROM_ID
REPO=/root/hyper-hosting-panel
PATCH_NAME=HH_CS16_SQL_FTP_FASTDL_NO_CS2_v2.sh

if [[ ! -d "$REPO/.git" ]]; then
    [[ ! -e "$REPO" ]] || die "$REPO exists but is not a git repository; refusing to overwrite"
    git clone --branch main https://github.com/memes4u1337/hyper-hosting-panel.git "$REPO"
fi
cd "$REPO"
log 'Updating panel files from origin/main'
git fetch origin main
git checkout main
git reset --hard origin/main
# Do NOT run git clean: it may delete locally created files.

[[ -f "$REPO/update.sh" ]] || die 'update.sh not found in GitHub repository'
[[ -f "$REPO/$PATCH_NAME" ]] || die "Upload $PATCH_NAME to the repository root before updating"
[[ -d /var/www/hyper-host/public ]] || die 'Panel is not installed; refusing to run a full install'

log 'Updating main panel (update.sh)'
bash "$REPO/update.sh"

log 'Applying CS1.6 patch before optional maintenance'
log "Using game SQL credentials from existing CS1.6 server ID ${CS16_SHARED_FROM_ID}"
# NOTE: this action removes dedicated CS2 game files unless CS16_SKIP_CS2_DELETE=1.
bash "$REPO/$PATCH_NAME" apply

log 'Nginx validation and reload'
nginx -t
systemctl reload nginx

log 'Read-only diagnostics (warnings do not mask patch failure)'
if command -v hyper-cs16-ctl >/dev/null 2>&1; then
    hyper-cs16-ctl doctor || warn 'CS1.6 doctor returned an error'
else
    warn 'hyper-cs16-ctl command missing'
fi
if command -v hyper >/dev/null 2>&1; then
    hyper ftp doctor || warn 'FTP doctor returned an error'
fi
log 'SUCCESS: panel updated and CS1.6 patch applied.'
