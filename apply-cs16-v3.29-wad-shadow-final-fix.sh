#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.29 — STOCK WAD SHADOW FIX
#
# Concrete failure fixed:
#   Custom WAD integrity failed before server start: halflife.wad: bad magic b'<!do'
#
# Root cause:
#   a bogus HTML file named cstrike/halflife.wad shadows the real
#   valve/halflife.wad. v3.28 correctly rejected it, but treated it like a
#   custom WAD instead of removing the invalid stock-name shadow.
#
# v3.29 behavior:
# - stock Valve WADs are sourced only from validated LOCAL WAD2/WAD3 donors;
# - no HTTP download is used;
# - cstrike/{halflife,liquids,xeno}.wad shadows are removed from the staged
#   full assembly before custom-WAD validation;
# - valve/{halflife,liquids,xeno}.wad are verified after repair;
# - all other custom cstrike/*.wad files remain strictly validated;
# - existing v3.27/v3.28 full-assembly/plugin integrity logic is preserved;
# - live controller is patched first, then copied into the current repo checkout.

SID="${1:-25}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
CACHE_ROOT="/var/lib/hyper-cs16/stock-assets"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.29-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.29-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die(){ echo; echo "[ERROR] $*"; echo "[ERROR] Log: $LOG"; echo "[ERROR] Backup: $BACKUP"; exit 1; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; local n; n="$(printf '%s' "$f" | sed 's#^/##;s#/#__#g')"; cp -a "$f" "$BACKUP/$n"; }

[[ "$EUID" -eq 0 ]] || die "Run as root"
[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$STATE" ]] || die "Server state not found: $STATE"
grep -q "def install_custom_build" "$LIVE_CTL" || die "install_custom_build missing in live controller"
grep -q "def _v328_repair_stock_wads" "$LIVE_CTL" || die "v3.28 WAD guard is not installed in live controller"
grep -q "def _v327_resolve_payload" "$LIVE_CTL" || die "v3.27 authoritative importer is not installed in live controller"

backup_file "$LIVE_CTL"
[[ -f "$REPO_CTL" ]] && backup_file "$REPO_CTL"
cp -a "$STATE" "$BACKUP/server-state.json"

SERVER_PATH="$(python3 - "$STATE" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
print(str(d.get('path') or f"/srv/hyper-cs16/servers/{d.get('id','')}"))
PY
)"
[[ -d "$SERVER_PATH" ]] || die "Current server path does not exist: $SERVER_PATH"

echo "============================================================"
echo " HYPER-HOST CS16 v3.29 — STOCK WAD SHADOW FINAL FIX"
echo "============================================================"
echo "Server:       $SID"
echo "Server path:  $SERVER_PATH"
echo "Live ctl:     $LIVE_CTL"
echo "Repo ctl:     $REPO_CTL"
echo "Stock cache:  $CACHE_ROOT"
echo "Backup:       $BACKUP"
echo "Log:          $LOG"
echo

echo "[1/7] Verifying LOCAL stock WAD donors and quarantining invalid cstrike shadows..."
mkdir -p "$CACHE_ROOT/valve" "$BACKUP/wad-shadows"
python3 - "$SERVER_PATH" "$CACHE_ROOT" "$BACKUP/wad-shadows" <<'PY'
from __future__ import annotations
import hashlib, shutil, struct, sys
from pathlib import Path

server=Path(sys.argv[1]); cache=Path(sys.argv[2])/'valve'; qroot=Path(sys.argv[3])
cache.mkdir(parents=True,exist_ok=True); qroot.mkdir(parents=True,exist_ok=True)
mandatory=('halflife.wad','liquids.wad','xeno.wad')

def wad_ok(p:Path):
    try:
        size=p.stat().st_size
        if size<12: return False,f'too small ({size})'
        with p.open('rb') as f:
            h=f.read(12); magic=h[:4]
            if magic not in (b'WAD2',b'WAD3'): return False,f'bad magic {magic!r}'
            n,ofs=struct.unpack('<ii',h[4:12])
            if n<0 or n>200000: return False,f'bad lump count {n}'
            if ofs<12 or ofs>size or ofs+n*32>size: return False,f'bad directory {ofs}+{n}*32 > {size}'
            f.seek(ofs)
            for i in range(n):
                e=f.read(32)
                if len(e)!=32: return False,f'short dir entry {i}'
                pos,ds,rs=struct.unpack('<iii',e[:12])
                if min(pos,ds,rs)<0 or pos+ds>size: return False,f'bad lump {i}'
        return True,f'{magic.decode()} lumps={n} size={size}'
    except Exception as e:
        return False,repr(e)

# Valid donor search: LOCAL valve directories only. Never HTTP and never cstrike.
roots=[server/'valve', cache, Path('/srv/hyper-cs16/servers/_build_backups'), Path('/srv/hyper-cs16')]
for name in mandatory:
    current=cache/name
    ok,why=wad_ok(current) if current.is_file() else (False,'missing')
    if not ok:
        candidates=[]
        for root in roots:
            if not root.exists(): continue
            if root.is_dir() and root.name.lower()=='valve':
                p=next((x for x in root.iterdir() if x.is_file() and x.name.lower()==name),None)
                if p: candidates.append(p)
                continue
            try:
                for p in root.rglob(name):
                    if not p.is_file(): continue
                    # Only real valve/<name>, never cstrike/<name> or a web/cache artifact.
                    if p.parent.name.lower()!='valve': continue
                    candidates.append(p)
            except OSError:
                pass
        # Current server first, then newest local files.
        def rank(p:Path):
            current_server = 0 if str(p).startswith(str(server/'valve')) else 1
            try: mt=-p.stat().st_mtime
            except OSError: mt=0
            return (current_server,mt,str(p))
        candidates=sorted(dict.fromkeys(candidates),key=rank)
        donor=None
        for p in candidates:
            good,_=wad_ok(p)
            if good:
                donor=p; break
        if donor is None:
            raise SystemExit(f'[ERROR] No valid LOCAL donor for {name}; refusing any network/html substitute')
        shutil.copy2(donor,current)
        print(f'[CACHE] {name} <- {donor}')
    good,why=wad_ok(current)
    if not good: raise SystemExit(f'[ERROR] cached {name} invalid after repair: {why}')
    print(f'[OK] cache/{name}: {why}; sha256={hashlib.sha256(current.read_bytes()).hexdigest()}')

# Quarantine only INVALID stock-name shadows from persistent cstrike trees.
# The staged importer will purge all stock-name shadows every time.
root=Path('/srv/hyper-cs16')
quarantined=[]
if root.exists():
    for p in root.rglob('*.wad'):
        try:
            if not p.is_file() or p.name.lower() not in mandatory: continue
            if p.parent.name.lower()!='cstrike': continue
            # Keep backups immutable.
            if '/servers/_build_backups/' in str(p): continue
            good,why=wad_ok(p)
            if good: continue
            rel=str(p).lstrip('/').replace('/','__')
            dst=qroot/rel
            dst.parent.mkdir(parents=True,exist_ok=True)
            shutil.move(str(p),str(dst))
            quarantined.append((str(p),why,str(dst)))
        except OSError:
            pass
for p,why,d in quarantined:
    print(f'[QUARANTINE] {p}: {why} -> {d}')
print(f'[OK] invalid persistent cstrike stock-WAD shadows quarantined: {len(quarantined)}')
PY

PATCHER="$(mktemp /tmp/hh-v329.XXXXXX.py)"
trap 'rm -f "$PATCHER" 2>/dev/null || true' EXIT
cat > "$PATCHER" <<'PY'
from __future__ import annotations
import ast, os, py_compile, re, sys
from pathlib import Path

MARKER='# >>> HYPER-HOST v3.29 STOCK WAD SHADOW FIX >>>'
NEW_FN=r'''def _v328_repair_stock_wads(stage:Path,current_path:Path,base:Path)->dict:
    # HYPER-HOST v3.29: stock WADs belong to valve/. A file named
    # cstrike/halflife.wad (especially an HTML error page beginning with <!do)
    # shadows the real Valve asset and crashes GoldSrc. Purge those stock-name
    # shadows before validating genuine custom cstrike WADs.
    import shutil as _shutil
    cache=Path('/var/lib/hyper-cs16/stock-assets/valve')
    valve=stage/'valve'; valve.mkdir(parents=True,exist_ok=True)
    cs=stage/'cstrike'; cs.mkdir(parents=True,exist_ok=True)
    mandatory=('halflife.wad','liquids.wad','xeno.wad')
    actions=[]; sources={}; purged=[]

    # LOCAL, validated donors only. No web fetch is ever accepted here.
    donor_dirs=[cache,current_path/'valve',base/'valve']
    for name in mandatory:
        donor=None
        for d in donor_dirs:
            if not d.is_dir(): continue
            try:
                matches=sorted([p for p in d.iterdir() if p.is_file() and p.name.lower()==name],key=lambda p:p.name.lower())
            except OSError:
                matches=[]
            for p in matches:
                good,_=_v328_wad_ok(p)
                if good:
                    donor=p; break
            if donor is not None: break
        if donor is None:
            raise RuntimeError('No valid LOCAL stock Valve WAD donor for '+name)

        # Remove case variants in valve/ so lookup is deterministic, then write
        # one canonical lower-case file from the validated donor.
        try:
            for p in list(valve.iterdir()):
                if p.is_file() and p.name.lower()==name and p.name!=name:
                    p.unlink(); actions.append('removed valve case-variant '+p.name)
        except OSError:
            pass
        dst=valve/name
        dst_good,_=_v328_wad_ok(dst) if dst.exists() else (False,'missing')
        same=False
        try:
            same=dst.exists() and donor.resolve()==dst.resolve()
        except Exception:
            same=False
        if not dst_good or not same:
            if not same:
                _shutil.copy2(donor,dst)
            actions.append('ensured valve/'+name)
            sources[name]=str(donor)

    # Critical v3.29 fix: stock-name WADs must never sit in cstrike/ for this
    # assembly. The supplied img archive does not contain these files; they are
    # inherited contamination from a managed/base tree and can shadow valve/.
    try:
        for p in list(cs.iterdir()):
            if p.is_file() and p.name.lower() in mandatory:
                purged.append(p.name)
                p.unlink()
                actions.append('purged cstrike stock-WAD shadow '+p.name)
    except OSError:
        pass

    missing=[]
    for name in mandatory:
        p=valve/name
        good,why=_v328_wad_ok(p)
        if not good: missing.append(f'{name}: {why}')
    if missing:
        raise RuntimeError('Stock Valve WAD preflight failed after v3.29 repair: '+'; '.join(missing))

    # Strict validation remains for ACTUAL custom WADs from the assembly.
    bad_custom=[]
    try:
        custom=sorted(cs.glob('*.wad'),key=lambda x:x.name.lower())
    except OSError:
        custom=[]
    for p in custom:
        good,why=_v328_wad_ok(p)
        if not good: bad_custom.append(f'{p.name}: {why}')
    if bad_custom:
        raise RuntimeError('Custom WAD integrity failed before server start: '+'; '.join(bad_custom[:20]))

    return {
        'ok':True,
        'actions':actions,
        'sources':sources,
        'mandatory':list(mandatory),
        'purged_cstrike_stock_wads':purged,
        'policy':'v329-local-valve-only-no-stock-shadow',
    }
'''

def fn_bounds(src:str,name:str):
    tree=ast.parse(src); lines=src.splitlines(keepends=True)
    nodes=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name]
    if not nodes: return -1,-1,''
    n=nodes[-1]; st=sum(len(x) for x in lines[:n.lineno-1]); en=sum(len(x) for x in lines[:n.end_lineno])
    return st,en,src[st:en]

def patch(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape'); original=src
    if 'def _v328_wad_ok' not in src: raise RuntimeError(f'{path}: v3.28 WAD validator missing')
    if 'def _v328_repair_stock_wads' not in src: raise RuntimeError(f'{path}: v3.28 WAD repair helper missing')
    if 'def install_custom_build(' not in src: raise RuntimeError(f'{path}: install_custom_build missing')

    st,en,_=fn_bounds(src,'_v328_repair_stock_wads')
    if st<0: raise RuntimeError(f'{path}: could not locate v3.28 WAD helper')
    tail=src[en:].lstrip('\n')
    src=src[:st]+NEW_FN.rstrip()+'\n\n'+tail

    # Marker is kept outside the function so a repeated run is easy to verify.
    if MARKER not in src:
        pos=src.find('\ndef _v328_repair_stock_wads')
        if pos<0: raise RuntimeError(f'{path}: marker insertion point missing')
        src=src[:pos]+'\n'+MARKER+'\n'+src[pos:]

    st,en,fn=fn_bounds(src,'install_custom_build')
    if st<0: raise RuntimeError(f'{path}: install_custom_build parse failed')
    marker="            import_mode=import_mode+'+wad-shadow-v329'\n"
    if marker not in fn:
        anchor="            import_mode=import_mode+'+integrity-v328'\n"
        if anchor in fn:
            fn=fn.replace(anchor,anchor+marker,1)
        else:
            # Do not risk patching an unknown flow. v3.28 must be present here.
            raise RuntimeError(f'{path}: v3.28 import marker anchor missing')
    src=src[:st]+fn+src[en:]

    ast.parse(src)
    tmp=path.with_name(path.name+'.v329tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape'); os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True); os.replace(tmp,path)

    final=path.read_text(encoding='utf-8',errors='surrogateescape')
    _,_,wadfn=fn_bounds(final,'_v328_repair_stock_wads'); _,_,inst=fn_bounds(final,'install_custom_build')
    checks={
        'v3.29 marker':MARKER in final,
        'purges cstrike stock shadows':"purged cstrike stock-WAD shadow" in wadfn,
        'local donor only':"No valid LOCAL stock Valve WAD donor" in wadfn,
        'strict custom WAD validation':"Custom WAD integrity failed before server start" in wadfn,
        'v3.29 import marker':'+wad-shadow-v329' in inst,
        'v3.28 integrity preserved':'+integrity-v328' in inst,
        'v3.27 full assembly preserved':'+full-assembly-v327' in inst,
    }
    bad=[k for k,v in checks.items() if not v]
    if bad: raise RuntimeError(f'{path}: verification failed: {bad}')
    return src!=original

for a in sys.argv[1:]:
    p=Path(a); print(('[PATCHED] ' if patch(p) else '[OK already patched] ')+str(p))
PY

echo
echo "[2/7] Patching LIVE controller..."
python3 "$PATCHER" "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller syntax failed"

echo
echo "[3/7] Running the exact <!doctype html> regression test against the patched helper..."
python3 - "$LIVE_CTL" <<'PY'
from __future__ import annotations
import ast, tempfile, struct, sys
from pathlib import Path

src=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
tree=ast.parse(src)
want={'_v328_wad_ok','_v328_repair_stock_wads'}
nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in want]
if {n.name for n in nodes}!=want: raise SystemExit('[FAIL] helper extraction failed')
mod=ast.Module(body=nodes,type_ignores=[]); ast.fix_missing_locations(mod)
ns={'Path':Path}; exec(compile(mod,'<v329-test>','exec'),ns)
wad_ok=ns['_v328_wad_ok']; repair=ns['_v328_repair_stock_wads']

def valid_wad(p:Path):
    # Structurally valid empty WAD3 is enough to exercise the path logic.
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes(b'WAD3'+struct.pack('<ii',0,12))

with tempfile.TemporaryDirectory(prefix='hh-v329-regression-') as td:
    root=Path(td); stage=root/'stage'; current=root/'current'; base=root/'base'
    cache=Path('/var/lib/hyper-cs16/stock-assets/valve')
    # The real function uses the host cache. It was validated in step 1.
    (stage/'cstrike').mkdir(parents=True); (stage/'valve').mkdir(parents=True)
    # Reproduce the exact user failure.
    (stage/'cstrike/halflife.wad').write_bytes(b'<!doctype html><html>bad gateway</html>')
    result=repair(stage,current,base)
    shadow=stage/'cstrike/halflife.wad'
    if shadow.exists(): raise SystemExit('[FAIL] HTML cstrike/halflife.wad shadow survived')
    ok,why=wad_ok(stage/'valve/halflife.wad')
    if not ok: raise SystemExit('[FAIL] valve/halflife.wad invalid: '+why)
    if 'halflife.wad' not in [x.lower() for x in result.get('purged_cstrike_stock_wads',[])]:
        raise SystemExit('[FAIL] purge was not reported')
    print('[OK] exact regression: HTML cstrike/halflife.wad was purged')
    print('[OK] canonical valve/halflife.wad remains valid:',why)

    # Ensure the fix does not weaken custom-WAD validation.
    (stage/'cstrike/evil_custom.wad').write_bytes(b'<!doctype html>')
    try:
        repair(stage,current,base)
    except RuntimeError as e:
        if 'Custom WAD integrity failed' not in str(e): raise
        print('[OK] unrelated corrupt custom WAD still hard-fails')
    else:
        raise SystemExit('[FAIL] corrupt custom WAD was incorrectly accepted')
PY

echo
echo "[4/7] Structural verification..."
python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape'); ast.parse(s)
checks={
 'v3.27 authoritative resolver':'def _v327_resolve_payload' in s,
 'v3.28 plugin integrity':'def _v328_verify_full_assembly' in s,
 'v3.29 WAD shadow policy':'v329-local-valve-only-no-stock-shadow' in s,
 'v3.29 import marker':'+wad-shadow-v329' in s,
}
for k,v in checks.items(): print(('[OK] ' if v else '[FAIL] ')+k)
if not all(checks.values()): raise SystemExit(1)
PY

echo
echo "[5/7] Syncing patched LIVE controller into current repository checkout..."
if [[ -d "$REPO/cs16-panel/bin" ]]; then
  install -m 0755 "$LIVE_CTL" "$REPO_CTL" || die "Could not sync controller into repo checkout"
  python3 -m py_compile "$REPO_CTL" || die "Repository controller syntax failed"
  echo "[OK] repo controller synced from verified live controller"
else
  echo "[WARN] repo controller directory not present; live controller is patched"
fi

echo
echo "[6/7] Resetting failed unit state; keeping the rollback server intact..."
systemctl reset-failed "hyper-cs16@${SID}.service" 2>/dev/null || true
if systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
  echo "[OK] rollback server is active"
else
  systemctl start "hyper-cs16@${SID}.service" 2>/dev/null || true
  sleep 3
  if systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
    echo "[OK] rollback server started"
  else
    echo "[WARN] rollback server is not active; no destructive change was made by v3.29"
    systemctl --no-pager --full status "hyper-cs16@${SID}.service" 2>&1 | tail -30 || true
  fi
fi

echo
echo "[7/7] Idempotence check..."
python3 "$PATCHER" "$LIVE_CTL" || die "Repeated v3.29 live patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller invalid after repeated patch"
if [[ -d "$REPO/cs16-panel/bin" ]]; then install -m 0755 "$LIVE_CTL" "$REPO_CTL"; fi

echo
echo "============================================================"
echo " v3.29 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "FIXED: HTML/error-page files named cstrike/halflife.wad can no longer shadow valve/halflife.wad."
echo "FIXED: stock Valve WADs are accepted only from validated LOCAL WAD2/WAD3 donors."
echo "FIXED: stage/cstrike/{halflife,liquids,xeno}.wad is purged before custom-WAD validation."
echo "KEPT: all other cstrike/*.wad files remain strictly validated."
echo "KEPT: v3.27 full-assembly detection and v3.28 AMXX/plugin integrity checks."
echo "EXPECTED IMPORT: +full-assembly-v327+integrity-v328+wad-shadow-v329"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
