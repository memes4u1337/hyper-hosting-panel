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
TARGET_DOMAIN="${1:-beta.mystockbot.xyz}"
SERVER_IP=192.168.0.179
PUBLIC_IP=90.189.208.25
BACKUP_DIR="$BASE_DIR/backups/v71-nginx-full-recovery-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v71-nginx-full-recovery-report.txt
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
[[ "$TARGET_DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || fail "Некорректный домен: $TARGET_DOMAIN"

ADMIN_BEFORE="$(admin_hash)"
CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.before-v71" || true
if [[ -d "$NGINX_RUNTIME_DIR" ]]; then
  tar -czf "$BACKUP_DIR/nginx-runtime-before-v71.tar.gz" -C "$NGINX_RUNTIME_DIR" .
fi

TARGET_ROOT="$SITES_DIR/$TARGET_DOMAIN/public_html"
mkdir -p "$TARGET_ROOT" "$SITES_DIR/$TARGET_DOMAIN/logs"
if [[ -f "$TARGET_ROOT/index.html" ]]; then
  cp -a "$TARGET_ROOT/index.html" "$BACKUP_DIR/${TARGET_DOMAIN}-index.html.before-v71"
fi
if [[ -f "$TARGET_ROOT/index.php" ]]; then
  cp -a "$TARGET_ROOT/index.php" "$BACKUP_DIR/${TARGET_DOMAIN}-index.php.before-v71"
fi

log "Резервная копия: $BACKUP_DIR"
log 'Восстанавливаю только Nginx: панель, все существующие домены и будущие сайты. FTP/SQL/боты/admin не меняются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"

# Удаляем только мусорные тестовые домены предыдущих неудачных установщиков.
find "$SITES_DIR" -mindepth 1 -maxdepth 1 -type d \
  \( -name 'v68-site-test-*.test' -o -name 'v69-site-test-*.test' -o -name 'v70-site-test-*.test' \) \
  -exec rm -rf {} + 2>/dev/null || true

# Пользователь попросил для beta отдельную заглушку. Старый index уже сохранён в backup.
cat > "$TARGET_ROOT/index.html" <<EOFPLACEHOLDER
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${TARGET_DOMAIN} — сайт создан</title>
  <style>
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#071224;color:#f4f8ff;font-family:Inter,Arial,sans-serif}.card{width:min(760px,calc(100% - 32px));padding:44px;border:1px solid rgba(255,255,255,.14);border-radius:28px;background:linear-gradient(145deg,#102341,#0b182e);box-shadow:0 28px 80px rgba(0,0,0,.35)}.mark{display:inline-flex;padding:8px 13px;border-radius:999px;background:#1677ff;font-weight:700}.domain{font-size:clamp(30px,6vw,56px);margin:22px 0 12px;overflow-wrap:anywhere}.text{font-size:18px;line-height:1.6;color:#b9c8df}.path{margin-top:24px;padding:14px 16px;border-radius:14px;background:rgba(0,0,0,.24);font-family:monospace;overflow-wrap:anywhere}
  </style>
</head>
<body><main class="card"><span class="mark">HYPER-HOST</span><h1 class="domain">${TARGET_DOMAIN}</h1><p class="text">Сайт создан и готов к загрузке файлов. Замени этот index.html через FTP — после обновления откроется твой сайт.</p><div class="path">${TARGET_ROOT}</div></main></body>
</html>
EOFPLACEHOLDER
chown -R www-data:www-data "$SITES_DIR/$TARGET_DOMAIN" 2>/dev/null || true
find "$SITES_DIR/$TARGET_DOMAIN" -type d -exec chmod 2775 {} + 2>/dev/null || true
find "$SITES_DIR/$TARGET_DOMAIN" -type f -exec chmod 0664 {} + 2>/dev/null || true

"$CONTROL_BIN" nginx-full-recover
nginx -t >/dev/null || fail 'После восстановления nginx -t возвращает ошибку'
systemctl is-active --quiet nginx || fail 'Nginx не запущен'

probe_url(){
  local host="$1" path="$2" expected="$3" body=''
  body="$(curl --noproxy '*' -fsS --max-time 8 -H "Host: $host" "http://$SERVER_IP$path" 2>/dev/null || true)"
  [[ "$body" == *"$expected"* ]] || {
    printf 'Host=%s URL=http://%s%s\nОтвет:\n%s\n' "$host" "$SERVER_IP" "$path" "$body" >&2
    return 1
  }
}

# Панель должна открываться по IP, а beta — из своего public_html.
PANEL_PROBE="$PANEL_DIR/public/.hyper-host-v71-panel-final-$$.txt"
printf 'HYPER-HOST-V71-PANEL-OK' > "$PANEL_PROBE"
chown www-data:www-data "$PANEL_PROBE" 2>/dev/null || true
chmod 0644 "$PANEL_PROBE" 2>/dev/null || true
probe_url "$SERVER_IP" "/${PANEL_PROBE##*/}" 'HYPER-HOST-V71-PANEL-OK' || fail 'Панель не открывается по 192.168.0.179'
rm -f "$PANEL_PROBE"
probe_url "$TARGET_DOMAIN" / "${TARGET_DOMAIN}" || fail "$TARGET_DOMAIN не показывает собственную заглушку"

# Проверяем каждый существующий домен отдельным файлом, не затрагивая index.
SITE_COUNT=0
while IFS= read -r dir; do
  domain="${dir##*/}"
  [[ "$domain" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || continue
  case "$domain" in panel.hyper-host.pw|www.panel.hyper-host.pw) continue ;; esac
  root="$dir/public_html"
  [[ -d "$root" ]] || continue
  token="HYPER-HOST-V71-SITE-${domain}-$$-$RANDOM"
  probe="$root/.hyper-host-v71-final-$$-$RANDOM.txt"
  printf '%s' "$token" > "$probe"
  chown www-data:www-data "$probe" 2>/dev/null || true
  chmod 0644 "$probe" 2>/dev/null || true
  if ! probe_url "$domain" "/${probe##*/}" "$token"; then
    rm -f "$probe"
    fail "Домен $domain всё ещё не открывает свой public_html"
  fi
  rm -f "$probe"
  SITE_COUNT=$((SITE_COUNT+1))
done < <(find "$SITES_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort)

ADMIN_AFTER="$(admin_hash)"
CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Хеш пароля admin изменился'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл реквизитов администратора изменился'

FTP_LAN_STATE="$(systemctl is-active hyper-host-ftp-lan.service 2>/dev/null || true)"
FTP_WAN_STATE="$(systemctl is-active hyper-host-ftp-wan.service 2>/dev/null || true)"
{
  echo 'HYPER-HOST v71 full Nginx recovery'
  echo "Panel LAN: http://$SERVER_IP/"
  echo "Panel WAN: http://$PUBLIC_IP/"
  echo 'Panel domain: http://panel.hyper-host.pw/'
  echo "Target placeholder: http://$TARGET_DOMAIN/"
  echo "Target root: $TARGET_ROOT"
  echo "Recovered site vhosts: $SITE_COUNT"
  echo "FTP LAN service: $FTP_LAN_STATE"
  echo "FTP WAN service: $FTP_WAN_STATE"
  echo 'Admin password: unchanged'
  echo "Backup: $BACKUP_DIR"
  echo
  echo 'Enabled HYPER-HOST vhosts:'
  find /etc/nginx/sites-enabled -maxdepth 1 -type l -name '*hyper-host*' -printf '%f -> %l\n' 2>/dev/null | sort
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' %b%s%b — панель и сайты восстановлены\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' Панель LAN:         http://%s/\n' "$SERVER_IP"
printf ' Панель WAN:         http://%s/\n' "$PUBLIC_IP"
printf ' Панель domain:      http://panel.hyper-host.pw/\n'
printf ' Заглушка сайта:     http://%s/\n' "$TARGET_DOMAIN"
printf ' Восстановлено сайтов: %s\n' "$SITE_COUNT"
printf ' FTP LAN/WAN:        НЕ ИЗМЕНЯЛСЯ (%s / %s)\n' "${FTP_LAN_STATE:-unknown}" "${FTP_WAN_STATE:-unknown}"
printf ' Admin password:     НЕ ИЗМЕНЁН\n'
printf ' Backup:             %s\n' "$BACKUP_DIR"
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'
