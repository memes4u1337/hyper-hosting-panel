#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel"
[[ -f "$SRC/bin/hyper-cs16-ctl" && -f "$SRC/bin/hyper-cs16-monitor" && -f "$SRC/public/index.php" && -f "$SRC/app/bootstrap.php" ]] || {
  echo '[ERROR] Run this script from the v3.2-fastdl patched HYPER-HOST repository root' >&2; exit 2;
}
BASE='/opt/hyper-cs16'
DOMAIN='www.avito.hyper-host.pw'
CANONICAL_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'

say(){ printf '\033[1;36m[CS16 v3.2-fastdl]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v3.2-fastdl WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[CS16 v3.2-fastdl ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

say 'Installing dependencies...'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends rsync curl p7zip-full python3-pymysql mariadb-client >/dev/null

say 'Validating source files...'
python3 -m py_compile \
  "$SRC/bin/hyper-cs16-ctl" "$SRC/bin/hyper-cs16-monitor" "$SRC/bin/hyper-cs16-run" \
  "$SRC/bin/hyper-cs16-migrate-v26" "$SRC/bin/hyper-cs16-migrate-v27" "$SRC/bin/hyper-cs16-migrate-v28" "$SRC/bin/hyper-cs16-migrate-v31" "$SRC/lib/csquery.py"
for f in "$SRC/public/index.php" "$SRC/public/api.php" "$SRC/public/public-api.php" "$SRC/app/bootstrap.php"; do
  php -l "$f" >/dev/null || fail "PHP syntax error: $f"
done
if command -v node >/dev/null 2>&1; then node --check "$SRC/public/assets/app.js" >/dev/null; fi

say 'Installing controller and monitor...'
install -d -m 0755 "$BASE/lib"
install -m 0755 "$SRC/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC/bin/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor
install -m 0755 "$SRC/bin/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v26" /usr/local/sbin/hyper-cs16-migrate-v26
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v27" /usr/local/sbin/hyper-cs16-migrate-v27
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v28" /usr/local/sbin/hyper-cs16-migrate-v28
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v31" /usr/local/sbin/hyper-cs16-migrate-v31
install -m 0644 "$SRC/lib/csquery.py" "$BASE/lib/csquery.py"
say 'No bundled game/server build files are included in this patch.'
install -m 0644 "$SRC/systemd/hyper-cs16-monitor.service" /etc/systemd/system/hyper-cs16-monitor.service
install -m 0644 "$SRC/systemd/hyper-cs16@.service" /etc/systemd/system/hyper-cs16@.service

say 'Preparing mutable state...'
install -d -m 0751 -o root -g cs16 /var/lib/hyper-cs16
install -d -m 0750 -o root -g cs16 /var/lib/hyper-cs16/servers /var/lib/hyper-cs16/deleted
# v3.0 upload staging deliberately lives under /var/tmp. It no longer depends on
# traversing /var/lib or any read-only /etc mount.
install -d -m 0750 -o www-data -g www-data /var/tmp/hyper-cs16-panel
install -d -m 0770 -o www-data -g www-data /var/tmp/hyper-cs16-panel/uploads

systemctl daemon-reload
say 'Verifying upload staging as www-data...'
STAGING_JSON="$(/usr/local/sbin/hyper-cs16-ctl staging-prepare 2>&1)" || fail "Upload staging controller self-test failed: $STAGING_JSON"
runuser -u www-data -- sh -c 'f=/var/tmp/hyper-cs16-panel/uploads/.write-test-$$; : > "$f" && rm -f "$f"' || fail 'www-data cannot create files in /var/tmp/hyper-cs16-panel/uploads'
say "Upload staging OK: $STAGING_JSON"

say 'Running database migrations...'
/usr/local/sbin/hyper-cs16-migrate-v26
/usr/local/sbin/hyper-cs16-migrate-v27
/usr/local/sbin/hyper-cs16-migrate-v28
/usr/local/sbin/hyper-cs16-migrate-v31

say 'Rescanning existing servers for physically installed ZM/AMXX mods...'
shopt -s nullglob
for cfg in /var/lib/hyper-cs16/servers/*.json; do
  sid="$(basename "$cfg" .json)"
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  if MOD_JSON="$(/usr/local/sbin/hyper-cs16-ctl mods-status "$sid" 2>&1)"; then
    say "Server #$sid mod scan: $MOD_JSON"
  else
    warn "Server #$sid mod scan failed: $MOD_JSON"
  fi
done
shopt -u nullglob

say 'Provisioning dedicated SQL for every existing game server...'
shopt -s nullglob
for cfg in /var/lib/hyper-cs16/servers/*.json; do
  sid="$(basename "$cfg" .json)"
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  if SQL_JSON="$(/usr/local/sbin/hyper-cs16-ctl sql-provision "$sid" 2>&1)"; then
    say "Server #$sid SQL ready: $SQL_JSON"
  else
    warn "Server #$sid SQL provisioning failed (game server left untouched): $SQL_JSON"
  fi
done
shopt -u nullglob

say 'Removing legacy resource limits...'
find /etc/systemd/system -maxdepth 2 -type f -path '/etc/systemd/system/hyper-cs16@*.service.d/limits.conf' -delete 2>/dev/null || true
systemctl daemon-reload

say 'Raising upload limits...'
cat >/etc/nginx/conf.d/hyper-cs16-large-upload.conf <<'EOF'
client_max_body_size 32g;
client_body_timeout 3600s;
fastcgi_read_timeout 3600s;
send_timeout 3600s;
EOF
for d in /etc/php/*/fpm/conf.d; do
  [[ -d "$d" ]] || continue
  cat >"$d/99-hyper-cs16-upload.ini" <<'EOF'
upload_max_filesize = 32G
post_max_size = 32G
max_execution_time = 0
max_input_time = -1
EOF
done

say 'Configuring built-in FastDL on HTTP/80...'
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
cat >/etc/nginx/conf.d/hyper-cs16-fastdl.conf <<EOF
# HYPER-HOST CS 1.6 built-in FastDL. Clients use the public IPv4 directly.
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
EOF
nginx -t >/dev/null || fail 'nginx FastDL config check failed'

say 'Discovering the REAL document root for www.avito.hyper-host.pw...'
declare -A ROOTS=()
if [[ -d "$CANONICAL_PUBLIC" ]]; then ROOTS["$CANONICAL_PUBLIC"]=1; fi
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  ROOTS["$(dirname "$f")"]=1
done < <(find /var/www -xdev -type f -name index.php -path '*avito.hyper-host.pw*' 2>/dev/null || true)

# Also parse nginx -T so a non-standard document root that does not contain the
# domain name is still found.
NGTMP="$(mktemp)"; trap 'rm -f "$NGTMP"' EXIT
nginx -T >"$NGTMP" 2>&1 || true
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  [[ "$r" == /* ]] || continue
  ROOTS["$r"]=1
done < <(python3 - "$NGTMP" "$DOMAIN" <<'PY'
import re,sys
p,domain=sys.argv[1:]
text=open(p,encoding='utf-8',errors='ignore').read().splitlines()
blocks=[]; cur=[]; depth=0; in_server=False
for line in text:
    stripped=line.strip()
    if not in_server and re.match(r'^server\s*\{', stripped):
        in_server=True; cur=[line]; depth=line.count('{')-line.count('}'); continue
    if in_server:
        cur.append(line); depth += line.count('{')-line.count('}')
        if depth<=0:
            b='\n'.join(cur); in_server=False; cur=[]
            if re.search(r'\bserver_name\b[^;]*\b'+re.escape(domain)+r'\b',b):
                m=re.search(r'(?m)^\s*root\s+([^;]+);',b)
                if m: print(m.group(1).strip())
PY
)

if [[ ${#ROOTS[@]} -eq 0 ]]; then
  fail "Could not find document root for $DOMAIN. Existing panel files were not touched."
fi

say "Deploying v3.2-fastdl to ${#ROOTS[@]} detected document root(s)..."
for DOCROOT in "${!ROOTS[@]}"; do
  [[ "$DOCROOT" == /var/www/* ]] || { warn "Skipping suspicious root: $DOCROOT"; continue; }
  mkdir -p "$DOCROOT"
  APPDIR="$(dirname "$DOCROOT")/app"
  mkdir -p "$APPDIR"
  rsync -a --delete "$SRC/app/" "$APPDIR/"
  rsync -a --delete "$SRC/public/" "$DOCROOT/"
  chown -R www-data:www-data "$APPDIR" "$DOCROOT" 2>/dev/null || true
  find "$APPDIR" "$DOCROOT" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$APPDIR" "$DOCROOT" -type f -exec chmod 0644 {} + 2>/dev/null || true
  # HTTPS/domain fallback for FastDL and an easy browser check. The dedicated
  # public-IP HTTP vhost above remains the URL written into GoldSrc server.cfg.
  if [[ -e "$DOCROOT/fastdl" && ! -L "$DOCROOT/fastdl" ]]; then rm -rf "$DOCROOT/fastdl"; fi
  ln -sfn /srv/hyper-cs16/fastdl "$DOCROOT/fastdl"
  grep -q "HYPER_CS16_PANEL_BUILD = '3.2-fastdl'" "$APPDIR/bootstrap.php" || fail "Wrong bootstrap deployed to $APPDIR/bootstrap.php"
  ! grep -qF 'Upload staging не настроен. Повтори install-cs16-panel.sh' "$APPDIR/bootstrap.php" || fail "Old v2.6/v2.7 bootstrap is still present at $APPDIR/bootstrap.php"
  grep -q 'style.css?v=320' "$DOCROOT/index.php" || fail "Wrong index.php deployed to $DOCROOT"
  say "Deployed: $DOCROOT (app: $APPDIR)"
done

say 'Clearing PHP OPcache by restarting every installed php-fpm service...'
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl restart "$unit" || fail "Failed to restart $unit"
  say "Restarted $unit"
done < <(systemctl list-unit-files --type=service --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | sort -u)

systemctl enable hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl restart hyper-cs16-monitor.service
systemctl reload nginx

say 'Enabling FastDL for every existing CS server...'
FASTDL_JSON="$(/usr/local/sbin/hyper-cs16-ctl fastdl-sync-all 2>&1)" || warn "Some FastDL syncs failed: $FASTDL_JSON"
say "FastDL sync result: $FASTDL_JSON"

# Local web self-test using the exact IP Host header that GoldSrc will request.
if [[ -n "$PUBLIC_IP" ]]; then
  SAMPLE="$(find /srv/hyper-cs16/fastdl -type f 2>/dev/null | head -n1 || true)"
  if [[ -n "$SAMPLE" ]]; then
    REL="${SAMPLE#/srv/hyper-cs16/}"
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $PUBLIC_IP" "http://127.0.0.1/$REL" || true)"
    [[ "$CODE" == "200" ]] && say "FastDL HTTP self-test OK: http://$PUBLIC_IP/$REL" || warn "FastDL HTTP self-test returned HTTP $CODE for $REL"
  else
    warn 'FastDL has no resource files yet; HTTP path is configured and will populate when a server has custom content.'
  fi
fi

say 'Verifying that nginx serves v3.2-fastdl, not cached/old PHP...'
LIVE="$(curl -ksS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/?page=login" 2>/dev/null || true)"
if [[ -n "$LIVE" ]]; then
  if grep -q 'style.css?v=320' <<<"$LIVE"; then
    say 'Live web verification OK: panel v3.2-fastdl is being served.'
  else
    warn 'Live HTTPS answered, but v3.2-fastdl marker was not found. Check nginx root/server_name; file deployment itself passed.'
  fi
else
  warn 'Could not perform local HTTPS live check. File deployment and PHP-FPM restart passed.'
fi

echo
say 'DONE. Built-in per-server FastDL + automatic build repair + SQL/statistics are installed. No game/server build files are bundled.'
say 'Open the panel and press Ctrl+F5. The sidebar must show Panel v3.2-fastdl.'
