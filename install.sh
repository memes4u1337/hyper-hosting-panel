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
DNS_DIR="/etc/bind/hyper-host-zones"
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
ensure_nologin_shell() {
  if [[ -x /usr/sbin/nologin ]] && ! grep -qxF /usr/sbin/nologin /etc/shells 2>/dev/null; then
    echo /usr/sbin/nologin >> /etc/shells
  fi
  if [[ -x /bin/false ]] && ! grep -qxF /bin/false /etc/shells 2>/dev/null; then
    echo /bin/false >> /etc/shells
  fi
}


log "Установка системных пакетов..."
apt-get update -y
apt-get install -y \
  ca-certificates curl git unzip rsync sudo openssl ufw \
  nginx mariadb-server \
  php-fpm php-cli php-sqlite3 php-mysql php-curl php-mbstring php-xml php-zip php-gd \
  vsftpd certbot python3-certbot-nginx python3 python3-venv python3-pip acl cron bind9 dnsutils

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
mkdir -p "$BASE_DIR/data" "$BASE_DIR/templates" "$BACKUP_DIR" "$PANEL_DIR" "$SITES_DIR" "$BOTS_DIR" "$FTP_DIR" "$DNS_DIR" "$CONF_DIR"

log "Очистка старых сломанных FTP bind-mount'ов..."
cleanup_hyper_host_mounts

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
FTP_DIR="${FTP_DIR}"
BACKUP_DIR="${BACKUP_DIR}"
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
    'base_dir' => '${BASE_DIR}',
    'panel_dir' => '${PANEL_DIR}',
    'sites_dir' => '${SITES_DIR}',
    'bots_dir' => '${BOTS_DIR}',
    'ftp_dir' => '${FTP_DIR}',
    'backup_dir' => '${BACKUP_DIR}',
    'dns_dir' => '${DNS_DIR}',
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
ensure_nologin_shell
usermod -d "$BOTS_DIR" -s /usr/sbin/nologin hyperbot || true
usermod -aG www-data hyperbot || true
safe_chown_tree www-data:www-data "$PANEL_DIR"
safe_chown_tree www-data:www-data "$BASE_DIR/data"
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
force_dot_files=YES
utf8_filesystem=YES
EOFTP
systemctl enable vsftpd >/dev/null 2>&1 || true
systemctl restart vsftpd

log "Настройка Node.js + PM2 для ботов 24/7..."
node_major() { node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 | grep -E '^[0-9]+$' || echo 0; }
fix_node_packages() {
  dpkg --configure -a >/tmp/hyper-host-dpkg-configure.log 2>&1 || true
  apt-get -f install -y >/tmp/hyper-host-apt-fix.log 2>&1 || true
  local major; major="$(node_major)"
  if [[ "$major" -lt 18 ]]; then
    log "Node.js старый или сломан: $(node -v 2>/dev/null || echo none). Чищу старые node/npm/libnode-dev и ставлю Node.js 20.x..."
    apt-get remove -y npm nodejs libnode-dev node-gyp nodejs-doc >/tmp/hyper-host-node-remove.log 2>&1 || true
    apt-get autoremove -y >/tmp/hyper-host-node-autoremove.log 2>&1 || true
    rm -f /etc/apt/sources.list.d/nodesource*.list /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
    apt-get install -y curl ca-certificates gnupg >/dev/null 2>&1 || true
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/tmp/hyper-host-nodesource.log 2>&1 || warn "NodeSource setup не отработал. Лог: /tmp/hyper-host-nodesource.log"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y nodejs >/tmp/hyper-host-node-install.log 2>&1 || {
      warn "Node.js 20 не установился. Лог: /tmp/hyper-host-node-install.log. Пробую fallback apt nodejs/npm."
      apt-get install -y nodejs npm || true
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
  sudo -u hyperbot -H env HOME="$BOTS_DIR" PM2_HOME="$BOTS_DIR/.pm2" PATH="/usr/local/bin:/usr/bin:/bin" pm2 startup systemd -u hyperbot --hp "$BOTS_DIR" >/dev/null 2>&1 || true
  sudo -u hyperbot -H env HOME="$BOTS_DIR" PM2_HOME="$BOTS_DIR/.pm2" PATH="/usr/local/bin:/usr/bin:/bin" pm2 save >/dev/null 2>&1 || true
fi

log "Настройка DNS сервиса bind9..."
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
 FTP папки:     ${FTP_DIR}
 Backup:       ${BACKUP_DIR}
 phpMyAdmin:   http://${SERVER_IP}/phpmyadmin

 ВАЖНО: сохрани пароль сейчас.
============================================================
EOF_DONE
