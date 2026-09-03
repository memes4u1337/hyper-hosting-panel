#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# HYPER-HOST — безопасное обновление уже установленной панели.
# powered by memes4u1337
#
# Заменяет собой все старые apply-v*.sh патчи: обновляет файлы панели,
# hhctl, nginx-reconcile и (если облако установлено) файлы cloud-приложения.
# apt/dpkg, PHP, MySQL и FTP не трогаются вообще.
#
#   sudo bash update.sh
# ==============================================================================

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
CONTROL_BIN="${CONTROL_BIN:-/usr/local/sbin/hyper-host-ctl}"
RECONCILE_BIN="${RECONCILE_BIN:-/usr/local/sbin/hyper-host-nginx-reconcile}"
BASE_DIR="${BASE_DIR:-/opt/hyper-host}"
CLOUD_APP_ROOT="${CLOUD_APP_ROOT:-/var/www/hyper-host-cloud-app}"
CP_APP_ROOT="${CP_APP_ROOT:-/var/www/hyper-host-cp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE_DIR/backups/update-$STAMP"
INSTALLED=0

log(){ printf '\033[1;36m[HYPER-HOST]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root: sudo bash update.sh"
[[ -d "$PANEL_DIR/public" ]] || fail "Панель не установлена: $PANEL_DIR. Запусти install.sh"

# ------------------------------------------------------------------ проверки
for f in src/public/index.php src/public/assets/style.css src/public/assets/app.js scripts/hhctl; do
  [[ -f "$SRC_DIR/$f" ]] || fail "В архиве не найден файл: $f"
done

log "Синтаксическая проверка перед установкой..."
php -l "$SRC_DIR/src/public/index.php" >/dev/null
php -l "$SRC_DIR/src/app/bootstrap.php" >/dev/null
bash -n "$SRC_DIR/scripts/hhctl"
bash -n "$SRC_DIR/scripts/nginx-reconcile-v89.sh"
command -v node >/dev/null 2>&1 && node --check "$SRC_DIR/src/public/assets/app.js" >/dev/null || true
for f in "$SRC_DIR"/src/cp/app/*.php "$SRC_DIR"/src/cp/public/*.php; do
  [[ -f "$f" ]] && php -l "$f" >/dev/null
done

# ------------------------------------------------------------------ бэкап
log "Бэкап текущей версии -> $BACKUP"
mkdir -p "$BACKUP"
cp -a "$PANEL_DIR" "$BACKUP/panel" 2>/dev/null || true
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP/hyper-host-ctl" || true
[[ -f "$RECONCILE_BIN" ]] && cp -a "$RECONCILE_BIN" "$BACKUP/hyper-host-nginx-reconcile" || true
[[ -d "$CLOUD_APP_ROOT" ]] && cp -a "$CLOUD_APP_ROOT" "$BACKUP/cloud-app" || true
[[ -d "$CP_APP_ROOT" ]] && cp -a "$CP_APP_ROOT" "$BACKUP/cp-app" || true

rollback(){
  local code=$?
  if [[ "$INSTALLED" -eq 1 ]]; then
    warn "Ошибка обновления — откатываю на предыдущую версию"
    [[ -d "$BACKUP/panel" ]] && rsync -a --delete "$BACKUP/panel/" "$PANEL_DIR/" || true
    [[ -f "$BACKUP/hyper-host-ctl" ]] && install -m 0755 "$BACKUP/hyper-host-ctl" "$CONTROL_BIN" || true
    [[ -d "$BACKUP/cloud-app" ]] && rsync -a --delete "$BACKUP/cloud-app/" "$CLOUD_APP_ROOT/" || true
    [[ -d "$BACKUP/cp-app" ]] && rsync -a --delete "$BACKUP/cp-app/" "$CP_APP_ROOT/" || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap rollback ERR
INSTALLED=1

# ------------------------------------------------------------------ панель
log "Обновление файлов панели..."
CONFIG_BACKUP=""
if [[ -f "$PANEL_DIR/app/config.php" ]]; then
  CONFIG_BACKUP="$(mktemp)"
  cp -a "$PANEL_DIR/app/config.php" "$CONFIG_BACKUP"
fi

install -m 0644 "$SRC_DIR/src/public/index.php"        "$PANEL_DIR/public/index.php"
install -m 0644 "$SRC_DIR/src/public/assets/style.css" "$PANEL_DIR/public/assets/style.css"
install -m 0644 "$SRC_DIR/src/public/assets/app.js"    "$PANEL_DIR/public/assets/app.js"
install -m 0644 "$SRC_DIR/src/app/bootstrap.php"       "$PANEL_DIR/app/bootstrap.php"
install -m 0644 "$SRC_DIR/src/app/setup_db.php"        "$PANEL_DIR/app/setup_db.php"
install -m 0644 "$SRC_DIR/src/app/config.example.php"  "$PANEL_DIR/app/config.example.php"

if [[ -n "$CONFIG_BACKUP" ]]; then
  cp -a "$CONFIG_BACKUP" "$PANEL_DIR/app/config.php"
  rm -f "$CONFIG_BACKUP"
fi
chown -R www-data:www-data "$PANEL_DIR/public" "$PANEL_DIR/app" 2>/dev/null || true

# ------------------------------------------------------------------ hhctl
log "Обновление управляющих скриптов..."
install -m 0755 "$SRC_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m 0755 "$SRC_DIR/scripts/nginx-reconcile-v89.sh" "$RECONCILE_BIN"
install -m 0755 "$SRC_DIR/scripts/nginx_recover_v89.py" "$BASE_DIR/nginx_recover_v89.py"
install -m 0755 "$SRC_DIR/scripts/ssl_truth.py" "$BASE_DIR/ssl-truth.py"
mkdir -p "$BASE_DIR/bin" "$BASE_DIR/deploy-center"
install -m 0755 "$SRC_DIR/scripts/hyper_nginx_runtime.sh" "$BASE_DIR/bin/hyper-host-nginx-runtime"
install -m 0755 "$SRC_DIR/scripts/hyper_sql_import.py" "$BASE_DIR/bin/hyper_sql_import.py"
install -m 0755 "$SRC_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
install -m 0755 "$SRC_DIR/scripts/deploy_center.py" "$BASE_DIR/deploy-center/deploy_center.py"
install -m 0755 "$SRC_DIR/scripts/hyper" /usr/local/sbin/hyper
[[ -f "$SRC_DIR/scripts/hyper_ftp_server.py" ]] && install -m 0755 "$SRC_DIR/scripts/hyper_ftp_server.py" "$BASE_DIR/bin/hyper-ftp-server" || true

# ------------------------------------------------------------------ облако
if [[ -d "$CLOUD_APP_ROOT/app" ]]; then
  log "Обновление HYPER CLOUD..."
  install -o root -g hypercloud -m 0640 "$SRC_DIR/src/cloud/app/bootstrap.php" "$CLOUD_APP_ROOT/app/bootstrap.php"
  install -o root -g hypercloud -m 0640 "$SRC_DIR/src/cloud/app/filelib.php"  "$CLOUD_APP_ROOT/app/filelib.php"
  for f in index.php editor.php site.php site-resource.php; do
    install -o root -g hypercloud -m 0640 "$SRC_DIR/src/cloud/public/$f" "$CLOUD_APP_ROOT/public/$f"
  done
  install -o root -g hypercloud -m 0640 "$SRC_DIR/src/cloud/public/api/upload.php" "$CLOUD_APP_ROOT/public/api/upload.php"
  install -m 0644 "$SRC_DIR/src/cloud/public/cloud.css" "$CLOUD_APP_ROOT/public/cloud.css"
  install -m 0644 "$SRC_DIR/src/cloud/public/cloud.js"  "$CLOUD_APP_ROOT/public/cloud.js"
  install -m 0755 "$SRC_DIR/scripts/hyper-cloud-nginx-fragment.sh" "$BASE_DIR/bin/hyper-cloud-nginx-fragment.sh"
  install -m 0755 "$SRC_DIR/scripts/hyper-cloud-panel-auth" /usr/local/sbin/hyper-cloud-panel-auth
fi

# ------------------------------------------------------------------ портал клиентов
if [[ -d "$CP_APP_ROOT/app" ]]; then
  log "Обновление клиентского портала..."
  install -o root -g hypercp -m 0640 "$SRC_DIR/src/cp/app/bootstrap.php" "$CP_APP_ROOT/app/bootstrap.php"
  install -o root -g hypercp -m 0640 "$SRC_DIR/src/cp/public/index.php"  "$CP_APP_ROOT/public/index.php"
  install -m 0644 "$SRC_DIR/src/cp/public/assets/cp.css" "$CP_APP_ROOT/public/assets/cp.css"
  install -m 0644 "$SRC_DIR/src/cp/public/assets/cp.js"  "$CP_APP_ROOT/public/assets/cp.js"
  install -m 0755 "$SRC_DIR/scripts/hyper-cp-bridge" /usr/local/sbin/hyper-cp-bridge
  install -m 0755 "$SRC_DIR/scripts/hyper-cp-nginx-fragment.sh" "$BASE_DIR/bin/hyper-cp-nginx-fragment.sh"
  python3 -m py_compile /usr/local/sbin/hyper-cp-bridge >/dev/null || fail "Мост портала не компилируется"
fi

# ------------------------------------------------------------------ проверки после
log "Проверка установленных файлов..."
php -l "$PANEL_DIR/public/index.php" >/dev/null
bash -n "$CONTROL_BIN"
nginx -t >/dev/null

rm -rf "$BASE_DIR/cache"/* 2>/dev/null || true
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl reload "$unit" >/dev/null 2>&1 || true
done < <(systemctl list-units --type=service --state=running 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1

INSTALLED=0
trap - ERR
log "Обновление завершено. Backup: $BACKUP"
