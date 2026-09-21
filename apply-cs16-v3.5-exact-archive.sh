#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel"
[[ -f "$SRC/bin/hyper-cs16-ctl" && -f "$SRC/bin/hyper-cs16-monitor" && -f "$SRC/public/index.php" && -f "$SRC/app/bootstrap.php" ]] || {
  echo '[ERROR] Run this script from the v3.5-exact-archive patched repository root' >&2; exit 2;
}
BASE='/opt/hyper-cs16'
DOMAIN='www.avito.hyper-host.pw'
CANONICAL_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'

say(){ printf '\033[1;36m[CS16 v3.5-exact-archive]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v3.5-exact-archive WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[CS16 v3.5-exact-archive ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

say 'Installing dependencies...'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends rsync curl p7zip-full python3-pymysql mariadb-client >/dev/null

say 'Validating patch source...'
python3 -m py_compile \
  "$SRC/bin/hyper-cs16-ctl" "$SRC/bin/hyper-cs16-monitor" "$SRC/bin/hyper-cs16-run" \
  "$SRC/bin/hyper-cs16-migrate-v26" "$SRC/bin/hyper-cs16-migrate-v27" "$SRC/bin/hyper-cs16-migrate-v28" "$SRC/bin/hyper-cs16-migrate-v31" "$SRC/lib/csquery.py"
for f in "$SRC/public/index.php" "$SRC/public/api.php" "$SRC/public/public-api.php" "$SRC/app/bootstrap.php"; do
  php -l "$f" >/dev/null || fail "PHP syntax error: $f"
done
if command -v node >/dev/null 2>&1; then node --check "$SRC/public/assets/app.js" >/dev/null; fi

say 'Installing controller/runtime-management code only...'
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
systemctl daemon-reload
say 'Existing /srv/hyper-cs16/servers/* game files are NOT changed and game services are NOT restarted by this installer.'

say 'Preparing mutable state and upload staging...'
install -d -m 0751 -o root -g cs16 /var/lib/hyper-cs16
install -d -m 0750 -o root -g cs16 /var/lib/hyper-cs16/servers /var/lib/hyper-cs16/deleted
install -d -m 0750 -o www-data -g www-data /var/tmp/hyper-cs16-panel
install -d -m 0770 -o www-data -g www-data /var/tmp/hyper-cs16-panel/uploads
STAGING_JSON="$(/usr/local/sbin/hyper-cs16-ctl staging-prepare 2>&1)" || fail "Upload staging self-test failed: $STAGING_JSON"
runuser -u www-data -- sh -c 'f=/var/tmp/hyper-cs16-panel/uploads/.write-test-$$; : > "$f" && rm -f "$f"' || fail 'www-data cannot write upload staging'
say "Upload staging OK: $STAGING_JSON"

say 'Running database migrations...'
/usr/local/sbin/hyper-cs16-migrate-v26
/usr/local/sbin/hyper-cs16-migrate-v27
/usr/local/sbin/hyper-cs16-migrate-v28
/usr/local/sbin/hyper-cs16-migrate-v31

say 'Preparing legacy MySQL socket compatibility without touching game files...'
systemctl start mariadb.service 2>/dev/null || true
MYSQL_SOCKET="$(mysql -NBe \"SHOW VARIABLES LIKE 'socket'\" 2>/dev/null | awk '{print $2}' | head -n1 || true)"
if [[ -z "$MYSQL_SOCKET" ]]; then
  for cand in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock; do [[ -S "$cand" ]] && MYSQL_SOCKET="$cand" && break; done
fi
if [[ -n "$MYSQL_SOCKET" && -S "$MYSQL_SOCKET" ]]; then
  rm -f /tmp/mysql.sock
  ln -s "$MYSQL_SOCKET" /tmp/mysql.sock
  say "Legacy MySQL socket ready: /tmp/mysql.sock -> $MYSQL_SOCKET"
else
  warn 'MariaDB socket was not found. SQL plugins can still use 127.0.0.1, but old plugins hardcoded to /tmp/mysql.sock may need MariaDB checked.'
fi

say 'Removing obsolete per-server resource-limit drop-ins...'
find /etc/systemd/system -maxdepth 2 -type f -path '/etc/systemd/system/hyper-cs16@*.service.d/limits.conf' -delete 2>/dev/null || true
systemctl daemon-reload

say 'Raising upload limits...'
cat >/etc/nginx/conf.d/hyper-cs16-large-upload.conf <<'NGEOF'
client_max_body_size 32g;
client_body_timeout 3600s;
fastcgi_read_timeout 3600s;
send_timeout 3600s;
NGEOF
for d in /etc/php/*/fpm/conf.d; do
  [[ -d "$d" ]] || continue
  cat >"$d/99-hyper-cs16-upload.ini" <<'PHPEOF'
upload_max_filesize = 32G
post_max_size = 32G
max_execution_time = 0
max_input_time = -1
PHPEOF
done

say 'Keeping built-in FastDL endpoint configured; existing server.cfg files are not rewritten now...'
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
cat >/etc/nginx/conf.d/hyper-cs16-fastdl.conf <<NGXEOF
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
NGXEOF
nginx -t >/dev/null || fail 'nginx config check failed after FastDL config'

say "Discovering ACTIVE nginx document root(s) for $DOMAIN only..."
NGTMP="$(mktemp)"; trap 'rm -f "$NGTMP"' EXIT
nginx -T >"$NGTMP" 2>&1 || fail 'nginx -T failed; refusing to guess a document root'
mapfile -t ACTIVE_ROOTS < <(python3 - "$NGTMP" "$DOMAIN" <<'PY'
import re,sys,os
p,domain=sys.argv[1:]
lines=open(p,encoding='utf-8',errors='ignore').read().splitlines()
roots=[]; cur=[]; depth=0; in_server=False
for line in lines:
    stripped=line.strip()
    if not in_server and re.match(r'^server\s*\{',stripped):
        in_server=True; cur=[line]; depth=line.count('{')-line.count('}'); continue
    if in_server:
        cur.append(line); depth += line.count('{')-line.count('}')
        if depth<=0:
            block='\n'.join(cur); in_server=False; cur=[]
            names=[]
            for m in re.finditer(r'(?m)^\s*server_name\s+([^;]+);',block): names += m.group(1).split()
            if domain not in names: continue
            # Prefer a root declared at server scope. nginx -T is already expanded
            # enough for the panel's ordinary vhost layout.
            m=re.search(r'(?m)^\s*root\s+([^;]+);',block)
            if m:
                r=m.group(1).strip().strip('"\'')
                if r.startswith('/') and r not in roots: roots.append(r)
for r in roots:
    print(os.path.normpath(r))
PY
)

# Never deploy to stale FTP-hosted site copies merely because old files exist.
FILTERED=()
for r in "${ACTIVE_ROOTS[@]:-}"; do
  [[ -n "$r" ]] || continue
  if [[ "$r" == /var/www/hyper-host-ftp/* ]]; then
    warn "Skipping FTP-hosted/stale panel copy even if present in nginx dump: $r"
    continue
  fi
  FILTERED+=("$r")
done
if [[ ${#FILTERED[@]} -eq 0 && -d "$CANONICAL_PUBLIC" ]]; then FILTERED+=("$CANONICAL_PUBLIC"); fi
[[ ${#FILTERED[@]} -gt 0 ]] || fail "No safe active document root found for $DOMAIN; game servers were left untouched"

# De-duplicate roots while keeping order.
declare -A SEEN=(); ROOTS=()
for r in "${FILTERED[@]}"; do [[ -n "${SEEN[$r]:-}" ]] && continue; SEEN[$r]=1; ROOTS+=("$r"); done
say "Deploying panel v3.5-exact-archive to ${#ROOTS[@]} active root(s)..."
for DOCROOT in "${ROOTS[@]}"; do
  [[ "$DOCROOT" == /var/www/* ]] || { warn "Skipping non-/var/www root: $DOCROOT"; continue; }
  mkdir -p "$DOCROOT"
  APPDIR="$(dirname "$DOCROOT")/app"
  mkdir -p "$APPDIR"
  rsync -a --delete "$SRC/app/" "$APPDIR/"
  rsync -a --delete "$SRC/public/" "$DOCROOT/"
  chown -R www-data:www-data "$APPDIR" "$DOCROOT" 2>/dev/null || true
  find "$APPDIR" "$DOCROOT" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$APPDIR" "$DOCROOT" -type f -exec chmod 0644 {} + 2>/dev/null || true
  if [[ -e "$DOCROOT/fastdl" && ! -L "$DOCROOT/fastdl" ]]; then rm -rf "$DOCROOT/fastdl"; fi
  ln -sfn /srv/hyper-cs16/fastdl "$DOCROOT/fastdl"
  grep -q "HYPER_CS16_PANEL_BUILD = '3.5-exact-archive'" "$APPDIR/bootstrap.php" || fail "v3.5 bootstrap validation failed at active app path: $APPDIR/bootstrap.php"
  grep -q 'style.css?v=350' "$DOCROOT/index.php" || fail "v3.5 index validation failed at active document root: $DOCROOT"
  say "Deployed active panel root: $DOCROOT"
done

say 'Clearing PHP OPcache...'
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl restart "$unit" || fail "Failed to restart $unit"
  say "Restarted $unit"
done < <(systemctl list-unit-files --type=service --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | sort -u)

systemctl enable hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl restart hyper-cs16-monitor.service
systemctl reload nginx

say 'No existing HLDS service was restarted and no existing assembly was replaced.'
say 'The new PrivateTmp=false unit will take effect only when a server is next restarted/repaired/updated by an explicit action.'

say 'Verifying live panel marker...'
LIVE="$(curl -ksS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/?page=login" 2>/dev/null || true)"
if [[ -n "$LIVE" && "$LIVE" == *'style.css?v=350'* ]]; then
  say 'Live web verification OK: v3.5-exact-archive marker is being served.'
elif [[ -n "$LIVE" ]]; then
  warn 'HTTPS answered but v3.5 marker was not found. Active-root deployment passed; inspect nginx proxy/root if the browser still shows an old panel.'
else
  warn 'Local HTTPS live check was unavailable. Active-root files and PHP syntax were validated.'
fi

echo
say 'DONE. Existing assembly files stayed untouched. For server #11 use the new “Исправить runtime текущей сборки” action if needed; re-upload the original archive once for exact restoration of files that older compat-content-overlay already discarded.'
