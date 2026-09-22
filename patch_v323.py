from __future__ import annotations

import ast
import os
import py_compile
import re
import sys
from pathlib import Path

MARKER = '# >>> HYPER-HOST v3.23 COHERENT RUNTIME GUARD >>>'

HELPER = r'''
# >>> HYPER-HOST v3.23 COHERENT RUNTIME GUARD >>>
_V323_OFFICIAL_AMXX_MODULES={
    'cstrike_amxx_i386.so','csx_amxx_i386.so','engine_amxx_i386.so',
    'fakemeta_amxx_i386.so','fun_amxx_i386.so','geoip_amxx_i386.so',
    'hamsandwich_amxx_i386.so','json_amxx_i386.so','mysql_amxx_i386.so',
    'nvault_amxx_i386.so','regex_amxx_i386.so','sockets_amxx_i386.so',
    'sqlite_amxx_i386.so',
}


def _v323_payload_cstrike(payload:Path,layout:str)->Path:
    return payload/'cstrike' if layout=='server-root' else payload


def _v323_detect_previous_build(cstrike:Path)->list[str]:
    builds=[]
    logs=cstrike/'logs'
    if not logs.is_dir():
        return builds
    seen=0
    for p in sorted(logs.glob('*.log')):
        if seen>=80: break
        seen+=1
        try:
            data=p.read_bytes()[:512*1024]
        except Exception:
            continue
        for m in re.finditer(rb'48/1[.]1[.]2[.]7/Stdio/?[ ]*([0-9]{3,6})',data):
            b=m.group(1).decode('ascii','ignore')
            if b and b not in builds:
                builds.append(b)
                if len(builds)>=6:
                    return builds
    return builds


def _v323_analyze_archive_runtime(payload:Path,layout:str)->dict:
    cstrike=_v323_payload_cstrike(payload,layout)
    root=payload if layout=='server-root' else payload.parent

    engine_files=[]
    if layout=='server-root':
        for rel in ('hlds_linux','engine_i486.so','core.so','filesystem_stdio.so'):
            if (payload/rel).is_file(): engine_files.append(rel)

    runtime_candidates=(
        'dlls/cs.so',
        'addons/metamod/dlls/metamod.so',
        'addons/metamod/dlls/metamod_i386.so',
        'addons/metamod/metamod_i386.so',
        'addons/amxmodx/dlls/amxmodx.so',
        'addons/amxmodx/dlls/amxmodx_mm_i386.so',
        'addons/reunion/dlls/reunion.so',
        'addons/dproto/dproto_i386.so',
    )
    runtime_files=[rel for rel in runtime_candidates if (cstrike/rel).is_file()]

    modules=[]
    moddir=cstrike/'addons/amxmodx/modules'
    if moddir.is_dir():
        modules=sorted(p.name for p in moddir.glob('*.so') if p.is_file())

    has_matching_engine=bool(
        layout=='server-root' and
        (payload/'hlds_linux').is_file() and
        _elf_bits(payload/'hlds_linux')==32
    )
    carries_cstrike_runtime=bool(runtime_files or modules)
    partial=bool(carries_cstrike_runtime and not has_matching_engine)
    builds=_v323_detect_previous_build(cstrike)

    reason=''
    if partial:
        reason='archive contains cstrike runtime but does not contain its matching Linux hlds_linux engine'
        if builds:
            reason+='; archived server logs show build(s): '+', '.join(builds)

    return {
        'layout':layout,
        'has_matching_engine':has_matching_engine,
        'engine_files':engine_files,
        'carries_cstrike_runtime':carries_cstrike_runtime,
        'runtime_files':runtime_files,
        'amxx_modules':modules,
        'partial_legacy_runtime':partial,
        'archived_engine_builds':builds,
        'reason':reason,
    }


def _v323_disable_legacy_auth_plugins(cstrike:Path)->list[str]:
    actions=[]
    mp=cstrike/'addons/metamod/plugins.ini'
    if not mp.is_file():
        return actions
    raw=mp.read_bytes().replace(b'\r\n',b'\n').replace(b'\r',b'\n').decode('latin1','ignore')
    out=[]; changed=False
    for line in raw.splitlines():
        st=line.strip(); low=st.lower()
        active=bool(st and not st.startswith((';','#','//')))
        if active and (('reunion' in low) or ('dproto' in low)) and '.so' in low:
            out.append('; HYPER-HOST v3.23 disabled legacy auth plugin from partial runtime: '+line)
            changed=True
            actions.append('disabled legacy '+('Reunion' if 'reunion' in low else 'dproto')+' loader')
        else:
            out.append(line)
    if changed:
        mp.write_bytes(('\n'.join(out).rstrip()+'\n').encode('latin1','replace'))
    return actions


def _v323_remove_legacy_runtime_files(path:Path)->list[str]:
    cstrike=path/'cstrike'; actions=[]

    # GameDLL: must match the engine selected below.
    cs=cstrike/'dlls/cs.so'
    if cs.is_file():
        cs.unlink()
        actions.append('removed uploaded cs.so without matching engine')

    # Metamod executable runtime.
    for p in (
        cstrike/'addons/metamod/dlls/metamod.so',
        cstrike/'addons/metamod/dlls/metamod_i386.so',
        cstrike/'addons/metamod/metamod_i386.so',
    ):
        try:
            if p.is_file():
                p.unlink(); actions.append('removed uploaded Metamod loader '+p.name)
        except Exception:
            pass

    # AMXX loader: configs/plugins/content stay exactly from the assembly.
    dlls=cstrike/'addons/amxmodx/dlls'
    if dlls.is_dir():
        for p in dlls.glob('*.so'):
            try:
                p.unlink(); actions.append('removed uploaded AMXX loader '+p.name)
            except Exception:
                pass

    # Replace official AMXX modules as one ABI-coherent set. Unknown custom
    # modules are preserved and can still be diagnosed by normal startup checks.
    mods=cstrike/'addons/amxmodx/modules'
    if mods.is_dir():
        for p in mods.glob('*.so'):
            if p.name.lower() in _V323_OFFICIAL_AMXX_MODULES:
                try:
                    p.unlink()
                except Exception:
                    pass

    # Ham/gamedata must match the managed AMXX binary set.
    try:
        (cstrike/'addons/amxmodx/configs/hamdata.ini').unlink()
    except Exception:
        pass
    gd=cstrike/'addons/amxmodx/data/gamedata'
    if gd.is_dir():
        shutil.rmtree(gd,ignore_errors=True)

    actions.extend(_v323_disable_legacy_auth_plugins(cstrike))
    return actions


def _v323_prepare_coherent_runtime(path:Path,c:dict,scope:dict)->dict:
    if not bool(scope.get('partial_legacy_runtime')):
        return {
            'ok':True,'forced':False,'reason':'',
            'archive_scope':scope,'actions':[],
            'runtime':_v320_runtime_inventory(path),
        }

    actions=[]
    actions.extend(_v323_remove_legacy_runtime_files(path))

    # A cstrike-only runtime cannot be preserved safely because the matching
    # engine is absent. Build one complete, mutually compatible Linux stack.
    install_rehlds(path)
    actions.append('installed coherent ReHLDS '+str(REHLDS_VERSION)+' + ReGameDLL '+str(REGAMEDLL_VERSION))

    install_metamod_rehlds(path)
    actions.append('installed coherent Metamod-R '+str(METAMOD_VERSION))

    if '_v316_refresh_amxx_platform' in globals():
        actions.extend(_v316_refresh_amxx_platform(path))
    else:
        install_amxx(path)
        actions.append('installed coherent AMXX runtime')

    # Install managed ReAPI only when actual plugins require it.
    try:
        reapi=_ensure_reapi_compatible_stack(path)
        actions.extend(list(reapi.get('actions') or []))
    except Exception as exc:
        reapi={'required':False,'actions':[],'warning':str(exc)}

    actions.extend(list((_v320_sanitize_loader_chain(path).get('actions') or [])))
    normalize_permissions(path)

    return {
        'ok':True,
        'forced':True,
        'reason':str(scope.get('reason') or 'partial cstrike runtime without matching engine'),
        'archive_scope':scope,
        'actions':list(dict.fromkeys(actions)),
        'auth_note':'legacy Reunion/dproto loader was disabled; install a compatible auth module separately if non-Steam access is required',
        'reapi':reapi,
        'runtime':_v320_runtime_inventory(path),
    }


def _v323_runtime_backup(path:Path,backup:Path):
    rels=(
        'hlds_linux','engine_i486.so','core.so','filesystem_stdio.so','demoplayer.so',
        'cstrike/dlls/cs.so','cstrike/liblist.gam','cstrike/addons/metamod',
        'cstrike/addons/reunion','cstrike/addons/dproto',
        'cstrike/addons/amxmodx/dlls','cstrike/addons/amxmodx/modules',
        'cstrike/addons/amxmodx/configs/hamdata.ini','cstrike/addons/amxmodx/data/gamedata',
    )
    for rel in rels:
        src=path/rel
        if not src.exists(): continue
        dst=backup/rel; dst.parent.mkdir(parents=True,exist_ok=True)
        if src.is_dir(): shutil.copytree(src,dst,dirs_exist_ok=True)
        else: shutil.copy2(src,dst)


def _v323_runtime_restore(path:Path,backup:Path):
    rels=(
        'hlds_linux','engine_i486.so','core.so','filesystem_stdio.so','demoplayer.so',
        'cstrike/dlls/cs.so','cstrike/liblist.gam','cstrike/addons/metamod',
        'cstrike/addons/reunion','cstrike/addons/dproto',
        'cstrike/addons/amxmodx/dlls','cstrike/addons/amxmodx/modules',
        'cstrike/addons/amxmodx/configs/hamdata.ini','cstrike/addons/amxmodx/data/gamedata',
    )
    for rel in rels:
        cur=path/rel
        if cur.is_dir(): shutil.rmtree(cur,ignore_errors=True)
        elif cur.exists():
            try: cur.unlink()
            except Exception: pass
        src=backup/rel
        if not src.exists(): continue
        cur.parent.mkdir(parents=True,exist_ok=True)
        if src.is_dir(): shutil.copytree(src,cur,dirs_exist_ok=True)
        else: shutil.copy2(src,cur)


def runtime_coherent_apply(sid:int):
    require_root(); c=load_server(sid); path=safe_server_path(sid)
    backup=path.parent/BUILD_BACKUP_DIR_NAME/f'{sid}-coherent-v323-{time.strftime("%Y%m%d-%H%M%S")}-{secrets.token_hex(4)}'
    backup.mkdir(parents=True,exist_ok=True)
    _v323_runtime_backup(path,backup)

    current_scope={
        'layout':'installed-server',
        'has_matching_engine':False,
        'carries_cstrike_runtime':True,
        'partial_legacy_runtime':True,
        'archived_engine_builds':_v323_detect_previous_build(path/'cstrike'),
        'reason':'manual/current-server coherent runtime repair',
    }

    run(['systemctl','stop',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
    try:
        result=_v323_prepare_coherent_runtime(path,c,current_scope)
        c=load_server(sid)
        c['profile']='rehlds'
        c['runtime_policy']={'engine':'auto','metamod':'auto','amxx':'auto'}
        save_server(c); db_update_profile(sid,'rehlds')
        normalize_permissions(path)
        run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
        run(['systemctl','start',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
        ok,detail=wait_server_ready(load_server(sid),50.0)
        if not ok:
            raise RuntimeError('coherent runtime did not become ready: '+str(detail))
        time.sleep(1.5)
        inv=_v320_runtime_inventory(path)
        return {'ok':True,'id':sid,'backup':str(backup),'query':detail,'coherence':result,'runtime':inv}
    except Exception as exc:
        run(['systemctl','stop',f'hyper-cs16@{sid}.service'],check=False,timeout=30)
        _v323_runtime_restore(path,backup)
        normalize_permissions(path)
        run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
        run(['systemctl','start',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
        raise RuntimeError('v3.23 coherent runtime repair failed and runtime backup was restored: '+str(exc))
# <<< HYPER-HOST v3.23 COHERENT RUNTIME GUARD <<<
'''


def parse(src:str):
    return ast.parse(src)


def function_node(tree:ast.AST,name:str):
    for node in getattr(tree,'body',[]):
        if isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name==name:
            return node
    return None


def func_source(src:str,node)->str:
    lines=src.splitlines(keepends=True)
    return ''.join(lines[node.lineno-1:node.end_lineno])


def replace_function(src:str,node,new_fn:str)->str:
    lines=src.splitlines(keepends=True)
    if new_fn and not new_fn.endswith('\n'): new_fn+='\n'
    lines[node.lineno-1:node.end_lineno]=[new_fn]
    return ''.join(lines)


def patch_ctl(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    if 'def _v320_prepare_runtime(' not in src:
        raise RuntimeError('v3.23 requires installed v3.20 adaptive runtime')
    if 'def _v322_skip_missing_optional_refs(' not in src:
        raise RuntimeError('v3.23 requires installed v3.22 optional-file sanitizer')

    if MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos<0: raise RuntimeError('install_custom_build not found')
        src=src[:pos]+'\n'+HELPER+src[pos:]

    tree=parse(src); fn=function_node(tree,'install_custom_build')
    if fn is None: raise RuntimeError('install_custom_build missing after helper insertion')
    fsrc=func_source(src,fn)

    if 'runtime_scope=_v323_analyze_archive_runtime(payload,layout)' not in fsrc:
        anchor='        payload,layout=_detect_build_payload(extract_root)\n'
        if anchor not in fsrc: raise RuntimeError('payload/layout structural point missing')
        fsrc=fsrc.replace(anchor,anchor+'        runtime_scope=_v323_analyze_archive_runtime(payload,layout)\n',1)

    if 'runtime_coherence=_v323_prepare_coherent_runtime(stage,c,runtime_scope)' not in fsrc:
        anchor='        platform_runtime=_v320_prepare_runtime(stage,c)\n'
        if anchor not in fsrc: raise RuntimeError('v3.20 platform runtime point missing')
        block=(
            '        runtime_coherence=_v323_prepare_coherent_runtime(stage,c,runtime_scope)\n'
            "        if runtime_coherence.get('forced'):\n"
            "            c['profile']='rehlds'\n"
            "            db_update_profile(sid,'rehlds')\n"
        )
        fsrc=fsrc.replace(anchor,block+anchor,1)

    if '+coherent-runtime-v323' not in fsrc:
        # Append only when a partial legacy runtime was actually normalized.
        anchor="        import_mode=import_mode+'+skip-missing-v322'\n"
        if anchor not in fsrc:
            raise RuntimeError('v3.22 import suffix point missing')
        fsrc=fsrc.replace(
            anchor,
            anchor+"        if runtime_coherence.get('forced'): import_mode=import_mode+'+coherent-runtime-v323'\n",
            1,
        )

    # Expose result to panel/API.
    if "'runtime_coherence':runtime_coherence" not in fsrc:
        old="'runtime_fill':runtime_fill,'reapi_compat':reapi_compat,'archive_manifest':manifest,"
        new="'runtime_fill':runtime_fill,'runtime_coherence':runtime_coherence,'reapi_compat':reapi_compat,'archive_manifest':manifest,"
        if old in fsrc:
            fsrc=fsrc.replace(old,new,1)
        else:
            # Current v3.22 function has runtime_fill followed by reapi_compat in the result dict.
            fsrc=fsrc.replace("'runtime_fill':runtime_fill,'reapi_compat':reapi_compat", "'runtime_fill':runtime_fill,'runtime_coherence':runtime_coherence,'reapi_compat':reapi_compat",1)

    # Add a concise warning/note only for forced coherence.
    if "runtime_coherence.get('forced')" in fsrc and 'Partial legacy runtime was replaced' not in fsrc:
        anchor="        warnings=[]\n"
        if anchor in fsrc:
            note=(
                "        if runtime_coherence.get('forced'):\n"
                "            builds=list((runtime_coherence.get('archive_scope') or {}).get('archived_engine_builds') or [])\n"
                "            warnings.append('Partial legacy runtime was replaced with one coherent HYPER-HOST stack' + ((' (archived build '+', '.join(builds)+')') if builds else '') + '. Legacy Reunion/dproto loader disabled.')\n"
            )
            fsrc=fsrc.replace(anchor,anchor+note,1)

    src=replace_function(src,fn,fsrc)

    # Add CLI command to the generic id command list.
    if "'runtime-coherent-apply'" not in src:
        src=src.replace("'runtime-status','runtime-apply','runtime-repair-chain'", "'runtime-status','runtime-apply','runtime-coherent-apply','runtime-repair-chain'",1)

    if "elif args.cmd=='runtime-coherent-apply'" not in src:
        anchor="        elif args.cmd=='runtime-apply': result=runtime_apply(args.id)\n"
        if anchor not in src: raise RuntimeError('runtime CLI branch anchor missing')
        src=src.replace(anchor,anchor+"        elif args.cmd=='runtime-coherent-apply': result=runtime_coherent_apply(args.id)\n",1)

    tmp=path.with_name(path.name+'.v323tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True)
    final=tmp.read_text(encoding='utf-8',errors='surrogateescape')
    checks=[
        MARKER,
        'runtime_scope=_v323_analyze_archive_runtime(payload,layout)',
        'runtime_coherence=_v323_prepare_coherent_runtime(stage,c,runtime_scope)',
        '+coherent-runtime-v323',
        'def runtime_coherent_apply(sid:int):',
        "elif args.cmd=='runtime-coherent-apply'",
    ]
    missing=[x for x in checks if x not in final]
    if missing:
        tmp.unlink(missing_ok=True)
        raise RuntimeError('v3.23 verification failed: '+repr(missing))
    os.replace(tmp,path)
    print('[PATCHED]',path)


def patch_index(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    src=src.replace('установлена из архива без вырезания runtime.','установлена из архива.')
    src=src.replace('Сборка скачана и установлена без вырезания runtime.','Сборка скачана и установлена.')
    # The build success handlers are intentionally one-line PHP; inject a small
    # coherence descriptor without depending on exact Russian wording around it.
    if "$coh=is_array($r['runtime_coherence']" not in src:
        marker="$warn=trim((string)($r['warning']??''));"
        inject="$coh=is_array($r['runtime_coherence']??null)?$r['runtime_coherence']:[];$cohForced=!empty($coh['forced']);$cohScope=is_array($coh['archive_scope']??null)?$coh['archive_scope']:[];$cohBuilds=is_array($cohScope['archived_engine_builds']??null)?$cohScope['archived_engine_builds']:[];"
        src=src.replace(marker,marker+inject)

    if 'Старый неполный runtime сборки автоматически заменён' not in src:
        needle="if(!$healthy)$msg.=' Сборка оставлена установленной, но runtime требует внимания'"
        inject="if(isset($cohForced)&&$cohForced)$msg.=' Старый неполный runtime сборки автоматически заменён единым совместимым HYPER-HOST runtime'.((isset($cohBuilds)&&$cohBuilds)?' (в старых логах build '.implode(', ',$cohBuilds).')':'').'. Старый Reunion/dproto отключён.';"
        if needle in src:
            src=src.replace(needle,inject+needle)

    tmp=path.with_name(path.name+'.v323tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    os.replace(tmp,path)
    print('[PATCHED]',path)


def main():
    if len(sys.argv)!=3:
        raise SystemExit('usage: patch_v323.py ctl|index PATH')
    mode=sys.argv[1]; path=Path(sys.argv[2])
    if mode=='ctl': patch_ctl(path)
    elif mode=='index': patch_index(path)
    else: raise SystemExit('unknown mode')

if __name__=='__main__':
    main()
