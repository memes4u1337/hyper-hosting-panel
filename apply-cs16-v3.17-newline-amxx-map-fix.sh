#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.17 — NEWLINE / AMXX LOADER / MAP POOL FIX
#
# Fixes a concrete v3.16 escaping bug:
#   plugins.ini received literal "\n" characters instead of real newlines,
#   so Metamod tried to load:
#       addons/amxmodx/dlls/amxmodx_mm_i386.so\n
#
# Also fixes the same double-escaping in mapcycle/maps.ini and the
# map/changelevel whitelist regexp.
#
# This patch:
#   - DOES NOT run v3.3/v3.14/v3.15/v3.16
#   - patches the live controller and repository controller
#   - repairs the current server's plugins.ini
#   - repairs mapcycle.txt / AMXX maps.ini if v3.16 wrote literal \n
#   - verifies AMXX loader exists
#   - restarts the requested server once
#   - verifies Metamod no longer has the "\n" badf loader
#   - keeps backups and restores controller files on syntax failure
#
# Usage:
#   bash apply-cs16-v3.17-newline-amxx-map-fix.sh 15

SID="${1:-15}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.17-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.17-${STAMP}.log"
UNIT="hyper-cs16@${SID}.service"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die() {
  echo
  echo "[ERROR] $*"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backup: $BACKUP"
  exit 1
}

echo "============================================================"
echo " HYPER-HOST CS16 v3.17 — AMXX/NEWLINE/MAPS FIX"
echo "============================================================"
echo "Server:     $SID"
echo "Live ctl:   $LIVE_CTL"
echo "Repo ctl:   $REPO_CTL"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"

cp -a "$LIVE_CTL" "$BACKUP/live-hyper-cs16-ctl"
cp -a "$REPO_CTL" "$BACKUP/repo-hyper-cs16-ctl"

echo "[1/8] Fixing v3.16 source escaping in controller..."

python3 - "$LIVE_CTL" "$REPO_CTL" <<'PY'
from pathlib import Path
import py_compile
import os
import sys

targets=[Path(x) for x in sys.argv[1:]]

def patch(path:Path):
    src=path.read_text(encoding='utf-8', errors='surrogateescape')
    old=src

    # v3.16 managed AMXX helper: source must contain Python '\n', not '\\n'.
    src=src.replace(
        "raw.replace('\\\\r\\\\n','\\\\n').replace('\\\\r','\\\\n').splitlines()",
        "raw.replace('\\r\\n','\\n').replace('\\r','\\n').splitlines()"
    )
    src=src.replace(
        "mp.write_text('\\\\n'.join(output).rstrip()+'\\\\n',encoding='latin1')",
        "mp.write_text('\\n'.join(output).rstrip()+'\\n',encoding='latin1')"
    )

    # v3.15/v3.16 map pool helper had the same double escaping.
    src=src.replace(
        "body='\\\\n'.join(allowed).rstrip()+'\\\\n'",
        "body='\\n'.join(allowed).rstrip()+'\\n'"
    )

    # The regexp was emitted as {{1,64}}, which does not mean {1,64}.
    src=src.replace(
        "[A-Za-z0-9_-]{{1,64}}",
        "[A-Za-z0-9_-]{1,64}"
    )

    # Marker for idempotent verification.
    if "# HYPER-HOST v3.17 NEWLINE FIX" not in src:
        marker="# >>> HYPER-HOST v3.16 MANAGED PLATFORM >>>"
        if marker in src:
            src=src.replace(
                marker,
                "# HYPER-HOST v3.17 NEWLINE FIX\n"+marker,
                1
            )
        else:
            src="# HYPER-HOST v3.17 NEWLINE FIX\n"+src

    checks={
        "v3.16 managed helper":
            "def _v316_refresh_amxx_platform(" in src,
        "real plugin newline":
            "mp.write_text('\\n'.join(output).rstrip()+'\\n',encoding='latin1')" in src,
        "no bad plugin literal newline":
            "mp.write_text('\\\\n'.join(output).rstrip()+'\\\\n',encoding='latin1')" not in src,
        "real mapcycle newline":
            "body='\\n'.join(allowed).rstrip()+'\\n'" in src,
        "no bad map literal newline":
            "body='\\\\n'.join(allowed).rstrip()+'\\\\n'" not in src,
        "map regexp":
            "[A-Za-z0-9_-]{1,64}" in src,
        "no doubled map regexp":
            "[A-Za-z0-9_-]{{1,64}}" not in src,
    }

    bad=[name for name,ok in checks.items() if not ok]
    if bad:
        raise RuntimeError(f"{path}: verification failed: {bad}")

    if src != old:
        tmp=path.with_name(path.name+".v317tmp")
        tmp.write_text(src, encoding='utf-8', errors='surrogateescape')
        os.chmod(tmp, path.stat().st_mode)
        os.replace(tmp,path)
        print("[PATCHED]",path)
    else:
        print("[OK already patched]",path)

    py_compile.compile(str(path), doraise=True)

for p in targets:
    patch(p)

print("[OK] controller source escaping fixed")
PY

if ! python3 -m py_compile "$LIVE_CTL"; then
  cp -a "$BACKUP/live-hyper-cs16-ctl" "$LIVE_CTL"
  cp -a "$BACKUP/repo-hyper-cs16-ctl" "$REPO_CTL"
  die "Python validation failed; controller files restored"
fi

echo
echo "[2/8] Loading server state..."

STATE="/var/lib/hyper-cs16/servers/${SID}.json"
[[ -f "$STATE" ]] || die "Server state missing: $STATE"

readarray -t INFO < <(python3 - "$STATE" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
sid=int(d.get('id') or 0)
print(str(d.get('path') or f'/srv/hyper-cs16/servers/{sid}'))
print(int(d.get('port') or 0))
print(str(d.get('start_map') or ''))
PY
)

SERVER_PATH="${INFO[0]}"
PORT="${INFO[1]}"
START_MAP="${INFO[2]}"

[[ -d "$SERVER_PATH/cstrike" ]] || die "Server cstrike directory missing: $SERVER_PATH/cstrike"

META_INI="$SERVER_PATH/cstrike/addons/metamod/plugins.ini"
AMXX_LOADER="$SERVER_PATH/cstrike/addons/amxmodx/dlls/amxmodx_mm_i386.so"
MAPCYCLE="$SERVER_PATH/cstrike/mapcycle.txt"
AMXX_MAPS="$SERVER_PATH/cstrike/addons/amxmodx/configs/maps.ini"

echo "  Path: $SERVER_PATH"
echo "  Port: $PORT"
echo "  Start map: $START_MAP"

mkdir -p "$BACKUP/server-files"
for f in "$META_INI" "$MAPCYCLE" "$AMXX_MAPS"; do
  if [[ -f "$f" ]]; then
    safe="$(basename "$f")"
    cp -a "$f" "$BACKUP/server-files/${safe}.before"
  fi
done

echo
echo "[3/8] Repairing CURRENT server text files..."

python3 - "$META_INI" "$MAPCYCLE" "$AMXX_MAPS" <<'PY'
from pathlib import Path
import sys

meta=Path(sys.argv[1])
mapcycle=Path(sys.argv[2])
mapsini=Path(sys.argv[3])

def decode_bytes(path:Path):
    raw=path.read_bytes()
    return raw.decode('latin1')

def normalize_literal_newlines(text:str)->str:
    # These sequences were accidentally written literally by v3.16.
    return (
        text
        .replace('\\r\\n','\n')
        .replace('\\n','\n')
        .replace('\\r','\n')
        .replace('\r\n','\n')
        .replace('\r','\n')
    )

if meta.exists():
    text=normalize_literal_newlines(decode_bytes(meta))
    out=[]
    amxx_seen=False

    for raw in text.splitlines():
        line=raw.strip()
        low=line.lower()
        active=bool(line and not line.startswith(';') and not line.startswith('#'))

        if active and 'amxmodx' in low:
            if not amxx_seen:
                out.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')
                amxx_seen=True
            continue

        out.append(raw)

    if not amxx_seen:
        out.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')

    # Remove blank noise while preserving comments/other plugin lines.
    result='\n'.join(out).rstrip()+'\n'
    meta.write_bytes(result.encode('latin1','replace'))
    print("[FIXED]",meta)

for path in (mapcycle,mapsini):
    if not path.exists():
        continue
    text=normalize_literal_newlines(
        path.read_bytes().decode('utf-8','replace')
    )
    lines=[]
    seen=set()
    for raw in text.splitlines():
        name=raw.strip()
        if not name:
            continue
        if name not in seen:
            seen.add(name)
            lines.append(name)
    path.write_text('\n'.join(lines).rstrip()+('\n' if lines else ''),encoding='utf-8')
    print("[FIXED]",path)
PY

[[ -f "$AMXX_LOADER" ]] || die "Managed AMXX loader does not exist: $AMXX_LOADER"

echo "[OK] AMXX loader exists: $AMXX_LOADER"

echo
echo "[4/8] Verifying plugins.ini has REAL line endings..."

python3 - "$META_INI" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
raw=p.read_bytes()
text=raw.decode('latin1')

if b'\\n' in raw or b'\\r' in raw:
    raise SystemExit("[ERROR] plugins.ini still contains literal backslash newline sequences")

lines=[x.strip() for x in text.splitlines() if x.strip() and not x.lstrip().startswith((';','#'))]
amxx=[x for x in lines if 'amxmodx' in x.lower()]

if amxx != ['linux addons/amxmodx/dlls/amxmodx_mm_i386.so']:
    raise SystemExit("[ERROR] AMXX loader line is not canonical: "+repr(amxx))

print("[OK] plugins.ini uses real newlines")
print("[OK] AMXX loader line:",amxx[0])
PY

echo
echo "[5/8] Restarting server #$SID once..."

systemctl reset-failed "$UNIT" 2>/dev/null || true
systemctl restart "$UNIT" || true

# Wait for UDP and allow AMXX/Metamod initialization.
OPENED=0
for _ in $(seq 1 45); do
  if systemctl is-active --quiet "$UNIT"; then
    if [[ "$PORT" -gt 0 ]] && ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$"; then
      OPENED=1
      break
    fi
  fi
  sleep 1
done

[[ "$OPENED" -eq 1 ]] || {
  journalctl -u "$UNIT" -n 120 --no-pager || true
  die "Server did not open UDP after plugins.ini repair"
}

sleep 5

echo
echo "[6/8] Checking Metamod / AMXX through RCON..."

META_JSON="$("$LIVE_CTL" rcon "$SID" "meta list" 2>&1 || true)"
AMXX_JSON="$("$LIVE_CTL" rcon "$SID" "amxx plugins" 2>&1 || true)"
ZP_JSON="$("$LIVE_CTL" rcon "$SID" "zp_on" 2>&1 || true)"

echo "--- meta list ---"
echo "$META_JSON"
echo "--- amxx plugins ---"
echo "$AMXX_JSON"
echo "--- zp_on ---"
echo "$ZP_JSON"

python3 - "$META_JSON" "$AMXX_JSON" <<'PY'
import json,sys,re

def output(s):
    try:
        d=json.loads(s.strip().splitlines()[-1])
        return str(d.get('output') or '')
    except Exception:
        return s

meta=output(sys.argv[1])
amxx=output(sys.argv[2])

bad_meta=(
    'amxmodx_mm_i386.so\\n' in meta or
    'badf load' in meta.lower() or
    "failed to load plugin 'amxmodx_mm_i386.so" in meta.lower()
)

if bad_meta:
    raise SystemExit("[ERROR] Metamod still reports malformed/bad AMXX loader:\n"+meta)

if 'amx mod x' not in meta.lower() and 'amxmodx' not in meta.lower():
    raise SystemExit("[ERROR] AMXX is not visible in meta list:\n"+meta)

# Do not require every arbitrary third-party plugin to be healthy, but AMXX
# itself must answer and must not be the old 0/69 symptom.
if not amxx.strip():
    raise SystemExit("[ERROR] Empty amxx plugins response")

if re.search(r'\b0\s+plugins?\b',amxx,re.I) or 'unknown command' in amxx.lower():
    raise SystemExit("[ERROR] AMXX still is not operational:\n"+amxx)

print("[OK] Metamod AMXX loader path is clean")
print("[OK] AMXX responds to 'amxx plugins'")
PY

echo
echo "[7/8] Verifying map-pool newline + regexp fixes..."

python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import sys

s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')

checks={
    "managed AMXX writes real newlines":
        "mp.write_text('\\n'.join(output).rstrip()+'\\n',encoding='latin1')" in s,
    "bad managed AMXX literal removed":
        "mp.write_text('\\\\n'.join(output).rstrip()+'\\\\n',encoding='latin1')" not in s,
    "map pool writes real newlines":
        "body='\\n'.join(allowed).rstrip()+'\\n'" in s,
    "bad map literal removed":
        "body='\\\\n'.join(allowed).rstrip()+'\\\\n'" not in s,
    "map whitelist regex is real":
        "[A-Za-z0-9_-]{1,64}" in s,
    "bad doubled regexp removed":
        "[A-Za-z0-9_-]{{1,64}}" not in s,
}

bad=[]
for name,ok in checks.items():
    print(("[OK] " if ok else "[FAIL] ")+name)
    if not ok:
        bad.append(name)

if bad:
    raise SystemExit("[ERROR] source verification failed: "+", ".join(bad))
PY

echo
echo "[8/8] Current service state..."
systemctl --no-pager --full status "$UNIT" | sed -n '1,18p' || true

echo
echo "============================================================"
echo " v3.17 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "Fixed:"
echo " - literal \\n in Metamod plugins.ini"
echo " - future v3.16 AMXX-loader newline generation"
echo " - literal \\n in mapcycle.txt/maps.ini generation"
echo " - map/changelevel whitelist regexp"
echo
echo "Current server #$SID now has a canonical AMXX loader line."
echo "Future assembly uploads use the corrected importer."
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
