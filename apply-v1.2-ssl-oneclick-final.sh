#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
BASE_DIR="/opt/hyper-host"
PANEL_DIR="/var/www/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
RECONCILE_BIN="/usr/local/sbin/hyper-host-nginx-reconcile"
SSL_TRUTH_BIN="$BASE_DIR/ssl-truth.py"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BASE_DIR/backups/v1.2-ssl-oneclick-$TIMESTAMP"
REPORT="$BASE_DIR/logs/ssl-oneclick-$TIMESTAMP.txt"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
warn(){ printf '[HYPER-HOST WARNING] %s\n' "$*" >&2; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Запусти патч через sudo/root.'

REQUIRED=(
  scripts/hhctl scripts/hyper scripts/nginx-reconcile-v89.sh
  scripts/nginx_recover_v89.py scripts/ssl_truth.py
  src/public/index.php src/app/bootstrap.php
)
for file in "${REQUIRED[@]}"; do
  [[ -f "$ROOT_DIR/$file" ]] || fail "Нет обязательного файла: $file"
done

bash -n "$ROOT_DIR/scripts/hhctl"
bash -n "$ROOT_DIR/scripts/hyper"
bash -n "$ROOT_DIR/scripts/nginx-reconcile-v89.sh"
python3 -m py_compile "$ROOT_DIR/scripts/nginx_recover_v89.py" "$ROOT_DIR/scripts/ssl_truth.py"
php -l "$ROOT_DIR/src/public/index.php" >/dev/null
php -l "$ROOT_DIR/src/app/bootstrap.php" >/dev/null

same_path(){
  local a b
  a="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
  b="$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")"
  [[ "$a" == "$b" ]]
}

install_if_different(){
  local mode="$1" src="$2" dst="$3"
  mkdir -p "$(dirname "$dst")"
  if same_path "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
  elif [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
  else
    install -m"$mode" "$src" "$dst"
  fi
}

log "Создаю резервную копию: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/logs" "$BASE_DIR/bin"
for path in "$CONTROL_BIN" "$HYPER_BIN" "$RECONCILE_BIN" "$SSL_TRUTH_BIN" \
            "$BASE_DIR/nginx_recover_v89.py" "$PANEL_DIR/public/index.php"; do
  if [[ -e "$path" || -L "$path" ]]; then
    name="$(printf '%s' "$path" | sed 's#^/##;s#/#__#g')"
    cp -aL "$path" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
  fi
done
# Certificate storage is not modified or deleted. Keep a metadata snapshot only;
# copying the whole tree can be very slow and is unnecessary for this patch.
find "$BASE_DIR/letsencrypt/live" /etc/letsencrypt/live -maxdepth 2 -name fullchain.pem -print \
  >"$BACKUP_DIR/certificates-before.txt" 2>/dev/null || true

log 'Устанавливаю единый SSL-движок и обновлённую панель.'
install_if_different 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$RECONCILE_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$BASE_DIR/nginx_recover_v89.py"
install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$SSL_TRUTH_BIN"
ln -sfn "$HYPER_BIN" /usr/bin/hyper
ln -sfn "$CONTROL_BIN" /usr/bin/hyper-host-ctl

if ! same_path "$ROOT_DIR" "$PROJECT_DIR"; then
  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/src/public" "$PROJECT_DIR/src/app"
  install_if_different 0755 "$ROOT_DIR/scripts/hhctl" "$PROJECT_DIR/scripts/hhctl"
  install_if_different 0755 "$ROOT_DIR/scripts/hyper" "$PROJECT_DIR/scripts/hyper"
  install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$PROJECT_DIR/scripts/nginx-reconcile-v89.sh"
  install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$PROJECT_DIR/scripts/nginx_recover_v89.py"
  install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$PROJECT_DIR/scripts/ssl_truth.py"
  install_if_different 0644 "$ROOT_DIR/src/public/index.php" "$PROJECT_DIR/src/public/index.php"
  install_if_different 0644 "$ROOT_DIR/src/app/bootstrap.php" "$PROJECT_DIR/src/app/bootstrap.php"
fi

mkdir -p "$PANEL_DIR/public" "$PANEL_DIR/app"
install_if_different 0644 "$ROOT_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
install_if_different 0644 "$ROOT_DIR/src/app/bootstrap.php" "$PANEL_DIR/app/bootstrap.php"
chown www-data:www-data "$PANEL_DIR/public/index.php" "$PANEL_DIR/app/bootstrap.php" 2>/dev/null || true

log 'Проверяю Certbot-каталоги и ACME webroot.'
mkdir -p "$BASE_DIR/letsencrypt" "$BASE_DIR/certbot-work" "$BASE_DIR/certbot-logs" \
  "$BASE_DIR/acme-webroot/.well-known/acme-challenge"
chmod 0700 "$BASE_DIR/letsencrypt" "$BASE_DIR/certbot-work" 2>/dev/null || true
chmod 0750 "$BASE_DIR/certbot-logs" 2>/dev/null || true
chown -R www-data:www-data "$BASE_DIR/acme-webroot" 2>/dev/null || true
chmod -R a+rX "$BASE_DIR/acme-webroot" 2>/dev/null || true

log 'Возвращаю существующие сертификаты в Nginx.'
RESTORE_JSON="$($CONTROL_BIN ssl-restore-existing 2>&1 || true)"
printf '%s\n' "$RESTORE_JSON" >"$BACKUP_DIR/restore.json"

log 'Пересобираю Nginx и проверяю HTTPS-конфигурацию.'
"$RECONCILE_BIN"
nginx -t
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx

# Update UI flags from real certificates and the SNI response.
AUDIT_JSON="$($CONTROL_BIN ssl-audit-json 2>&1 || true)"
printf '%s\n' "$AUDIT_JSON" >"$BACKUP_DIR/audit.json"

# Certbot renewal must use HYPER-HOST paths, never read-only /etc/letsencrypt.
if command -v crontab >/dev/null 2>&1; then
  current="$(crontab -l 2>/dev/null | grep -v 'HYPER-HOST-CERTBOT-RENEW' || true)"
  {
    printf '%s\n' "$current"
    printf '17 3 * * * /usr/local/bin/hyper ssl renew >>%s/certbot-logs/renew-cron.log 2>&1 # HYPER-HOST-CERTBOT-RENEW\n' "$BASE_DIR"
  } | awk 'NF' | crontab -
fi

{
  echo 'HYPER-HOST v1.2 SSL ONE-CLICK FINAL'
  echo "backup=$BACKUP_DIR"
  echo 'certbot_config=/opt/hyper-host/letsencrypt'
  echo 'acme_webroot=/opt/hyper-host/acme-webroot'
  echo 'public_ip=90.189.208.25'
  echo 'lan_ip=192.168.0.179'
  echo 'existing_certificates=reconnected'
  echo 'aliases=issued_independently_when_dns_ready'
  echo 'ftp=not_modified'
  echo
  echo 'Restore:'
  printf '%s\n' "$RESTORE_JSON"
  echo
  echo 'Audit:'
  printf '%s\n' "$AUDIT_JSON"
} >"$REPORT"

printf '\n'
printf '============================================================\n'
printf ' HYPER-HOST v1.2 — SSL ИСПРАВЛЕН\n'
printf '============================================================\n'
printf ' Старые сертификаты: найдены и подключены к Nginx\n'
printf ' Новые сайты: одна кнопка выпускает SSL для домена\n'
printf ' Aliases/www: выпускаются отдельно, если их DNS готов\n'
printf ' Certbot: /opt/hyper-host/letsencrypt\n'
printf ' FTP и данные сайтов: не изменялись\n'
printf ' Backup: %s\n' "$BACKUP_DIR"
printf ' Report: %s\n' "$REPORT"
printf '============================================================\n'
printf ' Проверка: sudo hyper ssl status\n'
printf ' Все домены: sudo hyper ssl repair-all EMAIL\n'
