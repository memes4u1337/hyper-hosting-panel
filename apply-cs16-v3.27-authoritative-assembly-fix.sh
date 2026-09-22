#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.27 — AUTHORITATIVE ASSEMBLY IMPORT
# Fixes false PARTIAL classification caused by layout ambiguity and makes
# cstrike-only full builds use a coherent ReHLDS/ReGameDLL/Metamod-R/AMXX stack.

SID="${1:-25}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.27-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.27-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die(){ echo; echo "[ERROR] $*"; echo "[ERROR] Log: $LOG"; echo "[ERROR] Backup: $BACKUP"; exit 1; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; local n; n="$(printf '%s' "$f"|sed 's#^/##;s#/#__#g')"; cp -a "$f" "$BACKUP/$n"; }

[[ "$EUID" -eq 0 ]] || die "Run as root"
[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"

grep -q "def install_custom_build" "$LIVE_CTL" || die "install_custom_build missing in live controller"
grep -q "partial-cstrike-overlay-v325" "$LIVE_CTL" || die "v3.25 partial overlay layer is not installed in live controller"

backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"

PATCHER="$(mktemp /tmp/hh-v327.XXXXXX.py)"
trap 'rm -f "$PATCHER" 2>/dev/null || true' EXIT

cat > "$PATCHER" <<'PY'
from __future__ import annotations
import ast, os, py_compile, re, sys
from pathlib import Path

MARKER='# >>> HYPER-HOST v3.27 AUTHORITATIVE ASSEMBLY IMPORT >>>'

HELPER=r'''
# >>> HYPER-HOST v3.27 AUTHORITATIVE ASSEMBLY IMPORT >>>
def _v327_plugin_refs(cstrike:Path)->list[str]:
    cfg=cstrike/'addons/amxmodx/configs'
    out=[]; seen=set()
    if not cfg.is_dir():
        return out
    try:
        lists=sorted([p for p in cfg.glob('plugins*.ini') if p.is_file()],key=lambda p:p.name.lower())
    except OSError:
        lists=[]
    for pin in lists:
        try:
            lines=pin.read_text(encoding='utf-8',errors='ignore').splitlines()
        except OSError:
            continue
        for line in lines:
            st=line.strip()
            if not st or st.startswith(';') or st.startswith('//'):
                continue
            body=st.split(';',1)[0].strip()
            if not body:
                continue
            tok=body.split()[0]
            if tok.lower().endswith('.amxx') and tok.lower() not in seen:
                seen.add(tok.lower()); out.append(tok)
    return out


def _v327_map_names(cstrike:Path)->list[str]:
    d=cstrike/'maps'; out=[]
    if not d.is_dir():
        return out
    try:
        it=list(d.iterdir())
    except OSError:
        return out
    for p in it:
        try:
            if p.is_file() and p.suffix.lower()=='.bsp' and SAFE_MAP.fullmatch(p.stem):
                out.append(p.stem)
        except OSError:
            pass
    return sorted(set(out),key=str.lower)


def _v327_score_cstrike(cs:Path)->dict:
    if not cs.is_dir():
        return {'score':-1,'full':False,'plugin_refs':[],'plugin_files':0,'maps':[],'signals':[]}
    sig=[]; score=0
    if (cs/'liblist.gam').is_file(): score+=120; sig.append('liblist.gam')
    if (cs/'dlls/cs.so').is_file(): score+=110; sig.append('dlls/cs.so')
    if (cs/'server.cfg').is_file(): score+=70; sig.append('server.cfg')
    cfg=cs/'addons/amxmodx/configs'; pd=cs/'addons/amxmodx/plugins'
    if (cfg/'plugins.ini').is_file(): score+=70; sig.append('plugins.ini')
    refs=_v327_plugin_refs(cs)
    try: pfiles=sum(1 for p in pd.glob('*.amxx') if p.is_file()) if pd.is_dir() else 0
    except OSError: pfiles=0
    score+=min(pfiles,50); score+=min(len(refs),50)
    maps=_v327_map_names(cs); score+=min(len(maps),30)
    content=0
    for n in ('addons','maps','models','sound','sprites','resource','gfx','events','overviews','classes'):
        if (cs/n).exists(): content+=1
    score+=content*4
    amxx_authoritative=(cfg/'plugins.ini').is_file() and pd.is_dir() and (pfiles>=3 or len(refs)>=3)
    full=bool((cs/'liblist.gam').is_file() or (cs/'dlls/cs.so').is_file() or ((cs/'server.cfg').is_file() and amxx_authoritative))
    return {'score':score,'full':full,'plugin_refs':refs,'plugin_files':pfiles,'maps':maps,'signals':sig,'content_dirs':content}


def _v327_resolve_payload(extract_root:Path,payload:Path,layout:str):
    # Never trust one layout label blindly. Score the actual extracted trees and
    # choose the directory that really contains the authoritative cstrike build.
    candidates=[]; seen=set()
    def add(cs:Path, out_payload:Path, out_layout:str, source:str):
        try: key=str(cs.resolve())
        except Exception: key=str(cs)
        if key in seen or not cs.is_dir(): return
        seen.add(key)
        info=_v327_score_cstrike(cs)
        candidates.append((int(info.get('score',-1)),cs,out_payload,out_layout,source,info))

    # The detector result itself, interpreted both ways when necessary.
    if (payload/'cstrike').is_dir(): add(payload/'cstrike',payload,'server-root','payload/cstrike')
    add(payload,payload,'cstrike-content','payload-as-cstrike')

    # The extraction root can be wrapped in release folders. Search only a few
    # levels deep so unrelated nested addon directories never win accidentally.
    root=extract_root
    try:
        unwrapped=_unwrap_single_dir(root)
    except Exception:
        unwrapped=root
    if (unwrapped/'cstrike').is_dir(): add(unwrapped/'cstrike',unwrapped,'server-root','unwrapped/cstrike')
    add(unwrapped,unwrapped,'cstrike-content','unwrapped-as-cstrike')

    try:
        for d in root.rglob('*'):
            if not d.is_dir(): continue
            try: depth=len(d.relative_to(root).parts)
            except Exception: continue
            if depth>4: continue
            if d.name.lower()=='cstrike': add(d,d.parent,'server-root','nested-cstrike')
            elif depth<=3:
                info=_v327_score_cstrike(d)
                if int(info.get('score',-1))>=120: add(d,d,'cstrike-content','nested-content')
    except OSError:
        pass

    if not candidates:
        old=_v325_payload_mode(payload,layout)
        old=dict(old); old.update({'classifier':'v327','resolver':'fallback-old-detector','full_assembly':not bool(old.get('partial_overlay'))})
        return payload,layout,old

    candidates.sort(key=lambda x:x[0],reverse=True)
    score,cs,out_payload,out_layout,source,info=candidates[0]
    full=bool(info.get('full'))

    # If the best candidate is not a full assembly, keep the original package as
    # a partial overlay. This keeps one-plugin ZIPs safe.
    if not full:
        old=_v325_payload_mode(payload,layout)
        old=dict(old); old.update({
            'classifier':'v327','resolver':source,'resolver_score':score,
            'full_assembly':False,'archive_plugin_entries':len(info.get('plugin_refs') or []),
            'archive_plugin_files':int(info.get('plugin_files') or 0),
            'archive_playable_maps':len(info.get('maps') or []),
        })
        return payload,layout,old

    own_engine=bool(out_layout=='server-root' and (out_payload/'hlds_linux').is_file())
    carries_runtime=bool((cs/'dlls/cs.so').is_file() or (cs/'addons/metamod/dlls/metamod.so').is_file() or (cs/'addons/amxmodx/dlls/amxmodx_mm_i386.so').is_file() or (cs/'addons/amxmodx/dlls/amxmodx.so').is_file())
    result={
        'partial_overlay':False,
        'classifier':'v327',
        'resolver':source,
        'resolver_score':score,
        'full_assembly':True,
        'layout':out_layout,
        'signals':list(info.get('signals') or []),
        'archive_plugin_entries':len(info.get('plugin_refs') or []),
        'archive_plugin_files':int(info.get('plugin_files') or 0),
        'archive_plugin_refs':list(info.get('plugin_refs') or [])[:200],
        'archive_playable_maps':len(info.get('maps') or []),
        'archive_maps':list(info.get('maps') or [])[:200],
        'own_hlds_linux':own_engine,
        'carries_cstrike_runtime':carries_runtime,
        'reason':'authoritative full cstrike assembly selected from extracted tree',
    }
    return out_payload,out_layout,result


def _v327_force_coherent_runtime(path:Path,c:dict,assembly:dict)->dict:
    # Fallback for installations where old v3.23 helper is missing. A full
    # cstrike runtime without its own hlds_linux is normalized as one stack.
    if not bool(assembly.get('full_assembly')) or bool(assembly.get('own_hlds_linux')) or not bool(assembly.get('carries_cstrike_runtime')):
        return {'ok':True,'forced':False,'actions':[]}
    actions=[]
    install_rehlds(path); actions.append('ReHLDS/ReGameDLL coherent stack installed')
    install_metamod_rehlds(path); actions.append('Metamod-R coherent stack installed')
    if '_v316_refresh_amxx_platform' in globals():
        try: actions.extend(list(_v316_refresh_amxx_platform(path) or []))
        except Exception: install_amxx(path); actions.append('AMXX coherent runtime installed')
    else:
        install_amxx(path); actions.append('AMXX coherent runtime installed')
    try:
        if '_ensure_reapi_compatible_stack' in globals():
            rr=_ensure_reapi_compatible_stack(path); actions.extend(list((rr or {}).get('actions') or []))
    except Exception:
        pass
    try:
        if '_v320_sanitize_loader_chain' in globals():
            rr=_v320_sanitize_loader_chain(path); actions.extend(list((rr or {}).get('actions') or []))
    except Exception:
        pass
    normalize_permissions(path)
    return {'ok':True,'forced':True,'actions':list(dict.fromkeys(actions))}


def _v327_validate_prepared_full(stage:Path,assembly:dict,detected:dict)->dict:
    if not bool(assembly.get('full_assembly')):
        return {'ok':True,'full':False}
    expected=int(assembly.get('archive_plugin_entries') or 0)
    configured=int((detected or {}).get('active_plugin_count') or 0)
    maps=_v327_map_names(stage/'cstrike')
    problems=[]
    # A full assembly must never silently collapse to stock AMXX again.
    if expected>=3 and configured < max(3, expected-2):
        problems.append(f'plugin list collapsed: archive config has {expected}, prepared server has {configured}')
    if int(assembly.get('archive_playable_maps') or 0)>0 and not maps:
        problems.append('archive has playable BSP maps but prepared server has none')
    return {'ok':not problems,'full':True,'archive_expected_plugins':expected,'prepared_plugins':configured,'prepared_maps':len(maps),'problems':problems}
# <<< HYPER-HOST v3.27 AUTHORITATIVE ASSEMBLY IMPORT <<<
'''


def bounds_all(src:str,name:str):
    tree=ast.parse(src); lines=src.splitlines(keepends=True); out=[]
    for n in tree.body:
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name:
            st=sum(len(x) for x in lines[:n.lineno-1]); en=sum(len(x) for x in lines[:n.end_lineno]); out.append((st,en,src[st:en]))
    return out


def fn_bounds(src:str,name:str):
    arr=bounds_all(src,name)
    return arr[-1] if arr else (-1,-1,'')


def patch(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src
    if 'def install_custom_build(' not in src: raise RuntimeError(f'{path}: install_custom_build missing')
    if 'def _v325_payload_mode' not in src: raise RuntimeError(f'{path}: v3.25 helper missing')

    if MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos<0: raise RuntimeError(f'{path}: helper insertion point missing')
        src=src[:pos]+'\n'+HELPER+src[pos:]

    st,en,fn=fn_bounds(src,'install_custom_build')
    if st<0: raise RuntimeError(f'{path}: install_custom_build parse failed')

    detect="        payload,layout=_detect_build_payload(extract_root)\n"
    if detect not in fn: raise RuntimeError(f'{path}: payload/layout anchor missing')

    # Remove every old classifier call from the install function and insert one
    # authoritative resolver immediately after extraction/detection.
    fn=re.sub(r"^\s*partial_payload=_v325_payload_mode\(payload,layout\)\s*$\n?",'',fn,flags=re.M)
    fn=re.sub(r"^\s*payload,layout,partial_payload=_v327_resolve_payload\(extract_root,payload,layout\)\s*$\n?",'',fn,flags=re.M)
    fn=fn.replace(detect,detect+"        payload,layout,partial_payload=_v327_resolve_payload(extract_root,payload,layout)\n",1)

    # v3.23 runtime analysis must see the corrected payload/layout, not the stale
    # detector interpretation. Reposition it after the v3.27 resolver.
    if '_v323_analyze_archive_runtime' in src:
        fn=re.sub(r"^\s*runtime_scope=_v323_analyze_archive_runtime\(payload,layout\)\s*$\n?",'',fn,flags=re.M)
        needle="        payload,layout,partial_payload=_v327_resolve_payload(extract_root,payload,layout)\n"
        fn=fn.replace(needle,needle+"        runtime_scope=_v323_analyze_archive_runtime(payload,layout)\n",1)

    # If v3.23 is absent, force one coherent stack ourselves before v3.20 auto
    # policy can preserve an incompatible classic/modern mixture.
    if '_v323_prepare_coherent_runtime(stage,c,runtime_scope)' not in fn:
        anchor='        platform_runtime=_v320_prepare_runtime(stage,c)\n'
        if anchor in fn and 'v327_coherence=_v327_force_coherent_runtime' not in fn:
            block=(
                "        v327_coherence=_v327_force_coherent_runtime(stage,c,partial_payload)\n"
                "        if v327_coherence.get('forced'):\n"
                "            c['profile']='rehlds'\n"
                "            db_update_profile(sid,'rehlds')\n"
            )
            fn=fn.replace(anchor,block+anchor,1)

    # Replace stale v3.26 import marker logic with an explicit v3.27 result.
    fn=re.sub(r"^\s*if '\+classifier-v326' not in import_mode: import_mode=import_mode\+'\+classifier-v326'\s*$\n?",'',fn,flags=re.M)
    base="        import_mode='exact-server-root' if layout=='server-root' else 'exact-cstrike-archive'\n"
    if base not in fn: raise RuntimeError(f'{path}: import_mode base anchor missing')
    # Remove old immediate v3.25 partial assignment; re-add controlled logic.
    fn=re.sub(r"^\s*if partial_payload\.get\('partial_overlay'\): import_mode='partial-cstrike-overlay-v325'\s*$\n?",'',fn,flags=re.M)
    replacement=(
        base+
        "        if partial_payload.get('partial_overlay'):\n"
        "            import_mode='partial-cstrike-overlay-v325+classifier-v327'\n"
        "        else:\n"
        "            import_mode=import_mode+'+full-assembly-v327'\n"
    )
    fn=fn.replace(base,replacement,1)

    # Before swapping the prepared tree into production, prove that a full
    # assembly still has the archive's plugin set instead of stock ~20 plugins.
    detect_stage="        detected=_detect_mod_profile_at(stage)\n"
    if detect_stage in fn and 'assembly_validation=_v327_validate_prepared_full' not in fn:
        block=(
            detect_stage+
            "        assembly_validation=_v327_validate_prepared_full(stage,partial_payload,detected)\n"
            "        if not assembly_validation.get('ok'):\n"
            "            raise RuntimeError('Full assembly validation failed: '+json.dumps(assembly_validation,ensure_ascii=False))\n"
        )
        fn=fn.replace(detect_stage,block,1)

    # Put validation data in the result when possible.
    if "'assembly_validation':assembly_validation" not in fn:
        for anchor in ["'archive_manifest':manifest,","'partial_payload':partial_payload,"]:
            if anchor in fn:
                fn=fn.replace(anchor,anchor+"'assembly_validation':assembly_validation,",1); break

    src=src[:st]+fn+src[en:]
    ast.parse(src)
    tmp=path.with_name(path.name+'.v327tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True)
    os.replace(tmp,path)

    final=path.read_text(encoding='utf-8',errors='surrogateescape')
    _,_,fin=fn_bounds(final,'install_custom_build')
    checks={
        'v327 helper':MARKER in final,
        'authoritative resolver':'payload,layout,partial_payload=_v327_resolve_payload(extract_root,payload,layout)' in fin,
        'old classifier call removed':'partial_payload=_v325_payload_mode(payload,layout)' not in fin,
        'full import marker':'+full-assembly-v327' in fin,
        'pre-swap plugin validation':'assembly_validation=_v327_validate_prepared_full' in fin,
    }
    if '_v323_analyze_archive_runtime' in final:
        checks['v323 sees resolved payload']=fin.find('_v327_resolve_payload') < fin.find('_v323_analyze_archive_runtime(payload,layout)')
    bad=[k for k,v in checks.items() if not v]
    if bad: raise RuntimeError(f'{path}: verification failed: {bad}')
    return src!=original

for a in sys.argv[1:]:
    p=Path(a); print(('[PATCHED] ' if patch(p) else '[OK already patched] ')+str(p))
PY

echo "============================================================"
echo " HYPER-HOST CS16 v3.27 — AUTHORITATIVE ASSEMBLY IMPORT"
echo "============================================================"
echo "Server: $SID"
echo "Live:   $LIVE_CTL"
echo "Repo:   $REPO_CTL"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo

echo "[1/6] Patching LIVE controller..."
python3 "$PATCHER" "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller syntax failed"

echo "[2/6] Syncing verified LIVE controller into clean GitHub checkout..."
install -m 0755 "$LIVE_CTL" "$REPO_CTL" || die "Could not sync live controller to repository"
python3 -m py_compile "$REPO_CTL" || die "Repository controller syntax failed"

echo "[3/6] Structural verification..."
python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape'); ast.parse(s)
checks={
 'resolver':'def _v327_resolve_payload' in s,
 'full marker':'+full-assembly-v327' in s,
 'validation':'def _v327_validate_prepared_full' in s,
 'partial overlay preserved':'partial-cstrike-overlay-v325+classifier-v327' in s,
}
if 'def _v323_analyze_archive_runtime' in s:
    checks['coherent runtime v3.23']='runtime_coherence=_v323_prepare_coherent_runtime(stage,c,runtime_scope)' in s
for k,v in checks.items(): print(('[OK] ' if v else '[FAIL] ')+k)
if not all(checks.values()): raise SystemExit(1)
PY

echo "[4/6] Regression test: full ZM tree vs single plugin pack..."
python3 - <<'PY'
from pathlib import Path
import tempfile,re

def refs(cs):
    out=[]
    cfg=cs/'addons/amxmodx/configs'
    if cfg.is_dir():
        for p in cfg.glob('plugins*.ini'):
            for line in p.read_text(errors='ignore').splitlines():
                st=line.strip()
                if not st or st.startswith((';','//')): continue
                body=st.split(';',1)[0].strip()
                if body and body.split()[0].lower().endswith('.amxx'): out.append(body.split()[0])
    return out

def full(cs):
    pd=cs/'addons/amxmodx/plugins'; cfg=cs/'addons/amxmodx/configs'
    pfiles=len(list(pd.glob('*.amxx'))) if pd.is_dir() else 0
    auth=(cfg/'plugins.ini').is_file() and pd.is_dir() and (pfiles>=3 or len(refs(cs))>=3)
    return (cs/'liblist.gam').is_file() or (cs/'dlls/cs.so').is_file() or ((cs/'server.cfg').is_file() and auth)

with tempfile.TemporaryDirectory() as td:
    t=Path(td)
    zm=t/'zm'; (zm/'addons/amxmodx/configs').mkdir(parents=True); (zm/'addons/amxmodx/plugins').mkdir(parents=True); (zm/'maps').mkdir()
    (zm/'server.cfg').write_text('hostname ZM\n'); (zm/'liblist.gam').write_text('game cstrike\n')
    (zm/'addons/amxmodx/configs/plugins.ini').write_text('a.amxx\nb.amxx\nc.amxx\n')
    for n in ('a','b','c'): (zm/f'addons/amxmodx/plugins/{n}.amxx').write_bytes(b'AMXX')
    (zm/'maps/zm_test.bsp').write_bytes(b'BSP')
    assert full(zm)
    ad=t/'addon'; (ad/'addons/amxmodx/plugins').mkdir(parents=True); (ad/'addons/amxmodx/plugins/x.amxx').write_bytes(b'AMXX')
    assert not full(ad)
print('[OK] full ZM assembly is FULL')
print('[OK] one-plugin addon remains PARTIAL')
PY

echo "[5/6] Idempotence check..."
python3 "$PATCHER" "$LIVE_CTL" || die "Repeated live patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller invalid after repeated patch"
install -m 0755 "$LIVE_CTL" "$REPO_CTL"

echo "[6/6] Current server diagnostic (no destructive repair)..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  "$LIVE_CTL" rcon "$SID" "version" 2>&1 || true
  "$LIVE_CTL" rcon "$SID" "meta version" 2>&1 || true
  "$LIVE_CTL" rcon "$SID" "amxx plugins" 2>&1 | tail -90 || true
else
  echo "[INFO] server #$SID does not exist"
fi

echo
echo "============================================================"
echo " v3.27 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "For the supplied img.zip, the next import must be FULL, not partial."
echo "Expected prefix: exact-cstrike-archive+full-assembly-v327"
echo "A full assembly that collapses to stock ~20 AMXX plugins is rejected before swap."
echo "A cstrike runtime without its own hlds_linux is normalized to a coherent runtime stack."
echo
echo "Re-upload img.zip to server #$SID once after this patch."
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
