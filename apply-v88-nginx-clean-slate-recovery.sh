#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
DATA=$BASE/data/hyperhost.sqlite
CONF=/etc/hyper-host/hyper-host.conf
PANEL_DOMAIN=panel.hyper-host.pw
BETA_DOMAIN="${1:-beta.mystockbot.xyz}"
LAN_IP=192.168.0.179
PUBLIC_IP=90.189.208.25
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v88-nginx-clean-slate-$STAMP"
REPORT=/root/hyper-host-v88-nginx-clean-slate-report.txt
ROUTING_MAP=$BASE/data/v88-routing.tsv
CERTBOT_LOG=/var/log/letsencrypt/hyper-host-v88-panel-$STAMP.log
mkdir -p "$BACKUP" /var/log/letsencrypt /var/log/nginx

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; return 1; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_domain "$BETA_DOMAIN" || { echo "[HYPER-HOST] Некорректный домен: $BETA_DOMAIN" >&2; exit 1; }
[[ "$BETA_DOMAIN" != "$PANEL_DOMAIN" ]] || { echo '[HYPER-HOST] beta-домен совпадает с доменом панели' >&2; exit 1; }

ensure_nginx_writable(){
  local test="/etc/nginx/hyper-host-v88-write-test-$$" runtime=/opt/hyper-host/runtime/nginx
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

read_conf(){
  local key="$1"
  [[ -f "$CONF" ]] || return 0
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#[:space:]]+).*/\\1/p" "$CONF" | tail -n1
}
set_conf(){
  local key="$1" value="$2"
  mkdir -p "$(dirname "$CONF")"; touch "$CONF"
  if grep -qE "^[[:space:]]*${key}=" "$CONF"; then
    sed -i -E "s#^[[:space:]]*${key}=.*#${key}=\"${value}\"#" "$CONF"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$CONF"
  fi
}
admin_hash(){
  [[ -f "$DATA" ]] || return 0
  python3 - "$DATA" <<'PY' 2>/dev/null || true
import sqlite3,sys
try:
    con=sqlite3.connect(sys.argv[1])
    cols={r[1] for r in con.execute('pragma table_info(users)')}
    if not {'username','password_hash'} <= cols: raise SystemExit
    row=con.execute("select password_hash from users where username='admin' limit 1").fetchone()
    print(row[0] if row else '')
finally:
    try: con.close()
    except Exception: pass
PY
}
find_cert(){
  local domain="$1" cert key
  shopt -s nullglob
  for cert in /etc/letsencrypt/live/*/fullchain.pem /opt/hyper-host/letsencrypt/live/*/fullchain.pem; do
    key="${cert%/fullchain.pem}/privkey.pem"
    [[ -f "$cert" && -f "$key" ]] || continue
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
[[ -f /var/www/hyper-host/public/index.php ]] || fail 'Не найден файл панели /var/www/hyper-host/public/index.php'
[[ -f /var/www/hyper-host/app/bootstrap.php ]] || fail 'Не найден bootstrap панели /var/www/hyper-host/app/bootstrap.php'

v="$(read_conf SERVER_IP)"; [[ -n "$v" ]] && LAN_IP="$v"
v="$(read_conf PUBLIC_IP)"; [[ -n "$v" ]] && PUBLIC_IP="$v"
PHP_SOCK="$(read_conf PHP_FPM_SOCK)"
if [[ -z "$PHP_SOCK" || ! -S "$PHP_SOCK" ]]; then
  PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
fi
[[ -n "$PHP_SOCK" ]] || PHP_SOCK=/run/php/php8.2-fpm.sock

log "Создаю полную резервную копию Nginx: $BACKUP"
tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" .
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"
[[ -f "$CONF" ]] && cp -a "$CONF" "$BACKUP/hyper-host.conf"
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP/hyper-host-ctl"
[[ -f /usr/local/sbin/hyper-host-nginx-reconcile ]] && cp -a /usr/local/sbin/hyper-host-nginx-reconcile "$BACKUP/hyper-host-nginx-reconcile"
ADMIN_BEFORE="$(admin_hash)"

COMMITTED=0
rollback(){
  local code=$?
  trap - ERR
  if [[ "$COMMITTED" == 1 ]]; then
    printf '[HYPER-HOST] HTTP-маршрутизация сохранена; ошибка относится только к выпуску SSL.\n' >&2
    exit "$code"
  fi
  printf '[HYPER-HOST] Ошибка до подтверждения маршрутов. Возвращаю Nginx до v88.\n' >&2
  find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  tar -C /etc/nginx -xpf "$BACKUP/nginx.tar" 2>/dev/null || true
  [[ -f "$BACKUP/hyperhost.sqlite" ]] && cp -a "$BACKUP/hyperhost.sqlite" "$DATA"
  [[ -f "$BACKUP/hyper-host.conf" ]] && cp -a "$BACKUP/hyper-host.conf" "$CONF"
  [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  [[ -f "$BACKUP/hyper-host-nginx-reconcile" ]] && cp -a "$BACKUP/hyper-host-nginx-reconcile" /usr/local/sbin/hyper-host-nginx-reconcile
  nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true
  exit "$code"
}
trap rollback ERR

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

set_conf PANEL_DOMAIN "$PANEL_DOMAIN"
set_conf SERVER_IP "$LAN_IP"
set_conf PUBLIC_IP "$PUBLIC_IP"
set_conf BETA_DOMAIN "$BETA_DOMAIN"

# Панель должна знать свой основной домен.
if [[ -f /var/www/hyper-host/app/config.php ]]; then
  python3 - /var/www/hyper-host/app/config.php "$PANEL_DOMAIN" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); d=sys.argv[2]
s=p.read_text(encoding='utf-8',errors='ignore')
s=re.sub(r"('panel_domain'\s*=>\s*)'[^']*'", lambda m:m.group(1)+repr(d), s)
p.write_text(s,encoding='utf-8')
PY
fi

install -m 0755 "$ROOT/scripts/nginx_recover_v88.py" /opt/hyper-host/nginx_recover_v88.py
install -m 0755 "$ROOT/scripts/nginx-reconcile-v88.sh" /usr/local/sbin/hyper-host-nginx-reconcile
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
python3 -m py_compile /opt/hyper-host/nginx_recover_v88.py
bash -n /usr/local/sbin/hyper-host-nginx-reconcile
bash -n /usr/local/sbin/hyper-host-ctl

# Только публичные каталоги: Nginx должен уметь читать загруженные файлы.
chgrp -R www-data /var/www/hyper-host/public 2>/dev/null || true
find /var/www/hyper-host/public -type d -exec chmod u+rwx,g+rwx,o+rx {} + 2>/dev/null || true
find /var/www/hyper-host/public -type f -exec chmod u+rw,g+rw,o+r {} + 2>/dev/null || true
find /var/www/hyper-host-sites -path '*/public_html*' -type d -exec chmod u+rwx,g+rwx,o+rx {} + 2>/dev/null || true
find /var/www/hyper-host-sites -path '*/public_html*' -type f -exec chmod u+rw,g+rw,o+r {} + 2>/dev/null || true

log 'Отключаю накопившиеся vhost на уровне nginx.conf и создаю единственный управляемый набор конфигов.'
python3 /opt/hyper-host/nginx_recover_v88.py \
  --panel-domain "$PANEL_DOMAIN" \
  --lan-ip "$LAN_IP" \
  --public-ip "$PUBLIC_IP" \
  --beta-domain "$BETA_DOMAIN" \
  --panel-root /var/www/hyper-host/public \
  --db "$DATA" \
  --panel-php-sock "$PHP_SOCK" \
  --default-cert "$DEFAULT_CERT" \
  --default-key "$DEFAULT_KEY" \
  --map "$ROUTING_MAP"

TEST="$(nginx -t 2>&1)" || { printf '%s\n' "$TEST" >&2; fail 'Nginx не прошёл проверку'; }
printf '%s\n' "$TEST"
printf '%s' "$TEST" | grep -qi 'conflicting server name' && fail 'После чистой сборки остались conflicting server_name'

# Полный restart, чтобы старые worker-процессы больше не могли отдавать старые vhost.
systemctl restart nginx
sleep 2
systemctl is-active --quiet nginx || { journalctl -u nginx -n 80 --no-pager >&2 || true; fail 'Nginx не запустился'; }

# nginx.conf v88 больше не подключает sites-enabled/conf.d.
NGINX_T="$(nginx -T 2>&1)"
printf '%s' "$NGINX_T" | grep -q '/etc/nginx/hyper-host-managed/' || fail 'Управляемые v88-конфиги не подключены'
printf '%s' "$NGINX_T" | grep -qE 'include[[:space:]]+/etc/nginx/sites-enabled|include[[:space:]]+/etc/nginx/conf.d' && fail 'Старые sites-enabled/conf.d всё ещё подключены'

# Проверяем выбор vhost отдельно от файлов.
PANEL_ROUTE="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $PANEL_DOMAIN" "http://127.0.0.1/__hyper_host_v88_route__" 2>/dev/null || true)"
PANEL_ROUTE_LAN="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $PANEL_DOMAIN" "http://$LAN_IP/__hyper_host_v88_route__" 2>/dev/null || true)"
[[ "$PANEL_ROUTE" == PANEL_V88 ]] || fail "$PANEL_DOMAIN всё ещё попадает в старый vhost. Ответ route: ${PANEL_ROUTE:0:240}"
[[ "$PANEL_ROUTE_LAN" == PANEL_V88 ]] || fail "$PANEL_DOMAIN по LAN IP не попадает в panel-vhost. Ответ: ${PANEL_ROUTE_LAN:0:240}"

# Проверяем фактический root панели обычным статическим файлом.
PANEL_PROBE="hyper-host-v88-panel-$$.txt"
PANEL_EXPECTED="panel-v88-$STAMP-$$"
printf '%s' "$PANEL_EXPECTED" > "/var/www/hyper-host/public/$PANEL_PROBE"
chmod 0644 "/var/www/hyper-host/public/$PANEL_PROBE"
PANEL_BODY="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $PANEL_DOMAIN" "http://127.0.0.1/$PANEL_PROBE" 2>/dev/null || true)"
PANEL_IP_BODY="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $LAN_IP" "http://127.0.0.1/$PANEL_PROBE" 2>/dev/null || true)"
rm -f "/var/www/hyper-host/public/$PANEL_PROBE"
[[ "$PANEL_BODY" == "$PANEL_EXPECTED" ]] || fail "$PANEL_DOMAIN не читает /var/www/hyper-host/public. Ответ: ${PANEL_BODY:0:240}"
[[ "$PANEL_IP_BODY" == "$PANEL_EXPECTED" ]] || fail "Вход по IP не читает /var/www/hyper-host/public. Ответ: ${PANEL_IP_BODY:0:240}"
PANEL_STATUS="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 -H "Host: $PANEL_DOMAIN" http://127.0.0.1/ 2>/dev/null || echo 000)"
[[ "$PANEL_STATUS" =~ ^[23][0-9][0-9]$ ]] || fail "Панель вернула HTTP $PANEL_STATUS"

SITE_TOTAL=0
SITE_OK=0
BETA_OK=0
while IFS=$'\t' read -r host owner root conf; do
  [[ -n "$host" && -d "$root" ]] || continue
  SITE_TOTAL=$((SITE_TOTAL+1))
  route="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $host" "http://127.0.0.1/__hyper_host_v88_route__" 2>/dev/null || true)"
  [[ "$route" == "SITE_V88:$owner" ]] || fail "$host попал не в vhost сайта $owner. Route: ${route:0:240}"
  safe="$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '-')"
  probe="hyper-host-v88-site-${safe}-$$.txt"
  expected="site-v88-$host-$STAMP-$$"
  printf '%s' "$expected" > "$root/$probe"
  chmod 0644 "$root/$probe"
  body="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $host" "http://127.0.0.1/$probe" 2>/dev/null || true)"
  rm -f "$root/$probe"
  [[ "$body" == "$expected" ]] || fail "$host не читает файлы из $root. Ответ: ${body:0:240}"
  SITE_OK=$((SITE_OK+1))
  [[ "$host" == "$BETA_DOMAIN" ]] && BETA_OK=1
done < "$ROUTING_MAP"
[[ "$SITE_TOTAL" -gt 0 ]] || fail 'Не найдено сайтов для проверки'
[[ "$BETA_OK" == 1 ]] || fail "$BETA_DOMAIN отсутствует в итоговой карте маршрутов"

ADMIN_AFTER="$(admin_hash)"
if [[ -n "$ADMIN_BEFORE" && "$ADMIN_BEFORE" != "$ADMIN_AFTER" ]]; then
  fail 'Хеш пароля admin изменился'
fi
COMMITTED=1

SSL_STATUS=missing
PANEL_CERT=''
PAIR="$(find_cert "$PANEL_DOMAIN" 2>/dev/null || true)"
if [[ -n "$PAIR" ]]; then
  PANEL_CERT="${PAIR%%$'\t'*}"
  SSL_STATUS=restored
else
  log "Действующего сертификата $PANEL_DOMAIN нет — пробую выпустить Let's Encrypt."
  command -v certbot >/dev/null 2>&1 || { apt-get update >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y certbot >/dev/null 2>&1 || true; }
  if command -v certbot >/dev/null 2>&1; then
    token="v88-$STAMP-$$"
    printf 'ok-%s' "$token" > "/opt/hyper-host/acme-webroot/.well-known/acme-challenge/$token"
    acme="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 -H "Host: $PANEL_DOMAIN" "http://127.0.0.1/.well-known/acme-challenge/$token" 2>/dev/null || true)"
    rm -f "/opt/hyper-host/acme-webroot/.well-known/acme-challenge/$token"
    if [[ "$acme" == "ok-$token" ]] && certbot certonly --webroot -w /opt/hyper-host/acme-webroot --non-interactive --agree-tos --register-unsafely-without-email --preferred-challenges http --keep-until-expiring --cert-name "$PANEL_DOMAIN" -d "$PANEL_DOMAIN" >"$CERTBOT_LOG" 2>&1; then
      /usr/local/sbin/hyper-host-nginx-reconcile >/dev/null
      PAIR="$(find_cert "$PANEL_DOMAIN" 2>/dev/null || true)"
      if [[ -n "$PAIR" ]]; then PANEL_CERT="${PAIR%%$'\t'*}"; SSL_STATUS=issued; else SSL_STATUS=failed-no-cert-after-certbot; fi
    else
      SSL_STATUS="failed:$CERTBOT_LOG"
    fi
  else
    SSL_STATUS=failed-certbot-not-installed
  fi
fi

HTTPS_STATUS=not-configured
if [[ "$SSL_STATUS" == restored || "$SSL_STATUS" == issued ]]; then
  CERT_OUT="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$PANEL_DOMAIN" 2>/dev/null | openssl x509 -noout -checkhost "$PANEL_DOMAIN" 2>&1 || true)"
  if printf '%s' "$CERT_OUT" | grep -qi 'does match certificate'; then
    HTTPS_STATUS=works
  else
    HTTPS_STATUS="wrong-certificate"
  fi
fi

BETA_INDEX=none
for f in index.html index.htm index.php; do
  [[ -f "/var/www/hyper-host-sites/$BETA_DOMAIN/public_html/$f" ]] && { BETA_INDEX="$f"; break; }
done

cat > "$REPORT" <<EOF
HYPER-HOST v88 — чистое восстановление Nginx
Дата: $(date -Is)
Резервная копия: $BACKUP

Панель domain: $PANEL_DOMAIN
Панель root: /var/www/hyper-host/public
Панель HTTP: $PANEL_STATUS
Панель route: OK
Панель по IP: OK

Сайтов/aliases: $SITE_OK/$SITE_TOTAL
Beta: $BETA_DOMAIN
Beta root: /var/www/hyper-host-sites/$BETA_DOMAIN/public_html
Beta index: $BETA_INDEX

SSL панели: $SSL_STATUS
HTTPS панели: $HTTPS_STATUS
Сертификат: ${PANEL_CERT:-нет}
Certbot log: $CERTBOT_LOG

Nginx main: /etc/nginx/nginx.conf
Управляемые vhost: /etc/nginx/hyper-host-managed
Карта: $ROUTING_MAP
Старые sites-enabled/conf.d: сохранены на диске, но НЕ подключаются
Admin password: НЕ ИЗМЕНЁН
FTP/SQL/боты/файлы сайтов: НЕ ИЗМЕНЯЛИСЬ
EOF

cat <<EOF

============================================================
 HYPER-HOST — Nginx полностью восстановлен v88
============================================================
 Панель IP:          http://$LAN_IP/ — РАБОТАЕТ
 Панель domain:      http://$PANEL_DOMAIN/ — РАБОТАЕТ
 Панель root:        /var/www/hyper-host/public
 Сайты/aliases:      $SITE_OK/$SITE_TOTAL — РАБОТАЮТ
 Beta root:          /var/www/hyper-host-sites/$BETA_DOMAIN/public_html
 Beta index:         $BETA_INDEX
 SSL панели:         $SSL_STATUS
 HTTPS панели:       $HTTPS_STATUS
 Старые vhost:       НЕ ПОДКЛЮЧАЮТСЯ
 Admin password:     НЕ ИЗМЕНЁН
 Отчёт:              $REPORT
============================================================
EOF
