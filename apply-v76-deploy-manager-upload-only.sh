#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
PANEL=/var/www/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v76-deploy-manager-upload-only-$STAMP"
REPORT=/root/hyper-host-v76-deploy-manager-report.txt
MASTER=/var/www/hyper-host-deploy/master
TEMPLATE=/var/www/hyper-host-deploy/template
MANAGED=/var/www/hyper-host-managed-bots
mkdir -p "$BACKUP" "$BASE/deploy-center" "$MASTER" "$TEMPLATE" "$MANAGED"

printf '[HYPER-HOST] Резервная копия: %s\n' "$BACKUP"
for f in \
  /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper \
  "$PANEL/public/index.php" "$PANEL/public/assets/style.css" "$PANEL/public/assets/app.js" \
  "$PANEL/app/setup_db.php" "$BASE/deploy-center/deploy_center.py"; do
  [[ -e "$f" ]] || continue
  mkdir -p "$BACKUP$(dirname "$f")"
  cp -a "$f" "$BACKUP$f"
done
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"
[[ -d "$MASTER" ]] && tar -C "$(dirname "$MASTER")" -czf "$BACKUP/master-before.tar.gz" "$(basename "$MASTER")" 2>/dev/null || true
[[ -d "$TEMPLATE" ]] && tar -C "$(dirname "$TEMPLATE")" -czf "$BACKUP/template-before.tar.gz" "$(basename "$TEMPLATE")" 2>/dev/null || true

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]]; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi

printf '%s\n' '[HYPER-HOST] Устанавливаю Deploy Manager без примеров и автосоздания файлов ботов.'
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install -m 0755 "$ROOT/scripts/hyper" /usr/local/bin/hyper
ln -sf /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true
ln -sf /usr/local/bin/hyper /usr/bin/hyper 2>/dev/null || true
install -m 0755 "$ROOT/scripts/deploy_center.py" "$BASE/deploy-center/deploy_center.py"
install -m 0755 "$ROOT/scripts/ssl_truth.py" "$BASE/ssl-truth.py"


install -m 0644 "$ROOT/src/public/index.php" "$PANEL/public/index.php"
install -m 0644 "$ROOT/src/public/assets/style.css" "$PANEL/public/assets/style.css"
install -m 0644 "$ROOT/src/public/assets/app.js" "$PANEL/public/assets/app.js"
install -m 0644 "$ROOT/src/app/setup_db.php" "$PANEL/app/setup_db.php"
chown www-data:www-data "$PANEL/public/index.php" "$PANEL/public/assets/style.css" "$PANEL/public/assets/app.js" "$PANEL/app/setup_db.php" 2>/dev/null || true

php -l "$PANEL/public/index.php" >/dev/null
php -l "$PANEL/app/setup_db.php" >/dev/null
php "$PANEL/app/setup_db.php" admin '__KEEP_EXISTING_ADMIN_PASSWORD__' >/tmp/hyper-host-v75-db.log
chown www-data:www-data "$DATA" "$DATA"-* 2>/dev/null || true
chmod 0660 "$DATA" "$DATA"-* 2>/dev/null || true

if ! id hyperbot >/dev/null 2>&1; then
  useradd --system --home /var/www/hyper-host-bots --shell /usr/sbin/nologin hyperbot
fi
usermod -aG www-data hyperbot 2>/dev/null || true

if ! command -v python3 >/dev/null 2>&1 || ! python3 -m venv --help >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt-get install -y python3 python3-venv python3-pip >/dev/null
fi
if ! command -v pm2 >/dev/null 2>&1; then
  if ! command -v npm >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    apt-get install -y nodejs npm >/dev/null
  fi
  npm install -g pm2@latest >/dev/null
fi

if [[ ! -x "$BASE/deploy-center/venv/bin/python" ]]; then
  python3 -m venv "$BASE/deploy-center/venv"
fi
"$BASE/deploy-center/venv/bin/python" -m pip install --upgrade pip wheel setuptools >/dev/null
"$BASE/deploy-center/venv/bin/pip" install 'PyMySQL>=1.1,<2' >/dev/null

chown -R hyperbot:www-data /var/www/hyper-host-deploy "$MANAGED" /var/www/hyper-host-bots 2>/dev/null || true
chmod 2775 /var/www/hyper-host-deploy "$MASTER" "$TEMPLATE" "$MANAGED" /var/www/hyper-host-bots 2>/dev/null || true

# Удаляем только старые файлы-заглушки v74, если пользователь их не изменял.
OLD_MASTER_HASH='9cd04ef8e2b06dd6fe04085958de01142441ed89026a4cc4ea1aebb435d61656'
OLD_TEMPLATE_HASH='f38fcc450e3dae8508e7781c2e2edcadff3c6f62bef1d21959f1b91db2fe1429'
REMOVED_PLACEHOLDERS=()
if [[ -f "$MASTER/bot.py" && "$(sha256sum "$MASTER/bot.py" | awk '{print $1}')" == "$OLD_MASTER_HASH" ]]; then
  rm -f "$MASTER/bot.py"
  REMOVED_PLACEHOLDERS+=("master/bot.py")
  sudo -u hyperbot -H env HOME=/var/www/hyper-host-bots PM2_HOME=/var/www/hyper-host-bots/.pm2 pm2 delete mystock_deploy_worker >/dev/null 2>&1 || true
fi
if [[ -f "$TEMPLATE/bot.py" && "$(sha256sum "$TEMPLATE/bot.py" | awk '{print $1}')" == "$OLD_TEMPLATE_HASH" ]]; then
  rm -f "$TEMPLATE/bot.py"
  REMOVED_PLACEHOLDERS+=("template/bot.py")
fi

/usr/local/sbin/hyper-host-ctl deploy-center-install >/tmp/hyper-host-v75-install.json

# Забираем пароль mystock только из уже сохранённого аккаунта панели.
MYSTOCK_PASS=""
if [[ -f "$DATA" ]]; then
  MYSTOCK_PASS="$(php -r '
    $p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");
    foreach (["SELECT password_plain FROM mysql_accounts WHERE username=\"mystock\" ORDER BY id DESC LIMIT 1","SELECT db_password_plain FROM databases WHERE db_user=\"mystock\" ORDER BY id DESC LIMIT 1"] as $q) {
      try {$v=$p->query($q)->fetchColumn(); if($v){echo $v; break;}} catch(Throwable $e){}
    }
  ' 2>/dev/null || true)"
fi
if [[ -n "$MYSTOCK_PASS" ]]; then
  /usr/local/sbin/hyper-host-ctl deploy-center-config save 90.189.208.25 3306 mystock "$MYSTOCK_PASS" mystock >/tmp/hyper-host-v75-config.json
fi

SYNC_STATUS='не выполнена: в панели не найден сохранённый пароль MySQL пользователя mystock'
if [[ -n "$MYSTOCK_PASS" ]]; then
  if /usr/local/sbin/hyper-host-ctl deploy-center-sync >/tmp/hyper-host-v75-projects.json 2>/tmp/hyper-host-v75-projects.err; then
    SYNC_STATUS="успешно: $(python3 -c 'import json;print(json.load(open("/tmp/hyper-host-v75-projects.json")).get("count",0))' 2>/dev/null || echo '?') проектов"
  else
    SYNC_STATUS="ошибка: $(tail -n 4 /tmp/hyper-host-v75-projects.err | tr '\n' ' ')"
  fi
fi

DOCTOR="$(/usr/local/sbin/hyper-host-ctl deploy-center-doctor 2>/dev/null || echo '{"ok":false}')"
SSL_AUDIT="$(/usr/local/sbin/hyper-host-ctl ssl-audit-json 2>/dev/null || echo '{"ok":false,"error":"audit failed"}')"

ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
if [[ -n "$ADMIN_HASH_BEFORE" && "$ADMIN_HASH_BEFORE" != "$ADMIN_HASH_AFTER" ]]; then
  printf '%s\n' '[HYPER-HOST] ERROR: пароль admin изменился — возвращаю SQLite' >&2
  cp -a "$BACKUP/hyperhost.sqlite" "$DATA"
  chown www-data:www-data "$DATA"; chmod 0660 "$DATA"
  exit 1
fi

rm -rf "$BASE/cache"/* 2>/dev/null || true
systemctl reload php*-fpm 2>/dev/null || true

cat > "$REPORT" <<EOF
HYPER-HOST v76 — Deploy Manager upload-only

Page: /?page=deploy_center
Master files (uploaded only through panel): $MASTER/{bot.py,.env,requirements.txt}
Store template (uploaded only through panel): $TEMPLATE/{bot.py,requirements.txt}
Installer-created bot files: none
Managed projects: $MANAGED/<project_id>-<project_name>/

SQL sync: $SYNC_STATUS
Doctor: $DOCTOR
Removed untouched v74 placeholders: ${REMOVED_PLACEHOLDERS[*]:-none}

SSL was NOT changed by v76.
Actual SSL audit: $SSL_AUDIT

Admin password: unchanged
Backup: $BACKUP
EOF
chmod 0600 "$REPORT"

printf '\n%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — Deploy Manager v76 установлен'
printf '%s\n' '============================================================'
printf ' Отдельная страница:      %s\n' '/?page=deploy_center'
printf ' Главный бот:             %s\n' "$MASTER"
printf ' Файлы новых магазинов:   %s\n' "$TEMPLATE"
printf ' Папки магазинов:         %s\n' "$MANAGED"
printf ' Автофайлы/примеры:       НЕ СОЗДАЮТСЯ\n'
printf ' SQL sync:                %s\n' "$SYNC_STATUS"
printf ' SSL:                     НЕ ИЗМЕНЯЛСЯ, смотри аудит на странице SSL\n'
printf ' Admin password:          НЕ ИЗМЕНЁН\n'
printf ' Отчёт:                   %s\n' "$REPORT"
printf '%s\n' '============================================================'
