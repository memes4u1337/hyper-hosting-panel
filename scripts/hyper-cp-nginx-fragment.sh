#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CP — генератор постоянного vhost для клиентского портала.
# powered by memes4u1337
# Вызывается установщиком и hyper-host-nginx-reconcile, чтобы vhost не терялся.

CP_DOMAIN="${CP_DOMAIN:-cp.hyper-host.pw}"
APP_ROOT="${CP_APP_ROOT:-/var/www/hyper-host-cp}"
MANAGED_DIR="${HYPER_NGINX_MANAGED_DIR:-/etc/nginx/hyper-host-managed}"
ACME_ROOT="${HYPER_ACME_ROOT:-/opt/hyper-host/acme-webroot}"
CONF="$MANAGED_DIR/16-cp-app.conf"

mkdir -p "$MANAGED_DIR" "$ACME_ROOT/.well-known/acme-challenge" /var/log/nginx/hyper-cp

# Портал имеет приоритет над обычным сайтом с тем же именем.
rm -f "$MANAGED_DIR/20-site-${CP_DOMAIN}.conf" 2>/dev/null || true

FPM_SOCK="${PHP_FPM_SOCK:-/run/php/hypercp.sock}"
if [[ ! -S "$FPM_SOCK" ]]; then
  FPM_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
fi
[[ -n "$FPM_SOCK" && -S "$FPM_SOCK" ]] || { echo "[HYPER-CP] PHP-FPM сокет не найден" >&2; exit 1; }

CERT=""; KEY=""
for base in /etc/letsencrypt/live /opt/hyper-host/letsencrypt/live; do
  c="$base/$CP_DOMAIN/fullchain.pem"; k="$base/$CP_DOMAIN/privkey.pem"
  if [[ -f "$c" && -f "$k" ]] && openssl x509 -in "$c" -noout -checkend 0 >/dev/null 2>&1; then
    CERT="$c"; KEY="$k"; break
  fi
done

write_locations(){
  cat <<NGINX
    root $APP_ROOT/public;
    index index.php;
    charset utf-8;
    client_max_body_size 512m;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "same-origin" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type text/plain;
        try_files \$uri =404;
        allow all;
    }

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }

    location ~ \.php\$ {
        try_files \$uri =404;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$document_root;
        fastcgi_param HTTPS \$https if_not_empty;
        fastcgi_pass unix:$FPM_SOCK;
        fastcgi_connect_timeout 60s;
        fastcgi_send_timeout 900s;
        fastcgi_read_timeout 900s;
    }

    location ~* \.(?:css|js|png|jpg|jpeg|gif|webp|svg|ico|woff2?)\$ {
        expires 1d;
        add_header Cache-Control "public, max-age=86400";
        try_files \$uri =404;
    }

    location ~ /\.(?!well-known) { deny all; }
    location = /favicon.ico { log_not_found off; access_log off; }
NGINX
}

{
  cat <<NGINX
# HYPER-HOST CP — клиентский портал. Сгенерировано автоматически.
server {
    listen 80;
    listen [::]:80;
    server_name $CP_DOMAIN;
    access_log /var/log/nginx/hyper-cp/access.log;
    error_log /var/log/nginx/hyper-cp/error.log;
NGINX
  if [[ -n "$CERT" ]]; then
    cat <<NGINX
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
NGINX
  else
    write_locations
  fi
  echo "}"

  if [[ -n "$CERT" ]]; then
    cat <<NGINX
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $CP_DOMAIN;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;
    access_log /var/log/nginx/hyper-cp/access-ssl.log;
    error_log /var/log/nginx/hyper-cp/error-ssl.log;
NGINX
    write_locations
    echo "}"
  fi
} > "$CONF"

chmod 0644 "$CONF"
printf '[HYPER-CP] vhost: %s -> %s/public (ssl=%s)\n' "$CP_DOMAIN" "$APP_ROOT" "$([[ -n "$CERT" ]] && echo yes || echo no)"
