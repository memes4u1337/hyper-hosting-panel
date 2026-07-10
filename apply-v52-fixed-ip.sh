#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="/etc/hyper-host/hyper-host.conf"
CTL="/usr/local/sbin/hyper-host-ctl"
HYPER="/usr/local/bin/hyper"
FTP_BIN="/usr/local/sbin/hyper-host-ftp-server"
FIXED_LAN_IP="192.168.0.179"
FIXED_WAN_IP="90.189.208.25"

log(){ printf '\033[1;36m[HYPER-HOST v52]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARNING]\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти: sudo bash apply-v52-fixed-ip.sh"

for f in scripts/hhctl scripts/hyper scripts/hyper_ftp_server.py src/app/bootstrap.php src/app/setup_db.php src/public/index.php; do
  [[ -f "$PROJECT_DIR/$f" ]] || fail "Не найден файл обновления: $f"
done

bash -n "$PROJECT_DIR/scripts/hhctl"
bash -n "$PROJECT_DIR/scripts/hyper"
python3 -m py_compile "$PROJECT_DIR/scripts/hyper_ftp_server.py"
php -l "$PROJECT_DIR/src/app/bootstrap.php" >/dev/null
php -l "$PROJECT_DIR/src/app/setup_db.php" >/dev/null
php -l "$PROJECT_DIR/src/public/index.php" >/dev/null

if [[ ! -f "$CONF" ]]; then
  log "Панель ещё не установлена — запускаю полную установку с фиксированными IP."
  exec bash "$PROJECT_DIR/install.sh"
fi

# shellcheck disable=SC1090
source "$CONF" || true
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
BASE_DIR="${BASE_DIR:-/opt/hyper-host}"
BACKUP_DIR="${BACKUP_DIR:-$BASE_DIR/backups}"
DNS_DIR="${DNS_DIR:-/etc/bind/hyper-host-zones}"
DB_PATH="${BASE_DIR}/data/hyperhost.sqlite"
OLD_WAN_IP="${PUBLIC_IP:-${SERVER_PUBLIC_IP:-}}"
[[ -z "$OLD_WAN_IP" && -f /etc/hyper-host/public_ip ]] && OLD_WAN_IP="$(tr -d '[:space:]' </etc/hyper-host/public_ip 2>/dev/null || true)"
STAMP="$(date +%Y%m%d-%H%M%S)"
PATCH_BACKUP="$BACKUP_DIR/v52-fixed-ip-$STAMP"
mkdir -p "$PATCH_BACKUP"

log "Создаю резервную копию: $PATCH_BACKUP"
for f in "$CTL" "$HYPER" "$FTP_BIN" "$PANEL_DIR/app/bootstrap.php" "$PANEL_DIR/app/config.php" "$PANEL_DIR/public/index.php" "$CONF" "$DB_PATH"; do
  if [[ -e "$f" ]]; then
    mkdir -p "$PATCH_BACKUP$(dirname "$f")"
    cp -a "$f" "$PATCH_BACKUP$f"
  fi
done
cp -a /etc/phpmyadmin/conf.d/hyper-host-server.php "$PATCH_BACKUP/phpmyadmin-server.php" 2>/dev/null || true
cp -a /etc/mysql/mariadb.conf.d/99-hyper-host-network.cnf "$PATCH_BACKUP/mysql-network.cnf" 2>/dev/null || true
[[ -d "$DNS_DIR" ]] && cp -a "$DNS_DIR" "$PATCH_BACKUP/dns-zones" 2>/dev/null || true

log "Устанавливаю CLI, FTP-сервер и файлы панели."
install -m 0755 "$PROJECT_DIR/scripts/hhctl" "$CTL"
install -m 0755 "$PROJECT_DIR/scripts/hyper" "$HYPER"
install -m 0755 "$PROJECT_DIR/scripts/hyper_ftp_server.py" "$FTP_BIN"
ln -sf "$HYPER" /usr/bin/hyper 2>/dev/null || true
ln -sf "$CTL" /usr/bin/hyper-host-ctl 2>/dev/null || true
mkdir -p "$PANEL_DIR/app" "$PANEL_DIR/public"
install -m 0644 "$PROJECT_DIR/src/app/bootstrap.php" "$PANEL_DIR/app/bootstrap.php"
install -m 0644 "$PROJECT_DIR/src/app/setup_db.php" "$PANEL_DIR/app/setup_db.php"
install -m 0644 "$PROJECT_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
if [[ -d "$PROJECT_DIR/src/public/assets" ]]; then
  mkdir -p "$PANEL_DIR/public/assets"
  rsync -a "$PROJECT_DIR/src/public/assets/" "$PANEL_DIR/public/assets/"
fi

log "Фиксирую LAN=$FIXED_LAN_IP и WAN=$FIXED_WAN_IP во всех конфигах."
mkdir -p /etc/hyper-host
printf '%s\n' "$FIXED_LAN_IP" > /etc/hyper-host/internal_ip
printf '%s\n' "$FIXED_WAN_IP" > /etc/hyper-host/public_ip
rm -f /run/hyper-host-public-ip.cache 2>/dev/null || true

FIXED_LAN_IP="$FIXED_LAN_IP" FIXED_WAN_IP="$FIXED_WAN_IP" python3 - "$CONF" "$PANEL_DIR/app/config.php" <<'PYCONF'
from pathlib import Path
import os,re,sys
lan=os.environ['FIXED_LAN_IP']; wan=os.environ['FIXED_WAN_IP']
conf=Path(sys.argv[1]); app=Path(sys.argv[2])
if conf.exists():
    text=conf.read_text(errors='ignore')
    def put(key,val):
        nonlocal_text[0]=re.sub(rf'^{re.escape(key)}=.*$', f'{key}="{val}"', nonlocal_text[0], flags=re.M) if re.search(rf'^{re.escape(key)}=', nonlocal_text[0], re.M) else nonlocal_text[0]+('\n' if nonlocal_text[0] and not nonlocal_text[0].endswith('\n') else '')+f'{key}="{val}"\n'
    nonlocal_text=[text]
    put('SERVER_IP',lan); put('PUBLIC_IP',wan); put('PUBLIC_IP_MODE','manual')
    conf.write_text(nonlocal_text[0])
if app.exists():
    text=app.read_text(errors='ignore')
    for key,val in [('server_ip',lan),('public_ip',wan)]:
        text=re.sub(rf"('{re.escape(key)}'\s*=>\s*)'[^']*'", rf"\1'{val}'", text, count=1)
    app.write_text(text)
PYCONF

log "Обновляю сохранённые адреса FTP и баз в SQLite."
if [[ -f "$DB_PATH" ]]; then
  FIXED_WAN_IP="$FIXED_WAN_IP" python3 - "$DB_PATH" <<'PYDB'
import os,sqlite3,sys
path=sys.argv[1]; wan=os.environ['FIXED_WAN_IP']
con=sqlite3.connect(path)
def cols(table):
    try: return {r[1] for r in con.execute(f'PRAGMA table_info({table})')}
    except Exception: return set()
try:
    if {'key','value'} <= cols('settings'):
        con.execute("INSERT INTO settings(key,value) VALUES('public_ip_override',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(wan,))
    if 'host' in cols('ftp_accounts'):
        con.execute('UPDATE ftp_accounts SET host=?',(wan,))
    dc=cols('databases')
    if {'db_host','remote_allowed'} <= dc:
        con.execute("UPDATE databases SET db_host=CASE WHEN remote_allowed=1 THEN ? ELSE '127.0.0.1' END",(wan,))
    con.commit()
finally:
    con.close()
PYDB
fi

log "Заменяю старый WAN-IP в управляемых DNS-зонах."
if [[ -d "$DNS_DIR" ]]; then
  OLD_WAN_IP="$OLD_WAN_IP" FIXED_WAN_IP="$FIXED_WAN_IP" python3 - "$DNS_DIR" <<'PYDNS'
from pathlib import Path
import os,sys
root=Path(sys.argv[1]); new=os.environ['FIXED_WAN_IP']
olds={os.environ.get('OLD_WAN_IP','').strip()}-{new,''}
for p in root.glob('db.*'):
    text=p.read_text(errors='ignore'); original=text
    for old in olds:
        text=text.replace(f'IN A {old}',f'IN A {new}').replace(f'ip4:{old} ',f'ip4:{new} ')
    if text != original: p.write_text(text)
PYDNS
  systemctl restart bind9 2>/dev/null || systemctl restart named 2>/dev/null || true
fi

chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
chmod 0640 "$PANEL_DIR/app/config.php" 2>/dev/null || true

log "Применяю профиль к FTP, MySQL и phpMyAdmin."
"$CTL" ip-detect --apply >/tmp/hyper-host-v52-ip.json
"$CTL" ftp-fix
"$CTL" mysql-external enable
"$CTL" phpmyadmin-fix

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart hyper-host-ftp.service >/dev/null 2>&1 || true
systemctl reload nginx >/dev/null 2>&1 || true
nginx -t >/dev/null 2>&1 || warn "nginx -t вернул ошибку — проверь: sudo nginx -t"

log "Готово. Панель теперь использует только LAN=$FIXED_LAN_IP и WAN=$FIXED_WAN_IP."
"$HYPER" ip
printf '\n'
log "Проверка FTP: sudo hyper ftp doctor"
log "Проверка SQL: sudo hyper db doctor"
log "Резервная копия: $PATCH_BACKUP"
