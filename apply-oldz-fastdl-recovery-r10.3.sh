#!/usr/bin/env bash
set -Eeuo pipefail

# OLD ZOMBIE FASTDL RECOVERY R10.3
# Fixes stale/corrupt .ztmp resource caches and verifies actual HTTP bytes.

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run with sudo/root"; exit 1; }

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"
ROOT="/srv/hyper-cs16/servers/${SID}"
CS="$ROOT/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/${SID}"
CTL="/usr/local/sbin/hyper-cs16-ctl"
SERVICE="hyper-cs16@${SID}.service"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-r103-backup-${SID}-${STAMP}"
PUBLIC_IP="$(python3 - <<'PYIP'
import json
try:
    d=json.load(open('/etc/hyper-cs16/runtime.json',encoding='utf-8'))
    print(d.get('public_ip') or '90.189.208.25')
except Exception:
    print('90.189.208.25')
PYIP
)"
URL="http://${PUBLIC_IP}/fastdl/${SID}/"

[[ -d "$CS" ]] || { echo "[ERROR] Missing $CS"; exit 2; }
[[ -x "$CTL" ]] || { echo "[ERROR] Missing $CTL"; exit 2; }

mkdir -p "$BACKUP"

echo "================================================================="
echo " OLD ZOMBIE FASTDL RECOVERY R10.3"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo "================================================================="

TIMER_WAS=0
cleanup() {
    if [[ "$TIMER_WAS" -eq 1 ]]; then
        systemctl start hyper-cs16-fastdl-sync.timer >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if systemctl is-active --quiet hyper-cs16-fastdl-sync.timer 2>/dev/null; then
    TIMER_WAS=1
    systemctl stop hyper-cs16-fastdl-sync.timer || true
fi
systemctl stop hyper-cs16-fastdl-sync.service 2>/dev/null || true

echo "[1/9] Checking/recovering VIP and ADMIN player models..."
python3 - "$CS" "$BACKUP" <<'PYMODELS'
from pathlib import Path
import hashlib,shutil,sys,os

cs=Path(sys.argv[1]); backup=Path(sys.argv[2])

expected={
 "models/player/oldz_vip_r8/oldz_vip_r8.mdl":(
   "e37deb0c0b16345f1952899f444736bcf651148513e51d51aac1948c5f3b23b3", 1833392,
   [
    "models/player/oldz_vip_r7/oldz_vip_r7.mdl",
    "models/player/oldz_vip_human/oldz_vip_human.mdl",
    "models/player/oldz_vip_r6/oldz_vip_r6.mdl",
   ]
 ),
 "models/player/oldz_admin_r8/oldz_admin_r8.mdl":(
   "74940223dbbd147f6ba7703a468fbd0aa1d609c3ad156541db0b88f4711e15ae", 2438072,
   [
    "models/player/oldz_admin_r7/oldz_admin_r7.mdl",
    "models/player/oldz_admin_human/oldz_admin_human.mdl",
    "models/player/oldz_admin_r6/oldz_admin_r6.mdl",
   ]
 ),
}

def good(data,sha,size):
    if len(data)!=size: return False
    if not (data[:4] in (b'IDST',b'IDSQ')): return False
    if len(data)<8 or int.from_bytes(data[4:8],'little')!=10: return False
    return hashlib.sha256(data).hexdigest()==sha

for rel,(sha,size,candidates) in expected.items():
    p=cs/rel
    old=p.read_bytes() if p.is_file() else b''
    print(rel, 'size=',len(old),'head=',old[:8], 'sha=',hashlib.sha256(old).hexdigest() if old else 'MISSING')
    if good(old,sha,size):
        print('  [OK] exact model from img(5)')
        continue

    if p.exists():
        b=backup/rel
        b.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(p,b)

    source=None
    for candidate in candidates:
        c=cs/candidate
        if not c.is_file(): continue
        data=c.read_bytes()
        if good(data,sha,size):
            source=c
            break
    if source is None:
        raise SystemExit('[ERROR] target model is corrupt and no identical valid sibling model exists: '+rel)

    p.parent.mkdir(parents=True,exist_ok=True)
    tmp=p.with_name('.'+p.name+'.r103tmp')
    shutil.copy2(source,tmp)
    os.replace(tmp,p)
    print('  [FIXED] restored from',source.relative_to(cs))
PYMODELS

echo "[2/9] Auditing source assets..."
python3 - "$CS" <<'PYAUDIT'
from pathlib import Path
import sys
cs=Path(sys.argv[1])
bad=[]; wav_count=0
for p in cs.rglob('*'):
    if not p.is_file(): continue
    ext=p.suffix.lower()
    if ext not in {'.mdl','.bsp','.spr','.wav','.wad','.tga'}: continue
    try: b=p.read_bytes()[:64]
    except OSError as e:
        bad.append((str(p.relative_to(cs)),'read error '+str(e))); continue
    low=b.lstrip().lower()
    if low.startswith(b'<!doctype') or low.startswith(b'<html'):
        bad.append((str(p.relative_to(cs)),'HTML masquerading as game file')); continue
    if ext=='.mdl' and not (b[:4] in (b'IDST',b'IDSQ') or (len(b)>=4 and int.from_bytes(b[:4],'little')==30)):
        bad.append((str(p.relative_to(cs)),'bad MDL header '+repr(b[:8])))
    elif ext=='.bsp' and (len(b)<4 or int.from_bytes(b[:4],'little')!=30):
        bad.append((str(p.relative_to(cs)),'bad BSP header'))
    elif ext=='.spr' and b[:4]!=b'IDSP':
        bad.append((str(p.relative_to(cs)),'bad SPR header'))
    elif ext=='.wav':
        wav_count+=1
        if not (b[:4]==b'RIFF' and b[8:12]==b'WAVE'):
            bad.append((str(p.relative_to(cs)),'missing RIFF/WAVE header'))
    elif ext=='.wad' and b[:4] not in (b'WAD2',b'WAD3'):
        bad.append((str(p.relative_to(cs)),'bad WAD header'))
if bad:
    print('[ERROR] invalid source assets:')
    for x in bad[:100]: print(' ',x[0],'=>',x[1])
    raise SystemExit(3)
print(f'[OK] source assets valid; WAV checked={wav_count}')
PYAUDIT

echo "[3/9] Rebuilding existing GoldSrc .ztmp compressed files..."
python3 - "$CS" "$BACKUP" <<'PYZTMP'
from pathlib import Path
import bz2,os,shutil,sys

cs=Path(sys.argv[1]); backup=Path(sys.argv[2])
critical=[
 cs/'models/player/oldz_vip_r8/oldz_vip_r8.mdl',
 cs/'models/player/oldz_admin_r8/oldz_admin_r8.mdl',
]
ztmps=set(cs.rglob('*.ztmp'))
for raw in critical:
    ztmps.add(Path(str(raw)+'.ztmp'))

rebuilt=ok=removed=0
for z in sorted(ztmps,key=lambda p:str(p)):
    raw=Path(str(z)[:-5])  # strip .ztmp
    if not raw.is_file():
        if z.is_file():
            b=backup/z.relative_to(cs)
            b.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(z,b)
            z.unlink()
            removed+=1
        continue

    raw_bytes=raw.read_bytes()
    good=False
    if z.is_file():
        try:
            good=(bz2.decompress(z.read_bytes())==raw_bytes)
        except Exception:
            good=False
    if good:
        ok+=1
        continue

    if z.is_file():
        b=backup/z.relative_to(cs)
        b.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(z,b)

    comp=bz2.compress(raw_bytes,compresslevel=9)
    if bz2.decompress(comp)!=raw_bytes:
        raise SystemExit('[ERROR] bzip2 self-check failed: '+str(raw))

    tmp=z.with_name('.'+z.name+'.r103tmp')
    tmp.parent.mkdir(parents=True,exist_ok=True)
    tmp.write_bytes(comp)
    os.replace(tmp,z)
    rebuilt+=1

print(f'[OK] ztmp audit: already_good={ok} rebuilt={rebuilt} orphan_removed={removed}')
PYZTMP

echo "[4/9] Deleting the generated FastDL cache and rebuilding it cleanly..."
rm -rf -- "$FASTDL"
"$CTL" fastdl-sync "$SID"

echo "[5/9] Validating FastDL WAVs, HTML and .ztmp pairs..."
python3 - "$FASTDL" <<'PYFAST'
from pathlib import Path
import bz2,sys
fd=Path(sys.argv[1])
bad=[]; zcount=0; wavcount=0
for p in fd.rglob('*'):
    if not p.is_file(): continue
    b=p.read_bytes()[:64]
    low=b.lstrip().lower()
    if low.startswith(b'<!doctype') or low.startswith(b'<html'):
        bad.append((p.relative_to(fd).as_posix(),'HTML in FastDL')); continue
    if p.suffix.lower()=='.wav':
        wavcount+=1
        if not (b[:4]==b'RIFF' and b[8:12]==b'WAVE'):
            bad.append((p.relative_to(fd).as_posix(),'WAV missing RIFF/WAVE'))

for z in fd.rglob('*.ztmp'):
    zcount+=1
    rel=z.relative_to(fd)
    raw=fd/Path(str(rel)[:-5])
    if not raw.is_file():
        bad.append((rel.as_posix(),'orphan .ztmp')); continue
    try:
        dec=bz2.decompress(z.read_bytes())
    except Exception as e:
        bad.append((rel.as_posix(),'bad bzip2: '+str(e))); continue
    if dec!=raw.read_bytes():
        bad.append((rel.as_posix(),'.ztmp decompresses to different bytes'))

if bad:
    print('[ERROR] FastDL validation failed:')
    for x in bad[:100]: print(' ',x[0],'=>',x[1])
    raise SystemExit(4)
print(f'[OK] FastDL valid; WAV={wavcount} ztmp={zcount}')
PYFAST

echo "[6/9] Verifying VIP/ADMIN models over HTTP byte-for-byte..."
python3 - "$CS" "$PUBLIC_IP" "$SID" <<'PYHTTP'
from pathlib import Path
import subprocess,hashlib,tempfile,sys,bz2,os
cs=Path(sys.argv[1]); ip=sys.argv[2]; sid=sys.argv[3]
rels=[
 'models/player/oldz_vip_r8/oldz_vip_r8.mdl',
 'models/player/oldz_admin_r8/oldz_admin_r8.mdl',
]
for rel in rels:
    src=(cs/rel).read_bytes()
    for suffix in ('','.ztmp'):
        url=f'http://127.0.0.1/fastdl/{sid}/{rel}{suffix}'
        fd,tmp=tempfile.mkstemp(prefix='oldz-http-'); os.close(fd)
        try:
            cp=subprocess.run(['curl','-fsS','-H',f'Host: {ip}','-o',tmp,url],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            if cp.returncode!=0:
                raise SystemExit(f'[ERROR] HTTP failed {url}: {cp.stderr.strip()}')
            got=Path(tmp).read_bytes()
            if suffix:
                try: got=bz2.decompress(got)
                except Exception as e: raise SystemExit(f'[ERROR] HTTP .ztmp invalid bzip2 {rel}: {e}')
            if got!=src:
                raise SystemExit(f'[ERROR] HTTP byte mismatch for {rel}{suffix}')
            print('[OK]',rel+suffix,'sha256='+hashlib.sha256(src).hexdigest())
        finally:
            try: os.unlink(tmp)
            except OSError: pass
PYHTTP

echo "[7/9] Reasserting FastDL config and restarting server..."
python3 - "$CS/server.cfg" "$URL" <<'PYCFG'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); url=sys.argv[2]
s=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
out=[]
for line in s.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\b',line)
    if m and m.group(1).lower() in managed: continue
    out.append(line)
out += [
 '',
 '// HYPER-HOST FASTDL R10.3',
 'sv_allowdownload 1',
 'sv_allowupload 0',
 'sv_send_resources 1',
 'sv_allow_dlfile 0',
 f'sv_downloadurl "{url}"',
]
p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
PYCFG

systemctl restart "$SERVICE"
for _ in $(seq 1 60); do
    systemctl is-active --quiet "$SERVICE" && break
    sleep 1
done
sleep 4

echo "[8/9] Runtime check..."
echo "--- version ---"
"$CTL" rcon "$SID" version 2>/dev/null || true
echo "--- sv_downloadurl ---"
DL="$("$CTL" rcon "$SID" sv_downloadurl 2>/dev/null || true)"
echo "$DL"
if printf '%s' "$DL" | grep -Fq "$URL"; then
    echo "[OK] runtime sv_downloadurl correct"
else
    echo "[WARN] RCON did not confirm sv_downloadurl. server.cfg is correct, but previous fastdl-sync also showed an RCON timeout."
fi

echo "[9/9] Clearing nginx access log for clean client test..."
: > /var/log/nginx/hyper-cs16-fastdl-access.log 2>/dev/null || true

echo
echo "================================================================="
echo " [SUCCESS] OLD ZOMBIE FASTDL RECOVERY R10.3"
echo "================================================================="
echo "Server and FastDL copies of oldz_vip_r8 / oldz_admin_r8 are verified."
echo "Existing .ztmp files were rebuilt when stale or mismatched."
echo "FastDL WAV files were checked for RIFF/WAVE."
echo
echo "IMPORTANT: your CURRENT PC already has corrupt resource files cached."
echo "Run the included Windows client cleanup once before testing again."
echo
echo "Then reconnect and run:"
echo "  grep '/fastdl/${SID}/' /var/log/nginx/hyper-cs16-fastdl-access.log | tail -n 100"
echo
echo "Backup: $BACKUP"
