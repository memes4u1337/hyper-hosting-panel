#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=/opt/hyper-host
CONTROL_BIN=/usr/local/sbin/hyper-host-ctl
AUTH_BUILDER="$BASE_DIR/bin/proftpd_auth_sync.py"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
PROFTPD_DIR="$BASE_DIR/proftpd"
BACKUP_DIR="$BASE_DIR/backups/v66-proftpd-lan-only-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v66-lan-ftp-report.txt
LAN_IP=192.168.0.179
PROJECT=HYPER-HOST
CYAN='\033[1;36m'; RESET='\033[0m'
ROLLBACK_NEEDED=1
TEST_USER="hhv66$(date +%s)"
TEST_PASS="V66$(openssl rand -hex 16)"
TEST_DIR="$(mktemp -d /tmp/hhv66-lan.XXXXXX)"
SRC="$TEST_DIR/source.bin"
DST="$TEST_DIR/downloaded.bin"
PLAIN_LOG="$TEST_DIR/plain.log"
TLS_LOG="$TEST_DIR/tls.log"

log(){ printf '[%b%s%b] %s\n' "$CYAN" "$PROJECT" "$RESET" "$*"; }
fail(){ printf '[%b%s%b] ERROR: %s\n' "$CYAN" "$PROJECT" "$RESET" "$*" >&2; exit 1; }
file_sha(){ [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || true; }
admin_hash(){
  [[ -f "$DB_PATH" ]] || return 0
  python3 - "$DB_PATH" <<'PY' 2>/dev/null || true
import sqlite3,sys
con=None
try:
    con=sqlite3.connect(sys.argv[1])
    cols={r[1] for r in con.execute('PRAGMA table_info(users)')}
    col=next((x for x in ('password_hash','password','pass_hash') if x in cols),None)
    if col:
        row=con.execute(f'SELECT {col} FROM users WHERE username=? LIMIT 1',('admin',)).fetchone()
        print('' if not row or row[0] is None else str(row[0]),end='')
finally:
    if con is not None: con.close()
PY
}
cleanup(){
  [[ -x "$CONTROL_BIN" ]] && "$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR" >/dev/null 2>&1 || true
}
restore(){
  [[ -d "$BACKUP_DIR" ]] || return 0
  printf '[%b%s%b] Ошибка установки, возвращаю предыдущий FTP runtime.\n' "$CYAN" "$PROJECT" "$RESET" >&2
  [[ -f "$BACKUP_DIR/hyper-host-ctl.bak" ]] && install -m0755 "$BACKUP_DIR/hyper-host-ctl.bak" "$CONTROL_BIN" || true
  [[ -f "$BACKUP_DIR/proftpd_auth_sync.py.bak" ]] && install -m0755 "$BACKUP_DIR/proftpd_auth_sync.py.bak" "$AUTH_BUILDER" || true
  if [[ -d "$BACKUP_DIR/proftpd.bak" ]]; then rm -rf "$PROFTPD_DIR"; cp -a "$BACKUP_DIR/proftpd.bak" "$PROFTPD_DIR"; fi
  "$CONTROL_BIN" ftp-fix >/dev/null 2>&1 || true
}
on_exit(){ rc=$?; trap - EXIT ERR INT TERM; cleanup; if [[ $rc -ne 0 && $ROLLBACK_NEEDED == 1 ]]; then restore; fi; exit $rc; }
trap on_exit EXIT
trap 'exit 130' INT TERM

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$ROOT_DIR/scripts/proftpd_auth_sync.py" ]] || fail 'Не найден scripts/proftpd_auth_sync.py'
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса hhctl'
python3 -m py_compile "$ROOT_DIR/scripts/proftpd_auth_sync.py" || fail 'Ошибка синтаксиса proftpd_auth_sync.py'

ADMIN_BEFORE="$(admin_hash)"; CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/bin"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$AUTH_BUILDER" ]] && cp -a "$AUTH_BUILDER" "$BACKUP_DIR/proftpd_auth_sync.py.bak" || true
[[ -d "$PROFTPD_DIR" ]] && cp -a "$PROFTPD_DIR" "$BACKUP_DIR/proftpd.bak" || true

log "Резервная копия: $BACKUP_DIR"
log 'Включаю простой локальный FTP на 192.168.0.179:21. Nginx, SQL, сайты, боты и пароль admin не изменяются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$AUTH_BUILDER"
"$CONTROL_BIN" ftp-fix

command -v proftpd >/dev/null 2>&1 || fail 'ProFTPD не установлен'
command -v lftp >/dev/null 2>&1 || fail 'lftp не установлен'
proftpd -t -c "$PROFTPD_DIR/proftpd.conf" || fail 'Конфиг ProFTPD не прошёл проверку'
systemctl is-active --quiet hyper-host-ftp.service || fail 'hyper-host-ftp.service не активен'
ss -H -lntp 'sport = :21' | grep -q proftpd || fail 'TCP 21 слушает не ProFTPD'
grep -Eq "^[[:space:]]*MasqueradeAddress[[:space:]]+$LAN_IP([[:space:]]|$)" "$PROFTPD_DIR/proftpd.conf" || fail 'PASV не привязан к 192.168.0.179'
grep -Eq '^[[:space:]]*TLSRequired[[:space:]]+off' "$PROFTPD_DIR/proftpd.conf" || fail 'Обычный FTP не разрешён'
if grep -q '90.189.208.25' "$PROFTPD_DIR/proftpd.conf"; then fail 'В LAN-only конфиге остался публичный PASV IP'; fi

"$CONTROL_BIN" create-ftp "$TEST_USER" "$TEST_PASS" files >/dev/null
printf 'HYPER-HOST v66 LAN FTP test\n%.0s' {1..4096} > "$SRC"
rm -f "$DST" "$PLAIN_LOG" "$TLS_LOG"

log 'Проверяю обычный FTP по локальному IP: PASV, список, загрузка и скачивание.'
TEST_USER="$TEST_USER" TEST_PASS="$TEST_PASS" LAN_IP="$LAN_IP" python3 - <<'PY'
import ftplib,os
class CaptureFTP(ftplib.FTP):
    last_pasv_host=None
    def makepasv(self):
        host,port=super().makepasv(); self.last_pasv_host=host; return host,port
f=CaptureFTP(timeout=15)
f.trust_server_pasv_ipv4_address=True
f.connect(os.environ['LAN_IP'],21)
f.login(os.environ['TEST_USER'],os.environ['TEST_PASS'])
f.nlst()
if f.last_pasv_host != os.environ['LAN_IP']:
    raise SystemExit(f'PASV вернул {f.last_pasv_host}, ожидался {os.environ["LAN_IP"]}')
f.quit()
print('PASV OK:',f.last_pasv_host)
PY

if ! timeout 90 lftp -d -u "$TEST_USER,$TEST_PASS" "ftp://$LAN_IP:21" >"$PLAIN_LOG" 2>&1 <<LFTP
set cmd:fail-exit true
set xfer:clobber true
set ftp:ssl-allow false
set ftp:passive-mode true
set ftp:prefer-epsv false
set ftp:fix-pasv-address false
set net:timeout 15
set net:max-retries 1
cls -1
put $SRC -o v66-lan-test.bin
get v66-lan-test.bin -o $DST
rm v66-lan-test.bin
cls -1
bye
LFTP
then
  cat "$PLAIN_LOG" >&2 || true
  fail 'Обычный FTP по LAN не прошёл'
fi
[[ -f "$DST" ]] || fail 'FTP не скачал тестовый файл'
SRC_SHA="$(sha256sum "$SRC"|awk '{print $1}')"; DST_SHA="$(sha256sum "$DST"|awk '{print $1}')"
[[ "$SRC_SHA" == "$DST_SHA" ]] || fail 'SHA-256 скачанного файла не совпадает'

log 'Проверяю optional explicit TLS по тому же локальному IP.'
if ! timeout 60 lftp -d -u "$TEST_USER,$TEST_PASS" "ftp://$LAN_IP:21" >"$TLS_LOG" 2>&1 <<LFTP
set cmd:fail-exit true
set ssl:verify-certificate no
set ftp:ssl-force true
set ftp:ssl-protect-data true
set ftp:ssl-protect-list true
set ftp:ssl-auth TLS
set ftp:passive-mode true
set ftp:prefer-epsv false
set ftp:fix-pasv-address false
set net:timeout 15
set net:max-retries 1
cls -1
bye
LFTP
then
  cat "$TLS_LOG" >&2 || true
  fail 'FTPS по LAN не прошёл'
fi

"$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null
ADMIN_AFTER="$(admin_hash)"; CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Хеш пароля admin изменился'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл реквизитов администратора изменился'
DOCTOR_JSON="$("$CONTROL_BIN" ftp-doctor-json 2>/dev/null || true)"
{
  echo 'HYPER-HOST v66 LAN-only FTP'
  echo "Endpoint: $LAN_IP:21"
  echo 'Plain FTP: enabled and tested'
  echo 'Explicit TLS 1.2: optional and tested'
  echo 'PASV: 40000-40100, address 192.168.0.179'
  echo 'Router/NAT: not used for LAN clients'
  echo "Source SHA-256: $SRC_SHA"
  echo "Downloaded SHA-256: $DST_SHA"
  echo 'Admin password: unchanged'
  echo "Doctor: $DOCTOR_JSON"
  echo; echo 'Plain FTP lftp output:'; cat "$PLAIN_LOG"
  echo; echo 'FTPS lftp output:'; cat "$TLS_LOG"
} > "$REPORT"
chmod 0600 "$REPORT"
ROLLBACK_NEEDED=0
cleanup

printf '\n============================================================\n'
printf ' %b%s%b — локальный FTP готов\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' Адрес:              %s\n' "$LAN_IP"
printf ' Порт:               21\n'
printf ' PASV:               40000-40100\n'
printf ' Обычный FTP:        РАБОТАЕТ\n'
printf ' Explicit TLS:       РАБОТАЕТ, необязательно\n'
printf ' Admin password:     НЕ ИЗМЕНЁН\n'
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'
