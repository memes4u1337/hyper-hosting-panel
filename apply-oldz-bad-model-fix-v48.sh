#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
MODELS="$CSTRIKE/models"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-bad-model-fix-v48-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$MODELS" ]] || fail "missing $MODELS"
[[ -x "$LIVE" ]] || fail "missing $LIVE"

mkdir -p "$BACKUP/models"

echo "================================================================"
echo " OLD ZOMBIE BAD MODEL CLIENT FIX v48"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Only broken .mdl files are replaced"
echo "================================================================"

echo "[1/5] Find valid fallback models..."
python3 - "$CSTRIKE" "$BACKUP/fallbacks.env" <<'PY'
from pathlib import Path
import sys,shlex

c=Path(sys.argv[1])
out=Path(sys.argv[2])

def valid_studio(p:Path):
    try:
        b=p.read_bytes()[:8]
    except Exception:
        return False
    return len(b)>=8 and b[:4]==b'IDST' and int.from_bytes(b[4:8],'little',signed=True) in (10,11)

preferred={
    'V': c/'models/v_knife.mdl',
    'P': c/'models/p_knife.mdl',
    'W': c/'models/w_knife.mdl',
}

all_valid=[]
for p in (c/'models').rglob('*.mdl'):
    if valid_studio(p):
        all_valid.append(p)

if not all_valid:
    raise SystemExit('No valid IDST studio model found for fallback')

generic=all_valid[0]
vals={}
for k,p in preferred.items():
    vals[k]=p if p.is_file() and valid_studio(p) else generic

for k,p in vals.items():
    print(k, p)
    if not valid_studio(p):
        raise SystemExit(f'invalid fallback {k}: {p}')

out.write_text(
    '\n'.join(f'{k}_FALLBACK={shlex.quote(str(v))}' for k,v in vals.items())+'\n',
    encoding='utf-8'
)
PY

# shellcheck disable=SC1090
source "$BACKUP/fallbacks.env"

echo "[2/5] Replace ONLY corrupt/non-studio .mdl files..."
python3 - "$CSTRIKE" "$BACKUP/models" "$V_FALLBACK" "$P_FALLBACK" "$W_FALLBACK" "$BACKUP/report.txt" <<'PY'
from pathlib import Path
import shutil,sys

c=Path(sys.argv[1])
backup=Path(sys.argv[2])
fallbacks={'v':Path(sys.argv[3]),'p':Path(sys.argv[4]),'w':Path(sys.argv[5])}
report=Path(sys.argv[6])

def studio_info(p:Path):
    try:
        b=p.read_bytes()[:8]
    except Exception:
        return False,None,None
    if len(b)<8:
        return False,b,None
    magic=b[:4]
    ver=int.from_bytes(b[4:8],'little',signed=True)
    return magic==b'IDST' and ver in (10,11),magic,ver

bad=[]
for p in sorted((c/'models').rglob('*.mdl')):
    ok,magic,ver=studio_info(p)
    if ok:
        continue

    rel=p.relative_to(c)
    name=p.name.lower()
    kind='v' if name.startswith('v_') else ('p' if name.startswith('p_') else ('w' if name.startswith('w_') else 'v'))
    fb=fallbacks[kind]

    dst_backup=backup/rel
    dst_backup.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(p,dst_backup)
    shutil.copy2(fb,p)

    ok2,_,_=studio_info(p)
    if not ok2:
        raise SystemExit(f'fallback replacement still invalid: {rel}')

    bad.append((rel.as_posix(),repr(magic),ver,fb.relative_to(c).as_posix()))

lines=[f'{rel}\tmagic={magic}\tversion={ver}\tfallback={fb}' for rel,magic,ver,fb in bad]
report.write_text('\n'.join(lines)+'\n',encoding='utf-8')

print('broken models replaced:',len(bad))
for row in bad:
    print(' FIXED:',row[0],'->',row[3])

target=c/'models/oldz_knife_r7/v_gold_wolf.mdl'
if target.exists():
    ok,magic,ver=studio_info(target)
    print('v_gold_wolf:', 'OK' if ok else 'BAD', magic, ver)
    if not ok:
        raise SystemExit('v_gold_wolf.mdl is still invalid')
PY

echo "[3/5] Verify there are no broken .mdl files left..."
python3 - "$CSTRIKE" <<'PY'
from pathlib import Path
import sys

root=Path(sys.argv[1])/'models'
bad=[]
count=0

for p in root.rglob('*.mdl'):
    count+=1
    try:
        b=p.read_bytes()[:8]
    except Exception as e:
        bad.append((p,str(e)))
        continue
    if len(b)<8 or b[:4]!=b'IDST' or int.from_bytes(b[4:8],'little',signed=True) not in (10,11):
        bad.append((p,f'head={b!r}'))

print('models checked:',count)
print('invalid models:',len(bad))
for p,why in bad[:50]:
    print(' BAD:',p,why)

if bad:
    raise SystemExit('invalid .mdl files remain')
PY

echo "[4/5] Rebuild FastDL from corrected server files..."
if "$LIVE" --help 2>&1 | grep -q 'fastdl-clean'; then
    "$LIVE" fastdl-clean "$SID"
fi
"$LIVE" fastdl-sync "$SID"

echo "[5/5] Restart server and verify..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"

OK=0
STATUS=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    STATUS="$("$LIVE" status "$SID" 2>/dev/null || true)"
    if echo "$STATUS" | grep -q '"running":true' \
       && echo "$STATUS" | grep -q '"udp_listening":true' \
       && echo "$STATUS" | grep -q '"query_ok":true'; then
        OK=1
        break
    fi
done

echo "$STATUS"

if [[ "$OK" -ne 1 ]]; then
    echo "[ERROR] server did not become ready"
    journalctl -u "hyper-cs16@${SID}.service" -n 160 --no-pager || true
    exit 20
fi

RECENT="$(journalctl -u "hyper-cs16@${SID}.service" --since "-30 seconds" --no-pager || true)"
if echo "$RECENT" | grep -qiE 'wrong version number|Mod_LoadBrushModel|PF_precache.*512 limit'; then
    echo "[ERROR] resource/precache error still present"
    echo "$RECENT" | grep -Ei 'wrong version number|Mod_LoadBrushModel|PF_precache|512 limit|FATAL ERROR' | tail -n 50
    exit 21
fi

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE BAD MODEL FIX v48"
echo "================================================================"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " Broken MDL files: REPLACED"
echo " FastDL: REBUILT"
echo " Original broken files: $BACKUP/models"
echo " Report: $BACKUP/report.txt"
echo "================================================================"
