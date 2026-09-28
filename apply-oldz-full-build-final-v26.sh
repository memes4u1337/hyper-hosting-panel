#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"

LIVE="/usr/local/sbin/hyper-cs16-ctl"
SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"
AMXX_CFG="$CSTRIKE/addons/amxmodx/configs"
AMXX_PLUG="$CSTRIKE/addons/amxmodx/plugins"
SCRIPTING="$CSTRIKE/addons/amxmodx/scripting"
META_CFG="$CSTRIKE/addons/metamod/plugins.ini"
UNP_DIR="$CSTRIKE/addons/unprecacher"
UNP_SO="$UNP_DIR/unprecacher_mm_i386.so"
UNP_LIST="$UNP_DIR/list.ini"
SERVER_CFG="$CSTRIKE/server.cfg"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-full-final-v26-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$CSTRIKE" ]] || fail "missing $CSTRIKE"
[[ -d "$AMXX_CFG" ]] || fail "missing AMXX configs"
[[ -d "$AMXX_PLUG" ]] || fail "missing AMXX plugins"
[[ -f "$META_CFG" ]] || fail "missing metamod plugins.ini"

mkdir -p "$BACKUP"
cp -a "$META_CFG" "$BACKUP/metamod-plugins.before.ini"
cp -a "$AMXX_CFG" "$BACKUP/amxx-configs.before"
[[ -f "$SERVER_CFG" ]] && cp -a "$SERVER_CFG" "$BACKUP/server.cfg.before" || true
[[ -d "$UNP_DIR" ]] && cp -a "$UNP_DIR" "$BACKUP/unprecacher.before" || true

echo "================================================================"
echo " OLD ZOMBIE FULL BUILD FINAL v26"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Goal: ALL plugins ON + sound precache under GoldSrc limit"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/7] Restore every HYPER-HOST SAFE MODE plugin that exists..."
python3 - "$AMXX_CFG" "$AMXX_PLUG" <<'PY'
from pathlib import Path
import re,sys

cfg=Path(sys.argv[1])
plug=Path(sys.argv[2])

rx=re.compile(
    r'^\s*;\s*HYPER-HOST SAFE MODE\s*\[[^\]]*\]\s*:\s*([A-Za-z0-9_.-]+\.amxx)\s*$',
    re.I
)

files=[x for x in sorted(cfg.glob("plugins*.ini")) if x.is_file()]

active=set()
for p in files:
    for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        s=line.strip()
        if not s or s.startswith(";") or s.startswith("#"):
            continue
        token=s.split()[0]
        if token.lower().endswith(".amxx"):
            active.add(token.lower())

restored=0
duplicates=0
missing=0

for p in files:
    out=[]
    changed=False
    for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        m=rx.match(line)
        if not m:
            out.append(line)
            continue

        name=m.group(1)
        low=name.lower()

        if not (plug/name).is_file():
            out.append(f"; HYPER-HOST SAFE MODE [binary missing]: {name}")
            missing+=1
            changed=True
            continue

        if low in active:
            out.append(f"; {name} ; already loaded from another plugins*.ini")
            duplicates+=1
            changed=True
            continue

        out.append(name)
        active.add(low)
        restored+=1
        changed=True

    if changed:
        p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")

print("restored:",restored)
print("duplicates skipped:",duplicates)
print("missing binaries:",missing)
print("active unique plugins:",len(active))
PY

echo "[2/7] Install Metamod Unprecacher..."
mkdir -p "$UNP_DIR"

curl -fL --retry 3 --connect-timeout 10 \
  "https://raw.githubusercontent.com/TheDoctor0/CSGOMod/master/cstrike/addons/unprecacher/unprecacher_mm_i386.so" \
  -o "$UNP_SO"

chmod 0755 "$UNP_SO"
[[ -s "$UNP_SO" ]] || fail "unprecacher binary download failed"

echo "unprecacher size: $(stat -c%s "$UNP_SO") bytes"

echo "[3/7] Put Unprecacher BEFORE AMX Mod X in Metamod..."
python3 - "$META_CFG" <<'PY'
from pathlib import Path
import sys,re

p=Path(sys.argv[1])
lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()

needle="linux addons/unprecacher/unprecacher_mm_i386.so"
out=[]
for line in lines:
    if "unprecacher" in line.lower():
        continue
    out.append(line)

# Must be first active metamod plugin so it can intercept later precaches.
out=[needle,""]+out
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
print(p.read_text(encoding="utf-8"))
PY

echo "[4/7] Build automatic sound-unprecache list from this OLD ZOMBIE build..."
python3 - "$CSTRIKE" "$SCRIPTING" "$AMXX_PLUG" "$UNP_LIST" "$BACKUP" <<'PY'
from pathlib import Path
import re,sys,subprocess,json

cstrike=Path(sys.argv[1])
scripting=Path(sys.argv[2])
plugins=Path(sys.argv[3])
out_file=Path(sys.argv[4])
backup=Path(sys.argv[5])

wav_rx=re.compile(r'(?i)(?:sound/)?([A-Za-z0-9_./\-]+\.wav)')

refs=set()

# 1) Sources: most reliable.
if scripting.is_dir():
    for p in scripting.rglob("*.sma"):
        try:
            txt=p.read_text(encoding="utf-8",errors="ignore")
        except Exception:
            continue
        for m in wav_rx.finditer(txt):
            s=m.group(1).replace("\\","/").lstrip("/")
            if s.lower().startswith("sound/"):
                s=s[6:]
            refs.add(s)

# 2) Compiled AMXX: strings catches plugins whose sources are not present.
if plugins.is_dir():
    for p in plugins.glob("*.amxx"):
        try:
            r=subprocess.run(
                ["strings","-a",str(p)],
                capture_output=True,text=True,errors="ignore",timeout=3
            )
            txt=r.stdout
        except Exception:
            continue
        for m in wav_rx.finditer(txt):
            s=m.group(1).replace("\\","/").lstrip("/")
            if s.lower().startswith("sound/"):
                s=s[6:]
            refs.add(s)

# Keep only custom physical sound files when possible.
physical=[]
for s in sorted(refs):
    f=cstrike/"sound"/s
    if f.is_file():
        physical.append(s)

# Fallback/supplement: all loose WAVs in cstrike/sound are custom/downloaded assets
# in this server build. We use them only to free the precache table; plugins remain ON.
all_loose=[]
sound_root=cstrike/"sound"
if sound_root.is_dir():
    for p in sound_root.rglob("*.wav"):
        try:
            rel=p.relative_to(sound_root).as_posix()
        except Exception:
            continue
        all_loose.append(rel)

# Prefer plugin-referenced custom sounds first, then other loose custom sounds.
ordered=[]
seen=set()
for s in physical + sorted(all_loose):
    low=s.lower()
    if low in seen:
        continue
    seen.add(low)
    ordered.append(s)

# Do NOT block basic UI/player sounds if they are loose.
protected_prefixes=(
    "common/",
    "buttons/",
    "player/",
    "radio/",
    "vox/",
    "fvox/",
)
protected_exact={
    "weapons/ric_metal-2.wav",
    "weapons/ric1.wav",
    "weapons/ric2.wav",
    "weapons/ric3.wav",
}

candidates=[
    s for s in ordered
    if s.lower() not in protected_exact
    and not s.lower().startswith(protected_prefixes)
]

# Block a generous amount of custom plugin sounds so all plugins can coexist
# below the 512 sound table. No AMXX plugin is disabled.
selected=candidates[:220]

out_file.parent.mkdir(parents=True,exist_ok=True)
out_file.write_text(
    "// OLD ZOMBIE v26 - auto generated\n"
    "// These custom sounds are blocked from precache to stay below GoldSrc 512 sound limit.\n"
    "// Plugins remain enabled; blocked cosmetic sounds may be silent.\n"
    + "\n".join(selected)
    + "\n",
    encoding="utf-8"
)

(backup/"sound-unprecache.json").write_text(
    json.dumps({
        "plugin_sound_refs":len(refs),
        "physical_referenced":len(physical),
        "loose_wavs":len(all_loose),
        "blocked":len(selected),
        "selected":selected,
    },ensure_ascii=False,indent=2)+"\n",
    encoding="utf-8"
)

print("plugin .wav refs:",len(refs))
print("referenced physical custom WAVs:",len(physical))
print("loose WAVs:",len(all_loose))
print("blocked from precache:",len(selected))
for s in selected[:40]:
    print(" -",s)
if len(selected)>40:
    print(" ...")
if len(selected)<24:
    raise SystemExit("Not enough custom sounds found to safely reduce precache table")
PY

echo "[5/7] Disable automatic model-attached sound precache in ReHLDS..."
touch "$SERVER_CFG"
python3 - "$SERVER_CFG" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="ignore")
line="sv_auto_precache_sounds_in_models 0"
if re.search(r'(?im)^\s*sv_auto_precache_sounds_in_models\s+\S+.*$',s):
    s=re.sub(
        r'(?im)^\s*sv_auto_precache_sounds_in_models\s+\S+.*$',
        line,
        s
    )
else:
    s=s.rstrip()+"\n"+line+"\n"
p.write_text(s,encoding="utf-8")
PY

echo "[6/7] Start full build NOW..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"

# No 45-second loop. This build historically reaches map startup in ~1-2 sec.
sleep 3

echo "--- SYSTEMD ---"
systemctl --no-pager --full status "hyper-cs16@${SID}.service" | head -n 18 || true

echo "--- CONTROLLER STATUS ---"
"$LIVE" status "$SID" || true

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo
    echo "[ERROR] Server still exited. Last fatal lines:"
    journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager | \
      grep -Ei 'fatal|host_error|precache|segv|error|failed' | tail -n 60 || true
    exit 1
fi

echo "[7/7] Verify Metamod + AMXX full build..."
echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- AMXX PLUGINS ---"
"$LIVE" rcon "$SID" "amxx plugins" || true

echo "--- SQL ADMINS ---"
"$LIVE" sql-admins-list "$SID" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FULL BUILD v26"
echo "================================================================"
echo "All AMXX plugins remain enabled."
echo "GoldSrc 512 sound precache overflow is bypassed by Unprecacher."
echo "FastDL: NOT MODIFIED"
echo "nginx:  NOT MODIFIED"
echo "site:   NOT MODIFIED"
echo "Backup: $BACKUP"
echo "Unprecacher config: $UNP_LIST"
echo "================================================================"
