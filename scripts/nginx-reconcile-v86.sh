#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_DOMAIN="${PANEL_DOMAIN_OVERRIDE:-panel.hyper-host.pw}"
BETA_DOMAIN="${BETA_DOMAIN_OVERRIDE:-beta.mystockbot.xyz}"
CONF=/etc/hyper-host/hyper-host.conf
BASE=/opt/hyper-host
DATA=$BASE/data/hyperhost.sqlite
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v86-reconcile-$STAMP"
mkdir -p "$BACKUP"

read_conf() {
  local key="$1"
  [[ -f "$CONF" ]] || return 0
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#[:space:]]+).*/\\1/p" "$CONF" | tail -n1
}

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

PHP_SOCK="$(read_conf PHP_FPM_SOCK)"
[[ -n "$PHP_SOCK" && -S "$PHP_SOCK" ]] || PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "$PHP_SOCK" ]] || PHP_SOCK=/run/php/php8.2-fpm.sock

DEFAULT_DIR=$BASE/ssl/default-vhost
DEFAULT_CERT=$DEFAULT_DIR/fullchain.pem
DEFAULT_KEY=$DEFAULT_DIR/privkey.pem
mkdir -p "$DEFAULT_DIR"
if [[ ! -s "$DEFAULT_CERT" || ! -s "$DEFAULT_KEY" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj '/CN=hyper-host-default.invalid' \
    -keyout "$DEFAULT_KEY" -out "$DEFAULT_CERT" >/dev/null 2>&1
  chmod 0600 "$DEFAULT_KEY"; chmod 0644 "$DEFAULT_CERT"
fi

tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" .
python3 /opt/hyper-host/nginx_recover_v86.py \
  --panel-domain "$PANEL_DOMAIN" --lan-ip "$LAN_IP" --public-ip "$PUBLIC_IP" \
  --beta-domain "$BETA_DOMAIN" --panel-root "$PANEL_ROOT" --db "$DATA" \
  --panel-php-sock "$PHP_SOCK" --default-cert "$DEFAULT_CERT" --default-key "$DEFAULT_KEY" \
  --backup-dir "$BACKUP" --map "$BASE/data/v86-routing.tsv" \
  --cleanup-report "$BASE/data/v86-nginx-cleanup.txt"
nginx -t
systemctl reload nginx
