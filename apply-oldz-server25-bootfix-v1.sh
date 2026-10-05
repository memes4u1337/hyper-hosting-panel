#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
UNIT="hyper-cs16@${SID}.service"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-server${SID}-bootfix-v1-${STAMP}"
CFG="/var/lib/hyper-cs16/servers/${SID}.json"
LEGACY_CFG="/etc/hyper-cs16/servers/${SID}.json"

echo "================================================================"
echo " OLD ZOMBIE SERVER BOOT FIX v1"
echo " Server: #${SID}"
echo " Backup: ${BACKUP}"
echo "================================================================"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

detect_root() {
  local p=""
  local src=""
  [[ -f "$CFG" ]] && src="$CFG"
  [[ -z "$src" && -f "$LEGACY_CFG" ]] && src="$LEGACY_CFG"
  if [[ -n "$src" ]]; then
    p="$(python3 - "$src" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
    print(d.get('path',''))
except Exception:
    print('')
PY
)"
  fi
  [[ -z "$p" ]] && p="/srv/hyper-cs16/servers/${SID}"
  printf '%s' "$p"
}

ROOT="$(detect_root)"
CSTRIKE="${ROOT}/cstrike"
AMXX_CFG="${CSTRIKE}/addons/amxmodx/configs"

[[ -d "$CSTRIKE" ]] || { echo "[ERROR] cstrike not found: $CSTRIKE"; exit 2; }
[[ -d "$AMXX_CFG" ]] || { echo "[ERROR] AMXX configs not found: $AMXX_CFG"; exit 3; }

mkdir -p "$BACKUP"

echo "[1/8] Server path: $ROOT"
echo "[2/8] Saving plugins configs..."
find "$AMXX_CFG" -maxdepth 1 -type f -name 'plugins*.ini' -print0 | while IFS= read -r -d '' f; do
  cp -a "$f" "$BACKUP/$(basename "$f")"
done
[[ -f "$CFG" ]] && cp -a "$CFG" "$BACKUP/server.json"
[[ -f "$LEGACY_CFG" ]] && cp -a "$LEGACY_CFG" "$BACKUP/server-legacy.json"

echo "[3/8] Stopping server..."
systemctl stop "$UNIT" 2>/dev/null || true
systemctl reset-failed "$UNIT" 2>/dev/null || true

disable_plugins() {
  local reason="$1"; shift
  python3 - "$AMXX_CFG" "$reason" "$@" <<'PY'
from pathlib import Path
import sys
cfg=Path(sys.argv[1]); reason=sys.argv[2]; targets={x.lower() for x in sys.argv[3:]}
for fp in sorted(cfg.glob('plugins*.ini')):
    try:
        lines=fp.read_text(encoding='utf-8',errors='ignore').splitlines()
    except Exception:
        continue
    changed=False; out=[]
    for line in lines:
        raw=line.strip()
        if raw.startswith(';'):
            out.append(line); continue
        token=(raw.split(None,1)[0] if raw else '').lower()
        if token in targets:
            out.append(f'; {reason}: {line}')
            changed=True
            print(f'[DISABLE] {fp.name}: {token}')
        else:
            out.append(line)
    if changed:
        fp.write_text('\n'.join(out)+'\n',encoding='utf-8')
PY
}

service_ok() {
  sleep 8
  systemctl is-active --quiet "$UNIT" || return 1
  local port="0"
  if [[ -f "$CFG" ]]; then
    port="$(python3 - "$CFG" <<'PY'
import json,sys
try: print(int(json.load(open(sys.argv[1],encoding='utf-8')).get('port',0)))
except Exception: print(0)
PY
)"
  fi
  if [[ "$port" != "0" ]]; then
    ss -lunH 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" || { sleep 7; systemctl is-active --quiet "$UNIT" || return 1; ss -lunH 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" || return 1; }
  fi
  return 0
}

start_and_test() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  systemctl enable "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT" >/dev/null 2>&1 || true
  service_ok
}

echo "[4/8] Applying Stage 1..."
disable_plugins "OLDZ-BOOTFIX-V1" \
  oldz_delux_bloodmoon.amxx \
  oldz_delux_starchaser.amxx \
  oldz_delux_balrog95.amxx \
  oldz_delux_menu.amxx \
  oldz_zclass_desperado_delux.amxx

echo "[5/8] Trying to start server after Stage 1..."
if start_and_test; then
  echo "================================================================"
  echo " [SUCCESS] Server #${SID} is running."
  echo "================================================================"
  echo "Backup: $BACKUP"
  echo "Broken/resource-heavy DELUX plugins were only commented, not deleted."
  systemctl --no-pager --full status "$UNIT" | tail -n 12 || true
  exit 0
fi

echo "[WARN] Stage 1 was not enough."
echo "[6/8] Applying Stage 2..."
disable_plugins "OLDZ-BOOTFIX-V1-STAGE2" \
  oldz_delux_hook.amxx \
  zm_addon_knife.amxx \
  oldz_store_models.amxx

echo "[7/8] Trying to start server after Stage 2..."
if start_and_test; then
  echo "================================================================"
  echo " [SUCCESS] Server #${SID} recovered in compatibility mode."
  echo "================================================================"
  echo "Backup: $BACKUP"
  echo "Nothing was deleted."
  systemctl --no-pager --full status "$UNIT" | tail -n 12 || true
  exit 0
fi

echo "[8/8] Server still does not stay up."
echo "Backup: $BACKUP"
echo "Last journal:"
journalctl -u "$UNIT" -n 160 --no-pager -o cat || true
exit 10
