#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" && -f "$ROOT_DIR/cs16-panel/public/index.php" && -f "$ROOT_DIR/scripts/hhctl" && -f "$ROOT_DIR/scripts/proftpd_auth_sync.py" ]] || { echo '[ERROR] Run this script from the patched HYPER-HOST repository root' >&2; exit 2; }

say(){ printf '\033[1;36m[CS16 v1.8]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v1.8 WARNING]\033[0m %s\n' "$*" >&2; }

say 'Installing dependencies for state recovery and optional UPnP...'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y python3-pymysql miniupnpc xz-utils curl unzip >/dev/null || true

say 'Installing fixed CS16 controller, FTP runtime and web panel...'
install -m 0755 "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
install -m 0755 "$ROOT_DIR/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install -d -m 0755 /opt/hyper-host/bin
install -m 0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" /opt/hyper-host/bin/proftpd_auth_sync.py
if [[ -d /var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html ]]; then
  rsync -a --delete "$ROOT_DIR/cs16-panel/public/" /var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/
  chown -R www-data:www-data /var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html 2>/dev/null || true
fi

say 'Migrating SQL schema...'
python3 - <<'PY'
import json, pymysql
from pathlib import Path
rt=json.loads(Path('/etc/hyper-cs16/runtime.json').read_text())
con=pymysql.connect(host=rt.get('db_host','127.0.0.1'),port=int(rt.get('db_port',3306)),user=rt['db_user'],password=rt['db_password'],database=rt['db_name'],charset='utf8mb4',autocommit=True)
cols={
 'game_mode':"VARCHAR(32) NOT NULL DEFAULT 'classic'",
 'bots_enabled':'TINYINT(1) NOT NULL DEFAULT 0',
 'bots_quota':'TINYINT UNSIGNED NOT NULL DEFAULT 9',
 'bots_difficulty':'TINYINT UNSIGNED NOT NULL DEFAULT 3',
}
with con.cursor() as cur:
    cur.execute("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=%s AND TABLE_NAME='servers'",(rt['db_name'],))
    have={r[0] for r in cur.fetchall()}
    for name,definition in cols.items():
        if name not in have:
            cur.execute(f'ALTER TABLE servers ADD COLUMN `{name}` {definition}')
con.close()
PY

say 'Fixing mutable state permissions...'
install -d -m 0750 -o root -g cs16 /var/lib/hyper-cs16 /var/lib/hyper-cs16/servers /var/lib/hyper-cs16/uploads
find /var/lib/hyper-cs16/servers -maxdepth 1 -type f -name '*.json' -exec chown root:cs16 {} + -exec chmod 0640 {} + 2>/dev/null || true

say 'Recovering missing JSON state from SQL/server.cfg and repairing FTP credentials...'
mapfile -t IDS < <(python3 - <<'PY'
import json,pymysql
from pathlib import Path
rt=json.loads(Path('/etc/hyper-cs16/runtime.json').read_text())
con=pymysql.connect(host=rt.get('db_host','127.0.0.1'),port=int(rt.get('db_port',3306)),user=rt['db_user'],password=rt['db_password'],database=rt['db_name'],autocommit=True)
with con.cursor() as cur:
    cur.execute('SELECT id FROM servers ORDER BY id')
    for (sid,) in cur.fetchall(): print(int(sid))
con.close()
PY
)

failed=0
for sid in "${IDS[@]:-}"; do
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  say "Server #$sid: recover/status"
  /usr/local/sbin/hyper-cs16-ctl status "$sid" >/tmp/hhcs16-status-$sid.json 2>/tmp/hhcs16-status-$sid.err || { warn "state recover failed for #$sid: $(cat /tmp/hhcs16-status-$sid.err)"; failed=1; }
  if [[ -d "/srv/hyper-cs16/servers/$sid" ]]; then
    say "Server #$sid: FTP direct-root repair + SQL credential sync"
    /usr/local/sbin/hyper-cs16-ctl ftp-repair "$sid" || { warn "FTP repair failed for #$sid"; failed=1; }
    /usr/local/sbin/hyper-cs16-ctl ftp-test "$sid" || { warn "FTP self-test failed for #$sid"; failed=1; }
  fi
  say "Server #$sid: local game network check"
  /usr/local/sbin/hyper-cs16-ctl network "$sid" || { warn "Local HLDS/UDP/A2S check failed for #$sid"; failed=1; }
  if command -v upnpc >/dev/null 2>&1; then
    say "Server #$sid: trying router UPnP UDP mapping (non-fatal)"
    /usr/local/sbin/hyper-cs16-ctl nat-upnp "$sid" || warn "UPnP not available/enabled. Use the exact manual UDP rule shown in the panel."
  fi
done

say 'Opening Ubuntu firewall...'
if command -v ufw >/dev/null 2>&1; then
  ufw allow 27015:27100/udp >/dev/null 2>&1 || true
  ufw allow 21/tcp >/dev/null 2>&1 || true
  ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
fi

systemctl reload proftpd >/dev/null 2>&1 || systemctl restart proftpd >/dev/null 2>&1 || true
systemctl reload nginx >/dev/null 2>&1 || true

LAN_IP="$(python3 - <<'PY'
import json
print(json.load(open('/etc/hyper-cs16/runtime.json')).get('lan_ip',''))
PY
)"
PUBLIC_IP="$(python3 - <<'PY'
import json
print(json.load(open('/etc/hyper-cs16/runtime.json')).get('public_ip',''))
PY
)"

echo
say 'IMPORTANT: your Keenetic game rule must use UDP and the SAME external/internal port.'
for sid in "${IDS[@]:-}"; do
  [[ -f "/var/lib/hyper-cs16/servers/$sid.json" ]] || continue
  port="$(python3 - "$sid" <<'PY'
import json,sys
p=f'/var/lib/hyper-cs16/servers/{int(sys.argv[1])}.json'
print(json.load(open(p)).get('port',''))
PY
)"
  [[ -n "$port" ]] && echo "  Server #$sid: UDP $port -> ${LAN_IP:-LAN_IP}:$port   | Internet: ${PUBLIC_IP:-PUBLIC_IP}:$port"
done

echo 'FTP router rules: TCP 21 -> 21 and TCP 40000-40100 -> 40000-40100 to the same LAN IP.'
echo 'Panel: http://www.avito.hyper-host.pw'
if ((failed)); then
  warn 'Patch installed, but one or more local self-tests failed. See messages above.'
  exit 2
fi
say 'DONE: delete fallback, FTP credentials, exact NAT guidance, YaPB/ZP43 installers and UPnP helper are installed.'
