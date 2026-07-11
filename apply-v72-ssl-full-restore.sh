#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=/opt/hyper-host
CONTROL_BIN=/usr/local/sbin/hyper-host-ctl
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
NGINX_RUNTIME_DIR="$BASE_DIR/runtime/nginx"
SITES_DIR=/var/www/hyper-host-sites
PANEL_DIR=/var/www/hyper-host
SERVER_IP=192.168.0.179
PUBLIC_IP=90.189.208.25
BACKUP_DIR="$BASE_DIR/backups/v72-ssl-full-restore-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v72-ssl-full-restore-report.txt
MAP_JSON=/root/hyper-host-v72-ssl-map.json
PROJECT=HYPER-HOST
CYAN='\033[1;36m'; RESET='\033[0m'

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

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса scripts/hhctl'
command -v nginx >/dev/null 2>&1 || fail 'Nginx не установлен'
command -v openssl >/dev/null 2>&1 || fail 'OpenSSL не установлен'

ADMIN_BEFORE="$(admin_hash)"
CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.before-v72" || true
if [[ -d "$NGINX_RUNTIME_DIR" ]]; then
  tar -czf "$BACKUP_DIR/nginx-runtime-before-v72.tar.gz" -C "$NGINX_RUNTIME_DIR" .
fi
# Сертификаты не меняем, но сохраняем список и метаданные до ремонта.
{
  find -L "$BASE_DIR/letsencrypt/live" /etc/letsencrypt/live -mindepth 2 -maxdepth 2 -name fullchain.pem -type f -print 2>/dev/null || true
} | sort -u > "$BACKUP_DIR/certificate-paths-before-v72.txt"
while IFS= read -r cert; do
  [[ -r "$cert" ]] || continue
  printf '\n=== %s ===\n' "$cert"
  openssl x509 -in "$cert" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true
done < "$BACKUP_DIR/certificate-paths-before-v72.txt" > "$BACKUP_DIR/certificate-details-before-v72.txt"

log "Резервная копия: $BACKUP_DIR"
log 'Восстанавливаю только реальные SSL-сертификаты в Nginx. FTP, SQL, боты, сайты и пароль admin не изменяются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"

# Пересобираем vhost'ы из существующих папок, но теперь с реальными сертификатами.
"$CONTROL_BIN" nginx-restore-ssl-all
nginx -t >/dev/null || fail 'После восстановления SSL nginx -t возвращает ошибку'
systemctl is-active --quiet nginx || fail 'Nginx не запущен'
"$CONTROL_BIN" nginx-ssl-map-json > "$MAP_JSON"
chmod 0600 "$MAP_JSON"

# Панель обязана оставаться доступной по LAN IP.
PANEL_PROBE="$PANEL_DIR/public/.hyper-host-v72-panel-$$.txt"
printf 'HYPER-HOST-V72-PANEL-OK' > "$PANEL_PROBE"
chown www-data:www-data "$PANEL_PROBE" 2>/dev/null || true
chmod 0644 "$PANEL_PROBE" 2>/dev/null || true
PANEL_BODY="$(curl --noproxy '*' -fsS --max-time 8 -H "Host: $SERVER_IP" "http://$SERVER_IP/${PANEL_PROBE##*/}" 2>/dev/null || true)"
rm -f "$PANEL_PROBE"
[[ "$PANEL_BODY" == 'HYPER-HOST-V72-PANEL-OK' ]] || fail 'После ремонта не открывается панель по LAN IP'

CERT_INVENTORY_COUNT="$(wc -l < "$BACKUP_DIR/certificate-paths-before-v72.txt" | tr -d ' ')"
HTTPS_COUNT="$(python3 - "$MAP_JSON" <<'PY'
import json,sys
items=json.load(open(sys.argv[1],encoding='utf-8'))
print(sum(1 for x in items if x.get('https')))
PY
)"
SITE_COUNT="$(python3 - "$MAP_JSON" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1],encoding='utf-8'))))
PY
)"

# Для каждого восстановленного HTTPS-vhost проверяем, что Nginx реально отдаёт
# тот сертификат, который указан в его конфиге, и что он подходит домену.
VERIFY_TMP="$(mktemp -d /tmp/hyper-host-v72-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_TMP"' EXIT
VERIFIED=0
while IFS=$'\t' read -r domain configured_cert; do
  [[ -n "$domain" && -r "$configured_cert" ]] || continue
  served="$VERIFY_TMP/${domain}.served.pem"
  timeout 12 openssl s_client -connect "$SERVER_IP:443" -servername "$domain" -showcerts </dev/null 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' > "$served" || true
  [[ -s "$served" ]] || fail "Nginx не отдал TLS-сертификат для $domain"
  openssl x509 -in "$served" -noout -checkhost "$domain" >/dev/null 2>&1 \
    || fail "Nginx отдаёт неправильный сертификат для $domain"
  served_fp="$(openssl x509 -in "$served" -noout -fingerprint -sha256 | cut -d= -f2)"
  configured_fp="$(openssl x509 -in "$configured_cert" -noout -fingerprint -sha256 | cut -d= -f2)"
  [[ "$served_fp" == "$configured_fp" ]] || fail "Для $domain Nginx отдаёт не тот сертификат, который записан в vhost"
  VERIFIED=$((VERIFIED+1))
done < <(python3 - "$MAP_JSON" <<'PY'
import json,sys
for x in json.load(open(sys.argv[1],encoding='utf-8')):
    if x.get('https') and x.get('certificate'):
        print(f"{x['domain']}\t{x['certificate']}")
PY
)

if [[ "$CERT_INVENTORY_COUNT" -gt 0 && "$HTTPS_COUNT" -eq 0 ]]; then
  fail "На сервере найдено сертификатов: $CERT_INVENTORY_COUNT, но ни один сайт не получил HTTPS-vhost"
fi

ADMIN_AFTER="$(admin_hash)"
CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Хеш пароля admin изменился'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл реквизитов администратора изменился'

{
  echo 'HYPER-HOST v72 SSL full restore'
  echo "Panel LAN: http://$SERVER_IP/"
  echo "Panel WAN: http://$PUBLIC_IP/"
  echo 'Panel domain: https://panel.hyper-host.pw/'
  echo "Existing certificate files found: $CERT_INVENTORY_COUNT"
  echo "Site vhosts rebuilt: $SITE_COUNT"
  echo "HTTPS site vhosts restored: $HTTPS_COUNT"
  echo "Served certificates verified: $VERIFIED"
  echo 'Admin password: unchanged'
  echo 'FTP/SQL/bots/site files: untouched'
  echo "Backup: $BACKUP_DIR"
  echo
  echo 'SSL map:'
  python3 -m json.tool "$MAP_JSON" 2>/dev/null || cat "$MAP_JSON"
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' %b%s%b — SSL доменов восстановлен\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' Найдено сертификатов:      %s\n' "$CERT_INVENTORY_COUNT"
printf ' Восстановлено vhost:       %s\n' "$SITE_COUNT"
printf ' HTTPS-сайтов:              %s\n' "$HTTPS_COUNT"
printf ' Проверено сертификатов:    %s\n' "$VERIFIED"
printf ' Панель LAN:                http://%s/\n' "$SERVER_IP"
printf ' Панель domain:             https://panel.hyper-host.pw/\n'
printf ' FTP/SQL/боты/файлы:        НЕ ИЗМЕНЯЛИСЬ\n'
printf ' Admin password:            НЕ ИЗМЕНЁН\n'
printf ' Backup:                    %s\n' "$BACKUP_DIR"
printf ' Отчёт:                     %s\n' "$REPORT"
printf '============================================================\n'
