#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" && -f "$ROOT_DIR/cs16-panel/public/index.php" ]] || { echo '[ERROR] Run this script from the patched HYPER-HOST repository root' >&2; exit 2; }

say(){ printf '\033[1;36m[CS16 v2.1]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v2.1 WARNING]\033[0m %s\n' "$*" >&2; }

SITE_PUBLIC='/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html'
PANEL_CFG='/etc/hyper-cs16/panel.php'
RUNTIME_CFG='/etc/hyper-cs16/runtime.json'

LAN_IP="${CS16_LAN_IP:-}"
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [[ -z "$LAN_IP" ]]; then
  warn 'Could not auto-detect LAN IPv4. Existing panel LAN IP will be preserved.'
else
  say "Primary server/LAN IP: $LAN_IP"
fi

say 'Installing updated CS 1.6 controller...'
install -m 0755 "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl" /usr/local/sbin/hyper-cs16-ctl

if [[ -n "$LAN_IP" && -f "$RUNTIME_CFG" ]]; then
  say 'Synchronizing LAN IP in runtime.json...'
  python3 - "$RUNTIME_CFG" "$LAN_IP" <<'PY'
import json,sys,os,tempfile
path,lan=sys.argv[1:]
with open(path,'r',encoding='utf-8') as f: data=json.load(f)
data['lan_ip']=lan
fd,tmp=tempfile.mkstemp(prefix='.runtime.',dir=os.path.dirname(path),text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(data,f,ensure_ascii=False,indent=2); f.write('\n')
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
  chown root:root "$RUNTIME_CFG" || true
  chmod 0600 "$RUNTIME_CFG" || true
fi

if [[ -n "$LAN_IP" && -f "$PANEL_CFG" ]]; then
  say 'Synchronizing LAN IP in panel.php...'
  php -r '$f=$argv[1];$lan=$argv[2];$c=require $f;$c["lan_ip"]=$lan;$out="<?php\nreturn ".var_export($c,true).";\n";if(file_put_contents($f,$out)===false){fwrite(STDERR,"cannot write panel.php\n");exit(1);}' "$PANEL_CFG" "$LAN_IP"
  chown root:www-data "$PANEL_CFG" || true
  chmod 0640 "$PANEL_CFG" || true
fi

if [[ -d "$SITE_PUBLIC" ]]; then
  say 'Updating CS 1.6 web panel UI...'
  rsync -a "$ROOT_DIR/cs16-panel/public/" "$SITE_PUBLIC/"
  chown -R www-data:www-data "$SITE_PUBLIC" 2>/dev/null || true
  find "$SITE_PUBLIC" -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$SITE_PUBLIC" -type f -exec chmod 0644 {} + 2>/dev/null || true
else
  warn "$SITE_PUBLIC does not exist. Run install-cs16-panel.sh first."
fi

say 'Validating controller and web files...'
python3 -m py_compile "$ROOT_DIR/cs16-panel/bin/hyper-cs16-ctl"
php -l "$ROOT_DIR/cs16-panel/public/index.php" >/dev/null
php -l "$ROOT_DIR/cs16-panel/public/api.php" >/dev/null
if command -v node >/dev/null 2>&1; then node --check "$ROOT_DIR/cs16-panel/public/assets/app.js" >/dev/null; fi

if /usr/local/sbin/hyper-cs16-ctl base-maps >/tmp/hyper-cs16-base-maps-v21.json 2>/dev/null; then
  MAP_COUNT="$(python3 - <<'PY'
import json
try:
 d=json.load(open('/tmp/hyper-cs16-base-maps-v21.json')); print(len(d.get('maps',[])))
except Exception: print(0)
PY
)"
  say "Base map selector ready: $MAP_COUNT maps"
else
  warn 'Could not read base maps right now; existing server map selectors will still work.'
fi
rm -f /tmp/hyper-cs16-base-maps-v21.json

systemctl reload nginx >/dev/null 2>&1 || true

say 'DONE. HLDS processes were not restarted.'
if [[ -n "$LAN_IP" ]]; then
  say "Main IP shown in panel: $LAN_IP"
fi
say 'Maps: selectors use actual installed .bsp files.'
say 'AMXX admins: player list now supports add/edit/delete admins, passwords, access presets and live amx_reloadadmins.'
