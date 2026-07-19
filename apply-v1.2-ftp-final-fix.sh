#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
BASE_DIR="/opt/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
INSTALLER_BIN="/usr/local/sbin/hyper-host-installer"
BACKUP_DIR="$BASE_DIR/backups/v1.2-ftp-final-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v1.2-ftp-final-report.txt"
FTP_LOG="/var/log/hyper-host-v1.2-ftp-final-install.log"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

REQUIRED=(
  setup.sh
  install.sh
  scripts/hyper
  scripts/hhctl
  scripts/proftpd_auth_sync.py
  scripts/hyper_ftp_proftpd_fix.sh
)

for file in "${REQUIRED[@]}"; do
  [[ -f "$ROOT_DIR/$file" ]] || fail "Не найден файл: $file"
done

bash -n "$ROOT_DIR/setup.sh"
bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/scripts/hyper"
bash -n "$ROOT_DIR/scripts/hhctl"
bash -n "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh"
python3 -m py_compile "$ROOT_DIR/scripts/proftpd_auth_sync.py"

mkdir -p "$BACKUP_DIR" "$PROJECT_DIR/scripts" "$BASE_DIR/bin" /var/log
for path in \
  "$PROJECT_DIR/setup.sh" \
  "$PROJECT_DIR/install.sh" \
  "$PROJECT_DIR/scripts/hyper" \
  "$PROJECT_DIR/scripts/hhctl" \
  "$PROJECT_DIR/scripts/proftpd_auth_sync.py" \
  "$PROJECT_DIR/scripts/hyper_ftp_proftpd_fix.sh" \
  "$CONTROL_BIN" "$HYPER_BIN" "$INSTALLER_BIN"; do
  if [[ -e "$path" || -L "$path" ]]; then
    name="$(echo "$path" | sed 's#^/##;s#/#__#g')"
    cp -aL "$path" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
  fi
done

log "Резервная копия: $BACKUP_DIR"
log 'Устанавливаю правильную структуру CLI: hyper отдельно, hyper-host-ctl отдельно.'

install -m0755 "$ROOT_DIR/setup.sh" "$PROJECT_DIR/setup.sh"
install -m0755 "$ROOT_DIR/install.sh" "$PROJECT_DIR/install.sh"
install -m0755 "$ROOT_DIR/scripts/hyper" "$PROJECT_DIR/scripts/hyper"
install -m0755 "$ROOT_DIR/scripts/hhctl" "$PROJECT_DIR/scripts/hhctl"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$PROJECT_DIR/scripts/proftpd_auth_sync.py"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$PROJECT_DIR/scripts/hyper_ftp_proftpd_fix.sh"

install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
rm -f "$HYPER_BIN"
install -m0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$BASE_DIR/bin/hyper_ftp_proftpd_fix.sh"
install -m0755 "$ROOT_DIR/setup.sh" "$INSTALLER_BIN"

ln -sfn "$CONTROL_BIN" /usr/local/bin/hyper-host-ctl
ln -sfn "$INSTALLER_BIN" /usr/local/bin/hyper-host-installer
ln -sfn "$HYPER_BIN" /usr/bin/hyper 2>/dev/null || true
ln -sfn "$CONTROL_BIN" /usr/bin/hyper-host-ctl 2>/dev/null || true

[[ -x "$CONTROL_BIN" ]] || fail "Не установлен $CONTROL_BIN"
[[ -x "$HYPER_BIN" ]] || fail "Не установлен $HYPER_BIN"
grep -q 'cmd_ftp()' "$HYPER_BIN" || fail 'В /usr/local/bin/hyper установлен неправильный файл'
if [[ "$(readlink -f "$HYPER_BIN")" == "$(readlink -f "$CONTROL_BIN")" ]]; then
  fail 'hyper ошибочно указывает на hyper-host-ctl'
fi

log 'Восстанавливаю FTP/FTPS напрямую через hyper-host-ctl...'
if ! "$CONTROL_BIN" ftp-fix 2>&1 | tee "$FTP_LOG"; then
  fail "FTP-восстановление завершилось ошибкой. Лог: $FTP_LOG"
fi

log 'Проверяю правильную работу команды hyper...'
"$HYPER_BIN" help >/dev/null
"$HYPER_BIN" ftp doctor > "$REPORT" 2>&1 || true

command -v proftpd >/dev/null 2>&1 || fail 'ProFTPD не установлен'
ss -H -lntp 'sport = :21' 2>/dev/null | grep -q proftpd || {
  systemctl --no-pager --full status hyper-host-proftpd-lan.service 2>/dev/null || true
  tail -n 120 "$FTP_LOG" >&2 || true
  fail 'ProFTPD не слушает TCP-порт 21'
}

timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/21; IFS= read -r -t 3 line <&3; [[ "$line" == 220* ]]' \
  || fail 'FTP на 127.0.0.1:21 не отдаёт приветствие 220'

if command -v openssl >/dev/null 2>&1; then
  timeout 12 openssl s_client -starttls ftp -connect 127.0.0.1:21 -tls1_2 </dev/null > /tmp/hyper-host-ftps-check.log 2>&1 \
    || fail 'Explicit FTPS на порту 21 не отвечает'
  grep -Eq 'Protocol *: TLSv1\.2|Protocol version: TLSv1\.2|Cipher is ' /tmp/hyper-host-ftps-check.log \
    || fail 'TLS-соединение FTP не подтвердилось'
fi

nginx -t

{
  echo 'HYPER-HOST v1.2 — FTP final fix'
  echo "Date: $(date -Is)"
  echo "hyper: $(readlink -f "$HYPER_BIN")"
  echo "hyper-host-ctl: $(readlink -f "$CONTROL_BIN")"
  echo "ProFTPD: $(proftpd -v 2>&1 | head -n1)"
  echo 'Port 21: listening'
  echo 'Explicit FTPS: responding'
  echo 'Passive ports: 40000-40100'
  echo "Backup: $BACKUP_DIR"
  echo
  "$HYPER_BIN" ftp doctor 2>&1 || true
} > "$REPORT"
chmod 0600 "$REPORT"

printf '\n============================================================\n'
printf ' HYPER-HOST v1.2 — FTP ИСПРАВЛЕН\n'
printf '============================================================\n'
printf ' Меню:       sudo hyper-host-installer\n'
printf ' FTP fix:    sudo hyper ftp fix\n'
printf ' FTP doctor: sudo hyper ftp doctor\n'
printf ' FileZilla:  FTP / порт 21 / Passive / Explicit TLS\n'
printf ' PASV:       TCP 40000-40100\n'
printf ' Отчёт:      %s\n' "$REPORT"
printf ' Backup:     %s\n' "$BACKUP_DIR"
printf '============================================================\n'
