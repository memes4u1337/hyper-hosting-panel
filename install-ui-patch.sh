#!/usr/bin/env bash
set -Eeuo pipefail
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${EUID}" -ne 0 ]]; then
  echo "[HYPER-HOST PATCH] Запусти от root: sudo bash install-ui-patch.sh"
  exit 1
fi
if [[ ! -d "$PANEL_DIR/public" ]]; then
  echo "[HYPER-HOST PATCH] Не найдена панель: $PANEL_DIR/public"
  exit 1
fi
BACKUP_DIR="/opt/hyper-host/backups/ui-patch-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR/public/assets"
cp -a "$PANEL_DIR/public/index.php" "$BACKUP_DIR/public/index.php" 2>/dev/null || true
cp -a "$PANEL_DIR/public/assets/style.css" "$BACKUP_DIR/public/assets/style.css" 2>/dev/null || true
cp -a "$PANEL_DIR/public/assets/app.js" "$BACKUP_DIR/public/assets/app.js" 2>/dev/null || true
install -m 0644 "$PATCH_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
install -m 0644 "$PATCH_DIR/src/public/assets/style.css" "$PANEL_DIR/public/assets/style.css"
install -m 0644 "$PATCH_DIR/src/public/assets/app.js" "$PANEL_DIR/public/assets/app.js"
chown www-data:www-data "$PANEL_DIR/public/index.php" "$PANEL_DIR/public/assets/style.css" "$PANEL_DIR/public/assets/app.js" 2>/dev/null || true
if command -v php >/dev/null 2>&1; then
  php -l "$PANEL_DIR/public/index.php" >/dev/null
fi
systemctl reload php*-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
rm -rf /opt/hyper-host/cache/* 2>/dev/null || true
echo "[HYPER-HOST PATCH] UI patch установлен. Backup: $BACKUP_DIR"
