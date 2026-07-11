#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=/opt/hyper-host
CONTROL_BIN=/usr/local/sbin/hyper-host-ctl
AUTH_BUILDER="$BASE_DIR/bin/proftpd_auth_sync.py"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
PROFTPD_DIR="$BASE_DIR/proftpd"
NGINX_RUNTIME_DIR="$BASE_DIR/runtime/nginx"
TARGET_DOMAIN="${1:-beta.mystockbot.xyz}"
TEST_SITE="v69-site-test-$(date +%s).test"
TARGET_PROBE="hyper-host-v69-route-$(date +%s)-$$.txt"
TARGET_PROBE_PATH=""
BACKUP_DIR="$BASE_DIR/backups/v69-dual-ftp-site-routing-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v69-dual-ftp-site-routing-report.txt
LAN_IP=192.168.0.179
PUBLIC_IP=90.189.208.25
LAN_PORT=21
WAN_BACKEND_PORT=2121
LAN_CIDR=192.168.0.0/24
PROJECT=HYPER-HOST
CYAN='\033[1;36m'; RESET='\033[0m'
ROLLBACK_NEEDED=1
FTP_COMMITTED=0
REDIRECT_EXISTED=0
TEST_USER="hhv69$(date +%s)"
TEST_PASS="V69$(openssl rand -hex 16)"
TEST_DIR="$(mktemp -d /tmp/hhv69-dual.XXXXXX)"
LAN_SRC="$TEST_DIR/lan-source.bin"
LAN_DST="$TEST_DIR/lan-downloaded.bin"
WAN_SRC="$TEST_DIR/wan-source.bin"
WAN_DST="$TEST_DIR/wan-downloaded.bin"
LAN_LOG="$TEST_DIR/lan-lftp.log"
WAN_LOG="$TEST_DIR/wan-lftp.log"

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
redirect_exists(){
  iptables -t nat -C PREROUTING -p tcp --dport "$LAN_PORT" ! -s "$LAN_CIDR" -j REDIRECT --to-ports "$WAN_BACKEND_PORT" >/dev/null 2>&1
}
cleanup(){
  [[ -x "$CONTROL_BIN" ]] && "$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null 2>&1 || true
  [[ -x "$CONTROL_BIN" ]] && "$CONTROL_BIN" delete-site "$TEST_SITE" --delete-files >/dev/null 2>&1 || true
  [[ -n "$TARGET_PROBE_PATH" ]] && rm -f "$TARGET_PROBE_PATH" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR" >/dev/null 2>&1 || true
}
restore(){
  [[ -d "$BACKUP_DIR" ]] || return 0
  printf '[%b%s%b] Ошибка установки. Возвращаю только компонент, который не прошёл проверку.\n' "$CYAN" "$PROJECT" "$RESET" >&2
  if [[ "$FTP_COMMITTED" != 1 ]]; then
    if [[ "$REDIRECT_EXISTED" == 0 ]]; then
      iptables -t nat -D PREROUTING -p tcp --dport "$LAN_PORT" ! -s "$LAN_CIDR" -j REDIRECT --to-ports "$WAN_BACKEND_PORT" >/dev/null 2>&1 || true
    fi
    [[ -f "$BACKUP_DIR/hyper-host-ctl.bak" ]] && install -m0755 "$BACKUP_DIR/hyper-host-ctl.bak" "$CONTROL_BIN" || true
    [[ -f "$BACKUP_DIR/proftpd_auth_sync.py.bak" ]] && install -m0755 "$BACKUP_DIR/proftpd_auth_sync.py.bak" "$AUTH_BUILDER" || true
    if [[ -d "$BACKUP_DIR/proftpd.bak" ]]; then rm -rf "$PROFTPD_DIR"; cp -a "$BACKUP_DIR/proftpd.bak" "$PROFTPD_DIR"; fi
  else
    printf '[%b%s%b] FTP/FTPS уже проверен и сохранён; откатываю только Nginx.\n' "$CYAN" "$PROJECT" "$RESET" >&2
  fi
  if [[ -f "$BACKUP_DIR/nginx-runtime.tar.gz" && -d "$NGINX_RUNTIME_DIR" ]]; then
    find "$NGINX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    tar -xzf "$BACKUP_DIR/nginx-runtime.tar.gz" -C "$NGINX_RUNTIME_DIR" >/dev/null 2>&1 || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  "$CONTROL_BIN" ftp-fix >/dev/null 2>&1 || true
}
on_exit(){ rc=$?; trap - EXIT ERR INT TERM; cleanup; if [[ $rc -ne 0 && $ROLLBACK_NEEDED == 1 ]]; then restore; fi; exit $rc; }
trap on_exit EXIT
trap 'exit 130' INT TERM

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$ROOT_DIR/scripts/proftpd_auth_sync.py" ]] || fail 'Не найден scripts/proftpd_auth_sync.py'
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса hhctl'
python3 -m py_compile "$ROOT_DIR/scripts/proftpd_auth_sync.py" || fail 'Ошибка синтаксиса proftpd_auth_sync.py'
redirect_exists && REDIRECT_EXISTED=1 || true

ADMIN_BEFORE="$(admin_hash)"; CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/bin"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$AUTH_BUILDER" ]] && cp -a "$AUTH_BUILDER" "$BACKUP_DIR/proftpd_auth_sync.py.bak" || true
[[ -d "$PROFTPD_DIR" ]] && cp -a "$PROFTPD_DIR" "$BACKUP_DIR/proftpd.bak" || true
if [[ -d "$NGINX_RUNTIME_DIR" ]]; then
  tar -czf "$BACKUP_DIR/nginx-runtime.tar.gz" -C "$NGINX_RUNTIME_DIR" .
fi

log "Резервная копия: $BACKUP_DIR"
log 'Включаю локальный и публичный FTPS и исправляю маршрутизацию новых сайтов. SQL, боты и пароль admin не изменяются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$AUTH_BUILDER"
"$CONTROL_BIN" ftp-fix
"$CONTROL_BIN" nginx-site-routing-fix

command -v proftpd >/dev/null 2>&1 || fail 'ProFTPD не установлен'
command -v lftp >/dev/null 2>&1 || fail 'lftp не установлен'
proftpd -t -c "$PROFTPD_DIR/proftpd-lan.conf" || fail 'LAN-конфиг ProFTPD не прошёл проверку'
proftpd -t -c "$PROFTPD_DIR/proftpd-wan.conf" || fail 'WAN-конфиг ProFTPD не прошёл проверку'
systemctl is-active --quiet hyper-host-ftp-lan.service || fail 'LAN FTP-сервис не активен'
systemctl is-active --quiet hyper-host-ftp-wan.service || fail 'WAN FTP backend не активен'
ss -H -lntp 'sport = :21' | grep -q proftpd || fail 'TCP 21 слушает не ProFTPD'
ss -H -lntp 'sport = :2121' | grep -q proftpd || fail 'TCP 2121 слушает не ProFTPD'
grep -Eq '^[[:space:]]*MasqueradeAddress[[:space:]]+192\.168\.0\.179([[:space:]]|$)' "$PROFTPD_DIR/proftpd-lan.conf" || fail 'LAN PASV-IP настроен неверно'
grep -Eq '^[[:space:]]*PassivePorts[[:space:]]+40000[[:space:]]+40049([[:space:]]|$)' "$PROFTPD_DIR/proftpd-lan.conf" || fail 'LAN PASV-диапазон настроен неверно'
grep -Eq '^[[:space:]]*MasqueradeAddress[[:space:]]+90\.189\.208\.25([[:space:]]|$)' "$PROFTPD_DIR/proftpd-wan.conf" || fail 'WAN PASV-IP настроен неверно'
grep -Eq '^[[:space:]]*PassivePorts[[:space:]]+40050[[:space:]]+40100([[:space:]]|$)' "$PROFTPD_DIR/proftpd-wan.conf" || fail 'WAN PASV-диапазон настроен неверно'
redirect_exists || fail 'Не включено перенаправление внешнего TCP 21 на WAN backend 2121'

"$CONTROL_BIN" create-ftp "$TEST_USER" "$TEST_PASS" files >/dev/null
printf 'HYPER-HOST v69 LAN transfer\n%.0s' {1..4096} > "$LAN_SRC"
printf 'HYPER-HOST v69 WAN transfer\n%.0s' {1..4096} > "$WAN_SRC"
rm -f "$LAN_DST" "$WAN_DST" "$LAN_LOG" "$WAN_LOG"

log 'Проверяю локальный FTPS: 192.168.0.179:21, PASV 192.168.0.179, upload/download.'
TEST_USER="$TEST_USER" TEST_PASS="$TEST_PASS" LAN_IP="$LAN_IP" python3 - <<'PY'
import ftplib,os,re,ssl
ctx=ssl._create_unverified_context(); ctx.minimum_version=ssl.TLSVersion.TLSv1_2; ctx.maximum_version=ssl.TLSVersion.TLSv1_2
f=ftplib.FTP_TLS(context=ctx,timeout=15)
f.connect(os.environ['LAN_IP'],21); f.auth(); f.login(os.environ['TEST_USER'],os.environ['TEST_PASS']); f.prot_p()
r=f.sendcmd('PASV')
m=re.search(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)',r)
if not m: raise SystemExit('LAN PASV response is invalid: '+r)
ip='.'.join(m.group(i) for i in range(1,5)); port=int(m.group(5))*256+int(m.group(6))
if ip != os.environ['LAN_IP'] or not 40000 <= port <= 40049:
    raise SystemExit(f'LAN PASV returned {ip}:{port}')
f.quit(); print(f'LAN PASV OK: {ip}:{port}')
PY
if ! timeout 90 lftp -d -u "$TEST_USER,$TEST_PASS" "ftp://$LAN_IP:21" >"$LAN_LOG" 2>&1 <<LFTP
set cmd:fail-exit true
set xfer:clobber true
set ssl:verify-certificate no
set ftp:ssl-force true
set ftp:ssl-protect-data true
set ftp:ssl-protect-list true
set ftp:ssl-auth TLS
set ftp:passive-mode true
set ftp:prefer-epsv false
set ftp:fix-pasv-address false
set net:timeout 15
set net:max-retries 1
cls -1
put $LAN_SRC -o v69-lan-test.bin
get v69-lan-test.bin -o $LAN_DST
rm v69-lan-test.bin
bye
LFTP
then
  cat "$LAN_LOG" >&2 || true
  fail 'Локальный FTPS-тест не прошёл'
fi
[[ -f "$LAN_DST" ]] || fail 'LAN FTP не скачал тестовый файл'
LAN_SRC_SHA="$(sha256sum "$LAN_SRC"|awk '{print $1}')"; LAN_DST_SHA="$(sha256sum "$LAN_DST"|awk '{print $1}')"
[[ "$LAN_SRC_SHA" == "$LAN_DST_SHA" ]] || fail 'LAN SHA-256 не совпадает'

log 'Проверяю WAN backend: TCP 2121, публичный PASV-IP и TLS data-channel.'
TEST_USER="$TEST_USER" TEST_PASS="$TEST_PASS" LAN_IP="$LAN_IP" PUBLIC_IP="$PUBLIC_IP" python3 - <<'PY'
import ftplib,os,re,ssl
ctx=ssl._create_unverified_context(); ctx.minimum_version=ssl.TLSVersion.TLSv1_2; ctx.maximum_version=ssl.TLSVersion.TLSv1_2
f=ftplib.FTP_TLS(context=ctx,timeout=15)
f.connect(os.environ['LAN_IP'],2121); f.auth(); f.login(os.environ['TEST_USER'],os.environ['TEST_PASS']); f.prot_p()
r=f.sendcmd('PASV')
m=re.search(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)',r)
if not m: raise SystemExit('WAN PASV response is invalid: '+r)
ip='.'.join(m.group(i) for i in range(1,5)); port=int(m.group(5))*256+int(m.group(6))
if ip != os.environ['PUBLIC_IP'] or not 40050 <= port <= 40100:
    raise SystemExit(f'WAN PASV returned {ip}:{port}')
f.quit(); print(f'WAN PASV OK: {ip}:{port}')
PY
# Для серверного теста заменяем только PASV-IP на LAN_IP; порт и TLS data-channel
# остаются от реального WAN-инстанса. Из интернета клиент использует публичный IP.
if ! timeout 90 lftp -d -u "$TEST_USER,$TEST_PASS" "ftp://$LAN_IP:2121" >"$WAN_LOG" 2>&1 <<LFTP
set cmd:fail-exit true
set xfer:clobber true
set ssl:verify-certificate no
set ftp:ssl-force true
set ftp:ssl-protect-data true
set ftp:ssl-protect-list true
set ftp:ssl-auth TLS
set ftp:passive-mode true
set ftp:prefer-epsv false
set ftp:fix-pasv-address true
set net:timeout 15
set net:max-retries 1
cls -1
put $WAN_SRC -o v69-wan-test.bin
get v69-wan-test.bin -o $WAN_DST
rm v69-wan-test.bin
bye
LFTP
then
  cat "$WAN_LOG" >&2 || true
  fail 'WAN backend FTPS-тест не прошёл'
fi
[[ -f "$WAN_DST" ]] || fail 'WAN backend не скачал тестовый файл'
WAN_SRC_SHA="$(sha256sum "$WAN_SRC"|awk '{print $1}')"; WAN_DST_SHA="$(sha256sum "$WAN_DST"|awk '{print $1}')"
[[ "$WAN_SRC_SHA" == "$WAN_DST_SHA" ]] || fail 'WAN SHA-256 не совпадает'
FTP_COMMITTED=1

local_http(){
  local host="$1" path="${2:-/}"
  curl --noproxy '*' -fsS --max-time 12 -H "Host: $host" "http://127.0.0.1${path}"
}
local_https(){
  local host="$1" path="${2:-/}"
  curl --noproxy '*' -kfsS --max-time 12 --resolve "$host:443:127.0.0.1" "https://${host}${path}"
}
show_nginx_route_debug(){
  local host="$1"
  echo '--- nginx enabled ---' >&2
  ls -la /etc/nginx/sites-enabled >&2 || true
  echo "--- configs containing $host ---" >&2
  grep -Rns -- "$host" /etc/nginx/sites-enabled /etc/nginx/sites-available 2>/dev/null >&2 || true
  echo '--- active server_name/default_server/root lines ---' >&2
  nginx -T 2>&1 | grep -E 'configuration file|server_name|default_server|root ' | tail -n 220 >&2 || true
}

log 'Проверяю Nginx: новый домен открывает свой public_html по HTTP/HTTPS, а не панель.'
NGINX_TEST_OUT="$(nginx -t 2>&1)" || { printf '%s\n' "$NGINX_TEST_OUT" >&2; fail 'Nginx-конфиг не прошёл проверку после исправления маршрутизации'; }
if grep -Fq 'conflicting server name "_"' <<<"$NGINX_TEST_OUT"; then
  printf '%s\n' "$NGINX_TEST_OUT" >&2
  fail 'Остался дублирующий server_name _'
fi
"$CONTROL_BIN" add-site "$TEST_SITE" '' '' >/dev/null
TEST_SITE_ROOT="/var/www/hyper-host-sites/$TEST_SITE/public_html"
TEST_SITE_CONF="/etc/nginx/sites-enabled/hyper-host-site-$TEST_SITE.conf"
[[ -f "$TEST_SITE_ROOT/index.html" ]] || fail 'Для нового сайта не создана заглушка index.html'
[[ -e "$TEST_SITE_CONF" ]] || fail 'Конфиг нового сайта не включён в sites-enabled'
grep -Eq "server_name[[:space:]]+$TEST_SITE([[:space:]]|;)" "$TEST_SITE_CONF" || fail 'В конфиге нового сайта нет точного server_name'
grep -Fq "root $TEST_SITE_ROOT;" "$TEST_SITE_CONF" || fail 'В конфиге нового сайта неправильный public_html'
STUB_HTTP="$(local_http "$TEST_SITE" / 2>/dev/null || true)"
STUB_HTTPS="$(local_https "$TEST_SITE" / 2>/dev/null || true)"
if ! grep -Fq "$TEST_SITE работает" <<<"$STUB_HTTP"; then
  printf '%s\n' "HTTP response: $STUB_HTTP" >&2
  show_nginx_route_debug "$TEST_SITE"
  fail 'Новый сайт по HTTP не отдаёт собственную заглушку'
fi
if ! grep -Fq "$TEST_SITE работает" <<<"$STUB_HTTPS"; then
  printf '%s\n' "HTTPS response: $STUB_HTTPS" >&2
  show_nginx_route_debug "$TEST_SITE"
  fail 'Новый сайт по HTTPS не отдаёт собственную заглушку'
fi
SITE_MARKER="HYPER-HOST-v69-user-files-$(date +%s)-$$"
printf '<!doctype html><title>%s</title><h1>%s</h1>\n' "$SITE_MARKER" "$SITE_MARKER" > "$TEST_SITE_ROOT/index.html"
chown www-data:www-data "$TEST_SITE_ROOT/index.html" 2>/dev/null || true
chmod 0664 "$TEST_SITE_ROOT/index.html" 2>/dev/null || true
USER_HTTP="$(local_http "$TEST_SITE" / 2>/dev/null || true)"
USER_HTTPS="$(local_https "$TEST_SITE" / 2>/dev/null || true)"
grep -Fq "$SITE_MARKER" <<<"$USER_HTTP" || { show_nginx_route_debug "$TEST_SITE"; fail 'После замены index.html сайт по HTTP не показывает загруженные файлы'; }
grep -Fq "$SITE_MARKER" <<<"$USER_HTTPS" || { show_nginx_route_debug "$TEST_SITE"; fail 'После замены index.html сайт по HTTPS не показывает загруженные файлы'; }
UNKNOWN_HOST="v69-unknown-$(date +%s).test"
UNKNOWN_BODY="$(local_http "$UNKNOWN_HOST" / 2>/dev/null || true)"
grep -Fq 'Домен не настроен' <<<"$UNKNOWN_BODY" || { show_nginx_route_debug "$UNKNOWN_HOST"; fail 'Неизвестный домен всё ещё попадает не в neutral default vhost'; }

TARGET_ROUTE='skipped: site not found'
TARGET_ROOT="/var/www/hyper-host-sites/$TARGET_DOMAIN/public_html"
TARGET_CONF="/etc/nginx/sites-available/hyper-host-site-$TARGET_DOMAIN.conf"
if [[ -d "$TARGET_ROOT" && -f "$TARGET_CONF" ]]; then
  TARGET_TOKEN="HYPER-HOST-v69-target-$TARGET_DOMAIN-$(date +%s)-$$"
  TARGET_PROBE_PATH="$TARGET_ROOT/$TARGET_PROBE"
  printf '%s' "$TARGET_TOKEN" > "$TARGET_PROBE_PATH"
  chown www-data:www-data "$TARGET_PROBE_PATH" 2>/dev/null || true
  chmod 0644 "$TARGET_PROBE_PATH" 2>/dev/null || true
  TARGET_HTTP="$(local_http "$TARGET_DOMAIN" "/$TARGET_PROBE" 2>/dev/null || true)"
  TARGET_HTTPS="$(local_https "$TARGET_DOMAIN" "/$TARGET_PROBE" 2>/dev/null || true)"
  [[ "$TARGET_HTTP" == "$TARGET_TOKEN" ]] || { show_nginx_route_debug "$TARGET_DOMAIN"; fail "$TARGET_DOMAIN по HTTP открывает не свой public_html"; }
  [[ "$TARGET_HTTPS" == "$TARGET_TOKEN" ]] || { show_nginx_route_debug "$TARGET_DOMAIN"; fail "$TARGET_DOMAIN по HTTPS открывает не свой public_html"; }
  TARGET_ROUTE='HTTP/HTTPS public_html: passed'
  rm -f "$TARGET_PROBE_PATH"; TARGET_PROBE_PATH=''
fi

"$CONTROL_BIN" delete-site "$TEST_SITE" --delete-files >/dev/null

"$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null
ADMIN_AFTER="$(admin_hash)"; CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Хеш пароля admin изменился'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл реквизитов администратора изменился'
DOCTOR_JSON="$("$CONTROL_BIN" ftp-doctor-json 2>/dev/null || true)"
{
  echo 'HYPER-HOST v69 dual FTP + final Nginx site routing'
  echo 'LAN endpoint: 192.168.0.179:21'
  echo 'LAN PASV: 40000-40049, address 192.168.0.179'
  echo 'Public endpoint: 90.189.208.25:21'
  echo 'WAN internal backend: 192.168.0.179:2121'
  echo 'WAN PASV: 40050-40100, address 90.189.208.25'
  echo 'External redirect: non-LAN TCP 21 -> internal TCP 2121'
  echo "LAN SHA-256: $LAN_SRC_SHA / $LAN_DST_SHA"
  echo "WAN SHA-256: $WAN_SRC_SHA / $WAN_DST_SHA"
  echo 'Nginx default vhost: single neutral catch-all; panel pinned to exact domain/IP'
  echo 'New-site HTTP/HTTPS direct-vhost test: passed'
  echo 'Uploaded index.html routing: passed'
  echo "Target domain ($TARGET_DOMAIN): $TARGET_ROUTE"
  echo 'Admin password: unchanged'
  echo "Doctor: $DOCTOR_JSON"
  echo; echo 'LAN lftp output:'; cat "$LAN_LOG"
  echo; echo 'WAN backend lftp output:'; cat "$WAN_LOG"
} > "$REPORT"
chmod 0600 "$REPORT"
ROLLBACK_NEEDED=0
cleanup

printf '\n============================================================\n'
printf ' %b%s%b — локальный/публичный FTPS и маршрутизация сайтов готовы\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' LAN:                %s:21\n' "$LAN_IP"
printf ' LAN PASV:           40000-40049\n'
printf ' WAN:                %s:21\n' "$PUBLIC_IP"
printf ' WAN PASV:           40050-40100\n'
printf ' Внутренний backend: %s:2121\n' "$LAN_IP"
printf ' TLS:                explicit TLS 1.2\n'
printf ' Сайты HTTP/HTTPS:   свой public_html, не панель\n'
printf ' Проверен домен:     %s\n' "$TARGET_DOMAIN"
printf ' Admin password:     НЕ ИЗМЕНЁН\n'
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'
printf ' Роутер: TCP 21 -> %s:21\n' "$LAN_IP"
printf ' Роутер: TCP 40000-40100 -> %s:40000-40100\n' "$LAN_IP"
printf '============================================================\n'
