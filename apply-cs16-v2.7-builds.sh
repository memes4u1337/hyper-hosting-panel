#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel"
[[ -f "$SRC/bin/hyper-cs16-ctl" && -f "$SRC/bin/hyper-cs16-monitor" && -f "$SRC/bin/hyper-cs16-migrate-v27" && -f "$SRC/public/index.php" ]] || {
  echo '[ERROR] Run this script from the v2.7 patched HYPER-HOST repository root' >&2; exit 2;
}
SITE_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'
SITE_APP='/var/www/hyper-host-sites/www.avito.hyper-host.pw/app'
BASE='/opt/hyper-cs16'

say(){ printf '\033[1;36m[CS16 v2.7]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v2.7 WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[CS16 v2.7 ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

say 'Installing dependencies for ZIP/RAR builds and panel runtime...'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends rsync curl p7zip-full python3-pymysql >/dev/null

say 'Validating files before deployment...'
python3 -m py_compile \
  "$SRC/bin/hyper-cs16-ctl" "$SRC/bin/hyper-cs16-monitor" "$SRC/bin/hyper-cs16-run" \
  "$SRC/bin/hyper-cs16-migrate-v26" "$SRC/bin/hyper-cs16-migrate-v27" "$SRC/lib/csquery.py"
for f in "$SRC/public/index.php" "$SRC/public/api.php" "$SRC/public/public-api.php" "$SRC/app/bootstrap.php"; do
  php -l "$f" >/dev/null || fail "PHP syntax error: $f"
done
if command -v node >/dev/null 2>&1; then node --check "$SRC/public/assets/app.js" >/dev/null; fi

say 'Installing controller/monitor and DB migrations...'
install -d -m 0755 "$BASE/lib"
install -m 0755 "$SRC/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC/bin/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor
install -m 0755 "$SRC/bin/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v26" /usr/local/sbin/hyper-cs16-migrate-v26
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v27" /usr/local/sbin/hyper-cs16-migrate-v27
install -m 0644 "$SRC/lib/csquery.py" "$BASE/lib/csquery.py"
install -m 0644 "$SRC/systemd/hyper-cs16-monitor.service" /etc/systemd/system/hyper-cs16-monitor.service
install -m 0644 "$SRC/systemd/hyper-cs16@.service" /etc/systemd/system/hyper-cs16@.service

# Mutable state stays outside immutable/read-only /etc.
install -d -m 0750 -o root -g cs16 /var/lib/hyper-cs16 /var/lib/hyper-cs16/servers /var/lib/hyper-cs16/deleted
install -d -m 0770 -o www-data -g cs16 /var/lib/hyper-cs16/uploads

systemctl daemon-reload
say 'Migrating hosting tables and disabling all resource quotas...'
/usr/local/sbin/hyper-cs16-migrate-v26
/usr/local/sbin/hyper-cs16-migrate-v27

say 'Removing old systemd CPU/RAM restrictions without restarting game servers...'
find /etc/systemd/system -maxdepth 2 -type f -path '/etc/systemd/system/hyper-cs16@*.service.d/limits.conf' -delete 2>/dev/null || true
systemctl daemon-reload
python3 - <<'PY'
import json, subprocess
from pathlib import Path
try: import pymysql
except Exception: raise SystemExit(0)
p=Path('/etc/hyper-cs16/runtime.json')
if not p.is_file(): raise SystemExit(0)
r=json.loads(p.read_text(encoding='utf-8'))
con=pymysql.connect(host=r.get('db_host','127.0.0.1'),port=int(r.get('db_port',3306)),user=r['db_user'],password=r['db_password'],database=r['db_name'],charset='utf8mb4',cursorclass=pymysql.cursors.DictCursor)
with con.cursor() as c:
    c.execute('SELECT id FROM servers ORDER BY id'); ids=[int(x['id']) for x in c.fetchall()]
con.close()
for sid in ids:
    cp=subprocess.run(['/usr/local/sbin/hyper-cs16-ctl','limits-set',str(sid),'--cpu','0','--memory','0'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
    print(f'[CS16 v2.7] #{sid}: unlimited' if cp.returncode==0 else f'[CS16 v2.7] #{sid}: unlimited warning: {(cp.stdout or "")[-500:]}')
PY

say 'Raising web upload ceiling for large CS assemblies...'
cat >/etc/nginx/conf.d/hyper-cs16-large-upload.conf <<'EOF'
# HYPER-HOST CS 1.6 custom build uploads / long unpack+health-check request
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
for svc in /lib/systemd/system/php*-fpm.service; do
  [[ -e "$svc" ]] || continue
  name="$(basename "$svc")"
  systemctl try-restart "$name" >/dev/null 2>&1 || true
done
nginx -t >/dev/null || fail 'nginx config check failed after upload setting'

if [[ -d "$SITE_PUBLIC" ]]; then
  say 'Deploying v2.7 panel UI...'
  rsync -a --delete "$SRC/public/" "$SITE_PUBLIC/"
  chown -R www-data:www-data "$SITE_PUBLIC" 2>/dev/null || true
  find "$SITE_PUBLIC" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$SITE_PUBLIC" -type f -exec chmod 0644 {} + 2>/dev/null || true
else warn "$SITE_PUBLIC does not exist. Web files were not deployed."; fi
if [[ -d "$SITE_APP" ]]; then
  rsync -a --delete "$SRC/app/" "$SITE_APP/"
  chown -R www-data:www-data "$SITE_APP" 2>/dev/null || true
else warn "$SITE_APP does not exist. bootstrap.php was not deployed."; fi

say 'Restarting monitor and reloading nginx. HLDS servers are NOT restarted...'
systemctl enable hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl restart hyper-cs16-monitor.service
systemctl reload nginx

echo
say 'DONE.'
say 'Fixed: delete on read-only /etc, unlimited CPU/RAM/disk/FTP, ZIP/RAR custom build installer with rollback.'
say 'Open www.avito.hyper-host.pw, Ctrl+F5, then Server -> Service/Deletion -> Install ready build.'
