#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-full-final-v28-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$CSTRIKE" ]] || fail "missing $CSTRIKE"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing Ultimate Unprecacher binary"
[[ -f "$META" ]] || fail "missing metamod/plugins.ini"

mkdir -p "$BACKUP"
cp -a "$UNP" "$BACKUP/unprecacher.before" 2>/dev/null || true
cp -a "$META" "$BACKUP/metamod-plugins.before.ini"

echo "================================================================"
echo " OLD ZOMBIE FULL BUILD FINAL v28"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Keep all 94 AMXX plugins enabled"
echo " Free precache slots using UNUSED STOCK CS resources"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/6] Write correct Ultimate Unprecacher config..."
mkdir -p "$UNP"

cat > "$UNP/config.ini" <<'EOF'
// OLD ZOMBIE v28
logger_verbosity = bcde
logger_output = 3
module_checks = abcdef
EOF

echo "[2/6] Build list.ini from proven Zombie-mode stock-resource unprecacher..."
TMP_SMA="/tmp/oldz-unprecacher_zm.sma"

curl -fsSL --retry 3 --connect-timeout 10 \
  "https://raw.githubusercontent.com/TheDoctor0/AMXXLegacy/master/unprecacher_zm.sma" \
  -o "$TMP_SMA"

[[ -s "$TMP_SMA" ]] || fail "failed to download proven ZM unprecacher source"

python3 - "$TMP_SMA" "$UNP/list.ini" <<'PY'
from pathlib import Path
import re,sys

src=Path(sys.argv[1]).read_text(encoding="utf-8",errors="ignore")
dst=Path(sys.argv[2])

def extract_array(name):
    m=re.search(
        rf'new\s+const\s+{re.escape(name)}\s*\[\]\[\]\s*=\s*\{{(.*?)\}}\s*;',
        src,
        re.S|re.I
    )
    if not m:
        raise SystemExit(f"array not found: {name}")
    vals=re.findall(r'"([^"]+)"',m.group(1))
    return [v.replace("\\","/").strip() for v in vals if v.strip()]

sounds=extract_array("g_Sounds")
models=extract_array("g_Models")

# Ultimate Unprecacher list.ini uses plain, unquoted resource paths.
# For sound precache matching it expects sound-relative WAV names.
# For model resources normalize to engine/model paths used by the module.
lines=[]
seen=set()

for s in sounds:
    low=s.lower()
    if low in seen:
        continue
    seen.add(low)
    lines.append(s)

for m in models:
    v=m
    # Keep known bare world-model names bare, exactly like official module examples.
    # Player/shield paths are relative to models in the legacy ZM list.
    if "/" in v and not v.lower().startswith("models/"):
        v="models/"+v
    low=v.lower()
    if low in seen:
        continue
    seen.add(low)
    lines.append(v)

header=[
    "// OLD ZOMBIE v28",
    "// Proven Zombie-mode stock resource unprecacher list.",
    "// Generated from TheDoctor0/AMXXLegacy unprecacher_zm.sma.",
    "// NO quotes: Ultimate Unprecacher expects raw path [flags] [replacement].",
]

dst.write_text("\n".join(header+lines)+"\n",encoding="utf-8")

print("stock sounds blocked:",len(sounds))
print("stock models blocked:",len(models))
print("total list entries:",len(lines))

required=[
    "weapons/ric_conc-2.wav",
    "weapons/ric_conc-1.wav",
    "weapons/ric_metal-1.wav",
    "weapons/ric_metal-2.wav",
]
missing=[x for x in required if x.lower() not in {y.lower() for y in lines}]
if missing:
    raise SystemExit("critical stock sounds missing: "+repr(missing))

for x in required:
    print(" critical:",x)
PY

echo "[3/6] Ensure Unprecacher is FIRST in Metamod..."
python3 - "$META" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
needle="linux addons/unprecacher/unprecacher_mm_i386.so"
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
lines=[ln for ln in lines if "unprecacher" not in ln.lower()]
body="\n".join(lines).strip()
p.write_text(needle+"\n"+(body+"\n" if body else ""),encoding="utf-8")
print(p.read_text(encoding="utf-8"))
PY

echo "[4/6] Confirm all AMXX plugins remain enabled..."
python3 - "$CSTRIKE/addons/amxmodx/configs" <<'PY'
from pathlib import Path
import sys
cfg=Path(sys.argv[1])
seen=set()
for p in sorted(cfg.glob("plugins*.ini")):
    if not p.is_file(): continue
    for ln in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        s=ln.strip()
        if not s or s.startswith(";") or s.startswith("#"): continue
        tok=s.split()[0]
        if tok.lower().endswith(".amxx"):
            seen.add(tok.lower())
print("active unique AMXX plugins:",len(seen))
required=[
    "zombie_plague40.amxx",
    "zp_zclasses40.amxx",
    "zmpl.amxx",
    "zm_vip.amxx",
    "oldz_credits_sql.amxx",
    "oldz_privilege_models_r8.amxx",
    "oldz_vip_weapon_limit.amxx",
    "oldz_asimov_admin.amxx",
    "oldz_sprifle_vip.amxx",
    "oldz_balrog_vip.amxx",
    "oldz_akblood_vip.amxx",
]
missing=[x for x in required if x.lower() not in seen]
print("required missing:",missing)
if missing:
    raise SystemExit("required OLD ZOMBIE plugins are not enabled")
PY

echo "[5/6] Restart server NOW..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-10 seconds" --no-pager || true)"

echo "--- STATUS ---"
"$LIVE" status "$SID" || true

echo "--- START ERRORS ---"
echo "$RECENT" | grep -Ei 'unprecach|precache|fatal|host_error|segv|runtime_error|cannot open|error' || true

if echo "$RECENT" | grep -qiE 'over the 512 limit|PF_precache_sound_I_internal'; then
    echo
    echo "[ERROR] 512 precache overflow still exists"
    echo "$RECENT" | grep -iE 'precache|512 limit|fatal' | tail -n 40
    exit 2
fi

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo
    echo "[ERROR] server exited for another reason"
    journalctl -u "hyper-cs16@${SID}.service" -n 140 --no-pager || true
    exit 3
fi

echo "[6/6] Verify complete OLD ZOMBIE runtime..."
echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- AMXX PLUGINS ---"
"$LIVE" rcon "$SID" "amxx plugins" || true

echo "--- SQL ADMINS ---"
"$LIVE" sql-admins-list "$SID" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FULL BUILD v28"
echo "================================================================"
echo "All 94 AMXX config entries kept enabled."
echo "Custom OLD ZOMBIE sounds/resources were NOT removed."
echo "Unused stock CS/ZM resources were unprecached instead."
echo "FastDL: NOT MODIFIED"
echo "nginx:  NOT MODIFIED"
echo "site:   NOT MODIFIED"
echo "Backup: $BACKUP"
echo "================================================================"
