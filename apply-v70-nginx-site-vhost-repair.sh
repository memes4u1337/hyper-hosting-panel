#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=/opt/hyper-host
CONTROL_BIN=/usr/local/sbin/hyper-host-ctl
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
NGINX_RUNTIME_DIR="$BASE_DIR/runtime/nginx"
TARGET_DOMAIN="${1:-beta.mystockbot.xyz}"
TEST_SITE="v70-site-test-$(date +%s).test"
BACKUP_DIR="$BASE_DIR/backups/v70-nginx-site-vhost-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v70-nginx-site-vhost-report.txt
SERVER_IP=192.168.0.179
PUBLIC_IP=90.189.208.25
PROJECT=HYPER-HOST
CYAN='\033[1;36m'; RESET='\033[0m'
ROLLBACK_NEEDED=1
TARGET_PROBE_PATH=''

log(){ printf '[%b%s%b] %s\n' "$CYAN" "$PROJECT" "$RESET" "$*"; }
fail(){ printf '[%b%s%b] ERROR: %s\n' "$CYAN" "$PROJECT" "$RESET" "$*" >&2; exit 1; }
file_sha(){ [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || true; }
admin_hash(){
  [[ -f "$DB_PATH" ]] || return 0
  python3 - "$DB_PATH" <<'PY' 2>/dev/null || true
import sqlite3,sys
con=None
try:
    con=sqlite3.connect(sys.argv[1])
    cols={r[1] for r in con.execute('PRAGMA table_info(users)')}
    col=next((x for x in ('password_hash','password','pass_hash') if x in cols),None)
    if col:
        row=con.execute(f'SELECT {col} FROM users WHERE username=? LIMIT 1',('admin',)).fetchone()
        print('' if not row or row[0] is None else str(row[0]),end='')
finally:
    if con is not None: con.close()
PY
}
cleanup(){
  [[ -x "$CONTROL_BIN" ]] && "$CONTROL_BIN" delete-site "$TEST_SITE" --delete-files >/dev/null 2>&1 || true
  [[ -n "$TARGET_PROBE_PATH" ]] && rm -f "$TARGET_PROBE_PATH" >/dev/null 2>&1 || true
}
restore(){
  [[ -d "$BACKUP_DIR" ]] || return 0
  printf '[%b%s%b] Ошибка проверки Nginx — возвращаю только прежние Nginx-конфиги. FTP не трогаю.\n' "$CYAN" "$PROJECT" "$RESET" >&2
  [[ -f "$BACKUP_DIR/hyper-host-ctl.bak" ]] && install -m0755 "$BACKUP_DIR/hyper-host-ctl.bak" "$CONTROL_BIN" || true
  if [[ -f "$BACKUP_DIR/nginx-runtime.tar.gz" && -d "$NGINX_RUNTIME_DIR" ]]; then
    find "$NGINX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    tar -xzf "$BACKUP_DIR/nginx-runtime.tar.gz" -C "$NGINX_RUNTIME_DIR" >/dev/null 2>&1 || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
}
on_exit(){ rc=$?; trap - EXIT ERR INT TERM; cleanup; if [[ $rc -ne 0 && $ROLLBACK_NEEDED == 1 ]]; then restore; fi; exit $rc; }
trap on_exit EXIT
trap 'exit 130' INT TERM

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса hhctl'
[[ "$TARGET_DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || fail "Некорректный домен: $TARGET_DOMAIN"

ADMIN_BEFORE="$(admin_hash)"; CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
if [[ -d "$NGINX_RUNTIME_DIR" ]]; then
  tar -czf "$BACKUP_DIR/nginx-runtime.tar.gz" -C "$NGINX_RUNTIME_DIR" .
fi

log "Резервная копия: $BACKUP_DIR"
log 'Исправляю только Nginx-vhost сайтов. FTP/FTPS, SQL, боты и пароль admin не изменяются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
"$CONTROL_BIN" nginx-site-routing-fix

# Старые неудачные попытки могли оставить public_html без Nginx-конфига.
# add-site безопасно сохраняет загруженные файлы и создаёт/пересоздаёт только vhost.
log "Создаю или восстанавливаю vhost: $TARGET_DOMAIN"
"$CONTROL_BIN" add-site "$TARGET_DOMAIN" '' '' >/dev/null

nginx -t >/dev/null || fail 'Nginx-конфиг не прошёл проверку'
TARGET_ROOT="/var/www/hyper-host-sites/$TARGET_DOMAIN/public_html"
TARGET_CONF="/etc/nginx/sites-enabled/hyper-host-site-$TARGET_DOMAIN.conf"
[[ -d "$TARGET_ROOT" ]] || fail "Не создан public_html: $TARGET_ROOT"
[[ -e "$TARGET_CONF" ]] || fail "Не включён vhost: $TARGET_CONF"

request_http(){
  local host="$1" path="${2:-/}" expected="${3:-}" i body=''
  for i in $(seq 1 30); do
    body="$(curl --noproxy '*' -fsS --max-time 4 --resolve "$host:80:$SERVER_IP" "http://$host$path" 2>/dev/null || true)"
    if [[ -n "$body" && ( -z "$expected" || "$body" == *"$expected"* ) ]]; then
      printf '%s' "$body"; return 0
    fi
    sleep 0.2
  done
  printf '%s' "$body"
  return 1
}
request_https(){
  local host="$1" path="${2:-/}" expected="${3:-}" i body=''
  for i in $(seq 1 30); do
    body="$(curl --noproxy '*' -kfsS --max-time 4 --resolve "$host:443:$SERVER_IP" "https://$host$path" 2>/dev/null || true)"
    if [[ -n "$body" && ( -z "$expected" || "$body" == *"$expected"* ) ]]; then
      printf '%s' "$body"; return 0
    fi
    sleep 0.2
  done
  printf '%s' "$body"
  return 1
}
verify_probe(){
  local host="$1" root="$2" token probe http https
  token="HYPER-HOST-v70-$host-$(date +%s)-$$-$RANDOM"
  probe="$root/.hyper-host-v70-probe-$$-$RANDOM.txt"
  TARGET_PROBE_PATH="$probe"
  printf '%s' "$token" > "$probe"
  chown www-data:www-data "$probe" 2>/dev/null || true
  chmod 0644 "$probe" 2>/dev/null || true
  http="$(request_http "$host" "/${probe##*/}" "$token" || true)"
  https="$(request_https "$host" "/${probe##*/}" "$token" || true)"
  [[ "$http" == "$token" ]] || fail "$host по HTTP попал не в $root"
  [[ "$https" == "$token" ]] || fail "$host по HTTPS попал не в $root"
  rm -f "$probe"; TARGET_PROBE_PATH=''
}

log "Проверяю $TARGET_DOMAIN через реальный LAN IP $SERVER_IP"
verify_probe "$TARGET_DOMAIN" "$TARGET_ROOT"

log 'Проверяю создание совершенно нового сайта и замену заглушки файлами пользователя.'
"$CONTROL_BIN" add-site "$TEST_SITE" '' '' >/dev/null
TEST_ROOT="/var/www/hyper-host-sites/$TEST_SITE/public_html"
[[ -f "$TEST_ROOT/index.html" ]] || fail 'У нового сайта нет index.html-заглушки'
STUB="$(request_http "$TEST_SITE" / "$TEST_SITE работает" || true)"
grep -Fq "$TEST_SITE работает" <<<"$STUB" || fail 'Новый сайт не показывает собственную заглушку'
MARKER="HYPER-HOST-v70-UPLOADED-$(date +%s)-$$"
printf '<!doctype html><title>%s</title><h1>%s</h1>\n' "$MARKER" "$MARKER" > "$TEST_ROOT/index.html"
chown www-data:www-data "$TEST_ROOT/index.html" 2>/dev/null || true
chmod 0664 "$TEST_ROOT/index.html" 2>/dev/null || true
BODY="$(request_http "$TEST_SITE" / "$MARKER" || true)"
grep -Fq "$MARKER" <<<"$BODY" || fail 'После загрузки index.html Nginx продолжает показывать не файлы сайта'
verify_probe "$TEST_SITE" "$TEST_ROOT"

UNKNOWN="v70-unknown-$(date +%s).test"
UNKNOWN_BODY="$(request_http "$UNKNOWN" / 'Домен не настроен' || true)"
grep -Fq 'Домен не настроен' <<<"$UNKNOWN_BODY" || fail 'Неизвестный домен попадает не в нейтральный default-vhost'

# FTP только проверяем, но не меняем.
FTP_LAN_STATE="$(systemctl is-active hyper-host-ftp-lan.service 2>/dev/null || true)"
FTP_WAN_STATE="$(systemctl is-active hyper-host-ftp-wan.service 2>/dev/null || true)"
LISTEN21="$(ss -H -lntp 'sport = :21' 2>/dev/null | head -n1 || true)"
LISTEN2121="$(ss -H -lntp 'sport = :2121' 2>/dev/null | head -n1 || true)"

ADMIN_AFTER="$(admin_hash)"; CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Хеш пароля admin изменился'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл реквизитов администратора изменился'

{
  echo 'HYPER-HOST v70 Nginx site-vhost repair'
  echo "Target domain: $TARGET_DOMAIN"
  echo "Target root: $TARGET_ROOT"
  echo 'Target HTTP/HTTPS probe: passed'
  echo 'New-site placeholder: passed'
  echo 'Uploaded index.html routing: passed'
  echo 'Unknown-domain neutral default: passed'
  echo "FTP LAN service: $FTP_LAN_STATE"
  echo "FTP WAN service: $FTP_WAN_STATE"
  echo "Listen 21: $LISTEN21"
  echo "Listen 2121: $LISTEN2121"
  echo 'Admin password: unchanged'
} > "$REPORT"
chmod 0600 "$REPORT"

"$CONTROL_BIN" delete-site "$TEST_SITE" --delete-files >/dev/null
ROLLBACK_NEEDED=0
cleanup

printf '\n============================================================\n'
printf ' %b%s%b — сайты открывают собственный public_html\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' Домен:              %s\n' "$TARGET_DOMAIN"
printf ' Корень:             %s\n' "$TARGET_ROOT"
printf ' HTTP/HTTPS:         ПРОВЕРЕНО\n'
printf ' Новые сайты:        заглушка → загруженный index.html\n'
printf ' FTP LAN:            %s / 192.168.0.179:21\n' "${FTP_LAN_STATE:-unknown}"
printf ' FTP WAN backend:    %s / 192.168.0.179:2121\n' "${FTP_WAN_STATE:-unknown}"
printf ' Публичный FTP:      90.189.208.25:21\n'
printf ' Admin password:     НЕ ИЗМЕНЁН\n'
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'
