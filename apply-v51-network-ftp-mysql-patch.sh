#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="/etc/hyper-host/hyper-host.conf"
CTL="/usr/local/sbin/hyper-host-ctl"
HYPER="/usr/local/bin/hyper"
FTP_BIN="/usr/local/sbin/hyper-host-ftp-server"

log(){ printf '\033[1;36m[HYPER-HOST v51]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARNING]\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти: sudo bash apply-v51-network-ftp-mysql-patch.sh"

for f in scripts/hhctl scripts/hyper scripts/hyper_ftp_server.py src/app/bootstrap.php src/public/index.php; do
  [[ -f "$PROJECT_DIR/$f" ]] || fail "Не найден файл патча: $f"
done

bash -n "$PROJECT_DIR/scripts/hhctl"
bash -n "$PROJECT_DIR/scripts/hyper"
python3 -m py_compile "$PROJECT_DIR/scripts/hyper_ftp_server.py"
php -l "$PROJECT_DIR/src/app/bootstrap.php" >/dev/null
php -l "$PROJECT_DIR/src/public/index.php" >/dev/null

if [[ ! -f "$CONF" ]]; then
  log "Панель ещё не установлена — запускаю полную установку v51."
  exec bash "$PROJECT_DIR/install.sh"
fi

# shellcheck disable=SC1090
source "$CONF"
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
BASE_DIR="${BASE_DIR:-/opt/hyper-host}"
BACKUP_DIR="${BACKUP_DIR:-$BASE_DIR/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PATCH_BACKUP="$BACKUP_DIR/v51-network-patch-$STAMP"
mkdir -p "$PATCH_BACKUP"

log "Резервная копия текущих файлов: $PATCH_BACKUP"
for f in "$CTL" "$HYPER" "$FTP_BIN" "$PANEL_DIR/app/bootstrap.php" "$PANEL_DIR/public/index.php" "$CONF"; do
  if [[ -e "$f" ]]; then
    mkdir -p "$PATCH_BACKUP$(dirname "$f")"
    cp -a "$f" "$PATCH_BACKUP$f"
  fi
done
cp -a /etc/phpmyadmin/conf.d/hyper-host-server.php "$PATCH_BACKUP/phpmyadmin-server.php" 2>/dev/null || true
cp -a /etc/mysql/mariadb.conf.d/99-hyper-host-network.cnf "$PATCH_BACKUP/mysql-network.cnf" 2>/dev/null || true

log "Устанавливаю обновлённый CLI, сетевой модуль и FTP-сервер."
install -m 0755 "$PROJECT_DIR/scripts/hhctl" "$CTL"
install -m 0755 "$PROJECT_DIR/scripts/hyper" "$HYPER"
install -m 0755 "$PROJECT_DIR/scripts/hyper_ftp_server.py" "$FTP_BIN"
ln -sf "$HYPER" /usr/bin/hyper 2>/dev/null || true
ln -sf "$CTL" /usr/bin/hyper-host-ctl 2>/dev/null || true

log "Обновляю файлы панели без удаления config.php и базы."
mkdir -p "$PANEL_DIR/app" "$PANEL_DIR/public"
install -m 0644 "$PROJECT_DIR/src/app/bootstrap.php" "$PANEL_DIR/app/bootstrap.php"
install -m 0644 "$PROJECT_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
if [[ -d "$PROJECT_DIR/src/public/assets" ]]; then
  mkdir -p "$PANEL_DIR/public/assets"
  rsync -a "$PROJECT_DIR/src/public/assets/" "$PANEL_DIR/public/assets/"
fi
chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
chmod 0640 "$PANEL_DIR/app/config.php" 2>/dev/null || true

log "Определяю фактические LAN/WAN IP и применяю их ко всем сервисам."
"$CTL" ip-detect --apply >/tmp/hyper-host-v51-ip.json

log "Поднимаю FTP, открываю control/passive-порты и восстанавливаю аккаунты."
"$CTL" ftp-fix

log "Включаю внешний MySQL и настраиваю phpMyAdmin на локальный SQL 127.0.0.1."
"$CTL" mysql-external enable
"$CTL" phpmyadmin-fix

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart hyper-host-ftp.service >/dev/null 2>&1 || true
systemctl reload nginx >/dev/null 2>&1 || true

php -l "$PANEL_DIR/app/bootstrap.php" >/dev/null
php -l "$PANEL_DIR/public/index.php" >/dev/null
nginx -t >/dev/null 2>&1 || warn "nginx -t вернул ошибку — проверь: sudo nginx -t"

log "Патч установлен. Текущие адреса:"
"$HYPER" ip
printf '\n'
log "Диагностика FTP: sudo hyper ftp doctor"
log "Реальный тест FTP: sudo hyper ftp test LOGIN PASSWORD 127.0.0.1"
log "Диагностика SQL: sudo hyper db doctor"
log "Резервная копия: $PATCH_BACKUP"
