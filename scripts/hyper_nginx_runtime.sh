#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-/opt/hyper-host}"
TARGET_DIR="${HYPER_NGINX_TARGET:-/etc/nginx}"
RUNTIME_DIR="${HYPER_NGINX_RUNTIME_DIR:-$BASE_DIR/runtime/nginx}"
BACKUP_ROOT="${HYPER_NGINX_BACKUP_DIR:-$BASE_DIR/backups}"
LOG_DIR="${HYPER_NGINX_LOG_DIR:-$BASE_DIR/logs}"
MARKER="$RUNTIME_DIR/.hyper-host-nginx-runtime"
QUIET=0
RESTART=0

for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --restart|--boot) RESTART=1 ;;
  esac
done

log(){ [[ "$QUIET" == 1 ]] || printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Nginx runtime необходимо запускать через sudo/root.'
[[ -d "$TARGET_DIR" ]] || fail "Не найден каталог Nginx: $TARGET_DIR"
mkdir -p "$(dirname "$RUNTIME_DIR")" "$BACKUP_ROOT" "$LOG_DIR"

is_runtime_mounted(){
  [[ -e "$MARKER" && -e "$TARGET_DIR/.hyper-host-nginx-runtime" ]] \
    && [[ "$MARKER" -ef "$TARGET_DIR/.hyper-host-nginx-runtime" ]]
}

is_writable(){
  local probe="$TARGET_DIR/.hyper-host-write-probe-$$"
  if ( umask 077; : > "$probe" ) 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    return 0
  fi
  return 1
}

bootstrap_runtime(){
  if [[ -e "$MARKER" ]]; then
    return 0
  fi

  local stamp staging old
  stamp="$(date +%Y%m%d-%H%M%S)"
  staging="${RUNTIME_DIR}.new.$$"
  old="${RUNTIME_DIR}.old-${stamp}"
  rm -rf "$staging"
  mkdir -p "$staging"

  log "Создаю writable-копию Nginx в $RUNTIME_DIR"
  # Если старый runtime уже существовал, считаем его главным источником и
  # дополняем отсутствующими системными файлами из /etc/nginx. Так не теряются
  # сайты, созданные предыдущими read-only патчами.
  if [[ -d "$RUNTIME_DIR" && -f "$RUNTIME_DIR/nginx.conf" ]]; then
    cp -a "$RUNTIME_DIR/." "$staging/"
    cp -an "$TARGET_DIR/." "$staging/" 2>/dev/null || true
  else
    cp -a "$TARGET_DIR/." "$staging/"
  fi
  mkdir -p "$staging/sites-available" "$staging/sites-enabled" "$staging/conf.d" "$staging/snippets"
  printf 'HYPER-HOST nginx runtime\ncreated=%s\n' "$(date -Is)" > "$staging/.hyper-host-nginx-runtime"

  if [[ -d "$RUNTIME_DIR" ]]; then
    mv "$RUNTIME_DIR" "$old"
  fi
  mv "$staging" "$RUNTIME_DIR"
}

activate_runtime(){
  if is_runtime_mounted; then
    mount -o remount,bind,rw "$TARGET_DIR" >/dev/null 2>&1 || true
    return 0
  fi

  bootstrap_runtime
  log "Подключаю writable Nginx runtime поверх $TARGET_DIR"
  mount --bind "$RUNTIME_DIR" "$TARGET_DIR" \
    || fail "Не удалось выполнить bind-mount $RUNTIME_DIR -> $TARGET_DIR"
  mount -o remount,bind,rw "$TARGET_DIR" >/dev/null 2>&1 \
    || mount -o remount,rw "$TARGET_DIR" >/dev/null 2>&1 \
    || true

  is_runtime_mounted || fail 'Bind-mount Nginx подключён некорректно.'
  is_writable || fail "$TARGET_DIR всё ещё read-only после подключения runtime."
}

activate_runtime
mkdir -p "$TARGET_DIR/sites-available" "$TARGET_DIR/sites-enabled" "$TARGET_DIR/conf.d" "$TARGET_DIR/snippets"

# Убираем только временные конфиги старых тестов. Реальные сайты не затрагиваются.
find "$TARGET_DIR/sites-available" -maxdepth 1 -type f \
  -name 'hyper-host-site-v*-nginx-test-*.local.conf' -delete 2>/dev/null || true
find "$TARGET_DIR/sites-enabled" -maxdepth 1 \( -type f -o -type l \) \
  -name '*hyper-host-site-v*-nginx-test-*.local.conf' -delete 2>/dev/null || true

if command -v nginx >/dev/null 2>&1; then
  nginx -t >/dev/null 2>&1 || {
    nginx -t >&2 || true
    fail 'Nginx runtime подключён, но текущая конфигурация содержит ошибку.'
  }
fi

if [[ "$RESTART" == 1 ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl restart nginx >/dev/null 2>&1 || systemctl reload nginx >/dev/null 2>&1 || true
fi

log "Nginx runtime готов: $TARGET_DIR -> $RUNTIME_DIR"
