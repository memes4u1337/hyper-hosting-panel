#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# HYPER-HOST doctor — диагностика и починка того, что чаще всего отваливается.
# powered by memes4u1337
#
#   sudo bash doctor.sh            # только диагностика, ничего не меняет
#   sudo bash doctor.sh --fix      # диагностика + автоматическая починка
#
# Проверяет:
#   1) HYPER CLOUD (cloud.hyper-host.pw) — причина HTTP 500
#   2) SSL — почему панель не показывает сертификаты и срок их действия
#   3) Панель, nginx, PHP-FPM, права
# ==============================================================================

FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

BASE_DIR="/opt/hyper-host"
PANEL_DIR="/var/www/hyper-host"
CLOUD_APP="/var/www/hyper-host-cloud-app"
CLOUD_STORAGE="/var/www/hyper-host-cloud"
CLOUD_META="/var/lib/hyper-host-cloud"
CLOUD_USER="hypercloud"
CLOUD_SOCK="/run/php/hypercloud.sock"
CLOUD_DOMAIN="${CLOUD_DOMAIN:-cloud.hyper-host.pw}"
SSL_TRUTH="$BASE_DIR/ssl-truth.py"

PROBLEMS=0
FIXED=0

hdr(){ printf '\n\033[1;36m━━ %s\033[0m\n' "$*"; }
ok(){   printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
bad(){  printf '  \033[1;31m✘\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }
did(){  printf '    \033[1;35m→ починено:\033[0m %s\n' "$*"; FIXED=$((FIXED+1)); }
hint(){ printf '    \033[2m%s\033[0m\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Запусти от root: sudo bash doctor.sh"; exit 1; }

# ============================================================== 1. HYPER CLOUD
hdr "HYPER CLOUD — $CLOUD_DOMAIN"

if [[ ! -d "$CLOUD_APP" ]]; then
  bad "Приложение облака не установлено: $CLOUD_APP"
  hint "Установи облако: sudo bash install-cloud.sh"
else
  ok "Каталог приложения на месте: $CLOUD_APP"

  # --- 1.1 файлы приложения
  MISSING=""
  for f in app/bootstrap.php app/filelib.php public/index.php public/api/upload.php; do
    [[ -f "$CLOUD_APP/$f" ]] || MISSING="$MISSING $f"
  done
  if [[ -n "$MISSING" ]]; then
    bad "Не хватает файлов облака:$MISSING"
    hint "Это первая причина HTTP 500 — index.php делает require несуществующего bootstrap."
    hint "Лечится: sudo bash update.sh"
  else
    ok "Все файлы приложения на месте"
  fi

  # --- 1.2 системный пользователь и PHP-FPM пул
  if id "$CLOUD_USER" >/dev/null 2>&1; then
    ok "Пользователь $CLOUD_USER существует"
  else
    bad "Нет системного пользователя $CLOUD_USER"
  fi

  if [[ -S "$CLOUD_SOCK" ]]; then
    ok "PHP-FPM сокет облака активен: $CLOUD_SOCK"
  else
    bad "Нет PHP-FPM сокета облака: $CLOUD_SOCK"
    hint "Без сокета nginx отдаёт 502/500. Проверь: systemctl status php*-fpm"
    if [[ $FIX -eq 1 ]]; then
      while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        systemctl restart "$unit" >/dev/null 2>&1 || true
      done < <(systemctl list-units --type=service 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
      sleep 2
      [[ -S "$CLOUD_SOCK" ]] && did "PHP-FPM перезапущен, сокет поднялся"
    fi
  fi

  # --- 1.3 права на SQLite-базу облака (самая частая причина 500)
  CLOUD_DB="$CLOUD_META/cloud.sqlite"
  if [[ ! -d "$CLOUD_META" ]]; then
    bad "Нет каталога метаданных облака: $CLOUD_META"
    if [[ $FIX -eq 1 ]]; then
      mkdir -p "$CLOUD_META/uploads" "$CLOUD_META/sessions" "$CLOUD_META/tmp"
      chown -R "$CLOUD_USER:$CLOUD_USER" "$CLOUD_META" 2>/dev/null || true
      chmod 02770 "$CLOUD_META"
      did "каталог $CLOUD_META создан"
    fi
  else
    if sudo -u "$CLOUD_USER" test -w "$CLOUD_META" 2>/dev/null; then
      ok "Каталог $CLOUD_META доступен на запись пользователю $CLOUD_USER"
    else
      bad "$CLOUD_META недоступен на запись для $CLOUD_USER"
      hint "PDO не может открыть SQLite → необработанное исключение → HTTP 500."
      if [[ $FIX -eq 1 ]]; then
        chown -R "$CLOUD_USER:$CLOUD_USER" "$CLOUD_META"
        chmod 02770 "$CLOUD_META"
        did "права на $CLOUD_META восстановлены"
      fi
    fi
    if [[ -f "$CLOUD_DB" ]]; then
      if sudo -u "$CLOUD_USER" test -w "$CLOUD_DB" 2>/dev/null; then
        ok "База облака доступна на запись"
      else
        bad "База $CLOUD_DB недоступна на запись для $CLOUD_USER"
        if [[ $FIX -eq 1 ]]; then
          chown "$CLOUD_USER:$CLOUD_USER" "$CLOUD_DB" "$CLOUD_DB"-wal "$CLOUD_DB"-shm 2>/dev/null || true
          chmod 0660 "$CLOUD_DB" 2>/dev/null || true
          did "права на базу облака восстановлены"
        fi
      fi
    else
      warn "База ещё не создана — появится при первом входе"
    fi
  fi

  # --- 1.4 хранилище
  if [[ -d "$CLOUD_STORAGE" ]] && sudo -u "$CLOUD_USER" test -w "$CLOUD_STORAGE" 2>/dev/null; then
    ok "Хранилище доступно: $CLOUD_STORAGE"
  else
    bad "Хранилище $CLOUD_STORAGE отсутствует или недоступно на запись"
    if [[ $FIX -eq 1 ]]; then
      mkdir -p "$CLOUD_STORAGE/users" "$CLOUD_STORAGE/shared"
      chown -R "$CLOUD_USER:$CLOUD_USER" "$CLOUD_STORAGE"
      chmod -R 02770 "$CLOUD_STORAGE"
      did "хранилище создано и права выставлены"
    fi
  fi

  # --- 1.5 helper входа администратора панели
  if [[ -x /usr/local/sbin/hyper-cloud-panel-auth ]]; then
    ok "Helper авторизации панели установлен"
    if sudo -n -u "$CLOUD_USER" sudo -n -l /usr/local/sbin/hyper-cloud-panel-auth >/dev/null 2>&1; then
      ok "sudoers для helper настроен"
    else
      warn "Нет правила sudoers — вход администратора панели в облако не сработает"
      hint "Логин обычных облачных пользователей при этом работает."
    fi
  else
    bad "Нет /usr/local/sbin/hyper-cloud-panel-auth"
  fi

  # --- 1.6 nginx vhost
  if [[ -f /etc/nginx/hyper-host-managed/15-cloud-app.conf ]]; then
    ok "nginx vhost облака существует"
    if grep -q "root $CLOUD_APP/public" /etc/nginx/hyper-host-managed/15-cloud-app.conf; then
      ok "root указывает на $CLOUD_APP/public"
    else
      bad "root в vhost указывает не туда — типовая причина 500/белой страницы"
      [[ $FIX -eq 1 ]] && { "$BASE_DIR/bin/hyper-cloud-nginx-fragment.sh" && did "vhost перегенерирован"; }
    fi
  else
    bad "Нет nginx vhost для $CLOUD_DOMAIN"
    if [[ $FIX -eq 1 && -x "$BASE_DIR/bin/hyper-cloud-nginx-fragment.sh" ]]; then
      "$BASE_DIR/bin/hyper-cloud-nginx-fragment.sh" && did "vhost сгенерирован"
    fi
  fi

  # --- 1.7 последняя ошибка PHP
  for LOG in /var/log/hyper-cloud/php-error.log /var/log/nginx/hyper-cloud/error-ssl.log /var/log/nginx/hyper-cloud/error.log; do
    if [[ -s "$LOG" ]]; then
      printf '\n  \033[1;33mПоследние ошибки %s:\033[0m\n' "$LOG"
      tail -n 6 "$LOG" | sed 's/^/      /'
    fi
  done
fi

# ===================================================================== 2. SSL
hdr "SSL"

if [[ -f "$SSL_TRUTH" ]]; then
  ok "ssl-truth.py установлен"
  if AUDIT="$(SERVER_IP="${SERVER_IP:-}" python3 "$SSL_TRUTH" audit 2>&1)"; then
    if echo "$AUDIT" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") else 1)' 2>/dev/null; then
      ok "Аудит SSL отвечает корректным JSON — панель увидит сертификаты и сроки"
      echo "$AUDIT" | python3 - <<'PY' 2>/dev/null || true
import sys,json
d=json.load(sys.stdin)
for s in d.get('sites',[]):
    c=s.get('certificate') or {}
    print("      %-32s %-10s %s дней  до %s" % (
        s.get('domain',''), s.get('status',''),
        c.get('days_left','?'), (c.get('expires','') or '')[:10]))
PY
    else
      bad "Аудит SSL вернул ok=false"
      echo "$AUDIT" | head -n 5 | sed 's/^/      /'
    fi
  else
    bad "ssl-truth.py падает — поэтому во вкладке SSL пусто и не видно сроков"
    echo "$AUDIT" | head -n 10 | sed 's/^/      /'
    hint "Чаще всего не хватает python3 или certbot. Лечится: sudo bash doctor.sh --fix"
    if [[ $FIX -eq 1 ]]; then
      apt-get install -y python3 certbot >/dev/null 2>&1 && did "python3/certbot доустановлены"
    fi
  fi
else
  bad "Не установлен $SSL_TRUTH — вкладка SSL не может показать состояние сертификатов"
  hint "Лечится: sudo bash update.sh"
fi

if command -v certbot >/dev/null 2>&1; then
  ok "certbot установлен ($(certbot --version 2>&1 | head -1))"
else
  bad "certbot не установлен — выпуск SSL из панели работать не будет"
  [[ $FIX -eq 1 ]] && apt-get install -y certbot >/dev/null 2>&1 && did "certbot установлен"
fi

ACME="$BASE_DIR/acme-webroot/.well-known/acme-challenge"
if [[ -d "$ACME" ]]; then
  ok "ACME webroot существует"
else
  bad "Нет ACME webroot: $ACME"
  if [[ $FIX -eq 1 ]]; then
    mkdir -p "$ACME"; chown -R www-data:www-data "$BASE_DIR/acme-webroot"; chmod -R 0755 "$BASE_DIR/acme-webroot"
    did "ACME webroot создан"
  fi
fi

# Кэш панели может держать устаревший «нет SSL» до 30 минут
if [[ $FIX -eq 1 && -d "$BASE_DIR/cache" ]]; then
  rm -f "$BASE_DIR/cache"/*.json 2>/dev/null || true
  did "кэш панели очищен (SSL-статусы перечитаются сразу)"
fi

# =========================================================== 2b. Клиентский портал
hdr "Клиентский портал — cp.hyper-host.pw"

CP_APP="/var/www/hyper-host-cp"
CP_META="/var/lib/hyper-host-cp"
CP_USER="hypercp"

if [[ ! -d "$CP_APP" ]]; then
  warn "Портал не установлен (это нормально, если он не нужен)"
  hint "Установить: sudo bash install-cp.sh"
else
  ok "Приложение портала на месте"
  [[ -S /run/php/hypercp.sock ]] && ok "PHP-FPM сокет портала активен" || bad "Нет сокета /run/php/hypercp.sock"

  if [[ -x /usr/local/sbin/hyper-cp-bridge ]]; then
    ok "Root-мост установлен"
    if sudo -n -u "$CP_USER" sudo -n -l /usr/local/sbin/hyper-cp-bridge >/dev/null 2>&1; then
      ok "sudoers для портала настроен"
    else
      bad "Нет правила sudoers — портал не сможет создавать сайты и ботов"
    fi
  else
    bad "Нет /usr/local/sbin/hyper-cp-bridge"
  fi

  if [[ -f "$CP_META/cp.sqlite" ]]; then
    sudo -u "$CP_USER" test -w "$CP_META/cp.sqlite" && ok "База портала доступна порталу" || bad "База портала недоступна на запись для $CP_USER"
    sudo -u www-data test -w "$CP_META/cp.sqlite" && ok "База портала доступна админ-панели" || {
      bad "Админ-панель не видит базу портала — раздел «Клиенты» не откроется"
      hint "www-data должен состоять в группе $CP_USER"
      if [[ $FIX -eq 1 ]]; then
        usermod -aG "$CP_USER" www-data
        chmod 2770 "$CP_META"; chmod 0660 "$CP_META"/cp.sqlite* 2>/dev/null || true
        while IFS= read -r unit; do [[ -n "$unit" ]] || continue; systemctl restart "$unit" >/dev/null 2>&1 || true;
        done < <(systemctl list-units --type=service 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
        did "www-data добавлен в группу $CP_USER, PHP-FPM перезапущен"
      fi
    }
  else
    warn "База портала ещё не создана"
  fi

  if [[ -f /etc/proftpd/conf.d/hyper-cp.conf ]]; then
    ok "FTP-chroot клиентов настроен (DefaultRoot ~)"
  else
    bad "Нет /etc/proftpd/conf.d/hyper-cp.conf — клиент увидит чужие папки по FTP"
    if [[ $FIX -eq 1 && -d /etc/proftpd ]]; then
      mkdir -p /etc/proftpd/conf.d
      printf 'DefaultRoot ~\nRequireValidShell off\nAllowOverwrite on\n' > /etc/proftpd/conf.d/hyper-cp.conf
      chmod 0644 /etc/proftpd/conf.d/hyper-cp.conf
      systemctl reload proftpd >/dev/null 2>&1 || true
      did "FTP-chroot включён"
    fi
  fi

  UNITS="$(systemctl list-units --type=service 'hyper-cp-*' --no-legend 2>/dev/null | wc -l)"
  ok "Юнитов ботов клиентов запущено: ${UNITS:-0}"
  [[ -s /var/log/hyper-cp/php-error.log ]] && {
    printf '\n  \033[1;33mПоследние ошибки портала:\033[0m\n'
    tail -n 6 /var/log/hyper-cp/php-error.log | sed 's/^/      /'
  }
fi

# ================================================================== 3. Панель
hdr "Панель и сервисы"

for svc in nginx mysql mariadb; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
    st="$(systemctl is-active "$svc" 2>/dev/null || true)"
    [[ "$st" == "active" ]] && ok "$svc: $st" || bad "$svc: $st"
  fi
done

if nginx -t >/dev/null 2>&1; then ok "Конфигурация nginx валидна"; else bad "nginx -t падает"; nginx -t 2>&1 | sed 's/^/      /'; fi

if [[ -f "$PANEL_DIR/app/config.php" ]]; then
  ok "config.php панели на месте"
else
  bad "Нет $PANEL_DIR/app/config.php — панель отдаст 500"
fi

DBP="$(php8.3 -r 'echo (require "'"$PANEL_DIR"'/app/config.php")["db_path"] ?? "";' 2>/dev/null || php -r 'echo (require "'"$PANEL_DIR"'/app/config.php")["db_path"] ?? "";' 2>/dev/null || true)"
if [[ -n "$DBP" && -f "$DBP" ]]; then
  if sudo -u www-data test -w "$DBP"; then ok "База панели доступна на запись"; else
    bad "База панели $DBP недоступна на запись для www-data"
    [[ $FIX -eq 1 ]] && { chown www-data:www-data "$DBP"; chmod 0660 "$DBP"; did "права на базу панели восстановлены"; }
  fi
fi

if [[ -x /usr/local/sbin/hyper-host-ctl ]]; then ok "hyper-host-ctl установлен"; else bad "Нет /usr/local/sbin/hyper-host-ctl"; fi

# ==================================================================== ИТОГ
hdr "Итог"
if [[ $PROBLEMS -eq 0 ]]; then
  printf '  \033[1;32mПроблем не найдено.\033[0m\n\n'
else
  printf '  Найдено проблем: \033[1;31m%s\033[0m\n' "$PROBLEMS"
  [[ $FIXED -gt 0 ]] && printf '  Починено автоматически: \033[1;32m%s\033[0m\n' "$FIXED"
  if [[ $FIX -eq 0 ]]; then
    printf '\n  Запусти с починкой:  \033[1;36msudo bash doctor.sh --fix\033[0m\n\n'
  else
    printf '\n  Что не починилось автоматически — смотри подсказки выше.\n\n'
  fi
fi
