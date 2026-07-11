#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
PANEL=/var/www/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v74-deploy-center-ssl-truth-$STAMP"
REPORT=/root/hyper-host-v74-deploy-center-report.txt
mkdir -p "$BACKUP" "$BASE/deploy-center/defaults" /var/www/hyper-host-deploy/master /var/www/hyper-host-deploy/template /var/www/hyper-host-managed-bots

echo "[HYPER-HOST] Резервная копия: $BACKUP"
for f in \
  /usr/local/sbin/hyper-host-ctl \
  "$PANEL/public/index.php" "$PANEL/public/assets/style.css" "$PANEL/app/setup_db.php" \
  "$BASE/deploy-center/deploy_center.py" "$BASE/ssl-truth.py"; do
  [[ -e "$f" ]] || continue
  mkdir -p "$BACKUP$(dirname "$f")"
  cp -a "$f" "$BACKUP$f"
done
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"
if [[ -d /etc/nginx/sites-available ]]; then tar -C /etc/nginx -czf "$BACKUP/nginx-sites-before.tar.gz" sites-available sites-enabled 2>/dev/null || true; fi

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]]; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi

install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
ln -sf /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true
install -m 0755 "$ROOT/scripts/deploy_center.py" "$BASE/deploy-center/deploy_center.py"
install -m 0755 "$ROOT/scripts/ssl_truth.py" "$BASE/ssl-truth.py"

install -m 0644 "$ROOT/templates/deploy-worker/bot.py" "$BASE/deploy-center/defaults/master-bot.py"
install -m 0644 "$ROOT/templates/deploy-worker/requirements.txt" "$BASE/deploy-center/defaults/master-requirements.txt"
install -m 0644 "$ROOT/templates/project-bot/bot.py" "$BASE/deploy-center/defaults/project-bot.py"
install -m 0644 "$ROOT/templates/project-bot/requirements.txt" "$BASE/deploy-center/defaults/project-requirements.txt"

[[ -f /var/www/hyper-host-deploy/master/bot.py ]] || cp "$BASE/deploy-center/defaults/master-bot.py" /var/www/hyper-host-deploy/master/bot.py
[[ -f /var/www/hyper-host-deploy/master/requirements.txt ]] || cp "$BASE/deploy-center/defaults/master-requirements.txt" /var/www/hyper-host-deploy/master/requirements.txt
[[ -f /var/www/hyper-host-deploy/template/bot.py ]] || cp "$BASE/deploy-center/defaults/project-bot.py" /var/www/hyper-host-deploy/template/bot.py
[[ -f /var/www/hyper-host-deploy/template/requirements.txt ]] || cp "$BASE/deploy-center/defaults/project-requirements.txt" /var/www/hyper-host-deploy/template/requirements.txt

install -m 0644 "$ROOT/src/public/index.php" "$PANEL/public/index.php"
install -m 0644 "$ROOT/src/public/assets/style.css" "$PANEL/public/assets/style.css"
install -m 0644 "$ROOT/src/app/setup_db.php" "$PANEL/app/setup_db.php"
chown -R www-data:www-data "$PANEL/public" "$PANEL/app/setup_db.php" 2>/dev/null || true

php "$PANEL/app/setup_db.php" admin '__KEEP_EXISTING_ADMIN_PASSWORD__' >/tmp/hyper-host-v74-db.log
chown www-data:www-data "$DATA" "$DATA"-* 2>/dev/null || true
chmod 0660 "$DATA" "$DATA"-* 2>/dev/null || true

if ! command -v python3 >/dev/null 2>&1 || ! python3 -m venv --help >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt-get install -y python3 python3-venv python3-pip >/dev/null
fi
if ! command -v pm2 >/dev/null 2>&1; then
  if ! command -v npm >/dev/null 2>&1; then apt-get update -y >/dev/null; apt-get install -y nodejs npm >/dev/null; fi
  npm install -g pm2@latest >/dev/null
fi

/usr/local/sbin/hyper-host-ctl deploy-center-install >/tmp/hyper-host-v74-deploy-install.json

# Забираем пароль существующего аккаунта mystock из базы панели, не вшивая пароль в GitHub/архив.
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
  /usr/local/sbin/hyper-host-ctl deploy-center-config save 90.189.208.25 3306 mystock "$MYSTOCK_PASS" mystock >/tmp/hyper-host-v74-deploy-config.json || true
fi

chown -R hyperbot:www-data /var/www/hyper-host-deploy /var/www/hyper-host-managed-bots /var/www/hyper-host-bots 2>/dev/null || true
chmod 2775 /var/www/hyper-host-deploy /var/www/hyper-host-deploy/master /var/www/hyper-host-deploy/template /var/www/hyper-host-managed-bots 2>/dev/null || true

SYNC_STATUS='не запускалась: пароль MySQL не найден в локальной базе панели'
if [[ -n "$MYSTOCK_PASS" ]]; then
  if /usr/local/sbin/hyper-host-ctl deploy-center-sync >/tmp/hyper-host-v74-projects.json 2>/tmp/hyper-host-v74-projects.err; then
    SYNC_STATUS="успешно"
  else
    SYNC_STATUS="ошибка: $(tail -n 3 /tmp/hyper-host-v74-projects.err | tr '\n' ' ')"
  fi
fi

SSL_BEFORE="$(/usr/local/sbin/hyper-host-ctl ssl-audit-json 2>/dev/null || echo '{"ok":false}')"
CERT_ONLY="$(printf '%s' "$SSL_BEFORE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(1 for x in d.get("sites",[]) if x.get("status")=="cert_only") + (1 if d.get("panel",{}).get("status")=="cert_only" else 0))' 2>/dev/null || echo 0)"
SSL_RESTORE='не требовалось'
if [[ "$CERT_ONLY" =~ ^[0-9]+$ && "$CERT_ONLY" -gt 0 ]]; then
  if /usr/local/sbin/hyper-host-ctl ssl-restore-existing >/tmp/hyper-host-v74-ssl-restore.json 2>/tmp/hyper-host-v74-ssl-restore.err; then
    SSL_RESTORE="подключено существующих сертификатов: $CERT_ONLY"
  else
    SSL_RESTORE="не удалось автоматически подключить; конфиги Nginx возвращены"
    if [[ -f "$BACKUP/nginx-sites-before.tar.gz" ]]; then
      rm -rf /etc/nginx/sites-available /etc/nginx/sites-enabled
      tar -C /etc/nginx -xzf "$BACKUP/nginx-sites-before.tar.gz"
      nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    fi
  fi
fi
SSL_AFTER="$(/usr/local/sbin/hyper-host-ctl ssl-audit-json 2>/dev/null || echo '{"ok":false}')"

ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
if [[ -n "$ADMIN_HASH_BEFORE" && "$ADMIN_HASH_BEFORE" != "$ADMIN_HASH_AFTER" ]]; then
  echo '[HYPER-HOST] ERROR: хеш пароля admin изменился, возвращаю SQLite' >&2
  cp -a "$BACKUP/hyperhost.sqlite" "$DATA"
  chown www-data:www-data "$DATA"; chmod 0660 "$DATA"
  exit 1
fi

DOCTOR="$(/usr/local/sbin/hyper-host-ctl deploy-center-doctor 2>/dev/null || echo '{"ok":false}')"
ACTIVE_SSL="$(printf '%s' "$SSL_AFTER" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(1 for x in d.get("sites",[]) if x.get("status")=="active") + (1 if d.get("panel",{}).get("status")=="active" else 0))' 2>/dev/null || echo 0)"
MISSING_SSL="$(printf '%s' "$SSL_AFTER" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(1 for x in d.get("sites",[]) if x.get("status") in ("missing","expired")))' 2>/dev/null || echo 0)"

cat > "$REPORT" <<EOF
HYPER-HOST v74 — MyStock Deploy Center + truthful SSL

Deploy Center:
  Master:   /var/www/hyper-host-deploy/master
  Template: /var/www/hyper-host-deploy/template
  Projects: /var/www/hyper-host-managed-bots
  SQL sync: $SYNC_STATUS
  Doctor:   $DOCTOR

SSL:
  Restore:  $SSL_RESTORE
  Active:   $ACTIVE_SSL
  Missing/expired: $MISSING_SSL
  Audit:    $SSL_AFTER

Admin password: unchanged
Backup: $BACKUP
EOF
chmod 0600 "$REPORT"

echo
printf '%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — Deploy Center установлен'
printf '%s\n' '============================================================'
printf ' Главный deploy-бот:  %s\n' '/var/www/hyper-host-deploy/master'
printf ' Шаблон магазинов:    %s\n' '/var/www/hyper-host-deploy/template'
printf ' Папки проектов:      %s\n' '/var/www/hyper-host-managed-bots'
printf ' Синхронизация SQL:    %s\n' "$SYNC_STATUS"
printf ' SSL активно сейчас:   %s\n' "$ACTIVE_SSL"
printf ' SSL без сертификата:  %s\n' "$MISSING_SSL"
printf ' Admin password:       НЕ ИЗМЕНЁН\n'
printf ' Отчёт:                %s\n' "$REPORT"
printf '%s\n' '============================================================'
