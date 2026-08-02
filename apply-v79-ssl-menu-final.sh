#!/usr/bin/env bash
set -Eeuo pipefail

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
BACKUP_DIR="/opt/hyper-host/backups/v79-ssl-menu-$(date +%Y%m%d-%H%M%S)"
INSTALLED=0

log(){ printf '[HYPER-HOST v79] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST v79 ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти: sudo bash apply-v79-ssl-menu-final.sh"

for file in \
  "$PATCH_DIR/src/public/index.php" \
  "$PATCH_DIR/src/public/assets/style.css" \
  "$PATCH_DIR/src/public/assets/app.js"; do
  [[ -f "$file" ]] || fail "Не найден файл патча: $file"
done

[[ -d "$PANEL_DIR/public/assets" ]] || fail "Панель не найдена: $PANEL_DIR/public/assets"
[[ -f "$PANEL_DIR/public/index.php" ]] || fail "Не найден index.php панели"

php -l "$PATCH_DIR/src/public/index.php" >/dev/null
if command -v node >/dev/null 2>&1; then node --check "$PATCH_DIR/src/public/assets/app.js" >/dev/null; fi

mkdir -p "$BACKUP_DIR/public/assets"
cp -a "$PANEL_DIR/public/index.php" "$BACKUP_DIR/public/index.php"
cp -a "$PANEL_DIR/public/assets/style.css" "$BACKUP_DIR/public/assets/style.css"
cp -a "$PANEL_DIR/public/assets/app.js" "$BACKUP_DIR/public/assets/app.js"

rollback(){
  local code=$?
  if [[ "$INSTALLED" -eq 1 ]]; then
    log "Ошибка — возвращаю предыдущие файлы"
    cp -a "$BACKUP_DIR/public/index.php" "$PANEL_DIR/public/index.php" 2>/dev/null || true
    cp -a "$BACKUP_DIR/public/assets/style.css" "$PANEL_DIR/public/assets/style.css" 2>/dev/null || true
    cp -a "$BACKUP_DIR/public/assets/app.js" "$PANEL_DIR/public/assets/app.js" 2>/dev/null || true
    chown www-data:www-data "$PANEL_DIR/public/index.php" "$PANEL_DIR/public/assets/style.css" "$PANEL_DIR/public/assets/app.js" 2>/dev/null || true
    systemctl reload php8.4-fpm >/dev/null 2>&1 || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap rollback ERR

INSTALLED=1
install -o www-data -g www-data -m 0644 "$PATCH_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
install -o www-data -g www-data -m 0644 "$PATCH_DIR/src/public/assets/style.css" "$PANEL_DIR/public/assets/style.css"
install -o www-data -g www-data -m 0644 "$PATCH_DIR/src/public/assets/app.js" "$PANEL_DIR/public/assets/app.js"

php -l "$PANEL_DIR/public/index.php" >/dev/null
if command -v node >/dev/null 2>&1; then node --check "$PANEL_DIR/public/assets/app.js" >/dev/null; fi
nginx -t >/dev/null

rm -rf /opt/hyper-host/cache/* 2>/dev/null || true
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl reload "$unit" >/dev/null 2>&1 || systemctl restart "$unit" >/dev/null 2>&1 || true
done < <(systemctl list-units --type=service --state=running 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1

INSTALLED=0
trap - ERR
log "Патч установлен"
log "Backup: $BACKUP_DIR"
log "Исправлен POST email для SSL, добавлены SSH-команды и новое меню без прокрутки"
