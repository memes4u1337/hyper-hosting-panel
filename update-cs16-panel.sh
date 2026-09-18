#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run as root/sudo" >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CS16_SKIP_GAME_DOWNLOAD=1
export CS16_CREATE_DEFAULT=0
echo "[CS16 FIX] Updating panel/runtime without touching existing game data..."
bash "$ROOT_DIR/install-cs16-panel.sh"

echo "[CS16 FIX] Restoring FTP runtime mounts (no /etc/fstab writes)..."
/usr/local/sbin/hyper-cs16-ctl ftp-restore || true

echo "[CS16 FIX] Installing/repairing HLDS base via SteamCMD..."
/usr/local/sbin/hyper-cs16-ctl base-install

echo "[CS16 FIX] Repairing incomplete DB servers, if any..."
python3 - <<'PYREPAIR'
import json,subprocess,sys
from pathlib import Path
try:
    import pymysql
except Exception:
    print('[CS16 FIX] python3-pymysql missing; skipping DB recovery'); raise SystemExit(0)
rt=json.loads(Path('/etc/hyper-cs16/runtime.json').read_text())
con=pymysql.connect(host=rt.get('db_host','127.0.0.1'),port=int(rt.get('db_port',3306)),user=rt['db_user'],password=rt['db_password'],database=rt['db_name'],charset='utf8mb4',cursorclass=pymysql.cursors.DictCursor,autocommit=True)
with con.cursor() as cur:
    cur.execute("SELECT * FROM servers ORDER BY id")
    all_rows=cur.fetchall()
    if not all_rows:
        public_ip=str(rt.get('public_ip',''))
        cur.execute("INSERT INTO servers(name,hostname,public_ip,port,slots,start_map,build_profile,status_cache,installed) VALUES(%s,%s,%s,27015,16,'de_dust2','classic','installing',0)",('HYPER-HOST CS 1.6','HYPER-HOST | Counter-Strike 1.6',public_ip))
        cur.execute("SELECT * FROM servers WHERE id=LAST_INSERT_ID()")
        all_rows=[cur.fetchone()]
        print('[CS16 FIX] No game servers found; created default DB entry for UDP 27015')
rows=[]
for r in all_rows:
    cfg=Path(f'/var/lib/hyper-cs16/servers/{int(r["id"])}.json')
    if not cfg.exists():
        legacy=Path(f'/etc/hyper-cs16/servers/{int(r["id"])}.json')
        if legacy.exists(): cfg=legacy
    if int(r.get('installed') or 0)==0 or str(r.get('status_cache') or '') in ('failed','installing') or not cfg.exists():
        rows.append(r)
for r in rows:
    sid=int(r['id']); cfg=Path(f'/var/lib/hyper-cs16/servers/{sid}.json')
    if not cfg.exists():
        legacy=Path(f'/etc/hyper-cs16/servers/{sid}.json')
        if legacy.exists(): cfg=legacy
    if cfg.exists():
        subprocess.run(['systemctl','enable','--now',f'hyper-cs16@{sid}.service'],check=False)
        with con.cursor() as cur: cur.execute("UPDATE servers SET installed=1,status_cache='starting' WHERE id=%s",(sid,))
        continue
    cmd=['/usr/local/sbin/hyper-cs16-ctl','server-create',str(sid),'--name',str(r['name']),'--port',str(r['port']),'--slots',str(min(32,max(1,int(r['slots'])))),'--map',str(r['start_map']),'--hostname',str(r['hostname']),'--profile',str(r.get('build_profile') or 'classic')]
    cp=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if cp.returncode!=0:
        print(f'[CS16 FIX] server {sid} recovery failed: {cp.stdout[-2000:]}'); continue
    try: data=json.loads(cp.stdout.strip().splitlines()[-1])
    except Exception: data={}
    with con.cursor() as cur:
        cur.execute("UPDATE servers SET installed=1,status_cache='starting',ftp_user=%s,ftp_password=%s WHERE id=%s",(data.get('ftp_user',''),data.get('ftp_password',''),sid))
    print(f'[CS16 FIX] server {sid} recovered')
con.close()
PYREPAIR

echo "[CS16 FIX] Restarting monitoring and verifying services..."
systemctl daemon-reload
systemctl enable --now hyper-cs16-monitor.service >/dev/null 2>&1 || true
systemctl enable hyper-cs16-ftp-restore.service >/dev/null 2>&1 || true
/usr/local/sbin/hyper-cs16-ctl ftp-restore || true
/usr/local/sbin/hyper-cs16-ctl doctor || true
echo "[CS16 FIX] Done. Existing CS 1.6 servers were kept."
