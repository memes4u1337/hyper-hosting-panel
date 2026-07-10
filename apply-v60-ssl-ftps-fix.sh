#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/opt/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
FTP_RUNTIME="$BASE_DIR/bin/hyper_ftp_runtime.py"
CONF="/etc/hyper-host/hyper-host.conf"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
TARGET_DOMAIN="${1:-beta.mystockbot.xyz}"
SSL_EMAIL="${2:-}"
BACKUP_DIR="$BASE_DIR/backups/v60-ssl-ftps-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v60-ssl-ftps-report.txt"
PROJECT='HYPER-HOST'
CYAN='\033[1;36m'; RESET='\033[0m'

log(){ printf '[%b%s%b] %s\n' "$CYAN" "$PROJECT" "$RESET" "$*"; }
fail(){ printf '[%b%s%b] ERROR: %s\n' "$CYAN" "$PROJECT" "$RESET" "$*" >&2; exit 1; }

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$ROOT_DIR/scripts/hyper_ftp_runtime.py" ]] || fail 'Не найден scripts/hyper_ftp_runtime.py'
[[ -f "$CONF" ]] || fail "Не найден $CONF"
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса scripts/hhctl'
python3 -m py_compile "$ROOT_DIR/scripts/hyper_ftp_runtime.py" || fail 'Ошибка синтаксиса FTP runtime'

# shellcheck disable=SC1090
source "$CONF"
SERVER_IP="${SERVER_IP:-192.168.0.179}"
PUBLIC_IP="${PUBLIC_IP:-90.189.208.25}"
PANEL_DOMAIN="${PANEL_DOMAIN:-_}"

admin_hash(){
  [[ -f "$DB_PATH" ]] || return 0
  php -r '
    try {
      $db=new PDO("sqlite:".$argv[1]);
      $q=$db->prepare("SELECT password_hash FROM users WHERE username = :u LIMIT 1");
      $q->execute([":u"=>"admin"]);
      echo (string)($q->fetchColumn() ?: "");
    } catch (Throwable $e) {}
  ' "$DB_PATH" 2>/dev/null || true
}
file_sha(){ [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || true; }

ADMIN_HASH_BEFORE="$(admin_hash)"
CRED_SHA_BEFORE="$(file_sha "$CREDENTIALS_FILE")"

log "Создаю резервную копию: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/bin"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$FTP_RUNTIME" ]] && cp -a "$FTP_RUNTIME" "$BACKUP_DIR/hyper_ftp_runtime.py.bak" || true
[[ -d "$BASE_DIR/runtime/nginx" ]] && cp -a "$BASE_DIR/runtime/nginx" "$BACKUP_DIR/nginx-runtime.bak" 2>/dev/null || true

log 'Устанавливаю только ACME/Certbot fix и explicit FTPS. База панели и пароль admin не изменяются.'
install -m 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m 0755 "$ROOT_DIR/scripts/hyper_ftp_runtime.py" "$FTP_RUNTIME"

log 'Подключаю текущий writable Nginx runtime.'
"$CONTROL_BIN" nginx-runtime-fix >/dev/null
nginx -t >/dev/null || fail 'nginx -t не прошёл до ACME-проверки'

if [[ -f "/etc/nginx/sites-available/hyper-host-site-$TARGET_DOMAIN.conf" ]]; then
  log "Исправляю и проверяю ACME challenge для $TARGET_DOMAIN."
  "$CONTROL_BIN" ssl-fix-site "$TARGET_DOMAIN" >/dev/null
  CHECK_JSON="$("$CONTROL_BIN" ssl-check-json "$TARGET_DOMAIN")"
  printf '%s' "$CHECK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("http_challenge_ok") else 1)' \
    || { printf '%s\n' "$CHECK_JSON" >&2; fail 'Локальная ACME-проверка всё ещё не проходит'; }
else
  log "Сайт $TARGET_DOMAIN не найден — проверяю ACME на временном виртуальном хосте."
  TEST_DOMAIN="v60-acme-test-$(date +%s).local"
  cleanup_site(){ "$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null 2>&1 || true; }
  trap cleanup_site EXIT
  "$CONTROL_BIN" add-site "$TEST_DOMAIN" '' '' >/dev/null
  "$CONTROL_BIN" ssl-fix-site "$TEST_DOMAIN" >/dev/null
  cleanup_site
  trap - EXIT
fi

log 'Поднимаю один FTP-движок с explicit TLS на TCP 21.'
"$CONTROL_BIN" ftp-fix >/dev/null

TLS_JSON="$("$CONTROL_BIN" ftp-doctor-json)"
printf '%s' "$TLS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("listen_21") and d.get("tls") else 1)' \
  || { printf '%s\n' "$TLS_JSON" >&2; fail 'FTPS не поднялся'; }

log 'Проверяю FTPS: AUTH TLS, защищённый канал данных, upload/download и удаление аккаунта.'
TEST_USER="hhv60tls$(date +%s)"
TEST_PASS="V60-$(openssl rand -hex 12)"
cleanup_ftp(){ "$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null 2>&1 || true; }
trap cleanup_ftp EXIT
"$CONTROL_BIN" create-ftp "$TEST_USER" "$TEST_PASS" files >/dev/null
FTP_USER="$TEST_USER" FTP_PASS="$TEST_PASS" python3 - <<'PYFTPS'
import ftplib, io, os, ssl
ctx=ssl._create_unverified_context()
f=ftplib.FTP_TLS(context=ctx, timeout=8)
f.connect('127.0.0.1',21)
f.auth()
f.login(os.environ['FTP_USER'], os.environ['FTP_PASS'])
f.prot_p()
payload=b'HYPER-HOST-v60-FTPS-OK\n'
f.storbinary('STOR v60-ftps-test.txt', io.BytesIO(payload))
got=bytearray(); f.retrbinary('RETR v60-ftps-test.txt', got.extend)
assert bytes(got)==payload
f.delete('v60-ftps-test.txt')
f.quit()
PYFTPS
"$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null
if FTP_USER="$TEST_USER" FTP_PASS="$TEST_PASS" python3 - <<'PYFTPSDELETED'
import ftplib, os, ssl
ctx=ssl._create_unverified_context()
f=ftplib.FTP_TLS(context=ctx, timeout=5)
f.connect('127.0.0.1',21); f.auth()
try:
    f.login(os.environ['FTP_USER'], os.environ['FTP_PASS'])
except ftplib.error_perm:
    raise SystemExit(1)
raise SystemExit(0)
PYFTPSDELETED
then
  fail 'Удалённый тестовый FTP-аккаунт всё ещё смог войти'
fi
trap - EXIT

if [[ -n "$SSL_EMAIL" && -f "/etc/nginx/sites-available/hyper-host-site-$TARGET_DOMAIN.conf" ]]; then
  log "Выпускаю SSL для $TARGET_DOMAIN."
  "$CONTROL_BIN" ssl-site "$TARGET_DOMAIN" "$SSL_EMAIL"
fi

ADMIN_HASH_AFTER="$(admin_hash)"
CRED_SHA_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_HASH_BEFORE" == "$ADMIN_HASH_AFTER" ]] || fail 'Хеш пароля admin изменился — откатись из резервной копии'
[[ "$CRED_SHA_BEFORE" == "$CRED_SHA_AFTER" ]] || fail 'Файл сохранённых данных admin изменился'

CERT_SOURCE="$(cat "$BASE_DIR/data/ftp-tls/active-source" 2>/dev/null || true)"
{
  printf 'HYPER-HOST v60 SSL + FTPS\n'
  printf 'LAN IP: %s\n' "$SERVER_IP"
  printf 'WAN IP: %s\n' "$PUBLIC_IP"
  printf 'Target domain: %s\n' "$TARGET_DOMAIN"
  printf 'ACME webroot: %s\n' "$BASE_DIR/acme-webroot"
  printf 'Certbot config: %s\n' "$BASE_DIR/letsencrypt"
  printf 'FTPS: explicit TLS, TCP 21, PASV 40000-40100\n'
  printf 'FTPS certificate: %s\n' "$CERT_SOURCE"
  printf 'Admin login: admin\n'
  printf 'Admin password: unchanged\n'
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' %b%s%b — патч SSL + FTPS установлен\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' LAN IP:             %s\n' "$SERVER_IP"
printf ' WAN IP:             %s\n' "$PUBLIC_IP"
printf ' Сайт:               http://%s/\n' "$TARGET_DOMAIN"
printf ' ACME:               работает локально\n'
printf ' Certbot data:       %s\n' "$BASE_DIR/letsencrypt"
printf ' FTPS:               explicit TLS, порт 21\n'
printf ' PASV:               40000-40100\n'
printf ' Сертификат FTPS:    %s\n' "$CERT_SOURCE"
printf ' Admin login:        admin\n'
printf ' Admin password:     НЕ ИЗМЕНЁН\n'
printf ' Отчёт:              %s\n' "$REPORT"
if [[ -z "$SSL_EMAIL" ]]; then
  printf '\n SSL для сайта не выпускался автоматически, потому что email не передан.\n'
  printf ' После патча выпусти через панель или командой:\n'
  printf ' sudo hyper-host-ctl ssl-site %s YOUR_EMAIL\n' "$TARGET_DOMAIN"
fi
printf '============================================================\n'
