#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
EMAIL="${2:-}"
BASE=/opt/hyper-host
BACKUP="$BASE/backups/v1.2-ssl-sql-truth-$(date +%Y%m%d-%H%M%S)"

say(){ printf '\033[1;36m[HYPER-HOST]\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31m[HYPER-HOST ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ [[ -f "$1" ]] || fail "Не найден файл: $1"; }
install_if_different(){
  local mode="$1" src="$2" dst="$3"
  need "$src"
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" ]] && [[ "$(readlink -f "$src")" == "$(readlink -f "$dst")" ]]; then
    chmod "$mode" "$dst" 2>/dev/null || true
    return 0
  fi
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
    return 0
  fi
  install -m "$mode" "$src" "$dst"
}
backup_one(){ local src="$1" rel="$2"; [[ -e "$src" ]] || return 0; mkdir -p "$BACKUP/$(dirname "$rel")"; cp -a "$src" "$BACKUP/$rel"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти патч через sudo"
for f in scripts/hhctl scripts/hyper scripts/ssl_truth.py scripts/nginx_recover_v89.py scripts/nginx-reconcile-v89.sh scripts/hyper_sql_import.py src/public/index.php; do need "$ROOT_DIR/$f"; done
bash -n "$ROOT_DIR/scripts/hhctl" "$ROOT_DIR/scripts/hyper" "$ROOT_DIR/scripts/nginx-reconcile-v89.sh"
python3 -m py_compile "$ROOT_DIR/scripts/ssl_truth.py" "$ROOT_DIR/scripts/nginx_recover_v89.py" "$ROOT_DIR/scripts/hyper_sql_import.py"
php -l "$ROOT_DIR/src/public/index.php" >/dev/null

say "Резервная копия: $BACKUP"
mkdir -p "$BACKUP"
backup_one /usr/local/sbin/hyper-host-ctl usr/local/sbin/hyper-host-ctl
backup_one /usr/local/bin/hyper usr/local/bin/hyper
backup_one "$BASE/ssl-truth.py" opt/hyper-host/ssl-truth.py
backup_one "$BASE/nginx_recover_v89.py" opt/hyper-host/nginx_recover_v89.py
backup_one "$BASE/bin/hyper_sql_import.py" opt/hyper-host/bin/hyper_sql_import.py
backup_one /usr/local/sbin/hyper-host-nginx-reconcile usr/local/sbin/hyper-host-nginx-reconcile
backup_one /var/www/hyper-host/public/index.php var/www/hyper-host/public/index.php

say "Устанавливаю честную SSL-проверку и живой SQL-мониторинг."
install_if_different 0755 "$ROOT_DIR/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install_if_different 0755 "$ROOT_DIR/scripts/hyper" /usr/local/bin/hyper
install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$BASE/ssl-truth.py"
install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$BASE/nginx_recover_v89.py"
install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" /usr/local/sbin/hyper-host-nginx-reconcile
install_if_different 0755 "$ROOT_DIR/scripts/hyper_sql_import.py" "$BASE/bin/hyper_sql_import.py"
install_if_different 0644 "$ROOT_DIR/src/public/index.php" /var/www/hyper-host/public/index.php
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl
ln -sfn /usr/local/bin/hyper /usr/bin/hyper

# Keep the checked-out GitHub tree in sync without self-copy failures.
if [[ -d "$PROJECT_DIR" && "$(readlink -f "$PROJECT_DIR")" != "$(readlink -f "$ROOT_DIR")" ]]; then
  install_if_different 0755 "$ROOT_DIR/scripts/hhctl" "$PROJECT_DIR/scripts/hhctl"
  install_if_different 0755 "$ROOT_DIR/scripts/hyper" "$PROJECT_DIR/scripts/hyper"
  install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$PROJECT_DIR/scripts/ssl_truth.py"
  install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$PROJECT_DIR/scripts/nginx_recover_v89.py"
  install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$PROJECT_DIR/scripts/nginx-reconcile-v89.sh"
  install_if_different 0755 "$ROOT_DIR/scripts/hyper_sql_import.py" "$PROJECT_DIR/scripts/hyper_sql_import.py"
  install_if_different 0644 "$ROOT_DIR/src/public/index.php" "$PROJECT_DIR/src/public/index.php"
fi

mkdir -p "$BASE/imports"/{jobs,logs,uploads,cancel,tmp} "$BASE/acme-webroot/.well-known/acme-challenge"
chmod 0750 "$BASE/imports/jobs" "$BASE/imports/logs" "$BASE/imports/cancel" 2>/dev/null || true
chmod 0770 "$BASE/imports/uploads" "$BASE/imports/tmp" 2>/dev/null || true
chown -R www-data:www-data "$BASE/imports/uploads" "$BASE/imports/tmp" 2>/dev/null || true

# Disable only known temporary test sites created by old patches. Real sites are untouched.
for d in /var/www/hyper-host-sites/v59-nginx-test-*.local /var/www/hyper-host-sites/v60-acme-test-*.local; do
  [[ -d "$d" ]] || continue
  touch "$d/.hyper-host-disabled"
done
rm -f /etc/nginx/hyper-host-managed/20-site-v59-nginx-test-*.local.conf /etc/nginx/hyper-host-managed/20-site-v60-acme-test-*.local.conf 2>/dev/null || true

say "Пересобираю Nginx только из реальных доменов и правильных сертификатов."
/usr/local/sbin/hyper-host-nginx-reconcile
nginx -t
systemctl reload nginx 2>/dev/null || systemctl restart nginx

say "Проверяю реальные SNI-сертификаты. Пустые fingerprint больше не считаются успехом."
RESTORE_JSON="$(python3 "$BASE/ssl-truth.py" restore)"
printf '%s\n' "$RESTORE_JSON" > "$BASE/ssl-last-restore.json"

if [[ -n "$EMAIL" ]]; then
  say "Восстанавливаю/выпускаю SSL для всех реальных доменов."
  set +e
  REPAIR_JSON="$(python3 "$BASE/ssl-truth.py" repair-all --email "$EMAIL")"
  RC=$?
  set -e
  printf '%s\n' "$REPAIR_JSON" > "$BASE/ssl-last-repair.json"
  printf '%s\n' "$REPAIR_JSON" | python3 -m json.tool || printf '%s\n' "$REPAIR_JSON"
  [[ $RC -eq 0 ]] || fail "SSL repair-all завершился ошибкой"
  OK="$(printf '%s' "$REPAIR_JSON" | python3 -c 'import json,sys; print(1 if json.load(sys.stdin).get("ok") else 0)' 2>/dev/null || echo 0)"
  [[ "$OK" == 1 ]] || fail "SSL не подтверждён для всех основных доменов. Смотри: $BASE/ssl-last-repair.json"
else
  printf '%s\n' "$RESTORE_JSON" | python3 -m json.tool || printf '%s\n' "$RESTORE_JSON"
  say "Email не передан — существующие сертификаты подключены, новые не выпускались."
fi

say "Текущие SQL-импорты:"
/usr/local/bin/hyper db imports || true

cat <<EOF

============================================================
 HYPER-HOST v1.2 — ПАТЧ УСТАНОВЛЕН
============================================================
 SSL: ложный ok устранён, проверка идёт по реальному SHA-256 + SNI + SAN
 SQL: видны PID, heartbeat, скорость, ETA, таблицы и реальный размер базы
 Backup: $BACKUP

 Проверка SSL:  sudo hyper ssl repair-all EMAIL
 Аудит SSL:     sudo /usr/local/sbin/hyper-host-ctl ssl-audit-json | python3 -m json.tool
 Импорт SQL:    sudo hyper db imports
 Лог импорта:   sudo hyper db import-log JOB_ID
 Остановка:     sudo hyper db import-cancel JOB_ID
============================================================
EOF
