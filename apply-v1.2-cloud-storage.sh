#!/usr/bin/env bash
set -Eeuo pipefail

PATCH_VERSION="v94-cloud"
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

[[ "${EUID}" -eq 0 ]] || fail "Запусти патч от root: sudo bash apply-v1.2-cloud-storage.sh /root/hyper-hosting-panel"
[[ -d "$PROJECT_DIR/src/app" && -d "$PROJECT_DIR/src/public" ]] || fail "Не найден исходный код HYPER-HOST в $PROJECT_DIR"
[[ -f "$PROJECT_DIR/src/app/cloud.php" ]] || fail "Нет нового файла src/app/cloud.php рядом с патчем"
[[ -f "$PROJECT_DIR/src/public/index.php" ]] || fail "Нет src/public/index.php"
[[ -f "$PROJECT_DIR/src/app/config.example.php" ]] || fail "Нет src/app/config.example.php"
[[ -f "$PROJECT_DIR/install.sh" ]] || fail "Нет install.sh"

mkdir -p "$BACKUP_DIR/source" "$BACKUP_DIR/installed"
for rel in src/public/index.php src/app/config.example.php install.sh; do
  [[ -f "$PROJECT_DIR/$rel" ]] || continue
  mkdir -p "$BACKUP_DIR/source/$(dirname "$rel")"
  cp -a "$PROJECT_DIR/$rel" "$BACKUP_DIR/source/$rel"
done
for src in "$PANEL_DIR/public/index.php" "$PANEL_DIR/app/bootstrap.php" "$PANEL_DIR/app/config.php" "$CONF_FILE"; do
  [[ -f "$src" ]] || continue
  dst="$BACKUP_DIR/installed${src}"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
done
log "Резервная копия: $BACKUP_DIR"

log "Обновляю исходники репозитория под Cloud Storage..."
python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def read(rel):
    p = root / rel
    return p, p.read_text(encoding='utf-8')

def write(p, text):
    p.write_text(text, encoding='utf-8')

def replace_once(text, old, new, label):
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"PATCH ERROR [{label}]: ожидалось 1 совпадение, найдено {count}")
    return text.replace(old, new, 1)

# src/public/index.php
p, s = read('src/public/index.php')
s = replace_once(
    s,
    "require __DIR__ . '/../app/bootstrap.php';\n",
    "require __DIR__ . '/../app/bootstrap.php';\nrequire_once __DIR__ . '/../app/cloud.php';\n",
    'index require cloud'
)
s = replace_once(
    s,
    "if (isset($_GET['api'])) { render_api((string)$_GET['api']); exit; }\nif ($_SERVER['REQUEST_METHOD'] === 'POST') { check_csrf(); handle_post((string)$action); }\nrender_page($page, $user);",
    "if (isset($_GET['api'])) { render_api((string)$_GET['api']); exit; }\nif ($page === 'cloud' && isset($_GET['cloud_action'])) { hh_cloud_handle_get((string)$_GET['cloud_action']); }\nif ($_SERVER['REQUEST_METHOD'] === 'POST') {\n    check_csrf();\n    if (str_starts_with((string)$action, 'cloud_')) { hh_cloud_handle_post((string)$action); }\n    handle_post((string)$action);\n}\nrender_page($page, $user);",
    'index request routing'
)
s = s.replace("function hh_app_version(): string { return '1.9-v93'; }", "function hh_app_version(): string { return '1.9-v94-cloud'; }")
s = replace_once(
    s,
    "'dashboard'=>['fa-chart-line','Дашборд'],'files'=>['fa-folder-open','Файлы'],'disk'=>['fa-hard-drive','Диск']",
    "'dashboard'=>['fa-chart-line','Дашборд'],'files'=>['fa-folder-open','Файлы'],'cloud'=>['fa-cloud','Облако'],'disk'=>['fa-hard-drive','Диск']",
    'index nav cloud'
)
s = replace_once(
    s,
    "'dashboard'=>'Панель управления','files'=>'Файловый менеджер','sites'=>'Сайты и папки'",
    "'dashboard'=>'Панель управления','files'=>'Файловый менеджер','cloud'=>'Облако','sites'=>'Сайты и папки'",
    'index title cloud'
)
s = replace_once(
    s,
    "match($page){ 'files'=>view_files(), 'sites'=>view_sites()",
    "match($page){ 'files'=>view_files(), 'cloud'=>view_cloud(), 'sites'=>view_sites()",
    'index route cloud'
)
# Bump cache query where current v93 markup is still present.
s = s.replace('/assets/style.css?v=93', '/assets/style.css?v=94')
s = s.replace('/assets/app.js?v=93', '/assets/app.js?v=94')
write(p, s)

# src/app/config.example.php
p, s = read('src/app/config.example.php')
s = replace_once(
    s,
    "'bots_dir' => '/var/www/hyper-host-bots',\n",
    "'bots_dir' => '/var/www/hyper-host-bots',\n'cloud_dir' => '/var/www/hyper-host-cloud',\n",
    'config example cloud_dir'
)
write(p, s)

# install.sh - fresh install support
p, s = read('install.sh')
s = replace_once(
    s,
    'BOTS_DIR="/var/www/hyper-host-bots"\nFTP_DIR=',
    'BOTS_DIR="/var/www/hyper-host-bots"\nCLOUD_DIR="/var/www/hyper-host-cloud"\nFTP_DIR=',
    'install cloud variable'
)
s = replace_once(
    s,
    '"$PANEL_DIR" "$SITES_DIR" "$BOTS_DIR" "$FTP_DIR" "$DNS_DIR" "$CONF_DIR"',
    '"$PANEL_DIR" "$SITES_DIR" "$BOTS_DIR" "$CLOUD_DIR" "$FTP_DIR" "$DNS_DIR" "$CONF_DIR"',
    'install mkdir cloud'
)
s = replace_once(
    s,
    'BOTS_DIR="${BOTS_DIR}"\nFTP_DIR=',
    'BOTS_DIR="${BOTS_DIR}"\nCLOUD_DIR="${CLOUD_DIR}"\nFTP_DIR=',
    'install conf cloud'
)
s = replace_once(
    s,
    "    'bots_dir' => '${BOTS_DIR}',\n    'ftp_dir' =>",
    "    'bots_dir' => '${BOTS_DIR}',\n    'cloud_dir' => '${CLOUD_DIR}',\n    'ftp_dir' =>",
    'install php config cloud'
)
s = replace_once(
    s,
    'safe_chown_tree www-data:www-data "$SITES_DIR"\nchown root:root "$FTP_DIR" "$BACKUP_DIR"',
    'safe_chown_tree www-data:www-data "$SITES_DIR"\nsafe_chown_tree www-data:www-data "$CLOUD_DIR"\nchown root:root "$FTP_DIR" "$BACKUP_DIR"',
    'install chown cloud'
)
s = replace_once(
    s,
    'chmod 0755 "$SITES_DIR" "$BOTS_DIR" "$FTP_DIR" "$BACKUP_DIR"\nchmod 0770 "$BASE_DIR/data"',
    'chmod 0755 "$SITES_DIR" "$BOTS_DIR" "$FTP_DIR" "$BACKUP_DIR"\nchmod 2770 "$CLOUD_DIR"\nchmod 0770 "$BASE_DIR/data"',
    'install chmod cloud'
)
write(p, s)
PY

log "Проверяю PHP после изменения исходников..."
php -l "$PROJECT_DIR/src/app/cloud.php" >/dev/null
php -l "$PROJECT_DIR/src/public/index.php" >/dev/null

log "Создаю отдельное физическое облако: $CLOUD_DIR"
mkdir -p "$CLOUD_DIR"
chown www-data:www-data "$CLOUD_DIR"
chmod 2770 "$CLOUD_DIR"
# Existing content is normalized without following symlinks or crossing mounts.
find "$CLOUD_DIR" -xdev -type d -exec chown www-data:www-data {} + -exec chmod 2770 {} + 2>/dev/null || true
find "$CLOUD_DIR" -xdev -type f -exec chown www-data:www-data {} + -exec chmod 0660 {} + 2>/dev/null || true

# Add CLOUD_DIR to shell config without destroying user settings.
if [[ -f "$CONF_FILE" ]]; then
  if grep -q '^CLOUD_DIR=' "$CONF_FILE"; then
    sed -i 's#^CLOUD_DIR=.*#CLOUD_DIR="/var/www/hyper-host-cloud"#' "$CONF_FILE"
  elif grep -q '^BOTS_DIR=' "$CONF_FILE"; then
    sed -i '/^BOTS_DIR=/a CLOUD_DIR="/var/www/hyper-host-cloud"' "$CONF_FILE"
  else
    printf '\nCLOUD_DIR="%s"\n' "$CLOUD_DIR" >> "$CONF_FILE"
  fi
fi

# Keep existing installed secrets/config and only add cloud_dir.
if [[ -f "$PANEL_DIR/app/config.php" ]]; then
  python3 - "$PANEL_DIR/app/config.php" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
if "'cloud_dir'" not in s:
    anchors = [
        "    'bots_dir' => '/var/www/hyper-host-bots',\n",
        "'bots_dir' => '/var/www/hyper-host-bots',\n",
    ]
    done=False
    for a in anchors:
        if a in s:
            indent = a[:len(a)-len(a.lstrip())]
            s=s.replace(a, a + indent + "'cloud_dir' => '/var/www/hyper-host-cloud',\n", 1)
            done=True
            break
    if not done:
        marker='return [\n'
        if marker not in s:
            raise SystemExit('Не удалось добавить cloud_dir в установленный config.php')
        s=s.replace(marker, marker + "    'cloud_dir' => '/var/www/hyper-host-cloud',\n", 1)
    p.write_text(s, encoding='utf-8')
PY
fi

# Deploy only web application files required by the patch. Do not overwrite installed config.php.
if [[ -d "$PANEL_DIR/public" && -d "$PANEL_DIR/app" ]]; then
  log "Устанавливаю Cloud-модуль в действующую панель..."
  install -m 0644 "$PROJECT_DIR/src/public/index.php" "$PANEL_DIR/public/index.php"
  install -m 0644 "$PROJECT_DIR/src/app/cloud.php" "$PANEL_DIR/app/cloud.php"
  chown www-data:www-data "$PANEL_DIR/public/index.php" "$PANEL_DIR/app/cloud.php"
  [[ -f "$PANEL_DIR/app/config.php" ]] && chown www-data:www-data "$PANEL_DIR/app/config.php" && chmod 0640 "$PANEL_DIR/app/config.php"
  php -l "$PANEL_DIR/public/index.php" >/dev/null
  php -l "$PANEL_DIR/app/cloud.php" >/dev/null
else
  warn "Действующая панель в $PANEL_DIR не найдена. Исходники подготовлены для новой установки."
fi

log "Проверяю поддержку архивов..."
if ! command -v 7z >/dev/null 2>&1 && ! command -v 7zz >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    log "Ставлю просмотр ZIP/RAR/7z: p7zip-full + libarchive-tools..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y p7zip-full libarchive-tools unzip >/dev/null 2>&1 || warn "Не удалось автоматически поставить архиваторы. Облако продолжит работать; для RAR/7z установи их вручную."
  else
    warn "7z/bsdtar не найден. ZIP может читаться через PHP ZipArchive; для RAR/7z установи p7zip/libarchive."
  fi
fi

# Restart only existing FPM services; no apt/dpkg and no database changes.
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
 Раздел:        https://panel.hyper-host.pw/?page=cloud
 Хранилище:     ${CLOUD_DIR}
 Права:         www-data:www-data / 2770
 Backup патча:  ${BACKUP_DIR}

 Для полного просмотра .rar/.7z (если 7z ещё нет):
   sudo apt update && sudo apt install -y p7zip-full libarchive-tools

 Быстрая проверка:
   sudo -u www-data test -w ${CLOUD_DIR} && echo CLOUD_WRITE_OK
   php -l ${PANEL_DIR}/app/cloud.php
   sudo nginx -t
============================================================
EOF
