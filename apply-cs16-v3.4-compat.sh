#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel"
[[ -f "$SRC/bin/hyper-cs16-ctl" && -f "$SRC/bin/hyper-cs16-monitor" && -f "$SRC/public/index.php" && -f "$SRC/app/bootstrap.php" ]] || {
  echo '[ERROR] Run this script from the v3.4-compat patched repository root' >&2; exit 2;
}
BASE='/opt/hyper-cs16'
DOMAIN='www.avito.hyper-host.pw'
CANONICAL_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'

say(){ printf '\033[1;36m[CS16 v3.4-compat]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v3.4-compat WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[CS16 v3.4-compat ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

say 'Installing controller dependencies...'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends rsync curl p7zip-full python3-pymysql mariadb-client >/dev/null

say 'Validating patch syntax...'
python3 -m py_compile \
  "$SRC/bin/hyper-cs16-ctl" "$SRC/bin/hyper-cs16-monitor" "$SRC/bin/hyper-cs16-run" \
  "$SRC/bin/hyper-cs16-migrate-v26" "$SRC/bin/hyper-cs16-migrate-v27" "$SRC/bin/hyper-cs16-migrate-v28" "$SRC/bin/hyper-cs16-migrate-v31" "$SRC/lib/csquery.py"
for f in "$SRC/public/index.php" "$SRC/public/api.php" "$SRC/public/public-api.php" "$SRC/app/bootstrap.php"; do
  php -l "$f" >/dev/null || fail "PHP syntax error: $f"
done
if command -v node >/dev/null 2>&1; then node --check "$SRC/public/assets/app.js" >/dev/null; fi

# IMPORTANT: v3.4 intentionally does NOT run sql-provision, fastdl-sync, reinstall,
# repair-runtime, update, restart or any other mutating command against existing
# /srv/hyper-cs16/servers/* trees. The currently working build stays byte-for-byte
# where it is. New compatibility logic is used only on the next ZIP/RAR import.
say 'Preserving every existing game server exactly as-is (no HLDS restart, no server.cfg rewrite, no SQL/FastDL resync).'

say 'Installing controller/monitor code...'
install -d -m 0755 "$BASE/lib"
install -m 0755 "$SRC/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC/bin/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor
install -m 0755 "$SRC/bin/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v26" /usr/local/sbin/hyper-cs16-migrate-v26
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v27" /usr/local/sbin/hyper-cs16-migrate-v27
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v28" /usr/local/sbin/hyper-cs16-migrate-v28
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v31" /usr/local/sbin/hyper-cs16-migrate-v31
install -m 0644 "$SRC/lib/csquery.py" "$BASE/lib/csquery.py"
install -m 0644 "$SRC/systemd/hyper-cs16-monitor.service" /etc/systemd/system/hyper-cs16-monitor.service
install -m 0644 "$SRC/systemd/hyper-cs16@.service" /etc/systemd/system/hyper-cs16@.service

say 'Preparing upload staging only...'
install -d -m 0751 -o root -g cs16 /var/lib/hyper-cs16
install -d -m 0750 -o root -g cs16 /var/lib/hyper-cs16/servers /var/lib/hyper-cs16/deleted
install -d -m 0750 -o www-data -g www-data /var/tmp/hyper-cs16-panel
install -d -m 0770 -o www-data -g www-data /var/tmp/hyper-cs16-panel/uploads
systemctl daemon-reload
STAGING_JSON="$(/usr/local/sbin/hyper-cs16-ctl staging-prepare 2>&1)" || fail "Upload staging test failed: $STAGING_JSON"
say "Upload staging OK: $STAGING_JSON"

say 'Running panel database migrations (game databases are not touched)...'
/usr/local/sbin/hyper-cs16-migrate-v26
/usr/local/sbin/hyper-cs16-migrate-v27
/usr/local/sbin/hyper-cs16-migrate-v28
/usr/local/sbin/hyper-cs16-migrate-v31

say 'Keeping large upload limits...'
cat >/etc/nginx/conf.d/hyper-cs16-large-upload.conf <<'NGINX'
client_max_body_size 32g;
client_body_timeout 3600s;
fastcgi_read_timeout 3600s;
send_timeout 3600s;
NGINX
for d in /etc/php/*/fpm/conf.d; do
  [[ -d "$d" ]] || continue
  cat >"$d/99-hyper-cs16-upload.ini" <<'PHPINI'
upload_max_filesize = 32G
post_max_size = 32G
max_execution_time = 0
max_input_time = -1
PHPINI
done

# Keep the already-established FastDL web endpoint available, but DO NOT sync
# existing servers or rewrite their server.cfg during this patch installation.
install -d -m 0755 -o root -g www-data /srv/hyper-cs16/fastdl
PUBLIC_IP="$(python3 - <<'PYIP'
import json,ipaddress
try:
    d=json.load(open('/etc/hyper-cs16/runtime.json',encoding='utf-8'))
    v=str(d.get('public_ip') or '').strip()
    print(v if ipaddress.ip_address(v).version==4 else '')
except Exception:
    print('')
PYIP
)"
FASTDL_SERVER_NAME="${PUBLIC_IP:-fastdl.local.invalid}"
cat >/etc/nginx/conf.d/hyper-cs16-fastdl.conf <<EOF2
server {
    listen 80;
    listen [::]:80;
    server_name ${FASTDL_SERVER_NAME};
    location ^~ /fastdl/ {
        root /srv/hyper-cs16;
        autoindex off;
        access_log off;
        log_not_found off;
        default_type application/octet-stream;
        sendfile on;
        tcp_nopush on;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000" always;
        add_header Access-Control-Allow-Origin "*" always;
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF2
nginx -t >/dev/null || fail 'nginx config check failed'

say "Discovering document root for $DOMAIN..."
declare -A ROOTS=()
if [[ -d "$CANONICAL_PUBLIC" ]]; then ROOTS["$CANONICAL_PUBLIC"]=1; fi
while IFS= read -r f; do [[ -n "$f" ]] && ROOTS["$(dirname "$f")"]=1; done < <(find /var/www -xdev -type f -name index.php -path '*avito.hyper-host.pw*' 2>/dev/null || true)
NGTMP="$(mktemp)"; trap 'rm -f "$NGTMP"' EXIT
nginx -T >"$NGTMP" 2>&1 || true
while IFS= read -r r; do [[ "$r" == /* ]] && ROOTS["$r"]=1; done < <(python3 - "$NGTMP" "$DOMAIN" <<'PY'
import re,sys
p,domain=sys.argv[1:]
text=open(p,encoding='utf-8',errors='ignore').read().splitlines(); cur=[]; depth=0; inside=False
for line in text:
    st=line.strip()
    if not inside and re.match(r'^server\s*\{',st): inside=True; cur=[line]; depth=line.count('{')-line.count('}'); continue
    if inside:
        cur.append(line); depth+=line.count('{')-line.count('}')
        if depth<=0:
            b='\n'.join(cur); inside=False; cur=[]
            if re.search(r'\bserver_name\b[^;]*\b'+re.escape(domain)+r'\b',b):
                m=re.search(r'(?m)^\s*root\s+([^;]+);',b)
                if m: print(m.group(1).strip())
PY
)
[[ ${#ROOTS[@]} -gt 0 ]] || fail "Could not find document root for $DOMAIN"

say "Deploying panel v3.4-compat to ${#ROOTS[@]} document root(s)..."
for DOCROOT in "${!ROOTS[@]}"; do
  [[ "$DOCROOT" == /var/www/* ]] || { warn "Skipping suspicious root: $DOCROOT"; continue; }
  APPDIR="$(dirname "$DOCROOT")/app"
  mkdir -p "$DOCROOT" "$APPDIR"
  rsync -a --delete "$SRC/app/" "$APPDIR/"
  rsync -a --delete "$SRC/public/" "$DOCROOT/"
  chown -R www-data:www-data "$APPDIR" "$DOCROOT" 2>/dev/null || true
  find "$APPDIR" "$DOCROOT" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$APPDIR" "$DOCROOT" -type f -exec chmod 0644 {} + 2>/dev/null || true
  if [[ -e "$DOCROOT/fastdl" && ! -L "$DOCROOT/fastdl" ]]; then rm -rf "$DOCROOT/fastdl"; fi
  ln -sfn /srv/hyper-cs16/fastdl "$DOCROOT/fastdl"
  grep -q "HYPER_CS16_PANEL_BUILD = '3.4-compat'" "$APPDIR/bootstrap.php" || fail "Wrong bootstrap deployed: $APPDIR/bootstrap.php"
  grep -q 'style.css?v=340' "$DOCROOT/index.php" || fail "Wrong index.php deployed: $DOCROOT"
  say "Deployed: $DOCROOT"
done

say 'Restarting PHP-FPM and panel monitor only; game server units are deliberately untouched.'
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl restart "$unit" || fail "Failed to restart $unit"
done < <(systemctl list-unit-files --type=service --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | sort -u)
systemctl enable hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl restart hyper-cs16-monitor.service
systemctl reload nginx

say 'DONE. Existing game builds were NOT modified or restarted.'
say 'New ZIP/RAR imports now auto-match ReAPI to ReHLDS/ReGameDLL, repair legacy MySQL socket/configs, preserve full Linux build configs, and validate fresh runtime errors.'
say 'Open the panel and press Ctrl+F5. Sidebar: Panel v3.4-compat.'
