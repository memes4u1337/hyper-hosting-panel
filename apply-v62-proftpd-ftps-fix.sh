#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=/opt/hyper-host
CONTROL_BIN=/usr/local/sbin/hyper-host-ctl
AUTH_BUILDER="$BASE_DIR/bin/proftpd_auth_sync.py"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
AUTH_TEXT="$BASE_DIR/data/vsftpd_virtual_users.txt"
USER_CONF_DIR="$BASE_DIR/ftp/user_conf"
PROFTPD_DIR="$BASE_DIR/proftpd"
BACKUP_DIR="$BASE_DIR/backups/v62-proftpd-ftps-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v62-proftpd-report.txt
PROJECT='HYPER-HOST'
CYAN='\033[1;36m'
RESET='\033[0m'
ROLLBACK_NEEDED=1
TEST_USER="hhv62$(date +%s)"
TEST_PASS="V62$(openssl rand -hex 16)"
TEST_REMOTE="v62-gnutls-data-$(date +%s).bin"
TEST_SRC="$(mktemp /tmp/hhv62-src.XXXXXX)"
TEST_DST="$(mktemp /tmp/hhv62-dst.XXXXXX)"
LFTP_LOG="$(mktemp /tmp/hhv62-lftp.XXXXXX)"

log() { printf '[%b%s%b] %s\n' "$CYAN" "$PROJECT" "$RESET" "$*"; }
fail() { printf '[%b%s%b] ERROR: %s\n' "$CYAN" "$PROJECT" "$RESET" "$*" >&2; exit 1; }
file_sha() { [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || true; }
admin_hash() {
  [[ -f "$DB_PATH" ]] || return 0
  python3 - "$DB_PATH" <<'PY' 2>/dev/null || true
import sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1])
    cols = {row[1] for row in con.execute("PRAGMA table_info(users)")}
    col = next((name for name in ("password_hash", "password", "pass_hash") if name in cols), None)
    if col:
        row = con.execute(f"SELECT {col} FROM users WHERE username=? LIMIT 1", ("admin",)).fetchone()
        print("" if not row or row[0] is None else str(row[0]), end="")
finally:
    try: con.close()
    except Exception: pass
PY
}

cleanup_test_user() {
  if [[ -x "$CONTROL_BIN" ]]; then
    "$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null 2>&1 || true
  fi
  rm -f "$TEST_SRC" "$TEST_DST" "$LFTP_LOG" /tmp/hhv62-deleted-login.log >/dev/null 2>&1 || true
}

restore_previous_runtime() {
  [[ -d "$BACKUP_DIR" ]] || return 0
  printf '[%b%s%b] Установка не завершена, возвращаю прежний FTP runtime.\n' "$CYAN" "$PROJECT" "$RESET" >&2
  if [[ -f "$BACKUP_DIR/hyper-host-ctl.bak" ]]; then
    install -m0755 "$BACKUP_DIR/hyper-host-ctl.bak" "$CONTROL_BIN" || true
  fi
  if [[ -f "$BACKUP_DIR/proftpd_auth_sync.py.bak" ]]; then
    install -m0755 "$BACKUP_DIR/proftpd_auth_sync.py.bak" "$AUTH_BUILDER" || true
  else
    rm -f "$AUTH_BUILDER" >/dev/null 2>&1 || true
  fi
  systemctl stop hyper-host-ftp.service >/dev/null 2>&1 || true
  pkill -x proftpd >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  "$CONTROL_BIN" ftp-fix >/dev/null 2>&1 || true
}

on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM
  cleanup_test_user
  if [[ "$rc" -ne 0 && "$ROLLBACK_NEEDED" == 1 ]]; then
    restore_previous_runtime
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$ROOT_DIR/scripts/proftpd_auth_sync.py" ]] || fail 'Не найден scripts/proftpd_auth_sync.py'
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса hhctl'
python3 -m py_compile "$ROOT_DIR/scripts/proftpd_auth_sync.py" || fail 'Ошибка синтаксиса генератора ProFTPD auth'
command -v openssl >/dev/null 2>&1 || fail 'Не найден openssl'

ADMIN_BEFORE="$(admin_hash)"
CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/bin"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$AUTH_BUILDER" ]] && cp -a "$AUTH_BUILDER" "$BACKUP_DIR/proftpd_auth_sync.py.bak" || true
[[ -f "$AUTH_TEXT" ]] && cp -a "$AUTH_TEXT" "$BACKUP_DIR/ftp-auth.txt.bak" || true
[[ -d "$USER_CONF_DIR" ]] && cp -a "$USER_CONF_DIR" "$BACKUP_DIR/user_conf.bak" || true
[[ -d "$PROFTPD_DIR" ]] && cp -a "$PROFTPD_DIR" "$BACKUP_DIR/proftpd.bak" || true
[[ -f /run/systemd/system/hyper-host-ftp.service ]] && cp -a /run/systemd/system/hyper-host-ftp.service "$BACKUP_DIR/hyper-host-ftp.service.bak" || true

log "Резервная копия: $BACKUP_DIR"
log 'Меняю только FTP/FTPS backend на ProFTPD. Nginx, SQL, сайты и пароль admin не изменяются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$AUTH_BUILDER"

"$CONTROL_BIN" ftp-fix

command -v proftpd >/dev/null 2>&1 || fail 'ProFTPD не установлен'
command -v lftp >/dev/null 2>&1 || fail 'lftp не установлен'
lftp --version 2>&1 | grep -qi 'GnuTLS' || fail 'lftp установлен без GnuTLS — проверка FileZilla-совместимости невозможна'
proftpd -t -c "$PROFTPD_DIR/proftpd.conf" || fail 'Конфиг ProFTPD не прошёл проверку'
systemctl is-active --quiet hyper-host-ftp.service || fail 'hyper-host-ftp.service не активен'
crontab -l 2>/dev/null | grep -q 'HYPER-HOST-FTP-RUNTIME' || fail 'Не создан автозапуск FTP после reboot'
ss -H -lntp 'sport = :21' | grep -q proftpd || fail 'TCP 21 слушает не ProFTPD'

VERSION="$(proftpd -v 2>&1 | head -n1 | sed 's/^ProFTPD Version //')"
[[ -n "$VERSION" ]] || fail 'Не удалось определить версию ProFTPD'

"$CONTROL_BIN" create-ftp "$TEST_USER" "$TEST_PASS" files >/dev/null
printf 'HYPER-HOST v62 ProFTPD GnuTLS data-channel test\n%.0s' {1..4096} > "$TEST_SRC"

log 'Проверяю explicit FTPS через lftp/GnuTLS: MLSD/LIST, upload, download и корректное закрытие data-channel.'
if ! timeout 90 lftp -u "$TEST_USER,$TEST_PASS" 'ftp://127.0.0.1:21' >"$LFTP_LOG" 2>&1 <<LFTP
set cmd:fail-exit true
set ssl:verify-certificate no
set ftp:ssl-force true
set ftp:ssl-protect-data true
set ftp:ssl-protect-list true
set ftp:ssl-auth TLS
set ftp:passive-mode true
set ftp:prefer-epsv false
set ftp:use-mlsd true
set ftp:fix-pasv-address true
set net:timeout 15
set net:max-retries 1
cls -1
cls -1
cls -1
put $TEST_SRC -o $TEST_REMOTE
get $TEST_REMOTE -o $TEST_DST
cls -1
rm $TEST_REMOTE
cls -1
bye
LFTP
then
  cat "$LFTP_LOG" >&2 || true
  fail 'Проверка FTPS через lftp/GnuTLS не прошла'
fi
cmp -s "$TEST_SRC" "$TEST_DST" || fail 'Скачанный через FTPS файл отличается от загруженного'
if grep -Eqi 'GnuTLS error|non-properly terminated|Fatal error|ECONNABORTED' "$LFTP_LOG"; then
  cat "$LFTP_LOG" >&2 || true
  fail 'В логе lftp осталась ошибка закрытия TLS data-channel'
fi

# Проверяем TLS 1.2 на управляющем соединении.
if ! timeout 15 openssl s_client -starttls ftp -connect 127.0.0.1:21 -tls1_2 -brief </dev/null 2>&1 | grep -q 'Protocol version: TLSv1.2'; then
  fail 'ProFTPD не подтвердил TLS 1.2 на управляющем соединении'
fi

"$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null
sleep 1
if timeout 25 lftp -u "$TEST_USER,$TEST_PASS" 'ftp://127.0.0.1:21' >/tmp/hhv62-deleted-login.log 2>&1 <<'LFTPDELETE'
set cmd:fail-exit true
set ssl:verify-certificate no
set ftp:ssl-force true
set ftp:ssl-protect-data true
set ftp:ssl-protect-list true
set ftp:ssl-auth TLS
set ftp:passive-mode true
set ftp:prefer-epsv false
set ftp:use-mlsd true
set ftp:fix-pasv-address true
set net:timeout 8
set net:max-retries 1
cls -1
bye
LFTPDELETE
then
  cat /tmp/hhv62-deleted-login.log >&2 || true
  fail 'Удалённый FTP-аккаунт всё ещё может войти'
fi
rm -f /tmp/hhv62-deleted-login.log

ADMIN_AFTER="$(admin_hash)"
CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Хеш пароля admin изменился'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл реквизитов администратора изменился'

DOCTOR_JSON="$($CONTROL_BIN ftp-doctor-json 2>/dev/null || true)"
{
  echo 'HYPER-HOST v62 ProFTPD FTPS fix'
  echo "ProFTPD: $VERSION"
  echo 'FTPS: explicit TLS 1.2, TCP 21'
  echo 'TLS data session reuse: not required'
  echo 'PASV: 40000-40100, address 90.189.208.25'
  echo 'GnuTLS MLSD/LIST: passed 5 cycles'
  echo 'GnuTLS upload/download: passed'
  echo 'Deleted-user login: rejected'
  echo 'Admin password: unchanged'
  echo "Doctor: $DOCTOR_JSON"
  echo
  echo 'lftp output:'
  cat "$LFTP_LOG"
} > "$REPORT"
chmod 0600 "$REPORT"

ROLLBACK_NEEDED=0
cleanup_test_user

printf '\n============================================================\n'
printf ' %b%s%b — ProFTPD FTPS установлен\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' Движок:             ProFTPD %s\n' "$VERSION"
printf ' FTPS:               explicit TLS 1.2, TCP 21\n'
printf ' PASV:               40000-40100 → 90.189.208.25\n'
printf ' GnuTLS MLSD/LIST:   OK\n'
printf ' Upload/download:    OK\n'
printf ' Create/delete user: OK\n'
printf ' Admin password:     НЕ ИЗМЕНЁН\n'
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'
