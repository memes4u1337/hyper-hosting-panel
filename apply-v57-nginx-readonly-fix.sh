#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/opt/hyper-host"
PANEL_DIR="/var/www/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
CONF="/etc/hyper-host/hyper-host.conf"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
PATCH_BACKUP_DIR="$BASE_DIR/backups/v57-nginx-readonly-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v57-access.txt"
PROJECT_LABEL="\033[1;36mHYPER-HOST\033[0m"

log(){ echo -e "[${PROJECT_LABEL}] $*"; }
fail(){ echo -e "[${PROJECT_LABEL}] ERROR: $*" >&2; exit 1; }

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$CONF" ]] || fail "Не найден $CONF — сначала должна быть установлена панель"
[[ -f "$DB_PATH" ]] || fail "Не найдена база панели $DB_PATH"
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса scripts/hhctl'

# shellcheck disable=SC1090
source "$CONF"
SERVER_IP="${SERVER_IP:-192.168.0.179}"
PUBLIC_IP="${PUBLIC_IP:-90.189.208.25}"
PANEL_DOMAIN="${PANEL_DOMAIN:-_}"
SITES_DIR="${SITES_DIR:-/var/www/hyper-host-sites}"
BOTS_DIR="${BOTS_DIR:-/var/www/hyper-host-bots}"
FTP_DIR="${FTP_DIR:-/var/www/hyper-host-ftp}"

log "Резервная копия: $PATCH_BACKUP_DIR"
mkdir -p "$PATCH_BACKUP_DIR"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$PATCH_BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$DB_PATH" ]] && cp -a "$DB_PATH" "$PATCH_BACKUP_DIR/hyperhost.sqlite.bak" || true
[[ -f "$CREDENTIALS_FILE" ]] && cp -a "$CREDENTIALS_FILE" "$PATCH_BACKUP_DIR/admin-credentials.env.bak" || true
if [[ -d /etc/nginx ]]; then
  mkdir -p "$PATCH_BACKUP_DIR/nginx"
  cp -a /etc/nginx/. "$PATCH_BACKUP_DIR/nginx/" 2>/dev/null || true
fi

log 'Устанавливаю только исправление writable Nginx runtime.'
install -m 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
ln -sf "$CONTROL_BIN" /usr/bin/hyper-host-ctl 2>/dev/null || true

log 'Подключаю действующую конфигурацию Nginx из writable-каталога /opt.'
"$CONTROL_BIN" nginx-runtime-fix

log 'Проверяю реальное создание и удаление сайта через тот же CLI, который вызывает панель.'
TEST_DOMAIN="v57-nginx-test-$(date +%s).local"
cleanup_test(){
  "$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null 2>&1 || true
  rm -f "/etc/nginx/sites-enabled/hyper-host-site-$TEST_DOMAIN.conf" "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" 2>/dev/null || true
  rm -rf "$SITES_DIR/$TEST_DOMAIN" 2>/dev/null || true
}
trap cleanup_test EXIT
"$CONTROL_BIN" add-site "$TEST_DOMAIN" '' '' >/dev/null
[[ -f "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" ]] || fail 'Тестовый Nginx-конфиг не создался'
[[ -L "/etc/nginx/sites-enabled/hyper-host-site-$TEST_DOMAIN.conf" ]] || fail 'Тестовый сайт не включился в Nginx'
curl -fsS --connect-timeout 2 --max-time 5 -H "Host: $TEST_DOMAIN" http://127.0.0.1/ >/dev/null || fail 'Nginx не отдал тестовый сайт локально'
"$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null
[[ ! -e "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" ]] || fail 'Тестовый конфиг не удалился'
trap - EXIT
log 'Проверка сайта пройдена: создать → открыть → удалить.'

log 'Подготавливаю актуальные данные администратора для итогового экрана.'
ADMIN_USER="$(php -r '
$db=new PDO("sqlite:".$argv[1]);
$v=$db->query("SELECT username FROM users ORDER BY id LIMIT 1")->fetchColumn();
echo $v ?: "admin";
' "$DB_PATH")"
[[ -n "$ADMIN_USER" ]] || ADMIN_USER='admin'

HYPER_ADMIN_USER=''
HYPER_ADMIN_PASS=''
if [[ -r "$CREDENTIALS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CREDENTIALS_FILE" || true
fi
CREDENTIALS_VALID=0
if [[ "$HYPER_ADMIN_USER" == "$ADMIN_USER" && -n "$HYPER_ADMIN_PASS" ]]; then
  CREDENTIALS_VALID="$(php -r '
$db=new PDO("sqlite:".$argv[1]);
$st=$db->prepare("SELECT password_hash FROM users WHERE username=? LIMIT 1");
$st->execute([$argv[2]]); $hash=$st->fetchColumn();
echo ($hash && password_verify($argv[3], $hash)) ? "1" : "0";
' "$DB_PATH" "$ADMIN_USER" "$HYPER_ADMIN_PASS")"
fi
if [[ "$CREDENTIALS_VALID" == '1' ]]; then
  ADMIN_PASS="$HYPER_ADMIN_PASS"
else
  ADMIN_PASS="$(openssl rand -base64 18 | tr -d '\n')"
  php -r '
$db=new PDO("sqlite:".$argv[1]);
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$user=$argv[2]; $pass=$argv[3];
$hash=password_hash($pass, PASSWORD_DEFAULT);
$st=$db->prepare("UPDATE users SET password_hash=? WHERE username=?");
$st->execute([$hash,$user]);
if ($st->rowCount() < 1) {
  $st=$db->prepare("INSERT INTO users(username,password_hash) VALUES(?,?)");
  $st->execute([$user,$hash]);
}
' "$DB_PATH" "$ADMIN_USER" "$ADMIN_PASS"
fi

{
  printf 'HYPER_ADMIN_USER=%q\n' "$ADMIN_USER"
  printf 'HYPER_ADMIN_PASS=%q\n' "$ADMIN_PASS"
} > "$CREDENTIALS_FILE"
chmod 0600 "$CREDENTIALS_FILE"
chown root:root "$CREDENTIALS_FILE" 2>/dev/null || true

PANEL_DOMAIN_HTTP='не настроен'
PMA_DOMAIN_HTTP='не настроен'
if [[ -n "$PANEL_DOMAIN" && "$PANEL_DOMAIN" != '_' ]]; then
  PANEL_DOMAIN_HTTP="http://$PANEL_DOMAIN/"
  PMA_DOMAIN_HTTP="http://$PANEL_DOMAIN/phpmyadmin/"
fi

{
  printf 'HYPER-HOST v57\n'
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
  printf 'FTP LAN: %s:21\n' "$SERVER_IP"
  printf 'FTP WAN: %s:21\n' "$PUBLIC_IP"
  printf 'SQL LAN: %s:3306\n' "$SERVER_IP"
  printf 'SQL WAN: %s:3306\n' "$PUBLIC_IP"
  printf 'Nginx runtime: /opt/hyper-host/runtime/nginx\n'
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' %b — патч установлен\n' "\033[1;36mHYPER-HOST\033[0m"
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
printf '\n Nginx runtime:      /opt/hyper-host/runtime/nginx\n'
printf ' Данные сохранены:  %s\n' "$REPORT"
printf '============================================================\n'
