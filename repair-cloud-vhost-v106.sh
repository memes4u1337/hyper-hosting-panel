#!/usr/bin/env bash
set -Eeuo pipefail

CLOUD_DOMAIN="${CLOUD_DOMAIN:-cloud.hyper-host.pw}"
APP_ROOT="${CLOUD_APP_ROOT:-/var/www/hyper-host-cloud-app}"
HELPER_SRC="${1:-$(pwd)}/scripts/hyper-cloud-nginx-fragment.sh"
HELPER_DST="/opt/hyper-host/bin/hyper-cloud-nginx-fragment.sh"
MANAGED_DIR="/etc/nginx/hyper-host-managed"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/hyper-host/backups/cloud-v106-vhost-${STAMP}"

[[ ${EUID} -eq 0 ]] || { echo "[ERROR] Запустите от root" >&2; exit 1; }
[[ -f "$APP_ROOT/public/index.php" ]] || { echo "[ERROR] Cloud app не найден: $APP_ROOT/public/index.php" >&2; exit 1; }
[[ -f "$HELPER_SRC" ]] || { echo "[ERROR] Не найден helper: $HELPER_SRC" >&2; exit 1; }

mkdir -p "$BACKUP" /opt/hyper-host/bin "$MANAGED_DIR"
cp -a "$MANAGED_DIR" "$BACKUP/hyper-host-managed" 2>/dev/null || true
install -m 0755 "$HELPER_SRC" "$HELPER_DST"

FPM_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "$FPM_SOCK" && -S "$FPM_SOCK" ]] || { echo "[ERROR] PHP-FPM socket не найден" >&2; exit 1; }
echo "[HYPER CLOUD] PHP-FPM: $FPM_SOCK"

# Quarantine every legacy nginx file that claims the same hostname outside managed dir.
for dir in /etc/nginx/sites-enabled /etc/nginx/sites-available; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r conf; do
    [[ -n "$conf" ]] || continue
    base="$(basename "$conf")"
    cp -aL "$conf" "$BACKUP/$base" 2>/dev/null || true
    rm -f -- "$conf"
  done < <(grep -RIlE "server_name[[:space:]][^;]*${CLOUD_DOMAIN//./\.}([[:space:];]|$)" "$dir" 2>/dev/null || true)
done
rm -f "$MANAGED_DIR/20-site-$CLOUD_DOMAIN.conf" 2>/dev/null || true

# Stop HYPER-HOST from treating the Cloud hostname as a regular hosted site.
if [[ -d "/var/www/hyper-host-sites/$CLOUD_DOMAIN" ]]; then
  touch "/var/www/hyper-host-sites/$CLOUD_DOMAIN/.hyper-host-disabled" || true
fi
PANEL_DB="$(php -r '$c=require "/var/www/hyper-host/app/config.php"; echo (string)($c["db_path"]??"");' 2>/dev/null || true)"
[[ -n "$PANEL_DB" ]] || PANEL_DB="/opt/hyper-host/data/hyperhost.sqlite"
if [[ -f "$PANEL_DB" ]] && command -v sqlite3 >/dev/null; then
  sqlite3 "$PANEL_DB" ".backup '$BACKUP/panel.sqlite'" >/dev/null 2>&1 || true
  sqlite3 "$PANEL_DB" "DELETE FROM sites WHERE lower(domain)=lower('$CLOUD_DOMAIN');" >/dev/null 2>&1 || true
fi

# If reconcile is already patched, it will use the new helper. Reconcile first, then
# always write the Cloud vhost one more time so this repair works even after failed v104/v105.
export PHP_FPM_SOCK="$FPM_SOCK"
if [[ -x /usr/local/sbin/hyper-host-nginx-reconcile ]]; then
  /usr/local/sbin/hyper-host-nginx-reconcile || true
fi
PHP_FPM_SOCK="$FPM_SOCK" "$HELPER_DST"

nginx -t
systemctl reload nginx
sleep 1

PROTO=http; PORT=80
if [[ -f "/etc/letsencrypt/live/$CLOUD_DOMAIN/fullchain.pem" || -f "/opt/hyper-host/letsencrypt/live/$CLOUD_DOMAIN/fullchain.pem" ]]; then
  PROTO=https; PORT=443
fi
ROUTE="$(curl -ksS --max-time 10 --resolve "$CLOUD_DOMAIN:$PORT:127.0.0.1" "$PROTO://$CLOUD_DOMAIN/__hyper_cloud_route__" || true)"
if [[ "$ROUTE" != "HYPER_CLOUD_V106" ]]; then
  echo "[ERROR] Cloud route не поднялся. Ответ: ${ROUTE:0:200}" >&2
  echo "[DEBUG] server_name $CLOUD_DOMAIN:" >&2
  grep -RInE "server_name[[:space:]].*${CLOUD_DOMAIN//./\.}" /etc/nginx/hyper-host-managed /etc/nginx/sites-enabled /etc/nginx/sites-available 2>/dev/null >&2 || true
  exit 1
fi
HTML="$(curl -ksS --max-time 10 --resolve "$CLOUD_DOMAIN:$PORT:127.0.0.1" "$PROTO://$CLOUD_DOMAIN/" || true)"
if ! grep -Fq 'HYPER CLOUD' <<<"$HTML"; then
  echo "[ERROR] Marker есть, но интерфейс Cloud не отдался" >&2
  exit 1
fi
printf '\n[HYPER CLOUD] DOMAIN_OK: %s://%s/ -> HYPER CLOUD v106\n' "$PROTO" "$CLOUD_DOMAIN"
printf '[HYPER CLOUD] Backup: %s\n' "$BACKUP"
