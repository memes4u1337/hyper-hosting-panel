#!/usr/bin/env bash
set -Eeuo pipefail
CONF=/etc/hyper-host/hyper-host.conf
read_conf(){ local k="$1"; [[ -f "$CONF" ]] && sed -nE "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*[\"']?([^\"'#[:space:]]+).*/\\1/p" "$CONF" | tail -n1 || true; }
PANEL_DOMAIN="${PANEL_DOMAIN_OVERRIDE:-$(read_conf PANEL_DOMAIN)}"; [[ -n "$PANEL_DOMAIN" ]] || PANEL_DOMAIN=panel.hyper-host.pw
BETA_DOMAIN="${BETA_DOMAIN_OVERRIDE:-beta.mystockbot.xyz}"
LAN_IP="$(read_conf SERVER_IP)"; [[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(read_conf PUBLIC_IP)"; [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP=90.189.208.25
PHP_SOCK="$(read_conf PHP_FPM_SOCK)"; [[ -n "$PHP_SOCK" && -S "$PHP_SOCK" ]] || PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"; [[ -n "$PHP_SOCK" ]] || PHP_SOCK=/run/php/php8.2-fpm.sock
DEFAULT_DIR=/opt/hyper-host/ssl/default-vhost; mkdir -p "$DEFAULT_DIR"
DEFAULT_CERT=$DEFAULT_DIR/fullchain.pem; DEFAULT_KEY=$DEFAULT_DIR/privkey.pem
if [[ ! -s "$DEFAULT_CERT" || ! -s "$DEFAULT_KEY" ]]; then openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj '/CN=hyper-host-default.invalid' -keyout "$DEFAULT_KEY" -out "$DEFAULT_CERT" >/dev/null 2>&1; chmod 0600 "$DEFAULT_KEY"; chmod 0644 "$DEFAULT_CERT"; fi
STAMP="$(date +%Y%m%d-%H%M%S)"; BACKUP="/opt/hyper-host/backups/v87-reconcile-$STAMP"; mkdir -p "$BACKUP"
tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" .
python3 /opt/hyper-host/nginx_recover_v87.py --panel-domain "$PANEL_DOMAIN" --lan-ip "$LAN_IP" --public-ip "$PUBLIC_IP" --beta-domain "$BETA_DOMAIN" --panel-root /var/www/hyper-host/public --db /opt/hyper-host/data/hyperhost.sqlite --panel-php-sock "$PHP_SOCK" --default-cert "$DEFAULT_CERT" --default-key "$DEFAULT_KEY" --backup-dir "$BACKUP" --map /opt/hyper-host/data/v87-routing.tsv --cleanup-report /opt/hyper-host/data/v87-nginx-cleanup.txt
nginx -t
systemctl reload nginx
