#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
BASE_DIR="/opt/hyper-host"
PANEL_DIR="/var/www/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
RECONCILE_BIN="/usr/local/sbin/hyper-host-nginx-reconcile"
SSL_TRUTH_BIN="$BASE_DIR/ssl-truth.py"
SQL_IMPORTER_BIN="$BASE_DIR/bin/hyper_sql_import.py"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BASE_DIR/backups/v1.2-sql-ssl-$TIMESTAMP"
REPORT="$BASE_DIR/logs/sql-ssl-repair-$TIMESTAMP.txt"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
warn(){ printf '[HYPER-HOST WARNING] %s\n' "$*" >&2; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Запусти патч через sudo/root.'

REQUIRED=(
  setup.sh install.sh
  scripts/hhctl scripts/hyper scripts/hyper_sql_import.py
  scripts/nginx-reconcile-v89.sh scripts/nginx_recover_v89.py
  scripts/hyper_nginx_runtime.sh scripts/ssl_truth.py
  src/public/index.php src/app/bootstrap.php
)
for file in "${REQUIRED[@]}"; do
  [[ -f "$ROOT_DIR/$file" ]] || fail "Нет обязательного файла: $file"
done

bash -n "$ROOT_DIR/setup.sh"
bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/scripts/hhctl"
bash -n "$ROOT_DIR/scripts/hyper"
bash -n "$ROOT_DIR/scripts/nginx-reconcile-v89.sh"
bash -n "$ROOT_DIR/scripts/hyper_nginx_runtime.sh"
python3 -m py_compile "$ROOT_DIR/scripts/hyper_sql_import.py" "$ROOT_DIR/scripts/nginx_recover_v89.py" "$ROOT_DIR/scripts/ssl_truth.py"
php -l "$ROOT_DIR/src/public/index.php" >/dev/null
php -l "$ROOT_DIR/src/app/bootstrap.php" >/dev/null

same_path(){
  local a b
  a="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
  b="$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")"
  [[ "$a" == "$b" ]]
}

install_if_different(){
  local mode="$1" src="$2" dst="$3"
  mkdir -p "$(dirname "$dst")"
  if same_path "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
  else
    install -m"$mode" "$src" "$dst"
  fi
}

log "Создаю резервную копию: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/logs" "$BASE_DIR/bin"
for path in "$CONTROL_BIN" "$HYPER_BIN" "$RECONCILE_BIN" "$SSL_TRUTH_BIN" "$SQL_IMPORTER_BIN" \
            /etc/hyper-host/hyper-host.conf /etc/mysql/mariadb.conf.d/99-hyper-host-large-import.cnf; do
  if [[ -e "$path" || -L "$path" ]]; then
    name="$(printf '%s' "$path" | sed 's#^/##;s#/#__#g')"
    cp -aL "$path" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
  fi
done
[[ -d "$BASE_DIR/letsencrypt" ]] && cp -a "$BASE_DIR/letsencrypt" "$BACKUP_DIR/letsencrypt" 2>/dev/null || true
[[ -d /etc/letsencrypt ]] && cp -a /etc/letsencrypt "$BACKUP_DIR/etc-letsencrypt" 2>/dev/null || true
[[ -d "$BASE_DIR/runtime/nginx" ]] && cp -a "$BASE_DIR/runtime/nginx" "$BACKUP_DIR/nginx-runtime" 2>/dev/null || true

log 'Устанавливаю исправленные файлы панели, SQL-импортера и SSL.'
mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/src/public" "$PROJECT_DIR/src/app"
if ! same_path "$ROOT_DIR" "$PROJECT_DIR"; then
  install_if_different 0755 "$ROOT_DIR/setup.sh" "$PROJECT_DIR/setup.sh"
  install_if_different 0755 "$ROOT_DIR/install.sh" "$PROJECT_DIR/install.sh"
  for file in hhctl hyper hyper_sql_import.py nginx-reconcile-v89.sh nginx_recover_v89.py hyper_nginx_runtime.sh ssl_truth.py; do
    install_if_different 0755 "$ROOT_DIR/scripts/$file" "$PROJECT_DIR/scripts/$file"
  done
  install_if_different 0644 "$ROOT_DIR/src/public/index.php" "$PROJECT_DIR/src/public/index.php"
  install_if_different 0644 "$ROOT_DIR/src/app/bootstrap.php" "$PROJECT_DIR/src/app/bootstrap.php"
fi

install_if_different 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper_sql_import.py" "$SQL_IMPORTER_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$RECONCILE_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$BASE_DIR/nginx_recover_v89.py"
install_if_different 0755 "$ROOT_DIR/scripts/hyper_nginx_runtime.sh" "$BASE_DIR/bin/hyper-host-nginx-runtime"
install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$SSL_TRUTH_BIN"
ln -sfn "$HYPER_BIN" /usr/bin/hyper
ln -sfn "$CONTROL_BIN" /usr/bin/hyper-host-ctl

# Копируем только код панели. config.php и база панели не удаляются.
mkdir -p "$PANEL_DIR/public" "$PANEL_DIR/app"
rsync -a "$ROOT_DIR/src/public/" "$PANEL_DIR/public/"
rsync -a --exclude='config.php' "$ROOT_DIR/src/app/" "$PANEL_DIR/app/"
chown -R www-data:www-data "$PANEL_DIR/public" 2>/dev/null || true
chown www-data:www-data "$PANEL_DIR/app/bootstrap.php" 2>/dev/null || true

log 'Настраиваю фоновый импорт SQL до 8 ГБ.'
mkdir -p "$BASE_DIR/imports/tmp" "$BASE_DIR/imports/uploads" "$BASE_DIR/imports/jobs" "$BASE_DIR/imports/logs"
chown -R www-data:www-data "$BASE_DIR/imports/tmp" "$BASE_DIR/imports/uploads"
chmod 0770 "$BASE_DIR/imports/tmp" "$BASE_DIR/imports/uploads"
chmod 0750 "$BASE_DIR/imports/jobs" "$BASE_DIR/imports/logs"
"$CONTROL_BIN" mysql-import-tune
"$CONTROL_BIN" phpmyadmin-fix

log 'Пересобираю Nginx с таймаутом 6 часов и лимитом загрузки 8 ГБ.'
"$BASE_DIR/bin/hyper-host-nginx-runtime" --quiet
"$RECONCILE_BIN"
nginx -t
systemctl reload nginx

log 'Возвращаю сертификаты из всех старых резервных копий и подключаю их к доменам.'
SSL_JSON="$($CONTROL_BIN ssl-repair-all 2>&1 || true)"
printf '%s\n' "$SSL_JSON" > "$REPORT.ssl.json"
"$RECONCILE_BIN"
nginx -t
systemctl reload nginx

log 'Проверяю PHP, MariaDB, панель и SSL.'
php -l "$PANEL_DIR/public/index.php" >/dev/null
php -l "$PANEL_DIR/app/bootstrap.php" >/dev/null
mysql --protocol=socket -uroot -e 'SELECT @@max_allowed_packet AS max_allowed_packet, @@net_read_timeout AS net_read_timeout, @@net_write_timeout AS net_write_timeout;' > "$REPORT.mysql.txt"
"$CONTROL_BIN" phpmyadmin-status-json > "$REPORT.phpmyadmin.json" || true
"$CONTROL_BIN" ssl-status-json > "$REPORT.ssl-status.json" || true
"$CONTROL_BIN" ssl-audit-json > "$REPORT.ssl-audit.json" || true

{
  echo 'HYPER-HOST v1.2 — SQL + SSL FINAL'
  echo "backup=$BACKUP_DIR"
  echo 'sql_upload_limit=8192M'
  echo 'sql_import_mode=background-streaming'
  echo 'sql_formats=.sql,.sql.gz,.gz,.zip'
  echo 'nginx_timeout=21600s'
  echo 'ssl_restore=all_backups_and_reconcile'
  echo 'ftp=not_modified'
  echo
  echo 'MySQL:'
  cat "$REPORT.mysql.txt" 2>/dev/null || true
  echo
  echo 'SSL repair:'
  cat "$REPORT.ssl.json" 2>/dev/null || true
} > "$REPORT"

printf '\n'
printf '============================================================\n'
printf ' HYPER-HOST v1.2 — SQL И SSL ИСПРАВЛЕНЫ\n'
printf '============================================================\n'
printf ' Большой SQL: фоновый потоковый импорт, лимит 8 ГБ\n'
printf ' Nginx/PHP timeout: 21600 секунд\n'
printf ' SSL: сертификаты восстановлены из backup и подключены\n'
printf ' FTP: не изменялся\n'
printf ' Backup: %s\n' "$BACKUP_DIR"
printf ' Report: %s\n' "$REPORT"
printf '============================================================\n'
printf ' Проверка импорта: sudo hyper db imports\n'
printf ' Проверка SSL:     sudo hyper ssl status\n'
printf ' Полный ремонт SSL: sudo hyper ssl repair-all EMAIL\n'
