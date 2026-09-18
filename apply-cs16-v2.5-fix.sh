#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/cs16-panel"
[[ -f "$SRC/bin/hyper-cs16-ctl" && -f "$SRC/bin/hyper-cs16-monitor" && -f "$SRC/bin/hyper-cs16-run" && -f "$SRC/public/index.php" ]] || {
  echo '[ERROR] Run this script from the patched HYPER-HOST repository root' >&2; exit 2;
}
SITE_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'
SITE_APP='/var/www/hyper-host-sites/www.avito.hyper-host.pw/app'
BASE='/opt/hyper-cs16'

say(){ printf '\033[1;36m[CS16 v2.5]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v2.5 WARNING]\033[0m %s\n' "$*" >&2; }

say 'Validating all changed files before installation...'
python3 -m py_compile "$SRC/bin/hyper-cs16-ctl" "$SRC/bin/hyper-cs16-monitor" "$SRC/bin/hyper-cs16-run" "$SRC/lib/csquery.py"
php -l "$SRC/public/index.php" >/dev/null
php -l "$SRC/public/api.php" >/dev/null
php -l "$SRC/app/bootstrap.php" >/dev/null
if command -v node >/dev/null 2>&1; then node --check "$SRC/public/assets/app.js" >/dev/null; fi

say 'Installing HLDS runtime + AMXX content self-repair + self-healing monitor...'
install -d -m 0755 "$BASE/lib"
install -m 0755 "$SRC/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$SRC/bin/hyper-cs16-monitor" /usr/local/sbin/hyper-cs16-monitor
install -m 0755 "$SRC/bin/hyper-cs16-run" /usr/local/sbin/hyper-cs16-run
install -m 0644 "$SRC/lib/csquery.py" "$BASE/lib/csquery.py"
install -m 0644 "$SRC/systemd/hyper-cs16-monitor.service" /etc/systemd/system/hyper-cs16-monitor.service
install -m 0644 "$SRC/systemd/hyper-cs16@.service" /etc/systemd/system/hyper-cs16@.service
systemctl daemon-reload

if [[ -d "$SITE_PUBLIC" ]]; then
  say 'Updating web panel UI/API...'
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

say 'Restarting statistics/self-healing monitor...'
systemctl enable hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl restart hyper-cs16-monitor.service

say 'Migrating existing servers from hlds_run wrapper to the real hlds_linux MainPID...'
SERVER_IDS="$(python3 - <<'PY'
import json
from pathlib import Path
ids=[]
for p in sorted(Path('/var/lib/hyper-cs16/servers').glob('*.json')):
    try:
        d=json.loads(p.read_text()); sid=int(d.get('id',p.stem));
        if sid>0: ids.append(sid)
    except Exception: pass
print(' '.join(map(str,sorted(set(ids)))))
PY
)"

FAIL=0
if [[ -z "$SERVER_IDS" ]]; then
  warn 'No existing CS server state files found.'
else
  for SID in $SERVER_IDS; do
    say "Server #$SID: repair malformed AMXX lists/resources, then verified restart"
    TMP="$(mktemp)"
    if timeout 60 /usr/local/sbin/hyper-cs16-ctl repair-content "$SID" >"$TMP" 2>&1; then
      cat "$TMP"
    else
      warn "Server #$SID content pre-repair reported a warning"
      cat "$TMP" >&2 || true
    fi
    if timeout 180 /usr/local/sbin/hyper-cs16-ctl restart "$SID" >"$TMP" 2>&1; then
      cat "$TMP"
    else
      warn "Server #$SID restart did not pass health check; running explicit recovery"
      cat "$TMP" >&2 || true
      if timeout 150 /usr/local/sbin/hyper-cs16-ctl recover "$SID" >"$TMP" 2>&1; then
        cat "$TMP"
      else
        FAIL=1; cat "$TMP" >&2 || true
      fi
    fi
    rm -f "$TMP"
  done
fi

say 'Refreshing SQL status cache from the real engine + UDP socket...'
python3 - <<'PY'
import json,subprocess
from pathlib import Path
try: import pymysql
except Exception as exc:
    print('[CS16 v2.5] PyMySQL unavailable:',exc); raise SystemExit(0)
rtp=Path('/etc/hyper-cs16/runtime.json')
if not rtp.is_file(): raise SystemExit(0)
rt=json.loads(rtp.read_text())
con=pymysql.connect(host=rt.get('db_host','127.0.0.1'),port=int(rt.get('db_port',3306)),user=rt['db_user'],password=rt['db_password'],database=rt['db_name'],charset='utf8mb4',autocommit=True,cursorclass=pymysql.cursors.DictCursor)
with con.cursor() as cur:
    cur.execute('SELECT id FROM servers WHERE enabled=1 ORDER BY id'); ids=[int(r['id']) for r in cur.fetchall()]
for sid in ids:
    try:
        cp=subprocess.run(['/usr/local/sbin/hyper-cs16-ctl','status',str(sid)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
        data=json.loads((cp.stdout or '').strip().splitlines()[-1])
        running=bool(data.get('running')); udp=bool(data.get('udp_listening'))
        state='online' if running and udp else ('starting' if running else ('offline' if data.get('service')=='inactive' else 'failed'))
        q=data.get('query') or {}; current=str(q.get('map') or data.get('start_map') or '')
        with con.cursor() as cur:
            cur.execute('UPDATE servers SET status_cache=%s,current_map=%s WHERE id=%s',(state,current,sid))
        print(f'[CS16 v2.5] #{sid}: {state} real_pid={data.get("pid",0)} UDP={udp} A2S={data.get("query_state","-")}')
    except Exception as exc:
        print(f'[CS16 v2.5] #{sid}: status refresh warning: {exc}')
with con.cursor() as cur:
    cur.execute("INSERT INTO settings(setting_key,setting_value) VALUES('panel_version','2.5.0') ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)")
con.close()
PY

systemctl reload nginx >/dev/null 2>&1 || true
sleep 2
say 'Current real HLDS processes:'
ps -eo pid,user,comm,args | grep '[h]lds_linux' || warn 'No hlds_linux processes are running.'
say 'Current game UDP sockets:'
ss -lunp 2>/dev/null | grep -E ':(270[1-9][0-9]|27100)\b' || warn 'No CS UDP sockets are listening.'

echo
if [[ "$FAIL" -eq 0 ]]; then
  say 'DONE. Existing servers were repaired, migrated and health-checked.'
else
  warn 'Patch installed, but at least one server still has a core HLDS failure. The panel now shows the real failure and keeps the journal instead of fake Process ON.'
fi
say 'The panel now repairs malformed AMXX lists, quarantines crash-causing custom plugins/resources, and keeps hlds_linux/UDP as the health source.'
say 'Open www.avito.hyper-host.pw and press Ctrl+F5 once.'
