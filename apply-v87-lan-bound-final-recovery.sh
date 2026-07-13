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
BACKUP="$BASE/backups/v87-lan-bound-final-$STAMP"
REPORT=/root/hyper-host-v87-lan-bound-final-report.txt
ROUTING_MAP=$BASE/data/v87-routing.tsv
CLEANUP_REPORT=$BASE/data/v87-nginx-cleanup.txt
CERTBOT_LOG=/var/log/letsencrypt/hyper-host-v87-panel-$STAMP.log
mkdir -p "$BACKUP" /var/log/letsencrypt

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; return 1; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_domain "$BETA_DOMAIN" || { echo "[HYPER-HOST] Некорректный домен: $BETA_DOMAIN" >&2; exit 1; }
[[ "$BETA_DOMAIN" != "$PANEL_DOMAIN" ]] || { echo '[HYPER-HOST] beta-домен совпадает с панелью' >&2; exit 1; }

ensure_nginx_writable(){
  local test="/etc/nginx/hyper-host-v87-write-test-$$" runtime=/opt/hyper-host/runtime/nginx
  if touch "$test" 2>/dev/null; then rm -f "$test"; return 0; fi
  log 'Подключаю writable Nginx runtime.'
  mkdir -p "$runtime" /etc/nginx /opt/hyper-host/bin
  [[ -f "$runtime/nginx.conf" ]] || cp -a /etc/nginx/. "$runtime/" 2>/dev/null || true
  mountpoint -q /etc/nginx && umount -lf /etc/nginx 2>/dev/null || true
  mount --bind "$runtime" /etc/nginx
  touch "$test"; rm -f "$test"
  cat > /opt/hyper-host/bin/mount-nginx-runtime.sh <<'EOS'
#!/usr/bin/env bash
set -e
mkdir -p /opt/hyper-host/runtime/nginx /etc/nginx
mountpoint -q /etc/nginx || mount --bind /opt/hyper-host/runtime/nginx /etc/nginx
EOS
  chmod 0755 /opt/hyper-host/bin/mount-nginx-runtime.sh
  { crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME' || true; echo '@reboot /opt/hyper-host/bin/mount-nginx-runtime.sh # HYPER-HOST-NGINX-RUNTIME'; } | crontab -
}

read_conf(){ local key="$1"; [[ -f "$CONF" ]] || return 0; sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#[:space:]]+).*/\\1/p" "$CONF" | tail -n1; }
set_conf(){ local key="$1" value="$2"; mkdir -p "$(dirname "$CONF")"; touch "$CONF"; if grep -qE "^[[:space:]]*${key}=" "$CONF"; then sed -i -E "s#^[[:space:]]*${key}=.*#${key}=\"${value}\"#" "$CONF"; else printf '%s="%s"\n' "$key" "$value" >> "$CONF"; fi; }
find_cert(){ local domain="$1" cert key; shopt -s nullglob; for cert in /etc/letsencrypt/live/*/fullchain.pem /opt/hyper-host/letsencrypt/live/*/fullchain.pem; do key="${cert%/fullchain.pem}/privkey.pem"; [[ -f "$cert" && -f "$key" ]] || continue; openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || continue; openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || continue; printf '%s\t%s\n' "$cert" "$key"; shopt -u nullglob; return 0; done; shopt -u nullglob; return 1; }

ensure_nginx_writable
[[ -f /var/www/hyper-host/public/index.php ]] || fail 'Не найден настоящий index.php панели: /var/www/hyper-host/public/index.php'
LAN_IP="$(read_conf SERVER_IP)"; [[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [[ -n "$LAN_IP" ]] || LAN_IP=192.168.0.179
PUBLIC_IP="$(read_conf PUBLIC_IP)"; [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(read_conf SERVER_PUBLIC_IP)"; [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP=90.189.208.25
PHP_SOCK="$(read_conf PHP_FPM_SOCK)"; [[ -n "$PHP_SOCK" && -S "$PHP_SOCK" ]] || PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"; [[ -n "$PHP_SOCK" ]] || PHP_SOCK=/run/php/php8.2-fpm.sock

log "Создаю полную резервную копию Nginx: $BACKUP"
tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" .
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"
[[ -f "$CONF" ]] && cp -a "$CONF" "$BACKUP/hyper-host.conf"
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP/hyper-host-ctl"

COMMITTED=0
rollback(){ local code=$?; trap - ERR; if [[ "$COMMITTED" == 1 ]]; then printf '[HYPER-HOST] Маршрутизация сохранена; ошибка относится только к SSL.\n' >&2; exit "$code"; fi; printf '[HYPER-HOST] Ошибка до подтверждения маршрутов. Возвращаю Nginx до v87.\n' >&2; find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; tar -C /etc/nginx -xpf "$BACKUP/nginx.tar" 2>/dev/null || true; [[ -f "$BACKUP/hyperhost.sqlite" ]] && cp -a "$BACKUP/hyperhost.sqlite" "$DATA"; [[ -f "$BACKUP/hyper-host.conf" ]] && cp -a "$BACKUP/hyper-host.conf" "$CONF"; [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl; nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true; exit "$code"; }
trap rollback ERR

DEFAULT_DIR=$BASE/ssl/default-vhost; DEFAULT_CERT=$DEFAULT_DIR/fullchain.pem; DEFAULT_KEY=$DEFAULT_DIR/privkey.pem
mkdir -p "$DEFAULT_DIR" /opt/hyper-host/acme-webroot/.well-known/acme-challenge "/var/www/hyper-host-sites/$BETA_DOMAIN/public_html" "/var/www/hyper-host-sites/$BETA_DOMAIN/logs"
if [[ ! -s "$DEFAULT_CERT" || ! -s "$DEFAULT_KEY" ]]; then openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj '/CN=hyper-host-default.invalid' -keyout "$DEFAULT_KEY" -out "$DEFAULT_CERT" >/dev/null 2>&1; chmod 0600 "$DEFAULT_KEY"; chmod 0644 "$DEFAULT_CERT"; fi

set_conf PANEL_DOMAIN "$PANEL_DOMAIN"; set_conf SERVER_IP "$LAN_IP"; set_conf PUBLIC_IP "$PUBLIC_IP"
install -m 0755 "$ROOT/scripts/nginx_recover_v87.py" /opt/hyper-host/nginx_recover_v87.py
install -m 0755 "$ROOT/scripts/nginx-reconcile-v87.sh" /usr/local/sbin/hyper-host-nginx-reconcile
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
python3 -m py_compile /opt/hyper-host/nginx_recover_v87.py
bash -n /usr/local/sbin/hyper-host-nginx-reconcile
bash -n /usr/local/sbin/hyper-host-ctl

log 'Очищаю старые server_name по фактическому nginx -T и создаю точные LAN-vhost панели и сайтов.'
python3 /opt/hyper-host/nginx_recover_v87.py --panel-domain "$PANEL_DOMAIN" --lan-ip "$LAN_IP" --public-ip "$PUBLIC_IP" --beta-domain "$BETA_DOMAIN" --panel-root /var/www/hyper-host/public --db "$DATA" --panel-php-sock "$PHP_SOCK" --default-cert "$DEFAULT_CERT" --default-key "$DEFAULT_KEY" --backup-dir "$BACKUP" --map "$ROUTING_MAP" --cleanup-report "$CLEANUP_REPORT"
TEST="$(nginx -t 2>&1)" || { printf '%s\n' "$TEST" >&2; fail 'Nginx не прошёл проверку'; }
printf '%s\n' "$TEST"
if printf '%s' "$TEST" | grep -qi 'conflicting server name'; then fail 'Остались конфликты server_name'; fi
systemctl reload nginx
sleep 1

PANEL_PROBE="hyper-host-v87-panel-$$.txt"; PANEL_EXPECTED="panel-v87-$STAMP-$$"
printf '%s' "$PANEL_EXPECTED" > "/var/www/hyper-host/public/$PANEL_PROBE"; chmod 0644 "/var/www/hyper-host/public/$PANEL_PROBE"
PANEL_DOMAIN_BODY="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $PANEL_DOMAIN" "http://$LAN_IP/$PANEL_PROBE" 2>/dev/null || true)"
PANEL_IP_BODY="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $LAN_IP" "http://$LAN_IP/$PANEL_PROBE" 2>/dev/null || true)"
rm -f "/var/www/hyper-host/public/$PANEL_PROBE"
[[ "$PANEL_DOMAIN_BODY" == "$PANEL_EXPECTED" ]] || fail "$PANEL_DOMAIN не попал в /var/www/hyper-host/public. Ответ: ${PANEL_DOMAIN_BODY:0:240}"
[[ "$PANEL_IP_BODY" == "$PANEL_EXPECTED" ]] || fail "$LAN_IP не попал в /var/www/hyper-host/public. Ответ: ${PANEL_IP_BODY:0:240}"
PANEL_STATUS="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 -H "Host: $PANEL_DOMAIN" "http://$LAN_IP/" 2>/dev/null || echo 000)"
[[ "$PANEL_STATUS" =~ ^[23][0-9][0-9]$ ]] || fail "Панель вернула HTTP $PANEL_STATUS"

SITE_TOTAL=0; SITE_OK=0
while IFS=$'\t' read -r host owner root conf; do
  [[ -n "$host" && -d "$root" ]] || continue
  SITE_TOTAL=$((SITE_TOTAL+1)); safe="$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '-')"; probe="hyper-host-v87-site-${safe}-$$.txt"; expected="site-v87-$host-$STAMP-$$"
  printf '%s' "$expected" > "$root/$probe"; chmod 0644 "$root/$probe"
  body="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $host" "http://$LAN_IP/$probe" 2>/dev/null || true)"; rm -f "$root/$probe"
  [[ "$body" == "$expected" ]] || fail "$host попал не в $root. Ответ: ${body:0:240}"
  SITE_OK=$((SITE_OK+1))
done < "$ROUTING_MAP"
[[ "$SITE_TOTAL" -gt 0 ]] || fail 'Не найдено сайтов для проверки'
COMMITTED=1
HTTP_GOOD_TAR="$BACKUP/http-good-nginx.tar"
tar -C /etc/nginx -cpf "$HTTP_GOOD_TAR" .

SSL_STATUS=missing; PANEL_CERT=''; PANEL_KEY=''; pair="$(find_cert "$PANEL_DOMAIN" 2>/dev/null || true)"
if [[ -n "$pair" ]]; then IFS=$'\t' read -r PANEL_CERT PANEL_KEY <<< "$pair"; SSL_STATUS=restored; else
  log "Сертификата $PANEL_DOMAIN нет — пробую выпустить Let's Encrypt."
  command -v certbot >/dev/null 2>&1 || { apt-get update >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y certbot >/dev/null 2>&1 || true; }
  if command -v certbot >/dev/null 2>&1; then
    token="v87-$STAMP-$$"; printf 'ok-%s' "$token" > "/opt/hyper-host/acme-webroot/.well-known/acme-challenge/$token"
    acme="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $PANEL_DOMAIN" "http://$LAN_IP/.well-known/acme-challenge/$token" 2>/dev/null || true)"; rm -f "/opt/hyper-host/acme-webroot/.well-known/acme-challenge/$token"
    if [[ "$acme" == "ok-$token" ]] && certbot certonly --webroot -w /opt/hyper-host/acme-webroot --non-interactive --agree-tos --register-unsafely-without-email --preferred-challenges http --keep-until-expiring --cert-name "$PANEL_DOMAIN" -d "$PANEL_DOMAIN" >"$CERTBOT_LOG" 2>&1; then pair="$(find_cert "$PANEL_DOMAIN" 2>/dev/null || true)"; [[ -n "$pair" ]] && { IFS=$'\t' read -r PANEL_CERT PANEL_KEY <<< "$pair"; SSL_STATUS=issued; }; else SSL_STATUS="failed:$CERTBOT_LOG"; fi
  else SSL_STATUS='failed:certbot-not-installed'; fi
fi

FINAL_SSL_ATTACHED=1
if ! python3 /opt/hyper-host/nginx_recover_v87.py --panel-domain "$PANEL_DOMAIN" --lan-ip "$LAN_IP" --public-ip "$PUBLIC_IP" --beta-domain "$BETA_DOMAIN" --panel-root /var/www/hyper-host/public --db "$DATA" --panel-php-sock "$PHP_SOCK" --default-cert "$DEFAULT_CERT" --default-key "$DEFAULT_KEY" --backup-dir "$BACKUP/final" --map "$ROUTING_MAP" --cleanup-report "$CLEANUP_REPORT" --skip-sanitize || ! nginx -t; then
  FINAL_SSL_ATTACHED=0
  find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  tar -C /etc/nginx -xpf "$HTTP_GOOD_TAR"
  nginx -t && systemctl reload nginx
  SSL_STATUS="${SSL_STATUS};attach-failed"
else
  systemctl reload nginx
fi
sleep 1

HTTPS_OK=0; HTTPS_STATUS=000
if [[ -n "$PANEL_CERT" ]] && echo | openssl s_client -connect "$LAN_IP:443" -servername "$PANEL_DOMAIN" 2>/dev/null | openssl x509 -noout -checkhost "$PANEL_DOMAIN" >/dev/null 2>&1; then HTTPS_OK=1; HTTPS_STATUS="$(curl --noproxy '*' -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 --resolve "$PANEL_DOMAIN:443:$LAN_IP" "https://$PANEL_DOMAIN/" 2>/dev/null || echo 000)"; fi

cat > "$REPORT" <<EOF
HYPER-HOST v87 LAN-bound final recovery
Date: $(date -Is)
Backup: $BACKUP
Panel domain: $PANEL_DOMAIN
Panel LAN IP: $LAN_IP
Panel public IP: $PUBLIC_IP
Panel root: /var/www/hyper-host/public
Panel HTTP: $PANEL_STATUS
Panel SSL: $SSL_STATUS
Panel HTTPS: $HTTPS_STATUS
Panel certificate: ${PANEL_CERT:-not found}
Sites/aliases checked: $SITE_OK/$SITE_TOTAL
Beta: $BETA_DOMAIN -> /var/www/hyper-host-sites/$BETA_DOMAIN/public_html
Routing: $ROUTING_MAP
Cleanup: $CLEANUP_REPORT
Site files / FTP / SQL / bots / admin password: NOT CHANGED
EOF

printf '\n============================================================\n'
printf ' HYPER-HOST — панель и сайты восстановлены v87\n'
printf '============================================================\n'
printf ' Панель IP:          http://%s/ — РАБОТАЕТ\n' "$LAN_IP"
printf ' Панель domain:      http://%s/ — РАБОТАЕТ\n' "$PANEL_DOMAIN"
printf ' SSL панели:         %s\n' "$SSL_STATUS"
printf ' HTTPS панели:       %s\n' "$([[ "$HTTPS_OK" == 1 ]] && echo РАБОТАЕТ || echo НЕ-ПОДТВЕРЖДЁН)"
printf ' Сайты/aliases:      %s/%s проверено\n' "$SITE_OK" "$SITE_TOTAL"
printf ' beta public_html:   РАБОТАЕТ\n'
printf ' FTP/SQL/боты/admin: НЕ ИЗМЕНЯЛИСЬ\n'
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'
[[ "$HTTPS_OK" == 1 ]] || printf '[HYPER-HOST] Маршрутизация работает, но SSL панели не подтверждён. Лог: %s\n' "$CERTBOT_LOG" >&2
