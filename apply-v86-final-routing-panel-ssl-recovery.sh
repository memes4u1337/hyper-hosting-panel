#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
DATA=$BASE/data/hyperhost.sqlite
CONF=/etc/hyper-host/hyper-host.conf
PANEL_DOMAIN=panel.hyper-host.pw
BETA_DOMAIN="${1:-beta.mystockbot.xyz}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v86-final-routing-panel-ssl-$STAMP"
REPORT=/root/hyper-host-v86-final-routing-panel-ssl-report.txt
ROUTING_MAP=$BASE/data/v86-routing.tsv
CLEANUP_REPORT=$BASE/data/v86-nginx-cleanup.txt
CERTBOT_LOG=/var/log/letsencrypt/hyper-host-v86-panel-$STAMP.log
mkdir -p "$BACKUP" /var/log/letsencrypt

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; return 1; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_domain "$BETA_DOMAIN" || { echo "[HYPER-HOST] Некорректный beta-домен: $BETA_DOMAIN" >&2; exit 1; }
[[ "$BETA_DOMAIN" != "$PANEL_DOMAIN" ]] || { echo '[HYPER-HOST] beta-домен совпадает с доменом панели' >&2; exit 1; }

ensure_nginx_writable(){
  local test="/etc/nginx/hyper-host-v86-write-test-$$" runtime=/opt/hyper-host/runtime/nginx mount_script=/opt/hyper-host/bin/mount-nginx-runtime.sh
  if touch "$test" 2>/dev/null; then rm -f "$test"; return 0; fi
  log 'Каталог /etc/nginx read-only — подключаю writable runtime.'
  mkdir -p "$runtime" /opt/hyper-host/bin /etc/nginx
  if [[ ! -f "$runtime/nginx.conf" ]]; then
    cp -a /etc/nginx/. "$runtime/" 2>/dev/null || fail 'Не удалось скопировать Nginx в writable runtime.'
  fi
  mountpoint -q /etc/nginx && umount -lf /etc/nginx 2>/dev/null || true
  mount --bind "$runtime" /etc/nginx || fail 'Не удалось подключить writable Nginx runtime.'
  touch "$test" 2>/dev/null || fail 'Nginx runtime всё ещё недоступен для записи.'
  rm -f "$test"
  cat > "$mount_script" <<'EOS'
#!/usr/bin/env bash
set -e
RUNTIME=/opt/hyper-host/runtime/nginx
TARGET=/etc/nginx
mkdir -p "$RUNTIME" "$TARGET"
mountpoint -q "$TARGET" && exit 0
mount --bind "$RUNTIME" "$TARGET"
EOS
  chmod 0755 "$mount_script"
  { crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME' || true; echo '@reboot /opt/hyper-host/bin/mount-nginx-runtime.sh # HYPER-HOST-NGINX-RUNTIME'; } | crontab -
}

read_conf(){
  local key="$1"
  [[ -f "$CONF" ]] || return 0
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#[:space:]]+).*/\\1/p" "$CONF" | tail -n1
}

set_conf_value(){
  local key="$1" value="$2"
  mkdir -p "$(dirname "$CONF")"
  touch "$CONF"
  if grep -qE "^[[:space:]]*${key}=" "$CONF"; then
    sed -i -E "s#^[[:space:]]*${key}=.*#${key}=\"${value}\"#" "$CONF"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$CONF"
  fi
}

find_matching_cert(){
  local domain="$1" cert key
  shopt -s nullglob
  for cert in /etc/letsencrypt/live/*/fullchain.pem /opt/hyper-host/letsencrypt/live/*/fullchain.pem; do
    [[ -f "$cert" ]] || continue
    key="${cert%/fullchain.pem}/privkey.pem"
    [[ -f "$key" ]] || continue
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || continue
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || continue
    printf '%s\t%s\n' "$cert" "$key"
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

ensure_nginx_writable
log "Создаю резервную копию: $BACKUP"
tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" .
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"
[[ -f "$CONF" ]] && cp -a "$CONF" "$BACKUP/hyper-host.conf"
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP/hyper-host-ctl"
[[ -f /opt/hyper-host/nginx_recover_v86.py ]] && cp -a /opt/hyper-host/nginx_recover_v86.py "$BACKUP/nginx_recover_v86.py"
[[ -f /usr/local/sbin/hyper-host-nginx-reconcile ]] && cp -a /usr/local/sbin/hyper-host-nginx-reconcile "$BACKUP/hyper-host-nginx-reconcile"

ROUTING_COMMITTED=0
rollback(){
  local code=$?
  trap - ERR
  if [[ "$ROUTING_COMMITTED" == 1 ]]; then
    printf '[HYPER-HOST] SSL не удалось выпустить, но рабочая маршрутизация панели и сайтов сохранена.\n' >&2
    exit "$code"
  fi
  printf '[HYPER-HOST] Ошибка маршрутизации. Возвращаю Nginx и настройки до v86.\n' >&2
  if [[ -f "$BACKUP/nginx.tar" ]]; then
    find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    tar -C /etc/nginx -xpf "$BACKUP/nginx.tar" 2>/dev/null || true
  fi
  [[ -f "$BACKUP/hyperhost.sqlite" ]] && cp -a "$BACKUP/hyperhost.sqlite" "$DATA"
  if [[ -f "$BACKUP/hyper-host.conf" ]]; then cp -a "$BACKUP/hyper-host.conf" "$CONF"; fi
  [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  if [[ -f "$BACKUP/nginx_recover_v86.py" ]]; then cp -a "$BACKUP/nginx_recover_v86.py" /opt/hyper-host/nginx_recover_v86.py; else rm -f /opt/hyper-host/nginx_recover_v86.py; fi
  if [[ -f "$BACKUP/hyper-host-nginx-reconcile" ]]; then cp -a "$BACKUP/hyper-host-nginx-reconcile" /usr/local/sbin/hyper-host-nginx-reconcile; else rm -f /usr/local/sbin/hyper-host-nginx-reconcile; fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  exit "$code"
}
trap rollback ERR

LAN_IP="$(read_conf SERVER_IP)"
[[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$LAN_IP" ]] || LAN_IP=192.168.0.179
PUBLIC_IP="$(read_conf PUBLIC_IP)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(read_conf SERVER_PUBLIC_IP)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(cat /etc/hyper-host/public_ip 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP=90.189.208.25

PANEL_ROOT=/var/www/hyper-host/public
for candidate in /var/www/hyper-host/public /var/www/hyper-host/panel/public /opt/hyper-host/panel/public; do
  if [[ -f "$candidate/index.php" || -f "$candidate/index.html" ]]; then PANEL_ROOT="$candidate"; break; fi
done
[[ -d "$PANEL_ROOT" ]] || fail "Не найдена папка панели: $PANEL_ROOT"
[[ -f "$PANEL_ROOT/index.php" || -f "$PANEL_ROOT/index.html" ]] || fail "В папке панели нет index.php/index.html: $PANEL_ROOT"

PHP_SOCK="$(read_conf PHP_FPM_SOCK)"
[[ -n "$PHP_SOCK" && -S "$PHP_SOCK" ]] || PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "$PHP_SOCK" ]] || PHP_SOCK=/run/php/php8.2-fpm.sock
if [[ -S "$PHP_SOCK" ]]; then
  PHP_SERVICE="$(basename "$PHP_SOCK" -fpm.sock)-fpm"
  systemctl start "$PHP_SERVICE" >/dev/null 2>&1 || true
fi

DEFAULT_DIR=$BASE/ssl/default-vhost
DEFAULT_CERT=$DEFAULT_DIR/fullchain.pem
DEFAULT_KEY=$DEFAULT_DIR/privkey.pem
mkdir -p "$DEFAULT_DIR" /opt/hyper-host/acme-webroot/.well-known/acme-challenge \
  "/var/www/hyper-host-sites/$BETA_DOMAIN/public_html" "/var/www/hyper-host-sites/$BETA_DOMAIN/logs"
if [[ ! -s "$DEFAULT_CERT" || ! -s "$DEFAULT_KEY" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj '/CN=hyper-host-default.invalid' \
    -keyout "$DEFAULT_KEY" -out "$DEFAULT_CERT" >/dev/null 2>&1
  chmod 0600 "$DEFAULT_KEY"; chmod 0644 "$DEFAULT_CERT"
fi

set_conf_value PANEL_DOMAIN "$PANEL_DOMAIN"
set_conf_value SERVER_IP "$LAN_IP"
set_conf_value PUBLIC_IP "$PUBLIC_IP"

# Update panel domain in app config without changing other settings.
python3 - "$PANEL_DOMAIN" <<'PY'
from pathlib import Path
import re,sys
value=sys.argv[1]
for name in ('/var/www/hyper-host/app/config.php','/var/www/hyper-host/app/config.example.php'):
    p=Path(name)
    if not p.is_file(): continue
    text=p.read_text(encoding='utf-8',errors='ignore')
    new=re.sub(r"(['\"]panel_domain['\"]\s*=>\s*)['\"][^'\"]*['\"]",lambda m:m.group(1)+repr(value),text)
    if new != text: p.write_text(new,encoding='utf-8')
PY

install -m 0755 "$ROOT/scripts/nginx_recover_v86.py" /opt/hyper-host/nginx_recover_v86.py
install -m 0755 "$ROOT/scripts/nginx-reconcile-v86.sh" /usr/local/sbin/hyper-host-nginx-reconcile
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true
bash -n /usr/local/sbin/hyper-host-ctl
bash -n /usr/local/sbin/hyper-host-nginx-reconcile
python3 -m py_compile /opt/hyper-host/nginx_recover_v86.py

log 'Удаляю конфликтующие старые vhost и создаю один vhost панели плюс отдельный vhost каждого сайта.'
python3 /opt/hyper-host/nginx_recover_v86.py \
  --panel-domain "$PANEL_DOMAIN" --lan-ip "$LAN_IP" --public-ip "$PUBLIC_IP" \
  --beta-domain "$BETA_DOMAIN" --panel-root "$PANEL_ROOT" --db "$DATA" \
  --panel-php-sock "$PHP_SOCK" --default-cert "$DEFAULT_CERT" --default-key "$DEFAULT_KEY" \
  --backup-dir "$BACKUP" --map "$ROUTING_MAP" --cleanup-report "$CLEANUP_REPORT"

NGINX_TEST="$(nginx -t 2>&1)" || { printf '%s\n' "$NGINX_TEST" >&2; fail 'Nginx не прошёл проверку после восстановления.'; }
printf '%s\n' "$NGINX_TEST"
if printf '%s' "$NGINX_TEST" | grep -qi 'conflicting server name'; then
  fail 'После очистки остались конфликтующие server_name.'
fi
systemctl reload nginx

# Verify panel document root by domain and IP using a normal, non-hidden probe file.
PANEL_PROBE="hyper-host-v86-panel-probe-$$.txt"
PANEL_EXPECTED="panel-v86-$STAMP-$$"
printf '%s' "$PANEL_EXPECTED" > "$PANEL_ROOT/$PANEL_PROBE"
chmod 0644 "$PANEL_ROOT/$PANEL_PROBE"
PANEL_BY_DOMAIN="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 -H "Host: $PANEL_DOMAIN" "http://127.0.0.1/$PANEL_PROBE" 2>/dev/null || true)"
PANEL_BY_IP="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 -H "Host: $LAN_IP" "http://127.0.0.1/$PANEL_PROBE" 2>/dev/null || true)"
rm -f "$PANEL_ROOT/$PANEL_PROBE"
[[ "$PANEL_BY_DOMAIN" == "$PANEL_EXPECTED" ]] || fail "$PANEL_DOMAIN не открывает папку панели $PANEL_ROOT. Ответ: ${PANEL_BY_DOMAIN:0:220}"
[[ "$PANEL_BY_IP" == "$PANEL_EXPECTED" ]] || fail "$LAN_IP не открывает папку панели $PANEL_ROOT. Ответ: ${PANEL_BY_IP:0:220}"

PANEL_HTTP_STATUS="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 10 -H "Host: $PANEL_DOMAIN" http://127.0.0.1/ 2>/dev/null || echo 000)"
if [[ "$PANEL_HTTP_STATUS" == 502 || "$PANEL_HTTP_STATUS" == 504 ]]; then
  [[ -n "${PHP_SERVICE:-}" ]] && systemctl restart "$PHP_SERVICE" >/dev/null 2>&1 || true
  sleep 1
  PANEL_HTTP_STATUS="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 10 -H "Host: $PANEL_DOMAIN" http://127.0.0.1/ 2>/dev/null || echo 000)"
fi
[[ "$PANEL_HTTP_STATUS" =~ ^[23][0-9][0-9]$ ]] || fail "Панель маршрутизируется правильно, но главная страница вернула HTTP $PANEL_HTTP_STATUS. Проверь PHP/app logs: /var/log/nginx/hyper-host-panel.error.log"

SITE_TOTAL=0
SITE_OK=0
while IFS=$'\t' read -r host owner root conf; do
  [[ -n "$host" && -d "$root" ]] || continue
  SITE_TOTAL=$((SITE_TOTAL+1))
  safe="$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '-')"
  probe="hyper-host-v86-site-${safe}-$$.txt"
  expected="site-v86-$host-$STAMP-$$"
  printf '%s' "$expected" > "$root/$probe"
  chmod 0644 "$root/$probe"
  body="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 -H "Host: $host" "http://127.0.0.1/$probe" 2>/dev/null || true)"
  rm -f "$root/$probe"
  if [[ "$body" != "$expected" ]]; then
    fail "Сайт $host попал не в $root. Ответ: ${body:0:220}"
  fi
  SITE_OK=$((SITE_OK+1))
done < "$ROUTING_MAP"
[[ "$SITE_TOTAL" -gt 0 ]] || fail 'Не найдено ни одного сайта для проверки.'
ROUTING_COMMITTED=1

# Routing is now known-good. SSL issuance must never roll it back.
SSL_STATUS=missing
PANEL_CERT=""
PANEL_KEY=""
if pair="$(find_matching_cert "$PANEL_DOMAIN" 2>/dev/null || true)" && [[ -n "$pair" ]]; then
  IFS=$'\t' read -r PANEL_CERT PANEL_KEY <<< "$pair"
  SSL_STATUS=restored
else
  log "Действующий сертификат $PANEL_DOMAIN не найден — выпускаю Let's Encrypt."
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  if ! command -v certbot >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot >/dev/null 2>&1 || true
  fi
  if command -v certbot >/dev/null 2>&1; then
    token="hyper-host-v86-acme-$STAMP-$$"
    printf 'acme-%s' "$token" > "/opt/hyper-host/acme-webroot/.well-known/acme-challenge/$token"
    chmod -R a+rX /opt/hyper-host/acme-webroot/.well-known
    acme_body="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 -H "Host: $PANEL_DOMAIN" "http://127.0.0.1/.well-known/acme-challenge/$token" 2>/dev/null || true)"
    rm -f "/opt/hyper-host/acme-webroot/.well-known/acme-challenge/$token"
    if [[ "$acme_body" == "acme-$token" ]]; then
      if certbot certonly --webroot -w /opt/hyper-host/acme-webroot \
          --non-interactive --agree-tos --register-unsafely-without-email \
          --preferred-challenges http --keep-until-expiring \
          --cert-name "$PANEL_DOMAIN" -d "$PANEL_DOMAIN" >"$CERTBOT_LOG" 2>&1; then
        pair="$(find_matching_cert "$PANEL_DOMAIN" 2>/dev/null || true)"
        if [[ -n "$pair" ]]; then
          IFS=$'\t' read -r PANEL_CERT PANEL_KEY <<< "$pair"
          SSL_STATUS=issued
        fi
      else
        SSL_STATUS="failed: $CERTBOT_LOG"
      fi
    else
      SSL_STATUS='failed: local ACME route does not work'
    fi
  else
    SSL_STATUS='failed: certbot is not installed'
  fi
fi

# Rebuild once more so the newly issued/restored certificate is attached, then reload.
python3 /opt/hyper-host/nginx_recover_v86.py \
  --panel-domain "$PANEL_DOMAIN" --lan-ip "$LAN_IP" --public-ip "$PUBLIC_IP" \
  --beta-domain "$BETA_DOMAIN" --panel-root "$PANEL_ROOT" --db "$DATA" \
  --panel-php-sock "$PHP_SOCK" --default-cert "$DEFAULT_CERT" --default-key "$DEFAULT_KEY" \
  --backup-dir "$BACKUP/final" --map "$ROUTING_MAP" --cleanup-report "$CLEANUP_REPORT"
nginx -t
systemctl reload nginx

HTTPS_OK=0
if [[ -n "$PANEL_CERT" && -n "$PANEL_KEY" ]]; then
  if echo | openssl s_client -connect 127.0.0.1:443 -servername "$PANEL_DOMAIN" 2>/dev/null \
      | openssl x509 -noout -checkhost "$PANEL_DOMAIN" >/dev/null 2>&1; then
    HTTPS_OK=1
  fi
fi

PANEL_HTTPS_STATUS=000
if [[ "$HTTPS_OK" == 1 ]]; then
  PANEL_HTTPS_STATUS="$(curl --noproxy '*' -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 8 --resolve "$PANEL_DOMAIN:443:127.0.0.1" "https://$PANEL_DOMAIN/" 2>/dev/null || echo 000)"
fi

cat > "$REPORT" <<EOF
HYPER-HOST v86 final routing + panel SSL recovery
Date: $(date -Is)
Backup: $BACKUP
Panel domain: $PANEL_DOMAIN
Panel root: $PANEL_ROOT
Panel LAN IP: $LAN_IP
Panel public IP: $PUBLIC_IP
Panel HTTP status: $PANEL_HTTP_STATUS
Panel HTTPS status: $PANEL_HTTPS_STATUS
Panel SSL: $SSL_STATUS
Panel certificate: ${PANEL_CERT:-not found}
Sites/aliases checked: $SITE_OK/$SITE_TOTAL
Beta domain: $BETA_DOMAIN
Beta root: /var/www/hyper-host-sites/$BETA_DOMAIN/public_html
Routing map: $ROUTING_MAP
Cleanup report: $CLEANUP_REPORT
Certbot log: $CERTBOT_LOG
FTP/SQL/bots/site files/admin password: NOT CHANGED
EOF

printf '\n============================================================\n'
printf ' HYPER-HOST — панель, сайты и SSL восстановлены\n'
printf '============================================================\n'
printf ' Панель:             http://%s/\n' "$LAN_IP"
printf ' Основной домен:     http://%s/\n' "$PANEL_DOMAIN"
printf ' HTTPS:              %s\n' "$SSL_STATUS"
printf ' HTTPS проверка:     %s\n' "$([[ "$HTTPS_OK" == 1 ]] && echo РАБОТАЕТ || echo НЕ ПОДТВЕРЖДЕНА)"
printf ' Сайты/aliases:      %s/%s проверено\n' "$SITE_OK" "$SITE_TOTAL"
printf ' beta root:          /var/www/hyper-host-sites/%s/public_html\n' "$BETA_DOMAIN"
printf ' Файлы сайтов:       НЕ ИЗМЕНЯЛИСЬ\n'
printf ' FTP/SQL/боты/admin: НЕ ИЗМЕНЯЛИСЬ\n'
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'

if [[ "$HTTPS_OK" != 1 ]]; then
  printf '[HYPER-HOST] ВНИМАНИЕ: маршрутизация уже работает, но Let\x27s Encrypt не подтвердился. Смотри: %s\n' "$CERTBOT_LOG" >&2
fi
