#!/usr/bin/env bash
# =============================================================================
# HYPER-HOST · apply-v76-ui-ops-console
# Обновление интерфейса панели до v76 «Ops Console» (новое меню, живой RAM/CPU,
# модальные окна). Патч ТОЛЬКО фронтенда: index.php + assets/app.js + style.css.
# Бэкенд (hhctl, python, SSL, config.php, база) НЕ трогается и НЕ удаляется.
#
# Запуск (в стиле остальных патчей):
#   sudo ./apply-v76-ui-ops-console.sh /root/hyper-hosting-panel  твой@email
# =============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
EMAIL="${2:-}"                       # не используется для UI, принимается для совместимости
BASE=/opt/hyper-host
PANEL_DIR="${PANEL_DIR:-/var/www/hyper-host}"
BACKUP="$BASE/backups/v76-ui-$(date +%Y%m%d-%H%M%S)"

say(){ printf '\033[1;36m[HYPER-HOST]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[HYPER-HOST WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[HYPER-HOST ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ [[ -f "$1" ]] || fail "Не найден файл: $1"; }
backup_one(){ local src="$1" rel="$2"; [[ -e "$src" ]] || return 0; mkdir -p "$BACKUP/$(dirname "$rel")"; cp -a "$src" "$BACKUP/$rel"; }
install_if_different(){
  local mode="$1" src="$2" dst="$3"; need "$src"; mkdir -p "$(dirname "$dst")"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then chmod "$mode" "$dst" 2>/dev/null || true; return 0; fi
  install -m "$mode" "$src" "$dst"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти патч через sudo"

# --- определяем корень панели (на случай нестандартной установки) ------------
if [[ ! -d "$PANEL_DIR/public" ]]; then
  d="$(grep -rhoE 'root[[:space:]]+\S+/public;' /etc/nginx 2>/dev/null | grep -i hyper-host | head -1 | sed -E 's/^root[[:space:]]+//; s#/public;##' || true)"
  [[ -n "$d" && -d "$d/public" ]] && PANEL_DIR="$d"
fi
[[ -d "$PANEL_DIR/public" ]] || fail "Не найден корень панели ($PANEL_DIR/public). Задай PANEL_DIR=/путь перед запуском."
PUB="$PANEL_DIR/public"
say "Корень панели: $PANEL_DIR"

# --- источник обновления (файлы из склонированного репозитория) ---------------
SRC="$ROOT_DIR/src/public"
need "$SRC/index.php"; need "$SRC/assets/app.js"; need "$SRC/assets/style.css"

# синтаксис-проверка PHP до установки
if command -v php >/dev/null 2>&1; then
  php -l "$SRC/index.php" >/dev/null || fail "Ошибка синтаксиса в новом index.php — установка прервана."
fi

# --- бэкап текущих файлов ----------------------------------------------------
say "Резервная копия текущего интерфейса: $BACKUP"
backup_one "$PUB/index.php"        public/index.php
backup_one "$PUB/assets/app.js"    public/assets/app.js
backup_one "$PUB/assets/style.css" public/assets/style.css

# --- установка трёх файлов интерфейса ----------------------------------------
say "Устанавливаю интерфейс v76 «Ops Console»."
install_if_different 0644 "$SRC/index.php"        "$PUB/index.php"
install_if_different 0644 "$SRC/assets/app.js"    "$PUB/assets/app.js"
install_if_different 0644 "$SRC/assets/style.css" "$PUB/assets/style.css"
chown www-data:www-data "$PUB/index.php" "$PUB/assets/app.js" "$PUB/assets/style.css" 2>/dev/null || true

# синхронизируем копию в PROJECT_DIR, если это другая папка (как в остальных патчах)
if [[ -d "$PROJECT_DIR" && "$(readlink -f "$PROJECT_DIR")" != "$(readlink -f "$ROOT_DIR")" ]]; then
  install_if_different 0644 "$SRC/index.php"        "$PROJECT_DIR/src/public/index.php"
  install_if_different 0644 "$SRC/assets/app.js"    "$PROJECT_DIR/src/public/assets/app.js"
  install_if_different 0644 "$SRC/assets/style.css" "$PROJECT_DIR/src/public/assets/style.css"
fi

# --- сброс opcache: перезапуск php-fpm ---------------------------------------
FPM="$(systemctl list-units --type=service 2>/dev/null | grep -oE 'php[0-9.]+-fpm' | head -1 || true)"
if [[ -n "$FPM" ]]; then
  systemctl reload "$FPM" 2>/dev/null || systemctl restart "$FPM" 2>/dev/null || true
  say "php-fpm перезагружен ($FPM) — opcache сброшен."
fi

say "Готово! Интерфейс обновлён до v76. Открой панель и нажми Ctrl+F5."
say "Откат при необходимости: файлы из $BACKUP скопировать обратно в $PUB."
[[ -n "$EMAIL" ]] && say "Email '$EMAIL' для UI-патча не требуется — принят для совместимости команды."
exit 0
