#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
BASE_DIR=/opt/hyper-host
BACKUP_DIR="$BASE_DIR/backups/v1.2-branding-ftp-$(date +%Y%m%d-%H%M%S)"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

for f in setup.sh install.sh scripts/hhctl scripts/proftpd_auth_sync.py scripts/hyper_ftp_proftpd_fix.sh; do
  [[ -f "$ROOT_DIR/$f" ]] || fail "Не найден файл патча: $f"
done

mkdir -p "$BACKUP_DIR" "$PROJECT_DIR/scripts" "$BASE_DIR/bin"
for f in setup.sh install.sh scripts/hhctl scripts/proftpd_auth_sync.py scripts/hyper_ftp_proftpd_fix.sh; do
  [[ -f "$PROJECT_DIR/$f" ]] && cp -a "$PROJECT_DIR/$f" "$BACKUP_DIR/$(basename "$f").bak" || true
done

log "Резервная копия: $BACKUP_DIR"
install -m0755 "$ROOT_DIR/setup.sh" "$PROJECT_DIR/setup.sh"
install -m0755 "$ROOT_DIR/install.sh" "$PROJECT_DIR/install.sh"
install -m0755 "$ROOT_DIR/scripts/hhctl" "$PROJECT_DIR/scripts/hhctl"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$PROJECT_DIR/scripts/proftpd_auth_sync.py"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$PROJECT_DIR/scripts/hyper_ftp_proftpd_fix.sh"

install -m0755 "$ROOT_DIR/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$BASE_DIR/bin/hyper_ftp_proftpd_fix.sh"
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper
install -m0755 "$ROOT_DIR/setup.sh" /usr/local/sbin/hyper-host-installer
ln -sfn /usr/local/sbin/hyper-host-installer /usr/local/bin/hyper-host-installer

log 'Восстанавливаю FTP/FTPS...'
/usr/local/bin/hyper ftp fix

log 'Проверяю FTP и Nginx...'
/usr/local/bin/hyper ftp doctor || true
nginx -t

printf '\n============================================================\n'
printf ' HYPER-HOST v1.2 установлен\n'
printf '============================================================\n'
printf ' Меню:        sudo hyper-host-installer\n'
printf ' FTP repair:  sudo hyper ftp fix\n'
printf ' FTP status:  sudo hyper ftp doctor\n'
printf ' FileZilla:   FTP, порт 21, passive, explicit TLS или plain\n'
printf ' Passive:     TCP 40000-40100\n'
printf ' Backup:      %s\n' "$BACKUP_DIR"
printf '============================================================\n'
