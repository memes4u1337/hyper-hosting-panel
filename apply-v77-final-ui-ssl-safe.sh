#!/usr/bin/env bash
set -Eeuo pipefail

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
CONTROL_BIN="${CONTROL_BIN:-/usr/local/sbin/hyper-host-ctl}"
RECONCILE_BIN="${RECONCILE_BIN:-/usr/local/sbin/hyper-host-nginx-reconcile}"
BACKUP_DIR="/opt/hyper-host/backups/v77-final-ui-ssl-$(date +%Y%m%d-%H%M%S)"
INSTALLED=0

log(){ printf '[HYPER-HOST v77] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST v77 ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти патч от root: sudo bash apply-v77-final-ui-ssl-safe.sh"

for file in \
  "$PATCH_DIR/src/public/index.php" \
  "$PATCH_DIR/src/public/assets/style.css" \
  "$PATCH_DIR/src/public/assets/app.js" \
  "$PATCH_DIR/scripts/hhctl" \
  "$PATCH_DIR/scripts/nginx-reconcile-v89.sh"; do
  [[ -f "$file" ]] || fail "В архиве не найден файл: $file"
done

[[ -d "$PANEL_DIR/public/assets" ]] || fail "Панель не найдена: $PANEL_DIR/public/assets"
[[ -f "$CONTROL_BIN" ]] || fail "Не найден управляющий файл: $CONTROL_BIN"
[[ -f "$RECONCILE_BIN" ]] || fail "Не найден Nginx reconcile: $RECONCILE_BIN"

php -l "$PATCH_DIR/src/public/index.php" >/dev/null
bash -n "$PATCH_DIR/scripts/hhctl"
bash -n "$PATCH_DIR/scripts/nginx-reconcile-v89.sh"
if command -v node >/dev/null 2>&1; then
  node --check "$PATCH_DIR/src/public/assets/app.js" >/dev/null
fi

mkdir -p "$BACKUP_DIR/panel/public/assets" "$BACKUP_DIR/scripts"
cp -a "$PANEL_DIR/public/index.php" "$BACKUP_DIR/panel/public/index.php"
cp -a "$PANEL_DIR/public/assets/style.css" "$BACKUP_DIR/panel/public/assets/style.css"
cp -a "$PANEL_DIR/public/assets/app.js" "$BACKUP_DIR/panel/public/assets/app.js"
cp -a "$CONTROL_BIN" "$BACKUP_DIR/scripts/hyper-host-ctl"
cp -a "$RECONCILE_BIN" "$BACKUP_DIR/scripts/hyper-host-nginx-reconcile"

rollback(){
  local code=$?
  if [[ "$INSTALLED" -eq 1 ]]; then
    log "Ошибка установки — возвращаю предыдущие файлы"
    cp -a "$BACKUP_DIR/panel/public/index.php" "$PANEL_DIR/public/index.php" 2>/dev/null || true
    cp -a "$BACKUP_DIR/panel/public/assets/style.css" "$PANEL_DIR/public/assets/style.css" 2>/dev/null || true
    cp -a "$BACKUP_DIR/panel/public/assets/app.js" "$PANEL_DIR/public/assets/app.js" 2>/dev/null || true
    cp -a "$BACKUP_DIR/scripts/hyper-host-ctl" "$CONTROL_BIN" 2>/dev/null || true
    cp -a "$BACKUP_DIR/scripts/hyper-host-nginx-reconcile" "$RECONCILE_BIN" 2>/dev/null || true
    chown www-data:www-data "$PANEL_DIR/public/index.php" "$PANEL_DIR/public/assets/style.css" "$PANEL_DIR/public/assets/app.js" 2>/dev/null || true
    chmod 0755 "$CONTROL_BIN" "$RECONCILE_BIN" 2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap rollback ERR

INSTALLED=1
install -m 0644 "$PATCH_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
install -m 0644 "$PATCH_DIR/src/public/assets/style.css" "$PANEL_DIR/public/assets/style.css"
install -m 0644 "$PATCH_DIR/src/public/assets/app.js" "$PANEL_DIR/public/assets/app.js"
install -m 0755 "$PATCH_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m 0755 "$PATCH_DIR/scripts/nginx-reconcile-v89.sh" "$RECONCILE_BIN"

chown www-data:www-data "$PANEL_DIR/public/index.php" "$PANEL_DIR/public/assets/style.css" "$PANEL_DIR/public/assets/app.js" 2>/dev/null || true
php -l "$PANEL_DIR/public/index.php" >/dev/null
bash -n "$CONTROL_BIN"
bash -n "$RECONCILE_BIN"
nginx -t >/dev/null

rm -rf /opt/hyper-host/cache/* 2>/dev/null || true
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl reload "$unit" >/dev/null 2>&1 || true
done < <(systemctl list-units --type=service --state=running 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1

INSTALLED=0
trap - ERR
log "Патч установлен без полной переустановки панели"
log "Backup: $BACKUP_DIR"
log "Версия интерфейса: 1.7-v77"
log "SSL теперь запускается фоном, Nginx перечитывается без остановки сайтов"
