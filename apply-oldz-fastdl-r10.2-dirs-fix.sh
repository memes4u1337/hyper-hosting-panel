#!/usr/bin/env bash
set -Eeuo pipefail

# OLD ZOMBIE FASTDL R10.2 — FASTDL_DIRS compatibility hotfix
# Fixes: NameError: name 'FASTDL_DIRS' is not defined
# Does NOT modify game resources, plugins or maps.

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run with sudo/root"; exit 1; }

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"
SRC="$REPO/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-r102-backup-${STAMP}"

[[ -f "$SRC" ]] || { echo "[ERROR] Missing $SRC"; exit 2; }
[[ -f "$LIVE" ]] || { echo "[ERROR] Missing $LIVE"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/hyper-cs16-ctl.source"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live"

echo "========================================================"
echo " OLD ZOMBIE FASTDL R10.2"
echo " Fix: FASTDL_DIRS compatibility"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo "========================================================"

TIMER_WAS=0
if systemctl is-active --quiet hyper-cs16-fastdl-sync.timer 2>/dev/null; then
    TIMER_WAS=1
    systemctl stop hyper-cs16-fastdl-sync.timer || true
fi
systemctl stop hyper-cs16-fastdl-sync.service 2>/dev/null || true

echo "[1/5] Patching source/live controllers..."

python3 - "$SRC" "$LIVE" <<'PY'
from pathlib import Path
import ast,sys

FALLBACK="('maps','models','sound','sprites','gfx','resource','overviews','events','media')"

for name in sys.argv[1:]:
    p=Path(name)
    s=p.read_text(encoding='utf-8',errors='surrogateescape')

    # R10/R10.1 fastdl_sync references FASTDL_DIRS.  Newer panel versions
    # replaced the old tuple with FASTDL_RULES, so define one canonical
    # compatibility tuple from the current rules.
    compat=(
        "\n# HYPER-HOST R10.2 FastDL directory compatibility\n"
        "FASTDL_DIRS = tuple(FASTDL_RULES.keys()) if isinstance(globals().get('FASTDL_RULES'), dict) else "
        + FALLBACK + "\n"
    )

    if 'FASTDL_DIRS = tuple(FASTDL_RULES.keys())' not in s:
        # Place immediately before R10 helpers if present; otherwise before fastdl_sync.
        anchors=[
            '\ndef _r10_fastdl_file_error(',
            '\ndef fastdl_sync(',
        ]
        pos=-1
        for a in anchors:
            pos=s.find(a)
            if pos>=0:
                break
        if pos<0:
            raise SystemExit(f'[PATCH ERROR] FastDL function anchor not found in {p}')
        s=s[:pos]+compat+s[pos:]

    # Make the R10 loop self-contained too, so even a later refactor of constants
    # cannot bring the same NameError back.
    old='        for name in FASTDL_DIRS:\n'
    new=(
        "        fastdl_dirs = tuple(FASTDL_RULES.keys()) if "
        "isinstance(globals().get('FASTDL_RULES'), dict) else FASTDL_DIRS\n"
        "        for name in fastdl_dirs:\n"
    )
    if old in s:
        s=s.replace(old,new,1)

    # Verify the resulting Python before replacing the file.
    ast.parse(s,filename=str(p))
    tmp=p.with_name(p.name+'.r102tmp')
    tmp.write_text(s,encoding='utf-8',errors='surrogateescape')
    tmp.chmod(p.stat().st_mode)
    tmp.replace(p)
    print('[OK] patched',p)
PY

echo "[2/5] Syntax validation..."
python3 -m py_compile "$SRC"
python3 -m py_compile "$LIVE"
chmod 0755 "$SRC" "$LIVE"

echo "[3/5] Verifying compatibility definition..."
grep -n "R10.2 FastDL directory compatibility" "$LIVE"
grep -n "fastdl_dirs = tuple(FASTDL_RULES.keys())" "$LIVE" | head -n 3

echo "[4/5] Running a real FastDL sync for server #$SID..."
set +e
SYNC_OUT="$("$LIVE" fastdl-sync "$SID" 2>&1)"
RC=$?
set -e
echo "$SYNC_OUT"

if [[ $RC -ne 0 ]]; then
    echo "[ERROR] FastDL sync still failed."
    exit $RC
fi

echo "[5/5] HTTP verification..."
PUBLIC_IP="$(python3 - <<'PY'
import json
try:
    d=json.load(open('/etc/hyper-cs16/runtime.json',encoding='utf-8'))
    print(d.get('public_ip') or '90.189.208.25')
except Exception:
    print('90.189.208.25')
PY
)"

TEST="/srv/hyper-cs16/fastdl/${SID}/maps/zm_toxic_house.bsp"
if [[ -f "$TEST" ]]; then
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $PUBLIC_IP" \
      "http://127.0.0.1/fastdl/${SID}/maps/zm_toxic_house.bsp" || true)"
    echo "zm_toxic_house.bsp HTTP=$CODE"
    [[ "$CODE" == "200" ]] || { echo "[ERROR] FastDL HTTP map test failed"; exit 4; }
else
    echo "[WARN] zm_toxic_house.bsp is not present in FastDL cache after sync."
fi

if [[ "$TIMER_WAS" -eq 1 ]]; then
    systemctl start hyper-cs16-fastdl-sync.timer || true
fi

echo
echo "========================================================"
echo "[SUCCESS] FASTDL R10.2 FIXED"
echo "FASTDL_DIRS NameError removed."
echo "Real fastdl-sync completed successfully."
echo "Backup: $BACKUP"
echo "========================================================"
