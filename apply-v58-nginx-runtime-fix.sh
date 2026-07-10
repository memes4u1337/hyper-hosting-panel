#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/opt/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
CONF="/etc/hyper-host/hyper-host.conf"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
PATCH_BACKUP_DIR="$BASE_DIR/backups/v58-nginx-runtime-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v58-access.txt"
PROJECT_LABEL="\033[1;36mHYPER-HOST\033[0m"

log(){ echo -e "[${PROJECT_LABEL}] $*"; }
fail(){ echo -e "[${PROJECT_LABEL}] ERROR: $*" >&2; exit 1; }

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$CONF" ]] || fail "Не найден $CONF — панель не установлена"
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса scripts/hhctl'

# shellcheck disable=SC1090
source "$CONF"
SERVER_IP="${SERVER_IP:-192.168.0.179}"
PUBLIC_IP="${PUBLIC_IP:-90.189.208.25}"
PANEL_DOMAIN="${PANEL_DOMAIN:-_}"
SITES_DIR="${SITES_DIR:-/var/www/hyper-host-sites}"

log "Резервная копия: $PATCH_BACKUP_DIR"
mkdir -p "$PATCH_BACKUP_DIR"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$PATCH_BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -d /opt/hyper-host/runtime/nginx ]] && cp -a /opt/hyper-host/runtime/nginx "$PATCH_BACKUP_DIR/nginx-runtime.bak" 2>/dev/null || true

log 'Устанавливаю только исправление Nginx runtime. FTP, SQL, сайты, боты и база панели не изменяются.'
install -m 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"

# Старые transient units можно безопасно убрать: они находятся только в /run.
rm -f /run/systemd/system/etc-nginx.mount \
      /run/systemd/system/hyper-host-nginx-runtime.service 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true

log 'Подключаю writable-конфигурацию Nginx без записи в /usr/lib/systemd и /etc/systemd.'
"$CONTROL_BIN" nginx-runtime-fix

# Жёсткая проверка, что новая версия больше не содержит старых путей.
if grep -Eq '/usr/lib/systemd/system/(etc-nginx|nginx\.service\.d)|/etc/systemd/system/(etc-nginx|nginx\.service\.d)' "$CONTROL_BIN"; then
  fail 'В установленном CLI остались запрещённые системные пути'
fi

[[ -x /opt/hyper-host/bin/hyper-host-nginx-runtime ]] || fail 'Не создан boot-script Nginx runtime в /opt'
[[ -f /run/systemd/system/hyper-host-nginx-runtime.service ]] || fail 'Не создан runtime-unit в /run'
crontab -l 2>/dev/null | grep -q 'HYPER-HOST-NGINX-RUNTIME' || fail 'Не установлен root @reboot для восстановления Nginx runtime'

PROBE="/etc/nginx/.hyper-host-v58-probe-$$"
( : > "$PROBE" ) 2>/dev/null || fail '/etc/nginx всё ещё доступен только для чтения'
rm -f "$PROBE"
nginx -t >/dev/null || fail 'nginx -t завершился ошибкой после подключения runtime'

log 'Проверяю создание, открытие и удаление сайта через тот же CLI, который вызывает панель.'
TEST_DOMAIN="v58-nginx-test-$(date +%s).local"
cleanup_test(){
  "$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null 2>&1 || true
  rm -f "/etc/nginx/sites-enabled/hyper-host-site-$TEST_DOMAIN.conf" "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" 2>/dev/null || true
  rm -rf "$SITES_DIR/$TEST_DOMAIN" 2>/dev/null || true
}
trap cleanup_test EXIT
"$CONTROL_BIN" add-site "$TEST_DOMAIN" '' '' >/dev/null
[[ -f "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" ]] || fail 'Тестовый конфиг сайта не создался'
[[ -L "/etc/nginx/sites-enabled/hyper-host-site-$TEST_DOMAIN.conf" ]] || fail 'Тестовый сайт не включился'
curl -fsS --connect-timeout 2 --max-time 5 -H "Host: $TEST_DOMAIN" http://127.0.0.1/ >/dev/null || fail 'Nginx не отдал тестовый сайт локально'
"$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null
[[ ! -e "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" ]] || fail 'Тестовый конфиг не удалился'
trap - EXIT
log 'Проверка пройдена: создать → открыть → удалить.'

ADMIN_USER='admin'
ADMIN_PASS='не изменён; сохранённый пароль не найден'
if [[ -r "$CREDENTIALS_FILE" ]]; then
  HYPER_ADMIN_USER=''
  HYPER_ADMIN_PASS=''
  # shellcheck disable=SC1090
  source "$CREDENTIALS_FILE" || true
  [[ -n "${HYPER_ADMIN_USER:-}" ]] && ADMIN_USER="$HYPER_ADMIN_USER"
  [[ -n "${HYPER_ADMIN_PASS:-}" ]] && ADMIN_PASS="$HYPER_ADMIN_PASS"
elif [[ -f "$DB_PATH" ]]; then
  DB_ADMIN="$(php -r '$db=new PDO("sqlite:".$argv[1]); echo $db->query("SELECT username FROM users ORDER BY id LIMIT 1")->fetchColumn() ?: "admin";' "$DB_PATH" 2>/dev/null || true)"
  [[ -n "$DB_ADMIN" ]] && ADMIN_USER="$DB_ADMIN"
fi

PANEL_DOMAIN_HTTP='не настроен'
PMA_DOMAIN_HTTP='не настроен'
if [[ -n "$PANEL_DOMAIN" && "$PANEL_DOMAIN" != '_' ]]; then
  PANEL_DOMAIN_HTTP="http://$PANEL_DOMAIN/"
  PMA_DOMAIN_HTTP="http://$PANEL_DOMAIN/phpmyadmin/"
fi

{
  printf 'HYPER-HOST v58\n'
  printf 'LAN IP: %s\n' "$SERVER_IP"
  printf 'WAN IP: %s\n' "$PUBLIC_IP"
  printf 'Panel LAN: http://%s/\n' "$SERVER_IP"
  printf 'Panel WAN: http://%s/\n' "$PUBLIC_IP"
  printf 'Panel domain: %s\n' "$PANEL_DOMAIN_HTTP"
  printf 'phpMyAdmin LAN: http://%s/phpmyadmin/\n' "$SERVER_IP"
  printf 'phpMyAdmin WAN: http://%s/phpmyadmin/\n' "$PUBLIC_IP"
  printf 'phpMyAdmin domain: %s\n' "$PMA_DOMAIN_HTTP"
  printf 'Admin login: %s\n' "$ADMIN_USER"
  printf 'Admin password: %s\n' "$ADMIN_PASS"
  printf 'FTP LAN/WAN: %s:21 / %s:21\n' "$SERVER_IP" "$PUBLIC_IP"
  printf 'SQL LAN/WAN: %s:3306 / %s:3306\n' "$SERVER_IP" "$PUBLIC_IP"
  printf 'Nginx runtime: /opt/hyper-host/runtime/nginx\n'
  printf 'Nginx boot: root crontab @reboot\n'
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' %b — Nginx patch установлен\n' "\033[1;36mHYPER-HOST\033[0m"
printf '============================================================\n'
printf ' LAN IP:             %s\n' "$SERVER_IP"
printf ' WAN IP:             %s\n' "$PUBLIC_IP"
printf '\n ПАНЕЛЬ\n'
printf ' LAN:                http://%s/\n' "$SERVER_IP"
printf ' WAN:                http://%s/\n' "$PUBLIC_IP"
printf ' Домен:              %s\n' "$PANEL_DOMAIN_HTTP"
printf '\n PHPMYADMIN\n'
printf ' LAN:                http://%s/phpmyadmin/\n' "$SERVER_IP"
printf ' WAN:                http://%s/phpmyadmin/\n' "$PUBLIC_IP"
printf ' Домен:              %s\n' "$PMA_DOMAIN_HTTP"
printf '\n ДОСТУП АДМИНИСТРАТОРА\n'
printf ' Логин:              %s\n' "$ADMIN_USER"
printf ' Пароль:             %s\n' "$ADMIN_PASS"
printf '\n СЕРВИСЫ\n'
printf ' FTP LAN/WAN:        %s:21 / %s:21\n' "$SERVER_IP" "$PUBLIC_IP"
printf ' SQL LAN/WAN:        %s:3306 / %s:3306\n' "$SERVER_IP" "$PUBLIC_IP"
printf ' Nginx runtime:      /opt/hyper-host/runtime/nginx\n'
printf ' Автоподъём:         root crontab @reboot\n'
printf ' Данные сохранены:   %s\n' "$REPORT"
printf '============================================================\n'
