#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_NAME="HYPER-HOST"
POWERED_BY="powered by memes4u1337"
BASE_DIR="/opt/hyper-host"
PANEL_DIR="/var/www/hyper-host"
SITES_DIR="/var/www/hyper-host-sites"
BOTS_DIR="/var/www/hyper-host-bots"
FTP_DIR="/var/www/hyper-host-ftp"
BACKUP_DIR="/opt/hyper-host/backups"
CACHE_DIR="/opt/hyper-host/cache"
DNS_DIR="/etc/bind/hyper-host-zones"
CONF_DIR="/etc/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
HYPER_FTP_BIN="/usr/local/sbin/hyper-host-ftp-server"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[HYPER-HOST] Запусти установщик от root: sudo bash install.sh"
  exit 1
fi

log() { echo -e "\033[1;36m[HYPER-HOST]\033[0m $*"; }
warn() { echo -e "\033[1;33m[HYPER-HOST WARNING]\033[0m $*"; }
fail() { echo -e "\033[1;31m[HYPER-HOST ERROR]\033[0m $*"; exit 1; }

get_server_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="127.0.0.1"
  fi
  echo "$ip"
}

# Preserve existing settings on updates. Older installers overwrote PANEL_DOMAIN/PUBLIC_IP
# and panel.hyper-host.pw could become a normal site again after every update.
if [[ -f "$CONF_DIR/hyper-host.conf" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_DIR/hyper-host.conf" || true
fi
SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
PUBLIC_IP="${PUBLIC_IP:-${SERVER_PUBLIC_IP:-}}"
PANEL_DOMAIN="${PANEL_DOMAIN:-_}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 18 | tr -d '\n')}"
PMA_APP_PASS="$(openssl rand -base64 24 | tr -d '\n')"

export DEBIAN_FRONTEND=noninteractive


cleanup_hyper_host_mounts() {
  local mp pass
  for pass in 1 2 3 4 5; do
    mapfile -t _hh_bad_mounts < <(
      awk '{print $5}' /proc/self/mountinfo 2>/dev/null         | sed 's/\040/ /g'         | grep -E '^/var/www/hyper-host-(ftp|sites)/'         | grep -E '/(common|sites|bots|site)(/|$)'         | sort -r || true
    )
    [[ ${#_hh_bad_mounts[@]} -eq 0 ]] && break
    for mp in "${_hh_bad_mounts[@]}"; do
      case "$mp" in
        "/"|"/var"|"/var/www"|"$SITES_DIR"|"$BOTS_DIR"|"$FTP_DIR") continue ;;
      esac
      umount -lf "$mp" 2>/dev/null || true
    done
  done
  if [[ -f /etc/fstab ]]; then
    sed -i.bak -E '/hyper-host-ftp|hyper-host-sites\/.*\/(common|sites|bots|site)|public_html\/(common|sites|bots|site)/d' /etc/fstab 2>/dev/null || true
  fi
}

safe_chown_tree() {
  local owner="$1" path="$2"
  [[ -e "$path" ]] || return 0
  cleanup_hyper_host_mounts
  find "$path" -xdev -exec chown -h "$owner" {} + 2>/dev/null || true
}


sql_quote() {
  printf "%s" "$1" | sed "s/'/''/g"
}

install_php_versions() {
  log "Установка PHP-FPM версий для сайтов..."
  apt-get install -y software-properties-common apt-transport-https lsb-release >/dev/null 2>&1 || true
  if ! apt-cache show php8.4-fpm >/dev/null 2>&1; then
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 && apt-get update -y || warn "PPA ondrej/php недоступен, будут установлены только версии PHP из текущих репозиториев"
  fi
  local v pkgs pkg
  for v in 8.1 8.2 8.3 8.4; do
    pkgs=("php${v}-fpm" "php${v}-cli" "php${v}-mysql" "php${v}-sqlite3" "php${v}-curl" "php${v}-mbstring" "php${v}-xml" "php${v}-zip" "php${v}-gd" "php${v}-intl" "php${v}-bcmath" "php${v}-soap" "php${v}-readline")
    if apt-cache show "php${v}-fpm" >/dev/null 2>&1; then
      apt-get install -y "${pkgs[@]}" || warn "Не удалось полностью установить PHP ${v}. Продолжаю установку."
      systemctl enable "php${v}-fpm" >/dev/null 2>&1 || true
      systemctl restart "php${v}-fpm" >/dev/null 2>&1 || true
    fi
  done
}

configure_php_limits() {
  log "Настройка больших загрузок PHP/phpMyAdmin..."
  local dir fpm
  for dir in /etc/php/*/fpm/conf.d /etc/php/*/cli/conf.d; do
    [[ -d "$dir" ]] || continue
    cat > "$dir/99-hyper-host-limits.ini" <<'EOINI'
; HYPER-HOST upload/export limits
file_uploads = On
upload_max_filesize = 1024M
post_max_size = 1024M
memory_limit = 1024M
max_execution_time = 600
max_input_time = 600
max_file_uploads = 100
max_input_vars = 10000
EOINI
  done
  for fpm in php*-fpm; do
    systemctl restart "$fpm" >/dev/null 2>&1 || true
  done
}

configure_phpmyadmin_storage() {
  log "Настройка хранилища конфигурации phpMyAdmin..."
  mkdir -p /etc/phpmyadmin/conf.d /var/lib/phpmyadmin/tmp /etc/hyper-host
  chown -R www-data:www-data /var/lib/phpmyadmin/tmp 2>/dev/null || true
  chmod 0770 /var/lib/phpmyadmin/tmp 2>/dev/null || true
  local pass secret_file sqlpass create_sql
  secret_file=/etc/hyper-host/phpmyadmin-control.secret
  if [[ -f "$secret_file" ]]; then
    pass="$(cat "$secret_file" 2>/dev/null || true)"
  fi
  if [[ -z "${pass:-}" ]]; then
    pass="$(openssl rand -base64 30 | tr -d '\n')"
    printf '%s' "$pass" > "$secret_file"
    chmod 0600 "$secret_file"
  fi
  sqlpass="$(sql_quote "$pass")"
  mysql --protocol=socket -uroot <<EOSQL >/dev/null 2>&1 || true
CREATE DATABASE IF NOT EXISTS phpmyadmin DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'pma'@'localhost' IDENTIFIED BY '${sqlpass}';
ALTER USER 'pma'@'localhost' IDENTIFIED BY '${sqlpass}';
GRANT SELECT, INSERT, UPDATE, DELETE ON phpmyadmin.* TO 'pma'@'localhost';
FLUSH PRIVILEGES;
EOSQL
  create_sql="/usr/share/phpmyadmin/sql/create_tables.sql"
  if [[ -f "$create_sql" ]]; then
    mysql --protocol=socket -uroot phpmyadmin < "$create_sql" >/dev/null 2>&1 || true
  fi
  cat > /etc/phpmyadmin/conf.d/hyper-host-storage.php <<EOPMASTORE
<?php
// HYPER-HOST: phpMyAdmin advanced configuration storage + large import/export.
\$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['ExecTimeLimit'] = 0;
\$cfg['MemoryLimit'] = '1024M';
if (isset(\$i) && isset(\$cfg['Servers'][\$i])) {
    \$cfg['Servers'][\$i]['pmadb'] = 'phpmyadmin';
    \$cfg['Servers'][\$i]['controlhost'] = 'localhost';
    \$cfg['Servers'][\$i]['controluser'] = 'pma';
    \$cfg['Servers'][\$i]['controlpass'] = '${pass}';
    \$cfg['Servers'][\$i]['bookmarktable'] = 'pma__bookmark';
    \$cfg['Servers'][\$i]['relation'] = 'pma__relation';
    \$cfg['Servers'][\$i]['table_info'] = 'pma__table_info';
    \$cfg['Servers'][\$i]['table_coords'] = 'pma__table_coords';
    \$cfg['Servers'][\$i]['pdf_pages'] = 'pma__pdf_pages';
    \$cfg['Servers'][\$i]['column_info'] = 'pma__column_info';
    \$cfg['Servers'][\$i]['history'] = 'pma__history';
    \$cfg['Servers'][\$i]['table_uiprefs'] = 'pma__table_uiprefs';
    \$cfg['Servers'][\$i]['tracking'] = 'pma__tracking';
    \$cfg['Servers'][\$i]['userconfig'] = 'pma__userconfig';
    \$cfg['Servers'][\$i]['recent'] = 'pma__recent';
    \$cfg['Servers'][\$i]['favorite'] = 'pma__favorite';
    \$cfg['Servers'][\$i]['users'] = 'pma__users';
    \$cfg['Servers'][\$i]['usergroups'] = 'pma__usergroups';
    \$cfg['Servers'][\$i]['navigationhiding'] = 'pma__navigationhiding';
    \$cfg['Servers'][\$i]['savedsearches'] = 'pma__savedsearches';
    \$cfg['Servers'][\$i]['central_columns'] = 'pma__central_columns';
    \$cfg['Servers'][\$i]['designer_settings'] = 'pma__designer_settings';
    \$cfg['Servers'][\$i]['export_templates'] = 'pma__export_templates';
}
EOPMASTORE
  chmod 0644 /etc/phpmyadmin/conf.d/hyper-host-storage.php || true
}

ensure_nologin_shell() {
  if [[ -x /usr/sbin/nologin ]] && ! grep -qxF /usr/sbin/nologin /etc/shells 2>/dev/null; then
    echo /usr/sbin/nologin >> /etc/shells 2>/dev/null || true
  fi
  if [[ -x /bin/false ]] && ! grep -qxF /bin/false /etc/shells 2>/dev/null; then
    echo /bin/false >> /etc/shells 2>/dev/null || true
  fi
}


log "Установка системных пакетов..."
apt-get update -y
apt-get install -y \
  ca-certificates curl git unzip rsync sudo openssl ufw software-properties-common apt-transport-https lsb-release \
  nginx mariadb-server \
  php-fpm php-cli php-sqlite3 php-mysql php-curl php-mbstring php-xml php-zip php-gd \
  vsftpd openssh-server certbot python3-certbot-nginx python3 python3-venv python3-pip acl cron bind9 dnsutils whois db-util

install_php_versions

log "Установка phpMyAdmin..."
if ! dpkg -s phpmyadmin >/dev/null 2>&1; then
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none" | debconf-set-selections || true
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections || true
  echo "phpmyadmin phpmyadmin/mysql/admin-pass password" | debconf-set-selections || true
  echo "phpmyadmin phpmyadmin/mysql/app-pass password ${PMA_APP_PASS}" | debconf-set-selections || true
  echo "phpmyadmin phpmyadmin/app-password-confirm password ${PMA_APP_PASS}" | debconf-set-selections || true
  apt-get install -y phpmyadmin || warn "phpMyAdmin не установился через apt. Панель продолжит установку, можно поставить phpmyadmin позже."
fi

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.1")"
PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
if [[ ! -S "$PHP_FPM_SOCK" ]]; then
  PHP_FPM_SOCK="$(find /run/php -maxdepth 1 -name 'php*-fpm.sock' 2>/dev/null | head -n1 || true)"
fi
[[ -n "$PHP_FPM_SOCK" ]] || fail "Не найден PHP-FPM socket. Проверь установку php-fpm."

log "Создание папок..."
mkdir -p "$BASE_DIR/data" "$BASE_DIR/templates" "$BACKUP_DIR" "$CACHE_DIR" "$PANEL_DIR" "$SITES_DIR" "$BOTS_DIR" "$FTP_DIR" "$DNS_DIR" "$CONF_DIR"

log "Очистка старых сломанных FTP bind-mount'ов..."
cleanup_hyper_host_mounts

log "Копирование файлов панели..."
rsync -a --delete "$PROJECT_DIR/src/" "$PANEL_DIR/"
rsync -a --delete "$PROJECT_DIR/templates/" "$BASE_DIR/templates/"
install -m 0755 "$PROJECT_DIR/scripts/hhctl" "$CONTROL_BIN"
install -m 0755 "$PROJECT_DIR/scripts/hyper" "$HYPER_BIN"
install -m 0755 "$PROJECT_DIR/scripts/hyper_ftp_server.py" "$HYPER_FTP_BIN"
# v23: делаем CLI доступным для панели, PM2-ботов и обычной shell-среды.
# Некоторые окружения/боты ищут hyper в /usr/local/bin или /usr/bin.
ln -sf "$HYPER_BIN" /usr/bin/hyper 2>/dev/null || true
ln -sf "$CONTROL_BIN" /usr/bin/hyper-host-ctl 2>/dev/null || true
chmod 0755 "$CONTROL_BIN" "$HYPER_BIN" "$HYPER_FTP_BIN" /usr/bin/hyper /usr/bin/hyper-host-ctl 2>/dev/null || true

log "Создание конфигурации HYPER-HOST..."
cat > "$CONF_DIR/hyper-host.conf" <<EOCONF
PANEL_NAME="${PANEL_NAME}"
POWERED_BY="${POWERED_BY}"
SERVER_IP="${SERVER_IP}"
PANEL_DOMAIN="${PANEL_DOMAIN}"
PUBLIC_IP="${PUBLIC_IP}"
BASE_DIR="${BASE_DIR}"
PANEL_DIR="${PANEL_DIR}"
SITES_DIR="${SITES_DIR}"
BOTS_DIR="${BOTS_DIR}"
FTP_DIR="${FTP_DIR}"
BACKUP_DIR="${BACKUP_DIR}"
CACHE_DIR="${CACHE_DIR}"
DNS_DIR="${DNS_DIR}"
PHP_FPM_SOCK="${PHP_FPM_SOCK}"
PHPMYADMIN_PATH="/usr/share/phpmyadmin"
EOCONF
chmod 0644 "$CONF_DIR/hyper-host.conf"

cat > "$PANEL_DIR/app/config.php" <<EOPHP
<?php
return [
    'panel_name' => '${PANEL_NAME}',
    'powered_by' => '${POWERED_BY}',
    'server_ip' => '${SERVER_IP}',
    'panel_domain' => '${PANEL_DOMAIN}',
    'public_ip' => '${PUBLIC_IP}',
    'base_dir' => '${BASE_DIR}',
    'panel_dir' => '${PANEL_DIR}',
    'sites_dir' => '${SITES_DIR}',
    'bots_dir' => '${BOTS_DIR}',
    'ftp_dir' => '${FTP_DIR}',
    'backup_dir' => '${BACKUP_DIR}',
    'cache_dir' => '${CACHE_DIR}',
    'dns_dir' => '${DNS_DIR}',
    'db_path' => '${BASE_DIR}/data/hyperhost.sqlite',
    'php_fpm_sock' => '${PHP_FPM_SOCK}',
    'phpmyadmin_path' => '/usr/share/phpmyadmin',
];
EOPHP
chmod 0640 "$PANEL_DIR/app/config.php"


log "Настройка phpMyAdmin host label..."
mkdir -p /etc/phpmyadmin/conf.d
PMA_VERBOSE_HOST="${PANEL_DOMAIN}"
if [[ -z "$PMA_VERBOSE_HOST" || "$PMA_VERBOSE_HOST" == "_" ]]; then
  PMA_VERBOSE_HOST="${PUBLIC_IP:-${SERVER_IP}}"
fi
cat > /etc/phpmyadmin/conf.d/hyper-host-server.php <<EOPMA
<?php
// HYPER-HOST: phpMyAdmin показывает понятное имя сервера вместо localhost:3306.
if (isset(\$i)) {
    \$cfg['Servers'][\$i]['verbose'] = '${PMA_VERBOSE_HOST}:3306';
    \$cfg['Servers'][\$i]['host'] = '127.0.0.1';
    \$cfg['Servers'][\$i]['port'] = '3306';
}
EOPMA
chmod 0644 /etc/phpmyadmin/conf.d/hyper-host-server.php || true
configure_php_limits
configure_phpmyadmin_storage


log "Настройка пользователей и прав..."
if ! id hyperbot >/dev/null 2>&1; then
  useradd --system --home "$BOTS_DIR" --shell /usr/sbin/nologin hyperbot
fi
ensure_nologin_shell
usermod -d "$BOTS_DIR" -s /usr/sbin/nologin hyperbot || true
usermod -aG www-data hyperbot || true
safe_chown_tree www-data:www-data "$PANEL_DIR"
safe_chown_tree www-data:www-data "$BASE_DIR/data"
safe_chown_tree www-data:www-data "$CACHE_DIR"
safe_chown_tree www-data:www-data "$SITES_DIR"
chown root:root "$FTP_DIR" "$BACKUP_DIR"
safe_chown_tree hyperbot:www-data "$BOTS_DIR"
chmod 0755 "$SITES_DIR" "$BOTS_DIR" "$FTP_DIR" "$BACKUP_DIR"
chmod 0770 "$BASE_DIR/data"

log "Инициализация базы панели..."
php "$PANEL_DIR/app/setup_db.php" "$ADMIN_USER" "$ADMIN_PASS"
chown www-data:www-data "$BASE_DIR/data/hyperhost.sqlite"
chmod 0660 "$BASE_DIR/data/hyperhost.sqlite"
chown www-data:www-data "$BASE_DIR/data/hyperhost.sqlite"-* 2>/dev/null || true
chmod 0660 "$BASE_DIR/data/hyperhost.sqlite"-* 2>/dev/null || true

log "Настройка sudo для панели..."
cat > /etc/sudoers.d/hyper-host <<EOSUDO
www-data ALL=(root) NOPASSWD: ${CONTROL_BIN} *
www-data ALL=(root) NOPASSWD: ${HYPER_BIN} *
EOSUDO
chmod 0440 /etc/sudoers.d/hyper-host
visudo -cf /etc/sudoers.d/hyper-host >/dev/null || fail "Ошибка sudoers-конфига"

log "Настройка Nginx для панели..."
cat > /etc/nginx/sites-available/hyper-host-panel.conf <<EONGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${PANEL_DOMAIN} _;

    root ${PANEL_DIR}/public;
    index index.php index.html;
    client_max_body_size 1024M;

    access_log /var/log/nginx/hyper-host-panel.access.log;
    error_log /var/log/nginx/hyper-host-panel.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location /phpmyadmin {
        alias /usr/share/phpmyadmin/;
        index index.php index.html;
    }

    location ~ ^/phpmyadmin/(.+\.php)$ {
        alias /usr/share/phpmyadmin/\$1;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/\$1;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~ ^/phpmyadmin/(.+)$ {
        alias /usr/share/phpmyadmin/\$1;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~ /\. {
        deny all;
    }
}
EONGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/hyper-host-panel.conf /etc/nginx/sites-enabled/hyper-host-panel.conf
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx

log "Настройка FTP..."
FTP_USER_CONF_DIR="$BASE_DIR/ftp/user_conf"
FTP_AUTH_TXT="$BASE_DIR/data/vsftpd_virtual_users.txt"
FTP_GUEST_USER="www-data"
mkdir -p "$FTP_DIR" "$BASE_DIR/data" "$BASE_DIR/ftp" "$FTP_USER_CONF_DIR" "$BASE_DIR/run" /var/log
[[ -f "$FTP_AUTH_TXT" ]] || touch "$FTP_AUTH_TXT"
chmod 0600 "$FTP_AUTH_TXT" 2>/dev/null || true
chmod 0755 "$FTP_DIR" "$FTP_USER_CONF_DIR" 2>/dev/null || true

# v44: FTP обслуживает встроенный HYPER-HOST FTP server.
# Он не использует /etc/passwd, /etc/fstab, PAM, useradd и не зависит от vsftpd.
# v45: mask, а не только stop/disable — иначе случайный "systemctl restart vsftpd"
# в чьём-нибудь deploy-скрипте снова поднимет vsftpd на порту 21 и он будет драться
# за порт с hyper-host-ftp.service.
systemctl stop vsftpd >/dev/null 2>&1 || true
systemctl disable vsftpd >/dev/null 2>&1 || true
systemctl mask vsftpd >/dev/null 2>&1 || true

start_hyper_ftp_runtime_install() {
  pkill -f "hyper_ftp_server.py|hyper-host-ftp-server" >/dev/null 2>&1 || true
  nohup "$HYPER_FTP_BIN" --host 0.0.0.0 --port 21 --passive-min 40000 --passive-max 40100 >>/var/log/hyper-host-ftp.log 2>&1 &
  echo $! > "$BASE_DIR/run/hyper-host-ftp.pid" 2>/dev/null || true
}

if [[ -d /etc/systemd/system && -w /etc/systemd/system ]]; then
  cat > /tmp/hyper-host-ftp.service.$$ <<EOSVC
[Unit]
Description=HYPER-HOST FTP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HYPER_HOST_CONF=$CONF_DIR/hyper-host.conf
ExecStart=$HYPER_FTP_BIN --host 0.0.0.0 --port 21 --passive-min 40000 --passive-max 40100
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOSVC
  if cat /tmp/hyper-host-ftp.service.$$ > /etc/systemd/system/hyper-host-ftp.service 2>/dev/null; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable hyper-host-ftp.service >/dev/null 2>&1 || true
    systemctl restart hyper-host-ftp.service >/dev/null 2>&1 || true
  else
    start_hyper_ftp_runtime_install
  fi
  rm -f /tmp/hyper-host-ftp.service.$$ 2>/dev/null || true
else
  start_hyper_ftp_runtime_install
fi

sleep 1
if ! ss -ltn 2>/dev/null | grep -q ':21 '; then
  start_hyper_ftp_runtime_install
  sleep 1
fi

ufw allow 21/tcp >/dev/null 2>&1 || true
ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
iptables -C INPUT -p tcp --dport 21 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 21 -j ACCEPT 2>/dev/null || true
iptables -C INPUT -p tcp --match multiport --dports 40000:40100 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --match multiport --dports 40000:40100 -j ACCEPT 2>/dev/null || true

systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true


log "Настройка Node.js + PM2 для ботов 24/7..."
node_major() { node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 | grep -E '^[0-9]+$' || echo 0; }
fix_node_packages() {
  dpkg --configure -a >/tmp/hyper-host-dpkg-configure.log 2>&1 || true
  apt-get -f install -y >/tmp/hyper-host-apt-fix.log 2>&1 || true
  local major; major="$(node_major)"
  if [[ "$major" -lt 18 ]]; then
    log "Node.js старый или сломан: $(node -v 2>/dev/null || echo none). Чищу старые node/npm/libnode-dev и ставлю Node.js 20.x..."
    apt-get remove -y npm nodejs libnode-dev libnode72 node-gyp nodejs-doc >/tmp/hyper-host-node-remove.log 2>&1 || true
    dpkg --remove --force-all libnode-dev libnode72 npm nodejs node-gyp nodejs-doc >/tmp/hyper-host-node-dpkg-remove.log 2>&1 || true
    apt-get autoremove -y >/tmp/hyper-host-node-autoremove.log 2>&1 || true
    rm -f /etc/apt/sources.list.d/nodesource*.list /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
    apt-get install -y curl ca-certificates gnupg >/dev/null 2>&1 || true
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/tmp/hyper-host-nodesource.log 2>&1 || warn "NodeSource setup не отработал. Лог: /tmp/hyper-host-nodesource.log"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y nodejs >/tmp/hyper-host-node-install.log 2>&1 || {
      warn "Node.js 20 не установился. Лог: /tmp/hyper-host-node-install.log. Пробую дополнительно очистить libnode-dev/libnode72."
      dpkg --remove --force-all libnode-dev libnode72 npm nodejs node-gyp nodejs-doc >/tmp/hyper-host-node-dpkg-force.log 2>&1 || true
      apt-get -f install -y >/tmp/hyper-host-apt-fix-2.log 2>&1 || true
      apt-get install -y nodejs >>/tmp/hyper-host-node-install.log 2>&1 || apt-get install -y nodejs npm || true
    }
  fi
}
fix_node_packages
if ! command -v npm >/dev/null 2>&1; then
  apt-get install -y npm || true
fi
if command -v npm >/dev/null 2>&1 && ! command -v pm2 >/dev/null 2>&1; then
  npm install -g pm2@latest || warn "PM2 не установился через npm. Проверь Node/NPM."
fi
mkdir -p "$BOTS_DIR/.pm2"
safe_chown_tree hyperbot:www-data "$BOTS_DIR"
chmod 2775 "$BOTS_DIR" "$BOTS_DIR/.pm2" 2>/dev/null || true
if command -v pm2 >/dev/null 2>&1; then
  sudo -u hyperbot -H env HOME="$BOTS_DIR" PM2_HOME="$BOTS_DIR/.pm2" PATH="/usr/local/bin:/usr/bin:/bin" pm2 ping >/dev/null 2>&1 || true
  sudo -u hyperbot -H env HOME="$BOTS_DIR" PM2_HOME="$BOTS_DIR/.pm2" PATH="/usr/local/bin:/usr/bin:/bin" pm2 save --force >/dev/null 2>&1 || sudo -u hyperbot -H env HOME="$BOTS_DIR" PM2_HOME="$BOTS_DIR/.pm2" PATH="/usr/local/bin:/usr/bin:/bin" pm2 save >/dev/null 2>&1 || true
  "$CONTROL_BIN" pm2-persist >/dev/null 2>&1 || warn "PM2 autostart не включился автоматически. Проверь вручную: sudo hyper-host-ctl pm2-persist"
fi

log "Настройка DNS сервиса bind9..."
cat > /etc/bind/named.conf.options <<'EOBINDOPT'
options {
    directory "/var/cache/bind";
    listen-on { any; };
    listen-on-v6 { any; };
    allow-query { any; };
    allow-recursion { none; };
    recursion no;
    dnssec-validation auto;
    auth-nxdomain no;
    minimal-responses yes;
};
EOBINDOPT
touch /etc/bind/named.conf.local
systemctl enable bind9 >/dev/null 2>&1 || true
systemctl restart bind9 2>/dev/null || true

log "Запуск MariaDB и PHP-FPM..."
systemctl enable mariadb >/dev/null 2>&1 || true
systemctl restart mariadb
systemctl enable "php${PHP_VER}-fpm" >/dev/null 2>&1 || true
systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true
systemctl enable cron >/dev/null 2>&1 || true
systemctl restart cron 2>/dev/null || true

log "Настройка firewall..."
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 53/tcp >/dev/null 2>&1 || true
ufw allow 53/udp >/dev/null 2>&1 || true
ufw allow 21/tcp >/dev/null 2>&1 || true
ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=21/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=40000-40100/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=53/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=53/udp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
if command -v nft >/dev/null 2>&1; then
  nft add table inet hyper_host 2>/dev/null || true
  nft 'add chain inet hyper_host input { type filter hook input priority -100; policy accept; }' 2>/dev/null || true
  nft add rule inet hyper_host input tcp dport '{ 21, 22, 53, 80, 443 }' accept 2>/dev/null || true
  nft add rule inet hyper_host input tcp dport 40000-40100 accept 2>/dev/null || true
  nft add rule inet hyper_host input udp dport 53 accept 2>/dev/null || true
fi
# 3306 открывается через настройки панели, когда включаешь внешние подключения.

log "Финальный ремонт прав и сервисов..."
/usr/local/sbin/hyper-host-ctl repair >/dev/null || warn "Repair-команда не выполнилась, проверь вручную: sudo hyper-host-ctl repair"
/usr/local/sbin/hyper-host-ctl network-fix "${PANEL_DOMAIN}" "${PUBLIC_IP}" >/dev/null 2>&1 || true

log "Проверка панели..."
php -l "$PANEL_DIR/public/index.php" >/dev/null
php -l "$PANEL_DIR/app/bootstrap.php" >/dev/null

cat <<EOF_DONE

============================================================
 ${PANEL_NAME} установлен
 ${POWERED_BY}
============================================================
 URL:      http://${SERVER_IP}/
 Login:    ${ADMIN_USER}
 Password: ${ADMIN_PASS}
 IP:       ${SERVER_IP}

 Файлы сайтов: ${SITES_DIR}
 Файлы ботов:  ${BOTS_DIR}
 FTP папки:     ${FTP_DIR}
 Backup:       ${BACKUP_DIR}
 phpMyAdmin:   http://${SERVER_IP}/phpmyadmin

 ВАЖНО: сохрани пароль сейчас.
============================================================
EOF_DONE
