#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# HYPER-HOST CP — установка клиентского портала на cp.hyper-host.pw
# powered by memes4u1337
#
#   sudo bash install-cp.sh [путь-к-архиву-панели]
#
# Ставит изолированное приложение: пользователь hypercp, свой PHP-FPM pool,
# свой nginx vhost, своя SQLite-база, root-мост с ограниченным набором действий.
# Безопасно запускать повторно: аккаунты клиентов и их файлы не сбрасываются.
# ==============================================================================

SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CP_DOMAIN="${CP_DOMAIN:-cp.hyper-host.pw}"
BASE_DOMAIN="${BASE_DOMAIN:-hyper-host.pw}"
APP_ROOT="/var/www/hyper-host-cp"
CLIENTS_ROOT="/var/www/hyper-host-clients"
META_ROOT="/var/lib/hyper-host-cp"
CP_USER="hypercp"
CP_SOCK="/run/php/hypercp.sock"
CP_CONFIG="/etc/hyper-host/cp.php"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/hyper-host/backups/cp-${STAMP}"

log(){ printf '\n\033[1;36m[HYPER-CP]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти от root: sudo bash install-cp.sh"

for f in src/cp/app/bootstrap.php src/cp/public/index.php src/cp/public/assets/cp.css \
         src/cp/public/assets/cp.js scripts/hyper-cp-bridge scripts/hyper-cp-nginx-fragment.sh; do
  [[ -f "$SRC/$f" ]] || die "Не найден файл архива: $f"
done

# --------------------------------------------------------------- зависимости
log "Проверяю пакеты"
apt-get install -y nginx acl sqlite3 python3 certbot curl ca-certificates sudo >/dev/null 2>&1 || \
  warn "Часть пакетов не установилась — проверь apt вручную"

FPM_VER="$(ls /etc/php 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "$FPM_VER" ]] || die "Не найден установленный PHP. Сначала поставь панель: sudo bash install.sh"
apt-get install -y "php${FPM_VER}-fpm" "php${FPM_VER}-sqlite3" "php${FPM_VER}-mbstring" >/dev/null 2>&1 || true

# --------------------------------------------------------------- бэкап
mkdir -p "$BACKUP"
[[ -d "$APP_ROOT" ]] && cp -a "$APP_ROOT" "$BACKUP/app" || true
[[ -f "$META_ROOT/cp.sqlite" ]] && cp -a "$META_ROOT/cp.sqlite" "$BACKUP/cp.sqlite" || true

# --------------------------------------------------------------- пользователь
log "Готовлю системного пользователя $CP_USER"
id "$CP_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$CP_USER"

# Админ-панель (www-data) должна читать и писать базу клиентов, чтобы
# управлять пользователями и квотами из раздела «Пользователи».
usermod -aG "$CP_USER" www-data 2>/dev/null || true

# --------------------------------------------------------------- файлы
log "Устанавливаю приложение портала"
mkdir -p "$APP_ROOT/app" "$APP_ROOT/public/assets" "$META_ROOT/sessions" "$META_ROOT/tmp" \
         "$CLIENTS_ROOT" /etc/hyper-host /var/log/hyper-cp

install -o root -g "$CP_USER" -m 0640 "$SRC/src/cp/app/bootstrap.php"        "$APP_ROOT/app/bootstrap.php"
install -o root -g "$CP_USER" -m 0640 "$SRC/src/cp/public/index.php"         "$APP_ROOT/public/index.php"
install -o root -g root       -m 0644 "$SRC/src/cp/public/assets/cp.css"     "$APP_ROOT/public/assets/cp.css"
install -o root -g root       -m 0644 "$SRC/src/cp/public/assets/cp.js"      "$APP_ROOT/public/assets/cp.js"

chown root:"$CP_USER" "$APP_ROOT" "$APP_ROOT/app" "$APP_ROOT/public"
chmod 0755 "$APP_ROOT" "$APP_ROOT/public" "$APP_ROOT/public/assets"
chmod 0750 "$APP_ROOT/app"

cat > "$CP_CONFIG" <<PHP
<?php
return [
    'db_path'      => '$META_ROOT/cp.sqlite',
    'clients_root' => '$CLIENTS_ROOT',
    'base_domain'  => '$BASE_DOMAIN',
    'cp_url'       => 'https://$CP_DOMAIN',
    'bridge'       => '/usr/local/sbin/hyper-cp-bridge',
];
PHP
chown root:"$CP_USER" "$CP_CONFIG"; chmod 0640 "$CP_CONFIG"
setfacl -m u:"$CP_USER":--x /etc/hyper-host 2>/dev/null || true
setfacl -m u:"$CP_USER":--x /var/www 2>/dev/null || true

# База должна быть общей для портала (hypercp) и админ-панели (www-data).
chown -R "$CP_USER:$CP_USER" "$META_ROOT"
chmod 2770 "$META_ROOT"
chmod 0700 "$META_ROOT/sessions" "$META_ROOT/tmp"
chown "$CP_USER:$CP_USER" "$META_ROOT/sessions" "$META_ROOT/tmp"

chown root:root "$CLIENTS_ROOT"; chmod 0755 "$CLIENTS_ROOT"
touch /var/log/hyper-cp/php-error.log
chown "$CP_USER:$CP_USER" /var/log/hyper-cp/php-error.log
chmod 0640 /var/log/hyper-cp/php-error.log

# --------------------------------------------------------------- root-мост
log "Устанавливаю привилегированный мост"
install -o root -g root -m 0755 "$SRC/scripts/hyper-cp-bridge" /usr/local/sbin/hyper-cp-bridge
cat > /etc/sudoers.d/hyper-cp-bridge <<SUDO
# HYPER-HOST CP: портал может запускать от root только этот один файл.
$CP_USER ALL=(root) NOPASSWD: /usr/local/sbin/hyper-cp-bridge
SUDO
chmod 0440 /etc/sudoers.d/hyper-cp-bridge
visudo -cf /etc/sudoers.d/hyper-cp-bridge >/dev/null || die "Ошибка правила sudoers"

# Панель тоже управляет клиентами (выдача ресурсов, блокировка).
cat > /etc/sudoers.d/hyper-cp-panel <<SUDO
www-data ALL=(root) NOPASSWD: /usr/local/sbin/hyper-cp-bridge
SUDO
chmod 0440 /etc/sudoers.d/hyper-cp-panel
visudo -cf /etc/sudoers.d/hyper-cp-panel >/dev/null || die "Ошибка правила sudoers для панели"

# --------------------------------------------------------------- PHP-FPM pool
log "Создаю отдельный PHP-FPM pool"
cat > "/etc/php/${FPM_VER}/fpm/pool.d/hypercp.conf" <<POOL
[hypercp]
user = $CP_USER
group = $CP_USER
listen = $CP_SOCK
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 12
pm.process_idle_timeout = 20s
pm.max_requests = 500
clear_env = yes
catch_workers_output = yes
php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/hyper-cp/php-error.log
php_admin_value[session.save_path] = $META_ROOT/sessions
php_admin_value[upload_tmp_dir] = $META_ROOT/tmp
php_admin_value[sys_temp_dir] = $META_ROOT/tmp
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[max_execution_time] = 900
php_admin_value[memory_limit] = 256M
php_admin_value[expose_php] = Off
php_admin_value[session.use_strict_mode] = 1
POOL

systemctl restart "php${FPM_VER}-fpm"
sleep 1
[[ -S "$CP_SOCK" ]] || die "Не создан сокет $CP_SOCK — смотри systemctl status php${FPM_VER}-fpm"

# --------------------------------------------------------------- база
log "Инициализирую базу портала"
runuser -u "$CP_USER" -- php -d display_errors=0 -d session.save_path="$META_ROOT/sessions" \
  -r "require '$APP_ROOT/app/bootstrap.php'; cp_db(); echo \"CP_DB_OK\n\";" | grep -q CP_DB_OK \
  || die "База портала не открывается"
chown "$CP_USER:$CP_USER" "$META_ROOT"/cp.sqlite* 2>/dev/null || true
chmod 0660 "$META_ROOT"/cp.sqlite* 2>/dev/null || true

# --------------------------------------------------------------- nginx
log "Подключаю vhost $CP_DOMAIN"
mkdir -p /opt/hyper-host/bin
install -m 0755 "$SRC/scripts/hyper-cp-nginx-fragment.sh" /opt/hyper-host/bin/hyper-cp-nginx-fragment.sh

# vhost должен переживать пересборку конфигурации nginx панелью.
if [[ -f /usr/local/sbin/hyper-host-nginx-reconcile ]] && \
   ! grep -Fq '/opt/hyper-host/bin/hyper-cp-nginx-fragment.sh' /usr/local/sbin/hyper-host-nginx-reconcile; then
  python3 - <<'PY' || warn "Не удалось встроить хук в reconcile — vhost придётся обновлять вручную"
from pathlib import Path
p = Path('/usr/local/sbin/hyper-host-nginx-reconcile')
s = p.read_text()
hook = ('\n# HYPER-HOST CP persistent vhost hook\n'
        'if [[ -x /opt/hyper-host/bin/hyper-cp-nginx-fragment.sh ]]; then\n'
        '  /opt/hyper-host/bin/hyper-cp-nginx-fragment.sh\n'
        'fi\n')
anchor = 'if ! TEST_OUTPUT="$(nginx -t 2>&1)"; then'
if anchor not in s:
    raise SystemExit(1)
p.write_text(s.replace(anchor, hook + anchor, 1))
PY
  bash -n /usr/local/sbin/hyper-host-nginx-reconcile || die "Повреждён hyper-host-nginx-reconcile"
fi

PHP_FPM_SOCK="$CP_SOCK" CP_DOMAIN="$CP_DOMAIN" /opt/hyper-host/bin/hyper-cp-nginx-fragment.sh
nginx -t
systemctl reload nginx

# --------------------------------------------------------------- FTP chroot
log "Настраиваю FTP: каждый клиент видит только свою папку"
if [[ -d /etc/proftpd ]]; then
  mkdir -p /etc/proftpd/conf.d
  cat > /etc/proftpd/conf.d/hyper-cp.conf <<'FTP'
# HYPER-HOST CP: клиент заперт в своей директории
DefaultRoot ~
RequireValidShell off
AllowOverwrite on
FTP
  chmod 0644 /etc/proftpd/conf.d/hyper-cp.conf
  systemctl reload proftpd 2>/dev/null || systemctl restart proftpd 2>/dev/null || \
    warn "proftpd не перезапустился — проверь вручную"
else
  warn "proftpd не найден. FTP для клиентов не будет работать, пока он не установлен."
fi

# --------------------------------------------------------------- SSL портала
log "Проверяю сертификат портала"
if [[ ! -f "/etc/letsencrypt/live/$CP_DOMAIN/fullchain.pem" ]]; then
  warn "Сертификата для $CP_DOMAIN нет. Портал работает по HTTP."
  warn "Выпустить: sudo certbot certonly --webroot -w /opt/hyper-host/acme-webroot -d $CP_DOMAIN"
  warn "Потом: sudo /opt/hyper-host/bin/hyper-cp-nginx-fragment.sh && sudo systemctl reload nginx"
fi

log "Готово."
printf '  Портал:  https://%s\n' "$CP_DOMAIN"
printf '  Клиенты: %s/<логин>\n' "$CLIENTS_ROOT"
printf '  Управление: админ-панель → Клиенты\n'
printf '  Backup:  %s\n\n' "$BACKUP"
