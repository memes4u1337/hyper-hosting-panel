#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.19 — ADAPTIVE RUNTIME MANAGER
#
# This is the architecture change:
# - uploaded assembly runtime is preserved first;
# - AUTO changes only a component with a proven incompatibility;
# - ASSEMBLY means do not replace that component on next upload;
# - MANAGED means use the HYPER-HOST compatible component;
# - loader chain is canonicalized to prevent recursive/double Metamod/AMXX.
#
# Current confirmed failure fixed:
#   duplicate Metamod/AMXX load -> duplicate cvars/commands ->
#   addHook: The same handler can't be used twice on the hookchain.
#
# Requires current live controller to already contain the v3.16/v3.18 runtime
# framework (the current server clearly does, because imports report
# managed-runtime-v316).
#
# Usage:
#   bash apply-cs16-v3.19-adaptive-runtime-manager.sh 15

SID="${1:-15}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
DOMAIN="www.avito.hyper-host.pw"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.19-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.19-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die() {
  echo
  echo "[ERROR] $*"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backup: $BACKUP"
  exit 1
}

echo "============================================================"
echo " HYPER-HOST CS16 ADAPTIVE RUNTIME MANAGER v3.19"
echo "============================================================"
echo "Server:     $SID"
echo "Live ctl:   $LIVE_CTL"
echo "Repo:       $REPO"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"

if ! grep -q "def _v316_refresh_amxx_platform" "$LIVE_CTL"; then
  die "Live controller does not contain the v3.16/v3.18 runtime framework. Do not run older base installers."
fi

PATCHER="$(mktemp /tmp/hh-v319.XXXXXX.py)"
ROOTS="$(mktemp /tmp/hh-v319-roots.XXXXXX)"
NGTMP="$(mktemp /tmp/hh-v319-nginx.XXXXXX)"

cleanup() {
  rm -f "$PATCHER" "$ROOTS" "$NGTMP" 2>/dev/null || true
}
trap cleanup EXIT

cat >"$PATCHER" <<'PY_V319_PATCH'
from __future__ import annotations

import os
import py_compile
import re
import sys
from pathlib import Path

CTL_MARKER = '# >>> HYPER-HOST v3.19 ADAPTIVE RUNTIME >>>'

HELPER = r'''
# >>> HYPER-HOST v3.19 ADAPTIVE RUNTIME >>>
def _v319_strings(path:Path)->str:
    if not path.is_file():
        return ''
    tool=shutil.which('strings')
    if not tool:
        return ''
    cp=run([tool,'-a',str(path)],check=False,timeout=20)
    return cp.stdout or ''


def _v319_version_from_strings(path:Path,kind:str)->str:
    text=_v319_strings(path)
    patterns={
        'amxx':[
            r'AMX Mod X(?: version)?\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+){1,2}(?:-[A-Za-z0-9._-]+)?)',
            r'amxmodx_version[^0-9]*([0-9]+\.[0-9]+(?:\.[0-9]+){1,2})',
        ],
        'metamod':[
            r'Metamod-r(?: version)?\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+){1,2})',
            r'Metamod(?: version)?\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+){1,2}(?:-[A-Za-z0-9._-]+)?)',
        ],
        'reapi':[
            r'ReAPI(?: version)?\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+){1,3})',
        ],
    }
    for pat in patterns.get(kind,[]):
        m=re.search(pat,text,re.I)
        if m: return m.group(1)
    return ''


def _v319_runtime_policy(c:dict)->dict:
    allowed={'auto','assembly','managed'}
    raw=c.get('runtime_policy') if isinstance(c,dict) else None
    if not isinstance(raw,dict): raw={}
    out={}
    for key in ('engine','metamod','amxx'):
        value=str(raw.get(key) or 'auto').strip().lower()
        out[key]=value if value in allowed else 'auto'
    return out


def _v319_find_metamod(cstrike:Path):
    return _first_existing(cstrike,[
        'addons/metamod/dlls/metamod.so',
        'addons/metamod/dlls/metamod_i386.so',
        'addons/metamod/metamod_i386.so',
    ])


def _v319_find_amxx(cstrike:Path):
    return _first_existing(cstrike,[
        'addons/amxmodx/dlls/amxmodx_mm_i386.so',
        'addons/amxmodx/dlls/amxmodx.so',
    ])


def _v319_runtime_inventory(path:Path)->dict:
    cstrike=path/'cstrike'
    engine=path/'hlds_linux'
    game=cstrike/'dlls/cs.so'
    meta=_v319_find_metamod(cstrike)
    amxx=_v319_find_amxx(cstrike)
    reapi=cstrike/'addons/amxmodx/modules/reapi_amxx_i386.so'

    engine_rehlds=bool(
        _binary_contains(path/'engine_i486.so',b'rehlds') or
        _binary_contains(engine,b'rehlds')
    )
    game_regame=_binary_contains(game,b'regamedll')

    liblist=cstrike/'liblist.gam'
    lib_lines=[]
    if liblist.is_file():
        txt=liblist.read_text(encoding='latin1',errors='ignore').replace('\r','')
        lib_lines=[x.strip() for x in txt.splitlines() if re.match(r'(?i)^\s*gamedll_linux\s+',x)]

    meta_cfg=cstrike/'addons/metamod/config.ini'
    meta_game=[]
    if meta_cfg.is_file():
        txt=meta_cfg.read_text(encoding='latin1',errors='ignore').replace('\r','')
        meta_game=[x.strip() for x in txt.splitlines() if x.strip() and not x.lstrip().startswith((';','#','//')) and re.match(r'(?i)^gamedll\b',x.strip())]

    plugins_ini=cstrike/'addons/metamod/plugins.ini'
    amxx_lines=[]; self_meta=[]
    if plugins_ini.is_file():
        txt=plugins_ini.read_text(encoding='latin1',errors='ignore').replace('\r','')
        for raw in txt.splitlines():
            st=raw.strip(); low=st.lower()
            if not st or st.startswith((';','#','//')): continue
            if 'amxmodx' in low: amxx_lines.append(st)
            if 'addons/metamod' in low and '.so' in low: self_meta.append(st)

    meta_ver=_v319_version_from_strings(meta,'metamod') if meta else ''
    amxx_ver=_v319_version_from_strings(amxx,'amxx') if amxx else ''
    reapi_ver=_v319_version_from_strings(reapi,'reapi') if reapi.is_file() else ''

    return {
        'engine':{
            'kind':'ReHLDS' if engine_rehlds else ('HLDS' if engine.is_file() else 'missing'),
            'version':str(REHLDS_VERSION) if engine_rehlds else '',
            'path':str(engine.relative_to(path)) if engine.is_file() else '',
            'elf_bits':_elf_bits(engine) if engine.is_file() else 0,
        },
        'gamedll':{
            'kind':'ReGameDLL' if game_regame else ('CS GameDLL' if game.is_file() else 'missing'),
            'version':str(REGAMEDLL_VERSION) if game_regame else '',
            'path':str(game.relative_to(path)) if game.is_file() else '',
            'elf_bits':_elf_bits(game) if game.is_file() else 0,
        },
        'metamod':{
            'kind':'Metamod-R' if (meta and ('metamod-r' in _v319_strings(meta).lower())) else ('Metamod' if meta else 'missing'),
            'version':meta_ver,
            'path':str(meta.relative_to(path)) if meta else '',
            'elf_bits':_elf_bits(meta) if meta else 0,
        },
        'amxx':{
            'kind':'AMX Mod X' if amxx else 'missing',
            'version':amxx_ver,
            'path':str(amxx.relative_to(path)) if amxx else '',
            'elf_bits':_elf_bits(amxx) if amxx else 0,
        },
        'reapi':{
            'installed':reapi.is_file(),
            'version':reapi_ver,
            'path':str(reapi.relative_to(path)) if reapi.is_file() else '',
        },
        'loader_chain':{
            'liblist_gamedll_linux':lib_lines,
            'metamod_gamedll_overrides':meta_game,
            'metamod_amxx_lines':amxx_lines,
            'metamod_self_lines':self_meta,
            'healthy':bool(len(lib_lines)==1 and len(amxx_lines)<=1 and not meta_game and not self_meta),
        },
    }


def _v319_sanitize_loader_chain(path:Path)->dict:
    cstrike=path/'cstrike'
    actions=[]
    meta=_v319_find_metamod(cstrike)
    amxx=_v319_find_amxx(cstrike)

    # CS 1.6 must have one Linux GameDLL entry only. When Metamod exists it is
    # the GameDLL proxy; otherwise load cs.so directly.
    lib=cstrike/'liblist.gam'
    if lib.is_file():
        text=lib.read_text(encoding='latin1',errors='ignore')
        out=[]
        for raw in text.replace('\r\n','\n').replace('\r','\n').splitlines():
            if re.match(r'(?i)^\s*gamedll_linux\s+',raw):
                continue
            out.append(raw)
        rel='dlls/cs.so'
        if meta:
            rel=str(meta.relative_to(cstrike)).replace('\\','/')
        out.append(f'gamedll_linux "{rel}"')
        lib.write_text('\n'.join(out).rstrip()+'\n',encoding='latin1')
        actions.append('canonicalized liblist.gam to one gamedll_linux')

    # Old hosting exports sometimes carry a Metamod gamedll override. If it
    # points to Metamod (or simply overrides the CS GameDLL), a managed/modern
    # loader can recursively load Metamod a second time. For cstrike the normal
    # auto-detected GameDLL is dlls/cs.so, so remove those overrides.
    meta_cfg=cstrike/'addons/metamod/config.ini'
    if meta_cfg.is_file():
        text=meta_cfg.read_text(encoding='latin1',errors='ignore')
        out=[]; changed=False
        for raw in text.replace('\r\n','\n').replace('\r','\n').splitlines():
            st=raw.strip()
            if st and not st.startswith((';','#','//')) and re.match(r'(?i)^gamedll\b',st):
                out.append('; HYPER-HOST v3.19 removed recursive/legacy GameDLL override: '+raw)
                changed=True
            else:
                out.append(raw)
        if changed:
            meta_cfg.write_text('\n'.join(out).rstrip()+'\n',encoding='latin1')
            actions.append('removed Metamod gamedll override')

    # Exactly one active AMXX loader and never let Metamod load itself from its
    # own plugins.ini.
    mp=cstrike/'addons/metamod/plugins.ini'
    mp.parent.mkdir(parents=True,exist_ok=True)
    text=mp.read_text(encoding='latin1',errors='ignore') if mp.exists() else ''
    out=[]; amxx_seen=False
    for raw in text.replace('\r\n','\n').replace('\r','\n').splitlines():
        st=raw.strip(); low=st.lower()
        active=bool(st and not st.startswith((';','#','//')))
        if active and 'addons/metamod' in low and '.so' in low:
            out.append('; HYPER-HOST v3.19 disabled recursive Metamod self-load: '+raw)
            continue
        if active and 'amxmodx' in low:
            if not amxx_seen and amxx:
                rel=str(amxx.relative_to(cstrike)).replace('\\','/')
                out.append('linux '+rel)
                amxx_seen=True
            continue
        out.append(raw)
    if amxx and not amxx_seen:
        rel=str(amxx.relative_to(cstrike)).replace('\\','/')
        out.append('linux '+rel)
    mp.write_text('\n'.join(out).rstrip()+'\n',encoding='latin1')
    actions.append('canonicalized Metamod plugins.ini')

    # De-duplicate explicit AMXX module entries. This preserves module choices
    # but prevents the same module line being processed twice in old packs.
    modules=cstrike/'addons/amxmodx/configs/modules.ini'
    if modules.is_file():
        text=modules.read_text(encoding='latin1',errors='ignore')
        out=[]; seen=set(); changed=False
        for raw in text.replace('\r\n','\n').replace('\r','\n').splitlines():
            st=raw.strip()
            if not st or st.startswith((';','#','//')):
                out.append(raw); continue
            token=st.split(';',1)[0].strip().split()[0].lower() if st.split(';',1)[0].strip() else ''
            if token and token in seen:
                out.append('; HYPER-HOST v3.19 duplicate disabled: '+raw)
                changed=True
                continue
            if token: seen.add(token)
            out.append(raw)
        if changed:
            modules.write_text('\n'.join(out).rstrip()+'\n',encoding='latin1')
            actions.append('de-duplicated modules.ini')

    return {'ok':True,'actions':actions,'inventory':_v319_runtime_inventory(path)}


def _v319_prepare_runtime(path:Path,c:dict)->dict:
    policy=_v319_runtime_policy(c)
    before=_v319_runtime_inventory(path)
    actions=[]

    # AUTO and ASSEMBLY preserve uploaded versions at first. MANAGED explicitly
    # replaces only the selected component family.
    if policy['engine']=='managed':
        install_rehlds(path)
        actions.append('managed ReHLDS/ReGameDLL selected')
    if policy['metamod']=='managed':
        current=_v319_runtime_inventory(path)
        if str((current.get('engine') or {}).get('kind') or '')=='ReHLDS':
            install_metamod_rehlds(path)
            actions.append('managed Metamod-R selected for ReHLDS')
        else:
            install_metamod_classic(path)
            actions.append('managed Metamod 1.21.1-am selected for classic HLDS')
    if policy['amxx']=='managed':
        if '_v316_refresh_amxx_platform' not in globals():
            install_amxx(path)
        else:
            actions.extend(_v316_refresh_amxx_platform(path))
        actions.append('managed AMX Mod X selected')

    clean=_v319_sanitize_loader_chain(path)
    actions.extend(clean.get('actions') or [])
    after=_v319_runtime_inventory(path)
    return {'ok':True,'policy':policy,'assembly':before,'active':after,'actions':actions}


def _v319_adaptive_repair(path:Path,c:dict,journal:str)->dict:
    policy=_v319_runtime_policy(c)
    low=str(journal or '').lower()
    actions=[]

    duplicate_meta=any(x in low for x in (
        'the same handler can\'t be used twice on the hookchain',
        'metamod_version", already defined',
        'cmd_addmalloccommand: "meta" already defined',
        'amxmodx_version", already defined',
        'cmd_addmalloccommand: "amxx" already defined',
    ))
    bad_amxx=any(x in low for x in (
        'failed query plugin',
        'failed to load plugin \'amxmodx',
        'amxmodx_mm_i386.so\\n',
    ))
    legacy_ham=('failed to retrieve vtable' in low and ('amx mod x version 1.8.' in low or 'invalid cvar pointer' in low))
    needs_reapi=('you need rehlds or regamedll' in low)

    if duplicate_meta:
        r=_v319_sanitize_loader_chain(path)
        actions.extend(r.get('actions') or [])
        actions.append('AUTO: repaired duplicate Metamod/AMXX loader chain')
        return {'ok':True,'actions':actions,'reason':'duplicate-loader'}

    if needs_reapi and policy['engine']=='auto':
        install_rehlds(path)
        _v319_sanitize_loader_chain(path)
        actions.append('AUTO: ReAPI requested ReHLDS/ReGameDLL')
        return {'ok':True,'actions':actions,'reason':'reapi'}

    if (legacy_ham or bad_amxx) and policy['amxx']=='auto':
        if '_v316_refresh_amxx_platform' in globals():
            actions.extend(_v316_refresh_amxx_platform(path))
        else:
            install_amxx(path)
        _v319_sanitize_loader_chain(path)
        actions.append('AUTO: replaced incompatible AMXX runtime')
        return {'ok':True,'actions':actions,'reason':'amxx'}

    return {'ok':False,'actions':[],'reason':'no-safe-automatic-repair'}


def runtime_status(sid:int):
    c=load_server(sid); path=safe_server_path(sid)
    inv=_v319_runtime_inventory(path)
    policy=_v319_runtime_policy(c)
    live={}
    try:
        if service_status(sid)=='active':
            for key,cmd in (('engine','version'),('metamod','meta version'),('amxx','amxx version'),('meta_list','meta list')):
                rr=rcon_cmd(sid,cmd)
                live[key]=str(rr.get('output') or '')[-6000:]
    except Exception as exc:
        live['error']=str(exc)
    return {'ok':True,'id':sid,'policy':policy,'inventory':inv,'live':live}


def runtime_policy_set(sid:int,payload:dict):
    allowed={'auto','assembly','managed'}
    c=load_server(sid)
    policy={}
    for key in ('engine','metamod','amxx'):
        value=str(payload.get(key) or 'auto').strip().lower()
        if value not in allowed: raise RuntimeError('Invalid runtime policy: '+key)
        policy[key]=value
    c['runtime_policy']=policy
    save_server(c)
    return {'ok':True,'id':sid,'policy':policy,'note':'assembly choices are applied on the next assembly upload; managed choices can be applied now'}


def runtime_repair_chain(sid:int):
    require_root(); c=load_server(sid); path=safe_server_path(sid)
    backup=path.parent/BUILD_BACKUP_DIR_NAME/f'{sid}-runtime-chain-{time.strftime("%Y%m%d-%H%M%S")}-{secrets.token_hex(4)}'
    backup.mkdir(parents=True,exist_ok=True)
    for rel in ('cstrike/liblist.gam','cstrike/addons/metamod/config.ini','cstrike/addons/metamod/plugins.ini','cstrike/addons/amxmodx/configs/modules.ini'):
        src=path/rel
        if src.is_file():
            dst=backup/rel; dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,dst)
    run(['systemctl','stop',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
    repair=_v319_sanitize_loader_chain(path)
    normalize_permissions(path)
    run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
    run(['systemctl','start',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
    ok,detail=wait_server_ready(load_server(sid),45.0)
    return {'ok':ok,'id':sid,'backup':str(backup),'query':detail,'actions':repair.get('actions') or [],'runtime':_v319_runtime_inventory(path)}


def runtime_apply(sid:int):
    require_root(); c=load_server(sid); path=safe_server_path(sid)
    policy=_v319_runtime_policy(c); actions=[]
    backup=path.parent/BUILD_BACKUP_DIR_NAME/f'{sid}-runtime-apply-{time.strftime("%Y%m%d-%H%M%S")}-{secrets.token_hex(4)}'
    backup.mkdir(parents=True,exist_ok=True)
    for rel in ('hlds_linux','engine_i486.so','cstrike/dlls/cs.so','cstrike/liblist.gam','cstrike/addons/metamod','cstrike/addons/amxmodx/dlls','cstrike/addons/amxmodx/modules','cstrike/addons/amxmodx/configs/hamdata.ini'):
        src=path/rel
        if src.exists():
            dst=backup/rel; dst.parent.mkdir(parents=True,exist_ok=True)
            if src.is_dir(): shutil.copytree(src,dst,dirs_exist_ok=True)
            else: shutil.copy2(src,dst)
    run(['systemctl','stop',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
    if policy['engine']=='managed': install_rehlds(path); actions.append('applied managed ReHLDS/ReGameDLL')
    if policy['metamod']=='managed':
        current=_v319_runtime_inventory(path)
        if str((current.get('engine') or {}).get('kind') or '')=='ReHLDS':
            install_metamod_rehlds(path); actions.append('applied managed Metamod-R')
        else:
            install_metamod_classic(path); actions.append('applied managed Metamod 1.21.1-am')
    if policy['amxx']=='managed':
        if '_v316_refresh_amxx_platform' in globals(): actions.extend(_v316_refresh_amxx_platform(path))
        else: install_amxx(path); actions.append('applied managed AMXX')
    actions.extend((_v319_sanitize_loader_chain(path).get('actions') or []))
    normalize_permissions(path)
    run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
    run(['systemctl','start',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
    ok,detail=wait_server_ready(load_server(sid),45.0)
    return {'ok':ok,'id':sid,'backup':str(backup),'query':detail,'actions':actions,'policy':policy,'runtime':_v319_runtime_inventory(path)}
# <<< HYPER-HOST v3.19 ADAPTIVE RUNTIME <<<
'''


def _replace_once(src:str, old:str, new:str, label:str)->str:
    if old not in src:
        raise RuntimeError(f'missing patch point: {label}')
    return src.replace(old,new,1)


def patch_controller(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src
    if 'def _v316_refresh_amxx_platform(' not in src:
        raise RuntimeError('v3.19 expects the v3.16/v3.18 controller to be installed first')

    if CTL_MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos<0: raise RuntimeError('install_custom_build not found')
        src=src[:pos]+'\n'+HELPER+src[pos:]

    # Replace forced managed runtime with adaptive policy-based preparation.
    old="""        # HYPER-HOST v3.16 normalize uploaded platform before first start
        platform_runtime=_v316_normalize_platform(stage)
        c['profile']='rehlds'
        runtime_profile=_analyze_build_runtime(stage/'cstrike')
        reapi_compat=_ensure_reapi_compatible_stack(stage)
        runtime_profile=_analyze_build_runtime(stage/'cstrike')
"""
    new="""        # HYPER-HOST v3.19: preserve assembly runtime first; replace only by policy/compatibility.
        platform_runtime=_v319_prepare_runtime(stage,c)
        runtime_profile=_analyze_build_runtime(stage/'cstrike')
        reapi_compat=_ensure_reapi_compatible_stack(stage)
        # ReAPI repair may have changed engine/GameDLL; canonicalize the loader chain again.
        _v319_sanitize_loader_chain(stage)
        runtime_profile=_analyze_build_runtime(stage/'cstrike')
"""
    if old in src:
        src=src.replace(old,new,1)
    elif 'platform_runtime=_v319_prepare_runtime(stage,c)' not in src:
        raise RuntimeError('managed-runtime patch point not found')

    src=src.replace("        import_mode=import_mode+'+managed-runtime-v316'\n", "        import_mode=import_mode+'+runtime-v319-'+str(platform_runtime.get('policy',{}).get('engine','auto'))+'-'+str(platform_runtime.get('policy',{}).get('metamod','auto'))+'-'+str(platform_runtime.get('policy',{}).get('amxx','auto'))\n",1)

    # Add adaptive repair before hard rollback.
    old_fail="""            if not ok:
                journal=_recent_failure_log(sid,220)
                broken,assets=_parse_plugin_failures(journal)
                hint=''
                if broken: hint+=' Broken AMXX: '+', '.join(dict.fromkeys(broken))[:1400]+'.'
                if assets: hint+=' Missing resources: '+', '.join(dict.fromkeys(assets))[:1400]+'.'
                if external_fastdl: hint+=' Previous FastDL checked: '+external_fastdl[:500]+'.'
                raise RuntimeError(f'Uploaded assembly cannot keep HLDS running: {detail}.{hint} {journal[-7000:]}')
"""
    new_fail="""            if not ok:
                adaptive_actions=[]
                # AUTO mode repairs one proven incompatibility at a time and retries.
                for _attempt in range(3):
                    journal=_recent_failure_log(sid,260)
                    adaptive=_v319_adaptive_repair(path,c,journal)
                    acts=list(adaptive.get('actions') or [])
                    if not acts:
                        break
                    adaptive_actions.extend(acts)
                    normalize_permissions(path)
                    run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
                    run(['systemctl','restart',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
                    ok,detail=wait_server_ready(c,45.0)
                    if ok:
                        break
                if adaptive_actions:
                    platform_runtime.setdefault('actions',[]).extend(adaptive_actions)
                    platform_runtime['active']=_v319_runtime_inventory(path)
                if not ok:
                    journal=_recent_failure_log(sid,220)
                    broken,assets=_parse_plugin_failures(journal)
                    hint=''
                    if broken: hint+=' Broken AMXX: '+', '.join(dict.fromkeys(broken))[:1400]+'.'
                    if assets: hint+=' Missing resources: '+', '.join(dict.fromkeys(assets))[:1400]+'.'
                    if external_fastdl: hint+=' Previous FastDL checked: '+external_fastdl[:500]+'.'
                    raise RuntimeError(f'Uploaded assembly cannot keep HLDS running: {detail}.{hint} {journal[-7000:]}')
"""
    if old_fail in src:
        src=src.replace(old_fail,new_fail,1)
    elif 'adaptive_actions=[]' not in src:
        raise RuntimeError('hard-failure adaptive repair patch point not found')

    # Result should expose both source and active runtime.
    old_result="""                'runtime_fill':runtime_fill,'platform_runtime':platform_runtime,'reapi_compat':reapi_compat,'archive_manifest':manifest,
"""
    if old_result in src:
        new_result="""                'runtime_fill':runtime_fill,'platform_runtime':platform_runtime,'assembly_runtime':platform_runtime.get('assembly',{}),'active_runtime':_v319_runtime_inventory(path),'runtime_policy':_v319_runtime_policy(c),'reapi_compat':reapi_compat,'archive_manifest':manifest,
"""
        src=src.replace(old_result,new_result,1)

    # install_metamod_rehlds() may leave legacy loader directives from an uploaded
    # pack. v3.19 always runs _v319_sanitize_loader_chain() after runtime
    # selection, so no global rewrite of the base helper is required here.

    # CLI parsers.
    list_old="'delete','repair-runtime','build-repair-current','mods-status','nat-upnp'"
    list_new="'delete','repair-runtime','build-repair-current','mods-status','runtime-status','runtime-apply','runtime-repair-chain','nat-upnp'"
    if list_old in src:
        src=src.replace(list_old,list_new,1)

    parser_anchor="    q=sp.add_parser('map-pool-set'); q.add_argument('id',type=int)\n"
    if "sp.add_parser('runtime-policy-set')" not in src:
        if parser_anchor not in src: raise RuntimeError('CLI parser anchor missing')
        src=src.replace(parser_anchor, parser_anchor+"    q=sp.add_parser('runtime-policy-set'); q.add_argument('id',type=int)\n",1)

    branch_anchor="        elif args.cmd=='plugins': result=plugins_list(args.id)\n"
    if "elif args.cmd=='runtime-status'" not in src:
        if branch_anchor not in src: raise RuntimeError('CLI branch anchor missing')
        src=src.replace(branch_anchor, branch_anchor+"        elif args.cmd=='runtime-status': result=runtime_status(args.id)\n        elif args.cmd=='runtime-apply': result=runtime_apply(args.id)\n        elif args.cmd=='runtime-repair-chain': result=runtime_repair_chain(args.id)\n        elif args.cmd=='runtime-policy-set':\n            raw=sys.stdin.buffer.read(64*1024+1)\n            if len(raw)>64*1024: raise RuntimeError('Runtime policy payload is too large')\n            try: payload=json.loads(raw.decode('utf-8','replace') or '{}')\n            except Exception: raise RuntimeError('Invalid runtime policy payload')\n            if not isinstance(payload,dict): raise RuntimeError('Invalid runtime policy payload')\n            result=runtime_policy_set(args.id,payload)\n",1)

    # Final validation.
    required=[
        CTL_MARKER,
        'platform_runtime=_v319_prepare_runtime(stage,c)',
        'def runtime_status(sid:int):',
        'def runtime_policy_set(sid:int,payload:dict):',
        'def runtime_repair_chain(sid:int):',
        "elif args.cmd=='runtime-status'",
        "sp.add_parser('runtime-policy-set')",
    ]
    missing=[x for x in required if x not in src]
    if missing: raise RuntimeError('controller verification failed: '+repr(missing))

    tmp=path.with_name(path.name+'.v319tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True)
    os.replace(tmp,path)
    print('[PATCHED]',path)


POST_HANDLER = r'''        if($action==='runtime_policy_save'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);server_row($id);
            $payload=['engine'=>(string)($_POST['runtime_engine']??'auto'),'metamod'=>(string)($_POST['runtime_metamod']??'auto'),'amxx'=>(string)($_POST['runtime_amxx']??'auto')];
            $r=ctl(['runtime-policy-set',$id],30,json_encode($payload,JSON_UNESCAPED_UNICODE));if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось сохранить runtime-политику'));
            audit('runtime_policy_save',json_encode($payload,JSON_UNESCAPED_UNICODE),$id);flash('Runtime-политика сохранена. Режим «Сборка» применяется при следующей загрузке архива; «HYPER-HOST» можно применить сейчас.');redirect('/?page=server&id='.$id.'#runtime');
        }
        if($action==='runtime_apply'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);server_row($id);$r=ctl(['runtime-apply',$id],1200);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Runtime не удалось применить'));
            $acts=is_array($r['actions']??null)?$r['actions']:[];audit('runtime_apply',implode('; ',$acts),$id);flash('Runtime применён. '.implode('; ',array_slice($acts,0,10)).' Backup: '.((string)($r['backup']??'')));redirect('/?page=server&id='.$id.'#runtime');
        }
        if($action==='runtime_repair_chain'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);server_row($id);$r=ctl(['runtime-repair-chain',$id],300);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Цепочку загрузки исправить не удалось'));
            $acts=is_array($r['actions']??null)?$r['actions']:[];audit('runtime_repair_chain',implode('; ',$acts),$id);flash('Цепочка Engine → Metamod → AMXX исправлена. '.implode('; ',array_slice($acts,0,10)));redirect('/?page=server&id='.$id.'#runtime');
        }
'''

RUNTIME_TAB = r'''<div class="tab-pane fade" id="runtime">
<?php $rp=is_array($runtimeInfo['policy']??null)?$runtimeInfo['policy']:['engine'=>'auto','metamod'=>'auto','amxx'=>'auto'];$ri=is_array($runtimeInfo['inventory']??null)?$runtimeInfo['inventory']:[];$lc=is_array($ri['loader_chain']??null)?$ri['loader_chain']:[]; ?>
<section class="panel-card"><div class="panel-head"><div><h2>Runtime сборки</h2><p>Панель показывает реальные компоненты текущего сервера. AUTO сначала сохраняет версии сборки и меняет только компонент, для которого журнал доказал несовместимость.</p></div><span class="feature-chip <?=!empty($lc['healthy'])?'on':'off'?>"><?=!empty($lc['healthy'])?'ЦЕПОЧКА OK':'НУЖНА ПРОВЕРКА'?></span></div>
<div class="resource-live-grid">
<div><small>Engine</small><b><?=e((string)($ri['engine']['kind']??'—'))?></b><small><?=e((string)($ri['engine']['version']??''))?></small></div>
<div><small>GameDLL</small><b><?=e((string)($ri['gamedll']['kind']??'—'))?></b><small><?=e((string)($ri['gamedll']['version']??''))?></small></div>
<div><small>Metamod</small><b><?=e((string)($ri['metamod']['kind']??'—'))?></b><small><?=e((string)($ri['metamod']['version']??''))?></small></div>
<div><small>AMX Mod X</small><b><?=e((string)($ri['amxx']['kind']??'—'))?></b><small><?=e((string)($ri['amxx']['version']??''))?></small></div>
<div><small>ReAPI</small><b><?=!empty($ri['reapi']['installed'])?'Установлен':'Нет'?></b><small><?=e((string)($ri['reapi']['version']??''))?></small></div>
<div><small>Loader chain</small><b><?=!empty($lc['healthy'])?'OK':'CHECK'?></b><small>GameDLL: <?=count($lc['liblist_gamedll_linux']??[])?> · AMXX lines: <?=count($lc['metamod_amxx_lines']??[])?></small></div>
</div>
</section>
<section class="panel-card mt-3"><div class="panel-head"><div><h2>Политика совместимости</h2><p><b>AUTO</b> — рекомендовано. <b>Сборка</b> — не заменять компонент архива. <b>HYPER-HOST</b> — использовать управляемый компонент.</p></div></div>
<form method="post" class="form-grid"><?=csrf_field()?><input type="hidden" name="action" value="runtime_policy_save"><input type="hidden" name="id" value="<?=$id?>">
<label><span>Engine + GameDLL</span><select class="form-select" name="runtime_engine"><?php foreach(['auto'=>'AUTO — менять только при необходимости','assembly'=>'Сборка — оставить как в архиве','managed'=>'HYPER-HOST — ReHLDS + ReGameDLL'] as $v=>$l):?><option value="<?=$v?>" <?=($rp['engine']??'auto')===$v?'selected':''?>><?=e($l)?></option><?php endforeach;?></select></label>
<label><span>Metamod</span><select class="form-select" name="runtime_metamod"><?php foreach(['auto'=>'AUTO — менять только при необходимости','assembly'=>'Сборка — оставить как в архиве','managed'=>'HYPER-HOST — совместимый Metamod'] as $v=>$l):?><option value="<?=$v?>" <?=($rp['metamod']??'auto')===$v?'selected':''?>><?=e($l)?></option><?php endforeach;?></select></label>
<label><span>AMX Mod X</span><select class="form-select" name="runtime_amxx"><?php foreach(['auto'=>'AUTO — менять только при необходимости','assembly'=>'Сборка — оставить как в архиве','managed'=>'HYPER-HOST — AMXX 1.9.x'] as $v=>$l):?><option value="<?=$v?>" <?=($rp['amxx']??'auto')===$v?'selected':''?>><?=e($l)?></option><?php endforeach;?></select></label>
<div class="wide d-flex gap-2 flex-wrap"><button class="btn btn-primary"><i class="fa-solid fa-floppy-disk me-2"></i>Сохранить политику</button></div></form>
<div class="callout mt-3"><i class="fa-solid fa-circle-info"></i><div><b>Как это работает</b><p>AUTO не переписывает runtime заранее. Если после загрузки журнал показывает ReAPI без ReHLDS, старый AMXX/Ham или двойную загрузку Metamod, панель исправляет только доказанную проблему и перезапускает один раз.</p></div></div>
</section>
<section class="hosting-grid mt-3"><div class="panel-card"><div class="panel-head"><div><h2>Применить выбранный runtime</h2><p>Для текущего сервера применяет только компоненты, выбранные как HYPER-HOST. «Сборка» восстанавливается повторной загрузкой исходного архива.</p></div></div><form method="post" onsubmit="return confirm('Применить выбранные управляемые компоненты и перезапустить сервер?')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_apply"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-primary"><i class="fa-solid fa-gears me-2"></i>Применить сейчас</button></form></div>
<div class="panel-card"><div class="panel-head"><div><h2>Цепочка загрузки</h2><p>Исправляет только liblist.gam, Metamod config/plugins.ini и дубли modules.ini. Версии Engine/Metamod/AMXX не меняются.</p></div></div><form method="post" onsubmit="return confirm('Исправить двойную загрузку Metamod/AMXX и перезапустить сервер?')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_repair_chain"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-soft"><i class="fa-solid fa-link me-2"></i>Исправить цепочку загрузки</button></form></div></section>
<section class="panel-card mt-3"><div class="panel-head"><div><h2>Файлы runtime</h2></div></div><div class="info-list"><div><span>Engine</span><b><?=e((string)($ri['engine']['path']??'—'))?></b></div><div><span>GameDLL</span><b><?=e((string)($ri['gamedll']['path']??'—'))?></b></div><div><span>Metamod</span><b><?=e((string)($ri['metamod']['path']??'—'))?></b></div><div><span>AMXX loader</span><b><?=e((string)($ri['amxx']['path']??'—'))?></b></div></div></section>
</div>
'''


def patch_index(path:Path):
    src=path.read_text(encoding='utf-8',errors='ignore')
    original=src
    if "if($action==='runtime_policy_save')" not in src:
        anchor="        if($action==='delete_server'){\n"
        if anchor not in src: raise RuntimeError(f'{path}: POST anchor missing')
        src=src.replace(anchor,POST_HANDLER+anchor,1)

    if "$runtimeInfo=ctl(['runtime-status',$id],20);" not in src:
        old="$mods=ctl(['mods-status',$id],15);"
        if old not in src: raise RuntimeError(f'{path}: server init anchor missing')
        src=src.replace(old,"$runtimeInfo=ctl(['runtime-status',$id],20);if(empty($runtimeInfo['ok']))$runtimeInfo=['policy'=>['engine'=>'auto','metamod'=>'auto','amxx'=>'auto'],'inventory'=>[]];"+old,1)

    if 'data-bs-target="#runtime"' not in src:
        old="<li><button data-bs-toggle=\"pill\" data-bs-target=\"#mods\">Моды</button></li>"
        if old not in src: raise RuntimeError(f'{path}: tabs anchor missing')
        src=src.replace(old,old+"<li><button data-bs-toggle=\"pill\" data-bs-target=\"#runtime\">Runtime</button></li>",1)

    if 'id="runtime"' not in src:
        anchor='<div class="tab-pane fade" id="ftp">'
        if anchor not in src:
            # Insert before logs if FTP is conditionally absent in source layout.
            anchor='<div class="tab-pane fade" id="logs">'
        if anchor not in src: raise RuntimeError(f'{path}: runtime pane anchor missing')
        src=src.replace(anchor,RUNTIME_TAB+anchor,1)

    # Add runtime summary to assembly success messages (both upload + URL handlers).
    marker="if(!$healthy)$msg.=' Сборка оставлена установленной"
    if 'Runtime активный:' not in src and marker in src:
        insert="$ari=is_array($r['active_runtime']??null)?$r['active_runtime']:[];$aa=is_array($ari['amxx']??null)?$ari['amxx']:[];$mm=is_array($ari['metamod']??null)?$ari['metamod']:[];$eng=is_array($ari['engine']??null)?$ari['engine']:[];if($ari)$msg.=' Runtime активный: '.(string)($eng['kind']??'Engine').' '.(string)($eng['version']??'').' / '.(string)($mm['kind']??'Metamod').' '.(string)($mm['version']??'').' / AMXX '.(string)($aa['version']??'не определён').'.';"
        src=src.replace(marker,insert+marker,1)
        # second occurrence for URL
        if marker in src:
            src=src.replace(marker,insert+marker,1)

    if src!=original:
        path.write_text(src,encoding='utf-8')
        print('[PATCHED UI]',path)
    else:
        print('[OK UI already patched]',path)


def main():
    if len(sys.argv)<3:
        print('usage: patch_v319.py ctl|index PATH',file=sys.stderr); return 2
    mode=sys.argv[1]; path=Path(sys.argv[2])
    if mode=='ctl': patch_controller(path)
    elif mode=='index': patch_index(path)
    else: raise RuntimeError('unknown mode')
    return 0

if __name__=='__main__':
    raise SystemExit(main())

PY_V319_PATCH

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local safe
  safe="$(printf '%s' "$f" | sed 's#^/##;s#/#__#g')"
  cp -a "$f" "$BACKUP/$safe"
}

echo "[1/9] Backing up live controller..."
backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"

echo
echo "[2/9] Patching LIVE controller with adaptive runtime logic..."
python3 "$PATCHER" ctl "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || {
  cp -a "$BACKUP/$(printf '%s' "$LIVE_CTL" | sed 's#^/##;s#/#__#g')" "$LIVE_CTL" || true
  die "Live controller syntax validation failed"
}

echo "[OK] live controller syntax"

echo
echo "[3/9] Making repository controller match the verified LIVE controller..."
install -m 0755 "$LIVE_CTL" "$REPO_CTL"
python3 -m py_compile "$REPO_CTL" || die "Repository controller validation failed"

echo "[OK] repository controller synchronized"

echo
echo "[4/9] Discovering active CS16 panel document roots..."

for root in   "/var/www/hyper-host-sites/$DOMAIN/public_html"   "/var/www/$DOMAIN/public_html"   "/var/www/$DOMAIN"
do
  [[ -f "$root/index.php" ]] && echo "$root" >>"$ROOTS"
done

if command -v nginx >/dev/null 2>&1; then
  nginx -T >"$NGTMP" 2>&1 || true
  python3 - "$NGTMP" "$DOMAIN" >>"$ROOTS" <<'PY_ROOTS'
import re,sys
text=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
domain=sys.argv[2]
for block in re.findall(r'server\s*\{.*?\n\}',text,re.S):
    if domain not in block:
        continue
    for root in re.findall(r'(?m)^\s*root\s+([^;]+);',block):
        root=root.strip()
        if root.startswith('/'):
            print(root)
PY_ROOTS
fi

while IFS= read -r idx; do
  grep -q "serverTabs" "$idx" 2>/dev/null || continue
  grep -q "page==='server'" "$idx" 2>/dev/null || continue
  echo "$(dirname "$idx")" >>"$ROOTS"
done < <(find /var/www -xdev -type f -name index.php 2>/dev/null || true)

sort -u "$ROOTS" -o "$ROOTS"

COUNT=0
FIRST_ROOT=""
while IFS= read -r DOCROOT; do
  [[ -n "$DOCROOT" ]] || continue
  [[ -f "$DOCROOT/index.php" ]] || continue
  grep -q "serverTabs" "$DOCROOT/index.php" || continue

  COUNT=$((COUNT+1))
  [[ -n "$FIRST_ROOT" ]] || FIRST_ROOT="$DOCROOT"

  backup_file "$DOCROOT/index.php"
  [[ -f "$DOCROOT/assets/app.js" ]] && backup_file "$DOCROOT/assets/app.js"
  [[ -f "$DOCROOT/assets/style.css" ]] && backup_file "$DOCROOT/assets/style.css"

  python3 "$PATCHER" index "$DOCROOT/index.php" || die "Panel patch failed: $DOCROOT"
  php -l "$DOCROOT/index.php" >/dev/null || die "PHP syntax failed: $DOCROOT/index.php"

  echo "[PATCHED PANEL] $DOCROOT"
done <"$ROOTS"

[[ "$COUNT" -gt 0 ]] || die "No active CS16 panel root found"

echo "[OK] patched $COUNT live panel root(s)"

echo
echo "[5/9] Synchronizing patched live panel source back into current repo checkout..."
if [[ -n "$FIRST_ROOT" ]]; then
  install -m 0644 "$FIRST_ROOT/index.php" "$REPO/cs16-panel/public/index.php"
  if [[ -f "$FIRST_ROOT/assets/app.js" ]]; then
    install -m 0644 "$FIRST_ROOT/assets/app.js" "$REPO/cs16-panel/public/assets/app.js"
  fi
  if [[ -f "$FIRST_ROOT/assets/style.css" ]]; then
    install -m 0644 "$FIRST_ROOT/assets/style.css" "$REPO/cs16-panel/public/assets/style.css"
  fi
fi

php -l "$REPO/cs16-panel/public/index.php" >/dev/null || die "Repo PHP syntax failed"
if command -v node >/dev/null 2>&1 && [[ -f "$REPO/cs16-panel/public/assets/app.js" ]]; then
  node --check "$REPO/cs16-panel/public/assets/app.js" >/dev/null || die "Repo JS syntax failed"
fi

echo "[OK] repo panel source synchronized"

echo
echo "[6/9] Reloading PHP-FPM..."
while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*fpm/ {print $1}')

echo
echo "[7/9] Setting AUTO policy as default for current server #$SID..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  printf '%s' '{"engine":"auto","metamod":"auto","amxx":"auto"}' |     "$LIVE_CTL" runtime-policy-set "$SID" || die "Could not set AUTO runtime policy"
else
  echo "[INFO] Server #$SID does not exist; policy will default to AUTO on future servers."
fi

echo
echo "[8/9] Repairing duplicate Metamod/AMXX loader chain on current server #$SID..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  set +e
  REPAIR_OUT="$("$LIVE_CTL" runtime-repair-chain "$SID" 2>&1)"
  REPAIR_RC=$?
  set -e
  echo "$REPAIR_OUT"

  if [[ "$REPAIR_RC" -ne 0 ]]; then
    echo "[WARN] Current server still did not become healthy after loader-chain repair."
    echo "[WARN] v3.19 itself IS installed; the next assembly upload will use adaptive runtime logic."
  else
    echo "[OK] current loader chain repaired"
  fi
else
  echo "[INFO] Current-server repair skipped."
fi

echo
echo "[9/9] Runtime inventory / selected policy..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  "$LIVE_CTL" runtime-status "$SID" || true
fi

echo
echo "============================================================"
echo " v3.19 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "Default import behavior is now AUTO:"
echo " - preserve assembly Engine/GameDLL first"
echo " - preserve assembly Metamod first"
echo " - preserve assembly AMXX first"
echo " - sanitize only the loader chain"
echo " - if a proven incompatibility appears, replace only that component"
echo
echo "Panel: Server -> Runtime"
echo "You can choose AUTO / Сборка / HYPER-HOST separately for:"
echo " - Engine + GameDLL"
echo " - Metamod"
echo " - AMX Mod X"
echo
echo "The Runtime tab also shows detected versions and actual runtime file paths."
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
