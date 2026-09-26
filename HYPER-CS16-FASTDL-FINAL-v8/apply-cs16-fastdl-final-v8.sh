#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
LIBEXEC="/usr/local/libexec"
CORE="$LIBEXEC/hyper-cs16-ctl-core-v8"
HELPER="$LIBEXEC/hyper-cs16-fastdl-v8"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-final-v8-${STAMP}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] run as root'; exit 1; }
[[ -f "$SRC_CTL" ]] || { echo "[ERROR] missing $SRC_CTL"; exit 2; }
for f in hyper-cs16-fastdl-v8.py hyper-cs16-ctl-wrapper-v8.py patch-core-v8.py core-fastdl-override-v8.py.txt; do [[ -f "$SCRIPT_DIR/$f" ]] || { echo "[ERROR] missing $f"; exit 2; }; done
mkdir -p "$BACKUP" "$LIBEXEC"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.repo.before"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -f "/srv/hyper-cs16/servers/$SID/cstrike/server.cfg" ]] && cp -a "/srv/hyper-cs16/servers/$SID/cstrike/server.cfg" "$BACKUP/server.cfg.before" || true
tar -C /etc/nginx -czf "$BACKUP/nginx-before.tar.gz" . 2>/dev/null || true

echo '================================================================'
echo ' HYPER-HOST FASTDL FINAL v8'
echo " Server: #$SID"
echo " URL:    http://old-zombie.ru/fastdl/$SID/"
echo " Backup: $BACKUP"
echo '================================================================'

echo '[1/9] Install isolated FastDL helper...'
install -m 0755 "$SCRIPT_DIR/hyper-cs16-fastdl-v8.py" "$HELPER"
python3 -m py_compile "$HELPER"

echo '[2/9] Patch internal panel FastDL calls...'
python3 "$SCRIPT_DIR/patch-core-v8.py" "$SRC_CTL" "$SCRIPT_DIR/core-fastdl-override-v8.py.txt"
python3 -m py_compile "$SRC_CTL"

echo '[3/9] Install patched core + wrapper...'
install -m 0755 "$SRC_CTL" "$CORE"
install -m 0755 "$SCRIPT_DIR/hyper-cs16-ctl-wrapper-v8.py" "$LIVE_CTL"
python3 -m py_compile "$CORE" "$LIVE_CTL"

echo '[4/9] Validate source BSP...'
python3 - "$SID" <<'PY'
from pathlib import Path
import struct,sys
sid=int(sys.argv[1]); maps=Path(f'/srv/hyper-cs16/servers/{sid}/cstrike/maps'); good=bad=0
for p in sorted(maps.glob('*.bsp')):
 b=p.read_bytes()[:4]; v=struct.unpack('<I',b)[0] if len(b)==4 else None
 if v==30: good+=1
 else: bad+=1; print('BAD SOURCE',p.name,v,b.hex())
print('valid BSP:',good); print('bad BSP:',bad)
if bad: raise SystemExit(20)
PY

echo '[5/9] Clean rebuild FastDL...'
"$HELPER" rebuild "$SID"

echo '[6/9] Verify panel fastdl-status...'
"$LIVE_CTL" fastdl-status "$SID"

echo '[7/9] Restart server once to load repaired server.cfg...'
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

echo '[8/9] Runtime cvars...'
"$CORE" rcon "$SID" 'sv_downloadurl' || true
"$CORE" rcon "$SID" 'sv_allowdownload' || true
"$CORE" rcon "$SID" 'sv_allow_dlfile' || true

echo '[9/9] Raw BSP nginx probe...'
TMP="$(mktemp)"; HDR="$(mktemp)"
CODE="$(curl -sS --connect-timeout 3 --max-time 10 -H 'Host: old-zombie.ru' -H 'Range: bytes=0-3' -D "$HDR" -o "$TMP" -w '%{http_code}' "http://127.0.0.1/fastdl/$SID/maps/zm_303.bsp" || true)"
HEAD="$(xxd -p -l 8 "$TMP" 2>/dev/null || true)"
echo "HTTP: $CODE"; echo "HEAD: $HEAD"; grep -i '^Content-Type:\|^X-Hyper-FastDL:' "$HDR" | tr -d '\r' || true
rm -f "$TMP" "$HDR"
[[ "$HEAD" == 1e000000* ]] || { echo '[ERROR] nginx still returns non-BSP bytes'; exit 30; }

echo
echo '================================================================'
echo ' [SUCCESS] FASTDL FINAL v8 INSTALLED'
echo '================================================================'
echo '206 is normal for Range requests.'
echo '1e000000 = GoldSrc BSP version 30.'
echo '3c21646f = <!do = HTML and is now rejected.'
echo 'Panel sync/status/rebuild now bypass old broken FastDL functions.'
echo "Backup: $BACKUP"
