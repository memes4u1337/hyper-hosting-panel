#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ "$SID" =~ ^[0-9]+$ ]] || { echo "[ERROR] bad server id"; exit 1; }

SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"
SRC_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
SRC_NGINX="$REPO/scripts/nginx_recover_v89.py"
LIVE_NGINX="/opt/hyper-host/nginx_recover_v89.py"
RECONCILE="/usr/local/sbin/hyper-host-nginx-reconcile"
META="$CSTRIKE/addons/metamod/plugins.ini"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-permanent-v37-1-$SID-$STAMP"
mkdir -p "$BACKUP"

echo "================================================================"
echo " OLD ZOMBIE / HYPER-HOST PERMANENT FIX v37.1"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo "================================================================"

backup(){ local f="$1"; [[ -e "$f" ]] || return 0; local rel="${f#/}"; mkdir -p "$BACKUP/$(dirname "$rel")"; cp -a "$f" "$BACKUP/$rel"; }

for f in "$SRC_CTL" "$LIVE_CTL" "$SRC_NGINX" "$LIVE_NGINX" "$META" /etc/nginx/hyper-host-managed/00-default.conf; do backup "$f"; done

echo "[1/8] Patch nginx generator"
patch_nginx(){
  local F="$1"
  [[ -f "$F" ]] || { echo "[SKIP] $F"; return 0; }
  python3 - "$F" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8',errors='strict')
marker='HYPER-CS16 FASTDL PERMANENT V37'
if marker not in s:
    anchor='def default_block(root: str, cert: str, key: str) -> str:'
    if anchor not in s:
        raise SystemExit(f'default_block not found: {p}')
    helper="""
def cs16_fastdl_v37() -> str:
    return r'''\n    # HYPER-CS16 FASTDL PERMANENT V37\n\n    location ~* ^/fastdl/[0-9]+/.+\\.(?:bsp|res|wad|mdl|spr|wav|mp3|tga|bmp|pcx|nav|txt|ztmp)(?:\\.bz2)?$ {\n        root /srv/hyper-cs16;\n        try_files $uri =404;\n        types { }\n        default_type application/octet-stream;\n        sendfile on;\n        tcp_nopush on;\n        gzip off;\n        autoindex off;\n        add_header X-Hyper-FastDL "permanent-v37" always;\n        add_header X-Content-Type-Options "nosniff" always;\n        add_header Cache-Control "no-cache, no-store, must-revalidate" always;\n    }\n\n    location /fastdl/ {\n        default_type text/plain;\n        add_header X-Hyper-FastDL "permanent-v37-reject" always;\n        add_header X-Content-Type-Options "nosniff" always;\n        return 404 "FastDL resource not found\\n";\n    }\n'''\n\n"""
    s=s.replace(anchor,helper+anchor,1)
    old='    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "DEFAULT_V89"; }}\n    location / {{ try_files $uri /index.html =404; }}'
    new='    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "DEFAULT_V89"; }}\n{cs16_fastdl_v37()}    location / {{ try_files $uri /index.html =404; }}'
    count=s.count(old)
    if count != 2:
        raise SystemExit(f'expected 2 default blocks, got {count}: {p}')
    s=s.replace(old,new)
p.write_text(s,encoding='utf-8')
print('[OK]',p)
PY
  python3 -m py_compile "$F"
}
patch_nginx "$SRC_NGINX"
patch_nginx "$LIVE_NGINX"

echo "[2/8] Patch hyper-cs16-ctl"
patch_ctl(){
  local F="$1"
  [[ -f "$F" ]] || { echo "[SKIP] $F"; return 0; }
  python3 - "$F" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8',errors='strict')
s=s.replace("return f'http://{public}/fastdl/{sid}'","return f'http://{public}/fastdl/{sid}/'")
s=s.replace("return f'https://{FASTDL_DOMAIN}/fastdl/{sid}'","return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'")
start=s.find('def _disable_yapb_for_recovery(c:dict):')
end=s.find('\ndef _disable_zp_for_recovery(c:dict):',start)
if start == -1 or end == -1:
    print(f'[SKIP] YaPB recovery function not present in {p}')
else:
    replacement='''def _disable_yapb_for_recovery(c:dict):\n    # HYPER-HOST v37.1: automatic recovery must not disable YaPB.\n    return False\n'''
    s=s[:start]+replacement+s[end+1:]
    print(f'[OK] removed YaPB auto-disable from {p}')
p.write_text(s,encoding='utf-8')
print('[OK]',p)
PY
  python3 -m py_compile "$F"
}
patch_ctl "$SRC_CTL"
patch_ctl "$LIVE_CTL"
chmod 0755 "$LIVE_CTL" 2>/dev/null || true

echo "[3/8] Restore YaPB if HYPER-HOST recovery disabled it"
if [[ -f "$META" ]] && grep -qi 'HYPER-HOST auto-recovery:.*addons/yapb/bin/yapb.so' "$META"; then
  sed -i -E 's#^[[:space:]]*;[[:space:]]*HYPER-HOST auto-recovery:[[:space:]]*(linux[[:space:]]+addons/yapb/bin/yapb\.so)[[:space:]]*$#\1#I' "$META"
  echo "[OK] YaPB restored"
else
  echo "[OK] no YaPB auto-recovery marker"
fi

echo "[4/8] Rebuild nginx from fixed generator"
[[ -x "$RECONCILE" ]] || { echo "[ERROR] $RECONCILE not found"; exit 10; }
"$RECONCILE"
nginx -t

echo "[5/8] Install permanent guard"
cat > /usr/local/sbin/hyper-cs16-fastdl-guard <<'EOF'
#!/usr/bin/env bash
set -u
SID="${1:-25}"
CTL=/usr/local/sbin/hyper-cs16-ctl
CONF=/etc/nginx/hyper-host-managed/00-default.conf
META="/srv/hyper-cs16/servers/$SID/cstrike/addons/metamod/plugins.ini"
CFG="/srv/hyper-cs16/servers/$SID/cstrike/server.cfg"
RECON=/usr/local/sbin/hyper-host-nginx-reconcile
LOCK="/run/hyper-cs16-fastdl-guard-$SID.lock"
exec 9>"$LOCK"; flock -n 9 || exit 0
if [[ -f "$META" ]] && grep -qi 'HYPER-HOST auto-recovery:.*addons/yapb/bin/yapb.so' "$META"; then
  sed -i -E 's#^[[:space:]]*;[[:space:]]*HYPER-HOST auto-recovery:[[:space:]]*(linux[[:space:]]+addons/yapb/bin/yapb\.so)[[:space:]]*$#\1#I' "$META"
  systemctl restart "hyper-cs16@$SID.service" >/dev/null 2>&1 || true
fi
if [[ ! -f "$CONF" ]] || ! grep -q 'HYPER-CS16 FASTDL PERMANENT V37' "$CONF"; then
  [[ -x "$RECON" ]] && "$RECON" >/dev/null 2>&1 || true
fi
if [[ ! -f "$CFG" ]] || ! grep -qE "^[[:space:]]*sv_downloadurl[[:space:]]+\"?[^\"]*/fastdl/$SID/\"?" "$CFG"; then
  "$CTL" fastdl-sync "$SID" >/dev/null 2>&1 || true
fi
CODE="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1/fastdl/$SID/__guard__.mdl" 2>/dev/null || true)"
if [[ "$CODE" != 404 ]]; then
  [[ -x "$RECON" ]] && "$RECON" >/dev/null 2>&1 || true
fi
EOF
chmod 0755 /usr/local/sbin/hyper-cs16-fastdl-guard

cat > /etc/systemd/system/hyper-cs16-fastdl-guard@.service <<'EOF'
[Unit]
Description=HYPER-HOST CS16 FastDL/YaPB guard #%i
After=nginx.service network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hyper-cs16-fastdl-guard %i
EOF

cat > /etc/systemd/system/hyper-cs16-fastdl-guard@.timer <<'EOF'
[Unit]
Description=HYPER-HOST CS16 FastDL guard timer #%i
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true
[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/hyper-cs16-fastdl-guard@.path <<'EOF'
[Unit]
Description=Watch HYPER-HOST nginx config for CS16 FastDL #%i
[Path]
PathChanged=/etc/nginx/hyper-host-managed/00-default.conf
Unit=hyper-cs16-fastdl-guard@%i.service
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "hyper-cs16-fastdl-guard@$SID.timer"
systemctl enable --now "hyper-cs16-fastdl-guard@$SID.path"

echo "[6/8] FastDL sync"
"$LIVE_CTL" fastdl-sync "$SID"

echo "[7/8] Restart server"
systemctl restart "hyper-cs16@$SID.service"
sleep 6
/usr/local/sbin/hyper-cs16-fastdl-guard "$SID" || true

echo "[8/8] Final checks"
CODE="$(curl -sS -o /tmp/v37-1-body -D /tmp/v37-1-hdr -w '%{http_code}' "http://127.0.0.1/fastdl/$SID/__missing_v37_1__.mdl")"
echo "Missing HTTP=$CODE"
grep -iE '^(HTTP/|Content-Type:|X-Hyper-FastDL:)' /tmp/v37-1-hdr || true
[[ "$CODE" == 404 ]] || { echo "[ERROR] FastDL missing file is not 404"; exit 20; }

for REL in \
  maps/zm_ice_attack.bsp \
  maps/zm_ice_attack_hd.bsp \
  models/player/oldz_delux_r1/oldz_delux_r1.mdl
do
  FILE="/srv/hyper-cs16/fastdl/$SID/$REL"
  [[ -f "$FILE" ]] || { echo "[MISSING] $REL"; continue; }
  curl -sS -o /tmp/v37-1-asset "http://127.0.0.1/fastdl/$SID/$REL"
  D="$(sha256sum "$FILE" | awk '{print $1}')"
  H="$(sha256sum /tmp/v37-1-asset | awk '{print $1}')"
  [[ "$D" == "$H" ]] || { echo "[ERROR HASH] $REL"; exit 21; }
  echo "[200 BINARY HASH OK] $REL"
done

echo "=== SV_DOWNLOADURL ==="
"$LIVE_CTL" rcon "$SID" 'sv_downloadurl' || true

echo "=== METAMOD ==="
"$LIVE_CTL" rcon "$SID" 'meta list' || true

echo "=== PLAYERS ==="
"$LIVE_CTL" rcon "$SID" 'status' || true

echo "=== GUARD ==="
systemctl is-active "hyper-cs16-fastdl-guard@$SID.timer" || true
systemctl is-active "hyper-cs16-fastdl-guard@$SID.path" || true

echo "================================================================"
echo " SUCCESS - PERMANENT FIX v37.1"
echo "================================================================"
echo "Backup: $BACKUP"
