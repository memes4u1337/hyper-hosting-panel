#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="1.2"
PANEL_NAME="HYPER-HOST"
POWERED_BY="Разработано memes4u1337"
AUTHOR="memes4u1337"
PROJECT_SITE="https://hyper-host.pw"
PANEL_SITE="https://panel.hyper-host.pw"
REPOSITORY="https://github.com/memes4u1337/hyper-hosting-panel"
AUTHOR_URL="https://github.com/memes4u1337"
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
HYPER_INSTALLER_BIN="/usr/local/sbin/hyper-host-installer"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]]; then
  RESET='\033[0m'
  BOLD='\033[1m'
  CYAN='\033[1;96m'
  BLUE='\033[1;94m'
  GREEN='\033[1;92m'
  YELLOW='\033[1;93m'
  RED='\033[1;91m'
  WHITE='\033[1;97m'
else
  RESET=''
  BOLD=''
  CYAN=''
  BLUE=''
  GREEN=''
  YELLOW=''
  RED=''
  WHITE=''
fi

log() { printf '%b[%bHYPER-HOST%b]%b %s\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$*"; }
warn() { printf '%b[%bHYPER-HOST WARNING%b]%b %b%s%b\n' "$BOLD" "$YELLOW" "$RESET" "$RESET" "$YELLOW" "$*" "$RESET"; }
fail() { printf '%b[%bHYPER-HOST ERROR%b]%b %b%s%b\n' "$BOLD" "$RED" "$RESET" "$RESET" "$RED" "$*" "$RESET" >&2; exit 1; }

show_install_banner() {
  [[ -t 1 ]] && clear || true
  printf '%b' "$CYAN"
  cat <<'HH_BANNER'
██╗  ██╗██╗   ██╗██████╗ ███████╗██████╗       ██╗  ██╗ ██████╗ ███████╗████████╗
██║  ██║╚██╗ ██╔╝██╔══██╗██╔════╝██╔══██╗      ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
███████║ ╚████╔╝ ██████╔╝█████╗  ██████╔╝█████╗███████║██║   ██║███████╗   ██║
██╔══██║  ╚██╔╝  ██╔═══╝ ██╔══╝  ██╔══██╗╚════╝██╔══██║██║   ██║╚════██║   ██║
██║  ██║   ██║   ██║     ███████╗██║  ██║      ██║  ██║╚██████╔╝███████║   ██║
╚═╝  ╚═╝   ╚═╝   ╚═╝     ╚══════╝╚═╝  ╚═╝      ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
HH_BANNER
  printf '%b' "$RESET"
  printf '%b======================================================================%b\n' "$BLUE" "$RESET"
  printf '  %bУстановка панели | v%s%b\n' "$WHITE" "$INSTALLER_VERSION" "$RESET"
  printf '  Разработчик: %b%s%b | %s\n' "$BOLD" "$AUTHOR" "$RESET" "$AUTHOR_URL"
  printf '%b======================================================================%b\n\n' "$BLUE" "$RESET"
}

if [[ "${EUID}" -ne 0 ]]; then
  fail "Запусти установщик от root: sudo bash setup.sh или sudo bash install.sh"
fi

show_install_banner

# v49: раньше при занятой dpkg-блокировке (unattended-upgrades или другой apt-get,
# который ещё не закончился) установка сразу падала с "Не удалось получить блокировку
# файла /var/lib/dpkg/lock-frontend" и всё останавливалось. Теперь ждём освобождения
# блокировки до 3 минут вместо мгновенного отказа — обычно unattended-upgrades
# отрабатывает за 10-60 секунд.
wait_for_dpkg_lock() {
  local waited=0 max=180
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    if [[ "$waited" -eq 0 ]]; then log "apt/dpkg сейчас занят другим процессом (например автообновления системы) — жду освобождения..."; fi
    sleep 5; waited=$((waited+5))
    if [[ "$waited" -ge "$max" ]]; then warn "dpkg всё ещё занят через ${max}с, пробую продолжить как есть"; break; fi
  done
}

# Ubuntu блокирует apt update, если сторонний репозиторий изменил Label/Origin/Suite.
# Для PPA ondrej/php это штатная смена метаданных. HYPER-HOST подтверждает её
# автоматически, чтобы установка не останавливалась посередине.
apt_update() {
  wait_for_dpkg_lock
  apt-get update --allow-releaseinfo-change
}

wait_for_dpkg_lock

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
# Брендинг установщика всегда остаётся актуальным даже при обновлении старой конфигурации.
PANEL_NAME="HYPER-HOST"
POWERED_BY="Разработано memes4u1337"
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
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 && apt_update || warn "PPA ondrej/php недоступен, будут установлены только версии PHP из текущих репозиториев"
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
  {
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
  } 2>/dev/null || warn "Не удалось записать /etc/phpmyadmin/conf.d/hyper-host-storage.php (read-only /etc?) — продолжаю установку."
  chmod 0644 /etc/phpmyadmin/conf.d/hyper-host-storage.php 2>/dev/null || true
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
wait_for_dpkg_lock
apt_update
wait_for_dpkg_lock
apt-get install -y \
  ca-certificates curl git unzip rsync sudo openssl ufw software-properties-common apt-transport-https lsb-release \
  nginx mariadb-server \
  php-fpm php-cli php-sqlite3 php-mysql php-curl php-mbstring php-xml php-zip php-gd \
  proftpd-basic lftp openssh-server certbot python3-certbot-nginx python3 python3-venv python3-pip acl cron bind9 dnsutils whois db-util

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
mkdir -p "$BASE_DIR/data" "$BASE_DIR/templates" "$BASE_DIR/bin" "$BASE_DIR/logs" "$BASE_DIR/runtime" "$BACKUP_DIR" "$CACHE_DIR" "$PANEL_DIR" "$SITES_DIR" "$BOTS_DIR" "$FTP_DIR" "$DNS_DIR" "$CONF_DIR"

log "Очистка старых сломанных FTP bind-mount'ов..."
cleanup_hyper_host_mounts

log "Копирование файлов панели..."
rsync -a --delete "$PROJECT_DIR/src/" "$PANEL_DIR/"
rsync -a --delete "$PROJECT_DIR/templates/" "$BASE_DIR/templates/"
install -m 0755 "$PROJECT_DIR/scripts/hhctl" "$CONTROL_BIN"
[[ -f "$PROJECT_DIR/scripts/hyper_nginx_runtime.sh" ]] || fail "Не найден scripts/hyper_nginx_runtime.sh"
install -m 0755 "$PROJECT_DIR/scripts/hyper_nginx_runtime.sh" "$BASE_DIR/bin/hyper-host-nginx-runtime"
[[ -f "$PROJECT_DIR/scripts/nginx_recover_v89.py" ]] && install -m 0755 "$PROJECT_DIR/scripts/nginx_recover_v89.py" /opt/hyper-host/nginx_recover_v89.py
[[ -f "$PROJECT_DIR/scripts/nginx-reconcile-v89.sh" ]] && install -m 0755 "$PROJECT_DIR/scripts/nginx-reconcile-v89.sh" /usr/local/sbin/hyper-host-nginx-reconcile
install -m 0755 "$PROJECT_DIR/scripts/hyper" "$HYPER_BIN"
install -m 0755 "$PROJECT_DIR/scripts/hyper_ftp_server.py" "$HYPER_FTP_BIN"
install -m 0755 "$PROJECT_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
install -m 0755 "$PROJECT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$BASE_DIR/bin/hyper_ftp_proftpd_fix.sh"
if [[ -f "$PROJECT_DIR/setup.sh" ]]; then
  install -m 0755 "$PROJECT_DIR/setup.sh" "$HYPER_INSTALLER_BIN"
  ln -sf "$HYPER_INSTALLER_BIN" /usr/local/bin/hyper-host-installer 2>/dev/null || true
fi
mkdir -p "$BASE_DIR/deploy-center/defaults" /var/www/hyper-host-deploy/master /var/www/hyper-host-deploy/template /var/www/hyper-host-managed-bots
install -m 0755 "$PROJECT_DIR/scripts/deploy_center.py" "$BASE_DIR/deploy-center/deploy_center.py"
install -m 0755 "$PROJECT_DIR/scripts/ssl_truth.py" "$BASE_DIR/ssl-truth.py"
# v76: не создаём и не копируем никакие bot.py/.env/requirements.txt.
# Пользователь загружает главный комплект и шаблон магазинов только через Deploy Manager.
# v23: делаем CLI доступным для панели, PM2-ботов и обычной shell-среды.
# Некоторые окружения/боты ищут hyper в /usr/local/bin или /usr/bin.
ln -sf "$HYPER_BIN" /usr/bin/hyper 2>/dev/null || true
ln -sf "$CONTROL_BIN" /usr/bin/hyper-host-ctl 2>/dev/null || true
chmod 0755 "$CONTROL_BIN" "$HYPER_BIN" "$HYPER_FTP_BIN" /usr/bin/hyper /usr/bin/hyper-host-ctl 2>/dev/null || true

log "Создание конфигурации панели..."
cat > "$CONF_DIR/hyper-host.conf" <<EOCONF
PANEL_NAME="${PANEL_NAME}"
POWERED_BY="${POWERED_BY}"
AUTHOR="${AUTHOR}"
PROJECT_SITE="${PROJECT_SITE}"
PANEL_SITE="${PANEL_SITE}"
REPOSITORY="${REPOSITORY}"
AUTHOR_URL="${AUTHOR_URL}"
PROJECT_SOURCE_DIR="${PROJECT_DIR}"
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
ACME_WEBROOT="${BASE_DIR}/acme-webroot"
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
{
cat > /etc/phpmyadmin/conf.d/hyper-host-server.php <<EOPMA
<?php
// HYPER-HOST: phpMyAdmin показывает понятное имя сервера вместо localhost:3306.
if (isset(\$i)) {
    \$cfg['Servers'][\$i]['verbose'] = '${PMA_VERBOSE_HOST}:3306';
    \$cfg['Servers'][\$i]['host'] = '127.0.0.1';
    \$cfg['Servers'][\$i]['port'] = '3306';
}
EOPMA
} 2>/dev/null || warn "Не удалось записать /etc/phpmyadmin/conf.d/hyper-host-server.php (read-only /etc?) — продолжаю установку."
chmod 0644 /etc/phpmyadmin/conf.d/hyper-host-server.php 2>/dev/null || true
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
"$CONTROL_BIN" deploy-center-install >/tmp/hyper-host-deploy-center-install.log 2>&1 || warn "Deploy Center не инициализирован. Лог: /tmp/hyper-host-deploy-center-install.log"
chown www-data:www-data "$BASE_DIR/data/hyperhost.sqlite"
chmod 0660 "$BASE_DIR/data/hyperhost.sqlite"
chown www-data:www-data "$BASE_DIR/data/hyperhost.sqlite"-* 2>/dev/null || true
chmod 0660 "$BASE_DIR/data/hyperhost.sqlite"-* 2>/dev/null || true

log "Настройка sudo для панели..."
{
cat > /etc/sudoers.d/hyper-host <<EOSUDO
www-data ALL=(root) NOPASSWD: ${CONTROL_BIN} *
www-data ALL=(root) NOPASSWD: ${HYPER_BIN} *
EOSUDO
} 2>/dev/null || fail "Не удалось записать /etc/sudoers.d/hyper-host (read-only /etc/sudoers.d?) — без этого панель не сможет выполнять команды. Проверь, что корневая ФС доступна на запись: mount | grep ' / '"
chmod 0440 /etc/sudoers.d/hyper-host
visudo -cf /etc/sudoers.d/hyper-host >/dev/null || fail "Ошибка sudoers-конфига"

log "Подключение writable Nginx runtime..."
"$BASE_DIR/bin/hyper-host-nginx-runtime" --quiet
if command -v crontab >/dev/null 2>&1; then
  _hh_cron="$(crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME' || true)"
  {
    printf '%s\n' "$_hh_cron"
    printf '@reboot sleep 5; %s/bin/hyper-host-nginx-runtime --boot >>%s/logs/nginx-runtime-boot.log 2>&1 # HYPER-HOST-NGINX-RUNTIME\n' "$BASE_DIR" "$BASE_DIR"
  } | awk 'NF' | crontab -
fi

log "Настройка Nginx для панели..."
{
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
} 2>/dev/null || fail "Не удалось записать /etc/nginx/sites-available/hyper-host-panel.conf (read-only /etc/nginx?) — без этого панель не будет доступна. Проверь: mount | grep ' / '"

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/hyper-host-panel.conf /etc/nginx/sites-enabled/hyper-host-panel.conf
mkdir -p "${BASE_DIR}/acme-webroot/.well-known/acme-challenge"
chown -R www-data:www-data "${BASE_DIR}/acme-webroot" 2>/dev/null || true
chmod -R a+rX "${BASE_DIR}/acme-webroot"
if [[ -x /usr/local/sbin/hyper-host-nginx-reconcile ]]; then
  /usr/local/sbin/hyper-host-nginx-reconcile
else
  nginx -t
  systemctl reload nginx
fi
systemctl enable nginx >/dev/null 2>&1 || true

log "Настройка FTP/FTPS через ProFTPD..."
FTP_AUTH_TXT="$BASE_DIR/data/vsftpd_virtual_users.txt"
FTP_USER_CONF_DIR="$BASE_DIR/ftp/user_conf"
mkdir -p "$FTP_DIR" "$BASE_DIR/data" "$BASE_DIR/ftp" "$FTP_USER_CONF_DIR" "$BASE_DIR/bin" /var/log
[[ -f "$FTP_AUTH_TXT" ]] || touch "$FTP_AUTH_TXT"
chmod 0600 "$FTP_AUTH_TXT" 2>/dev/null || true
chmod 0755 "$FTP_DIR" "$FTP_USER_CONF_DIR" 2>/dev/null || true

# Не удаляем существующие FTP-аккаунты. Пересобираем ProFTPD auth из файла панели
# и восстанавливаем LAN/WAN endpoints, TLS и passive-порты.
"$CONTROL_BIN" ftp-fix

ufw allow 21/tcp >/dev/null 2>&1 || true
ufw allow 2121/tcp >/dev/null 2>&1 || true
ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
iptables -C INPUT -p tcp --dport 21 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 21 -j ACCEPT 2>/dev/null || true
iptables -C INPUT -p tcp --dport 2121 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 2121 -j ACCEPT 2>/dev/null || true
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
    apt_update >/dev/null 2>&1 || true
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
{
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
} 2>/dev/null || warn "Не удалось записать /etc/bind/named.conf.options (read-only /etc?) — DNS-зоны настраивай позже вручную: sudo hyper dns wizard."
touch /etc/bind/named.conf.local 2>/dev/null || true
systemctl enable bind9 >/dev/null 2>&1 || true
systemctl restart bind9 2>/dev/null || true

log "Запуск MariaDB и PHP-FPM..."
systemctl enable mariadb >/dev/null 2>&1 || true
systemctl restart mariadb
systemctl enable "php${PHP_VER}-fpm" >/dev/null 2>&1 || true
systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true
systemctl enable cron >/dev/null 2>&1 || true
systemctl restart cron 2>/dev/null || true

# v47: у многих домашних провайдеров публичный IP не статичный (меняется при
# переподключении/перезагрузке роутера). Без этого вотчера при смене IP FTP и DNS
# продолжали бы рекламировать старый, недоступный извне адрес. Проверяем раз в 5 минут.
{
cat > /etc/cron.d/hyper-host-ip-watch <<EOIPWATCH
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/sbin/hyper-host-ctl ip-autofix --quiet >/var/log/hyper-host-ip-watch.log 2>&1
EOIPWATCH
} 2>/dev/null || warn "Не удалось поставить cron для автообновления IP (read-only /etc/cron.d?) — при смене IP чини вручную: sudo hyper network ip-fix"
chmod 0644 /etc/cron.d/hyper-host-ip-watch 2>/dev/null || true
systemctl reload cron 2>/dev/null || true

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

PANEL_PRIMARY_URL="http://${SERVER_IP}/"
if [[ -n "${PANEL_DOMAIN:-}" && "${PANEL_DOMAIN}" != "_" ]]; then
  PANEL_PRIMARY_URL="https://${PANEL_DOMAIN}/"
fi

printf '\n%b======================================================================%b\n' "$BLUE" "$RESET"
printf '  %bHYPER-HOST УСПЕШНО УСТАНОВЛЕН%b\n' "$CYAN" "$RESET"
printf '  Разработчик: %b%s%b\n' "$BOLD" "$AUTHOR" "$RESET"
printf '%b======================================================================%b\n' "$BLUE" "$RESET"
printf '\n%bДоступ к панели%b\n' "$WHITE" "$RESET"
printf '  Основной URL:      %s\n' "$PANEL_PRIMARY_URL"
printf '  Локальный URL:     http://%s/\n' "$SERVER_IP"
printf '  phpMyAdmin:        http://%s/phpmyadmin\n' "$SERVER_IP"
if [[ -n "${PANEL_DOMAIN:-}" && "${PANEL_DOMAIN}" != "_" ]]; then
  printf '  Домен панели:      %s\n' "$PANEL_DOMAIN"
fi
printf '\n%bДанные администратора%b\n' "$WHITE" "$RESET"
printf '  Логин:             %s\n' "$ADMIN_USER"
printf '  Пароль:            %b%s%b\n' "$YELLOW" "$ADMIN_PASS" "$RESET"
printf '\n%bПапки %bHYPER-HOST%b\n' "$WHITE" "$CYAN" "$RESET"
printf '  Сайты:             %s\n' "$SITES_DIR"
printf '  Telegram-боты:     %s\n' "$BOTS_DIR"
printf '  FTP:               %s\n' "$FTP_DIR"
printf '  Резервные копии:   %s\n' "$BACKUP_DIR"
printf '  Конфигурация:      %s/hyper-host.conf\n' "$CONF_DIR"
printf '\n%bПолезные команды%b\n' "$WHITE" "$RESET"
printf '  Меню установщика:  sudo hyper-host-installer\n'
printf '  Помощь CLI:        sudo hyper help\n'
printf '  Ремонт:            sudo hyper repair\n'
printf '  Статистика:        sudo hyper stats\n'
printf '  Проверка Nginx:    sudo nginx -t\n'
printf '  Статус SSL:        sudo hyper ssl status\n'
printf '\n%bСсылки проекта%b\n' "$WHITE" "$RESET"
printf '  Сайт:              %s\n' "$PROJECT_SITE"
printf '  Панель:            %s\n' "$PANEL_SITE"
printf '  GitHub:            %s\n' "$REPOSITORY"
printf '  Разработчик:       %s (%s)\n' "$AUTHOR" "$AUTHOR_URL"
printf '\n%bВАЖНО: сохрани логин и пароль администратора прямо сейчас.%b\n' "$YELLOW" "$RESET"
printf '%b======================================================================%b\n' "$BLUE" "$RESET"
