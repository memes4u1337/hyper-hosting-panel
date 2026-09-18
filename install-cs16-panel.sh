#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root: sudo bash install-cs16-panel.sh' >&2; exit 1; }
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cs16-panel"
[[ -d "$SRC_DIR" ]] || { echo "[ERROR] cs16-panel directory not found next to installer" >&2; exit 1; }

DOMAIN="${CS16_PANEL_DOMAIN:-www.avito.hyper-host.pw}"
DB_NAME="${CS16_DB_NAME:-hyper_cs16}"
DB_USER="${CS16_DB_USER:-hyper_cs16_panel}"
DB_PASS="${CS16_DB_PASSWORD:-$(openssl rand -hex 24)}"
REQUESTED_PUBLIC_IP="${CS16_PUBLIC_IP:-}"
SSL_EMAIL="${CS16_SSL_EMAIL:-}"
SKIP_GAME="${CS16_SKIP_GAME_DOWNLOAD:-0}"
CREATE_DEFAULT="${CS16_CREATE_DEFAULT:-1}"
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || { echo "[ERROR] Invalid CS16_PANEL_DOMAIN: $DOMAIN" >&2; exit 1; }
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]{2,48}$ ]] || { echo "[ERROR] Invalid CS16_DB_NAME" >&2; exit 1; }
[[ "$DB_USER" =~ ^[A-Za-z0-9_]{2,32}$ ]] || { echo "[ERROR] Invalid CS16_DB_USER" >&2; exit 1; }
[[ "$DB_PASS" =~ ^[A-Za-z0-9._~!@#%+=:-]{16,128}$ ]] || { echo "[ERROR] CS16_DB_PASSWORD must be 16-128 safe ASCII characters (letters, digits, . _ ~ ! @ # % + = : -)" >&2; exit 1; }
SITE_BASE="/var/www/hyper-host-sites/$DOMAIN"
SITE_PUBLIC="$SITE_BASE/public_html"
BASE="/opt/hyper-cs16"
ETC="/etc/hyper-cs16"
SERVERS="/srv/hyper-cs16/servers"
STEAMCMD="/opt/steamcmd"
STATE="/var/lib/hyper-cs16"
SERVER_STATE="$STATE/servers"
UPLOAD_STAGE="$STATE/uploads"

log(){ printf '\033[1;36m[CS16]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[CS16 ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v hyper-host-ctl >/dev/null 2>&1 || fail 'hyper-host-ctl not found. Install HYPER-HOST first.'
command -v mysql >/dev/null 2>&1 || fail 'MariaDB/MySQL client not found. Run the main HYPER-HOST installer first.'

# Read HYPER-HOST network values, but do not overwrite explicit CS16_PUBLIC_IP.
set +u
[[ -f /etc/hyper-host/hyper-host.conf ]] && source /etc/hyper-host/hyper-host.conf || true
[[ -f /opt/hyper-host/network.env ]] && source /opt/hyper-host/network.env || true
set -u
if [[ -n "$REQUESTED_PUBLIC_IP" ]]; then
  GAME_PUBLIC_IP="$REQUESTED_PUBLIC_IP"
else
  GAME_PUBLIC_IP="${STATIC_PUBLIC_IP:-${SERVER_PUBLIC_IP:-${PUBLIC_IP:-}}}"
fi
if [[ -z "$GAME_PUBLIC_IP" ]]; then
  GAME_PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
fi
[[ -n "$GAME_PUBLIC_IP" ]] || GAME_PUBLIC_IP="127.0.0.1"
python3 - "$GAME_PUBLIC_IP" <<'PYIP' || fail "Invalid public IPv4: $GAME_PUBLIC_IP"
import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1])
assert ip.version==4
PYIP

log "Installing OS dependencies..."
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386 >/dev/null 2>&1 || true
apt-get update --allow-releaseinfo-change
apt-get install -y ca-certificates curl unzip rsync sudo openssl sqlite3 python3 python3-pymysql php-mysql lib32gcc-s1 libc6:i386 libstdc++6:i386 libgcc-s1:i386 >/dev/null

log "Creating service user and directories..."
getent group cs16 >/dev/null 2>&1 || groupadd --system cs16
if ! id cs16 >/dev/null 2>&1; then
  useradd --system --gid cs16 --create-home --home-dir /srv/hyper-cs16 --shell /usr/sbin/nologin cs16
fi
usermod -aG www-data cs16 >/dev/null 2>&1 || true
mkdir -p "$BASE"/{lib,backups} "$ETC" "$SERVERS" "$STEAMCMD"
install -d -o root -g cs16 -m 0750 "$SERVER_STATE"
install -d -o root -g www-data -m 0730 "$UPLOAD_STAGE"
# v1.3+: mutable per-server JSON belongs in /var/lib, never /etc. Migrate legacy configs if present.
if [[ -d "$ETC/servers" ]]; then
  shopt -s nullglob
  for old_cfg in "$ETC/servers"/*.json; do
    base_cfg="$(basename "$old_cfg")"
    [[ -e "$SERVER_STATE/$base_cfg" ]] || cp -a "$old_cfg" "$SERVER_STATE/$base_cfg" || true
  done
  shopt -u nullglob
fi
chown root:cs16 "$SERVER_STATE"
chmod 0750 "$SERVER_STATE"
find "$SERVER_STATE" -maxdepth 1 -type f -name '*.json' -exec chown root:cs16 {} + -exec chmod 0640 {} + 2>/dev/null || true
cat >/etc/tmpfiles.d/hyper-cs16.conf <<EOF
d $UPLOAD_STAGE 0730 root www-data 1h
EOF
chown -R cs16:www-data /srv/hyper-cs16
chmod 2775 /srv/hyper-cs16 "$SERVERS"

log "Installing SteamCMD..."
if [[ ! -x "$STEAMCMD/steamcmd.sh" ]]; then
  tmp="$(mktemp)"
  curl -fL --retry 4 --retry-delay 2 https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o "$tmp"
  tar -xzf "$tmp" -C "$STEAMCMD"
  rm -f "$tmp"
fi
chown -R cs16:cs16 "$STEAMCMD"
chmod +x "$STEAMCMD/steamcmd.sh"

log "Installing CS 1.6 control runtime..."
install -m 0755 "$SRC_DIR/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC_DIR/bin/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0755 "$SRC_DIR/bin/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor
install -m 0644 "$SRC_DIR/lib/csquery.py" "$BASE/lib/csquery.py"
install -m 0644 "$SRC_DIR/systemd/hyper-cs16@.service" /etc/systemd/system/hyper-cs16@.service
install -m 0644 "$SRC_DIR/systemd/hyper-cs16-monitor.service" /etc/systemd/system/hyper-cs16-monitor.service
install -m 0644 "$SRC_DIR/systemd/hyper-cs16-ftp-restore.service" /etc/systemd/system/hyper-cs16-ftp-restore.service

cat >/etc/sudoers.d/hyper-cs16-panel <<'SUDOERS'
# HYPER-HOST CS 1.6 panel: all privileged operations go through a validating controller.
www-data ALL=(root) NOPASSWD: /usr/local/sbin/hyper-cs16-ctl *
SUDOERS
chmod 0440 /etc/sudoers.d/hyper-cs16-panel
visudo -cf /etc/sudoers.d/hyper-cs16-panel >/dev/null || fail 'sudoers validation failed'

log "Creating MariaDB database..."
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
mysql --protocol=socket -uroot "$DB_NAME" < "$SRC_DIR/sql/schema.sql"

log "Preparing panel administrator..."
ADMIN_USER="admin"; ADMIN_HASH=""; GENERATED_ADMIN_PASS=""; IMPORTED_ADMIN=0
HYPER_DB="/opt/hyper-host/data/hyperhost.sqlite"
if [[ -f "$HYPER_DB" ]]; then
  IFS=$'\t' read -r _u _h < <(python3 - "$HYPER_DB" <<'PY' || true
import sqlite3,sys
try:
 c=sqlite3.connect(sys.argv[1]); r=c.execute('SELECT username,password_hash FROM users ORDER BY id LIMIT 1').fetchone()
 if r: print(str(r[0]).replace('\t','')+'\t'+str(r[1]).replace('\t',''))
except Exception: pass
PY
)
  if [[ -n "${_u:-}" && -n "${_h:-}" ]]; then ADMIN_USER="$_u"; ADMIN_HASH="$_h"; IMPORTED_ADMIN=1; fi
fi
if [[ -z "$ADMIN_HASH" ]]; then
  GENERATED_ADMIN_PASS="${CS16_ADMIN_PASSWORD:-$(openssl rand -hex 10)}"
  ADMIN_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$GENERATED_ADMIN_PASS")"
fi
hex(){ printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
UHEX="$(hex "$ADMIN_USER")"; HHEX="$(hex "$ADMIN_HASH")"
mysql --protocol=socket -uroot "$DB_NAME" <<SQL
INSERT INTO users(username,password_hash,role) VALUES(CONVERT(0x$UHEX USING utf8mb4),CONVERT(0x$HHEX USING utf8mb4),'admin')
ON DUPLICATE KEY UPDATE password_hash=VALUES(password_hash),role='admin';
INSERT INTO settings(setting_key,setting_value) VALUES('panel_version','1.2.0') ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value);
SQL

log "Writing runtime configuration..."
cat >"$ETC/panel.php" <<PHP
<?php
return [
  'domain' => '$DOMAIN',
  'public_ip' => '$GAME_PUBLIC_IP',
  'db_host' => '127.0.0.1',
  'db_port' => 3306,
  'db_name' => '$DB_NAME',
  'db_user' => '$DB_USER',
  'db_password' => '$DB_PASS',
];
PHP
chmod 0640 "$ETC/panel.php"; chown root:www-data "$ETC/panel.php"
python3 - "$ETC/runtime.json" "$DOMAIN" "$GAME_PUBLIC_IP" "$DB_NAME" "$DB_USER" "$DB_PASS" <<'PY'
import json,sys
path,domain,ip,dbname,user,pw=sys.argv[1:]
data={'domain':domain,'public_ip':ip,'db_host':'127.0.0.1','db_port':3306,'db_name':dbname,'db_user':user,'db_password':pw,'servers_dir':'/srv/hyper-cs16/servers','base_game_dir':'/srv/hyper-cs16/base-hlds','steamcmd':'/opt/steamcmd/steamcmd.sh'}
open(path,'w',encoding='utf-8').write(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
PY
chmod 0600 "$ETC/runtime.json"
chown root:root "$ETC/runtime.json"

log "Creating $DOMAIN in HYPER-HOST..."
if [[ ! -d "$SITE_PUBLIC" ]]; then
  hyper-host-ctl add-site "$DOMAIN" "" "8.2"
fi
mkdir -p "$SITE_BASE/app" "$SITE_PUBLIC/assets"
rsync -a --delete "$SRC_DIR/app/" "$SITE_BASE/app/"
rsync -a --delete "$SRC_DIR/public/" "$SITE_PUBLIC/"
chown -R www-data:www-data "$SITE_BASE/app" "$SITE_PUBLIC"
find "$SITE_BASE/app" "$SITE_PUBLIC" -type d -exec chmod 0755 {} +
find "$SITE_BASE/app" "$SITE_PUBLIC" -type f -exec chmod 0644 {} +
cat >"$SITE_PUBLIC/.user.ini" <<'PHPINI'
upload_max_filesize=256M
post_max_size=272M
max_execution_time=300
max_input_time=300
PHPINI
chown www-data:www-data "$SITE_PUBLIC/.user.ini"
chmod 0644 "$SITE_PUBLIC/.user.ini"

# Register the site in the main HYPER-HOST SQLite UI if that DB exists.
if [[ -f "$HYPER_DB" ]]; then
  python3 - "$HYPER_DB" "$DOMAIN" "$SITE_PUBLIC" <<'PY' || true
import sqlite3,sys
p,d,r=sys.argv[1:]
try:
 c=sqlite3.connect(p); c.execute("INSERT OR IGNORE INTO sites(domain,aliases,root_path,php_version,disk_limit_mb,ssl_enabled) VALUES(?,?,?,?,0,0)",(d,'',r,'8.2')); c.commit()
except Exception: pass
PY
fi

log "Opening game ports and enabling monitor..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 27015:27100/udp >/dev/null 2>&1 || true
  ufw allow 21/tcp >/dev/null 2>&1 || true
fi
systemctl daemon-reload
systemctl enable --now hyper-cs16-monitor.service >/dev/null 2>&1 || warn 'Monitor will start after MariaDB/network is ready.'
systemctl enable hyper-cs16-ftp-restore.service >/dev/null 2>&1 || true

if [[ "$SKIP_GAME" != "1" ]]; then
  log "Downloading/repairing base Counter-Strike 1.6 via SteamCMD. This can take several passes; do not interrupt it."
  if ! /usr/local/sbin/hyper-cs16-ctl base-install; then
    warn 'Base HLDS download failed. The web panel is installed; retry later with: sudo hyper-cs16-ctl base-install'
  elif [[ "$CREATE_DEFAULT" == "1" ]]; then
    count="$(mysql --protocol=socket -uroot -NBe "SELECT COUNT(*) FROM \`$DB_NAME\`.servers" 2>/dev/null || echo 0)"
    if [[ "${count:-0}" -eq 0 ]]; then
      log "Creating default CS 1.6 server on UDP 27015..."
      mysql --protocol=socket -uroot "$DB_NAME" -e "INSERT INTO servers(name,hostname,public_ip,port,slots,start_map,build_profile,status_cache) VALUES('HYPER-HOST CS 1.6','HYPER-HOST | Counter-Strike 1.6','$GAME_PUBLIC_IP',27015,16,'de_dust2','classic','installing')"
      sid="$(mysql --protocol=socket -uroot -NBe "SELECT LAST_INSERT_ID()" "$DB_NAME")"
      # LAST_INSERT_ID in a new connection is 0; retrieve deterministic newest row.
      sid="$(mysql --protocol=socket -uroot -NBe "SELECT id FROM \`$DB_NAME\`.servers ORDER BY id DESC LIMIT 1")"
      set +e
      result="$(/usr/local/sbin/hyper-cs16-ctl server-create "$sid" --name 'HYPER-HOST CS 1.6' --port 27015 --slots 16 --map de_dust2 --hostname 'HYPER-HOST | Counter-Strike 1.6' --profile classic 2>&1)"; rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        read -r ftp_user ftp_pass < <(printf '%s' "$result" | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j.get("ftp_user",""),j.get("ftp_password",""))')
        FU="$(hex "$ftp_user")"; FP="$(hex "$ftp_pass")"
        mysql --protocol=socket -uroot "$DB_NAME" -e "UPDATE servers SET installed=1,status_cache='starting',ftp_user=CONVERT(0x$FU USING utf8mb4),ftp_password=CONVERT(0x$FP USING utf8mb4) WHERE id=$sid"
      else
        warn "Default server creation failed: $result"
        mysql --protocol=socket -uroot "$DB_NAME" -e "UPDATE servers SET status_cache='failed' WHERE id=$sid" || true
      fi
    fi
  fi
fi

if [[ -n "$SSL_EMAIL" ]]; then
  log "Requesting SSL for $DOMAIN..."
  hyper-host-ctl ssl-site "$DOMAIN" "$SSL_EMAIL" || warn "SSL could not be issued now. Check DNS, then issue SSL from HYPER-HOST."
else
  log "SSL was not requested automatically. Set CS16_SSL_EMAIL=email@example.com when running the installer, or issue SSL from HYPER-HOST after DNS resolves."
fi

systemctl restart hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl start hyper-cs16-ftp-restore.service >/dev/null 2>&1 || true

echo
printf '\033[1;32mHYPER-HOST CS 1.6 PANEL INSTALLED\033[0m\n'
printf 'Panel:      http://%s\n' "$DOMAIN"
printf 'Public IP:  %s\n' "$GAME_PUBLIC_IP"
printf 'Game ports: UDP 27015-27100\n'
printf 'FTP:        %s:21\n' "$GAME_PUBLIC_IP"
printf 'Login:      %s\n' "$ADMIN_USER"
if [[ "$IMPORTED_ADMIN" == "1" ]]; then
  printf 'Password:   same as the main HYPER-HOST panel\n'
else
  printf 'Password:   %s\n' "$GENERATED_ADMIN_PASS"
fi
printf '\nIf the server is behind a router/NAT, forward UDP 27015-27100 to this Ubuntu host.\n'
printf 'Diagnostics: sudo hyper-cs16-ctl doctor\n'
printf 'Base reinstall: sudo hyper-cs16-ctl base-install\n'
