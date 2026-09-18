#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel"
[[ -f "$SRC/bin/hyper-cs16-ctl" && -f "$SRC/bin/hyper-cs16-monitor" && -f "$SRC/lib/csquery.py" && -f "$SRC/public/index.php" ]] || {
  echo '[ERROR] Run this script from the patched HYPER-HOST repository root' >&2; exit 2;
}
SITE_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'
SITE_APP='/var/www/hyper-host-sites/www.avito.hyper-host.pw/app'
BASE='/opt/hyper-cs16'

say(){ printf '\033[1;36m[CS16 v2.3]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v2.3 WARNING]\033[0m %s\n' "$*" >&2; }

say 'Validating patch before touching the server...'
python3 -m py_compile "$SRC/bin/hyper-cs16-ctl" "$SRC/bin/hyper-cs16-monitor" "$SRC/bin/hyper-cs16-run" "$SRC/lib/csquery.py"
php -l "$SRC/public/index.php" >/dev/null
php -l "$SRC/public/api.php" >/dev/null
php -l "$SRC/app/bootstrap.php" >/dev/null
if command -v node >/dev/null 2>&1; then node --check "$SRC/public/assets/app.js" >/dev/null; fi

say 'Installing resilient HLDS health/query runtime...'
install -d -m 0755 "$BASE/lib"
install -m 0755 "$SRC/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC/bin/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor
install -m 0755 "$SRC/bin/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0644 "$SRC/lib/csquery.py" "$BASE/lib/csquery.py"
install -m 0644 "$SRC/systemd/hyper-cs16-monitor.service" /etc/systemd/system/hyper-cs16-monitor.service
install -m 0644 "$SRC/systemd/hyper-cs16@.service" /etc/systemd/system/hyper-cs16@.service
systemctl daemon-reload

if [[ -d "$SITE_PUBLIC" ]]; then
  say 'Updating the web panel UI/API...'
  rsync -a --delete "$SRC/public/" "$SITE_PUBLIC/"
  chown -R www-data:www-data "$SITE_PUBLIC" 2>/dev/null || true
  find "$SITE_PUBLIC" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$SITE_PUBLIC" -type f -exec chmod 0644 {} + 2>/dev/null || true
else
  warn "$SITE_PUBLIC does not exist. Run install-cs16-panel.sh once."
fi
if [[ -d "$SITE_APP" ]]; then
  rsync -a --delete "$SRC/app/" "$SITE_APP/"
  chown -R www-data:www-data "$SITE_APP" 2>/dev/null || true
fi

say 'Restarting only the statistics monitor (game servers are NOT restarted)...'
systemctl enable hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl restart hyper-cs16-monitor.service

say 'Clearing stale NO QUERY states using process + UDP as the authoritative health signal...'
python3 - <<'PY'
import json,subprocess,time
from pathlib import Path
try:
    import pymysql
except Exception as exc:
    print('[CS16 v2.3] PyMySQL unavailable:',exc); raise SystemExit(0)
rtp=Path('/etc/hyper-cs16/runtime.json')
if not rtp.is_file(): raise SystemExit(0)
rt=json.loads(rtp.read_text())
con=pymysql.connect(host=rt.get('db_host','127.0.0.1'),port=int(rt.get('db_port',3306)),user=rt['db_user'],password=rt['db_password'],database=rt['db_name'],charset='utf8mb4',autocommit=True,cursorclass=pymysql.cursors.DictCursor)
with con.cursor() as cur:
    cur.execute('SELECT id FROM servers WHERE enabled=1 ORDER BY id')
    ids=[int(r['id']) for r in cur.fetchall()]
for sid in ids:
    try:
        cp=subprocess.run(['/usr/local/sbin/hyper-cs16-ctl','status',str(sid)],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
        data=json.loads((cp.stdout or '').strip().splitlines()[-1]) if (cp.stdout or '').strip() else {}
        running=bool(data.get('running')); udp=bool(data.get('udp_listening'))
        state='online' if running and udp else ('starting' if running else 'offline')
        q=data.get('query') or {}; current=str(q.get('map') or '')
        with con.cursor() as cur:
            if current:
                cur.execute('UPDATE servers SET status_cache=%s,current_map=%s WHERE id=%s',(state,current,sid))
            else:
                cur.execute('UPDATE servers SET status_cache=%s WHERE id=%s',(state,sid))
        print(f'[CS16 v2.3] server #{sid}: {state}, UDP={udp}, A2S={data.get("query_state","-")}')
    except Exception as exc:
        print(f'[CS16 v2.3] server #{sid}: health refresh warning: {exc}')
with con.cursor() as cur:
    cur.execute("INSERT INTO settings(setting_key,setting_value) VALUES('panel_version','2.3.0') ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)")
con.close()
PY

# Let the freshly restarted monitor finish its first pass.
sleep 2
systemctl reload nginx >/dev/null 2>&1 || true

say 'Current game sockets:'
ss -lunp 2>/dev/null | grep -E ':(270[1-9][0-9]|27100)\b' || warn 'No CS UDP sockets found right now.'

echo
say 'DONE.'
say 'False NO QUERY states are removed: one dropped A2S packet no longer marks a live server offline.'
say 'Map changes now verify via RCON first and no longer restart a healthy server just because A2S is temporarily rate-limited.'
say 'Open the panel and press Ctrl+F5 once to load the new UI.'
