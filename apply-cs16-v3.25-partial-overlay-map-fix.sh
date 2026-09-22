#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.25 — PARTIAL OVERLAY + MAP FALLBACK
#
# Fixes two related importer bugs:
# 1) archives such as addons/amxmodx/... were treated as a complete cstrike build
#    and could wipe the installed assembly;
# 2) such partial archives then failed with "Assembly has no playable .bsp maps".
#
# New behavior:
# - full server/cstrike builds still install with replacement semantics;
# - partial addon/plugin/config packs are merged into the current server;
# - plugins.ini/modules.ini/Metamod plugins.ini are merged, never replaced;
# - uploaded .amxx files are auto-enabled only when the package does not mention
#   them in any plugin list;
# - if a real full build has no maps, managed base maps are added as a safe fallback.

SID="${1:-24}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.25-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.25-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die(){ echo; echo "[ERROR] $*"; echo "[ERROR] Log: $LOG"; echo "[ERROR] Backup: $BACKUP"; exit 1; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; local n; n="$(printf '%s' "$f"|sed 's#^/##;s#/#__#g')"; cp -a "$f" "$BACKUP/$n"; }

[[ "$EUID" -eq 0 ]] || die "Run as root"
[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"

echo "============================================================"
echo " HYPER-HOST CS16 v3.25 — PARTIAL OVERLAY + MAP FALLBACK"
echo "============================================================"
echo "Server: $SID"
echo "Live:   $LIVE_CTL"
echo "Repo:   $REPO_CTL"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo

backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"

PATCHER="$(mktemp /tmp/hh-v325.XXXXXX.py)"
trap 'rm -f "$PATCHER" 2>/dev/null || true' EXIT
cat > "$PATCHER" <<'PY'
from __future__ import annotations
import ast, os, py_compile, re, sys
from pathlib import Path

MARKER = '# >>> HYPER-HOST v3.25 PARTIAL OVERLAY + MAP FALLBACK >>>'
HELPER = r'''# >>> HYPER-HOST v3.25 PARTIAL OVERLAY + MAP FALLBACK >>>
def _v325_cs_payload(payload:Path,layout:str)->Path:
    return payload/'cstrike' if layout=='server-root' else payload


def _v325_playable_map_names(maps_dir:Path)->list[str]:
    if not maps_dir.is_dir():
        return []
    names=[]
    for p in maps_dir.iterdir():
        try:
            if p.is_file() and p.suffix.lower()=='.bsp' and SAFE_MAP.fullmatch(p.stem):
                names.append(p.stem)
        except OSError:
            continue
    return sorted(set(names),key=str.lower)


def _v325_normalize_map_case(cstrike:Path)->list[str]:
    actions=[]
    target=cstrike/'maps'
    if cstrike.is_dir():
        for d in list(cstrike.iterdir()):
            if d.is_dir() and d.name.lower()=='maps' and d.name!='maps':
                target.mkdir(parents=True,exist_ok=True)
                shutil.copytree(d,target,dirs_exist_ok=True)
                actions.append('merged '+d.name+' -> maps')
    if target.is_dir():
        for p in list(target.iterdir()):
            if not p.is_file() or p.suffix.lower()!='.bsp' or p.suffix=='.bsp':
                continue
            dst=p.with_suffix('.bsp')
            if dst.exists():
                continue
            p.rename(dst)
            actions.append('normalized '+p.name+' -> '+dst.name)
    return actions


def _v325_payload_mode(payload:Path,layout:str)->dict:
    cs=_v325_cs_payload(payload,layout)
    markers=('addons','maps','models','sound','sprites','resource','gfx','events','overviews','dlls','classes')
    present=[x for x in markers if (cs/x).exists()]
    maps=_v325_playable_map_names(cs/'maps')
    root_engine=bool(layout=='server-root' and (payload/'hlds_linux').is_file())
    strong=bool(
        root_engine or
        (cs/'liblist.gam').is_file() or
        (cs/'dlls/cs.so').is_file() or
        ((cs/'server.cfg').is_file() and maps and len(present)>=5)
    )
    partial=not strong
    return {
        'partial_overlay':partial,
        'layout':layout,
        'markers':present,
        'playable_maps':maps[:200],
        'root_engine':root_engine,
        'reason':('partial addon/content package' if partial else 'complete build signals detected'),
    }


def _v325_token_from_plugin_line(line:str)->str:
    st=line.strip()
    if not st:
        return ''
    body=st.lstrip(';').strip()
    if not body or body.startswith('//'):
        return ''
    body=body.split(';',1)[0].strip()
    if not body:
        return ''
    return body.split()[0]


def _v325_merge_plugin_list(src:Path,dst:Path)->dict:
    if not src.is_file():
        return {'added':[],'source':src.name}
    dst.parent.mkdir(parents=True,exist_ok=True)
    old=dst.read_text(encoding='utf-8',errors='ignore').splitlines() if dst.is_file() else []
    known=set()
    for line in old:
        tok=_v325_token_from_plugin_line(line)
        if tok.lower().endswith('.amxx'):
            known.add(tok.lower())
    added=[]
    for line in src.read_text(encoding='utf-8',errors='ignore').splitlines():
        tok=_v325_token_from_plugin_line(line)
        if not tok.lower().endswith('.amxx') or tok.lower() in known:
            continue
        old.append(line.strip())
        known.add(tok.lower())
        added.append(tok)
    dst.write_text('\n'.join(old).rstrip()+'\n',encoding='utf-8')
    return {'added':added,'source':src.name}


def _v325_merge_plain_unique(src:Path,dst:Path)->list[str]:
    if not src.is_file():
        return []
    dst.parent.mkdir(parents=True,exist_ok=True)
    old=dst.read_text(encoding='utf-8',errors='ignore').splitlines() if dst.is_file() else []
    keys={re.sub(r'\s+',' ',x.strip().lower()) for x in old if x.strip()}
    added=[]
    for line in src.read_text(encoding='utf-8',errors='ignore').splitlines():
        st=line.strip()
        if not st or st.startswith(';') or st.startswith('//'):
            continue
        key=re.sub(r'\s+',' ',st.lower())
        if key in keys:
            continue
        old.append(st); keys.add(key); added.append(st)
    dst.write_text('\n'.join(old).rstrip()+'\n',encoding='utf-8')
    return added


def _v325_copy_partial_tree(src:Path,dst:Path)->list[str]:
    # Copy a plugin/addon/content package over an existing cstrike tree without
    # allowing loader/plugin lists to erase the assembly's current configuration.
    special={
        'addons/metamod/plugins.ini',
        'addons/amxmodx/configs/modules.ini',
        'addons/amxmodx/configs/core.ini',
    }
    copied=[]
    for p in src.rglob('*'):
        try:
            rel=p.relative_to(src)
        except Exception:
            continue
        rels=rel.as_posix()
        low=rels.lower()
        if p.is_dir():
            (dst/rel).mkdir(parents=True,exist_ok=True)
            continue
        if not p.is_file():
            continue
        if low in special or (low.startswith('addons/amxmodx/configs/plugins') and low.endswith('.ini')):
            continue
        q=dst/rel
        q.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(p,q)
        copied.append(rels)
    return copied


def _v325_overlay_partial_payload(payload:Path,layout:str,stage:Path)->dict:
    src=_v325_cs_payload(payload,layout)
    dst=stage/'cstrike'
    dst.mkdir(parents=True,exist_ok=True)
    copied=_v325_copy_partial_tree(src,dst)

    src_cfg=src/'addons/amxmodx/configs'
    dst_cfg=dst/'addons/amxmodx/configs'
    merged=[]
    mentioned=set()
    if src_cfg.is_dir():
        for pin in sorted(src_cfg.glob('plugins*.ini'),key=lambda p:p.name.lower()):
            for line in pin.read_text(encoding='utf-8',errors='ignore').splitlines():
                tok=_v325_token_from_plugin_line(line)
                if tok.lower().endswith('.amxx'):
                    mentioned.add(tok.lower())
            info=_v325_merge_plugin_list(pin,dst_cfg/pin.name)
            merged.extend(info.get('added') or [])
        _v325_merge_plain_unique(src_cfg/'modules.ini',dst_cfg/'modules.ini')

    _v325_merge_plain_unique(src/'addons/metamod/plugins.ini',dst/'addons/metamod/plugins.ini')

    # A simple plugin ZIP often contains only addons/amxmodx/plugins/foo.amxx and
    # no plugins.ini. In that case make the upload actually active while keeping
    # every existing assembly entry intact.
    all_cfg=[]
    if dst_cfg.is_dir():
        all_cfg=[p for p in dst_cfg.glob('plugins*.ini') if p.is_file()]
    configured=set()
    for pin in all_cfg:
        for line in pin.read_text(encoding='utf-8',errors='ignore').splitlines():
            tok=_v325_token_from_plugin_line(line)
            if tok.lower().endswith('.amxx'):
                configured.add(tok.lower())
    main=dst_cfg/'plugins.ini'
    main.parent.mkdir(parents=True,exist_ok=True)
    lines=main.read_text(encoding='utf-8',errors='ignore').splitlines() if main.is_file() else []
    auto=[]
    src_plugins=src/'addons/amxmodx/plugins'
    if src_plugins.is_dir():
        for amxx in sorted(src_plugins.glob('*.amxx'),key=lambda p:p.name.lower()):
            low=amxx.name.lower()
            if low in configured or low in mentioned:
                continue
            lines.append(amxx.name)
            configured.add(low); auto.append(amxx.name)
    if auto:
        main.write_text('\n'.join(lines).rstrip()+'\n',encoding='utf-8')

    return {
        'partial_overlay':True,
        'copied_files':len(copied),
        'merged_plugin_entries':merged[:200],
        'auto_enabled_plugins':auto[:200],
    }


def _v325_copy_base_map_fallback(stage:Path,base:Path)->dict:
    cstrike=stage/'cstrike'
    actions=_v325_normalize_map_case(cstrike)
    choices=_v325_playable_map_names(cstrike/'maps')
    if choices:
        return {'fallback_used':False,'source':'assembly-or-existing-stage','maps':choices,'actions':actions}

    src=base/'cstrike/maps'
    if src.is_dir() and _v325_playable_map_names(src):
        dst=cstrike/'maps'; dst.mkdir(parents=True,exist_ok=True)
        shutil.copytree(src,dst,dirs_exist_ok=True)
        # Copy stock WADs that the fallback maps may reference, but never replace
        # archive-provided WADs.
        for wad in (base/'cstrike').glob('*.wad'):
            q=cstrike/wad.name
            if not q.exists():
                shutil.copy2(wad,q)
        actions.append('managed base maps added')

    actions.extend(_v325_normalize_map_case(cstrike))
    choices=_v325_playable_map_names(cstrike/'maps')
    if not choices:
        raise RuntimeError('No playable .bsp maps are available after safe fallback')
    return {'fallback_used':True,'source':'managed-base','maps':choices,'actions':actions}

# <<< HYPER-HOST v3.25 PARTIAL OVERLAY + MAP FALLBACK <<<
'''


def fn_bounds(src:str,name:str):
    tree=ast.parse(src)
    node=next((n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name),None)
    if node is None:
        return -1,-1,''
    lines=src.splitlines(keepends=True)
    st=sum(len(x) for x in lines[:node.lineno-1])
    en=sum(len(x) for x in lines[:node.end_lineno])
    return st,en,src[st:en]


def replace_fn(src:str,name:str,new:str)->str:
    st,en,_=fn_bounds(src,name)
    if st<0: raise RuntimeError(name+' not found')
    return src[:st]+new+("\n" if not new.endswith('\n') else '')+src[en:]


def patch(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src
    if 'def install_custom_build(' not in src:
        raise RuntimeError(f'{path}: install_custom_build not found')

    if MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos<0: raise RuntimeError(f'{path}: helper insertion point missing')
        src=src[:pos]+'\n'+HELPER+src[pos:]

    st,en,fn=fn_bounds(src,'install_custom_build')
    if st<0: raise RuntimeError(f'{path}: install_custom_build parse failed')

    # Detect whether the upload is a complete assembly or a partial addon pack.
    if 'partial_payload=_v325_payload_mode(payload,layout)' not in fn:
        anchor='        payload,layout=_detect_build_payload(extract_root)\n'
        if anchor not in fn: raise RuntimeError(f'{path}: payload/layout anchor missing')
        fn=fn.replace(anchor,anchor+'        partial_payload=_v325_payload_mode(payload,layout)\n',1)

    # Partial archives must merge into the current server instead of deleting cstrike.
    old='        exact_copy=_overlay_uploaded_build_exact(payload,layout,stage,base)\n'
    if '_v325_overlay_partial_payload(payload,layout,stage)' not in fn:
        if old not in fn: raise RuntimeError(f'{path}: exact overlay anchor missing')
        new=(
            "        if partial_payload.get('partial_overlay'):\n"
            "            if old_existed:\n"
            "                run(['rsync','-a','--delete',str(path)+'/',str(stage)+'/'],timeout=1800)\n"
            "            partial_merge=_v325_overlay_partial_payload(payload,layout,stage)\n"
            "            exact_copy={'partial_overlay':True,**partial_merge}\n"
            "        else:\n"
            "            partial_merge={'partial_overlay':False}\n"
            "            exact_copy=_overlay_uploaded_build_exact(payload,layout,stage,base)\n"
        )
        fn=fn.replace(old,new,1)

    # Ensure map validation never destroys a valid partial overlay. Full builds with
    # zero maps receive the panel's managed stock maps as a safe fallback.
    if 'map_recovery=_v325_copy_base_map_fallback(stage,base)' not in fn:
        anchor="        maps=stage/'cstrike/maps'; preferred=str(preferred_map_override or c.get('start_map') or '')\n"
        if anchor not in fn: raise RuntimeError(f'{path}: map selection anchor missing')
        fn=fn.replace(anchor,"        map_recovery=_v325_copy_base_map_fallback(stage,base)\n"+anchor,1)

    # Mark partial installs and map fallback in the persisted import mode.
    old_assign="        import_mode='exact-server-root' if layout=='server-root' else 'exact-cstrike-archive'\n"
    if "partial-cstrike-overlay-v325" not in fn:
        if old_assign not in fn: raise RuntimeError(f'{path}: import_mode anchor missing')
        new_assign=(
            old_assign+
            "        if partial_payload.get('partial_overlay'): import_mode='partial-cstrike-overlay-v325'\n"
            "        if map_recovery.get('fallback_used'): import_mode=import_mode+'+map-fallback-v325'\n"
        )
        fn=fn.replace(old_assign,new_assign,1)

    # Expose non-secret diagnostics to the panel/API if the standard result dict is present.
    if "'partial_payload':partial_payload" not in fn:
        candidates=[
            ("'runtime_fill':runtime_fill,", "'runtime_fill':runtime_fill,'partial_payload':partial_payload,'partial_merge':partial_merge,'map_recovery':map_recovery,"),
            ("'archive_manifest':manifest,", "'archive_manifest':manifest,'partial_payload':partial_payload,'partial_merge':partial_merge,'map_recovery':map_recovery,"),
        ]
        for a,b in candidates:
            if a in fn:
                fn=fn.replace(a,b,1)
                break

    src=src[:st]+fn+src[en:]
    ast.parse(src)

    tmp=path.with_name(path.name+'.v325tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True)
    os.replace(tmp,path)

    final=path.read_text(encoding='utf-8',errors='surrogateescape')
    checks={
        'helper':MARKER in final,
        'partial detector':'partial_payload=_v325_payload_mode(payload,layout)' in final,
        'safe merge':'_v325_overlay_partial_payload(payload,layout,stage)' in final,
        'map fallback':'map_recovery=_v325_copy_base_map_fallback(stage,base)' in final,
        'import marker':'partial-cstrike-overlay-v325' in final,
    }
    bad=[k for k,v in checks.items() if not v]
    if bad: raise RuntimeError(f'{path}: verification failed: {bad}')
    return src!=original

for arg in sys.argv[1:]:
    p=Path(arg)
    changed=patch(p)
    print(('[PATCHED] ' if changed else '[OK already patched] ')+str(p))
PY

echo "[1/5] Patching live + repository controllers..."
python3 "$PATCHER" "$LIVE_CTL" "$REPO_CTL" || die "Controller patch failed"

echo "[2/5] Python syntax check..."
python3 -m py_compile "$LIVE_CTL" "$REPO_CTL" || die "Python syntax check failed"

echo "[3/5] Semantic checks..."
python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
ast.parse(s)
checks={
 'v3.25 helper':'def _v325_payload_mode' in s,
 'partial package merge':'_v325_overlay_partial_payload(payload,layout,stage)' in s,
 'map fallback':'_v325_copy_base_map_fallback(stage,base)' in s,
 'partial import mode':'partial-cstrike-overlay-v325' in s,
 'old map hard error still guarded':'Assembly has no playable .bsp maps' in s,
}
for k,v in checks.items(): print(('[OK] ' if v else '[FAIL] ')+k)
if not all(checks.values()): raise SystemExit(1)
PY

echo "[4/5] Controller idempotence check..."
python3 "$PATCHER" "$LIVE_CTL" "$REPO_CTL" || die "Idempotence pass failed"
python3 -m py_compile "$LIVE_CTL" "$REPO_CTL" || die "Controller invalid after second pass"

echo "[5/5] Current server sanity (no destructive changes)..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  "$LIVE_CTL" rcon "$SID" "status" 2>&1 || true
  echo "--- AMXX ---"
  "$LIVE_CTL" rcon "$SID" "amxx plugins" 2>&1 | tail -80 || true
else
  echo "[INFO] server #$SID does not exist; future imports are patched"
fi

echo
echo "============================================================"
echo " v3.25 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "FIXED: addons/plugin ZIPs no longer replace the whole cstrike assembly."
echo "FIXED: existing plugins.ini/modules.ini/Metamod lists are merged, not overwritten."
echo "FIXED: simple uploaded .amxx files are auto-enabled without deleting old plugins."
echo "FIXED: 'Assembly has no playable .bsp maps' for partial addon packages."
echo "FIXED: a complete build with no maps gets managed stock maps as safe fallback."
echo
echo "Re-upload the same archive after this patch."
echo "Expected import mode for plugin/addon archives: partial-cstrike-overlay-v325"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
