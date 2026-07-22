#!/usr/bin/env bash
set -Eeuo pipefail

CONF=/etc/hyper-host/hyper-host.conf
BASE=/opt/hyper-host
DATA=$BASE/data/hyperhost.sqlite
PANEL_DOMAIN=panel.hyper-host.pw
BETA_DOMAIN=beta.mystockbot.xyz
LAN_IP=192.168.0.179
PUBLIC_IP=90.189.208.25

read_conf(){
  local key="$1"
  [[ -f "$CONF" ]] || return 0
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#[:space:]]+).*/\\1/p" "$CONF" | tail -n1
}

v="$(read_conf PANEL_DOMAIN)"; [[ -n "$v" && "$v" != _ ]] && PANEL_DOMAIN="$v"
LAN_IP="192.168.0.179"
PUBLIC_IP="90.189.208.25"
v="$(read_conf BETA_DOMAIN)"; [[ -n "$v" ]] && BETA_DOMAIN="$v"

PHP_SOCK="$(read_conf PHP_FPM_SOCK)"
if [[ -z "$PHP_SOCK" || ! -S "$PHP_SOCK" ]]; then
  PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
fi
[[ -n "$PHP_SOCK" ]] || PHP_SOCK=/run/php/php8.2-fpm.sock

DEFAULT_DIR=$BASE/ssl/default-vhost
DEFAULT_CERT=$DEFAULT_DIR/fullchain.pem
DEFAULT_KEY=$DEFAULT_DIR/privkey.pem
mkdir -p "$DEFAULT_DIR" /opt/hyper-host/acme-webroot/.well-known/acme-challenge /var/log/nginx
if [[ ! -s "$DEFAULT_CERT" || ! -s "$DEFAULT_KEY" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj '/CN=hyper-host-default.invalid' \
    -keyout "$DEFAULT_KEY" -out "$DEFAULT_CERT" >/dev/null 2>&1
  chmod 0600 "$DEFAULT_KEY"; chmod 0644 "$DEFAULT_CERT"
fi

python3 /opt/hyper-host/nginx_recover_v89.py \
  --panel-domain "$PANEL_DOMAIN" \
  --lan-ip "$LAN_IP" \
  --public-ip "$PUBLIC_IP" \
  --beta-domain "$BETA_DOMAIN" \
  --panel-root /var/www/hyper-host/public \
  --db "$DATA" \
  --panel-php-sock "$PHP_SOCK" \
  --default-cert "$DEFAULT_CERT" \
  --default-key "$DEFAULT_KEY" \
  --acme-webroot "$BASE/acme-webroot" \
  --map /opt/hyper-host/data/v89-routing.tsv

if ! TEST_OUTPUT="$(nginx -t 2>&1)"; then
  printf '%s\n' "$TEST_OUTPUT" >&2
  exit 1
fi

# Do not trust a soft reload here. A stale nginx master previously kept the
# omnistockcrm.tech certificate as the TLS fallback for every SNI domain even
# though nginx -T already showed the new files. Restart the single systemd
# instance so the tested configuration is certainly active.
systemctl stop nginx >/dev/null 2>&1 || true
pkill -TERM -x nginx >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  pgrep -x nginx >/dev/null 2>&1 || break
  sleep 0.2
done
if pgrep -x nginx >/dev/null 2>&1; then
  pkill -KILL -x nginx >/dev/null 2>&1 || true
  sleep 0.5
fi
rm -f /run/nginx.pid 2>/dev/null || true
if ss -ltnp 'sport = :443' 2>/dev/null | tail -n +2 | grep -q .; then
  ss -ltnp 'sport = :443' >&2 || true
  echo '[HYPER-HOST ERROR] Порт 443 занят не Nginx' >&2
  exit 1
fi
systemctl start nginx >/dev/null 2>&1 || {
  systemctl status nginx --no-pager -l >&2 2>/dev/null || true
  exit 1
}
sleep 1
systemctl is-active --quiet nginx
ss -ltnp 'sport = :443' 2>/dev/null | grep -q nginx
