#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="/etc/hyper-host/hyper-host.conf"
CTL="/usr/local/sbin/hyper-host-ctl"
HYPER="/usr/local/bin/hyper"
FIXED_LAN_IP="192.168.0.179"
FIXED_WAN_IP="90.189.208.25"

log(){ printf '\033[1;36m[HYPER-HOST v53]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти: sudo bash apply-v53-connectivity-fix.sh"

for f in scripts/hhctl scripts/hyper src/app/bootstrap.php src/app/setup_db.php src/public/index.php; do
  [[ -f "$PROJECT_DIR/$f" ]] || fail "В архиве отсутствует: $f"
done
bash -n "$PROJECT_DIR/scripts/hhctl"
bash -n "$PROJECT_DIR/scripts/hyper"
php -l "$PROJECT_DIR/src/app/bootstrap.php" >/dev/null
php -l "$PROJECT_DIR/src/app/setup_db.php" >/dev/null
php -l "$PROJECT_DIR/src/public/index.php" >/dev/null

if [[ ! -f "$CONF" ]]; then
  log "Панель ещё не установлена. Запускаю полную установку v53."
  exec bash "$PROJECT_DIR/install.sh"
fi

# shellcheck disable=SC1090
source "$CONF" || true
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
BASE_DIR="${BASE_DIR:-/opt/hyper-host}"
BACKUP_DIR="${BACKUP_DIR:-$BASE_DIR/backups}"
DB_PATH="$BASE_DIR/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
PATCH_BACKUP="$BACKUP_DIR/v53-connectivity-$STAMP"
REPORT="/root/hyper-host-v53-connectivity-report.txt"
mkdir -p "$PATCH_BACKUP"

log "Создаю резервную копию: $PATCH_BACKUP"
for f in "$CTL" "$HYPER" "$PANEL_DIR/app/bootstrap.php" "$PANEL_DIR/app/config.php" "$PANEL_DIR/public/index.php" "$CONF" "$DB_PATH" /etc/vsftpd.conf /etc/vsftpd-hyper-lan.conf /etc/vsftpd-hyper-wan.conf /etc/pam.d/vsftpd-hyper-host /etc/systemd/system/hyper-host-vsftpd-lan.service /etc/systemd/system/hyper-host-vsftpd-wan.service /etc/mysql/conf.d/99-hyper-host-network.cnf /etc/mysql/mariadb.conf.d/99-hyper-host-network.cnf /etc/mysql/mysql.conf.d/99-hyper-host-network.cnf /etc/fstab; do
  [[ -e "$f" ]] || continue
  mkdir -p "$PATCH_BACKUP$(dirname "$f")"
  cp -a "$f" "$PATCH_BACKUP$f"
done

log "Ставлю системные компоненты FTP, MySQL-диагностики и UPnP."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y vsftpd db-util libpam-modules openssl miniupnpc iptables curl netcat-openbsd acl binutils

log "Устанавливаю обновлённый CLI и файлы панели."
install -m 0755 "$PROJECT_DIR/scripts/hhctl" "$CTL"
install -m 0755 "$PROJECT_DIR/scripts/hyper" "$HYPER"
ln -sf "$HYPER" /usr/bin/hyper
ln -sf "$CTL" /usr/bin/hyper-host-ctl
mkdir -p "$PANEL_DIR/app" "$PANEL_DIR/public"
install -m 0644 "$PROJECT_DIR/src/app/bootstrap.php" "$PANEL_DIR/app/bootstrap.php"
install -m 0644 "$PROJECT_DIR/src/app/setup_db.php" "$PANEL_DIR/app/setup_db.php"
install -m 0644 "$PROJECT_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
if [[ -d "$PROJECT_DIR/src/public/assets" ]]; then
  mkdir -p "$PANEL_DIR/public/assets"
  rsync -a "$PROJECT_DIR/src/public/assets/" "$PANEL_DIR/public/assets/"
fi

log "Фиксирую только твои IP: LAN=$FIXED_LAN_IP, WAN=$FIXED_WAN_IP."
mkdir -p /etc/hyper-host
printf '%s\n' "$FIXED_LAN_IP" > /etc/hyper-host/internal_ip
printf '%s\n' "$FIXED_WAN_IP" > /etc/hyper-host/public_ip
rm -f /etc/cron.d/hyper-host-ip-watch /run/hyper-host-public-ip.cache /var/log/hyper-host-ip-watch.log 2>/dev/null || true

FIXED_LAN_IP="$FIXED_LAN_IP" FIXED_WAN_IP="$FIXED_WAN_IP" python3 - "$CONF" "$PANEL_DIR/app/config.php" <<'PYCONF'
from pathlib import Path
import os,re,sys
lan=os.environ['FIXED_LAN_IP']; wan=os.environ['FIXED_WAN_IP']
conf=Path(sys.argv[1]); app=Path(sys.argv[2])
if conf.exists():
    text=conf.read_text(errors='ignore')
    for key,val in [('SERVER_IP',lan),('PUBLIC_IP',wan),('PUBLIC_IP_MODE','manual')]:
        line=f'{key}="{val}"'
        if re.search(rf'^{re.escape(key)}=',text,re.M): text=re.sub(rf'^{re.escape(key)}=.*$',line,text,flags=re.M)
        else: text += ('\n' if text and not text.endswith('\n') else '')+line+'\n'
    conf.write_text(text)
if app.exists():
    text=app.read_text(errors='ignore')
    for key,val in [('server_ip',lan),('public_ip',wan)]:
        text=re.sub(rf"('{key}'\s*=>\s*)'[^']*'",rf"\1'{val}'",text,count=1)
    app.write_text(text)
PYCONF

if [[ -f "$DB_PATH" ]]; then
  FIXED_WAN_IP="$FIXED_WAN_IP" python3 - "$DB_PATH" <<'PYDB'
import os,sqlite3,sys
p=sys.argv[1]; wan=os.environ['FIXED_WAN_IP']; con=sqlite3.connect(p)
def cols(t):
    try:return {r[1] for r in con.execute(f'pragma table_info({t})')}
    except:return set()
if {'key','value'} <= cols('settings'):
    con.execute("insert into settings(key,value) values('public_ip_override',?) on conflict(key) do update set value=excluded.value",(wan,))
if 'host' in cols('ftp_accounts'): con.execute('update ftp_accounts set host=?',(wan,))
if {'remote_allowed','db_host'} <= cols('databases'): con.execute('update databases set remote_allowed=1,db_host=?',(wan,))
if {'remote_allowed','host_pattern'} <= cols('mysql_accounts'): con.execute("update mysql_accounts set remote_allowed=1,host_pattern='%'")
con.commit(); con.close()
PYDB
fi

chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
chmod 0640 "$PANEL_DIR/app/config.php" 2>/dev/null || true

log "Отключаю старый самописный FTP и запускаю полный ремонт подключения."
systemctl stop hyper-host-ftp.service vsftpd.service hyper-host-vsftpd-lan.service hyper-host-vsftpd-wan.service >/dev/null 2>&1 || true
systemctl disable hyper-host-ftp.service vsftpd.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/hyper-host-ftp.service
pkill -f 'hyper_ftp_server.py|hyper-host-ftp-server' >/dev/null 2>&1 || true
systemctl unmask vsftpd >/dev/null 2>&1 || true
systemctl daemon-reload

"$CTL" connectivity-fix
systemctl reload nginx >/dev/null 2>&1 || true

log "Провожу локальные функциональные проверки."
{
  echo "HYPER-HOST v53 connectivity report"
  echo "Generated: $(date -Is)"
  echo
  echo "=== IP ==="
  "$HYPER" ip || true
  echo
  echo "=== CONNECTIVITY DOCTOR ==="
  "$HYPER" connectivity doctor || true
  echo
  echo "=== LISTEN SOCKETS ==="
  ss -lntup | grep -E ':(21|3306|4000[0-9]|4001[0-9]|40020)\b' || true
  echo
  echo "=== VSFTPD LAN ==="
  systemctl --no-pager --full status hyper-host-vsftpd-lan.service || true
  echo
  echo "=== VSFTPD WAN ==="
  systemctl --no-pager --full status hyper-host-vsftpd-wan.service || true
  echo
  echo "=== MARIADB ==="
  systemctl --no-pager --full status mariadb || true
  echo
  echo "=== FTP SAVED ACCOUNT FUNCTIONAL TEST ==="
  "$CTL" ftp-test-saved-json || true
  echo
  echo "=== MYSQL SAVED ACCOUNT FUNCTIONAL TEST ==="
  "$CTL" mysql-test-saved-json || true
  echo
  echo "=== MYSQL REMOTE USERS ==="
  mysql --protocol=socket -uroot -NBe "SELECT User,Host FROM mysql.user WHERE Host IN ('%','192.168.0.%','127.0.0.1','localhost') ORDER BY User,Host" 2>/dev/null || true
  echo
  echo "=== EFFECTIVE MARIADB OPTIONS ==="
  (mariadbd --print-defaults 2>/dev/null || mysqld --print-defaults 2>/dev/null || true)
  echo
  echo "=== UPNP ==="
  upnpc -l 2>/dev/null || true
} > "$REPORT" 2>&1

log "Готово. Отчёт сохранён: $REPORT"
log "Проверка: sudo hyper connectivity doctor"
log "Функциональный тест всех сохранённых FTP/MySQL логинов: sudo hyper connectivity test"
log "FTP LAN тест: sudo hyper ftp test ЛОГИН ПАРОЛЬ 127.0.0.1 21"
log "FTP WAN-backend тест: sudo hyper ftp test ЛОГИН ПАРОЛЬ 127.0.0.1 2121"
log "SQL тест локально: sudo hyper db test 127.0.0.1 ЛОГИН ПАРОЛЬ БАЗА"
log "SQL тест через внешний IP с ЭТОГО сервера: sudo hyper db test 90.189.208.25 ЛОГИН ПАРОЛЬ БАЗА"
log "Резервная копия: $PATCH_BACKUP"

cat <<'DONE'

ВАЖНО:
- phpMyAdmin — это веб-интерфейс: http://192.168.0.179/phpmyadmin/ или http://90.189.208.25/phpmyadmin/
- В коде бота нужен не URL phpMyAdmin, а MySQL host/port/user/password/database.
- Бот на этом же сервере: host=127.0.0.1, port=3306.
- Бот на другом сервере в интернете: host=90.189.208.25, port=3306.
- Если UPnP выключен: TCP 2121 и 40100-40120 на такие же порты 192.168.0.179; TCP 3306 -> 192.168.0.179:3306.
- Для внешнего стандартного FTP-порта можно сделать правило: внешний TCP 21 -> 192.168.0.179:2121.
- FTP внутри сети: 192.168.0.179:21. FTP из интернета: 90.189.208.25:2121.
DONE
