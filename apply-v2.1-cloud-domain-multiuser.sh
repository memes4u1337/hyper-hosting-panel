#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER CLOUD v103 — cloud.hyper-host.pw / multi-user / shared storage / chunk uploads.
# Usage: sudo ./apply-v2.1-cloud-domain-multiuser.sh [/root/hyper-hosting-panel]

SRC="${1:-$(pwd)}"
CLOUD_DOMAIN="${CLOUD_DOMAIN:-cloud.hyper-host.pw}"
PANEL_DOMAIN="${PANEL_DOMAIN:-panel.hyper-host.pw}"
APP_ROOT="/var/www/hyper-host-cloud-app"
STORAGE_ROOT="/var/www/hyper-host-cloud"
META_ROOT="/var/lib/hyper-host-cloud"
PANEL_ROOT="/var/www/hyper-host"
PANEL_CONFIG="$PANEL_ROOT/app/config.php"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/hyper-host/backups/cloud-v103-${STAMP}"
NGINX_AVAIL="/etc/nginx/sites-available/hyper-host-cloud"
NGINX_ENABLED="/etc/nginx/sites-enabled/hyper-host-cloud"
CLOUD_CONFIG="/etc/hyper-host/cloud.php"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Запустите от root: sudo $0 ${SRC}" >&2
  exit 1
fi
if [[ ! -f "$SRC/src/cloud/public/index.php" || ! -f "$SRC/src/cloud/app/bootstrap.php" || ! -f "$SRC/src/cloud/public/api/upload.php" ]]; then
  echo "[ERROR] В $SRC нет файлов HYPER CLOUD v103 (src/cloud/...)" >&2
  exit 1
fi

log(){ printf '\n\033[1;36m[HYPER CLOUD]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }

log "Создаю backup конфигурации: $BACKUP"
mkdir -p "$BACKUP"
[[ -d "$APP_ROOT" ]] && cp -a "$APP_ROOT" "$BACKUP/cloud-app" || true
[[ -f "$NGINX_AVAIL" ]] && cp -a "$NGINX_AVAIL" "$BACKUP/nginx-cloud.conf" || true
[[ -f "$CLOUD_CONFIG" ]] && cp -a "$CLOUD_CONFIG" "$BACKUP/cloud.php" || true
[[ -f "$PANEL_ROOT/public/index.php" ]] && cp -a "$PANEL_ROOT/public/index.php" "$BACKUP/panel-index.php" || true
# Файлы пользователей намеренно НЕ копируются: они сохраняются на месте и не удаляются.

log "Устанавливаю PHP/SQLite/архиваторы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx sqlite3 zip unzip p7zip-full libarchive-tools file curl ca-certificates certbot python3-certbot-nginx software-properties-common >/dev/null
# RAR умеет изменять .rar. Он находится в multiverse и может быть недоступен у части зеркал.
add-apt-repository -y multiverse >/dev/null 2>&1 || true
apt-get update -y >/dev/null
apt-get install -y rar unrar >/dev/null 2>&1 || warn "Пакет rar не найден. ZIP/7Z будут редактироваться полностью; RAR останется читаемым через 7z до установки rar."

PHP_VERSIONS=()
if [[ -d /etc/php ]]; then
  while IFS= read -r v; do PHP_VERSIONS+=("$v"); done < <(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E '^[0-9]+\.[0-9]+$' | sort -V)
fi
for v in "${PHP_VERSIONS[@]}"; do
  apt-get install -y "php${v}-sqlite3" "php${v}-zip" "php${v}-mbstring" "php${v}-xml" >/dev/null 2>&1 || true
done

# Choose the FPM socket used by the panel when possible.
FPM_SOCK=""
PANEL_NGINX_FILE="$(grep -RIlE "server_name[[:space:]].*${PANEL_DOMAIN//./\\.}" /etc/nginx/sites-enabled /etc/nginx/sites-available 2>/dev/null | head -n1 || true)"
if [[ -n "$PANEL_NGINX_FILE" ]]; then
  FPM_SOCK="$(grep -Eo 'unix:/run/php/php[0-9.]+-fpm\.sock' "$PANEL_NGINX_FILE" | head -n1 | sed 's#^unix:##' || true)"
fi
if [[ -z "$FPM_SOCK" || ! -S "$FPM_SOCK" ]]; then
  FPM_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
fi
if [[ -z "$FPM_SOCK" || ! -S "$FPM_SOCK" ]]; then
  echo "[ERROR] Не найден PHP-FPM socket в /run/php" >&2
  exit 1
fi
FPM_VER="$(basename "$FPM_SOCK" | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm\.sock$/\1/p')"
log "Cloud будет использовать PHP-FPM ${FPM_VER:-unknown}: $FPM_SOCK"
if [[ -n "$FPM_VER" ]]; then
  apt-get install -y "php${FPM_VER}-sqlite3" "php${FPM_VER}-zip" "php${FPM_VER}-mbstring" "php${FPM_VER}-xml" >/dev/null
fi
CLI_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ -n "$CLI_VER" ]]; then
  apt-get install -y "php${CLI_VER}-sqlite3" "php${CLI_VER}-zip" "php${CLI_VER}-mbstring" "php${CLI_VER}-xml" >/dev/null 2>&1 || true
fi

# Large editor saves + chunk uploads. Chunk API itself uses only 4 MiB/request.
for ini in /etc/php/*/fpm/php.ini /etc/php/*/cli/php.ini; do
  [[ -f "$ini" ]] || continue
  sed -ri 's~^[;[:space:]]*upload_max_filesize[[:space:]]*=.*~upload_max_filesize = 8192M~' "$ini" || true
  sed -ri 's~^[;[:space:]]*post_max_size[[:space:]]*=.*~post_max_size = 8192M~' "$ini" || true
  sed -ri 's~^[;[:space:]]*max_execution_time[[:space:]]*=.*~max_execution_time = 0~' "$ini" || true
  sed -ri 's~^[;[:space:]]*max_input_time[[:space:]]*=.*~max_input_time = -1~' "$ini" || true
  sed -ri 's~^[;[:space:]]*memory_limit[[:space:]]*=.*~memory_limit = 2048M~' "$ini" || true
done

log "Устанавливаю отдельное Cloud-приложение"
mkdir -p "$APP_ROOT/app" "$APP_ROOT/public/api" "$STORAGE_ROOT/users" "$STORAGE_ROOT/shared" "$META_ROOT/uploads" /etc/hyper-host
install -m 0644 "$SRC/src/cloud/app/bootstrap.php" "$APP_ROOT/app/bootstrap.php"
install -m 0644 "$SRC/src/cloud/public/index.php" "$APP_ROOT/public/index.php"
install -m 0644 "$SRC/src/cloud/public/cloud.css" "$APP_ROOT/public/cloud.css"
install -m 0644 "$SRC/src/cloud/public/cloud.js" "$APP_ROOT/public/cloud.js"
install -m 0644 "$SRC/src/cloud/public/api/upload.php" "$APP_ROOT/public/api/upload.php"
chown -R root:root "$APP_ROOT"
find "$APP_ROOT" -type d -exec chmod 0755 {} +
find "$APP_ROOT" -type f -exec chmod 0644 {} +
chown -R www-data:www-data "$STORAGE_ROOT" "$META_ROOT"
find "$STORAGE_ROOT" "$META_ROOT" -type d -exec chmod 2770 {} +
find "$STORAGE_ROOT" "$META_ROOT" -type f -exec chmod 0660 {} + 2>/dev/null || true

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
chown root:www-data "$CLOUD_CONFIG"
chmod 0640 "$CLOUD_CONFIG"

log "Инициализирую Cloud DB и переношу старые файлы в аккаунт администратора панели"
# Restart FPM first so extensions are available to web; CLI modules are loaded immediately.
for svc in /etc/init.d/php*-fpm; do [[ -e "$svc" ]] || continue; service "$(basename "$svc")" restart >/dev/null 2>&1 || true; done
systemctl restart "php${FPM_VER}-fpm" >/dev/null 2>&1 || true

MIG_INFO="$(php -d display_errors=0 -r '
require "/var/www/hyper-host-cloud-app/app/bootstrap.php";
$db=hc_db();$p=hc_panel_db();
if(!$p){fwrite(STDERR,"Panel DB unavailable\n");exit(2);} $row=$p->query("SELECT * FROM users ORDER BY id ASC LIMIT 1")->fetch();
if(!is_array($row)){fwrite(STDERR,"Panel admin unavailable\n");exit(3);} $u=hc_upsert_panel_cloud_user($row);hc_ensure_user_root($u);
echo (int)$u["id"]."|".(string)$u["storage_key"]."|".(int)$row["id"];
' 2>/dev/null || true)"
if [[ -z "$MIG_INFO" || "$MIG_INFO" != *"|"* ]]; then
  echo "[ERROR] Cloud DB не инициализировалась или не найден пользователь панели. Проверьте php${FPM_VER}-sqlite3 и $PANEL_CONFIG" >&2
  exit 1
fi
IFS='|' read -r CLOUD_ADMIN_ID CLOUD_STORAGE_KEY PANEL_USER_ID <<< "$MIG_INFO"
PRIVATE_ROOT="$STORAGE_ROOT/users/$CLOUD_STORAGE_KEY"
mkdir -p "$PRIVATE_ROOT" "$STORAGE_ROOT/shared"
chown -R www-data:www-data "$PRIVATE_ROOT" "$STORAGE_ROOT/shared"
chmod 2770 "$PRIVATE_ROOT" "$STORAGE_ROOT/shared"

MIG_MARK="$META_ROOT/.v103-storage-migrated"
if [[ ! -f "$MIG_MARK" ]]; then
  shopt -s dotglob nullglob
  for item in "$STORAGE_ROOT"/*; do
    base="$(basename "$item")"
    [[ "$base" == "users" || "$base" == "shared" ]] && continue
    target="$PRIVATE_ROOT/$base"
    if [[ -e "$target" ]]; then
      n=1
      while [[ -e "$PRIVATE_ROOT/${base}.legacy-${n}" ]]; do ((n++)); done
      target="$PRIVATE_ROOT/${base}.legacy-${n}"
    fi
    mv -- "$item" "$target"
  done
  shopt -u dotglob nullglob
  chown -R www-data:www-data "$PRIVATE_ROOT"
  find "$PRIVATE_ROOT" -type d -exec chmod 2770 {} +
  find "$PRIVATE_ROOT" -type f -exec chmod 0660 {} +
  touch "$MIG_MARK"; chown www-data:www-data "$MIG_MARK"; chmod 0660 "$MIG_MARK"
fi

# Import v97-v102 public links into the new per-account DB without changing tokens.
if [[ -f "$META_ROOT/shares.json" && ! -f "$META_ROOT/.v103-shares-imported" ]]; then
  CLOUD_ADMIN_ID="$CLOUD_ADMIN_ID" php -d display_errors=0 <<'PHP' || true
<?php
require '/var/www/hyper-host-cloud-app/app/bootstrap.php';
$id=(int)getenv('CLOUD_ADMIN_ID');$u=hc_cloud_user_by_id($id);if(!$u)exit(2);
$file='/var/lib/hyper-host-cloud/shares.json';$raw=@file_get_contents($file);$all=json_decode(is_string($raw)?$raw:'',true);if(!is_array($all))$all=[];
$st=hc_db()->prepare("INSERT OR IGNORE INTO public_shares(token,owner_user_id,space,rel_path,created_at) VALUES(?,?,'private',?,?)");
foreach($all as $token=>$entry){if(!preg_match('/^[a-f0-9]{48}$/',(string)$token)||!is_array($entry))continue;$rel=trim(str_replace('\\','/',(string)($entry['path']??'')),'/');if($rel===''||str_contains($rel,'../'))continue;$path=hc_root_for_user($u,'private').'/'.$rel;if(!is_file($path))continue;$created=(string)($entry['created_at']??date(DATE_ATOM));$st->execute([(string)$token,$id,$rel,$created]);}
PHP
  touch "$META_ROOT/.v103-shares-imported"; chown www-data:www-data "$META_ROOT/.v103-shares-imported"; chmod 0660 "$META_ROOT/.v103-shares-imported"
fi

# CLI migration runs as root; return all mutable Cloud data to the web user.
chown -R www-data:www-data "$STORAGE_ROOT" "$META_ROOT"
find "$STORAGE_ROOT" "$META_ROOT" -type d -exec chmod 2770 {} +
find "$STORAGE_ROOT" "$META_ROOT" -type f -exec chmod 0660 {} + 2>/dev/null || true

log "Настраиваю nginx для $CLOUD_DOMAIN"
cat > "$NGINX_AVAIL" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $CLOUD_DOMAIN;

    root $APP_ROOT/public;
    index index.php;
    charset utf-8;

    # Upload API receives 4 MiB chunks; editor POST can be much larger.
    client_max_body_size 8192m;
    client_body_timeout 3600s;
    send_timeout 3600s;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$FPM_SOCK;
        fastcgi_read_timeout 3600s;
        fastcgi_send_timeout 3600s;
        fastcgi_request_buffering off;
    }

    location ~* \.(?:css|js|png|jpg|jpeg|gif|webp|svg|ico|woff2?)$ {
        expires 1d;
        add_header Cache-Control "public, max-age=86400";
        try_files \$uri =404;
    }

    location ~ /\.(?!well-known) { deny all; }
    location = /favicon.ico { log_not_found off; access_log off; }
}
NGINX
ln -sfn "$NGINX_AVAIL" "$NGINX_ENABLED"
nginx -t
systemctl reload nginx

log "Добавляю кнопку Облако в HYPER-HOST панели"
patch_panel(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$CLOUD_DOMAIN" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); domain=sys.argv[2]; s=p.read_text()
s=re.sub(r"function hh_app_version\(\): string \{ return '[^']+'; \}", "function hh_app_version(): string { return '1.9-v103-cloud'; }", s)
# Remove previous embedded-cloud redirects and add an external-domain redirect.
s=re.sub(r"\nif \(\$page === 'cloud'\) \{?\s*redirect\([^\n]+\);?\s*\}?", "", s)
anchor="$action = $_POST['action'] ?? $_GET['action'] ?? null;"
redir=f"\nif ($page === 'cloud') {{ header('Location: https://{domain}/', true, 302); exit; }}"
if redir not in s and anchor in s: s=s.replace(anchor,anchor+redir,1)
# Nav config: Cloud lives next to Files.
if "'cloud'=>['fa-cloud','Облако']" not in s:
    s=s.replace("'files'=>['fa-folder-open','Файлы'],", "'files'=>['fa-folder-open','Файлы'],'cloud'=>['fa-cloud','Облако'],",1)
# Force nav_item cloud link to external app; keep normal links untouched.
start=s.find('function nav_item('); end=s.find('function render_login',start)
if start!=-1 and end!=-1:
    fn=f'''function nav_item(string $id,string $icon,string $label,string $page): string\n{{\n    if ($id === 'cloud') {{\n        return '<a class="nav-link" href="https://{domain}/"><span class="nav-link-icon"><i class="fa-solid fa-cloud"></i></span><span class="nav-link-label">Облако</span><i class="fa-solid fa-arrow-up-right-from-square nav-link-arrow"></i></a>';\n    }}\n    $active=$id===$page?' active':'';\n    return '<a class="nav-link'.$active.'" href="/?page='.e($id).'"'.($active?' aria-current="page"':'').'><span class="nav-link-icon"><i class="fa-solid '.e($icon).'"></i></span><span class="nav-link-label">'.e($label).'</span><i class="fa-solid fa-chevron-right nav-link-arrow"></i></a>';\n}}\n'''
    s=s[:start]+fn+s[end:]
p.write_text(s)
PY
  php -l "$file" >/dev/null
}
patch_panel "$PANEL_ROOT/public/index.php"
patch_panel "$SRC/src/public/index.php"

# Legacy /cloud/ on panel now always leaves the panel shell and goes to the new domain.
mkdir -p "$PANEL_ROOT/public/cloud"
cat > "$PANEL_ROOT/public/cloud/index.php" <<PHP
<?php
\$query = preg_replace('/[\r\n]/', '', (string)(\$_SERVER['QUERY_STRING'] ?? ''));
header('Location: https://$CLOUD_DOMAIN/' . (\$query !== '' ? '?' . \$query : ''), true, 302);
exit;
PHP
chown root:root "$PANEL_ROOT/public/cloud/index.php"; chmod 0644 "$PANEL_ROOT/public/cloud/index.php"

cat > /etc/cron.d/hyper-host-cloud-cleanup <<'CRON'
27 4 * * * root find /var/lib/hyper-host-cloud/uploads -mindepth 2 -maxdepth 2 -type d -mmin +1440 -exec rm -rf -- {} + >/dev/null 2>&1
CRON
chmod 0644 /etc/cron.d/hyper-host-cloud-cleanup

log "Проверяю приложение"
php -l "$APP_ROOT/app/bootstrap.php"
php -l "$APP_ROOT/public/index.php"
php -l "$APP_ROOT/public/api/upload.php"
command -v node >/dev/null 2>&1 && node --check "$APP_ROOT/public/cloud.js" || true
php -d display_errors=0 -r 'require "/var/www/hyper-host-cloud-app/app/bootstrap.php"; hc_db(); echo "CLOUD_DB_OK\n";'
nginx -t

log "Пробую выпустить SSL для $CLOUD_DOMAIN"
if certbot certificates 2>/dev/null | grep -Fq "Domains: $CLOUD_DOMAIN"; then
  certbot --nginx -d "$CLOUD_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect >/dev/null 2>&1 || true
else
  if getent ahostsv4 "$CLOUD_DOMAIN" >/dev/null 2>&1; then
    if ! certbot --nginx -d "$CLOUD_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
      warn "SSL пока не выпущен. Убедитесь, что A-запись $CLOUD_DOMAIN указывает на этот сервер, затем: certbot --nginx -d $CLOUD_DOMAIN"
    fi
  else
    warn "DNS для $CLOUD_DOMAIN пока не разрешается. Создайте A-запись на IP сервера, затем выполните: certbot --nginx -d $CLOUD_DOMAIN"
  fi
fi
nginx -t && systemctl reload nginx

PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m HYPER CLOUD v103 установлен\033[0m\n'
printf ' URL: https://%s/\n' "$CLOUD_DOMAIN"
printf ' Панель: https://%s/\n' "$PANEL_DOMAIN"
printf ' Private: %s/users/<account>/\n' "$STORAGE_ROOT"
printf ' Shared:  %s/shared/\n' "$STORAGE_ROOT"
printf ' DB:      %s/cloud.sqlite\n' "$META_ROOT"
printf ' Backup:  %s\n' "$BACKUP"
[[ -n "$PUBLIC_IP" ]] && printf ' DNS A:    %s -> %s\n' "$CLOUD_DOMAIN" "$PUBLIC_IP"
printf '\033[1;32m============================================================\033[0m\n'
