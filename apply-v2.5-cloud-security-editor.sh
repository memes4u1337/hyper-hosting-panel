#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER CLOUD v107 — editor/site repair + premium UI + process isolation/security hardening.
# Usage: sudo ./apply-v2.5-cloud-security-editor.sh [/root/hyper-hosting-panel]

SRC="${1:-$(pwd)}"
CLOUD_DOMAIN="${CLOUD_DOMAIN:-cloud.hyper-host.pw}"
PANEL_DOMAIN="${PANEL_DOMAIN:-panel.hyper-host.pw}"
APP_ROOT="/var/www/hyper-host-cloud-app"
STORAGE_ROOT="/var/www/hyper-host-cloud"
META_ROOT="/var/lib/hyper-host-cloud"
PANEL_ROOT="/var/www/hyper-host"
PANEL_CONFIG="$PANEL_ROOT/app/config.php"
CLOUD_CONFIG="/etc/hyper-host/cloud.php"
CLOUD_USER="hypercloud"
CLOUD_SOCK="/run/php/hypercloud.sock"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/hyper-host/backups/cloud-v107-${STAMP}"

log(){ printf '\n\033[1;36m[HYPER CLOUD]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Запустите от root"
for f in src/cloud/app/bootstrap.php src/cloud/app/filelib.php src/cloud/public/index.php src/cloud/public/editor.php src/cloud/public/site.php src/cloud/public/site-resource.php src/cloud/public/cloud.css src/cloud/public/cloud.js src/cloud/public/api/upload.php scripts/hyper-cloud-nginx-fragment.sh scripts/hyper-cloud-panel-auth; do
  [[ -f "$SRC/$f" ]] || die "Нет файла $SRC/$f"
done

log "Backup конфигурации: $BACKUP"
mkdir -p "$BACKUP"
[[ -d "$APP_ROOT" ]] && cp -a "$APP_ROOT" "$BACKUP/cloud-app" || true
[[ -f "$CLOUD_CONFIG" ]] && cp -a "$CLOUD_CONFIG" "$BACKUP/cloud.php" || true
[[ -f /etc/nginx/hyper-host-managed/15-cloud-app.conf ]] && cp -a /etc/nginx/hyper-host-managed/15-cloud-app.conf "$BACKUP/nginx-cloud.conf" || true
[[ -f "$PANEL_ROOT/public/index.php" ]] && cp -a "$PANEL_ROOT/public/index.php" "$BACKUP/panel-index.php" || true

log "Проверяю PHP и необходимые модули"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y nginx sqlite3 zip unzip p7zip-full libarchive-tools file curl ca-certificates sudo acl >/dev/null
FPM_VER="$(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)"
[[ -n "$FPM_VER" ]] || die "Не найдена версия PHP-FPM"
apt-get install -y "php${FPM_VER}-fpm" "php${FPM_VER}-sqlite3" "php${FPM_VER}-zip" "php${FPM_VER}-mbstring" "php${FPM_VER}-xml" >/dev/null
log "Cloud PHP-FPM: ${FPM_VER}, отдельный socket $CLOUD_SOCK"

if ! id "$CLOUD_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$CLOUD_USER"
fi

log "Устанавливаю Cloud-приложение и отдельные editor/site endpoints"
mkdir -p "$APP_ROOT/app" "$APP_ROOT/public/api" "$STORAGE_ROOT/users" "$STORAGE_ROOT/shared" "$META_ROOT/uploads" "$META_ROOT/sessions" "$META_ROOT/tmp" /etc/hyper-host
install -o root -g "$CLOUD_USER" -m 0640 "$SRC/src/cloud/app/bootstrap.php" "$APP_ROOT/app/bootstrap.php"
install -o root -g "$CLOUD_USER" -m 0640 "$SRC/src/cloud/app/filelib.php" "$APP_ROOT/app/filelib.php"
for f in index.php editor.php site.php site-resource.php; do install -o root -g "$CLOUD_USER" -m 0640 "$SRC/src/cloud/public/$f" "$APP_ROOT/public/$f"; done
install -o root -g root -m 0644 "$SRC/src/cloud/public/cloud.css" "$APP_ROOT/public/cloud.css"
install -o root -g root -m 0644 "$SRC/src/cloud/public/cloud.js" "$APP_ROOT/public/cloud.js"
install -o root -g "$CLOUD_USER" -m 0640 "$SRC/src/cloud/public/api/upload.php" "$APP_ROOT/public/api/upload.php"
find "$APP_ROOT" -type d -exec chmod 0755 {} +
chmod 0750 "$APP_ROOT/app"

cat > "$CLOUD_CONFIG" <<PHP
<?php
return [
    'storage_root' => '$STORAGE_ROOT',
    'cloud_meta_dir' => '$META_ROOT',
    'cloud_db_path' => '$META_ROOT/cloud.sqlite',
    'panel_config' => '$PANEL_CONFIG',
    'panel_url' => 'https://$PANEL_DOMAIN',
    'cloud_url' => 'https://$CLOUD_DOMAIN',
];
PHP
chown root:"$CLOUD_USER" "$CLOUD_CONFIG"; chmod 0640 "$CLOUD_CONFIG"

# Mutable Cloud data belongs only to the dedicated Cloud process user.
chown -R "$CLOUD_USER:$CLOUD_USER" "$STORAGE_ROOT" "$META_ROOT"
find "$STORAGE_ROOT" -type d -exec chmod 0750 {} +
find "$STORAGE_ROOT" -type f -exec chmod 0640 {} + 2>/dev/null || true
find "$META_ROOT" -type d -exec chmod 0700 {} +
find "$META_ROOT" -type f -exec chmod 0600 {} + 2>/dev/null || true
chmod 0700 "$META_ROOT/sessions" "$META_ROOT/tmp" "$META_ROOT/uploads"

log "Изолирую Cloud от базы и секретов панели"
PANEL_DB="$(php -r '$c=require "/var/www/hyper-host/app/config.php"; echo (string)($c["db_path"]??"");' 2>/dev/null || true)"
[[ -n "$PANEL_DB" && -f "$PANEL_DB" ]] || die "Не найдена база панели"
cp -a "$PANEL_DB" "$BACKUP/panel-db.sqlite" 2>/dev/null || true
# Do not change the panel's owner/group layout. Explicit POSIX ACLs deny only the
# dedicated Cloud runtime account, so panel services keep their existing access.
PANEL_DB_DIR="$(dirname "$PANEL_DB")"
setfacl -m u:$CLOUD_USER:--- "$PANEL_CONFIG" "$PANEL_DB_DIR" "$PANEL_DB" 2>/dev/null || die "Не удалось изолировать Cloud от базы панели"
setfacl -m d:u:$CLOUD_USER:--- "$PANEL_DB_DIR" 2>/dev/null || true
for dbf in "$PANEL_DB-wal" "$PANEL_DB-shm"; do [[ -e "$dbf" ]] || continue; setfacl -m u:$CLOUD_USER:--- "$dbf" 2>/dev/null || true; done

install -o root -g root -m 0755 "$SRC/scripts/hyper-cloud-panel-auth" /usr/local/sbin/hyper-cloud-panel-auth
cat > /etc/sudoers.d/hyper-cloud-panel-auth <<SUDO
# HYPER CLOUD v107: only this fixed credential verifier may run as root.
$CLOUD_USER ALL=(root) NOPASSWD: /usr/local/sbin/hyper-cloud-panel-auth
SUDO
chmod 0440 /etc/sudoers.d/hyper-cloud-panel-auth
visudo -cf /etc/sudoers.d/hyper-cloud-panel-auth >/dev/null || die "Ошибка sudoers для Cloud auth helper"
mkdir -p /var/lib/hyper-cloud-auth; chown root:root /var/lib/hyper-cloud-auth; chmod 0700 /var/lib/hyper-cloud-auth

log "Создаю отдельный PHP-FPM pool пользователя $CLOUD_USER"
POOL="/etc/php/${FPM_VER}/fpm/pool.d/hypercloud.conf"
cat > "$POOL" <<POOLCONF
[hypercloud]
user = $CLOUD_USER
group = $CLOUD_USER
listen = $CLOUD_SOCK
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 14
pm.process_idle_timeout = 20s
pm.max_requests = 500
clear_env = yes
catch_workers_output = yes
php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/hyper-cloud/php-error.log
php_admin_value[session.save_path] = $META_ROOT/sessions
php_admin_value[upload_tmp_dir] = $META_ROOT/tmp
php_admin_value[sys_temp_dir] = $META_ROOT/tmp
php_admin_value[upload_max_filesize] = 8192M
php_admin_value[post_max_size] = 8192M
php_admin_value[max_execution_time] = 0
php_admin_value[max_input_time] = -1
php_admin_value[memory_limit] = 1024M
php_admin_value[session.cookie_secure] = 1
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_samesite] = Lax
php_admin_value[session.use_strict_mode] = 1
php_admin_value[expose_php] = Off
POOLCONF
mkdir -p /var/log/hyper-cloud; touch /var/log/hyper-cloud/php-error.log; chown "$CLOUD_USER:$CLOUD_USER" /var/log/hyper-cloud/php-error.log; chmod 0640 /var/log/hyper-cloud/php-error.log
systemctl restart "php${FPM_VER}-fpm"
[[ -S "$CLOUD_SOCK" ]] || die "Не создан $CLOUD_SOCK"

log "Обновляю Cloud DB без сброса аккаунтов и файлов"
# Initialize/upgrade schema as the isolated runtime user.
sudo -u "$CLOUD_USER" php -d session.save_path="$META_ROOT/sessions" -d display_errors=0 -r 'require "/var/www/hyper-host-cloud-app/app/bootstrap.php"; hc_db(); echo "CLOUD_DB_OK\n";' | grep -q CLOUD_DB_OK || die "Cloud DB не открывается"
# Ensure at least one panel admin Cloud profile exists on clean installs; existing installations are untouched.
PANEL_FIRST="$(php -r '$c=require "/var/www/hyper-host/app/config.php";$p=new PDO("sqlite:".$c["db_path"]);$r=$p->query("SELECT id,username FROM users ORDER BY id ASC LIMIT 1")->fetch(PDO::FETCH_ASSOC);if($r)echo (int)$r["id"]."|".$r["username"];' 2>/dev/null || true)"
if [[ "$PANEL_FIRST" == *"|"* ]]; then
  IFS='|' read -r PID PUSER <<< "$PANEL_FIRST"
  PID="$PID" PUSER="$PUSER" sudo -u "$CLOUD_USER" php -d session.save_path="$META_ROOT/sessions" -d display_errors=0 -r 'require "/var/www/hyper-host-cloud-app/app/bootstrap.php";$u=hc_upsert_panel_cloud_user(["id"=>(int)getenv("PID"),"username"=>(string)getenv("PUSER")]);hc_ensure_user_root($u);' || true
fi
chown -R "$CLOUD_USER:$CLOUD_USER" "$STORAGE_ROOT" "$META_ROOT"

log "Проверяю privileged auth bridge и изоляцию"
if [[ "$PANEL_FIRST" == *"|"* ]]; then
  IFS='|' read -r _ PUSER <<< "$PANEL_FIRST"
  AUTH_TEST="$(printf '{"action":"exists","username":"%s"}' "$PUSER" | sudo -u "$CLOUD_USER" sudo -n /usr/local/sbin/hyper-cloud-panel-auth 2>/dev/null || true)"
  [[ "$AUTH_TEST" == *'"exists":true'* ]] || die "Cloud auth bridge не видит пользователя панели"
fi
if sudo -u "$CLOUD_USER" test -r "$PANEL_DB"; then die "Cloud process всё ещё может читать базу панели — установка остановлена"; else echo "PANEL_DB_ISOLATED_OK"; fi
if sudo -u "$CLOUD_USER" test -w "$APP_ROOT/public/index.php"; then die "Cloud process может изменять собственный PHP-код"; else echo "CLOUD_CODE_READONLY_OK"; fi

log "Обновляю постоянный Nginx vhost"
install -o root -g root -m 0755 "$SRC/scripts/hyper-cloud-nginx-fragment.sh" /opt/hyper-host/bin/hyper-cloud-nginx-fragment.sh
# Existing v106 installations already have this hook. Add it only if absent.
if [[ -f /usr/local/sbin/hyper-host-nginx-reconcile ]] && ! grep -Fq '/opt/hyper-host/bin/hyper-cloud-nginx-fragment.sh' /usr/local/sbin/hyper-host-nginx-reconcile; then
  cp -a /usr/local/sbin/hyper-host-nginx-reconcile "$BACKUP/nginx-reconcile.before-v107"
  python3 - <<'PY'
from pathlib import Path
p=Path('/usr/local/sbin/hyper-host-nginx-reconcile');s=p.read_text();hook='\n# HYPER CLOUD v107 persistent vhost hook\nif [[ -x /opt/hyper-host/bin/hyper-cloud-nginx-fragment.sh ]]; then\n  /opt/hyper-host/bin/hyper-cloud-nginx-fragment.sh\nfi\n'
anchor='if ! TEST_OUTPUT="$(nginx -t 2>&1)"; then'
if anchor not in s: raise SystemExit('nginx reconcile anchor not found')
s=s.replace(anchor,hook+'\n'+anchor,1);p.write_text(s)
PY
  bash -n /usr/local/sbin/hyper-host-nginx-reconcile
fi
export PHP_FPM_SOCK="$CLOUD_SOCK"
[[ -x /usr/local/sbin/hyper-host-nginx-reconcile ]] && /usr/local/sbin/hyper-host-nginx-reconcile || true
PHP_FPM_SOCK="$CLOUD_SOCK" /opt/hyper-host/bin/hyper-cloud-nginx-fragment.sh
nginx -t
systemctl reload nginx

log "Обновляю ссылку Cloud в панели"
python3 - "$PANEL_ROOT/public/index.php" "$CLOUD_DOMAIN" <<'PY' || true
from pathlib import Path
import re,sys
p=Path(sys.argv[1]);domain=sys.argv[2]
if not p.exists(): raise SystemExit
s=p.read_text()
s=re.sub(r"function hh_app_version\(\): string \{ return '[^']+'; \}","function hh_app_version(): string { return '1.9-v107-cloud'; }",s)
anchor="$action = $_POST['action'] ?? $_GET['action'] ?? null;"
redir=f"\nif ($page === 'cloud') {{ header('Location: https://{domain}/', true, 302); exit; }}"
if redir not in s and anchor in s:s=s.replace(anchor,anchor+redir,1)
if "'cloud'=>['fa-cloud','Облако']" not in s:s=s.replace("'files'=>['fa-folder-open','Файлы'],","'files'=>['fa-folder-open','Файлы'],'cloud'=>['fa-cloud','Облако'],",1)
p.write_text(s)
PY
php -l "$PANEL_ROOT/public/index.php" >/dev/null || true

log "Финальная проверка v107"
php -l "$APP_ROOT/app/bootstrap.php"
php -l "$APP_ROOT/app/filelib.php"
php -l "$APP_ROOT/public/index.php"
php -l "$APP_ROOT/public/editor.php"
php -l "$APP_ROOT/public/site.php"
php -l "$APP_ROOT/public/site-resource.php"
php -l "$APP_ROOT/public/api/upload.php"
command -v node >/dev/null 2>&1 && node --check "$APP_ROOT/public/cloud.js" || true
nginx -t
MARKER="$(curl -ksS --resolve "$CLOUD_DOMAIN:443:127.0.0.1" "https://$CLOUD_DOMAIN/__hyper_cloud_route__" || true)"
[[ "$MARKER" == "HYPER_CLOUD_V107" ]] || die "Домен не отдаёт HYPER CLOUD v107 (получено: $MARKER)"
# Unauthenticated editor/site must redirect to auth, not return HTTP 500.
EDITOR_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' --resolve "$CLOUD_DOMAIN:443:127.0.0.1" "https://$CLOUD_DOMAIN/editor.php?path=test.html" || true)"
SITE_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' --resolve "$CLOUD_DOMAIN:443:127.0.0.1" "https://$CLOUD_DOMAIN/site.php?path=test.html" || true)"
[[ "$EDITOR_CODE" =~ ^(302|303)$ ]] || die "editor.php возвращает HTTP $EDITOR_CODE вместо редиректа авторизации"
[[ "$SITE_CODE" =~ ^(302|303)$ ]] || die "site.php возвращает HTTP $SITE_CODE вместо редиректа авторизации"

# Real authenticated probe: open editor, SAVE HTML, then render it through the
# isolated site preview endpoint. This catches the exact HTTP 500 class that v107 repairs.
log "Проверяю редактор и HTML-preview под реальной Cloud-сессией"
PROBE_SID="$(sudo -u "$CLOUD_USER" php -d session.save_path="$META_ROOT/sessions" -d display_errors=0 -r '
require "/var/www/hyper-host-cloud-app/app/bootstrap.php";
$u=hc_db()->query("SELECT * FROM cloud_users WHERE is_active=1 ORDER BY CASE WHEN auth_source=\"panel\" THEN 0 ELSE 1 END,id ASC LIMIT 1")->fetch(PDO::FETCH_ASSOC);
if(!$u)exit(2);hc_ensure_user_root($u);$f=hc_root_for_user($u,"private")."/.hc-v107-probe.html";file_put_contents($f,"<!doctype html><html><body><h1>probe-before</h1></body></html>");chmod($f,0660);$_SESSION["hc_user_id"]=(int)$u["id"];$_SESSION["hc_started_at"]=time();$_SESSION["hc_last_seen"]=time();$sid=session_id();session_write_close();echo $sid;' 2>/dev/null)"
[[ -n "$PROBE_SID" ]] || die "Не удалось создать тестовую Cloud-сессию"
PROBE_COOKIE="HYPERCLOUDSESSID=$PROBE_SID"
TMP_EDITOR="$(mktemp)"; TMP_SAVE="$(mktemp)"; TMP_SITE="$(mktemp)"; TMP_RES="$(mktemp)"
cleanup_probe(){
  rm -f "$TMP_EDITOR" "$TMP_SAVE" "$TMP_SITE" "$TMP_RES" "$META_ROOT/sessions/sess_$PROBE_SID" 2>/dev/null || true
  sudo -u "$CLOUD_USER" php -d session.save_path="$META_ROOT/sessions" -d display_errors=0 -r 'require "/var/www/hyper-host-cloud-app/app/bootstrap.php";$u=hc_db()->query("SELECT * FROM cloud_users WHERE is_active=1 ORDER BY CASE WHEN auth_source=\"panel\" THEN 0 ELSE 1 END,id ASC LIMIT 1")->fetch(PDO::FETCH_ASSOC);if($u)@unlink(hc_root_for_user($u,"private")."/.hc-v107-probe.html");' >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT
PROBE_EDITOR_CODE="$(curl -ksS -o "$TMP_EDITOR" -w '%{http_code}' --resolve "$CLOUD_DOMAIN:443:127.0.0.1" -H "Cookie: $PROBE_COOKIE" --get --data-urlencode 'space=private' --data-urlencode 'path=.hc-v107-probe.html' "https://$CLOUD_DOMAIN/editor.php" || true)"
[[ "$PROBE_EDITOR_CODE" == "200" ]] || { tail -n 80 /var/log/hyper-cloud/php-error.log >&2 || true; die "Авторизованный editor.php вернул HTTP $PROBE_EDITOR_CODE"; }
grep -q 'hc-code-shell' "$TMP_EDITOR" || die "editor.php не отдал интерфейс редактора"
PROBE_CSRF="$(python3 - "$TMP_EDITOR" <<'PY2'
import html,re,sys
s=open(sys.argv[1],encoding='utf-8',errors='replace').read();m=re.search(r'name="_csrf" value="([^"]+)"',s);print(html.unescape(m.group(1)) if m else '')
PY2
)"
[[ -n "$PROBE_CSRF" ]] || die "Не найден CSRF редактора"
PROBE_SAVE_CODE="$(curl -ksS -o "$TMP_SAVE" -w '%{http_code}' --resolve "$CLOUD_DOMAIN:443:127.0.0.1" -H "Cookie: $PROBE_COOKIE" -X POST --data-urlencode "_csrf=$PROBE_CSRF" --data-urlencode 'space=private' --data-urlencode 'path=.hc-v107-probe.html' --data-urlencode 'content=<!doctype html><html><body><h1>probe-after</h1></body></html>' "https://$CLOUD_DOMAIN/editor.php" || true)"
[[ "$PROBE_SAVE_CODE" == "200" ]] || { tail -n 80 /var/log/hyper-cloud/php-error.log >&2 || true; die "Сохранение editor.php вернуло HTTP $PROBE_SAVE_CODE"; }
grep -q 'probe-after' "$TMP_SAVE" || die "Редактор не сохранил тестовый HTML"
PROBE_SITE_CODE="$(curl -ksS -o "$TMP_SITE" -w '%{http_code}' --resolve "$CLOUD_DOMAIN:443:127.0.0.1" -H "Cookie: $PROBE_COOKIE" --get --data-urlencode 'space=private' --data-urlencode 'path=.hc-v107-probe.html' "https://$CLOUD_DOMAIN/site.php" || true)"
[[ "$PROBE_SITE_CODE" == "200" ]] || { tail -n 80 /var/log/hyper-cloud/php-error.log >&2 || true; die "Авторизованный site.php вернул HTTP $PROBE_SITE_CODE"; }
PROBE_SRC="$(python3 - "$TMP_SITE" <<'PY2'
import html,re,sys
s=open(sys.argv[1],encoding='utf-8',errors='replace').read();m=re.search(r'<iframe[^>]+id="preview"[^>]+src="([^"]+)"',s);print(html.unescape(m.group(1)) if m else '')
PY2
)"
[[ "$PROBE_SRC" == /site-resource.php* ]] || die "HTML-preview не создал защищённый ресурс"
PROBE_RES_CODE="$(curl -ksS -o "$TMP_RES" -w '%{http_code}' --resolve "$CLOUD_DOMAIN:443:127.0.0.1" "https://$CLOUD_DOMAIN$PROBE_SRC" || true)"
[[ "$PROBE_RES_CODE" == "200" ]] || { tail -n 80 /var/log/hyper-cloud/php-error.log >&2 || true; die "site-resource.php вернул HTTP $PROBE_RES_CODE"; }
grep -q 'probe-after' "$TMP_RES" || die "HTML-preview не отдал сохранённый HTML"
echo "EDITOR_SITE_PROBE_OK"
cleanup_probe
trap - EXIT

printf '\n============================================================\n'
printf ' HYPER CLOUD v107 установлен\n'
printf ' URL:      https://%s/\n' "$CLOUD_DOMAIN"
printf ' Editor:   отдельный /editor.php\n'
printf ' Preview:  sandbox /site.php + signed resources\n'
printf ' Runtime:  %s via %s\n' "$CLOUD_USER" "$CLOUD_SOCK"
printf ' Security: panel DB isolated / code read-only / rate limit enabled\n'
printf ' Backup:   %s\n' "$BACKUP"
printf ' DOMAIN_OK: HYPER_CLOUD_V107\n'
printf '============================================================\n'
