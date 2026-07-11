#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
PANEL=/var/www/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v77-deploy-delete-bots-$STAMP"
REPORT=/root/hyper-host-v77-deploy-delete-bots-report.txt
mkdir -p "$BACKUP" "$BASE/deploy-center"

printf '[HYPER-HOST] Резервная копия: %s\n' "$BACKUP"
for f in "$PANEL/public/index.php" "$BASE/deploy-center/deploy_center.py"; do
  [[ -e "$f" ]] || continue
  mkdir -p "$BACKUP$(dirname "$f")"
  cp -a "$f" "$BACKUP$f"
done
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]]; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi

printf '%s\n' '[HYPER-HOST] Добавляю только полное удаление дочерних ботов в Deploy Manager.'
install -m 0755 "$ROOT/scripts/deploy_center.py" "$BASE/deploy-center/deploy_center.py"
install -m 0644 "$ROOT/src/public/index.php" "$PANEL/public/index.php"
chown root:root "$BASE/deploy-center/deploy_center.py" 2>/dev/null || true
chown www-data:www-data "$PANEL/public/index.php" 2>/dev/null || true

python3 -m py_compile "$BASE/deploy-center/deploy_center.py"
php -l "$PANEL/public/index.php" >/dev/null

ADMIN_HASH_AFTER=""
if [[ -f "$DATA" ]]; then
  ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi
if [[ -n "$ADMIN_HASH_BEFORE" && "$ADMIN_HASH_BEFORE" != "$ADMIN_HASH_AFTER" ]]; then
  printf '%s\n' '[HYPER-HOST] ERROR: пароль admin изменился — возвращаю файлы' >&2
  [[ -f "$BACKUP$PANEL/public/index.php" ]] && cp -a "$BACKUP$PANEL/public/index.php" "$PANEL/public/index.php"
  [[ -f "$BACKUP$BASE/deploy-center/deploy_center.py" ]] && cp -a "$BACKUP$BASE/deploy-center/deploy_center.py" "$BASE/deploy-center/deploy_center.py"
  exit 1
fi

rm -rf "$BASE/cache"/* 2>/dev/null || true
systemctl reload php*-fpm 2>/dev/null || true

cat > "$REPORT" <<EOF2
HYPER-HOST v77 — Deploy Manager delete bots

New UI: red Delete button for every managed project.
Delete operation:
- PM2 process removed
- project directory removed
- project .env / venv / logs removed with directory
- PM2 stdout/stderr log files removed
- bot_deployments row removed
- projects/users/token in MyStock MySQL are NOT removed
- master deploy bot and template are NOT changed

Safety: files can be removed only inside /var/www/hyper-host-managed-bots.
Admin password: unchanged
FTP/SSL/Nginx/SQL/sites: unchanged
Backup: $BACKUP
EOF2
chmod 0600 "$REPORT"

printf '\n%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — удаление ботов добавлено'
printf '%s\n' '============================================================'
printf ' Страница:             %s\n' '/?page=deploy_center'
printf ' Кнопка:               %s\n' 'Удалить — в строке каждого проекта'
printf ' Удаляется:            %s\n' 'PM2 + папка + .env + venv + логи + deployment'
printf ' Проект в MySQL:       %s\n' 'СОХРАНЯЕТСЯ'
printf ' Master/template:      %s\n' 'НЕ ИЗМЕНЯЛИСЬ'
printf ' Admin password:       %s\n' 'НЕ ИЗМЕНЁН'
printf ' Отчёт:                %s\n' "$REPORT"
printf '%s\n' '============================================================'
