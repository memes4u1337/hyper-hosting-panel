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
v="$(read_conf SERVER_IP)"; [[ -n "$v" ]] && LAN_IP="$v"
v="$(read_conf PUBLIC_IP)"; [[ -n "$v" ]] && PUBLIC_IP="$v"
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
  --map /opt/hyper-host/data/v88-routing.tsv

nginx -t
systemctl restart nginx
