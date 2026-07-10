#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Запусти через sudo/root" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/opt/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
RUNTIME_SCRIPT="$BASE_DIR/bin/hyper_ftp_runtime.py"
BACKUP_DIR="$BASE_DIR/backups/v55-readonly-ftp-$(date +%Y%m%d-%H%M%S)"
REPORT="/root/hyper-host-v55-ftp-report.txt"

log(){ echo "[HYPER-HOST v55] $*"; }
fail(){ echo "[HYPER-HOST v55 ERROR] $*" >&2; exit 1; }

[[ -f "$ROOT_DIR/scripts/hhctl" ]] || fail "Не найден scripts/hhctl"
[[ -f "$ROOT_DIR/scripts/hyper_ftp_runtime.py" ]] || fail "Не найден scripts/hyper_ftp_runtime.py"
[[ -f /etc/hyper-host/hyper-host.conf ]] || fail "Не найден действующий конфиг /etc/hyper-host/hyper-host.conf"

log "Резервная копия: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/bin" "$BASE_DIR/logs" "$BASE_DIR/run" "$BASE_DIR/data" "$BASE_DIR/ftp/user_conf"
[[ -f "$CONTROL_BIN" ]] && cp -a "$CONTROL_BIN" "$BACKUP_DIR/hyper-host-ctl.bak" || true
[[ -f "$RUNTIME_SCRIPT" ]] && cp -a "$RUNTIME_SCRIPT" "$BACKUP_DIR/hyper_ftp_runtime.py.bak" || true
[[ -f "$BASE_DIR/data/vsftpd_virtual_users.txt" ]] && cp -a "$BASE_DIR/data/vsftpd_virtual_users.txt" "$BACKUP_DIR/" || true
[[ -f "$BASE_DIR/data/hyperhost.sqlite" ]] && cp -a "$BASE_DIR/data/hyperhost.sqlite" "$BACKUP_DIR/" || true
crontab -l > "$BACKUP_DIR/root.crontab" 2>/dev/null || true

log "Устанавливаю CLI без записи в /etc/fstab и PAM."
install -m 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m 0755 "$ROOT_DIR/scripts/hyper_ftp_runtime.py" "$RUNTIME_SCRIPT"
ln -sf "$CONTROL_BIN" /usr/bin/hyper-host-ctl 2>/dev/null || true

# Keep the existing user-facing hyper wrapper. Recreate only if it is missing.
if [[ ! -x /usr/local/bin/hyper && -f "$ROOT_DIR/scripts/hyper" ]]; then
  install -m 0755 "$ROOT_DIR/scripts/hyper" /usr/local/bin/hyper
fi
ln -sf /usr/local/bin/hyper /usr/bin/hyper 2>/dev/null || true

log "Ставлю изолированный FTP runtime в /opt (не требует writable /etc)."
if ! /usr/bin/python3 -c 'import pyftpdlib' >/dev/null 2>&1; then
  if [[ ! -x "$BASE_DIR/venv-ftp/bin/python3" ]]; then
    /usr/bin/python3 -m venv "$BASE_DIR/venv-ftp" >/dev/null 2>&1 || true
  fi
  if [[ -x "$BASE_DIR/venv-ftp/bin/python3" ]]; then
    "$BASE_DIR/venv-ftp/bin/python3" -m ensurepip --upgrade >/dev/null 2>&1 || true
    "$BASE_DIR/venv-ftp/bin/python3" -m pip install --disable-pip-version-check --no-cache-dir 'pyftpdlib>=1.5.9,<2.0' >/dev/null
  fi
fi
if ! /usr/bin/python3 -c 'import pyftpdlib' >/dev/null 2>&1 && ! "$BASE_DIR/venv-ftp/bin/python3" -c 'import pyftpdlib' >/dev/null 2>&1; then
  fail "Не удалось установить pyftpdlib. Проверь интернет и выполни: python3 -m venv /opt/hyper-host/venv-ftp && /opt/hyper-host/venv-ftp/bin/pip install pyftpdlib"
fi

log "Останавливаю сломанный vsftpd/PAM backend и поднимаю FTP runtime."
systemctl stop hyper-host-vsftpd-lan.service hyper-host-vsftpd-wan.service vsftpd.service hyper-host-ftp.service >/dev/null 2>&1 || true
pkill -f 'hyper_ftp_runtime.py' >/dev/null 2>&1 || true
"$CONTROL_BIN" ftp-fix

log "Проверяю порты и сохранённые аккаунты."
"$CONTROL_BIN" ftp-doctor-json | tee "$REPORT"
printf '\n===== SAVED ACCOUNTS =====\n' | tee -a "$REPORT"
"$CONTROL_BIN" ftp-test-saved-json | tee -a "$REPORT" || true

log "Проверяю создание, вход, загрузку, скачивание и удаление временного аккаунта."
TEST_USER="hhv55test$(date +%s)"
TEST_PASS="V55test-$(openssl rand -hex 8)"
cleanup(){ "$CONTROL_BIN" delete-ftp "$TEST_USER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$CONTROL_BIN" create-ftp "$TEST_USER" "$TEST_PASS" files
"$CONTROL_BIN" ftp-test-login "$TEST_USER" "$TEST_PASS" 127.0.0.1 21 | tee -a "$REPORT"
"$CONTROL_BIN" delete-ftp "$TEST_USER"
trap - EXIT

if ! ss -H -ltn 'sport = :21' | grep -q .; then fail "TCP 21 не слушается после фикса"; fi
if ! ss -H -ltn 'sport = :2121' | grep -q .; then fail "TCP 2121 не слушается после фикса"; fi

cat >> "$REPORT" <<'EOF'

===== CONNECTIONS =====
LAN FTP:      192.168.0.179:21, passive 40000-40020
Internet FTP: 90.189.208.25:2121, passive 40100-40120
Router: TCP 2121 and TCP 40100-40120 -> 192.168.0.179
Encryption: plain FTP (TLS disabled in read-only /etc fallback)
EOF

log "ГОТОВО. FTP работает без /etc/fstab и /etc/pam.d."
log "Отчёт: $REPORT"
log "Проверка: sudo hyper connectivity doctor && sudo hyper connectivity test"
