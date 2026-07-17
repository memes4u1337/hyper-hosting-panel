#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${1:-beta.mystockbot.xyz}"
EMAIL="${2:-}"
BASE="/opt/hyper-host"
LE_CONFIG="$BASE/letsencrypt"
LE_WORK="$BASE/certbot-work"
LE_LOGS="$BASE/certbot-logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v90-certbot-readonly-$STAMP"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; exit 1; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_domain "$DOMAIN" || fail "Некорректный домен: $DOMAIN"
[[ -f "$ROOT/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$ROOT/scripts/hyper" ]] || fail 'Не найден scripts/hyper'
command -v certbot >/dev/null 2>&1 || fail 'certbot не установлен'

mkdir -p "$BACKUP" "$LE_CONFIG" "$LE_WORK" "$LE_LOGS"
chmod 0700 "$LE_CONFIG" "$LE_WORK"
chmod 0750 "$LE_LOGS"

for file in /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper /usr/bin/hyper; do
  [[ -e "$file" || -L "$file" ]] && cp -aL "$file" "$BACKUP/$(basename "$file")" 2>/dev/null || true
done

# Если раньше сертификаты уже создавались в /etc/letsencrypt, переносим их
# в writable-каталог HYPER-HOST. Относительные symlink live -> archive сохраняются.
if [[ -d /etc/letsencrypt && ! -d "$LE_CONFIG/live" ]]; then
  log 'Переношу существующее состояние Certbot из read-only /etc/letsencrypt в /opt/hyper-host/letsencrypt.'
  tar -C /etc/letsencrypt --exclude='./.certbot.lock' -cpf - . 2>/dev/null | tar -C "$LE_CONFIG" -xpf - 2>/dev/null || true
fi
rm -f "$LE_CONFIG/.certbot.lock" "$LE_WORK/.certbot.lock" "$LE_LOGS/.certbot.lock" 2>/dev/null || true

log 'Устанавливаю v90: Certbot больше не записывает в /etc/letsencrypt.'
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install -m 0755 "$ROOT/scripts/hyper" /usr/local/bin/hyper
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl
ln -sfn /usr/local/bin/hyper /usr/bin/hyper

bash -n /usr/local/sbin/hyper-host-ctl
bash -n /usr/local/bin/hyper

# Обычный certbot.timer использует /etc/letsencrypt. Останавливаем его и
# ставим собственное ежедневное продление через root-crontab в /var/spool.
systemctl disable --now certbot.timer >/dev/null 2>&1 || systemctl stop certbot.timer >/dev/null 2>&1 || true
if command -v crontab >/dev/null 2>&1; then
  {
    crontab -l 2>/dev/null | grep -v 'HYPER-HOST-CERTBOT-RENEW' || true
    printf '17 3 * * * /usr/local/bin/hyper ssl renew >>%s/renew-cron.log 2>&1 # HYPER-HOST-CERTBOT-RENEW\n' "$LE_LOGS"
  } | awk 'NF' | crontab -
fi

log 'Проверяю, что Certbot создаёт lock-файл только внутри /opt.'
certbot \
  --config-dir "$LE_CONFIG" \
  --work-dir "$LE_WORK" \
  --logs-dir "$LE_LOGS" \
  certificates >/dev/null

log "Исправляю ACME/Nginx для $DOMAIN."
/usr/local/bin/hyper ssl fix "$DOMAIN"

if [[ -n "$EMAIL" ]]; then
  log "Выпускаю SSL для $DOMAIN."
  /usr/local/bin/hyper ssl issue "$DOMAIN" "$EMAIL"
  /usr/local/bin/hyper ssl check "$DOMAIN" || true
  nginx -t
  log "Готово: https://$DOMAIN"
else
  log 'v90 установлен. Для выпуска сертификата выполни:'
  printf 'sudo hyper ssl issue %s YOUR_EMAIL\n' "$DOMAIN"
fi

printf 'Certbot config: %s\nCertbot work: %s\nCertbot logs: %s\nBackup: %s\n' \
  "$LE_CONFIG" "$LE_WORK" "$LE_LOGS" "$BACKUP"
