#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=/opt/hyper-host
CONTROL_BIN=/usr/local/sbin/hyper-host-ctl
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
NGINX_RUNTIME_DIR="$BASE_DIR/runtime/nginx"
PANEL_DIR=/var/www/hyper-host
SERVER_IP=192.168.0.179
PUBLIC_IP=90.189.208.25
BACKUP_DIR="$BASE_DIR/backups/v73-panel-ssl-probe-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v73-panel-ssl-report.txt
MAP_JSON=/root/hyper-host-v73-ssl-map.json
PROJECT=HYPER-HOST
CYAN='\033[1;36m'; RESET='\033[0m'
ROLLBACK_NEEDED=1

log(){ printf '[%b%s%b] %s\n' "$CYAN" "$PROJECT" "$RESET" "$*"; }
fail(){ printf '[%b%s%b] ERROR: %s\n' "$CYAN" "$PROJECT" "$RESET" "$*" >&2; return 1; }
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
rollback(){
  local rc=$?
  [[ $ROLLBACK_NEEDED -eq 1 ]] || exit "$rc"
  printf '[%b%s%b] Ошибка проверки, возвращаю предыдущий Nginx runtime. FTP/SQL/боты не затрагиваются.\n' "$CYAN" "$PROJECT" "$RESET" >&2
  if [[ -f "$BACKUP_DIR/nginx-runtime-before-v73.tar.gz" ]]; then
    rm -rf "$NGINX_RUNTIME_DIR"
    mkdir -p "$NGINX_RUNTIME_DIR"
    tar -xzf "$BACKUP_DIR/nginx-runtime-before-v73.tar.gz" -C "$NGINX_RUNTIME_DIR" || true
  fi
  [[ -f "$BACKUP_DIR/hyper-host-ctl.before-v73" ]] && install -m0755 "$BACKUP_DIR/hyper-host-ctl.before-v73" "$CONTROL_BIN" || true
  nginx -t >/dev/null 2>&1 && (systemctl restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true)
  exit "$rc"
}
trap rollback ERR

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса scripts/hhctl'
command -v nginx >/dev/null 2>&1 || fail 'Nginx не установлен'
command -v curl >/dev/null 2>&1 || fail 'curl не установлен'
command -v openssl >/dev/null 2>&1 || fail 'OpenSSL не установлен'

ADMIN_BEFORE="$(admin_hash)"
CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.before-v73" || true
if [[ -d "$NGINX_RUNTIME_DIR" ]]; then
  tar -czf "$BACKUP_DIR/nginx-runtime-before-v73.tar.gz" -C "$NGINX_RUNTIME_DIR" .
fi

log "Резервная копия: $BACKUP_DIR"
log 'Исправляю только ложную проверку панели и повторно привязываю существующие SSL-сертификаты. FTP, SQL, боты, файлы сайтов и пароль admin не изменяются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"

# Команда заново создаёт panel/site vhost-ы и подключает только существующие
# сертификаты, подходящие домену по SAN/CN.
"$CONTROL_BIN" nginx-restore-ssl-all
nginx -t >/dev/null || fail 'После восстановления nginx -t возвращает ошибку'
systemctl is-active --quiet nginx || fail 'Nginx не запущен'

# В v71/v72 probe начинался с точки, а location ~ /\. запрещает dot-файлы.
# Используем обычное имя и проверяем реальный document root панели.
mkdir -p "$PANEL_DIR/public"
PANEL_NAME="hyper-host-v73-panel-probe-$$-$RANDOM.txt"
PANEL_PROBE="$PANEL_DIR/public/$PANEL_NAME"
PANEL_TOKEN="HYPER-HOST-V73-PANEL-OK-$$-$RANDOM"
printf '%s' "$PANEL_TOKEN" > "$PANEL_PROBE"
chown www-data:www-data "$PANEL_PROBE" 2>/dev/null || true
chmod 0644 "$PANEL_PROBE"
PANEL_BODY=''
for _ in $(seq 1 20); do
  PANEL_BODY="$(curl --noproxy '*' -fsS --max-time 5 -H "Host: $SERVER_IP" "http://$SERVER_IP/$PANEL_NAME" 2>/dev/null || true)"
  [[ "$PANEL_BODY" == "$PANEL_TOKEN" ]] && break
  sleep 0.25
done
rm -f "$PANEL_PROBE"
[[ "$PANEL_BODY" == "$PANEL_TOKEN" ]] || {
  echo '--- panel nginx config ---' >&2
  nginx -T 2>&1 | grep -A70 -B5 -E 'server_name .*192\.168\.0\.179|root /var/www/hyper-host/public' >&2 || true
  echo '--- panel error log ---' >&2
  tail -n 100 /var/log/nginx/hyper-host-panel.error.log >&2 2>/dev/null || true
  fail 'Панель не отдала файл из /var/www/hyper-host/public по LAN IP'
}

# Главная страница может отвечать 200/302/401 в зависимости от авторизации,
# но не должна попадать в default-заглушку/404.
PANEL_STATUS="$(curl --noproxy '*' -sS -o /tmp/hyper-host-v73-panel-home.$$ -w '%{http_code}' --max-time 8 -H "Host: $SERVER_IP" "http://$SERVER_IP/" 2>/dev/null || true)"
PANEL_HOME="$(cat /tmp/hyper-host-v73-panel-home.$$ 2>/dev/null || true)"
rm -f /tmp/hyper-host-v73-panel-home.$$
[[ "$PANEL_STATUS" =~ ^(200|301|302|303|307|308|401|403)$ ]] || fail "Панель по LAN IP вернула HTTP $PANEL_STATUS"
[[ "$PANEL_HOME" != *'Домен не настроен'* ]] || fail 'LAN IP всё ещё попадает в default-заглушку вместо панели'

"$CONTROL_BIN" nginx-ssl-map-json > "$MAP_JSON"
chmod 0600 "$MAP_JSON"

# Проверяем каждый HTTPS vhost через SNI: сертификат должен подходить домену
# и совпадать с сертификатом, указанным в его конфиге.
VERIFY_TMP="$(mktemp -d /tmp/hyper-host-v73-verify.XXXXXX)"
VERIFIED=0
while IFS=$'\t' read -r domain configured_cert; do
  [[ -n "$domain" && -r "$configured_cert" ]] || continue
  served="$VERIFY_TMP/${domain}.served.pem"
  timeout 12 openssl s_client -connect "$SERVER_IP:443" -servername "$domain" -showcerts </dev/null 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' > "$served" || true
  [[ -s "$served" ]] || fail "Nginx не отдал TLS-сертификат для $domain"
  openssl x509 -in "$served" -noout -checkhost "$domain" >/dev/null 2>&1 || fail "Для $domain отдаётся неподходящий сертификат"
  served_fp="$(openssl x509 -in "$served" -noout -fingerprint -sha256 | cut -d= -f2)"
  configured_fp="$(openssl x509 -in "$configured_cert" -noout -fingerprint -sha256 | cut -d= -f2)"
  [[ "$served_fp" == "$configured_fp" ]] || fail "Для $domain Nginx отдаёт не сертификат из его vhost"
  VERIFIED=$((VERIFIED+1))
done < <(python3 - "$MAP_JSON" <<'PY'
import json,sys
for x in json.load(open(sys.argv[1],encoding='utf-8')):
    if x.get('https') and x.get('certificate'):
        print(f"{x['domain']}\t{x['certificate']}")
PY
)
rm -rf "$VERIFY_TMP"

ADMIN_AFTER="$(admin_hash)"
CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Хеш пароля admin изменился'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл реквизитов администратора изменился'

SITE_COUNT="$(python3 - "$MAP_JSON" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1],encoding='utf-8'))))
PY
)"
HTTPS_COUNT="$(python3 - "$MAP_JSON" <<'PY'
import json,sys
print(sum(1 for x in json.load(open(sys.argv[1],encoding='utf-8')) if x.get('https')))
PY
)"

{
  echo 'HYPER-HOST v73 panel + SSL probe fix'
  echo "Panel LAN: http://$SERVER_IP/"
  echo "Panel WAN: http://$PUBLIC_IP/"
  echo 'Panel document-root probe: passed'
  echo "Panel home HTTP status: $PANEL_STATUS"
  echo "Site vhosts: $SITE_COUNT"
  echo "HTTPS vhosts: $HTTPS_COUNT"
  echo "Served certificates verified: $VERIFIED"
  echo 'Admin password: unchanged'
  echo 'FTP/SQL/bots/site files: untouched'
  echo "Backup: $BACKUP_DIR"
  echo
  python3 -m json.tool "$MAP_JSON" 2>/dev/null || cat "$MAP_JSON"
} > "$REPORT"
chmod 0600 "$REPORT"

ROLLBACK_NEEDED=0
trap - ERR
printf '\n============================================================\n'
printf ' %b%s%b — панель и SSL восстановлены\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' Панель LAN:                http://%s/\n' "$SERVER_IP"
printf ' Панель WAN:                http://%s/\n' "$PUBLIC_IP"
printf ' Проверка document root:    OK\n'
printf ' HTTP статус панели:        %s\n' "$PANEL_STATUS"
printf ' Сайтов:                    %s\n' "$SITE_COUNT"
printf ' HTTPS vhost:               %s\n' "$HTTPS_COUNT"
printf ' Сертификатов проверено:    %s\n' "$VERIFIED"
printf ' FTP/SQL/боты/файлы:        НЕ ИЗМЕНЯЛИСЬ\n'
printf ' Admin password:            НЕ ИЗМЕНЁН\n'
printf ' Отчёт:                     %s\n' "$REPORT"
printf ' Backup:                    %s\n' "$BACKUP_DIR"
printf '============================================================\n'
