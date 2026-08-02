#!/usr/bin/env bash
set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/opt/hyper-host/backups/v78-dpkg-systemd-${STAMP}"
LOG_FILE="/root/hyper-host-v78-recovery-${STAMP}.log"
POLICY_FILE=/usr/sbin/policy-rc.d
POLICY_BACKUP="$BACKUP_DIR/policy-rc.d.bak"
DSI_FILE=/usr/bin/deb-systemd-invoke
DSI_BACKUP="$BACKUP_DIR/deb-systemd-invoke.bak"
POLICY_REPLACED=0
DSI_REPLACED=0

log()  { printf '[HYPER-HOST v78] %s\n' "$*"; }
warn() { printf '[HYPER-HOST v78 WARNING] %s\n' "$*" >&2; }
fail() { printf '[HYPER-HOST v78 ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Запусти от root: sudo bash apply-v78-dpkg-systemd-recovery.sh'
mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

restore_policy() {
  if [[ "$POLICY_REPLACED" -eq 1 ]]; then
    if [[ -f "$POLICY_BACKUP" ]]; then
      cp -a "$POLICY_BACKUP" "$POLICY_FILE"
    else
      rm -f "$POLICY_FILE"
    fi
    POLICY_REPLACED=0
  fi
}

restore_dsi() {
  if [[ "$DSI_REPLACED" -eq 1 ]]; then
    cp -a "$DSI_BACKUP" "$DSI_FILE"
    DSI_REPLACED=0
  fi
}

cleanup() {
  local rc=$?
  restore_dsi || true
  restore_policy || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

wait_for_dpkg() {
  local waited=0
  while pgrep -x apt >/dev/null 2>&1 \
     || pgrep -x apt-get >/dev/null 2>&1 \
     || pgrep -x dpkg >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    if [[ "$waited" -eq 0 ]]; then
      log 'Жду освобождения apt/dpkg...'
    fi
    sleep 5
    waited=$((waited + 5))
    [[ "$waited" -lt 180 ]] || fail 'apt/dpkg занят больше 3 минут. Не удаляй lock-файлы вручную; проверь процессы ps aux | grep -E "apt|dpkg".'
  done
}

install_policy_block() {
  if [[ -e "$POLICY_FILE" ]]; then
    cp -a "$POLICY_FILE" "$POLICY_BACKUP"
  fi
  cat > "$POLICY_FILE" <<'EOF'
#!/bin/sh
# HYPER-HOST v78: временно не запускаем сервисы из package postinst.
exit 101
EOF
  chmod 0755 "$POLICY_FILE"
  POLICY_REPLACED=1
}

install_dsi_stub() {
  [[ -f "$DSI_FILE" ]] || fail "$DSI_FILE отсутствует — невозможно сделать безопасный fallback"
  cp -a "$DSI_FILE" "$DSI_BACKUP"
  cat > "$DSI_FILE" <<'EOF'
#!/bin/sh
# HYPER-HOST v78: временный fallback только на время dpkg --configure -a.
exit 0
EOF
  chmod 0755 "$DSI_FILE"
  DSI_REPLACED=1
}

service_enable_start() {
  local unit="$1"
  systemctl enable "$unit" >/dev/null 2>&1 || true
  systemctl restart "$unit" >/dev/null 2>&1 || systemctl start "$unit" >/dev/null 2>&1 || true
}

log "Лог восстановления: $LOG_FILE"
log "Резервная копия: $BACKUP_DIR"
log 'Диагностика systemd и пакетного менеджера'
printf 'PID 1: '; ps -p 1 -o comm= || true
printf 'systemctl: '; command -v systemctl || true
[[ -e /usr/bin/systemctl ]] && ls -l /usr/bin/systemctl || true
/usr/bin/systemctl --version 2>/dev/null | head -n 2 || warn 'systemctl сейчас не запускается; восстановлю пакет после разблокировки dpkg'
dpkg --audit || true

wait_for_dpkg
install_policy_block

log 'Завершаю незаконченные настройки пакетов без автоматического старта сервисов'
if ! dpkg --configure -a; then
  warn 'Стандартный проход dpkg не завершился. Включаю временный безопасный обход deb-systemd-invoke.'
  install_dsi_stub
  dpkg --configure -a
  restore_dsi
fi

log 'Исправляю зависимости пакетов'
apt-get -f install -y

# Возвращаем штатную политику до переустановки системных компонентов.
restore_policy

log 'Обновляю индекс и переустанавливаю systemd/init-system-helpers'
apt-get update --allow-releaseinfo-change
apt-get install --reinstall -y systemd systemd-sysv init-system-helpers

command -v systemctl >/dev/null 2>&1 || fail 'systemctl не восстановлен'
systemctl --version >/dev/null 2>&1 || fail 'systemctl найден, но не запускается'
[[ "$(ps -p 1 -o comm= | tr -d '[:space:]')" == "systemd" ]] || warn 'PID 1 не systemd. Сервисы будут проверены, но после работ рекомендуется перезагрузка.'

log 'Перечитываю systemd и сбрасываю старые ошибки'
systemctl daemon-reload
systemctl reset-failed || true

# Дистрибутивный ProFTPD не должен занимать порт 21, когда используется runtime HYPER-HOST.
if systemctl list-unit-files proftpd.service --no-legend 2>/dev/null | grep -q '^proftpd.service'; then
  systemctl disable --now proftpd.service >/dev/null 2>&1 || true
fi

log 'Восстанавливаю основные службы панели'
service_enable_start nginx.service
service_enable_start mariadb.service
service_enable_start cron.service
service_enable_start ssh.service
service_enable_start bind9.service

while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  service_enable_start "$unit"
done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')

if [[ -x /usr/local/sbin/hyper-host-ctl ]]; then
  log 'Запускаю штатное восстановление HYPER-HOST'
  /usr/local/sbin/hyper-host-ctl repair >/tmp/hyper-host-v78-repair.log 2>&1 || warn 'Команда repair завершилась с предупреждением; лог: /tmp/hyper-host-v78-repair.log'
  /usr/local/sbin/hyper-host-ctl ftp-fix >/tmp/hyper-host-v78-ftp-fix.log 2>&1 || warn 'Команда ftp-fix завершилась с предупреждением; лог: /tmp/hyper-host-v78-ftp-fix.log'
fi

PATCH_FILE=''
for candidate in \
  "$ROOT_DIR/apply-v77-final-ui-ssl-safe.sh" \
  "$ROOT_DIR/hyper-hosting-panel-v77-patch-only/apply-v77-final-ui-ssl-safe.sh"; do
  if [[ -f "$candidate" ]]; then
    PATCH_FILE="$candidate"
    break
  fi
done
if [[ -n "$PATCH_FILE" ]]; then
  log "Устанавливаю файловый патч интерфейса/SSL: $PATCH_FILE"
  bash "$PATCH_FILE"
else
  warn 'apply-v77-final-ui-ssl-safe.sh рядом не найден — пакетная система восстановлена, но файловый патч v77 не запускался.'
fi

log 'Финальная проверка Nginx и сервисов'
nginx -t
systemctl reload nginx.service >/dev/null 2>&1 || systemctl restart nginx.service
systemctl is-active --quiet nginx.service || fail 'Nginx не active'

PHP_ACTIVE="$(systemctl list-units --type=service --state=running 'php*-fpm.service' --no-legend 2>/dev/null | awk 'NR==1{print $1}')"
[[ -n "$PHP_ACTIVE" ]] || fail 'Ни один PHP-FPM сервис не запущен'
systemctl is-active --quiet mariadb.service || fail 'MariaDB не active'

HTTP_CODE="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' http://127.0.0.1/ || true)"
[[ "$HTTP_CODE" != '000' ]] || fail 'Nginx слушает, но локально не отдаёт HTTP-ответ'

printf '\n============================================================\n'
printf ' HYPER-HOST v78 — ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО\n'
printf '============================================================\n'
printf ' dpkg:       OK\n'
printf ' systemctl: OK\n'
printf ' nginx:     %s\n' "$(systemctl is-active nginx.service 2>/dev/null || true)"
printf ' mariadb:   %s\n' "$(systemctl is-active mariadb.service 2>/dev/null || true)"
printf ' php-fpm:   %s\n' "$PHP_ACTIVE"
printf ' local HTTP: %s\n' "$HTTP_CODE"
printf ' log:        %s\n' "$LOG_FILE"
printf ' backup:     %s\n' "$BACKUP_DIR"
printf '============================================================\n'

trap - EXIT INT TERM
restore_dsi
restore_policy
