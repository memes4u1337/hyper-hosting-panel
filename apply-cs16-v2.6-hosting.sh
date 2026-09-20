#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel"
[[ -f "$SRC/bin/hyper-cs16-ctl" && -f "$SRC/bin/hyper-cs16-monitor" && -f "$SRC/bin/hyper-cs16-migrate-v26" && -f "$SRC/public/index.php" && -f "$SRC/public/public-api.php" ]] || {
  echo '[ERROR] Run this script from the v2.6 patched HYPER-HOST repository root' >&2; exit 2;
}
SITE_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'
SITE_APP='/var/www/hyper-host-sites/www.avito.hyper-host.pw/app'
BASE='/opt/hyper-cs16'

say(){ printf '\033[1;36m[CS16 v2.6]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v2.6 WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[CS16 v2.6 ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

say 'Checking dependencies...'
export DEBIAN_FRONTEND=noninteractive
MISSING=()
command -v rsync >/dev/null 2>&1 || MISSING+=(rsync)
python3 - <<'PY' >/dev/null 2>&1 || MISSING+=(python3-pymysql)
import pymysql
PY
if ((${#MISSING[@]})); then
  apt-get update -qq
  apt-get install -y --no-install-recommends "${MISSING[@]}"
fi

say 'Validating panel/runtime files before touching the live installation...'
python3 -m py_compile \
  "$SRC/bin/hyper-cs16-ctl" \
  "$SRC/bin/hyper-cs16-monitor" \
  "$SRC/bin/hyper-cs16-run" \
  "$SRC/bin/hyper-cs16-migrate-v26" \
  "$SRC/lib/csquery.py"
for f in "$SRC/public/index.php" "$SRC/public/api.php" "$SRC/public/public-api.php" "$SRC/app/bootstrap.php"; do
  php -l "$f" >/dev/null || fail "PHP syntax error: $f"
done
if command -v node >/dev/null 2>&1; then node --check "$SRC/public/assets/app.js" >/dev/null; fi

say 'Installing controller, monitor and v2.6 DB migration...'
install -d -m 0755 "$BASE/lib"
install -m 0755 "$SRC/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC/bin/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor
install -m 0755 "$SRC/bin/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0755 "$SRC/bin/hyper-cs16-migrate-v26" /usr/local/sbin/hyper-cs16-migrate-v26
install -m 0644 "$SRC/lib/csquery.py" "$BASE/lib/csquery.py"
install -m 0644 "$SRC/systemd/hyper-cs16-monitor.service" /etc/systemd/system/hyper-cs16-monitor.service
install -m 0644 "$SRC/systemd/hyper-cs16@.service" /etc/systemd/system/hyper-cs16@.service
systemctl daemon-reload

say 'Migrating SQL. Existing servers/users/files are preserved...'
/usr/local/sbin/hyper-cs16-migrate-v26

say 'Applying per-server CPU/RAM limits without restarting HLDS...'
python3 - <<'PY'
import json, subprocess
from pathlib import Path
try:
    import pymysql
except Exception as exc:
    print('[CS16 v2.6] PyMySQL unavailable:',exc); raise SystemExit(0)
p=Path('/etc/hyper-cs16/runtime.json')
if not p.is_file():
    print('[CS16 v2.6] runtime.json missing; skip resource limits'); raise SystemExit(0)
r=json.loads(p.read_text(encoding='utf-8'))
con=pymysql.connect(host=r.get('db_host','127.0.0.1'),port=int(r.get('db_port',3306)),user=r['db_user'],password=r['db_password'],database=r['db_name'],charset='utf8mb4',autocommit=True,cursorclass=pymysql.cursors.DictCursor)
with con.cursor() as cur:
    cur.execute('SELECT id,cpu_limit_percent,memory_limit_mb FROM servers ORDER BY id')
    rows=cur.fetchall()
for row in rows:
    sid=int(row['id']); cpu=float(row.get('cpu_limit_percent') or 0); ram=int(row.get('memory_limit_mb') or 0)
    cp=subprocess.run(['/usr/local/sbin/hyper-cs16-ctl','limits-set',str(sid),'--cpu',str(cpu),'--memory',str(ram)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
    if cp.returncode==0: print(f'[CS16 v2.6] #{sid}: limits CPU={cpu:g}% RAM={ram}MB')
    else: print(f'[CS16 v2.6] #{sid}: limits warning: {(cp.stdout or "").strip()[-500:]}')
con.close()
PY

if [[ -d "$SITE_PUBLIC" ]]; then
  say 'Deploying v2.6 panel UI, REST API and hosting modules...'
  rsync -a --delete "$SRC/public/" "$SITE_PUBLIC/"
  chown -R www-data:www-data "$SITE_PUBLIC" 2>/dev/null || true
  find "$SITE_PUBLIC" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$SITE_PUBLIC" -type f -exec chmod 0644 {} + 2>/dev/null || true
else
  warn "$SITE_PUBLIC does not exist. Web files were not deployed."
fi
if [[ -d "$SITE_APP" ]]; then
  rsync -a --delete "$SRC/app/" "$SITE_APP/"
  chown -R www-data:www-data "$SITE_APP" 2>/dev/null || true
else
  warn "$SITE_APP does not exist. bootstrap.php was not deployed."
fi

say 'Restarting only the monitor; game servers are NOT restarted by this upgrade...'
systemctl enable hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl restart hyper-cs16-monitor.service
systemctl reload nginx >/dev/null 2>&1 || true

say 'Quick health check...'
if ! systemctl is-active --quiet hyper-cs16-monitor.service; then warn 'hyper-cs16-monitor is not active; inspect: journalctl -u hyper-cs16-monitor -n 100'; fi
python3 - <<'PY'
import json
from pathlib import Path
try:
 import pymysql
except Exception: raise SystemExit(0)
p=Path('/etc/hyper-cs16/runtime.json')
if not p.is_file(): raise SystemExit(0)
r=json.loads(p.read_text())
con=pymysql.connect(host=r.get('db_host','127.0.0.1'),port=int(r.get('db_port',3306)),user=r['db_user'],password=r['db_password'],database=r['db_name'],charset='utf8mb4',cursorclass=pymysql.cursors.DictCursor)
with con.cursor() as c:
 c.execute("SELECT setting_value FROM settings WHERE setting_key='panel_version'"); v=c.fetchone()
 c.execute('SELECT COUNT(*) n FROM users'); users=c.fetchone()['n']
 c.execute('SELECT COUNT(*) n FROM servers'); servers=c.fetchone()['n']
 c.execute('SELECT COUNT(*) n FROM plans'); plans=c.fetchone()['n']
print(f"[CS16 v2.6] DB version={(v or {}).get('setting_value','?')} users={users} servers={servers} plans={plans}")
con.close()
PY

echo
say 'DONE. Hosting modules installed: Telegram events, action history, roles, resources, billing/rental, promo codes and REST API.'
say 'Existing HLDS instances were not restarted. Open www.avito.hyper-host.pw and press Ctrl+F5.'
say 'First existing account is Owner if the database had no owner role.'
