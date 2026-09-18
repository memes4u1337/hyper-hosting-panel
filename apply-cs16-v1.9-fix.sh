#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" && -f "$ROOT_DIR/cs16-panel/public/index.php" ]] || { echo '[ERROR] Run this script from the patched HYPER-HOST repository root' >&2; exit 2; }

say(){ printf '\033[1;36m[CS16 v1.9]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v1.9 WARNING]\033[0m %s\n' "$*" >&2; }

say 'Installing network repair dependencies...'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y miniupnpc iptables ufw python3-pymysql >/dev/null || true

say 'Installing fixed controller and web panel...'
install -m 0755 "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl
if [[ -d /var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html ]]; then
  rsync -a --delete "$ROOT_DIR/cs16-panel/public/" /var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/
  chown -R www-data:www-data /var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html 2>/dev/null || true
fi

say 'Opening CS 1.6 UDP range on Ubuntu...'
if command -v ufw >/dev/null 2>&1; then
  ufw allow 27015:27100/udp >/dev/null 2>&1 || true
fi

mapfile -t IDS < <(python3 - <<'PY'
import json,pymysql
from pathlib import Path
rt=json.loads(Path('/etc/hyper-cs16/runtime.json').read_text())
con=pymysql.connect(host=rt.get('db_host','127.0.0.1'),port=int(rt.get('db_port',3306)),user=rt['db_user'],password=rt['db_password'],database=rt['db_name'],charset='utf8mb4',autocommit=True)
with con.cursor() as cur:
    cur.execute('SELECT id FROM servers WHERE installed=1 ORDER BY id')
    for (sid,) in cur.fetchall(): print(int(sid))
con.close()
PY
)

failed=0
for sid in "${IDS[@]:-}"; do
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  say "Server #$sid: repairing host firewall, sv_lan, HLDS and Keenetic UPnP..."
  if ! /usr/local/sbin/hyper-cs16-ctl network-fix "$sid"; then
    warn "Automatic network repair was not fully successful for server #$sid"
    failed=1
  fi
done

systemctl reload nginx >/dev/null 2>&1 || true

echo
say 'Current CS UDP sockets:'
ss -lunp | grep -E ':(2701[5-9]|270[2-9][0-9]|27100)\b' || true

echo
say 'DONE. In the panel open the server and click "Исправить подключение автоматически" if you change the port later.'
if ((failed)); then
  warn 'HLDS can still be healthy even if UPnP is unavailable. If router_external_ip differs from public_ip, the problem is double NAT/CGNAT and cannot be fixed inside Ubuntu.'
fi
