#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST v95 — безопасный sparse-патч CP + клиентов админ-панели.
# Не требует полного исходного архива панели и меняет только файлы из этого патча.

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
CP_APP_ROOT="${CP_APP_ROOT:-/var/www/hyper-host-cp}"
BASE_DIR="${BASE_DIR:-/opt/hyper-host}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE_DIR/backups/v95-cp-$STAMP"
INSTALLED=0

log(){ printf '\033[1;36m[HYPER-HOST v95]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти: sudo bash update.sh"
[[ -d "$PANEL_DIR/public" ]] || fail "Основная панель не найдена: $PANEL_DIR"

for f in src/public/index.php src/public/assets/style.css \
         src/cp/app/bootstrap.php src/cp/public/index.php \
         src/cp/public/assets/cp.css src/cp/public/assets/cp.js \
         scripts/hyper-cp-bridge; do
  [[ -f "$SRC_DIR/$f" ]] || fail "В патче отсутствует: $f"
done

log "Проверяю синтаксис патча"
php -l "$SRC_DIR/src/public/index.php" >/dev/null
php -l "$SRC_DIR/src/cp/app/bootstrap.php" >/dev/null
php -l "$SRC_DIR/src/cp/public/index.php" >/dev/null
python3 -m py_compile "$SRC_DIR/scripts/hyper-cp-bridge" >/dev/null

mkdir -p "$BACKUP"
log "Создаю резервную копию: $BACKUP"
[[ -f "$PANEL_DIR/public/index.php" ]] && cp -a "$PANEL_DIR/public/index.php" "$BACKUP/panel-index.php"
[[ -f "$PANEL_DIR/public/assets/style.css" ]] && cp -a "$PANEL_DIR/public/assets/style.css" "$BACKUP/panel-style.css"
if [[ -d "$CP_APP_ROOT" ]]; then
  mkdir -p "$BACKUP/cp"
  [[ -f "$CP_APP_ROOT/app/bootstrap.php" ]] && cp -a "$CP_APP_ROOT/app/bootstrap.php" "$BACKUP/cp/bootstrap.php"
  [[ -f "$CP_APP_ROOT/public/index.php" ]] && cp -a "$CP_APP_ROOT/public/index.php" "$BACKUP/cp/index.php"
  [[ -f "$CP_APP_ROOT/public/assets/cp.css" ]] && cp -a "$CP_APP_ROOT/public/assets/cp.css" "$BACKUP/cp/cp.css"
  [[ -f "$CP_APP_ROOT/public/assets/cp.js" ]] && cp -a "$CP_APP_ROOT/public/assets/cp.js" "$BACKUP/cp/cp.js"
fi
[[ -f /usr/local/sbin/hyper-cp-bridge ]] && cp -a /usr/local/sbin/hyper-cp-bridge "$BACKUP/hyper-cp-bridge"

rollback(){
  local rc=$?
  if [[ "$INSTALLED" -eq 1 ]]; then
    warn "Ошибка установки — возвращаю резервную копию"
    [[ -f "$BACKUP/panel-index.php" ]] && install -m 0644 "$BACKUP/panel-index.php" "$PANEL_DIR/public/index.php" || true
    [[ -f "$BACKUP/panel-style.css" ]] && install -m 0644 "$BACKUP/panel-style.css" "$PANEL_DIR/public/assets/style.css" || true
    if [[ -d "$CP_APP_ROOT" ]]; then
      [[ -f "$BACKUP/cp/bootstrap.php" ]] && install -o root -g hypercp -m 0640 "$BACKUP/cp/bootstrap.php" "$CP_APP_ROOT/app/bootstrap.php" || true
      [[ -f "$BACKUP/cp/index.php" ]] && install -o root -g hypercp -m 0640 "$BACKUP/cp/index.php" "$CP_APP_ROOT/public/index.php" || true
      [[ -f "$BACKUP/cp/cp.css" ]] && install -m 0644 "$BACKUP/cp/cp.css" "$CP_APP_ROOT/public/assets/cp.css" || true
      [[ -f "$BACKUP/cp/cp.js" ]] && install -m 0644 "$BACKUP/cp/cp.js" "$CP_APP_ROOT/public/assets/cp.js" || true
    fi
    [[ -f "$BACKUP/hyper-cp-bridge" ]] && install -m 0755 "$BACKUP/hyper-cp-bridge" /usr/local/sbin/hyper-cp-bridge || true
    systemctl reload nginx >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap rollback ERR
INSTALLED=1

log "Обновляю раздел клиентов основной панели"
install -m 0644 "$SRC_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
install -m 0644 "$SRC_DIR/src/public/assets/style.css" "$PANEL_DIR/public/assets/style.css"
chown www-data:www-data "$PANEL_DIR/public/index.php" "$PANEL_DIR/public/assets/style.css" 2>/dev/null || true

if [[ -d "$CP_APP_ROOT/app" ]]; then
  log "Обновляю клиентскую CP"
  install -o root -g hypercp -m 0640 "$SRC_DIR/src/cp/app/bootstrap.php" "$CP_APP_ROOT/app/bootstrap.php"
  install -o root -g hypercp -m 0640 "$SRC_DIR/src/cp/public/index.php" "$CP_APP_ROOT/public/index.php"
  install -m 0644 "$SRC_DIR/src/cp/public/assets/cp.css" "$CP_APP_ROOT/public/assets/cp.css"
  install -m 0644 "$SRC_DIR/src/cp/public/assets/cp.js" "$CP_APP_ROOT/public/assets/cp.js"
  install -m 0755 "$SRC_DIR/scripts/hyper-cp-bridge" /usr/local/sbin/hyper-cp-bridge
else
  warn "CP ещё не установлена. Основная панель обновлена; для CP выполни: sudo bash install-cp.sh"
fi

log "Финальная проверка"
php -l "$PANEL_DIR/public/index.php" >/dev/null
if [[ -f "$CP_APP_ROOT/public/index.php" ]]; then
  php -l "$CP_APP_ROOT/public/index.php" >/dev/null
  python3 -m py_compile /usr/local/sbin/hyper-cp-bridge >/dev/null
fi
nginx -t >/dev/null

rm -rf "$BASE_DIR/cache"/* 2>/dev/null || true
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl reload "$unit" >/dev/null 2>&1 || true
done < <(systemctl list-units --type=service --state=running 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1

INSTALLED=0
trap - ERR
log "Готово. Резервная копия: $BACKUP"
