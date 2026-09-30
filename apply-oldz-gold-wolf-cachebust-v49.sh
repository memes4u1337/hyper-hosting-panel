#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CS="/srv/hyper-cs16/servers/$SID/cstrike"
AMXX="$CS/addons/amxmodx"
SCRIPTING="$AMXX/scripting"
PLUGINS="$AMXX/plugins"
OLD_REL="models/oldz_knife_r7/v_gold_wolf.mdl"
NEW_REL="models/oldz_knife_r7/v_gold_wolf_v2.mdl"
OLD="$CS/$OLD_REL"
NEW="$CS/$NEW_REL"
CTL="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-gold-wolf-cachebust-v49-${STAMP}"
EXPORT="/root/oldz-gold-wolf-cachebust-export-v49"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$OLD" ]] || fail "missing source model: $OLD"
[[ -d "$SCRIPTING" ]] || fail "missing $SCRIPTING"
[[ -d "$PLUGINS" ]] || fail "missing $PLUGINS"
[[ -x "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP" "$EXPORT"
rm -rf "$EXPORT"/*
mkdir -p "$EXPORT/models/oldz_knife_r7" "$EXPORT/plugins" "$EXPORT/scripting"

echo "================================================================"
echo " OLD ZOMBIE GOLD WOLF CACHE-BUST v49"
echo " Server: #$SID"
echo " Old: $OLD_REL"
echo " New: $NEW_REL"
echo " Backup: $BACKUP"
echo "================================================================"

echo "[1/7] Validate current fixed model and create v2..."
python3 - "$OLD" "$NEW" "$EXPORT/models/oldz_knife_r7/v_gold_wolf_v2.mdl" <<'PY'
from pathlib import Path
import shutil,sys,hashlib

src=Path(sys.argv[1]); dst=Path(sys.argv[2]); exp=Path(sys.argv[3])
b=src.read_bytes()

if len(b)<8 or b[:4]!=b'IDST':
    raise SystemExit('source model is not IDST')
ver=int.from_bytes(b[4:8],'little',signed=True)
if ver not in (10,11):
    raise SystemExit(f'bad model version: {ver}')

dst.parent.mkdir(parents=True,exist_ok=True)
shutil.copy2(src,dst)
exp.parent.mkdir(parents=True,exist_ok=True)
shutil.copy2(src,exp)

b2=dst.read_bytes()
if b2!=b:
    raise SystemExit('v2 model copy verification failed')

print('model: OK')
print('version:',ver)
print('size:',len(b))
print('sha256:',hashlib.sha256(b).hexdigest())
PY

echo "[2/7] Find every SMA that references old model..."
mapfile -t SMA_FILES < <(grep -RIl --include='*.sma' -F "$OLD_REL" "$SCRIPTING" 2>/dev/null || true)

echo "SMA references: ${#SMA_FILES[@]}"
printf ' %s\n' "${SMA_FILES[@]:-}"

if [[ "${#SMA_FILES[@]}" -eq 0 ]]; then
    echo "[WARN] No SMA source references found. Will inspect compiled AMXX strings."
fi

echo "[3/7] Find every compiled AMXX that references old model..."
mapfile -t AMXX_FILES < <(
    find "$PLUGINS" -maxdepth 1 -type f -name '*.amxx' -print0 |
    while IFS= read -r -d '' f; do
        if strings -a "$f" 2>/dev/null | grep -Fq "$OLD_REL"; then
            printf '%s\n' "$f"
        fi
    done
)

echo "AMXX references: ${#AMXX_FILES[@]}"
printf ' %s\n' "${AMXX_FILES[@]:-}"

if [[ "${#SMA_FILES[@]}" -eq 0 && "${#AMXX_FILES[@]}" -eq 0 ]]; then
    fail "No plugin references $OLD_REL; refusing to guess"
fi

echo "[4/7] Patch SMA sources..."
for f in "${SMA_FILES[@]}"; do
    rel="${f#$AMXX/}"
    mkdir -p "$BACKUP/$(dirname "$rel")"
    cp -a "$f" "$BACKUP/$rel"

    python3 - "$f" "$OLD_REL" "$NEW_REL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); old=sys.argv[2]; new=sys.argv[3]
s=p.read_text(encoding='utf-8',errors='ignore')
n=s.count(old)
if n<1:
    raise SystemExit('reference disappeared from '+str(p))
s=s.replace(old,new)
p.write_text(s,encoding='utf-8')
print('patched',p,'occurrences=',n)
PY

    cp -a "$f" "$EXPORT/scripting/$(basename "$f")"
done

echo "[5/7] Compile patched SMA and replace matching plugin(s)..."
COMPILER=""
for c in "$SCRIPTING/amxxpc" "$SCRIPTING/amxxpc32"; do
    if [[ -x "$c" ]]; then COMPILER="$c"; break; fi
done
[[ -n "$COMPILER" ]] || fail "AMXX compiler not found"

COMPILED=0

for f in "${SMA_FILES[@]}"; do
    base="$(basename "$f" .sma)"
    out="/tmp/${base}.v49.amxx"

    (
        cd "$SCRIPTING"
        "$COMPILER" "$(basename "$f")" -o"$out"
    )

    [[ -s "$out" ]] || fail "compile failed: $f"

    # Prefer same-name plugin. If the compiled plugin reference scan found a
    # different target name, handle it below.
    target="$PLUGINS/${base}.amxx"
    if [[ -f "$target" ]]; then
        cp -a "$target" "$BACKUP/$(basename "$target").before"
        install -m 0644 "$out" "$target"
        cp -a "$out" "$EXPORT/plugins/$(basename "$target")"
        echo " installed: $target"
        COMPILED=$((COMPILED+1))
    fi
done

# If an AMXX contains the old path but no matching SMA basename was installed,
# try to map it to a source by basename. Never binary-patch .amxx.
for target in "${AMXX_FILES[@]}"; do
    name="$(basename "$target" .amxx)"
    if [[ -f "$EXPORT/plugins/${name}.amxx" ]]; then
        continue
    fi
    src="$SCRIPTING/${name}.sma"
    if [[ -f "$src" ]]; then
        # If source exists but did not have the literal old path, it may build
        # the path from macros; do not guess.
        if grep -Fq "$OLD_REL" "$src"; then
            :
        else
            echo "[WARN] $target references old model but $src does not contain literal path; left unchanged"
        fi
    else
        echo "[WARN] compiled plugin has no source: $target"
        cp -a "$target" "$EXPORT/plugins/$(basename "$target").OLD_UNPATCHED"
    fi
done

[[ "$COMPILED" -gt 0 ]] || fail "No live plugin was safely recompiled/replaced"

echo "[6/7] Prove old path is gone from installed patched plugin(s)..."
BAD=0
for f in "$EXPORT/plugins"/*.amxx; do
    [[ -f "$f" ]] || continue
    if strings -a "$f" | grep -Fq "$OLD_REL"; then
        echo "[ERROR] old path still in $f"
        BAD=1
    fi
    if ! strings -a "$f" | grep -Fq "$NEW_REL"; then
        echo "[ERROR] new path missing from $f"
        BAD=1
    fi
done
[[ "$BAD" -eq 0 ]] || fail "plugin verification failed"

echo "[7/7] Sync FastDL, restart and build export archive..."
"$CTL" fastdl-sync "$SID" || true

systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"

sleep 5
"$CTL" status "$SID" || true

# Verify HTTP new model if FastDL is reachable.
PUBLIC_IP="$(python3 - <<'PY'
import json
try:
    d=json.load(open('/etc/hyper-cs16/runtime.json',encoding='utf-8'))
    print(d.get('public_ip') or '90.189.208.25')
except Exception:
    print('90.189.208.25')
PY
)"
URL="http://${PUBLIC_IP}/fastdl/${SID}/${NEW_REL}"

TMP="/tmp/oldz-v49-model.$$"
if curl -fsS "$URL" -o "$TMP"; then
    MAGIC="$(dd if="$TMP" bs=1 count=4 status=none 2>/dev/null || true)"
    [[ "$MAGIC" == "IDST" ]] || fail "FastDL new model is not raw IDST"
    echo "FastDL new model: OK $URL"
else
    echo "[WARN] Could not HTTP-verify $URL"
fi
rm -f "$TMP"

cat > "$EXPORT/README.txt" <<EOF
OLD ZOMBIE cache-bust v49

Install model:
  cstrike/$NEW_REL

Patched plugins:
  cstrike/addons/amxmodx/plugins/

Patched sources:
  cstrike/addons/amxmodx/scripting/

Old cached path is no longer referenced by patched plugins:
  $OLD_REL

New path:
  $NEW_REL
EOF

tar -C "$(dirname "$EXPORT")" -czf "/root/oldz-gold-wolf-cachebust-export-v49.tar.gz" "$(basename "$EXPORT")"

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE GOLD WOLF CACHE-BUST v49"
echo "================================================================"
echo " New model: $NEW_REL"
echo " Export folder: $EXPORT"
echo " Export archive: /root/oldz-gold-wolf-cachebust-export-v49.tar.gz"
echo " Old client cache path is no longer used by patched plugin(s)."
echo "================================================================"
