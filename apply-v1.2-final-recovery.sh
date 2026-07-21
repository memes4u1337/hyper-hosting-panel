#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST ERROR] Запусти через sudo/root.' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
BASE_DIR="/opt/hyper-host"
CONF="/etc/hyper-host/hyper-host.conf"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
INSTALLER_BIN="/usr/local/sbin/hyper-host-installer"
RUNTIME_BIN="$BASE_DIR/bin/hyper-host-nginx-runtime"
RECONCILE_BIN="/usr/local/sbin/hyper-host-nginx-reconcile"
SSL_TRUTH_BIN="$BASE_DIR/ssl-truth.py"
FTP_FIX_BIN="$BASE_DIR/bin/hyper_ftp_proftpd_fix.sh"
LE_CONFIG_DIR="$BASE_DIR/letsencrypt"
LE_WORK_DIR="$BASE_DIR/certbot-work"
LE_LOGS_DIR="$BASE_DIR/certbot-logs"
BACKUP_DIR="$BASE_DIR/backups/v1.2-final-recovery-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v1.2-final-recovery-report.txt"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
warn(){ printf '[HYPER-HOST WARNING] %s\n' "$*" >&2; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

REQUIRED=(
  setup.sh
  install.sh
  scripts/hhctl
  scripts/hyper
  scripts/hyper_nginx_runtime.sh
  scripts/nginx_recover_v89.py
  scripts/nginx-reconcile-v89.sh
  scripts/hyper_ftp_proftpd_fix.sh
  scripts/proftpd_auth_sync.py
  scripts/ssl_truth.py
)
for file in "${REQUIRED[@]}"; do
  [[ -f "$ROOT_DIR/$file" ]] || fail "В архиве отсутствует обязательный файл: $file"
done

bash -n "$ROOT_DIR/setup.sh"
bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/scripts/hhctl"
bash -n "$ROOT_DIR/scripts/hyper"
bash -n "$ROOT_DIR/scripts/hyper_nginx_runtime.sh"
bash -n "$ROOT_DIR/scripts/nginx-reconcile-v89.sh"
bash -n "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh"
python3 -m py_compile \
  "$ROOT_DIR/scripts/nginx_recover_v89.py" \
  "$ROOT_DIR/scripts/proftpd_auth_sync.py" \
  "$ROOT_DIR/scripts/ssl_truth.py"

[[ -f "$CONF" ]] || fail "Панель не установлена: отсутствует $CONF"
# shellcheck disable=SC1090
source "$CONF"
SITES_DIR="${SITES_DIR:-/var/www/hyper-host-sites}"
ACME_WEBROOT="${ACME_WEBROOT:-$BASE_DIR/acme-webroot}"

copy_exec_if_needed(){
  local src="$1" dst="$2" src_real dst_real
  mkdir -p "$(dirname "$dst")"
  src_real="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
  dst_real="$(readlink -f "$dst" 2>/dev/null || printf '%s' "$dst")"
  if [[ "$src_real" == "$dst_real" ]]; then
    chmod 0755 "$dst"
  else
    install -m0755 "$src" "$dst"
  fi
}

cert_count(){
  local root="${1:-$LE_CONFIG_DIR}"
  [[ -d "$root/live" ]] || { echo 0; return; }
  find -L "$root/live" -mindepth 2 -maxdepth 2 -type f -name fullchain.pem 2>/dev/null | wc -l | tr -d ' '
}

copy_certbot_state(){
  local src="$1"
  [[ -d "$src/live" && -d "$src/archive" ]] || return 1
  log "Восстанавливаю состояние Certbot из $src"
  mkdir -p "$LE_CONFIG_DIR"
  tar -C "$src" --exclude='./.certbot.lock' -cpf - . 2>/dev/null \
    | tar -C "$LE_CONFIG_DIR" -xpf - 2>/dev/null
}

recover_certificates(){
  mkdir -p "$LE_CONFIG_DIR" "$LE_WORK_DIR" "$LE_LOGS_DIR" "$ACME_WEBROOT/.well-known/acme-challenge"
  chmod 0700 "$LE_CONFIG_DIR" "$LE_WORK_DIR" 2>/dev/null || true
  chmod 0750 "$LE_LOGS_DIR" 2>/dev/null || true
  rm -f "$LE_CONFIG_DIR/.certbot.lock" "$LE_WORK_DIR/.certbot.lock" "$LE_LOGS_DIR/.certbot.lock" 2>/dev/null || true

  if (( $(cert_count "$LE_CONFIG_DIR") > 0 )); then
    log "Найдено действующих хранилищ сертификатов: $(cert_count "$LE_CONFIG_DIR")"
    return 0
  fi

  if [[ -d /etc/letsencrypt/live && -d /etc/letsencrypt/archive ]]; then
    copy_certbot_state /etc/letsencrypt || true
  fi
  if (( $(cert_count "$LE_CONFIG_DIR") > 0 )); then return 0; fi

  local candidate
  while IFS= read -r candidate; do
    [[ "$candidate" != "$LE_CONFIG_DIR" ]] || continue
    copy_certbot_state "$candidate" || true
    (( $(cert_count "$LE_CONFIG_DIR") > 0 )) && break
  done < <(find "$BASE_DIR/backups" -type d -name letsencrypt 2>/dev/null | sort -r)

  if (( $(cert_count "$LE_CONFIG_DIR") == 0 )); then
    warn 'Файлы ранее выпущенных сертификатов не найдены. Существующие сайты будут восстановлены по HTTP; SSL можно выпустить повторно из панели.'
  fi
}

log "Создаю резервную копию: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$PROJECT_DIR/scripts" "$BASE_DIR/bin" "$BASE_DIR/logs" "$BASE_DIR/runtime"
for path in "$CONTROL_BIN" "$HYPER_BIN" "$INSTALLER_BIN" "$RUNTIME_BIN" "$RECONCILE_BIN" "$SSL_TRUTH_BIN" "$FTP_FIX_BIN"; do
  if [[ -e "$path" || -L "$path" ]]; then
    name="$(printf '%s' "$path" | sed 's#^/##;s#/#__#g')"
    cp -aL "$path" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
  fi
done
if [[ -d "$LE_CONFIG_DIR" ]]; then
  mkdir -p "$BACKUP_DIR/letsencrypt"
  cp -a "$LE_CONFIG_DIR/." "$BACKUP_DIR/letsencrypt/" 2>/dev/null || true
fi
if [[ -d "$BASE_DIR/runtime/nginx" ]]; then
  cp -a "$BASE_DIR/runtime/nginx" "$BACKUP_DIR/nginx-runtime" 2>/dev/null || true
elif [[ -d /etc/nginx ]]; then
  cp -a /etc/nginx "$BACKUP_DIR/nginx" 2>/dev/null || true
fi
if [[ -d "$BASE_DIR/proftpd" ]]; then
  cp -a "$BASE_DIR/proftpd" "$BACKUP_DIR/proftpd" 2>/dev/null || true
fi

log 'Устанавливаю только актуальные файлы HYPER-HOST v1.2.'
for file in setup.sh install.sh; do
  copy_exec_if_needed "$ROOT_DIR/$file" "$PROJECT_DIR/$file"
done
for file in hhctl hyper hyper_nginx_runtime.sh nginx-reconcile-v89.sh hyper_ftp_proftpd_fix.sh; do
  copy_exec_if_needed "$ROOT_DIR/scripts/$file" "$PROJECT_DIR/scripts/$file"
done
for file in nginx_recover_v89.py proftpd_auth_sync.py ssl_truth.py; do
  install -m0755 "$ROOT_DIR/scripts/$file" "$PROJECT_DIR/scripts/$file"
done

install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install -m0755 "$ROOT_DIR/setup.sh" "$INSTALLER_BIN"
install -m0755 "$ROOT_DIR/scripts/hyper_nginx_runtime.sh" "$RUNTIME_BIN"
install -m0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$RECONCILE_BIN"
install -m0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$BASE_DIR/nginx_recover_v89.py"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$FTP_FIX_BIN"
install -m0755 "$ROOT_DIR/scripts/ssl_truth.py" "$SSL_TRUTH_BIN"

ln -sfn "$HYPER_BIN" /usr/bin/hyper
ln -sfn "$CONTROL_BIN" /usr/bin/hyper-host-ctl
ln -sfn "$INSTALLER_BIN" /usr/local/bin/hyper-host-installer
[[ "$(readlink -f "$HYPER_BIN")" != "$(readlink -f "$CONTROL_BIN")" ]] \
  || fail 'Команда hyper ошибочно указывает на hyper-host-ctl.'

recover_certificates

log 'Восстанавливаю writable Nginx runtime.'
"$RUNTIME_BIN"

if command -v crontab >/dev/null 2>&1; then
  current="$(crontab -l 2>/dev/null \
    | grep -v 'HYPER-HOST-NGINX-RUNTIME' \
    | grep -v 'HYPER-HOST-FTP-RESTORE' \
    | grep -v 'HYPER-HOST-CERTBOT-RENEW' || true)"
  {
    printf '%s\n' "$current"
    printf '@reboot sleep 5; %s --boot >>%s/logs/nginx-runtime-boot.log 2>&1 # HYPER-HOST-NGINX-RUNTIME\n' "$RUNTIME_BIN" "$BASE_DIR"
    printf '@reboot sleep 20; %s ftp-fix >>/var/log/hyper-host-ftp-restore.log 2>&1 # HYPER-HOST-FTP-RESTORE\n' "$CONTROL_BIN"
    printf '17 3 * * * %s ssl renew >>%s/renew-cron.log 2>&1 # HYPER-HOST-CERTBOT-RENEW\n' "$HYPER_BIN" "$LE_LOGS_DIR"
  } | awk 'NF' | crontab -
fi

probe="/etc/nginx/.hyper-host-write-probe-$$"
( umask 077; : > "$probe" ) 2>/dev/null || fail '/etc/nginx остался read-only.'
rm -f "$probe"

log 'Удаляю только временные тестовые конфиги старых патчей.'
find /etc/nginx/sites-available -maxdepth 1 -type f -name 'hyper-host-site-v*-nginx-test-*.local.conf' -delete 2>/dev/null || true
find /etc/nginx/sites-enabled -maxdepth 1 \( -type f -o -type l \) -name '*hyper-host-site-v*-nginx-test-*.local.conf' -delete 2>/dev/null || true

log 'Пересобираю сайты и возвращаю HTTPS-блоки для найденных сертификатов.'
"$RECONCILE_BIN"
nginx -t

log 'Восстанавливаю FTP/FTPS через совместимый конфиг ProFTPD.'
FTP_LOG="/var/log/hyper-host-v1.2-final-ftp.log"
if ! "$CONTROL_BIN" ftp-fix >"$FTP_LOG" 2>&1; then
  cat "$FTP_LOG" >&2 || true
  fail "FTP/FTPS не восстановлен. Лог: $FTP_LOG"
fi
cat "$FTP_LOG"

log 'Повторно подключаю ранее выпущенные SSL-сертификаты после восстановления сервисов.'
SSL_RESTORE_JSON="$($CONTROL_BIN ssl-restore-existing 2>&1)" || {
  printf '%s\n' "$SSL_RESTORE_JSON" >&2
  fail 'Не удалось восстановить SSL-конфигурации.'
}
printf '%s\n' "$SSL_RESTORE_JSON"

nginx -t
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || fail 'Не удалось перезапустить Nginx.'

log 'Проверяю реальное создание и удаление сайта.'
TEST_DOMAIN="hyper-final-test-$(date +%s).local"
cleanup_test(){
  "$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null 2>&1 || true
  rm -rf "$SITES_DIR/$TEST_DOMAIN" 2>/dev/null || true
}
trap cleanup_test EXIT
"$CONTROL_BIN" add-site "$TEST_DOMAIN" '' '' >/tmp/hyper-host-final-site-test.log 2>&1 \
  || { cat /tmp/hyper-host-final-site-test.log >&2; fail 'Тест создания сайта не прошёл.'; }
nginx -t >/dev/null
curl -fsS --connect-timeout 3 --max-time 7 -H "Host: $TEST_DOMAIN" http://127.0.0.1/ >/dev/null \
  || fail 'Тестовый сайт не открылся локально.'
"$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null
trap - EXIT

log 'Проверяю FTP-порт и приветствие.'
ss -H -lntp 'sport = :21' 2>/dev/null | grep -q proftpd || fail 'ProFTPD не слушает порт 21.'
timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/21; IFS= read -r -t 3 line <&3; [[ "$line" == 220* ]]' \
  || fail 'FTP на порту 21 не отдаёт приветствие 220.'

SSL_AUDIT="$($CONTROL_BIN ssl-audit-json 2>/dev/null || echo '{"ok":false}')"
{
  echo 'HYPER-HOST v1.2 final recovery'
  echo "date=$(date -Is)"
  echo "backup=$BACKUP_DIR"
  echo "nginx_runtime=$BASE_DIR/runtime/nginx"
  echo "certificates=$(cert_count "$LE_CONFIG_DIR")"
  echo 'nginx=ok'
  echo 'site_create_delete=ok'
  echo 'ftp=ok'
  echo "ssl_audit=$SSL_AUDIT"
  echo
  "$HYPER_BIN" nginx doctor 2>&1 || true
  "$HYPER_BIN" ftp doctor 2>&1 || true
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' HYPER-HOST v1.2 — ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО\n'
printf '============================================================\n'
printf ' Nginx и создание сайтов: OK\n'
printf ' FTP/FTPS:                OK\n'
printf ' Найдено сертификатов:    %s\n' "$(cert_count "$LE_CONFIG_DIR")"
printf ' SSL-конфиги:              восстановлены\n'
printf ' Меню:                     sudo hyper-host-installer\n'
printf ' Отчёт:                    %s\n' "$REPORT"
printf ' Резервная копия:          %s\n' "$BACKUP_DIR"
printf '============================================================\n'
