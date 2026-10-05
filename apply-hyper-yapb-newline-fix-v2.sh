#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
ROOT="/srv/hyper-cs16/servers/${SID}/cstrike"
META="$ROOT/addons/metamod/plugins.ini"
LIVE="/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-yapb-newline-fix-${STAMP}"

mkdir -p "$BACKUP"

echo "============================================================"
echo " HYPER YaPB/METAMOD NEWLINE FIX"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo "============================================================"

[[ $EUID -eq 0 ]] || { echo "[ERROR] Run as root"; exit 1; }
[[ -f "$LIVE" ]] || { echo "[ERROR] Missing $LIVE"; exit 2; }

cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.bak"
[[ -f "$META" ]] && cp -a "$META" "$BACKUP/plugins.ini.bak"

echo "[1/5] Fix controller bug that writes literal \\n into plugins.ini..."

python3 - "$LIVE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8", errors="strict")
orig = s

# Previous YaPB toggle patch accidentally generated Python code using '\\n'
# as literal backslash+n instead of real newline. Fix all known variants.
repls = [
    (
        "p.write_text('\\\\n'.join(out_lines).rstrip()+'\\\\n',encoding='utf-8')",
        "p.write_text('\\n'.join(out_lines).rstrip()+'\\n',encoding='utf-8')",
    ),
    (
        'p.write_text("\\\\n".join(out_lines).rstrip()+"\\\\n",encoding="utf-8")',
        'p.write_text("\\n".join(out_lines).rstrip()+"\\n",encoding="utf-8")',
    ),
]

for bad, good in repls:
    s = s.replace(bad, good)

if s == orig:
    # Generic safety pass only around write_text/join lines.
    lines = s.splitlines()
    changed = False
    for i, line in enumerate(lines):
        if "write_text" in line and "join(out_lines)" in line and "\\\\n" in line:
            lines[i] = line.replace("'\\\\n'.join", "'\\n'.join").replace("+\'\\\\n\'", "+'\\n'")
            lines[i] = lines[i].replace('"\\\\n".join', '"\\n".join').replace('+"\\\\n"', '+"\\n"')
            changed = changed or lines[i] != line
    if changed:
        s = "\n".join(lines) + ("\n" if orig.endswith("\n") else "")

if s == orig:
    print("[INFO] No buggy write_text pattern found; controller may already be fixed.")
else:
    compile(s, str(p), "exec")
    p.write_text(s, encoding="utf-8")
    print("[OK] Controller newline bug patched.")
PY

chmod 0755 "$LIVE"
python3 -m py_compile "$LIVE"

echo "[2/5] Rebuild Metamod plugins.ini with REAL newlines..."

cat > "$META" <<'EOF'
linux addons/unprecacher/unprecacher_mm_i386.so
linux addons/reunion/reunion_mm_i386.so
linux addons/amxmodx/dlls/amxmodx_mm_i386.so
linux addons/yapb/bin/yapb.so
EOF

chown cs16:www-data "$META" 2>/dev/null || true
chmod 0664 "$META"

echo "--- plugins.ini ---"
cat -A "$META"

if grep -Fq '\nlinux' "$META"; then
    echo "[ERROR] plugins.ini still contains literal \\n"
    exit 3
fi

echo "[3/5] Keep YaPB settings directly in its cfg..."
YBCFG="$ROOT/addons/yapb/conf/yapb.cfg"
if [[ -f "$YBCFG" ]]; then
    python3 - "$YBCFG" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="ignore")
vals={
    "yb_quota":"12",
    "yb_quota_mode":"fill",
    "yb_join_after_player":"0",
    "yb_join_delay":"2.0",
    "yb_difficulty":"4",
    "yb_autovacate":"1",
}
for k,v in vals.items():
    pat=re.compile(r"(?m)^\s*"+re.escape(k)+r"\s+.*$")
    line=f'{k} "{v}"'
    if pat.search(s):
        s=pat.sub(line,s,count=1)
    else:
        s += "\n"+line
p.write_text(s.rstrip()+"\n",encoding="utf-8")
PY
fi

echo "[4/5] Restart once WITHOUT bots-enable first..."
systemctl stop "hyper-cs16@${SID}.service" || true
systemctl reset-failed "hyper-cs16@${SID}.service" || true
systemctl start "hyper-cs16@${SID}.service"
sleep 3

echo "--- runtime load ---"
journalctl -u "hyper-cs16@${SID}.service" --since "-1 minute" --no-pager | \
grep -Ei 'Found [0-9]+ plugins to load|Loaded plugin .Reunion|Loaded plugin .AMX Mod X|Loaded plugin .YaPB|PF_precache|512 limit|FATAL|Host_Error' || true

echo "[5/5] Test patched bots-enable (it must NOT corrupt plugins.ini)..."
"$LIVE" bots-enable "$SID" --quota 12 --difficulty 4 || true
sleep 2

echo "--- plugins.ini AFTER bots-enable ---"
cat -A "$META"

if grep -Fq '\nlinux' "$META"; then
    echo
    echo "[ERROR] bots-enable STILL corrupted plugins.ini."
    echo "Restoring correct file and restarting without bots-enable."
    cat > "$META" <<'EOF'
linux addons/unprecacher/unprecacher_mm_i386.so
linux addons/reunion/reunion_mm_i386.so
linux addons/amxmodx/dlls/amxmodx_mm_i386.so
linux addons/yapb/bin/yapb.so
EOF
    systemctl restart "hyper-cs16@${SID}.service"
    exit 4
fi

echo
echo "--- FINAL STATUS ---"
systemctl --no-pager --full status "hyper-cs16@${SID}.service" | head -n 18 || true
echo
echo "--- FINAL ERRORS ---"
journalctl -u "hyper-cs16@${SID}.service" --since "-2 minutes" --no-pager | \
grep -Ei 'PF_precache|512 limit|FATAL|Host_Error|unknown function|failed to load' | tail -n 40 || true

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
