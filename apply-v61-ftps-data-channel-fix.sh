#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=/opt/hyper-host
CONTROL_BIN=/usr/local/sbin/hyper-host-ctl
FTP_RUNTIME="$BASE_DIR/bin/hyper_ftp_runtime.py"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
CREDENTIALS_FILE="$BASE_DIR/admin-credentials.env"
BACKUP_DIR="$BASE_DIR/backups/v61-ftps-data-$(date +%Y%m%d-%H%M%S)"
REPORT=/root/hyper-host-v61-ftps-report.txt
PROJECT='HYPER-HOST'; CYAN='\033[1;36m'; RESET='\033[0m'
log(){ printf '[%b%s%b] %s\n' "$CYAN" "$PROJECT" "$RESET" "$*"; }
fail(){ printf '[%b%s%b] ERROR: %s\n' "$CYAN" "$PROJECT" "$RESET" "$*" >&2; exit 1; }
admin_hash(){ [[ -f "$DB_PATH" ]] || return 0; php -r 'try{$d=new PDO("sqlite:".$argv[1]);$q=$d->prepare("SELECT password_hash FROM users WHERE username=:u LIMIT 1");$q->execute([":u"=>"admin"]);echo(string)($q->fetchColumn()?:"");}catch(Throwable $e){}' "$DB_PATH" 2>/dev/null || true; }
file_sha(){ [[ -f "$1" ]] && sha256sum "$1"|awk '{print $1}' || true; }
[[ -f "$ROOT_DIR/scripts/hhctl" && -f "$ROOT_DIR/scripts/hyper_ftp_runtime.py" ]] || fail 'Не найдены файлы патча'
bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса hhctl'
python3 -m py_compile "$ROOT_DIR/scripts/hyper_ftp_runtime.py" || fail 'Ошибка синтаксиса FTP runtime'
ADMIN_BEFORE="$(admin_hash)"; CRED_BEFORE="$(file_sha "$CREDENTIALS_FILE")"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/bin"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$FTP_RUNTIME" ]] && cp -a "$FTP_RUNTIME" "$BACKUP_DIR/hyper_ftp_runtime.py.bak" || true
log 'Устанавливаю только исправление FTPS data-channel. Nginx, SQL и пароль admin не изменяются.'
install -m0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m0755 "$ROOT_DIR/scripts/hyper_ftp_runtime.py" "$FTP_RUNTIME"
"$CONTROL_BIN" ftp-fix
PY="$BASE_DIR/venv-ftp/bin/python3"
[[ -x "$PY" ]] || fail 'FTP venv не найден'
VERSION="$($PY -c 'from importlib.metadata import version; print(version("pyftpdlib"))')"
[[ "$VERSION" == '2.2.0' ]] || fail "Ожидался pyftpdlib 2.2.0, установлен $VERSION"
TEST_USER="hhv61$(date +%s)"; TEST_PASS="V61-$(openssl rand -hex 12)"
cleanup(){ "$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$CONTROL_BIN" create-ftp "$TEST_USER" "$TEST_PASS" files >/dev/null
log 'Проверяю AUTH TLS, TLS 1.2, MLSD/LIST, upload/download и корректное завершение data-channel.'
FTP_USER="$TEST_USER" FTP_PASS="$TEST_PASS" "$PY" - <<'PYTEST'
import ftplib, io, os, ssl
ctx=ssl._create_unverified_context()
ctx.minimum_version=ssl.TLSVersion.TLSv1_2
ctx.maximum_version=ssl.TLSVersion.TLSv1_2
f=ftplib.FTP_TLS(context=ctx, timeout=10)
f.connect('127.0.0.1',21); f.auth(); f.login(os.environ['FTP_USER'],os.environ['FTP_PASS']); f.prot_p()
assert f.sock.version() == 'TLSv1.2', f.sock.version()
for _ in range(5):
    list(f.mlsd())
    f.nlst()
payload=(b'HYPER-HOST-v61-FTPS-DATA-OK\n'*4096)
f.storbinary('STOR v61-data-test.bin', io.BytesIO(payload))
got=bytearray(); f.retrbinary('RETR v61-data-test.bin', got.extend)
assert bytes(got)==payload
f.delete('v61-data-test.bin')
list(f.mlsd())
f.quit()
PYTEST
"$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null
trap - EXIT
ADMIN_AFTER="$(admin_hash)"; CRED_AFTER="$(file_sha "$CREDENTIALS_FILE")"
[[ "$ADMIN_BEFORE" == "$ADMIN_AFTER" ]] || fail 'Пароль admin изменился — восстанови backup'
[[ "$CRED_BEFORE" == "$CRED_AFTER" ]] || fail 'Файл данных admin изменился'
{
 echo 'HYPER-HOST v61 FTPS data-channel fix'
 echo "pyftpdlib: $VERSION"
 echo 'FTPS: explicit TLS 1.2, TCP 21'
 echo 'PASV: 40000-40100'
 echo 'MLSD/LIST: passed 5 cycles'
 echo 'Upload/download: passed'
 echo 'Admin password: unchanged'
} > "$REPORT"
chmod 0600 "$REPORT"
printf '\n============================================================\n'
printf ' %b%s%b — FTPS data-channel исправлен\n' "$CYAN" "$PROJECT" "$RESET"
printf '============================================================\n'
printf ' Движок:             pyftpdlib %s\n' "$VERSION"
printf ' FTPS:               explicit TLS 1.2, TCP 21\n'
printf ' PASV:               40000-40100\n'
printf ' MLSD/LIST:          OK\n'
printf ' Upload/download:    OK\n'
printf ' Admin password:     НЕ ИЗМЕНЁН\n'
printf ' Отчёт:              %s\n' "$REPORT"
printf '============================================================\n'
