#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# HYPER-HOST v92 · powered by memes4u1337
#   1) Вёрстка: слипшиеся подписи, пустые полоски метров, кривая раскладка FTP
#   2) Боты PM2: реальная нагрузка на сервер вместо декоративных цифр
#   3) SSL: выпуск на www и любые поддомены одним сертификатом
#
# Запуск:  sudo ./apply-v92-ui-bots-ssl.sh
#          sudo ./apply-v92-ui-bots-ssl.sh www.pixel-pc.store admin@example.com
# ============================================================================

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_HOST="${1:-}"
SSL_EMAIL="${2:-}"

BASE=/opt/hyper-host
PANEL_DIR=/var/www/hyper-host
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v92-ui-bots-ssl-$STAMP"

if [[ -t 1 ]]; then
  RESET='\033[0m'; CYAN='\033[1;96m'; GREEN='\033[1;92m'; YELLOW='\033[1;93m'; RED='\033[1;91m'; BOLD='\033[1m'
else
  RESET=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; BOLD=''
fi
log()  { printf '%b[%bHYPER-HOST%b]%b %s\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$*"; }
ok()   { printf '%b[%bHYPER-HOST%b]%b %b%s%b\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$GREEN" "$*" "$RESET"; }
warn() { printf '%b[%bHYPER-HOST%b]%b %b%s%b\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$YELLOW" "$*" "$RESET"; }
fail() { printf '%b[HYPER-HOST ERROR]%b %b%s%b\n' "$BOLD" "$RESET" "$RED" "$*" "$RESET" >&2; exit 1; }

for file in src/public/index.php src/public/assets/style.css src/public/assets/app.js scripts/hhctl; do
  [[ -f "$ROOT/$file" ]] || fail "В архиве нет $file"
done
[[ -d "$PANEL_DIR/public" ]] || fail "Панель не найдена: $PANEL_DIR/public"

# ------------------------------------------------------------------ backup
mkdir -p "$BACKUP"
for file in "$PANEL_DIR/public/index.php" "$PANEL_DIR/public/assets/style.css" \
            "$PANEL_DIR/public/assets/app.js" /usr/local/sbin/hyper-host-ctl; do
  [[ -f "$file" ]] && cp -a "$file" "$BACKUP/$(basename "$file")"
done
log "Резервная копия: $BACKUP"

rollback() {
  local code=$?
  trap - ERR
  warn 'Ошибка установки v92. Возвращаю предыдущие файлы.'
  [[ -f "$BACKUP/index.php" ]]  && install -m 0644 "$BACKUP/index.php"  "$PANEL_DIR/public/index.php"
  [[ -f "$BACKUP/style.css" ]]  && install -m 0644 "$BACKUP/style.css"  "$PANEL_DIR/public/assets/style.css"
  [[ -f "$BACKUP/app.js" ]]     && install -m 0644 "$BACKUP/app.js"     "$PANEL_DIR/public/assets/app.js"
  [[ -f "$BACKUP/hyper-host-ctl" ]] && install -m 0755 "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  exit "$code"
}
trap rollback ERR

# ------------------------------------------------------------------ проверки до установки
log 'Проверяю синтаксис новых файлов.'
bash -n "$ROOT/scripts/hhctl" || fail 'hhctl не проходит bash -n'
if command -v php >/dev/null 2>&1; then
  php -l "$ROOT/src/public/index.php" >/dev/null || fail 'index.php не проходит php -l'
fi

# ------------------------------------------------------------------ установка
log 'Ставлю обновлённую панель.'
install -m 0644 "$ROOT/src/public/index.php"        "$PANEL_DIR/public/index.php"
install -m 0644 "$ROOT/src/public/assets/style.css" "$PANEL_DIR/public/assets/style.css"
install -m 0644 "$ROOT/src/public/assets/app.js"    "$PANEL_DIR/public/assets/app.js"
chown -R www-data:www-data "$PANEL_DIR/public" 2>/dev/null || true

log 'Ставлю обновлённый hyper-host-ctl.'
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true

mkdir -p "$BASE/runtime" "$BASE/runtime/ssl-jobs" "$BASE/certbot-logs"
chmod 0750 "$BASE/runtime/ssl-jobs" 2>/dev/null || true

# ------------------------------------------------------------------ проверка новых команд
log 'Проверяю новые команды hyper-host-ctl.'
/usr/local/sbin/hyper-host-ctl bots-usage-json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d.get("bots"),list), d; print("[HYPER-HOST] bots-usage-json: ботов %d, RAM %.1f MB, сервер %d ядер" % (len(d["bots"]), d["totals"]["memory"]/1048576, d["server"]["cpu_cores"]))' \
  || fail 'bots-usage-json не отдал корректный JSON'

if command -v php >/dev/null 2>&1; then
  php -r 'exit(0);' >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl reload "php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)-fpm" >/dev/null 2>&1 || true
fi

trap - ERR
ok 'v92 установлен: вёрстка починена, боты показывают реальную нагрузку, SSL умеет www.'

# ------------------------------------------------------------------ SSL по желанию
if [[ -n "$SSL_HOST" ]]; then
  log "Диагностика SSL для $SSL_HOST:"
  /usr/local/sbin/hyper-host-ctl ssl-host-check-json "$SSL_HOST" | python3 -m json.tool || true
  if [[ -n "$SSL_EMAIL" ]]; then
    SITE="$(/usr/local/sbin/hyper-host-ctl ssl-host-check-json "$SSL_HOST" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("site",""))')"
    if [[ -z "$SITE" ]]; then
      warn "Для $SSL_HOST нет сайта в панели. Создай сайт с базовым доменом и повтори."
    else
      log "Выпускаю один сертификат для сайта $SITE вместе с $SSL_HOST."
      /usr/local/sbin/hyper-host-ctl ssl-bundle "$SITE" "$SSL_EMAIL" "$SSL_HOST" \
        && ok "SSL выдан и подключён: $SSL_HOST" \
        || warn "Выпуск не прошёл — читай текст ошибки выше, там указан конкретный лог certbot."
    fi
  fi
fi

cat <<EOTXT

Что дальше:
  1. Обнови панель в браузере с Ctrl+F5 (стили и скрипты подписаны ?v=92).
  2. Вкладка «Боты PM2» теперь показывает долю RAM/CPU от сервера, threads, PID,
     CPU time, размер папки и предупреждение о цикле перезапусков.
  3. Вкладка «SSL» → блок «SSL на www и поддомены»:
     впиши www.pixel-pc.store, нажми «Проверить домен», потом «Выпустить SSL».

CLI, если хочется руками:
  sudo hyper-host-ctl ssl-host-check-json www.pixel-pc.store
  sudo hyper-host-ctl site-aliases-set pixel-pc.store www.pixel-pc.store
  sudo hyper-host-ctl ssl-bundle pixel-pc.store ТВОЙ@EMAIL www.pixel-pc.store

Откат: файлы лежат в $BACKUP
EOTXT
