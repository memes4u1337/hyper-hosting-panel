#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"

CS="/srv/hyper-cs16/servers/$SID/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
CTL="/usr/local/sbin/hyper-cs16-ctl"

OLD="models/oldz_knife_r7/v_gold_wolf_v2.mdl"
NEW="models/oldz_knife_r7/v_gold_wolf_v4.mdl"

NEW_CS="$CS/$NEW"
NEW_FD="$FASTDL/$NEW"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-v2-reference-fix-v57-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$CS" ]] || fail "missing $CS"
[[ -d "$FASTDL" ]] || fail "missing $FASTDL"
[[ -f "$NEW_CS" ]] || fail "working v4 model missing: $NEW_CS"
[[ -x "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP/files"

echo "================================================================"
echo " OLD ZOMBIE V2 REFERENCE FIX v57"
echo " Server: #$SID"
echo " Old: $OLD"
echo " New: $NEW"
echo " Backup: $BACKUP"
echo " No compiler"
echo "================================================================"

echo "[1/6] Verify working v4 model..."
python3 - "$NEW_CS" <<'PY'
from pathlib import Path
import sys,hashlib
p=Path(sys.argv[1])
b=p.read_bytes()
if len(b)<8 or b[:4]!=b'IDST':
    raise SystemExit(f'bad model header: {b[:16]!r}')
ver=int.from_bytes(b[4:8],'little',signed=True)
if ver not in (10,11):
    raise SystemExit(f'bad model version: {ver}')
print('version:',ver)
print('size:',len(b))
print('sha256:',hashlib.sha256(b).hexdigest())
PY

mkdir -p "$(dirname "$NEW_FD")"
cp -a "$NEW_CS" "$NEW_FD"

echo "[2/6] Find EVERY file that still references v2..."
python3 - "$CS" "$OLD" "$BACKUP/references-before.txt" <<'PY'
from pathlib import Path
import sys

root=Path(sys.argv[1])
needle=sys.argv[2].encode()
report=Path(sys.argv[3])

hits=[]
skip={'.mdl','.bsp','.wav','.spr','.wad','.ztmp','.bz2','.zip','.rar','.7z','.so'}

for p in root.rglob('*'):
    if not p.is_file() or p.suffix.lower() in skip:
        continue
    try:
        d=p.read_bytes()
    except Exception:
        continue
    c=d.count(needle)
    if c:
        rel=p.relative_to(root).as_posix()
        hits.append((rel,c,p.suffix.lower()))
        print(f' FOUND: {rel} x{c}')

report.write_text(
    '\n'.join(f'{p}\tcount={c}\text={e}' for p,c,e in hits)+'\n',
    encoding='utf-8'
)
print('reference files:',len(hits))
PY

echo "[3/6] Patch v2 -> v4 in SMA/configs and ALL AMXX recursively..."
python3 - "$CS" "$BACKUP/files" "$OLD" "$NEW" <<'PY'
from pathlib import Path
import shutil,sys

root=Path(sys.argv[1])
backup=Path(sys.argv[2])
old=sys.argv[3]
new=sys.argv[4]

ob=old.encode()
nb=new.encode()

if len(ob)!=len(nb):
    raise SystemExit('old/new byte lengths differ; AMXX binary patch unsafe')

text_ext={
    '.sma','.inc','.cfg','.ini','.res','.txt','.json','.xml',
    '.lst','.list','.conf','.php','.html','.htm','.js','.css'
}

patched=[]

for p in root.rglob('*'):
    if not p.is_file():
        continue
    try:
        data=p.read_bytes()
    except Exception:
        continue

    count=data.count(ob)
    if not count:
        continue

    rel=p.relative_to(root)
    ext=p.suffix.lower()

    if ext=='.amxx':
        dst=backup/rel
        dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(p,dst)

        newdata=data.replace(ob,nb)
        if ob in newdata:
            raise SystemExit(f'old path remains in {rel}')

        tmp=p.with_name('.'+p.name+'.v57tmp')
        tmp.write_bytes(newdata)
        tmp.chmod(p.stat().st_mode)
        tmp.replace(p)

        patched.append((rel.as_posix(),count,'AMXX'))
        continue

    if ext in text_ext:
        dst=backup/rel
        dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(p,dst)

        s=data.decode('utf-8',errors='ignore')
        s=s.replace(old,new)
        p.write_text(s,encoding='utf-8')

        patched.append((rel.as_posix(),count,'TEXT'))
        continue

    print('[WARN] unsupported reference left untouched:',rel)

print('patched files:',len(patched))
for rel,count,kind in patched:
    print(f' PATCHED {kind}: {rel} x{count}')
PY

echo "[4/6] Verify v2 is completely gone from executable/source references..."
python3 - "$CS" "$OLD" "$NEW" <<'PY'
from pathlib import Path
import sys

root=Path(sys.argv[1])
old=sys.argv[2].encode()
new=sys.argv[3].encode()

skip={'.mdl','.bsp','.wav','.spr','.wad','.ztmp','.bz2','.zip','.rar','.7z','.so'}
old_hits=[]
new_hits=[]

for p in root.rglob('*'):
    if not p.is_file() or p.suffix.lower() in skip:
        continue
    try:
        d=p.read_bytes()
    except Exception:
        continue
    if old in d:
        old_hits.append(p.relative_to(root).as_posix())
    if new in d:
        new_hits.append(p.relative_to(root).as_posix())

print('remaining v2 refs:',len(old_hits))
for x in old_hits:
    print(' BAD:',x)

print('v4 refs:',len(new_hits))
for x in new_hits[:100]:
    print(' OK:',x)

if old_hits:
    raise SystemExit('v2 references still remain')
PY

echo "[5/6] Verify FastDL v4 file is valid locally..."
python3 - "$NEW_FD" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
b=p.read_bytes()
if len(b)<8 or b[:4]!=b'IDST':
    raise SystemExit('FastDL v4 file is not IDST')
ver=int.from_bytes(b[4:8],'little',signed=True)
if ver not in (10,11):
    raise SystemExit(f'FastDL v4 version invalid: {ver}')
print('FastDL v4: OK, version',ver,'size',len(b))
PY

echo "[6/6] Restart server and verify..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service" || true

OK=0
STATUS=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    STATUS="$("$CTL" status "$SID" 2>/dev/null || true)"
    if echo "$STATUS" | grep -q '"running":true' \
       && echo "$STATUS" | grep -q '"udp_listening":true' \
       && echo "$STATUS" | grep -q '"query_ok":true'; then
        OK=1
        break
    fi
done

echo "$STATUS"
[[ "$OK" -eq 1 ]] || {
    journalctl -u "hyper-cs16@${SID}.service" -n 160 --no-pager || true
    fail "server not ready"
}

echo "--- recent bad model refs ---"
journalctl -u "hyper-cs16@${SID}.service" --since "-30 seconds" --no-pager \
    | grep -Ei 'v_gold_wolf_v2|wrong version number|Mod_LoadBrushModel' || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE V2 REFERENCE FIX v57"
echo "================================================================"
echo " v2 references: REMOVED"
echo " v4 model: ACTIVE"
echo " AMXX compiler: NOT USED"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " Backup: $BACKUP"
echo "================================================================"
