#!/usr/bin/env bash
set -Eeuo pipefail

PATCH_VERSION="v95-cloud-dragdrop"
PROJECT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PANEL_DIR="/var/www/hyper-host"
CLOUD_DIR="/var/www/hyper-host-cloud"
CONF_FILE="/etc/hyper-host/hyper-host.conf"
BACKUP_BASE="/opt/hyper-host/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_BASE}/cloud-patch-${STAMP}"

log()  { printf '\033[1;96m[HYPER-HOST CLOUD]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;93m[HYPER-HOST CLOUD WARNING]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;91m[HYPER-HOST CLOUD ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "Запусти патч от root: sudo bash apply-v1.3-cloud-storage.sh /root/hyper-hosting-panel"
[[ -d "$PROJECT_DIR/src/app" && -d "$PROJECT_DIR/src/public" ]] || fail "Не найден исходный код HYPER-HOST в $PROJECT_DIR"
for required in \
  src/app/cloud.php \
  src/public/assets/cloud.css \
  src/public/assets/cloud.js \
  src/public/index.php \
  src/app/config.example.php \
  install.sh; do
  [[ -f "$PROJECT_DIR/$required" ]] || fail "Нет файла $required"
done

mkdir -p "$BACKUP_DIR/source" "$BACKUP_DIR/installed"
for rel in src/public/index.php src/app/config.example.php install.sh src/public/assets/cloud.css src/public/assets/cloud.js src/app/cloud.php; do
  [[ -f "$PROJECT_DIR/$rel" ]] || continue
  mkdir -p "$BACKUP_DIR/source/$(dirname "$rel")"
  cp -a "$PROJECT_DIR/$rel" "$BACKUP_DIR/source/$rel"
done
for src in \
  "$PANEL_DIR/public/index.php" \
  "$PANEL_DIR/public/assets/cloud.css" \
  "$PANEL_DIR/public/assets/cloud.js" \
  "$PANEL_DIR/app/cloud.php" \
  "$PANEL_DIR/app/bootstrap.php" \
  "$PANEL_DIR/app/config.php" \
  "$CONF_FILE"; do
  [[ -f "$src" ]] || continue
  dst="$BACKUP_DIR/installed${src}"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
done
log "Резервная копия: $BACKUP_DIR"

log "Обновляю исходники панели: отдельный Cloud + авторизация + Drag & Drop..."
python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import re, sys

root = Path(sys.argv[1])

def load(rel):
    p = root / rel
    return p, p.read_text(encoding='utf-8')

def save(p, s):
    p.write_text(s, encoding='utf-8')

def require_once(s, old, new, label):
    if new in s:
        return s
    if old not in s:
        raise SystemExit(f"PATCH ERROR [{label}]: anchor not found")
    return s.replace(old, new, 1)

# ---------- src/public/index.php ----------
p, s = load('src/public/index.php')

if "require_once __DIR__ . '/../app/cloud.php';" not in s:
    s = require_once(
        s,
        "require __DIR__ . '/../app/bootstrap.php';\n",
        "require __DIR__ . '/../app/bootstrap.php';\nrequire_once __DIR__ . '/../app/cloud.php';\n",
        'cloud require'
    )

# Cloud routes are intentionally AFTER $user = require_auth();.
if "hh_cloud_handle_get" not in s:
    old = "if (isset($_GET['api'])) { render_api((string)$_GET['api']); exit; }\nif ($_SERVER['REQUEST_METHOD'] === 'POST') { check_csrf(); handle_post((string)$action); }\nrender_page($page, $user);"
    new = "if (isset($_GET['api'])) { render_api((string)$_GET['api']); exit; }\nif ($page === 'cloud' && isset($_GET['cloud_action'])) { hh_cloud_handle_get((string)$_GET['cloud_action']); }\nif ($_SERVER['REQUEST_METHOD'] === 'POST') {\n    check_csrf();\n    if (str_starts_with((string)$action, 'cloud_')) { hh_cloud_handle_post((string)$action); }\n    handle_post((string)$action);\n}\nrender_page($page, $user);"
    s = require_once(s, old, new, 'cloud protected routes')

# Version can be v93, previous v94-cloud, or another patch version.
s, n = re.subn(r"function hh_app_version\(\): string \{ return '[^']+'; \}", "function hh_app_version(): string { return '1.9-v95-cloud'; }", s, count=1)
if n != 1:
    raise SystemExit('PATCH ERROR [version]: hh_app_version not found')

if "'cloud'=>['fa-cloud','Облако']" not in s:
    s = require_once(
        s,
        "'files'=>['fa-folder-open','Файлы'],",
        "'files'=>['fa-folder-open','Файлы'],'cloud'=>['fa-cloud','Облако'],",
        'cloud nav'
    )

if "'cloud'=>'Облако'" not in s:
    s = require_once(
        s,
        "'files'=>'Файловый менеджер',",
        "'files'=>'Файловый менеджер','cloud'=>'Облако',",
        'cloud title'
    )

if "'cloud'=>view_cloud()" not in s:
    s = require_once(
        s,
        "match($page){ 'files'=>view_files(),",
        "match($page){ 'files'=>view_files(), 'cloud'=>view_cloud(),",
        'cloud view route'
    )

# Bust only panel assets; Cloud gets its own CSS and JS files.
s = re.sub(r'/assets/style\.css\?v=\d+(?:-[A-Za-z0-9_-]+)?', '/assets/style.css?v=95', s)
s = re.sub(r'/assets/app\.js\?v=\d+(?:-[A-Za-z0-9_-]+)?', '/assets/app.js?v=95', s)

cloud_css = "<?php if($page==='cloud'): ?><link href=\"/assets/cloud.css?v=95\" rel=\"stylesheet\"><?php endif; ?>"
if '/assets/cloud.css?v=95' not in s:
    anchor = '<link href="/assets/style.css?v=95" rel="stylesheet"></head><body class="hh-v17">'
    repl = '<link href="/assets/style.css?v=95" rel="stylesheet">' + cloud_css + '</head><body class="hh-v17">'
    s = require_once(s, anchor, repl, 'cloud css include')

cloud_js = "<?php if($page==='cloud'): ?><script src=\"/assets/cloud.js?v=95\" defer></script><?php endif; ?>"
if '/assets/cloud.js?v=95' not in s:
    anchor = '<script src="/assets/app.js?v=95" defer></script></body></html>'
    repl = '<script src="/assets/app.js?v=95" defer></script>' + cloud_js + '</body></html>'
    s = require_once(s, anchor, repl, 'cloud js include')

save(p, s)

# ---------- src/app/config.example.php ----------
p, s = load('src/app/config.example.php')
if "'cloud_dir'" not in s:
    matches = list(re.finditer(r"^(\s*)'bots_dir'\s*=>\s*'[^']+',\s*$", s, re.M))
    if len(matches) != 1:
        raise SystemExit(f'PATCH ERROR [config cloud_dir]: expected one bots_dir, got {len(matches)}')
    m = matches[0]
    line = m.group(0)
    indent = m.group(1)
    s = s[:m.end()] + "\n" + indent + "'cloud_dir' => '/var/www/hyper-host-cloud'," + s[m.end():]
save(p, s)

# ---------- install.sh / fresh installs ----------
p, s = load('install.sh')
if 'CLOUD_DIR="/var/www/hyper-host-cloud"' not in s:
    s = require_once(s, 'BOTS_DIR="/var/www/hyper-host-bots"\n', 'BOTS_DIR="/var/www/hyper-host-bots"\nCLOUD_DIR="/var/www/hyper-host-cloud"\n', 'install cloud var')

# Add cloud directory to mkdir list if not already there.
if '"$BOTS_DIR" "$CLOUD_DIR"' not in s:
    s = s.replace('"$SITES_DIR" "$BOTS_DIR" "$FTP_DIR"', '"$SITES_DIR" "$BOTS_DIR" "$CLOUD_DIR" "$FTP_DIR"', 1)

if 'CLOUD_DIR="${CLOUD_DIR}"' not in s:
    s = require_once(s, 'BOTS_DIR="${BOTS_DIR}"\n', 'BOTS_DIR="${BOTS_DIR}"\nCLOUD_DIR="${CLOUD_DIR}"\n', 'install conf cloud')

if "'cloud_dir' => '${CLOUD_DIR}'" not in s:
    s = require_once(s, "    'bots_dir' => '${BOTS_DIR}',\n", "    'bots_dir' => '${BOTS_DIR}',\n    'cloud_dir' => '${CLOUD_DIR}',\n", 'install php cloud config')

if 'safe_chown_tree www-data:www-data "$CLOUD_DIR"' not in s:
    s = require_once(s, 'safe_chown_tree www-data:www-data "$SITES_DIR"\n', 'safe_chown_tree www-data:www-data "$SITES_DIR"\nsafe_chown_tree www-data:www-data "$CLOUD_DIR"\n', 'install cloud ownership')

if 'chmod 2770 "$CLOUD_DIR"' not in s:
    # Put Cloud permission close to other storage permissions.
    marker = 'chmod 0770 "$BASE_DIR/data"'
    if marker not in s:
        raise SystemExit('PATCH ERROR [install cloud chmod]: marker not found')
    s = s.replace(marker, 'chmod 2770 "$CLOUD_DIR"\n' + marker, 1)

save(p, s)
PY

log "Проверяю синтаксис нового модуля..."
php -l "$PROJECT_DIR/src/app/cloud.php" >/dev/null
php -l "$PROJECT_DIR/src/public/index.php" >/dev/null
if command -v node >/dev/null 2>&1; then
  node --check "$PROJECT_DIR/src/public/assets/cloud.js" >/dev/null
fi

log "Создаю отдельное физическое облако: $CLOUD_DIR"
mkdir -p "$CLOUD_DIR"
chown www-data:www-data "$CLOUD_DIR"
chmod 2770 "$CLOUD_DIR"
find "$CLOUD_DIR" -xdev -type d -exec chown www-data:www-data {} + -exec chmod 2770 {} + 2>/dev/null || true
find "$CLOUD_DIR" -xdev -type f -exec chown www-data:www-data {} + -exec chmod 0660 {} + 2>/dev/null || true

# Keep cloud root in system config without touching other user settings.
if [[ -f "$CONF_FILE" ]]; then
  if grep -q '^CLOUD_DIR=' "$CONF_FILE"; then
    sed -i 's#^CLOUD_DIR=.*#CLOUD_DIR="/var/www/hyper-host-cloud"#' "$CONF_FILE"
  elif grep -q '^BOTS_DIR=' "$CONF_FILE"; then
    sed -i '/^BOTS_DIR=/a CLOUD_DIR="/var/www/hyper-host-cloud"' "$CONF_FILE"
  else
    printf '\nCLOUD_DIR="%s"\n' "$CLOUD_DIR" >> "$CONF_FILE"
  fi
fi

# Keep installed secrets/config and only add cloud_dir if it is missing.
if [[ -f "$PANEL_DIR/app/config.php" ]]; then
  python3 - "$PANEL_DIR/app/config.php" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
if "'cloud_dir'" not in s:
    m = re.search(r"^(\s*)'bots_dir'\s*=>\s*'[^']+',\s*$", s, re.M)
    if m:
        s = s[:m.end()] + "\n" + m.group(1) + "'cloud_dir' => '/var/www/hyper-host-cloud'," + s[m.end():]
    elif 'return [\n' in s:
        s = s.replace('return [\n', "return [\n    'cloud_dir' => '/var/www/hyper-host-cloud',\n", 1)
    else:
        raise SystemExit('Не удалось добавить cloud_dir в установленный config.php')
    p.write_text(s, encoding='utf-8')
PY
fi

# Deploy module + its completely separate design/assets.
if [[ -d "$PANEL_DIR/public" && -d "$PANEL_DIR/app" ]]; then
  log "Устанавливаю Cloud-модуль в действующую панель..."
  mkdir -p "$PANEL_DIR/public/assets"
  install -m 0644 "$PROJECT_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
  install -m 0644 "$PROJECT_DIR/src/app/cloud.php" "$PANEL_DIR/app/cloud.php"
  install -m 0644 "$PROJECT_DIR/src/public/assets/cloud.css" "$PANEL_DIR/public/assets/cloud.css"
  install -m 0644 "$PROJECT_DIR/src/public/assets/cloud.js" "$PANEL_DIR/public/assets/cloud.js"
  chown www-data:www-data \
    "$PANEL_DIR/public/index.php" \
    "$PANEL_DIR/app/cloud.php" \
    "$PANEL_DIR/public/assets/cloud.css" \
    "$PANEL_DIR/public/assets/cloud.js"
  [[ -f "$PANEL_DIR/app/config.php" ]] && chown www-data:www-data "$PANEL_DIR/app/config.php" && chmod 0640 "$PANEL_DIR/app/config.php"
  php -l "$PANEL_DIR/public/index.php" >/dev/null
  php -l "$PANEL_DIR/app/cloud.php" >/dev/null
else
  warn "Действующая панель в $PANEL_DIR не найдена. Исходники подготовлены для новой установки."
fi

log "Проверяю поддержку ZIP/RAR/7z..."
if ! command -v 7z >/dev/null 2>&1 && ! command -v 7zz >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y p7zip-full libarchive-tools unzip >/dev/null 2>&1 || warn "Не удалось автоматически поставить архиваторы. Файлы можно загружать/скачивать, но просмотр RAR/7z может быть недоступен."
  else
    warn "7z/bsdtar не найден. Для просмотра RAR/7z установи p7zip/libarchive."
  fi
fi

while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl restart "$unit" >/dev/null 2>&1 || warn "Не удалось перезапустить $unit"
done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')

if command -v nginx >/dev/null 2>&1; then
  if nginx -t; then
    systemctl reload nginx >/dev/null 2>&1 || warn "Nginx config OK, но reload не выполнился"
  else
    warn "nginx -t вернул ошибку; Nginx не перезагружался"
  fi
fi

cat <<EOF

============================================================
 HYPER-HOST CLOUD ${PATCH_VERSION} — ГОТОВО
============================================================
 URL:            https://panel.hyper-host.pw/?page=cloud
 Хранилище:      ${CLOUD_DIR}
 PHP модуль:     ${PANEL_DIR}/app/cloud.php
 Отдельный CSS:  ${PANEL_DIR}/public/assets/cloud.css
 Отдельный JS:   ${PANEL_DIR}/public/assets/cloud.js
 Авторизация:    только через сессию HYPER-HOST
 Drag & Drop:    включён
 Папка загрузки: корень / текущая / любая созданная папка
 Backup патча:   ${BACKUP_DIR}

 Проверка:
   sudo -u www-data test -w ${CLOUD_DIR} && echo CLOUD_WRITE_OK
   php -l ${PANEL_DIR}/app/cloud.php
   nginx -t
============================================================
EOF
