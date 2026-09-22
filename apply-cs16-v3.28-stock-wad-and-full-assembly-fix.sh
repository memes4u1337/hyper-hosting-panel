#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.28 — STOCK WAD + FULL ASSEMBLY INTEGRITY
#
# Targets the concrete failure from the supplied ZM 4.3 assembly:
#   FATAL ERROR: TEX_InitFromWad: halflife.wad isn't a wadfile
#
# It also makes a FULL assembly fail closed before swap if its AMXX plugin list
# collapses to stock AMXX again.  It does NOT rewrite the user's gameplay config.

SID="${1:-25}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
CACHE_ROOT="/var/lib/hyper-cs16/stock-assets"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.28-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.28-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die(){ echo; echo "[ERROR] $*"; echo "[ERROR] Log: $LOG"; echo "[ERROR] Backup: $BACKUP"; exit 1; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; local n; n="$(printf '%s' "$f" | sed 's#^/##;s#/#__#g')"; cp -a "$f" "$BACKUP/$n"; }

[[ "$EUID" -eq 0 ]] || die "Run as root"
[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$STATE" ]] || die "Server state not found: $STATE"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"

grep -q "def install_custom_build" "$LIVE_CTL" || die "install_custom_build missing in live controller"
grep -q "def _v327_resolve_payload" "$LIVE_CTL" || die "v3.27 authoritative importer is not installed in live controller"
grep -q "+full-assembly-v327" "$LIVE_CTL" || die "v3.27 full-assembly marker missing"

backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"
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
echo " HYPER-HOST CS16 v3.28 — STOCK WAD + FULL ASSEMBLY INTEGRITY"
echo "============================================================"
echo "Server:       $SID"
echo "Server path:  $SERVER_PATH"
echo "Live ctl:     $LIVE_CTL"
echo "Repo ctl:     $REPO_CTL"
echo "Stock cache:  $CACHE_ROOT"
echo "Backup:       $BACKUP"
echo "Log:          $LOG"
echo

echo "[1/8] Capturing a VERIFIED stock Valve WAD set from the currently working server/backups..."
mkdir -p "$CACHE_ROOT/valve"
python3 - "$SERVER_PATH" "$CACHE_ROOT" <<'PY'
from __future__ import annotations
import hashlib, os, shutil, struct, sys
from pathlib import Path

server=Path(sys.argv[1])
cache=Path(sys.argv[2])/'valve'
cache.mkdir(parents=True,exist_ok=True)


def wad_ok(p:Path):
    try:
        size=p.stat().st_size
        if size < 12: return False, f'too small ({size})'
        with p.open('rb') as f:
            h=f.read(12)
            magic=h[:4]
            if magic not in (b'WAD2',b'WAD3'): return False, f'bad magic {magic!r}'
            n,ofs=struct.unpack('<ii',h[4:12])
            if n < 0 or n > 200000: return False, f'bad lump count {n}'
            if ofs < 12 or ofs > size: return False, f'bad directory offset {ofs}/{size}'
            if ofs + n*32 > size: return False, f'directory outside file ({n} @ {ofs}, size {size})'
            if n:
                f.seek(ofs)
                for i in range(n):
                    ent=f.read(32)
                    if len(ent)!=32: return False, f'short directory at {i}'
                    pos,disksz,rawsz=struct.unpack('<iii',ent[:12])
                    if pos < 0 or disksz < 0 or rawsz < 0: return False, f'negative lump at {i}'
                    if pos + disksz > size: return False, f'lump {i} outside file'
        return True, f'{magic.decode()} lumps={n} size={size}'
    except Exception as e:
        return False, repr(e)

# Prefer the current server because rollback guarantees it is the known-working tree.
candidates=[]
for p in [server/'valve']:
    if p.is_dir(): candidates.append(p)

# Then latest server build backups and managed bases.
roots=[Path('/srv/hyper-cs16/servers/_build_backups'),Path('/srv/hyper-cs16')]
seen=set()
for root in roots:
    if not root.exists(): continue
    try:
        for p in root.rglob('valve'):
            if not p.is_dir(): continue
            s=str(p)
            if s in seen: continue
            seen.add(s)
            # Current server was already explicitly first.
            if p == server/'valve': continue
            candidates.append(p)
    except OSError:
        pass

# Sort non-current candidates newest first.
first=candidates[:1]
rest=candidates[1:]
rest.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)
candidates=first+rest

copied={}
for d in candidates:
    try:
        wads=sorted(d.glob('*.wad'))
    except OSError:
        continue
    for src in wads:
        name=src.name.lower()
        dst=cache/src.name
        if name in copied: continue
        ok,why=wad_ok(src)
        if not ok: continue
        shutil.copy2(src,dst)
        copied[name]=str(src)

need=('halflife.wad','liquids.wad','xeno.wad')
missing=[]
for name in need:
    matches=[p for p in cache.glob('*.wad') if p.name.lower()==name]
    if not matches:
        missing.append(name); continue
    ok,why=wad_ok(matches[0])
    if not ok: missing.append(name)

print(f'[INFO] cached valid Valve WADs: {len(copied)}')
for name in need:
    p=next((x for x in cache.glob('*.wad') if x.name.lower()==name),None)
    if p:
        ok,why=wad_ok(p)
        sha=hashlib.sha256(p.read_bytes()).hexdigest()
        print(f'[OK] {name}: {why}; sha256={sha}; source={copied.get(name,"existing cache")}')
    else:
        print(f'[MISS] {name}')

if 'halflife.wad' in missing:
    raise SystemExit('[ERROR] No valid halflife.wad donor was found. Refusing to install a build that would crash.')
# liquids/xeno are stock assets used by some supplied maps; require them too.
if any(x in missing for x in ('liquids.wad','xeno.wad')):
    raise SystemExit('[ERROR] Missing required stock Valve WAD(s): '+', '.join(missing))
PY

echo
echo "[2/8] Repairing invalid managed-base stock WAD copies (valid files are untouched)..."
python3 - "$CACHE_ROOT" <<'PY'
from __future__ import annotations
import shutil,struct,sys
from pathlib import Path
cache=Path(sys.argv[1])/'valve'

def ok(p):
    try:
        b=p.read_bytes();
        if len(b)<12 or b[:4] not in (b'WAD2',b'WAD3'): return False
        n,ofs=struct.unpack('<ii',b[4:12])
        return 0<=n<=200000 and 12<=ofs<=len(b) and ofs+n*32<=len(b)
    except Exception: return False

fixed=[]
root=Path('/srv/hyper-cs16')
for target in root.rglob('halflife.wad') if root.exists() else []:
    s=str(target)
    # Do not mutate live servers or their backups here; only managed/shared base trees.
    if '/servers/' in s: continue
    if ok(target): continue
    donor=cache/'halflife.wad'
    if donor.is_file() and ok(donor):
        target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(donor,target); fixed.append(s)
for p in fixed: print('[FIXED BASE]',p)
print('[OK] managed-base invalid halflife.wad repairs:',len(fixed))
PY

PATCHER="$(mktemp /tmp/hh-v328.XXXXXX.py)"
trap 'rm -f "$PATCHER" 2>/dev/null || true' EXIT
cat > "$PATCHER" <<'PY'
from __future__ import annotations
import ast, os, py_compile, re, sys
from pathlib import Path

MARKER='# >>> HYPER-HOST v3.28 STOCK WAD + ASSEMBLY INTEGRITY >>>'
HELPER=r'''
# >>> HYPER-HOST v3.28 STOCK WAD + ASSEMBLY INTEGRITY >>>
def _v328_wad_ok(p:Path)->tuple[bool,str]:
    import struct as _struct
    try:
        size=p.stat().st_size
        if size<12: return False,f'too small ({size})'
        with p.open('rb') as f:
            h=f.read(12); magic=h[:4]
            if magic not in (b'WAD2',b'WAD3'): return False,f'bad magic {magic!r}'
            n,ofs=_struct.unpack('<ii',h[4:12])
            if n<0 or n>200000: return False,f'bad lump count {n}'
            if ofs<12 or ofs>size or ofs+n*32>size: return False,f'bad directory {ofs}+{n}*32 > {size}'
            if n:
                f.seek(ofs)
                for i in range(n):
                    e=f.read(32)
                    if len(e)!=32: return False,f'short dir entry {i}'
                    pos,ds,rs=_struct.unpack('<iii',e[:12])
                    if min(pos,ds,rs)<0 or pos+ds>size: return False,f'bad lump {i}'
        return True,f'{magic.decode()} lumps={n} size={size}'
    except Exception as e:
        return False,repr(e)


def _v328_repair_stock_wads(stage:Path,current_path:Path,base:Path)->dict:
    import shutil as _shutil
    cache=Path('/var/lib/hyper-cs16/stock-assets/valve')
    valve=stage/'valve'; valve.mkdir(parents=True,exist_ok=True)
    actions=[]; sources={}

    # Build donor list in trust order. Cached files are captured only from a
    # structurally valid, previously working server/base by the v3.28 installer.
    donor_dirs=[cache,current_path/'valve',base/'valve']
    for d in donor_dirs:
        if not d.is_dir(): continue
        for src in d.glob('*.wad'):
            good,_=_v328_wad_ok(src)
            if not good: continue
            name=src.name.lower()
            dst=valve/src.name
            dst_good,_=_v328_wad_ok(dst) if dst.exists() else (False,'missing')
            if not dst.exists() or not dst_good:
                _shutil.copy2(src,dst)
                actions.append(('restored' if dst.exists() else 'added')+' valve/'+src.name)
                sources[name]=str(src)

    # These are referenced by the supplied ZM maps and are mandatory stock WADs.
    mandatory=('halflife.wad','liquids.wad','xeno.wad')
    missing=[]
    for name in mandatory:
        p=next((x for x in valve.glob('*.wad') if x.name.lower()==name),valve/name)
        good,why=_v328_wad_ok(p)
        if not good: missing.append(f'{name}: {why}')
    if missing:
        raise RuntimeError('Stock Valve WAD preflight failed: '+'; '.join(missing))

    # Never launch with a corrupt custom WAD either. The supplied archive has 30
    # valid WAD3 files, so corruption here is an importer/storage fault, not a
    # plugin compatibility issue.
    bad_custom=[]
    cs=stage/'cstrike'
    if cs.is_dir():
        for p in sorted(cs.glob('*.wad'),key=lambda x:x.name.lower()):
            good,why=_v328_wad_ok(p)
            if not good: bad_custom.append(f'{p.name}: {why}')
    if bad_custom:
        raise RuntimeError('Custom WAD integrity failed before server start: '+'; '.join(bad_custom[:20]))

    return {'ok':True,'actions':actions,'sources':sources,'mandatory':list(mandatory)}


def _v328_plugin_refs(cstrike:Path)->list[str]:
    cfg=cstrike/'addons/amxmodx/configs'; out=[]; seen=set()
    if not cfg.is_dir(): return out
    for pin in sorted(cfg.glob('plugins*.ini'),key=lambda p:p.name.lower()):
        if not pin.is_file(): continue
        try: lines=pin.read_text(encoding='utf-8',errors='ignore').splitlines()
        except OSError: continue
        for line in lines:
            st=line.strip()
            if not st or st.startswith(';') or st.startswith('//'): continue
            body=st.split(';',1)[0].strip()
            if not body: continue
            tok=body.split()[0]
            if tok.lower().endswith('.amxx') and tok.lower() not in seen:
                seen.add(tok.lower()); out.append(tok)
    return out


def _v328_verify_full_assembly(stage:Path,assembly:dict)->dict:
    if not bool(assembly.get('full_assembly')):
        return {'ok':True,'full':False}
    cs=stage/'cstrike'; refs=_v328_plugin_refs(cs); pd=cs/'addons/amxmodx/plugins'
    files={p.name.lower() for p in pd.glob('*.amxx') if p.is_file()} if pd.is_dir() else set()
    missing=[r for r in refs if Path(r).name.lower() not in files]
    expected=int(assembly.get('archive_plugin_entries') or 0)
    maps=_v327_map_names(cs) if '_v327_map_names' in globals() else [p.stem for p in (cs/'maps').glob('*.bsp')]
    problems=[]
    if expected>=3 and len(refs)<max(3,expected-1):
        problems.append(f'configured plugin list collapsed: archive={expected}, prepared={len(refs)}')
    if missing:
        problems.append('configured AMXX files missing: '+', '.join(missing[:20]))
    if expected>=20 and 'zmpl.amxx' not in {Path(x).name.lower() for x in refs}:
        problems.append('Zombie Plague core zmpl.amxx disappeared from active plugin lists')
    archive_maps=int(assembly.get('archive_playable_maps') or 0)
    if archive_maps>0 and len(maps)<archive_maps:
        problems.append(f'map set collapsed: archive={archive_maps}, prepared={len(maps)}')
    return {'ok':not problems,'full':True,'archive_plugins':expected,'prepared_plugins':len(refs),'missing_plugins':missing,'archive_maps':archive_maps,'prepared_maps':len(maps),'problems':problems}


def _v328_is_benign_ham_memloc(line:str)->bool:
    low=str(line or '').lower()
    return "failed to find memloc for regcmd 'ham'" in low
# <<< HYPER-HOST v3.28 STOCK WAD + ASSEMBLY INTEGRITY <<<
'''


def fn_bounds(src:str,name:str):
    tree=ast.parse(src); lines=src.splitlines(keepends=True)
    nodes=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name]
    if not nodes: return -1,-1,''
    n=nodes[-1]; st=sum(len(x) for x in lines[:n.lineno-1]); en=sum(len(x) for x in lines[:n.end_lineno])
    return st,en,src[st:en]


def patch(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape'); original=src
    if 'def install_custom_build(' not in src: raise RuntimeError(f'{path}: install_custom_build missing')
    if 'def _v327_resolve_payload' not in src: raise RuntimeError(f'{path}: v3.27 resolver missing')

    if MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos<0: raise RuntimeError(f'{path}: helper insertion point missing')
        src=src[:pos]+'\n'+HELPER+src[pos:]

    st,en,fn=fn_bounds(src,'install_custom_build')
    if st<0: raise RuntimeError(f'{path}: install_custom_build parse failed')

    # Always run after v3.27's prepared-tree validation. This is late enough that
    # runtime normalization has populated the stage, but still before production swap/start.
    if 'stock_wad_integrity=_v328_repair_stock_wads(stage,path,base)' not in fn:
        anchor=(
            "        assembly_validation=_v327_validate_prepared_full(stage,partial_payload,detected)\n"
            "        if not assembly_validation.get('ok'):\n"
            "            raise RuntimeError('Full assembly validation failed: '+json.dumps(assembly_validation,ensure_ascii=False))\n"
        )
        if anchor not in fn:
            # Structural fallback: insert immediately after detected profile line.
            alt="        detected=_detect_mod_profile_at(stage)\n"
            if alt not in fn: raise RuntimeError(f'{path}: prepared-tree validation anchor missing')
            block=(
                alt+
                "        stock_wad_integrity=_v328_repair_stock_wads(stage,path,base)\n"
                "        assembly_integrity=_v328_verify_full_assembly(stage,partial_payload)\n"
                "        if not assembly_integrity.get('ok'):\n"
                "            raise RuntimeError('Full assembly integrity failed: '+json.dumps(assembly_integrity,ensure_ascii=False))\n"
            )
            fn=fn.replace(alt,block,1)
        else:
            block=(
                anchor+
                "        stock_wad_integrity=_v328_repair_stock_wads(stage,path,base)\n"
                "        assembly_integrity=_v328_verify_full_assembly(stage,partial_payload)\n"
                "        if not assembly_integrity.get('ok'):\n"
                "            raise RuntimeError('Full assembly integrity failed: '+json.dumps(assembly_integrity,ensure_ascii=False))\n"
            )
            fn=fn.replace(anchor,block,1)

    # Mark successful full imports so the panel clearly shows that v3.28 integrity
    # checks were applied.
    if "+integrity-v328" not in fn:
        anchor="            import_mode=import_mode+'+full-assembly-v327'\n"
        if anchor not in fn: raise RuntimeError(f'{path}: v3.27 import marker anchor missing')
        fn=fn.replace(anchor,anchor+"            import_mode=import_mode+'+integrity-v328'\n",1)

    # Surface diagnostics in JSON result where possible.
    if "'stock_wad_integrity':stock_wad_integrity" not in fn:
        for anchor in ["'assembly_validation':assembly_validation,","'partial_payload':partial_payload,"]:
            if anchor in fn:
                fn=fn.replace(anchor,anchor+"'stock_wad_integrity':stock_wad_integrity,'assembly_integrity':assembly_integrity,",1)
                break

    src=src[:st]+fn+src[en:]

    # The Ham Sandwich memloc line is a long-standing Metamod diagnostic and is
    # not a runtime failure when Ham is actually RUNNING. Keep it in journal, but
    # do not count that exact line as a critical runtime error.
    cst,cen,crit=fn_bounds(src,'_critical_runtime_errors')
    if cst>=0 and '_v328_is_benign_ham_memloc' not in crit:
        lines=crit.splitlines(keepends=True)
        insert=None
        for i,l in enumerate(lines):
            if re.match(r'\s*for\s+ln\s+in\s+lines\s*:',l):
                insert=i+1; indent=re.match(r'(\s*)',l).group(1)+'    '; break
        if insert is not None:
            lines.insert(insert,indent+"if _v328_is_benign_ham_memloc(ln):\n"+indent+"    continue\n")
            crit2=''.join(lines); src=src[:cst]+crit2+src[cen:]

    ast.parse(src)
    tmp=path.with_name(path.name+'.v328tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape'); os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True); os.replace(tmp,path)

    final=path.read_text(encoding='utf-8',errors='surrogateescape'); _,_,fin=fn_bounds(final,'install_custom_build')
    checks={
        'helper':MARKER in final,
        'stock WAD preflight':'stock_wad_integrity=_v328_repair_stock_wads(stage,path,base)' in fin,
        'full assembly integrity':'assembly_integrity=_v328_verify_full_assembly(stage,partial_payload)' in fin,
        'v3.28 import marker':'+integrity-v328' in fin,
        'v3.27 resolver preserved':'payload,layout,partial_payload=_v327_resolve_payload(extract_root,payload,layout)' in fin,
        'v3.27 full marker preserved':'+full-assembly-v327' in fin,
    }
    bad=[k for k,v in checks.items() if not v]
    if bad: raise RuntimeError(f'{path}: verification failed: {bad}')
    return src!=original

for a in sys.argv[1:]:
    p=Path(a); print(('[PATCHED] ' if patch(p) else '[OK already patched] ')+str(p))
PY

echo
echo "[3/8] Patching LIVE controller..."
python3 "$PATCHER" "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller syntax failed"

echo
echo "[4/8] Syncing the verified LIVE controller into the clean GitHub checkout..."
install -m 0755 "$LIVE_CTL" "$REPO_CTL" || die "Could not sync live controller into repository"
python3 -m py_compile "$REPO_CTL" || die "Repository controller syntax failed"

echo
echo "[5/8] Structural verification..."
python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape'); ast.parse(s)
checks={
 'v3.27 resolver kept':'def _v327_resolve_payload' in s,
 'v3.28 WAD validator':'def _v328_wad_ok' in s,
 'v3.28 stage WAD repair':'stock_wad_integrity=_v328_repair_stock_wads(stage,path,base)' in s,
 'v3.28 plugin integrity':'assembly_integrity=_v328_verify_full_assembly(stage,partial_payload)' in s,
 'v3.28 import marker':'+integrity-v328' in s,
}
for k,v in checks.items(): print(('[OK] ' if v else '[FAIL] ')+k)
if not all(checks.values()): raise SystemExit(1)
PY

echo
echo "[6/8] Testing WAD parser against cached halflife.wad..."
python3 - "$CACHE_ROOT/valve/halflife.wad" <<'PY'
import struct,sys
from pathlib import Path
p=Path(sys.argv[1]); b=p.read_bytes(); assert len(b)>=12 and b[:4] in (b'WAD2',b'WAD3')
n,ofs=struct.unpack('<ii',b[4:12]); assert 0<=n<=200000 and 12<=ofs<=len(b) and ofs+n*32<=len(b)
print(f'[OK] {p}: {b[:4].decode()} lumps={n} size={len(b)}')
PY

echo
echo "[7/8] Current server stays intact; resetting any failed unit state..."
systemctl reset-failed "hyper-cs16@${SID}.service" 2>/dev/null || true
if systemctl is-active --quiet "hyper-cs16@${SID}.service"; then
  echo "[OK] current rollback server is active"
else
  echo "[INFO] current rollback server is not active; attempting one normal start"
  systemctl start "hyper-cs16@${SID}.service" 2>/dev/null || true
  sleep 3
  systemctl --no-pager --full status "hyper-cs16@${SID}.service" 2>&1 | tail -35 || true
fi

echo
echo "[8/8] Idempotence check..."
python3 "$PATCHER" "$LIVE_CTL" || die "Repeated v3.28 live patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller invalid after repeated patch"
install -m 0755 "$LIVE_CTL" "$REPO_CTL"

echo
echo "============================================================"
echo " v3.28 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "FIXED: invalid/missing valve/halflife.wad is restored BEFORE a build can be swapped/started."
echo "FIXED: liquids.wad and xeno.wad are preserved for the supplied map pack."
echo "FIXED: corrupt custom cstrike/*.wad files hard-fail before production swap."
echo "FIXED: full ZM assembly plugin lists are verified against real .amxx files before swap."
echo "KEPT: v3.27 authoritative full-assembly resolver and coherent runtime path."
echo "INFO: the exact Ham memloc diagnostic is not treated as a fatal runtime error; it remains in journal."
echo
echo "Now re-upload img-ZM43-v3.28-FINAL.zip to server #$SID."
echo "Expected import contains: +full-assembly-v327+integrity-v328"
echo "It must NOT contain: partial-cstrike-overlay-v325"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
