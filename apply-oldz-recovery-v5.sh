#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
QUOTA="${2:-12}"
DIFF="${3:-4}"
STAMP="$(date +%Y%m%d-%H%M%S)"
UNIT="hyper-cs16@${SID}.service"
BACKUP="/root/oldz-recovery-v5-${SID}-${STAMP}"

echo "================================================================"
echo " OLD ZOMBIE RECOVERY v5"
echo " Server: #${SID}"
echo " Bots: quota=${QUOTA}, difficulty=${DIFF}"
echo " Backup: ${BACKUP}"
echo "================================================================"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

mkdir -p "$BACKUP"

CFG="/var/lib/hyper-cs16/servers/${SID}.json"
LEGACY_CFG="/etc/hyper-cs16/servers/${SID}.json"

json_get() {
  python3 - "$1" "$2" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    print(d.get(sys.argv[2],"") or "")
except Exception:
    print("")
PY
}

ROOT=""
if [[ -f "$CFG" ]]; then ROOT="$(json_get "$CFG" path)"; fi
if [[ -z "$ROOT" && -f "$LEGACY_CFG" ]]; then ROOT="$(json_get "$LEGACY_CFG" path)"; fi
[[ -n "$ROOT" ]] || ROOT="/srv/hyper-cs16/servers/${SID}"

CSTRIKE="$ROOT/cstrike"
AMXX="$CSTRIKE/addons/amxmodx"
PLUGINS="$AMXX/configs/plugins.ini"
META="$CSTRIKE/addons/metamod/plugins.ini"
YCFG="$CSTRIKE/addons/yapb/conf/yapb.cfg"

if [[ ! -d "$CSTRIKE" ]]; then
  echo "[ERROR] cstrike directory not found: $CSTRIKE"
  exit 2
fi

echo "[INFO] ROOT=$ROOT"

# ------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------
echo "[1/8] Backup..."
for f in "$PLUGINS" "$META" "$YCFG" "$CSTRIKE/server.cfg"; do
  [[ -f "$f" ]] && cp -a "$f" "$BACKUP/$(echo "${f#$CSTRIKE/}" | tr '/' '_')" || true
done
for f in \
  "$AMXX/plugins/zmpl.amxx" \
  "$AMXX/plugins/zm_addon_knife.amxx" \
  "$AMXX/plugins/oldz_delux_menu.amxx" \
  "$AMXX/plugins/oldz_delux_hook.amxx" \
  "$AMXX/plugins/oldz_zclass_desperado_delux.amxx"
do
  [[ -f "$f" ]] && cp -a "$f" "$BACKUP/$(basename "$f")" || true
done

# ------------------------------------------------------------------
# 2. YaPB: make it actually load and join even when server is empty
# ------------------------------------------------------------------
echo "[2/8] Fixing YaPB..."

mkdir -p "$(dirname "$META")" "$(dirname "$YCFG")"
touch "$META"

python3 - "$META" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
needle="addons/yapb/bin/yapb.so"
out=[]
found=False
for line in lines:
    if needle in line.lower():
        if found:
            continue
        out.append("linux addons/yapb/bin/yapb.so")
        found=True
    else:
        out.append(line)
if not found:
    out.append("linux addons/yapb/bin/yapb.so")
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
PY

if [[ -f "$YCFG" ]]; then
  python3 - "$YCFG" "$QUOTA" "$DIFF" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); quota=sys.argv[2]; diff=sys.argv[3]
text=p.read_text(encoding="utf-8",errors="ignore")

vals={
 "yb_quota":quota,
 "yb_quota_mode":"fill",
 "yb_difficulty":diff,
 "yb_difficulty_min":"-1",
 "yb_difficulty_max":"-1",
 "yb_difficulty_auto":"0",
 "yb_join_after_player":"0",
 "yb_join_delay":"2.0",
 "yb_autovacate":"1",
 "yb_autovacate_keep_slots":"1",
}

for k,v in vals.items():
    pat=re.compile(r'(?im)^\s*'+re.escape(k)+r'\s+"?[^"\r\n]*"?\s*$')
    newline=f'{k} "{v}"'
    if pat.search(text):
        text=pat.sub(newline,text,1)
    else:
        text += ("\n" if text and not text.endswith("\n") else "") + newline + "\n"

p.write_text(text,encoding="utf-8")
PY
else
  echo "[WARN] YaPB config not found: $YCFG"
fi

# ------------------------------------------------------------------
# 3. Remove known startup killers, but keep stable DELUX components
# ------------------------------------------------------------------
echo "[3/8] Sanitizing AMXX plugin list..."
[[ -f "$PLUGINS" ]] || touch "$PLUGINS"

python3 - "$PLUGINS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()

# These have already caused native/precache startup failures in this build.
unsafe={
    "oldz_delux_bloodmoon.amxx",
    "oldz_delux_starchaser.amxx",
    "oldz_delux_balrog95.amxx",
}

# These are expected to be enabled if their binaries exist.
wanted=[
    "zmpl.amxx",
    "zm_addon_knife.amxx",
    "oldz_delux_menu.amxx",
    "oldz_delux_hook.amxx",
    "oldz_zclass_desperado_delux.amxx",
]

out=[]
seen=set()
for line in lines:
    raw=line.strip()
    token=raw.lstrip(";").strip().split(None,1)[0].lower() if raw else ""

    if token in unsafe:
        out.append("; OLDZ-V5 disabled until precache/native cleanup: "+raw.lstrip(";").strip())
        continue

    if token in [x.lower() for x in wanted]:
        if token in seen:
            continue
        out.append(token)
        seen.add(token)
        continue

    out.append(line)

for name in wanted:
    if name.lower() not in seen:
        out.append(name)

p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
PY

# ------------------------------------------------------------------
# 4. Replace the crashing/local compiler with an isolated official 5303 compiler
#    and compile only if sources exist. Existing binaries stay untouched on fail.
# ------------------------------------------------------------------
echo "[4/8] Preparing official AMXX 1.9.0.5303 compiler..."
COMPILER_DIR="/tmp/amxx5303-${SID}"
rm -rf "$COMPILER_DIR"
mkdir -p "$COMPILER_DIR"

AMXX_URL="https://www.amxmodx.org/amxxdrop/1.9/amxmodx-1.9.0-git5303-base-linux.tar.gz"
AMXX_TGZ="/tmp/amxmodx-1.9.0-git5303-base-linux.tar.gz"

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --connect-timeout 15 "$AMXX_URL" -o "$AMXX_TGZ"
else
  wget -O "$AMXX_TGZ" "$AMXX_URL"
fi

tar -xzf "$AMXX_TGZ" -C "$COMPILER_DIR"

OFFICIAL_COMPILER="$COMPILER_DIR/addons/amxmodx/scripting/amxxpc"
OFFICIAL_INCLUDE="$COMPILER_DIR/addons/amxmodx/scripting/include"

if [[ ! -x "$OFFICIAL_COMPILER" ]]; then
  chmod +x "$OFFICIAL_COMPILER" 2>/dev/null || true
fi

if [[ ! -x "$OFFICIAL_COMPILER" ]]; then
  echo "[WARN] Official compiler unavailable; keeping existing binaries."
else
  echo "[OK] Official compiler: $OFFICIAL_COMPILER"
fi

compile_one() {
  local src="$1"
  local dst="$2"
  local name
  name="$(basename "$src")"

  [[ -f "$src" ]] || {
    echo "[SKIP] source missing: $name"
    return 0
  }

  [[ -x "$OFFICIAL_COMPILER" ]] || return 0

  local tmp="/tmp/${name%.sma}.${SID}.amxx"
  rm -f "$tmp"

  echo "[AMXX] $name"
  set +e
  "$OFFICIAL_COMPILER" "$src" \
    "-i${AMXX}/scripting/include" \
    "-i${OFFICIAL_INCLUDE}" \
    "-o${tmp}" >/tmp/"${name}".compile.log 2>&1
  rc=$?
  set -e

  if [[ $rc -eq 0 && -s "$tmp" ]]; then
    cp -a "$tmp" "$dst"
    chmod 0644 "$dst"
    chown cs16:www-data "$dst" 2>/dev/null || true
    echo "[OK] $(basename "$dst") compiled"
  else
    echo "[WARN] compile failed for $name (rc=$rc); old binary kept"
    tail -n 25 /tmp/"${name}".compile.log || true
  fi

  rm -f "$tmp"
}

# Main core first.
compile_one "$AMXX/scripting/zmpl.sma" "$AMXX/plugins/zmpl.amxx"
compile_one "$AMXX/scripting/zm_addon_knife.sma" "$AMXX/plugins/zm_addon_knife.amxx"
compile_one "$AMXX/scripting/oldz_delux_menu.sma" "$AMXX/plugins/oldz_delux_menu.amxx"
compile_one "$AMXX/scripting/oldz_delux_hook.sma" "$AMXX/plugins/oldz_delux_hook.amxx"
compile_one "$AMXX/scripting/oldz_zclass_desperado_delux.sma" "$AMXX/plugins/oldz_zclass_desperado_delux.amxx"

# ------------------------------------------------------------------
# 5. Verify critical binaries before restart.
# ------------------------------------------------------------------
echo "[5/8] Checking critical binaries..."

critical=(zmpl.amxx zm_addon_knife.amxx)
for p in "${critical[@]}"; do
  if [[ ! -s "$AMXX/plugins/$p" ]]; then
    echo "[ERROR] critical plugin missing: $AMXX/plugins/$p"
    exit 20
  fi
done

# DELUX plugins are optional for boot. If source exists but binary is absent,
# comment them instead of letting AMXX complain every map.
python3 - "$PLUGINS" "$AMXX/plugins" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); plugdir=Path(sys.argv[2])
optional={
 "oldz_delux_menu.amxx",
 "oldz_delux_hook.amxx",
 "oldz_zclass_desperado_delux.amxx",
}
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
out=[]
for line in lines:
    raw=line.strip()
    token=raw.lstrip(";").strip().split(None,1)[0].lower() if raw else ""
    if token in optional and not (plugdir/token).exists():
        out.append("; OLDZ-V5 missing binary: "+raw.lstrip(";").strip())
    else:
        out.append(line)
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
PY

# ------------------------------------------------------------------
# 6. Restart and auto-recover from known AMXX startup killers.
# ------------------------------------------------------------------
echo "[6/8] Restarting server..."
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
systemctl restart "$UNIT" || true
sleep 10

if ! systemctl is-active --quiet "$UNIT"; then
  echo "[WARN] First restart failed. Looking for known plugin failures..."
  J="/tmp/oldz-v5-journal-${SID}.log"
  journalctl -u "$UNIT" -n 250 --no-pager -o cat > "$J" || true

  # If precache limit is hit, remove optional DELUX resource plugins from load.
  if grep -qiE 'over the 512 limit|PF_precache_.*failed to precache' "$J"; then
    echo "[RECOVERY] 512 precache limit detected -> disabling optional DELUX resource plugins."
    python3 - "$PLUGINS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
targets={
 "oldz_delux_menu.amxx",
 "oldz_delux_hook.amxx",
 "oldz_zclass_desperado_delux.amxx",
}
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
out=[]
for line in lines:
    raw=line.strip()
    token=raw.lstrip(";").strip().split(None,1)[0].lower() if raw else ""
    if token in targets:
        out.append("; OLDZ-V5 recovery/precache: "+raw.lstrip(";").strip())
    else:
        out.append(line)
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
PY
  fi

  # Automatically disable any plugin explicitly named in an AMXX runtime/native error.
  python3 - "$J" "$PLUGINS" <<'PY'
from pathlib import Path
import re,sys
j=Path(sys.argv[1]).read_text(encoding="utf-8",errors="ignore")
p=Path(sys.argv[2])
bad=set(re.findall(r'plugin "([^"]+\.amxx)"',j,re.I))
if bad:
    lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
    out=[]
    for line in lines:
        raw=line.strip()
        token=raw.lstrip(";").strip().split(None,1)[0] if raw else ""
        if token.lower() in {x.lower() for x in bad}:
            out.append("; OLDZ-V5 runtime recovery: "+raw.lstrip(";").strip())
        else:
            out.append(line)
    p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
    print("[RECOVERY] Disabled:",", ".join(sorted(bad)))
PY

  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT" || true
  sleep 10
fi

if ! systemctl is-active --quiet "$UNIT"; then
  echo "[ERROR] Server still fails to stay active."
  journalctl -u "$UNIT" -n 200 --no-pager -o cat
  echo "[INFO] Backup: $BACKUP"
  exit 30
fi

echo "[OK] systemd service is active."

# ------------------------------------------------------------------
# 7. Force bot cvars at runtime as well.
# ------------------------------------------------------------------
echo "[7/8] Applying YaPB runtime cvars..."

CTL="/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl"
if [[ -x "$CTL" ]]; then
  for cmd in \
    "yb_quota $QUOTA" \
    "yb_quota_mode fill" \
    "yb_difficulty $DIFF" \
    "yb_join_after_player 0" \
    "yb_join_delay 2.0" \
    "yb_autovacate 1"
  do
    "$CTL" rcon "$SID" "$cmd" >/dev/null 2>&1 || true
  done
fi

sleep 8

# ------------------------------------------------------------------
# 8. Final diagnostics
# ------------------------------------------------------------------
echo "[8/8] Final diagnostics..."

echo
echo "--- SERVICE ---"
systemctl --no-pager --full status "$UNIT" | tail -n 18 || true

echo
echo "--- METAMOD YaPB ---"
grep -in 'yapb' "$META" || true

echo
echo "--- YaPB config ---"
if [[ -f "$YCFG" ]]; then
  grep -Ei '^(yb_quota|yb_quota_mode|yb_difficulty|yb_join_after_player|yb_join_delay|yb_autovacate)' "$YCFG" || true
fi

echo
echo "--- DELUX / KNIFE plugins ---"
grep -Ein 'zmpl|zm_addon_knife|oldz_delux|desperado' "$PLUGINS" || true

if [[ -x "$CTL" ]]; then
  echo
  echo "--- PANEL STATUS ---"
  "$CTL" status "$SID" || true
fi

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE RECOVERY v5 finished"
echo "================================================================"
echo "Server is active."
echo "YaPB loader is enabled."
echo "YaPB is configured for ${QUOTA} bots, difficulty ${DIFF}, join_after_player=0."
echo "Known broken DELUX weapon plugins remain disabled until their native/precache"
echo "trees are cleaned."
echo
echo "Backup: $BACKUP"
echo
echo "If players still cannot connect, send:"
echo "  journalctl -u $UNIT -n 200 --no-pager"
echo "and:"
echo "  $CTL status $SID"
