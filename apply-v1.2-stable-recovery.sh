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
BACKUP_DIR="$BASE_DIR/backups/v1.2-stable-recovery-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v1.2-stable-recovery-report.txt"

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

same_path(){
  local left="$1" right="$2" left_real right_real
  left_real="$(readlink -f "$left" 2>/dev/null || printf '%s' "$left")"
  right_real="$(readlink -f "$right" 2>/dev/null || printf '%s' "$right")"
  [[ "$left_real" == "$right_real" ]]
}

install_if_different(){
  local mode="$1" src="$2" dst="$3"
  mkdir -p "$(dirname "$dst")"
  if same_path "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
    return 0
  fi
  install -m"$mode" "$src" "$dst"
}


cert_count(){
  local root="${1:-$LE_CONFIG_DIR}"
  [[ -d "$root/live" ]] || { echo 0; return; }
  find -L "$root/live" -mindepth 2 -maxdepth 2 -type f -name fullchain.pem 2>/dev/null | wc -l | tr -d ' '
}

cert_expiry_epoch(){
  local cert="$1" end
  end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
  [[ -n "$end" ]] || { echo 0; return; }
  date -d "$end" +%s 2>/dev/null || echo 0
}

lineage_valid(){
  local root="$1" lineage="$2"
  [[ -s "$root/live/$lineage/fullchain.pem" && -s "$root/live/$lineage/privkey.pem" ]] || return 1
  openssl x509 -in "$root/live/$lineage/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || return 1
  openssl pkey -in "$root/live/$lineage/privkey.pem" -noout >/dev/null 2>&1 || return 1
}

merge_certbot_state(){
  local src="$1" lineage src_epoch dst_epoch
  [[ -d "$src/live" && -d "$src/archive" ]] || return 0
  same_path "$src" "$LE_CONFIG_DIR" && return 0

  while IFS= read -r -d '' lineage_dir; do
    lineage="$(basename "$lineage_dir")"
    lineage_valid "$src" "$lineage" || continue
    src_epoch="$(cert_expiry_epoch "$src/live/$lineage/fullchain.pem")"
    dst_epoch=0
    if lineage_valid "$LE_CONFIG_DIR" "$lineage"; then
      dst_epoch="$(cert_expiry_epoch "$LE_CONFIG_DIR/live/$lineage/fullchain.pem")"
    fi
    (( src_epoch > dst_epoch )) || continue

    log "Возвращаю SSL lineage: $lineage из $src"
    rm -rf "$LE_CONFIG_DIR/live/$lineage" "$LE_CONFIG_DIR/archive/$lineage"
    mkdir -p "$LE_CONFIG_DIR/live" "$LE_CONFIG_DIR/archive" "$LE_CONFIG_DIR/renewal"
    cp -a "$src/archive/$lineage" "$LE_CONFIG_DIR/archive/$lineage"
    cp -a "$src/live/$lineage" "$LE_CONFIG_DIR/live/$lineage"
    if [[ -f "$src/renewal/$lineage.conf" ]]; then
      cp -a "$src/renewal/$lineage.conf" "$LE_CONFIG_DIR/renewal/$lineage.conf"
      sed -i -E \
        "s#^archive_dir[[:space:]]*=.*#archive_dir = $LE_CONFIG_DIR/archive/$lineage#; \
         s#^cert[[:space:]]*=.*#cert = $LE_CONFIG_DIR/live/$lineage/cert.pem#; \
         s#^privkey[[:space:]]*=.*#privkey = $LE_CONFIG_DIR/live/$lineage/privkey.pem#; \
         s#^chain[[:space:]]*=.*#chain = $LE_CONFIG_DIR/live/$lineage/chain.pem#; \
         s#^fullchain[[:space:]]*=.*#fullchain = $LE_CONFIG_DIR/live/$lineage/fullchain.pem#" \
        "$LE_CONFIG_DIR/renewal/$lineage.conf" 2>/dev/null || true
    fi
  done < <(find -L "$src/live" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

recover_certificates(){
  mkdir -p "$LE_CONFIG_DIR" "$LE_WORK_DIR" "$LE_LOGS_DIR" "$ACME_WEBROOT/.well-known/acme-challenge"
  chmod 0700 "$LE_CONFIG_DIR" "$LE_WORK_DIR" 2>/dev/null || true
  chmod 0750 "$LE_LOGS_DIR" 2>/dev/null || true
  rm -f "$LE_CONFIG_DIR/.certbot.lock" "$LE_WORK_DIR/.certbot.lock" "$LE_LOGS_DIR/.certbot.lock" 2>/dev/null || true

  # Не прекращаем восстановление после первого найденного сертификата: старые
  # резервные копии могут содержать SSL других сайтов, потерянные позднее.
  local -a roots=("/etc/letsencrypt")
  local candidate parent
  while IFS= read -r -d '' candidate; do
    parent="$(dirname "$candidate")"
    roots+=("$parent")
  done < <(find "$BASE_DIR/backups" -type d -name live -print0 2>/dev/null)

  # Сначала старые копии, затем более свежие; для каждого lineage остаётся
  # сертификат с наиболее поздней датой окончания.
  for candidate in "${roots[@]}"; do
    merge_certbot_state "$candidate" || true
  done

  if (( $(cert_count "$LE_CONFIG_DIR") == 0 )); then
    warn 'Ранее выпущенные сертификаты не найдены ни в рабочем каталоге, ни в резервных копиях.'
  else
    log "Доступных действующих SSL lineage: $(cert_count "$LE_CONFIG_DIR")"
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
if same_path "$ROOT_DIR" "$PROJECT_DIR"; then
  log 'Патч запущен из каталога проекта — копирование файлов самих в себя пропущено.'
  chmod 0755 "$PROJECT_DIR/setup.sh" "$PROJECT_DIR/install.sh" "$PROJECT_DIR/scripts/"* 2>/dev/null || true
else
  mkdir -p "$PROJECT_DIR/scripts"
  for file in setup.sh install.sh; do
    install_if_different 0755 "$ROOT_DIR/$file" "$PROJECT_DIR/$file"
  done
  for file in hhctl hyper hyper_nginx_runtime.sh nginx-reconcile-v89.sh nginx_recover_v89.py hyper_ftp_proftpd_fix.sh proftpd_auth_sync.py ssl_truth.py; do
    install_if_different 0755 "$ROOT_DIR/scripts/$file" "$PROJECT_DIR/scripts/$file"
  done
fi

install_if_different 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install_if_different 0755 "$ROOT_DIR/setup.sh" "$INSTALLER_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper_nginx_runtime.sh" "$RUNTIME_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$RECONCILE_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$BASE_DIR/nginx_recover_v89.py"
install_if_different 0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
install_if_different 0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$FTP_FIX_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$SSL_TRUTH_BIN"

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

log 'Восстанавливаю FTP/FTPS через совместимый конфиг ProFTPD без несовместимых директив.'
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
  echo 'HYPER-HOST v1.2 stable recovery'
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
