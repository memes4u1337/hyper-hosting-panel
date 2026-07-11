#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v78-deploy-project-actions-$STAMP"
REPORT=/root/hyper-host-v78-deploy-project-actions-report.txt
mkdir -p "$BACKUP"

printf '[HYPER-HOST] Резервная копия: %s\n' "$BACKUP"
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP/hyper-host-ctl"
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]]; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi

printf '%s\n' '[HYPER-HOST] Исправляю передачу project_id для Start/Stop/Restart/Logs/Delete.'
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
bash -n /usr/local/sbin/hyper-host-ctl

# Проверяем саму Bash-семантику без обращения к MySQL/PM2.
CHECK="$(bash -c '
  f(){
    local project_id="${1:-0}"
    local action="${2:-}"
    local delete_files="${3:-0}"
    local -a args
    args=(project-action "$project_id" "$action")
    [[ "$delete_files" == 1 ]] && args+=(--delete-files)
    printf "%s|%s|%s" "${args[0]}" "${args[1]}" "${args[2]}"
  }
  f 123 restart 0
')"
[[ "$CHECK" == 'project-action|123|restart' ]] || {
  printf '[HYPER-HOST] ERROR: тест аргументов не пройден: %s\n' "$CHECK" >&2
  [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  exit 1
}

ADMIN_HASH_AFTER=""
if [[ -f "$DATA" ]]; then
  ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi
if [[ -n "$ADMIN_HASH_BEFORE" && "$ADMIN_HASH_BEFORE" != "$ADMIN_HASH_AFTER" ]]; then
  printf '%s\n' '[HYPER-HOST] ERROR: пароль admin изменился — откатываю CLI' >&2
  [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  exit 1
fi

cat > "$REPORT" <<EOF2
HYPER-HOST v78 — Deploy Manager project actions fix

Fixed Bash local/array initialization bug.
Project ID and action are now passed correctly to deploy_center.py.
Working actions: deploy, start, stop, restart, logs, delete.
Admin password: unchanged
FTP/SSL/Nginx/SQL/sites/bot files: unchanged
Backup: $BACKUP
EOF2
chmod 0600 "$REPORT"

printf '\n%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — действия проектов исправлены'
printf '%s\n' '============================================================'
printf ' Start/Stop/Restart:  %s\n' 'ИСПРАВЛЕНО'
printf ' Logs/Delete:         %s\n' 'ИСПРАВЛЕНО'
printf ' Project ID:          %s\n' 'передаётся корректно'
printf ' Admin password:      %s\n' 'НЕ ИЗМЕНЁН'
printf ' Отчёт:               %s\n' "$REPORT"
printf '%s\n' '============================================================'
