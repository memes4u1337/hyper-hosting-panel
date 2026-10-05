#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="/srv/hyper-cs16/servers/${SID}"
CSTRIKE="${ROOT}/cstrike"
AMXX="${CSTRIKE}/addons/amxmodx"
PLUGINS="${AMXX}/configs/plugins.ini"
UNIT="hyper-cs16@${SID}.service"
BACKUP="/root/oldz-delux-no-compile-v8.3-${SID}-${STAMP}"

echo "================================================================"
echo " OLD ZOMBIE DELUX ACTIVATE v8.3 (NO COMPILE)"
echo " Server: #${SID}"
echo " Backup: ${BACKUP}"
echo "================================================================"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

if [[ ! -d "${AMXX}" ]]; then
  echo "[ERROR] AMXX directory not found: ${AMXX}"
  exit 2
fi

mkdir -p "${BACKUP}"
cp -a "${PLUGINS}" "${BACKUP}/plugins.ini" 2>/dev/null || true

REQ=(
  "zmpl.amxx"
  "zm_addon_knife.amxx"
  "oldz_account_privileges.amxx"
  "oldz_delux_menu.amxx"
  "oldz_delux_hook.amxx"
  "oldz_zclass_desperado_delux.amxx"
)

echo "[1/6] Checking READY .amxx binaries..."
MISSING=0
for p in "${REQ[@]}"; do
  f="${AMXX}/plugins/${p}"
  if [[ -s "$f" ]]; then
    echo "[OK] $p ($(stat -c%s "$f") bytes)"
  else
    echo "[MISSING] $f"
    MISSING=1
  fi
done

if [[ "$MISSING" -ne 0 ]]; then
  echo
  echo "[ABORT] Nothing changed."
  echo "Put all READY .amxx files into:"
  echo "  ${AMXX}/plugins/"
  exit 10
fi

echo
echo "[2/6] Checking that core binaries look like DELUX builds..."
WARN=0
if command -v strings >/dev/null 2>&1; then
  if strings "${AMXX}/plugins/zmpl.amxx" | grep -Eqi 'DELUX|Desperado'; then
    echo "[OK] zmpl.amxx contains DELUX/Desperado strings"
  else
    echo "[WARN] zmpl.amxx does not expose DELUX/Desperado strings via strings(1)"
    WARN=1
  fi

  if strings "${AMXX}/plugins/zm_addon_knife.amxx" | grep -Eqi 'Wolf Axe|DELUX'; then
    echo "[OK] zm_addon_knife.amxx contains Wolf Axe/DELUX strings"
  else
    echo "[WARN] zm_addon_knife.amxx does not expose Wolf Axe/DELUX strings via strings(1)"
    WARN=1
  fi
fi

echo
echo "[3/6] Activating DELUX plugins in plugins.ini..."
python3 - "${PLUGINS}" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()

wanted=[
    "zmpl.amxx",
    "zm_addon_knife.amxx",
    "oldz_account_privileges.amxx",
    "oldz_delux_menu.amxx",
    "oldz_delux_hook.amxx",
    "oldz_zclass_desperado_delux.amxx",
]

# Keep first occurrence of unrelated lines.
# Remove all active/commented copies of wanted entries, then insert a clean block.
out=[]
for line in lines:
    st=line.strip()
    token=st.lstrip(";").strip().split(None,1)[0].lower() if st else ""
    if token in {x.lower() for x in wanted}:
        continue
    out.append(line)

# Put core plugins near the top, DELUX block right after them.
block=[
    "zmpl.amxx",
    "zm_addon_knife.amxx",
    "",
    "; ======================================================",
    "; OLD ZOMBIE | DELUX",
    "; ======================================================",
    "oldz_account_privileges.amxx",
    "oldz_delux_menu.amxx",
    "oldz_delux_hook.amxx",
    "oldz_zclass_desperado_delux.amxx",
    "",
]

# Insert before admin_loader/fresh_bans if present; otherwise at start.
idx=0
for i,line in enumerate(out):
    tok=line.strip().split(None,1)[0].lower() if line.strip() and not line.lstrip().startswith(";") else ""
    if tok in {"admin_loader.amxx","fresh_bans.amxx"}:
        idx=i
        break
else:
    idx=0

out[idx:idx]=block
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
PY

echo "[4/6] Verifying active entries..."
for p in "${REQ[@]}"; do
  if grep -Eqi "^[[:space:]]*${p//./\\.}([[:space:]]|$)" "${PLUGINS}"; then
    echo "[OK] active: $p"
  else
    echo "[ERROR] not active: $p"
    exit 20
  fi
done

echo
echo "[5/6] Restarting server..."
systemctl reset-failed "${UNIT}" >/dev/null 2>&1 || true
systemctl restart "${UNIT}"
sleep 8

if ! systemctl is-active --quiet "${UNIT}"; then
  echo "[ERROR] Server did not stay active."
  journalctl -u "${UNIT}" -n 180 --no-pager -o cat || true
  echo "[ROLLBACK] Restoring old plugins.ini"
  cp -a "${BACKUP}/plugins.ini" "${PLUGINS}" 2>/dev/null || true
  systemctl restart "${UNIT}" || true
  exit 30
fi

echo "[OK] Server is active."

echo
echo "[6/6] Runtime verification..."
CTL="/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl"
if [[ -x "$CTL" ]]; then
  echo
  echo "--- STATUS ---"
  "$CTL" status "$SID" || true

  echo
  echo "--- AMXX PLUGINS ---"
  "$CTL" rcon "$SID" "amxx plugins" 2>&1 | grep -Ei 'zmpl|knife|delux|desperado|account privileges' || true

  echo
  echo "--- COMMANDS ---"
  "$CTL" rcon "$SID" "amxx cmds" 2>&1 | grep -Ei 'new_delux_menu|oldz_delux_zombie|oldz_delux_hook_menu|knife_zb|dhook' || true
fi

echo
echo "================================================================"
echo " [SUCCESS] DELUX v8.3 activated WITHOUT COMPILATION"
echo "================================================================"
echo "Nothing was compiled."
echo "Only existing ready .amxx binaries were enabled."
echo "Backup: ${BACKUP}"
if [[ "$WARN" -ne 0 ]]; then
  echo
  echo "[NOTE] One or both core binaries did not expose expected DELUX strings."
  echo "If menu/knife still do not appear, your uploaded zmpl.amxx or"
  echo "zm_addon_knife.amxx is an OLD build, not the DELUX build."
fi
