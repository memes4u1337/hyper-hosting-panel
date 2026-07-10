#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запусти через sudo/root' >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/opt/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
RUNTIME_SCRIPT="$BASE_DIR/bin/hyper_ftp_runtime.py"
AUTH_FILE="$BASE_DIR/data/vsftpd_virtual_users.txt"
CONF="/etc/hyper-host/hyper-host.conf"
BACKUP_DIR="$BASE_DIR/backups/v56-single-ftp-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v56-ftp-report.txt"

log(){ echo "[HYPER-HOST v56] $*"; }
fail(){ echo "[HYPER-HOST v56 ERROR] $*" >&2; exit 1; }

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail 'Не найден scripts/hhctl'
[[ -f "$ROOT_DIR/scripts/hyper" ]] || fail 'Не найден scripts/hyper'
[[ -f "$ROOT_DIR/scripts/hyper_ftp_runtime.py" ]] || fail 'Не найден scripts/hyper_ftp_runtime.py'
[[ -f "$CONF" ]] || fail "Не найден конфиг $CONF"

bash -n "$ROOT_DIR/scripts/hhctl" || fail 'Ошибка синтаксиса scripts/hhctl'
bash -n "$ROOT_DIR/scripts/hyper" || fail 'Ошибка синтаксиса scripts/hyper'
python3 -m py_compile "$ROOT_DIR/scripts/hyper_ftp_runtime.py" || fail 'Ошибка синтаксиса FTP runtime'

# shellcheck disable=SC1090
source "$CONF"
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
FTP_DIR="${FTP_DIR:-/var/www/hyper-host-ftp}"

log "Резервная копия: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/bin" "$BASE_DIR/logs" "$BASE_DIR/run" "$BASE_DIR/data" "$BASE_DIR/ftp/user_conf" "$FTP_DIR"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$HYPER_BIN" ]] && cp -a "$HYPER_BIN" "$BACKUP_DIR/hyper.bak" || true
[[ -f "$RUNTIME_SCRIPT" ]] && cp -a "$RUNTIME_SCRIPT" "$BACKUP_DIR/hyper_ftp_runtime.py.bak" || true
[[ -f "$AUTH_FILE" ]] && cp -a "$AUTH_FILE" "$BACKUP_DIR/ftp-auth.bak" || true
[[ -f "$PANEL_DIR/public/index.php" ]] && cp -a "$PANEL_DIR/public/index.php" "$BACKUP_DIR/panel-index.php.bak" || true
[[ -f "$BASE_DIR/data/hyperhost.sqlite" ]] && cp -a "$BASE_DIR/data/hyperhost.sqlite" "$BACKUP_DIR/hyperhost.sqlite.bak" || true

log 'Устанавливаю один FTP-движок pyftpdlib и исправленный CLI.'
install -m 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m 0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install -m 0755 "$ROOT_DIR/scripts/hyper_ftp_runtime.py" "$RUNTIME_SCRIPT"
ln -sf "$CONTROL_BIN" /usr/bin/hyper-host-ctl 2>/dev/null || true
ln -sf "$HYPER_BIN" /usr/bin/hyper 2>/dev/null || true

if [[ -f "$ROOT_DIR/src/public/index.php" && -d "$PANEL_DIR/public" ]]; then
  install -m 0644 "$ROOT_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
  chown www-data:www-data "$PANEL_DIR/public/index.php" 2>/dev/null || true
fi

log 'Проверяю зависимость pyftpdlib.'
if ! /usr/bin/python3 -c 'import pyftpdlib' >/dev/null 2>&1; then
  if [[ ! -x "$BASE_DIR/venv-ftp/bin/python3" ]]; then
    /usr/bin/python3 -m venv "$BASE_DIR/venv-ftp" >/dev/null 2>&1 || true
  fi
  [[ -x "$BASE_DIR/venv-ftp/bin/python3" ]] || fail 'Не удалось создать /opt/hyper-host/venv-ftp'
  "$BASE_DIR/venv-ftp/bin/python3" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$BASE_DIR/venv-ftp/bin/python3" -m pip install --disable-pip-version-check --no-cache-dir 'pyftpdlib>=1.5.9,<2.0' >/dev/null
fi
if ! /usr/bin/python3 -c 'import pyftpdlib' >/dev/null 2>&1 && ! "$BASE_DIR/venv-ftp/bin/python3" -c 'import pyftpdlib' >/dev/null 2>&1; then
  fail 'pyftpdlib не установлен'
fi

log 'Удаляю остатки неудачных тестовых аккаунтов v55/v56.'
python3 - "$AUTH_FILE" "$BASE_DIR/data/hyperhost.sqlite" "$BASE_DIR/ftp/user_conf" "$FTP_DIR" <<'PYCLEAN'
from pathlib import Path
import shutil
import sqlite3
import sys

auth = Path(sys.argv[1])
db = Path(sys.argv[2])
conf_dir = Path(sys.argv[3])
ftp_dir = Path(sys.argv[4])
prefixes = ("hhv55test", "hhv56test", "hhftp_hhv55test", "hhftp_hhv56test")
try:
    raw = auth.read_text(encoding="utf-8", errors="surrogateescape")
except FileNotFoundError:
    raw = ""
if "\\n" in raw and raw.count("\n") <= 1:
    raw = raw.replace("\\r\\n", "\n").replace("\\n", "\n")
lines = raw.splitlines()
out = []
for index in range(0, len(lines) - 1, 2):
    username = lines[index].strip()
    password = lines[index + 1]
    if username and password and not username.startswith(prefixes):
        out.extend((username, password))
auth.parent.mkdir(parents=True, exist_ok=True)
auth.write_text(("\n".join(out) + "\n") if out else "", encoding="utf-8")
for directory in (conf_dir, ftp_dir):
    if not directory.exists():
        continue
    for item in directory.iterdir():
        if item.name.startswith(prefixes):
            if item.is_dir() and not item.is_symlink():
                shutil.rmtree(item, ignore_errors=True)
            else:
                item.unlink(missing_ok=True)
if db.exists():
    try:
        connection = sqlite3.connect(db)
        connection.execute("DELETE FROM ftp_accounts WHERE username LIKE 'hhv55test%' OR username LIKE 'hhv56test%'")
        connection.commit()
        connection.close()
    except Exception:
        pass
PYCLEAN
chmod 0600 "$AUTH_FILE" 2>/dev/null || true

log 'Останавливаю старые vsftpd/dual-instance процессы и запускаю один FTP-сервис.'
systemctl stop hyper-host-ftp.service hyper-host-ftp-lan.service hyper-host-ftp-wan.service hyper-host-vsftpd-lan.service hyper-host-vsftpd-wan.service vsftpd.service >/dev/null 2>&1 || true
pkill -f 'hyper_ftp_runtime.py' >/dev/null 2>&1 || true
"$CONTROL_BIN" ftp-fix

log 'Проверяю сервис, порт и banner.'
DOCTOR_JSON="$("$CONTROL_BIN" ftp-doctor-json)"
printf '%s\n' "$DOCTOR_JSON" | tee "$REPORT"
DOCTOR_JSON="$DOCTOR_JSON" python3 - <<'PYDOCTOR'
import json, os, sys
try:
    data = json.loads(os.environ['DOCTOR_JSON'])
except Exception as exc:
    raise SystemExit(f"Некорректный doctor JSON: {exc}")
if not data.get('listen_21'):
    raise SystemExit('TCP 21 не слушается')
if not str(data.get('banner','')).startswith('220'):
    raise SystemExit('FTP не отдал 220 banner')
if data.get('ftp_backend') != 'pyftpdlib single-engine':
    raise SystemExit('Запущен не тот FTP backend')
PYDOCTOR

log 'Проверяю сохранённые аккаунты реальной загрузкой и скачиванием.'
SAVED_JSON="$("$CONTROL_BIN" ftp-test-saved-json)"
printf '\n===== SAVED ACCOUNTS =====\n%s\n' "$SAVED_JSON" | tee -a "$REPORT"
SAVED_JSON="$SAVED_JSON" python3 - <<'PYSAVED'
import json, os
result=json.loads(os.environ.get('SAVED_JSON','{}'))
if int(result.get('failed') or 0) > 0:
    raise SystemExit('Один или несколько сохранённых FTP-аккаунтов не прошли тест')
PYSAVED

log 'Проверяю полный цикл: создать → войти → загрузить → скачать → удалить → получить отказ.'
TEST_USER="hhv56test$(date +%s)"
TEST_PASS="V56-$(openssl rand -hex 10)"
cleanup(){ "$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$CONTROL_BIN" create-ftp "$TEST_USER" "$TEST_PASS" files | tee -a "$REPORT"
"$CONTROL_BIN" ftp-test-login "$TEST_USER" "$TEST_PASS" 127.0.0.1 21 | tee -a "$REPORT"
"$CONTROL_BIN" delete-ftp "$TEST_USER" | tee -a "$REPORT"
sleep 1
if "$CONTROL_BIN" ftp-test-login "$TEST_USER" "$TEST_PASS" 127.0.0.1 21 >>"$REPORT" 2>&1; then
  fail 'Удалённый FTP-аккаунт всё ещё может войти'
fi
if grep -Fxq "$TEST_USER" "$AUTH_FILE" 2>/dev/null; then
  fail 'Удалённый FTP-аккаунт остался в auth-файле'
fi
[[ ! -e "$FTP_DIR/$TEST_USER" ]] || fail 'Папка удалённого тестового аккаунта осталась'
trap - EXIT
printf 'OK: после удаления вход запрещён\n' | tee -a "$REPORT"

ss -H -lntp 'sport = :21' | grep -q . || fail 'TCP 21 не слушается после финального теста'

cat >> "$REPORT" <<'EOF'

===== CONNECTIONS =====
LAN:      192.168.0.179:21
Internet: 90.189.208.25:21
Passive:  40000-40100
Router:   TCP 21 and TCP 40000-40100 -> 192.168.0.179
Mode:     Plain FTP, Passive
EOF

log 'ГОТОВО: один FTP-движок, один сервис, один порт 21.'
log "Отчёт: $REPORT"
