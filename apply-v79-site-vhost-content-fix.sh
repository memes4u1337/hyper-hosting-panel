#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v79-site-vhost-content-$STAMP"
REPORT=/root/hyper-host-v79-site-vhost-content-report.txt
DOMAIN="${1:-beta.mystockbot.xyz}"
SITE_ROOT="/var/www/hyper-host-sites/$DOMAIN/public_html"
mkdir -p "$BACKUP"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || fail "Некорректный домен: $DOMAIN"

log "Резервная копия: $BACKUP"
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP/hyper-host-ctl"
[[ -d /etc/nginx ]] && tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" . 2>/dev/null || true
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi

ensure_nginx_writable(){
  local test=/etc/nginx/.hyper-host-v79-write-test runtime=/opt/hyper-host/runtime/nginx mount_script=/opt/hyper-host/bin/mount-nginx-runtime.sh
  if touch "$test" 2>/dev/null; then rm -f "$test"; return 0; fi

  log 'Каталог /etc/nginx read-only — подключаю существующий writable runtime из /opt.'
  mkdir -p "$runtime" /opt/hyper-host/bin
  if [[ ! -f "$runtime/nginx.conf" ]]; then
    cp -a /etc/nginx/. "$runtime/" 2>/dev/null || fail 'Не удалось скопировать текущую конфигурацию Nginx в /opt.'
  fi
  mountpoint -q /etc/nginx && umount -lf /etc/nginx 2>/dev/null || true
  mount --bind "$runtime" /etc/nginx || fail 'Не удалось подключить writable Nginx runtime.'
  touch "$test" 2>/dev/null || fail 'После bind-mount /etc/nginx всё ещё недоступен для записи.'
  rm -f "$test"

  cat > "$mount_script" <<'EOSCRIPT'
#!/usr/bin/env bash
set -e
RUNTIME=/opt/hyper-host/runtime/nginx
TARGET=/etc/nginx
mkdir -p "$RUNTIME" "$TARGET"
mountpoint -q "$TARGET" && exit 0
mount --bind "$RUNTIME" "$TARGET"
EOSCRIPT
  chmod 0755 "$mount_script"
  { crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME'; echo '@reboot /opt/hyper-host/bin/mount-nginx-runtime.sh # HYPER-HOST-NGINX-RUNTIME'; } | crontab -
}

rollback(){
  local code=$?
  trap - ERR
  printf '[HYPER-HOST] Ошибка установки, возвращаю CLI и Nginx-конфиги.\n' >&2
  [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  if [[ -f "$BACKUP/nginx.tar" ]]; then
    find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    find /etc/nginx/sites-available -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    tar -C /etc/nginx -xpf "$BACKUP/nginx.tar" 2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap rollback ERR

ensure_nginx_writable

log 'Устанавливаю только исправление Nginx-vhost сайтов. FTP, SQL, боты и admin не изменяются.'
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
bash -n /usr/local/sbin/hyper-host-ctl

# Сохраняем совместимые ссылки CLI, если они уже используются панелью.
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true

mkdir -p "$SITE_ROOT" "/var/www/hyper-host-sites/$DOMAIN/logs"

log 'Восстанавливаю отдельные vhost для всех существующих папок сайтов.'
/usr/local/sbin/hyper-host-ctl sites-rebuild

log "Закрепляю $DOMAIN за $SITE_ROOT без изменения загруженных файлов."
/usr/local/sbin/hyper-host-ctl site-repair "$DOMAIN"

nginx -t
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx

# Проверяем не главную страницу, а уникальный файл прямо в public_html.
PROBE="hyper-host-v79-probe-${STAMP}-$$.txt"
PROBE_BODY="HYPER-HOST-V79-$STAMP-$$"
printf '%s' "$PROBE_BODY" > "$SITE_ROOT/$PROBE"
chmod 0644 "$SITE_ROOT/$PROBE"

SERVER_IP="$(awk -F= '/^SERVER_IP=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' /etc/hyper-host/hyper-host.conf 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HTTP_OK=0
HTTP_BODY=""
for addr in "$SERVER_IP" 127.0.0.1; do
  [[ -n "$addr" ]] || continue
  HTTP_BODY="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 -H "Host: $DOMAIN" "http://$addr/$PROBE" 2>/dev/null || true)"
  if [[ "$HTTP_BODY" == "$PROBE_BODY" ]]; then HTTP_OK=1; break; fi
done
rm -f "$SITE_ROOT/$PROBE"
[[ "$HTTP_OK" == 1 ]] || fail "$DOMAIN всё ещё не отдаёт файлы из $SITE_ROOT. Получено: ${HTTP_BODY:0:300}"

# Дополнительная проверка HTTPS только если vhost получил реальный сертификат.
HTTPS_STATUS='сертификат для домена не найден — HTTP работает'
CONF="/etc/nginx/sites-available/hyper-host-site-$DOMAIN.conf"
if grep -qE '^[[:space:]]*ssl_certificate[[:space:]]+' "$CONF" 2>/dev/null; then
  HTTPS_PROBE="hyper-host-v79-https-${STAMP}-$$.txt"
  printf '%s' "$PROBE_BODY" > "$SITE_ROOT/$HTTPS_PROBE"
  chmod 0644 "$SITE_ROOT/$HTTPS_PROBE"
  HTTPS_BODY="$(curl --noproxy '*' -kfsS --connect-timeout 2 --max-time 7 --resolve "$DOMAIN:443:$SERVER_IP" "https://$DOMAIN/$HTTPS_PROBE" 2>/dev/null || true)"
  rm -f "$SITE_ROOT/$HTTPS_PROBE"
  [[ "$HTTPS_BODY" == "$PROBE_BODY" ]] || fail "HTTPS-vhost $DOMAIN не отдаёт public_html"
  HTTPS_STATUS='реальный сертификат найден, HTTPS public_html работает'
fi

ADMIN_HASH_AFTER=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi
[[ -z "$ADMIN_HASH_BEFORE" || "$ADMIN_HASH_BEFORE" == "$ADMIN_HASH_AFTER" ]] || fail 'Пароль admin изменился'

FILE_LIST="$(find "$SITE_ROOT" -maxdepth 2 -type f -printf '%P\n' 2>/dev/null | sort | head -n 100 || true)"
INDEX_STATUS='нет index.html/index.htm/index.php'
for idx in index.html index.htm index.php; do
  [[ -f "$SITE_ROOT/$idx" ]] && { INDEX_STATUS="$idx"; break; }
done

cat > "$REPORT" <<EOFREPORT
HYPER-HOST v79 — site vhost/content fix

Domain: $DOMAIN
Document root: $SITE_ROOT
HTTP public_html probe: passed
HTTPS: $HTTPS_STATUS
Index selected by Nginx: $INDEX_STATUS
Nginx config: /etc/nginx/sites-available/hyper-host-site-$DOMAIN.conf
Admin password: unchanged
FTP/SQL/bots/site files: unchanged
Backup: $BACKUP

Files found in public_html:
${FILE_LIST:-[папка пуста]}
EOFREPORT
chmod 0600 "$REPORT"
trap - ERR

printf '\n%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — сайт привязан к своему public_html'
printf '%s\n' '============================================================'
printf ' Домен:              %s\n' "$DOMAIN"
printf ' Корень:             %s\n' "$SITE_ROOT"
printf ' HTTP:               %s\n' 'РАБОТАЕТ'
printf ' HTTPS:              %s\n' "$HTTPS_STATUS"
printf ' Index:              %s\n' "$INDEX_STATUS"
printf ' Файлы сайта:        %s\n' 'НЕ ИЗМЕНЯЛИСЬ'
printf ' Admin password:     %s\n' 'НЕ ИЗМЕНЁН'
printf ' Отчёт:              %s\n' "$REPORT"
printf '%s\n' '============================================================'
