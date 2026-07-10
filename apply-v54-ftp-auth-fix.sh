#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="/usr/local/sbin/hyper-host-ctl"
HYPER="/usr/local/bin/hyper"
BASE_DIR="/opt/hyper-host"
AUTH_TXT="$BASE_DIR/data/vsftpd_virtual_users.txt"
AUTH_DB="$BASE_DIR/data/vsftpd_virtual_users.db"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BASE_DIR/backups/v54-ftp-auth-$STAMP"
REPORT="/root/hyper-host-v54-ftp-auth-report.txt"

log(){ printf '\033[1;36m[HYPER-HOST v54]\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти: sudo bash apply-v54-ftp-auth-fix.sh"
[[ -f "$PROJECT_DIR/scripts/hhctl" ]] || fail "Не найден scripts/hhctl"
[[ -f "$PROJECT_DIR/scripts/hyper" ]] || fail "Не найден scripts/hyper"

bash -n "$PROJECT_DIR/scripts/hhctl"
bash -n "$PROJECT_DIR/scripts/hyper"

log "Создаю резервную копию FTP-конфигурации: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for f in "$CTL" "$HYPER" "$AUTH_TXT" "$AUTH_DB" "$DB_PATH" \
  /etc/vsftpd-hyper-lan.conf /etc/vsftpd-hyper-wan.conf \
  /etc/pam.d/vsftpd-hyper-host \
  /etc/systemd/system/hyper-host-vsftpd-lan.service \
  /etc/systemd/system/hyper-host-vsftpd-wan.service; do
  [[ -e "$f" ]] || continue
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"
done

log "Устанавливаю исправленный CLI."
install -m 0755 "$PROJECT_DIR/scripts/hhctl" "$CTL"
install -m 0755 "$PROJECT_DIR/scripts/hyper" "$HYPER"
ln -sf "$HYPER" /usr/bin/hyper
ln -sf "$CTL" /usr/bin/hyper-host-ctl

export DEBIAN_FRONTEND=noninteractive
if ! command -v db_load >/dev/null 2>&1 || ! command -v vsftpd >/dev/null 2>&1; then
  log "Устанавливаю vsftpd и Berkeley DB tools."
  apt-get update -y
  apt-get install -y vsftpd db-util libpam-modules openssl acl binutils
fi

mkdir -p "$BASE_DIR/data"

log "Исправляю повреждённый файл FTP-логинов v53."
if [[ -f "$AUTH_TXT" ]]; then
  python3 - "$AUTH_TXT" <<'PYREPAIRTXT'
from pathlib import Path
import sys
p=Path(sys.argv[1])
raw=p.read_text(encoding='utf-8', errors='surrogateescape') if p.exists() else ''
if '\\n' in raw and raw.count('\n') <= 1:
    raw=raw.replace('\\r\\n','\n').replace('\\n','\n')
p.write_text(raw, encoding='utf-8', errors='surrogateescape')
PYREPAIRTXT
fi
rm -f "$AUTH_DB".new.* 2>/dev/null || true

log "Пересобираю FTP-авторизацию и восстанавливаю аккаунты из SQLite."
"$CTL" connectivity-fix

log "Проверяю, что оба FTP-сервиса реально слушают порты."
systemctl is-active --quiet hyper-host-vsftpd-lan.service || fail "LAN FTP не запустился. Смотри: journalctl -u hyper-host-vsftpd-lan -n 150 --no-pager"
systemctl is-active --quiet hyper-host-vsftpd-wan.service || fail "WAN FTP не запустился. Смотри: journalctl -u hyper-host-vsftpd-wan -n 150 --no-pager"
ss -H -lnt 'sport = :21' | grep -q . || fail "Никто не слушает TCP 21"
ss -H -lnt 'sport = :2121' | grep -q . || fail "Никто не слушает TCP 2121"

{
  echo "HYPER-HOST v54 FTP auth report"
  echo "Generated: $(date -Is)"
  echo
  echo "=== SERVICES ==="
  systemctl --no-pager --full status hyper-host-vsftpd-lan.service || true
  systemctl --no-pager --full status hyper-host-vsftpd-wan.service || true
  echo
  echo "=== PORTS ==="
  ss -lntp | grep -E ':(21|2121|4000[0-9]|4001[0-9]|40020|4010[0-9]|4011[0-9]|40120)\\b' || true
  echo
  echo "=== FTP DOCTOR ==="
  "$HYPER" ftp doctor || true
  echo
  echo "=== SAVED ACCOUNT TESTS ==="
  "$CTL" ftp-test-saved-json || true
  echo
  echo "=== AUTH FILE SHAPE ==="
  python3 - "$AUTH_TXT" <<'PYAUDIT'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8',errors='ignore').splitlines() if p.exists() else []
print({'lines':len(lines),'pairs':len(lines)//2,'even':len(lines)%2==0,'literal_backslash_n':('\\n' in p.read_text(errors='ignore') if p.exists() else False)})
PYAUDIT
} > "$REPORT" 2>&1

log "Готово: FTP LAN 192.168.0.179:21, FTP WAN 90.189.208.25:2121"
log "Отчёт: $REPORT"
log "Проверка: sudo hyper connectivity doctor && sudo hyper connectivity test"
log "Резервная копия: $BACKUP_DIR"
