#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
BASE_DIR="/opt/hyper-host"
CONF="/etc/hyper-host/hyper-host.conf"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
INSTALLER_BIN="/usr/local/sbin/hyper-host-installer"
RUNTIME_BIN="$BASE_DIR/bin/hyper-host-nginx-runtime"
BACKUP_DIR="$BASE_DIR/backups/v1.2-nginx-readonly-final-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v1.2-nginx-readonly-report.txt"
FTP_LOG="/var/log/hyper-host-v1.2-ftp-check.log"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

REQUIRED=(
  setup.sh
  install.sh
  scripts/hyper
  scripts/hhctl
  scripts/hyper_nginx_runtime.sh
  scripts/nginx_recover_v89.py
  scripts/nginx-reconcile-v89.sh
  scripts/proftpd_auth_sync.py
  scripts/hyper_ftp_proftpd_fix.sh
)
for file in "${REQUIRED[@]}"; do
  [[ -f "$ROOT_DIR/$file" ]] || fail "Не найден файл патча: $file"
done

bash -n "$ROOT_DIR/setup.sh"
bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/scripts/hyper"
bash -n "$ROOT_DIR/scripts/hhctl"
bash -n "$ROOT_DIR/scripts/hyper_nginx_runtime.sh"
bash -n "$ROOT_DIR/scripts/nginx-reconcile-v89.sh"
bash -n "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh"
python3 -m py_compile "$ROOT_DIR/scripts/nginx_recover_v89.py" "$ROOT_DIR/scripts/proftpd_auth_sync.py"

[[ -f "$CONF" ]] || fail "Панель не установлена: отсутствует $CONF"
# shellcheck disable=SC1090
source "$CONF"
SITES_DIR="${SITES_DIR:-/var/www/hyper-host-sites}"
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"

log "Создаю резервную копию: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$PROJECT_DIR/scripts" "$BASE_DIR/bin" "$BASE_DIR/logs" "$BASE_DIR/runtime"
for path in \
  "$PROJECT_DIR/setup.sh" "$PROJECT_DIR/install.sh" \
  "$PROJECT_DIR/scripts/hyper" "$PROJECT_DIR/scripts/hhctl" \
  "$PROJECT_DIR/scripts/hyper_nginx_runtime.sh" \
  "$CONTROL_BIN" "$HYPER_BIN" "$INSTALLER_BIN" "$RUNTIME_BIN" \
  /usr/local/sbin/hyper-host-nginx-reconcile /opt/hyper-host/nginx_recover_v89.py; do
  if [[ -e "$path" || -L "$path" ]]; then
    name="$(printf '%s' "$path" | sed 's#^/##;s#/#__#g')"
    cp -aL "$path" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
  fi
done
if [[ -d /etc/nginx ]]; then
  mkdir -p "$BACKUP_DIR/nginx-before"
  cp -a /etc/nginx/. "$BACKUP_DIR/nginx-before/" 2>/dev/null || true
fi
if [[ -d "$BASE_DIR/runtime/nginx" ]]; then
  cp -a "$BASE_DIR/runtime/nginx" "$BACKUP_DIR/nginx-runtime-before" 2>/dev/null || true
fi

log 'Обновляю файлы проекта и правильную структуру CLI.'
install -m0755 "$ROOT_DIR/setup.sh" "$PROJECT_DIR/setup.sh"
install -m0755 "$ROOT_DIR/install.sh" "$PROJECT_DIR/install.sh"
install -m0755 "$ROOT_DIR/scripts/hyper" "$PROJECT_DIR/scripts/hyper"
install -m0755 "$ROOT_DIR/scripts/hhctl" "$PROJECT_DIR/scripts/hhctl"
install -m0755 "$ROOT_DIR/scripts/hyper_nginx_runtime.sh" "$PROJECT_DIR/scripts/hyper_nginx_runtime.sh"
install -m0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$PROJECT_DIR/scripts/nginx_recover_v89.py"
install -m0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$PROJECT_DIR/scripts/nginx-reconcile-v89.sh"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$PROJECT_DIR/scripts/proftpd_auth_sync.py"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$PROJECT_DIR/scripts/hyper_ftp_proftpd_fix.sh"

install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install -m0755 "$ROOT_DIR/setup.sh" "$INSTALLER_BIN"
install -m0755 "$ROOT_DIR/scripts/hyper_nginx_runtime.sh" "$RUNTIME_BIN"
install -m0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" /opt/hyper-host/nginx_recover_v89.py
install -m0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" /usr/local/sbin/hyper-host-nginx-reconcile
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$BASE_DIR/bin/hyper_ftp_proftpd_fix.sh"

ln -sfn "$HYPER_BIN" /usr/bin/hyper 2>/dev/null || true
ln -sfn "$CONTROL_BIN" /usr/bin/hyper-host-ctl 2>/dev/null || true
ln -sfn "$INSTALLER_BIN" /usr/local/bin/hyper-host-installer 2>/dev/null || true
[[ "$(readlink -f "$HYPER_BIN")" != "$(readlink -f "$CONTROL_BIN")" ]] || fail 'Команда hyper снова ошибочно указывает на hyper-host-ctl.'

log 'Подключаю постоянный writable Nginx runtime.'
"$RUNTIME_BIN"

if command -v crontab >/dev/null 2>&1; then
  current="$(crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME' || true)"
  {
    printf '%s\n' "$current"
    printf '@reboot sleep 5; %s --boot >>%s/logs/nginx-runtime-boot.log 2>&1 # HYPER-HOST-NGINX-RUNTIME\n' "$RUNTIME_BIN" "$BASE_DIR"
  } | awk 'NF' | crontab -
fi

PROBE="/etc/nginx/.hyper-host-v1.2-write-probe-$$"
( : > "$PROBE" ) 2>/dev/null || fail '/etc/nginx остался read-only после подключения runtime.'
rm -f "$PROBE"

log 'Удаляю только временные тестовые Nginx-конфиги старых патчей.'
find /etc/nginx/sites-available -maxdepth 1 -type f \
  -name 'hyper-host-site-v*-nginx-test-*.local.conf' -delete 2>/dev/null || true
find /etc/nginx/sites-enabled -maxdepth 1 \( -type f -o -type l \) \
  -name '*hyper-host-site-v*-nginx-test-*.local.conf' -delete 2>/dev/null || true

log 'Пересобираю управляемые виртуальные хосты без записи в SQLite.'
/usr/local/sbin/hyper-host-nginx-reconcile
nginx -t

log 'Проверяю реальное создание, открытие и удаление сайта.'
TEST_DOMAIN="runtime-nginx-test-$(date +%s).local"
cleanup_test(){
  "$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null 2>&1 || true
  rm -f "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" \
        "/etc/nginx/sites-enabled/hyper-host-site-$TEST_DOMAIN.conf" \
        "/etc/nginx/sites-enabled/20-hyper-host-site-$TEST_DOMAIN.conf" 2>/dev/null || true
  rm -rf "$SITES_DIR/$TEST_DOMAIN" 2>/dev/null || true
}
trap cleanup_test EXIT
"$CONTROL_BIN" add-site "$TEST_DOMAIN" '' '' >/tmp/hyper-host-nginx-site-test.log 2>&1 \
  || { cat /tmp/hyper-host-nginx-site-test.log >&2; fail 'Тестовое создание сайта завершилось ошибкой.'; }
[[ -f "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" ]] \
  || fail 'Тестовый Nginx-конфиг не создан.'
[[ -L "/etc/nginx/sites-enabled/20-hyper-host-site-$TEST_DOMAIN.conf" ]] \
  || fail 'Тестовый Nginx-конфиг не включён.'
nginx -t >/dev/null
curl -fsS --connect-timeout 3 --max-time 7 -H "Host: $TEST_DOMAIN" http://127.0.0.1/ >/dev/null \
  || fail 'Nginx не отдал тестовый сайт локально.'
"$CONTROL_BIN" delete-site "$TEST_DOMAIN" --delete-files >/dev/null
[[ ! -e "/etc/nginx/sites-available/hyper-host-site-$TEST_DOMAIN.conf" ]] \
  || fail 'Тестовый Nginx-конфиг не удалился.'
trap - EXIT

log 'Проверяю сохранение FTP/FTPS исправлений.'
if "$CONTROL_BIN" ftp-fix >"$FTP_LOG" 2>&1; then
  if command -v proftpd >/dev/null 2>&1; then
    ss -H -lntp 'sport = :21' 2>/dev/null | grep -q proftpd \
      || fail "ProFTPD не слушает порт 21. Лог: $FTP_LOG"
    timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/21; IFS= read -r -t 3 line <&3; [[ "$line" == 220* ]]' \
      || fail 'FTP на 127.0.0.1:21 не отдаёт приветствие 220.'
  fi
else
  cat "$FTP_LOG" >&2 || true
  fail 'Не удалось сохранить/восстановить FTP после Nginx-патча.'
fi

nginx -t
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true

{
  echo 'HYPER-HOST v1.2 — Nginx read-only final fix'
  echo "Date: $(date -Is)"
  echo "Runtime: $BASE_DIR/runtime/nginx"
  echo "Runtime helper: $RUNTIME_BIN"
  echo "Runtime marker active: $([[ "$BASE_DIR/runtime/nginx/.hyper-host-nginx-runtime" -ef /etc/nginx/.hyper-host-nginx-runtime ]] && echo yes || echo no)"
  echo 'Nginx writable: yes'
  echo 'Nginx syntax: ok'
  echo 'Create/open/delete site test: ok'
  echo 'FTP/FTPS restore: ok'
  echo 'SSL writable dirs: /opt/hyper-host/letsencrypt /opt/hyper-host/certbot-work /opt/hyper-host/certbot-logs'
  echo "Backup: $BACKUP_DIR"
  echo
  "$HYPER_BIN" nginx doctor 2>&1 || true
  "$HYPER_BIN" ftp doctor 2>&1 || true
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' HYPER-HOST v1.2 — NGINX / FTP / SSL ГОТОВЫ\n'
printf '============================================================\n'
printf ' Nginx runtime: %s\n' "$BASE_DIR/runtime/nginx"
printf ' Создание сайтов: проверено\n'
printf ' FTP/FTPS:       проверено\n'
printf ' SSL/ACME:       сохранено через /opt/hyper-host\n'
printf ' Меню:           sudo hyper-host-installer\n'
printf ' Nginx fix:      sudo hyper nginx fix\n'
printf ' Nginx doctor:   sudo hyper nginx doctor\n'
printf ' Отчёт:          %s\n' "$REPORT"
printf ' Backup:          %s\n' "$BACKUP_DIR"
printf '============================================================\n'
