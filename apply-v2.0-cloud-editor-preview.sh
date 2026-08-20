#!/usr/bin/env bash
set -Eeuo pipefail

PATCH_VERSION="v102-archive-editor-html-site"
PROJECT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PANEL_DIR="/var/www/hyper-host"
CLOUD_DIR="/var/www/hyper-host-cloud"
META_DIR="/var/lib/hyper-host-cloud"
CONF_FILE="/etc/hyper-host/hyper-host.conf"
BACKUP_BASE="/opt/hyper-host/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_BASE}/cloud-v102-${STAMP}"

log(){ printf '\033[1;96m[HYPER CLOUD]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;93m[HYPER CLOUD WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;91m[HYPER CLOUD ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail "Запусти от root: sudo ./apply-v2.0-cloud-editor-preview.sh /root/hyper-hosting-panel"
INDEX_SOURCE="$PROJECT_DIR/src/public/index.php"
if [[ ! -f "$INDEX_SOURCE" ]]; then
  [[ -f "$PANEL_DIR/public/index.php" ]] || fail "Не найден ни $PROJECT_DIR/src/public/index.php, ни установленный $PANEL_DIR/public/index.php"
  INDEX_SOURCE="$PANEL_DIR/public/index.php"
  warn "Исходный index.php в архиве не найден — патчу установленную панель напрямую."
fi
[[ -f "$PROJECT_DIR/src/public/cloud/index.php" ]] || fail "Не найден src/public/cloud/index.php"
[[ -f "$PROJECT_DIR/src/public/cloud/cloud.css" ]] || fail "Не найден cloud.css"
[[ -f "$PROJECT_DIR/src/public/cloud/cloud.js" ]] || fail "Не найден cloud.js"

mkdir -p "$BACKUP_DIR/source" "$BACKUP_DIR/installed"
for f in src/public/index.php install.sh src/app/config.example.php; do
  [[ -f "$PROJECT_DIR/$f" ]] || continue
  mkdir -p "$BACKUP_DIR/source/$(dirname "$f")"
  cp -a "$PROJECT_DIR/$f" "$BACKUP_DIR/source/$f"
done
for f in "$PANEL_DIR/public/index.php" "$PANEL_DIR/app/config.php" "$PANEL_DIR/app/cloud.php" "$PANEL_DIR/public/assets/cloud.css" "$PANEL_DIR/public/assets/cloud.js"; do
  [[ -f "$f" ]] || continue
  dst="$BACKUP_DIR/installed$f"; mkdir -p "$(dirname "$dst")"; cp -a "$f" "$dst"
done
[[ -d "$PANEL_DIR/public/cloud" ]] && cp -a "$PANEL_DIR/public/cloud" "$BACKUP_DIR/installed/cloud-old" || true
if [[ -f "$META_DIR/shares.json" ]]; then mkdir -p "$BACKUP_DIR/installed/cloud-meta"; cp -a "$META_DIR/shares.json" "$BACKUP_DIR/installed/cloud-meta/shares.json"; fi
log "Backup: $BACKUP_DIR"

log "Перевожу Cloud из встроенной страницы в отдельное приложение /cloud/..."
python3 - "$INDEX_SOURCE" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

# Remove previous v94/v95 embedded Cloud hooks if they exist.
s=s.replace("require_once __DIR__ . '/../app/cloud.php';\n", "")
s=re.sub(r"\nif \(\$page === 'cloud' && isset\(\$_GET\['cloud_action'\]\)\) \{ hh_cloud_handle_get\(\(string\)\$_GET\['cloud_action'\]\); \}\n", "\n", s)
s=re.sub(r"if \(\$_SERVER\['REQUEST_METHOD'\] === 'POST'\) \{\s*check_csrf\(\);\s*if \(str_starts_with\(\(string\)\$action, 'cloud_'\)\) \{ hh_cloud_handle_post\(\(string\)\$action\); \}\s*handle_post\(\(string\)\$action\);\s*\}", "if ($_SERVER['REQUEST_METHOD'] === 'POST') { check_csrf(); handle_post((string)$action); }", s, count=1)
s=s.replace("<?php if($page==='cloud'): ?><link href=\"/assets/cloud.css?v=95\" rel=\"stylesheet\"><?php endif; ?>", "")
s=s.replace("<?php if($page==='cloud'): ?><script src=\"/assets/cloud.js?v=95\" defer></script><?php endif; ?>", "")
s=s.replace(",'cloud'=>'Облако'", "")
s=s.replace("'cloud'=>'Облако',", "")
s=s.replace(" 'cloud'=>view_cloud(),", "")
s=s.replace("'cloud'=>view_cloud(), ", "")

# Old ?page=cloud must NEVER render inside the HYPER-HOST shell anymore.
redirect_line="if ($page === 'cloud') { redirect('/cloud/'); }"
if redirect_line not in s:
    anchor="$user = require_auth();\n"
    if anchor not in s:
        raise SystemExit('PATCH ERROR: require_auth anchor not found')
    s=s.replace(anchor, anchor+redirect_line+"\n", 1)

# Login opened from /cloud/ returns to /cloud/ after successful auth.
if "after_login" not in s:
    old="$_SESSION['user_id'] = (int)$u['id']; auth_log($username, 'success'); add_event('auth', 'Вход в панель: '.$username); redirect('/');"
    new="$_SESSION['user_id'] = (int)$u['id']; auth_log($username, 'success'); add_event('auth', 'Вход в панель: '.$username); $next = $_SESSION['after_login'] ?? '/'; unset($_SESSION['after_login']); redirect(is_string($next) && str_starts_with($next, '/') ? $next : '/');"
    if old not in s:
        raise SystemExit('PATCH ERROR: login success anchor not found')
    s=s.replace(old,new,1)

# Add Cloud to main menu if absent.
if "'cloud'=>['fa-cloud','Облако']" not in s:
    old="'files'=>['fa-folder-open','Файлы'],"
    if old not in s:
        raise SystemExit('PATCH ERROR: Files nav anchor not found')
    s=s.replace(old, old+"'cloud'=>['fa-cloud','Облако'],",1)

# Cloud menu item gets a direct standalone URL; every other item keeps ?page=...
pattern=r"function nav_item\(string \$id,string \$icon,string \$label,string \$page\): string\s*\{.*?\n\}"
replacement="""function nav_item(string $id,string $icon,string $label,string $page): string
{
    $active=$id===$page?' active':'';
    $href=$id==='cloud'?'/cloud/':'/?page='.rawurlencode($id);
    return '<a class=\"nav-link'.$active.'\" href=\"'.e($href).'\"'.($active?' aria-current=\"page\"':'').'><span class=\"nav-link-icon\"><i class=\"fa-solid '.e($icon).'\"></i></span><span class=\"nav-link-label\">'.e($label).'</span><i class=\"fa-solid fa-chevron-right nav-link-arrow\"></i></a>';
}"""
s,n=re.subn(pattern,replacement,s,count=1,flags=re.S)
if n!=1:
    raise SystemExit('PATCH ERROR: nav_item function not found')

# Version marker.
s,n=re.subn(r"function hh_app_version\(\): string \{ return '[^']+'; \}", "function hh_app_version(): string { return '1.9-v102-cloud'; }", s, count=1)
if n!=1:
    raise SystemExit('PATCH ERROR: hh_app_version not found')

# Optional dashboard shortcut next to existing file shortcut.
cloud_quick='<a class="quick-card" href="/cloud/"><i class="fa-solid fa-cloud"></i><b>Облако</b><span>личное хранилище файлов</span></a>'
if cloud_quick not in s:
    anchor='<a class="quick-card" href="/?page=files"><i class="fa-solid fa-folder-open"></i><b>Файлы</b><span>папки сайтов и ботов</span></a>'
    if anchor in s:
        s=s.replace(anchor,anchor+cloud_quick,1)

p.write_text(s,encoding='utf-8')
PY

# Future fresh installs: create the storage directory and put cloud_dir in app config.
if [[ -f "$PROJECT_DIR/install.sh" ]]; then
python3 - "$PROJECT_DIR/install.sh" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if 'CLOUD_DIR="/var/www/hyper-host-cloud"' not in s:
    s=s.replace('BOTS_DIR="/var/www/hyper-host-bots"\n','BOTS_DIR="/var/www/hyper-host-bots"\nCLOUD_DIR="/var/www/hyper-host-cloud"\n',1)
if 'CLOUD_META_DIR="/var/lib/hyper-host-cloud"' not in s:
    s=s.replace('CLOUD_DIR="/var/www/hyper-host-cloud"\n','CLOUD_DIR="/var/www/hyper-host-cloud"\nCLOUD_META_DIR="/var/lib/hyper-host-cloud"\n',1)
if '"$SITES_DIR" "$BOTS_DIR" "$CLOUD_DIR" "$FTP_DIR"' not in s:
    s=s.replace('"$SITES_DIR" "$BOTS_DIR" "$FTP_DIR"','"$SITES_DIR" "$BOTS_DIR" "$CLOUD_DIR" "$FTP_DIR"',1)
if 'CLOUD_DIR="${CLOUD_DIR}"' not in s:
    s=s.replace('BOTS_DIR="${BOTS_DIR}"\n','BOTS_DIR="${BOTS_DIR}"\nCLOUD_DIR="${CLOUD_DIR}"\n',1)
if 'CLOUD_META_DIR="${CLOUD_META_DIR}"' not in s:
    s=s.replace('CLOUD_DIR="${CLOUD_DIR}"\n','CLOUD_DIR="${CLOUD_DIR}"\nCLOUD_META_DIR="${CLOUD_META_DIR}"\n',1)
if "'cloud_dir' => '${CLOUD_DIR}'" not in s:
    s=s.replace("    'bots_dir' => '${BOTS_DIR}',\n","    'bots_dir' => '${BOTS_DIR}',\n    'cloud_dir' => '${CLOUD_DIR}',\n",1)
if "'cloud_meta_dir' => '${CLOUD_META_DIR}'" not in s:
    s=s.replace("    'cloud_dir' => '${CLOUD_DIR}',\n","    'cloud_dir' => '${CLOUD_DIR}',\n    'cloud_meta_dir' => '${CLOUD_META_DIR}',\n",1)
# Permission after dirs are created/copied.
if 'chmod 2770 "$CLOUD_DIR"' not in s:
    marker='log "Очистка старых сломанных FTP bind-mount\'ов..."'
    if marker in s:
        s=s.replace(marker,'chown www-data:www-data "$CLOUD_DIR" 2>/dev/null || true\nchmod 2770 "$CLOUD_DIR" 2>/dev/null || true\ninstall -d -m 2770 -o www-data -g www-data "$CLOUD_META_DIR" 2>/dev/null || true\n[[ -f "$CLOUD_META_DIR/shares.json" ]] || printf "{}\n" > "$CLOUD_META_DIR/shares.json"\nchown www-data:www-data "$CLOUD_META_DIR/shares.json" 2>/dev/null || true\nchmod 0660 "$CLOUD_META_DIR/shares.json" 2>/dev/null || true\n'+marker,1)
p.write_text(s,encoding='utf-8')
PY
fi

if [[ -f "$PROJECT_DIR/src/app/config.example.php" ]]; then
python3 - "$PROJECT_DIR/src/app/config.example.php" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "'cloud_dir'" not in s:
    m=re.search(r"^(\s*)'bots_dir'\s*=>\s*'[^']+',\s*$",s,re.M)
    if m:
        s=s[:m.end()]+"\n"+m.group(1)+"'cloud_dir' => '/var/www/hyper-host-cloud',"+s[m.end():]
if "'cloud_meta_dir'" not in s:
    m=re.search(r"^(\s*)'cloud_dir'\s*=>\s*'[^']+',\s*$",s,re.M)
    if m:
        s=s[:m.end()]+"\n"+m.group(1)+"'cloud_meta_dir' => '/var/lib/hyper-host-cloud',"+s[m.end():]
p.write_text(s,encoding='utf-8')
PY
fi

log "Проверяю синтаксис исходников..."
php -l "$INDEX_SOURCE" >/dev/null
php -l "$PROJECT_DIR/src/public/cloud/index.php" >/dev/null
command -v node >/dev/null 2>&1 && node --check "$PROJECT_DIR/src/public/cloud/cloud.js" >/dev/null || true

log "Создаю отдельное хранилище: $CLOUD_DIR"
mkdir -p "$CLOUD_DIR"
chown www-data:www-data "$CLOUD_DIR"
chmod 2770 "$CLOUD_DIR"

log "Создаю приватный реестр ссылок: $META_DIR"
install -d -m 2770 -o www-data -g www-data "$META_DIR"
if [[ ! -f "$META_DIR/shares.json" ]]; then printf '{}\n' > "$META_DIR/shares.json"; fi
chown www-data:www-data "$META_DIR/shares.json"
chmod 0660 "$META_DIR/shares.json"

if [[ -f "$CONF_FILE" ]]; then
  if grep -q '^CLOUD_DIR=' "$CONF_FILE"; then sed -i 's#^CLOUD_DIR=.*#CLOUD_DIR="/var/www/hyper-host-cloud"#' "$CONF_FILE"
  elif grep -q '^BOTS_DIR=' "$CONF_FILE"; then sed -i '/^BOTS_DIR=/a CLOUD_DIR="/var/www/hyper-host-cloud"' "$CONF_FILE"
  else printf '\nCLOUD_DIR="%s"\n' "$CLOUD_DIR" >> "$CONF_FILE"; fi
  if grep -q '^CLOUD_META_DIR=' "$CONF_FILE"; then sed -i 's#^CLOUD_META_DIR=.*#CLOUD_META_DIR="/var/lib/hyper-host-cloud"#' "$CONF_FILE"
  elif grep -q '^CLOUD_DIR=' "$CONF_FILE"; then sed -i '/^CLOUD_DIR=/a CLOUD_META_DIR="/var/lib/hyper-host-cloud"' "$CONF_FILE"
  else printf 'CLOUD_META_DIR="%s"\n' "$META_DIR" >> "$CONF_FILE"; fi
fi

if [[ -f "$PANEL_DIR/app/config.php" ]]; then
python3 - "$PANEL_DIR/app/config.php" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "'cloud_dir'" not in s:
    m=re.search(r"^(\s*)'bots_dir'\s*=>\s*'[^']+',\s*$",s,re.M)
    if m: s=s[:m.end()]+"\n"+m.group(1)+"'cloud_dir' => '/var/www/hyper-host-cloud',"+s[m.end():]
    elif 'return [\n' in s: s=s.replace('return [\n',"return [\n    'cloud_dir' => '/var/www/hyper-host-cloud',\n",1)
    else: raise SystemExit('Не удалось добавить cloud_dir в app/config.php')
if "'cloud_meta_dir'" not in s:
    m=re.search(r"^(\s*)'cloud_dir'\s*=>\s*'[^']+',\s*$",s,re.M)
    if m: s=s[:m.end()]+"\n"+m.group(1)+"'cloud_meta_dir' => '/var/lib/hyper-host-cloud',"+s[m.end():]
    elif 'return [\n' in s: s=s.replace('return [\n',"return [\n    'cloud_meta_dir' => '/var/lib/hyper-host-cloud',\n",1)
    else: raise SystemExit('Не удалось добавить cloud_meta_dir в app/config.php')
p.write_text(s,encoding='utf-8')
PY
fi

log "Устанавливаю standalone-интерфейс /cloud/..."
mkdir -p "$PANEL_DIR/public/cloud"
if [[ "$INDEX_SOURCE" != "$PANEL_DIR/public/index.php" ]]; then install -m 0644 "$INDEX_SOURCE" "$PANEL_DIR/public/index.php"; fi
install -m 0644 "$PROJECT_DIR/src/public/cloud/index.php" "$PANEL_DIR/public/cloud/index.php"
install -m 0644 "$PROJECT_DIR/src/public/cloud/cloud.css" "$PANEL_DIR/public/cloud/cloud.css"
install -m 0644 "$PROJECT_DIR/src/public/cloud/cloud.js" "$PANEL_DIR/public/cloud/cloud.js"
chown -R www-data:www-data "$PANEL_DIR/public/cloud" "$PANEL_DIR/public/index.php"
[[ -f "$PANEL_DIR/app/config.php" ]] && chown www-data:www-data "$PANEL_DIR/app/config.php" && chmod 0640 "$PANEL_DIR/app/config.php"

# Remove ONLY obsolete embedded Cloud runtime files. User storage is never touched.
rm -f "$PANEL_DIR/app/cloud.php" "$PANEL_DIR/public/assets/cloud.css" "$PANEL_DIR/public/assets/cloud.js" 2>/dev/null || true

log "Проверяю архиваторы для Cloud (если пакеты доступны)..."
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y p7zip-full libarchive-tools unzip zip >/dev/null 2>&1 || warn "Архиваторы не установились автоматически. Сам Cloud работать будет; ZIP/7z редактор можно поставить позже."
  DEBIAN_FRONTEND=noninteractive apt-get install -y rar >/dev/null 2>&1 || true
fi

php -l "$PANEL_DIR/public/index.php" >/dev/null
php -l "$PANEL_DIR/public/cloud/index.php" >/dev/null
command -v node >/dev/null 2>&1 && node --check "$PANEL_DIR/public/cloud/cloud.js" >/dev/null || true

while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl restart "$unit" >/dev/null 2>&1 || warn "Не удалось перезапустить $unit"
done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')

if command -v nginx >/dev/null 2>&1; then
  nginx -t || fail "nginx -t вернул ошибку. Runtime не перезагружен; backup: $BACKUP_DIR"
  systemctl reload nginx >/dev/null 2>&1 || warn "Nginx config OK, но reload не выполнился"
fi

log "Готово: $PATCH_VERSION"
log "Панель: /"
log "Отдельное облако: /cloud/"
log "Файлы облака: $CLOUD_DIR"
log "Реестр ссылок: $META_DIR/shares.json"
