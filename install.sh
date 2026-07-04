#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_NAME="HYPER-HOST"
POWERED_BY="powered by memes4u1337"
BASE_DIR="/opt/hyper-host"
PANEL_DIR="/var/www/hyper-host"
SITES_DIR="/var/www/hyper-host-sites"
BOTS_DIR="/var/www/hyper-host-bots"
CONF_DIR="/etc/hyper-host"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
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

SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
PANEL_DOMAIN="${PANEL_DOMAIN:-_}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 18 | tr -d '\n')}"
PMA_APP_PASS="$(openssl rand -base64 24 | tr -d '\n')"

export DEBIAN_FRONTEND=noninteractive

log "Установка системных пакетов..."
apt-get update -y
apt-get install -y \
  ca-certificates curl git unzip rsync sudo openssl ufw \
  nginx mariadb-server \
  php-fpm php-cli php-sqlite3 php-mysql php-curl php-mbstring php-xml php-zip php-gd \
  vsftpd certbot python3-certbot-nginx python3 python3-venv python3-pip nodejs npm

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
mkdir -p "$BASE_DIR/data" "$BASE_DIR/templates" "$PANEL_DIR" "$SITES_DIR" "$BOTS_DIR" "$CONF_DIR"

log "Копирование файлов панели..."
rsync -a --delete "$PROJECT_DIR/src/" "$PANEL_DIR/"
rsync -a --delete "$PROJECT_DIR/templates/" "$BASE_DIR/templates/"
install -m 0755 "$PROJECT_DIR/scripts/hhctl" "$CONTROL_BIN"

log "Создание конфигурации HYPER-HOST..."
cat > "$CONF_DIR/hyper-host.conf" <<EOCONF
PANEL_NAME="${PANEL_NAME}"
POWERED_BY="${POWERED_BY}"
SERVER_IP="${SERVER_IP}"
PANEL_DOMAIN="${PANEL_DOMAIN}"
BASE_DIR="${BASE_DIR}"
PANEL_DIR="${PANEL_DIR}"
SITES_DIR="${SITES_DIR}"
BOTS_DIR="${BOTS_DIR}"
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
    'base_dir' => '${BASE_DIR}',
    'panel_dir' => '${PANEL_DIR}',
    'sites_dir' => '${SITES_DIR}',
    'bots_dir' => '${BOTS_DIR}',
    'db_path' => '${BASE_DIR}/data/hyperhost.sqlite',
    'php_fpm_sock' => '${PHP_FPM_SOCK}',
    'phpmyadmin_path' => '/usr/share/phpmyadmin',
];
EOPHP
chmod 0640 "$PANEL_DIR/app/config.php"

log "Настройка пользователей и прав..."
if ! id hyperbot >/dev/null 2>&1; then
  useradd --system --home "$BOTS_DIR" --shell /usr/sbin/nologin hyperbot
fi
usermod -aG www-data hyperbot || true
chown -R www-data:www-data "$PANEL_DIR"
chown -R www-data:www-data "$BASE_DIR/data"
chown -R www-data:www-data "$SITES_DIR"
chown -R hyperbot:www-data "$BOTS_DIR"
chmod 0755 "$SITES_DIR" "$BOTS_DIR"
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
EOSUDO
chmod 0440 /etc/sudoers.d/hyper-host
visudo -cf /etc/sudoers.d/hyper-host >/dev/null || fail "Ошибка sudoers-конфига"

log "Настройка Nginx для панели..."
cat > /etc/nginx/sites-available/hyper-host-panel.conf <<EONGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${PANEL_DOMAIN};

    root ${PANEL_DIR}/public;
    index index.php index.html;
    client_max_body_size 256M;

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
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~ ^/phpmyadmin/(.+)$ {
        alias /usr/share/phpmyadmin/\$1;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
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
cp /etc/vsftpd.conf "/etc/vsftpd.conf.backup.$(date +%s)" 2>/dev/null || true
cat > /etc/vsftpd.conf <<EOFTP
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
ssl_enable=NO
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
pasv_address=${SERVER_IP}
EOFTP
systemctl enable vsftpd >/dev/null 2>&1 || true
systemctl restart vsftpd

log "Запуск MariaDB и PHP-FPM..."
systemctl enable mariadb >/dev/null 2>&1 || true
systemctl restart mariadb
systemctl enable "php${PHP_VER}-fpm" >/dev/null 2>&1 || true
systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true

log "Настройка firewall..."
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 21/tcp >/dev/null 2>&1 || true
ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
# 3306 открывается через настройки панели, когда включаешь внешние подключения.

log "Финальный ремонт прав и сервисов..."
/usr/local/sbin/hyper-host-ctl repair >/dev/null || warn "Repair-команда не выполнилась, проверь вручную: sudo hyper-host-ctl repair"

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
 phpMyAdmin:   http://${SERVER_IP}/phpmyadmin

 ВАЖНО: сохрани пароль сейчас.
============================================================
EOF_DONE
