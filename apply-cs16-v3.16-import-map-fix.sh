#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.16 — INSTALL FIX + MANAGED RUNTIME + MAP POOL
#
# Fixes the exact v3.14 crash:
#   local variable 'import_mode' referenced before assignment
#
# Also installs the map-pool feature without the v3.15 importlib loader bug:
#   AttributeError: 'NoneType' object has no attribute 'loader'
#
# It is safe to run over:
# - original v3.5 exact-archive controller;
# - v3.8/v3.9 runtime-patched controller;
# - partially/broken v3.14 controller;
# - partially applied v3.15 map-pool code.
#
# It does NOT run v3.3 and does NOT reinstall the whole panel.

SID="${1:-14}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PATCH_ONLY="${PATCH_ONLY:-0}"
DOMAIN="www.avito.hyper-host.pw"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.16-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.16-${STAMP}.log"
MANIFEST="$BACKUP/restore-paths.txt"
PATCHER="$(mktemp /tmp/hh-v316.XXXXXX.py)"
ROOT_FILE="$(mktemp /tmp/hh-v316-roots.XXXXXX)"
NGTMP="$(mktemp /tmp/hh-v316-nginx.XXXXXX)"

mkdir -p "$BACKUP/files"
: > "$MANIFEST"
exec > >(tee -a "$LOG") 2>&1

cleanup_tmp() {
  rm -f "$PATCHER" "$ROOT_FILE" "$NGTMP" 2>/dev/null || true
}

backup_one() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local dst="$BACKUP/files$src"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  printf '%s\n' "$src" >> "$MANIFEST"
}

rollback() {
  local rc="$?"
  trap - ERR
  echo
  echo "[ROLLBACK] A validation step failed. Restoring original files..."
  if [[ -f "$MANIFEST" ]]; then
    tac "$MANIFEST" | while IFS= read -r original; do
      [[ -n "$original" ]] || continue
      local_copy="$BACKUP/files$original"
      if [[ -f "$local_copy" ]]; then
        mkdir -p "$(dirname "$original")"
        cp -a "$local_copy" "$original"
        echo "[RESTORED] $original"
      fi
    done
  fi
  systemctl daemon-reload 2>/dev/null || true
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    systemctl reload "$svc" 2>/dev/null || true
  done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*fpm/ {print $1}')
  cleanup_tmp
  echo "[ROLLBACK] Done. Backup: $BACKUP"
  echo "[ROLLBACK] Log: $LOG"
  exit "$rc"
}

trap rollback ERR
trap cleanup_tmp EXIT

cat > "$PATCHER" <<'PY_PATCHER_V316'
from __future__ import annotations

import ast
import os
import py_compile
import re
import sys
from pathlib import Path

RUNTIME_MARKER = '# >>> HYPER-HOST v3.16 MANAGED PLATFORM >>>'
MAP_MARKER = '# >>> HYPER-HOST v3.16 MAP POOL >>>'

RUNTIME_HELPER = r'''
# >>> HYPER-HOST v3.16 MANAGED PLATFORM >>>
def _v316_refresh_amxx_platform(path:Path)->list[str]:
    # The uploaded archive owns plugins/configs/content, but not the executable
    # AMXX platform. Official runtime files are replaced as one coherent set.
    cstrike=path/'cstrike'
    dst=cstrike/'addons/amxmodx'
    dst.mkdir(parents=True,exist_ok=True)
    actions=[]

    with tempfile.TemporaryDirectory(prefix='hhcs16-v316-amxx-') as td:
        td=Path(td)
        payload=td/'payload'
        payload.mkdir(parents=True,exist_ok=True)

        base=td/'amxx-base.tgz'
        cs=td/'amxx-cstrike.tgz'
        download(AMXX_BASE,base)
        download(AMXX_CSTRIKE,cs)
        extract_tar(base,payload)
        extract_tar(cs,payload)

        src=payload/'addons/amxmodx'
        loader=src/'dlls/amxmodx_mm_i386.so'
        ham=src/'modules/hamsandwich_amxx_i386.so'
        if not loader.is_file() or not ham.is_file():
            raise RuntimeError('Managed AMXX runtime package is incomplete')

        # Replace official loader/modules, but do not delete uploaded custom
        # third-party modules that do not collide with official file names.
        for rel in ('dlls','modules'):
            source=src/rel
            target=dst/rel
            target.mkdir(parents=True,exist_ok=True)
            if source.is_dir():
                for fp in source.iterdir():
                    if fp.is_file():
                        shutil.copy2(fp,target/fp.name)

        # Ham binary and its vtable/signature data must be the same build.
        hamdata=src/'configs/hamdata.ini'
        if hamdata.is_file():
            target=dst/'configs/hamdata.ini'
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(hamdata,target)

        gamedata=src/'data/gamedata'
        if gamedata.is_dir():
            target=dst/'data/gamedata'
            target.mkdir(parents=True,exist_ok=True)
            shutil.copytree(gamedata,target,dirs_exist_ok=True)

    # Keep uploaded Metamod plugins, but force one managed AMXX loader. DProto
    # is an old stock-HLDS extension and is not loaded together with ReHLDS.
    mp=cstrike/'addons/metamod/plugins.ini'
    mp.parent.mkdir(parents=True,exist_ok=True)
    raw=mp.read_text(encoding='latin1',errors='replace') if mp.exists() else ''
    output=[]
    amxx_seen=False

    for raw_line in raw.replace('\\r\\n','\\n').replace('\\r','\\n').splitlines():
        stripped=raw_line.strip()
        low=stripped.lower()
        active=bool(stripped and not stripped.startswith(';') and not stripped.startswith('#'))

        if active and 'amxmodx' in low:
            if not amxx_seen:
                output.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')
                amxx_seen=True
            continue

        if active and 'dproto' in low:
            output.append('; HYPER-HOST v3.16 disabled on ReHLDS: '+raw_line)
            continue

        output.append(raw_line)

    if not amxx_seen:
        output.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')

    mp.write_text('\\n'.join(output).rstrip()+'\\n',encoding='latin1')
    actions.append('AMXX 1.9.0.'+str(AMXX_BUILD)+' core/modules/Ham data normalized')
    return actions


def _v316_normalize_platform(path:Path)->dict:
    # Archive = gameplay/content. HYPER-HOST = executable runtime.
    actions=[]

    install_rehlds(path)
    actions.append('ReHLDS '+str(REHLDS_VERSION)+' + ReGameDLL '+str(REGAMEDLL_VERSION))

    install_metamod_rehlds(path)
    actions.append('Metamod-R '+str(METAMOD_VERSION))

    actions.extend(_v316_refresh_amxx_platform(path))
    normalize_permissions(path)

    return {
        'ok':True,
        'profile':'hyper-host-v3.16',
        'actions':actions,
    }
# <<< HYPER-HOST v3.16 MANAGED PLATFORM <<<

'''

MAP_HELPER = r'''
# >>> HYPER-HOST v3.16 MAP POOL >>>
def _installed_map_names(c:dict)->list[str]:
    d=Path(c['path'])/'cstrike/maps'
    if not d.is_dir():
        return []
    return sorted({p.stem for p in d.glob('*.bsp') if SAFE_MAP.fullmatch(p.stem)},key=str.lower)


def _map_pool_state(c:dict)->tuple[list[str],list[str],bool]:
    installed=_installed_map_names(c)
    enabled=bool(c.get('map_pool_enabled',False))
    if not enabled:
        return installed,installed,False

    raw=c.get('map_pool') if isinstance(c.get('map_pool'),list) else []
    installed_set=set(installed)
    seen=set()
    allowed=[]
    for item in raw:
        name=str(item or '').strip()
        if name in installed_set and name not in seen and SAFE_MAP.fullmatch(name):
            seen.add(name)
            allowed.append(name)
    return installed,allowed,True


def _map_pool_write_files(c:dict,allowed:list[str]):
    root=Path(c['path'])/'cstrike'
    body='\\n'.join(allowed).rstrip()+'\\n'
    (root/'mapcycle.txt').write_text(body,encoding='utf-8')
    amxx=root/'addons/amxmodx/configs'
    amxx.mkdir(parents=True,exist_ok=True)
    (amxx/'maps.ini').write_text(body,encoding='utf-8')


def _map_pool_allowed(c:dict,map_name:str)->bool:
    installed,allowed,enabled=_map_pool_state(c)
    if map_name not in installed:
        return False
    return (not enabled) or map_name in allowed


def map_pool_reconcile(sid:int):
    c=load_server(sid)
    installed,allowed,enabled=_map_pool_state(c)
    if not installed:
        return {
            'ok':True,'enabled':enabled,'installed_maps':[],
            'allowed_maps':[],'start_map':str(c.get('start_map') or '')
        }

    if enabled:
        if not allowed:
            requested=str(c.get('start_map') or '')
            if requested in installed:
                allowed=[requested]
            else:
                zm=[x for x in installed if x.lower().startswith('zm_')]
                allowed=[zm[0] if zm else installed[0]]

        c['map_pool']=allowed
        if str(c.get('start_map') or '') not in allowed:
            c['start_map']=allowed[0]
            db_update_start_map(sid,allowed[0])

        _map_pool_write_files(c,allowed)
        save_server(c)
        normalize_permissions(Path(c['path']))

    return {
        'ok':True,
        'enabled':enabled,
        'installed_maps':installed,
        'allowed_maps':allowed if enabled else installed,
        'start_map':str(c.get('start_map') or ''),
    }


def map_pool_set(sid:int,payload:dict):
    require_root()
    c=load_server(sid)
    installed=_installed_map_names(c)
    installed_set=set(installed)

    raw=payload.get('maps') if isinstance(payload,dict) else None
    if not isinstance(raw,list):
        raise RuntimeError('Map list is required')

    selected=[]
    seen=set()
    for item in raw:
        name=str(item or '').strip()
        if not SAFE_MAP.fullmatch(name):
            raise RuntimeError('Invalid map name: '+name)
        if name not in installed_set:
            raise RuntimeError('Map is not installed on this server: '+name)
        if name not in seen:
            seen.add(name)
            selected.append(name)

    if not selected:
        raise RuntimeError('Select at least one map')

    start=str(payload.get('start_map') or '').strip()
    if start not in selected:
        start=selected[0]

    old_start=str(c.get('start_map') or '')
    c['map_pool_enabled']=True
    c['map_pool']=selected
    c['start_map']=start
    save_server(c)
    db_update_start_map(sid,start)

    _map_pool_write_files(c,selected)
    normalize_permissions(Path(c['path']))

    current=''
    if service_status(sid)=='active' and udp_listening(int(c['port'])):
        current,_=rcon_current_map(c)
        if current and current not in selected:
            changed=activate_map(sid,start)
            current=str(changed.get('current_map') or start)

    return {
        'ok':True,
        'enabled':True,
        'installed_maps':installed,
        'allowed_maps':selected,
        'maps':selected,
        'start_map':start,
        'current_map':current,
        'changed_start':old_start!=start,
    }
# <<< HYPER-HOST v3.16 MAP POOL <<<

'''


def _get_function(src: str, name: str) -> tuple[int,int,str]:
    start = src.find('def '+name+'(')
    if start < 0:
        return -1,-1,''
    end = src.find('\ndef ', start+10)
    if end < 0:
        end = len(src)
    return start,end,src[start:end]


def _replace_function(src: str, name: str, new_text: str) -> str:
    start,end,_ = _get_function(src,name)
    if start < 0:
        raise RuntimeError(f'{name} function not found')
    if not new_text.endswith('\n\n'):
        new_text = new_text.rstrip()+"\n\n"
    return src[:start] + new_text + src[end:]


def _ensure_runtime_platform(src: str) -> str:
    # UTF-8 subprocess fix, if this controller predates v3.8.
    old_run=(
        "cp=subprocess.run(cmd,stdout=subprocess.PIPE if capture else None,"
        "stderr=subprocess.STDOUT if capture else None,text=True,check=False,"
        "timeout=timeout,cwd=cwd,env=env)"
    )
    new_run=(
        "cp=subprocess.run(cmd,stdout=subprocess.PIPE if capture else None,"
        "stderr=subprocess.STDOUT if capture else None,text=True,"
        "encoding='utf-8',errors='replace',check=False,"
        "timeout=timeout,cwd=cwd,env=env)"
    )
    if old_run in src:
        src=src.replace(old_run,new_run,1)

    if RUNTIME_MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos < 0:
            raise RuntimeError('install_custom_build insertion point missing')
        src=src[:pos]+'\n'+RUNTIME_HELPER+src[pos:]

    st,en,fn=_get_function(src,'install_custom_build')
    if st < 0:
        raise RuntimeError('install_custom_build missing')

    # Remove the exact bad v3.13/v3.14 statement that caused:
    # local variable import_mode referenced before assignment.
    fn=re.sub(
        r"(?m)^\s*import_mode\s*=\s*str\(import_mode\)\s*\+\s*['\"]\+managed-runtime-v(?:313|314|315|316)['\"]\s*$\n?",
        '',
        fn,
    )
    # Collapse suffix lines left by earlier/repeated universal-runtime patches.
    fn=re.sub(
        r"(?m)^        import_mode\s*=\s*import_mode\s*\+\s*['\"]\+managed-runtime-v\d+['\"]\s*$\n?",
        '',
        fn,
    )

    # Use v3.16 normalizer even if old v3.13/v3.14 helpers are still present.
    fn=fn.replace(
        'platform_runtime=_v314_normalize_platform(stage)',
        'platform_runtime=_v316_normalize_platform(stage)'
    )
    fn=fn.replace(
        'platform_runtime=_v313_normalize_platform(stage)',
        'platform_runtime=_v316_normalize_platform(stage)'
    )

    if 'platform_runtime=_v316_normalize_platform(stage)' not in fn:
        candidates=[
            '        reapi_compat=_ensure_reapi_compatible_stack(stage)\n',
            "        runtime_preflight=_critical_runtime_preflight(stage/'cstrike',runtime_profile)\n",
        ]
        chosen=next((x for x in candidates if x in fn),None)
        if chosen is None:
            raise RuntimeError('safe runtime-normalization insertion point missing')
        block=(
            '        # HYPER-HOST v3.16 normalize uploaded platform before first start\n'
            '        platform_runtime=_v316_normalize_platform(stage)\n'
            "        c['profile']='rehlds'\n"
            "        runtime_profile=_analyze_build_runtime(stage/'cstrike')\n"
        )
        fn=fn.replace(chosen,block+chosen,1)
    else:
        # Ensure managed profile/runtime analysis immediately follows the call.
        needle='        platform_runtime=_v316_normalize_platform(stage)\n'
        if needle in fn and "        c['profile']='rehlds'\n" not in fn[fn.find(needle):fn.find(needle)+260]:
            fn=fn.replace(
                needle,
                needle+"        c['profile']='rehlds'\n        runtime_profile=_analyze_build_runtime(stage/'cstrike')\n",
                1,
            )

    # Normalize the ONLY authoritative assignment of import_mode. This is after
    # the platform work, so no read can occur before assignment.
    assign_re=re.compile(
        r"(?m)^        import_mode\s*=\s*(?:\(?['\"]exact-server-root['\"] if layout==['\"]server-root['\"] else ['\"]exact-cstrike-archive['\"]\)?)(?:\s*\+\s*['\"]\+managed-runtime-v\d+['\"])?\s*$"
    )
    if not assign_re.search(fn):
        raise RuntimeError('authoritative import_mode assignment missing')
    fn=assign_re.sub(
        "        import_mode='exact-server-root' if layout=='server-root' else 'exact-cstrike-archive'\n"
        "        import_mode=import_mode+'+managed-runtime-v316'",
        fn,
        count=1,
    )

    src=src[:st]+fn+src[en:]

    # Expose platform result in the success payload if a compatible result field exists.
    if "'platform_runtime':platform_runtime" not in src:
        options=[
            (
                "'runtime_profile':runtime_profile,'runtime_preflight':runtime_preflight,",
                "'runtime_profile':runtime_profile,'platform_runtime':platform_runtime,'runtime_preflight':runtime_preflight,",
            ),
            (
                "'runtime_profile':runtime_profile,",
                "'runtime_profile':runtime_profile,'platform_runtime':platform_runtime,",
            ),
        ]
        for old,new in options:
            if old in src:
                src=src.replace(old,new,1)
                break

    return src


def _assert_import_mode_safe(src: str):
    tree=ast.parse(src)
    target=None
    for node in tree.body:
        if isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name=='install_custom_build':
            target=node
            break
    if target is None:
        raise RuntimeError('install_custom_build AST node missing')

    assigns=[]
    loads=[]
    for node in ast.walk(target):
        if isinstance(node,ast.Name) and node.id=='import_mode':
            if isinstance(node.ctx,ast.Store):
                assigns.append((node.lineno,node.col_offset))
            elif isinstance(node.ctx,ast.Load):
                loads.append((node.lineno,node.col_offset))

    if not assigns:
        raise RuntimeError('import_mode has no assignment')
    first_assign=min(assigns)
    if loads and min(loads) < first_assign:
        raise RuntimeError(
            f'import_mode is still read before assignment: load={min(loads)}, assign={first_assign}'
        )


def _patch_map_pool(src: str) -> str:
    if MAP_MARKER not in src and 'def _installed_map_names(c:dict)' not in src:
        pos=src.find('\ndef map_list(sid:int):')
        if pos < 0:
            raise RuntimeError('map_list insertion point missing')
        src=src[:pos]+'\n'+MAP_HELPER+src[pos:]

    # map_list: when pool is enabled normal panel selectors receive only allowed maps.
    new_map_list="""def map_list(sid:int):
    c=load_server(sid)
    installed,allowed,enabled=_map_pool_state(c)
    current=str(c.get('start_map') or '')
    if service_status(sid)=='active' and udp_listening(int(c['port'])):
        rmap,_=rcon_current_map(c)
        if rmap:
            current=rmap
        else:
            qi,_=query_info_retry(int(c['port']),1)
            if qi:
                current=str(qi.get('map') or current)
    return {
        'ok':True,
        'maps':allowed,
        'installed_maps':installed,
        'allowed_maps':allowed,
        'map_pool_enabled':enabled,
        'current_map':current,
        'start_map':str(c.get('start_map') or ''),
    }


"""
    src=_replace_function(src,'map_list',new_map_list)

    # RCON map/changelevel guard.
    st,en,fn=_get_function(src,'rcon_cmd')
    if st < 0:
        raise RuntimeError('rcon_cmd missing')
    if '# HYPER-HOST v3.16 map-pool RCON guard' not in fn:
        needle="    if not command or len(command)>512 or '\\n' in command or '\\r' in command: raise RuntimeError('Invalid RCON command')\n"
        if needle not in fn:
            raise RuntimeError('rcon_cmd validation point missing')
        block=(
            needle+
            "    # HYPER-HOST v3.16 map-pool RCON guard\n"
            "    m=re.match(r'^\\s*(?:changelevel|map)\\s+([A-Za-z0-9_-]{{1,64}})(?:\\s|$)',command,re.I)\n"
            "    if m and not _map_pool_allowed(c,m.group(1)):\n"
            "        raise RuntimeError('Map is not enabled in this server map pool: '+m.group(1))\n"
        )
        fn=fn.replace(needle,block,1)
        src=src[:st]+fn+src[en:]

    # Panel config editor cannot silently overwrite managed map files.
    st,en,fn=_get_function(src,'config_write')
    if st < 0:
        raise RuntimeError('config_write missing')
    if '# HYPER-HOST v3.16 managed map-file guard' not in fn:
        needle='    require_root(); c,p=config_file(sid,name)\n'
        if needle not in fn:
            raise RuntimeError('config_write insertion point missing')
        block=(
            needle+
            "    # HYPER-HOST v3.16 managed map-file guard\n"
            "    if name in {'mapcycle.txt','maps.ini'} and bool(c.get('map_pool_enabled',False)):\n"
            "        raise RuntimeError('This map file is managed by the panel map pool. Change it on the Maps tab.')\n"
        )
        fn=fn.replace(needle,block,1)
        src=src[:st]+fn+src[en:]

    # activate_map cannot bypass whitelist.
    st,en,fn=_get_function(src,'activate_map')
    if st < 0:
        raise RuntimeError('activate_map missing')
    if '# HYPER-HOST v3.16 activate-map whitelist' not in fn:
        needle="    if not bsp.is_file(): raise RuntimeError(f'Map is not installed on this server: {map_name}')\n"
        if needle not in fn:
            raise RuntimeError('activate_map validation point missing')
        block=(
            needle+
            "    # HYPER-HOST v3.16 activate-map whitelist\n"
            "    if not _map_pool_allowed(c,map_name):\n"
            "        raise RuntimeError(f'Map is not enabled in this server map pool: {map_name}')\n"
        )
        fn=fn.replace(needle,block,1)
        src=src[:st]+fn+src[en:]

    # config-set start map cannot bypass whitelist.
    st,en,fn=_get_function(src,'server_config_set')
    if st < 0:
        raise RuntimeError('server_config_set missing')
    if '# HYPER-HOST v3.16 start-map whitelist' not in fn:
        needle="        if not (Path(c['path'])/'cstrike/maps'/(args.map+'.bsp')).is_file(): raise RuntimeError('map is not installed on this server')\n"
        if needle not in fn:
            raise RuntimeError('server_config_set map validation point missing')
        block=(
            needle+
            "        # HYPER-HOST v3.16 start-map whitelist\n"
            "        if not _map_pool_allowed(c,args.map):\n"
            "            raise RuntimeError('start map is not enabled in this server map pool')\n"
        )
        fn=fn.replace(needle,block,1)
        src=src[:st]+fn+src[en:]

    # Recovery must also respect the configured pool.
    new_choose="""def _choose_safe_map(c:dict):
    maps=Path(c['path'])/'cstrike/maps'
    requested=str(c.get('start_map') or '')
    installed,allowed,enabled=_map_pool_state(c)
    candidates=allowed if enabled else installed
    if requested and requested in candidates and (maps/(requested+'.bsp')).is_file():
        return requested
    if enabled and candidates:
        return candidates[0]
    if (maps/'de_dust2.bsp').is_file():
        return 'de_dust2'
    if installed:
        return installed[0]
    raise RuntimeError('No playable .bsp maps are installed on this server')


"""
    src=_replace_function(src,'_choose_safe_map',new_choose)

    # Reconcile the persisted pool against the newly uploaded assembly BEFORE start.
    st,en,fn=_get_function(src,'install_custom_build')
    if 'map_pool_reconcile(sid)' not in fn:
        needle="        c['path']=str(path); c['custom_build_source']=source_label; c['custom_build_installed_at']=int(time.time()); save_server(c)\n"
        if needle not in fn:
            raise RuntimeError('assembly swap/save point missing')
        repl=(
            needle+
            "\n        # HYPER-HOST v3.16 reconcile map pool after assembly swap\n"
            "        map_pool_reconcile(sid)\n"
            "        c=load_server(sid)\n"
        )
        fn=fn.replace(needle,repl,1)
        src=src[:st]+fn+src[en:]

    # CLI parser.
    if "sp.add_parser('map-pool-set')" not in src:
        needle="    q=sp.add_parser('activate-map'); q.add_argument('id',type=int); q.add_argument('map')\n"
        if needle not in src:
            raise RuntimeError('argparse activate-map point missing')
        src=src.replace(needle,needle+"    q=sp.add_parser('map-pool-set'); q.add_argument('id',type=int)\n",1)

    # CLI dispatch receives JSON from stdin.
    if "elif args.cmd=='map-pool-set':" not in src:
        needle="        elif args.cmd in {'change-map','activate-map'}:\n            result=activate_map(args.id,args.map)\n"
        if needle not in src:
            raise RuntimeError('activate-map dispatch point missing')
        block=(
            needle+
            "        elif args.cmd=='map-pool-set':\n"
            "            raw=sys.stdin.buffer.read(256*1024+1)\n"
            "            if len(raw)>256*1024: raise RuntimeError('Map pool payload is too large')\n"
            "            try: payload=json.loads(raw.decode('utf-8','replace') or '{}')\n"
            "            except Exception: raise RuntimeError('Invalid map pool payload')\n"
            "            if not isinstance(payload,dict): raise RuntimeError('Invalid map pool payload')\n"
            "            result=map_pool_set(args.id,payload)\n"
        )
        src=src.replace(needle,block,1)

    return src


def patch_controller(path: Path) -> bool:
    path=Path(path)
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src

    required=[
        'def install_custom_build(',
        'def install_rehlds(',
        'def install_metamod_rehlds(',
        'def map_list(',
        'def activate_map(',
        'def server_config_set(',
    ]
    missing=[x for x in required if x not in src]
    if missing:
        raise RuntimeError(f'{path}: unsupported controller layout; missing {missing}')

    src=_ensure_runtime_platform(src)
    src=_patch_map_pool(src)

    # Compile + semantic assertions before touching disk.
    ast.parse(src)
    _assert_import_mode_safe(src)

    _,_,fn=_get_function(src,'install_custom_build')
    norm=fn.find('platform_runtime=_v316_normalize_platform(stage)')
    start=fn.find("run(['systemctl','start'")
    if norm < 0 or start < 0 or norm > start:
        raise RuntimeError(f'{path}: managed platform is not before first server start')

    checks={
        'runtime marker': RUNTIME_MARKER in src,
        'map helper': MAP_MARKER in src or 'def map_pool_set(sid:int,payload:dict)' in src,
        'import mode v316': "import_mode=import_mode+'+managed-runtime-v316'" in fn,
        'map pool command': "sp.add_parser('map-pool-set')" in src,
        'activate whitelist': '# HYPER-HOST v3.16 activate-map whitelist' in src,
        'RCON whitelist': '# HYPER-HOST v3.16 map-pool RCON guard' in src,
        'config whitelist': '# HYPER-HOST v3.16 start-map whitelist' in src,
        'reconcile': 'map_pool_reconcile(sid)' in fn,
    }
    bad=[k for k,v in checks.items() if not v]
    if bad:
        raise RuntimeError(f'{path}: verification failed: {bad}')

    if src != original:
        tmp=path.with_name(path.name+'.v316tmp')
        tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
        os.chmod(tmp,path.stat().st_mode)
        py_compile.compile(str(tmp),doraise=True)
        os.replace(tmp,path)
    else:
        py_compile.compile(str(path),doraise=True)

    return src != original


def patch_index(path: Path) -> bool:
    p=Path(path)
    s=p.read_text(encoding='utf-8')
    orig=s

    if "if($action==='save_map_pool')" not in s:
        marker="        if($action==='ftp_reset'){\n"
        block="""        if($action==='save_map_pool'){
            $id=(int)($_POST['id']??0);require_perm('server.map',$id);
            $maps=$_POST['allowed_maps']??[];if(!is_array($maps))$maps=[];if(count($maps)>512)throw new RuntimeException('Слишком много карт');
            $clean=[];foreach($maps as $m){$m=trim((string)$m);if(!preg_match('/^[A-Za-z0-9_-]{1,64}$/',$m))throw new RuntimeException('Некорректная карта: '.$m);$clean[]=$m;}
            $clean=array_values(array_unique($clean));if(!$clean)throw new RuntimeException('Выбери хотя бы одну карту');
            $start=trim((string)($_POST['pool_start_map']??''));if(!in_array($start,$clean,true))$start=$clean[0];
            $payload=json_encode(['maps'=>$clean,'start_map'=>$start],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
            $r=ctl(['map-pool-set',$id],45,$payload?:'{}');if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось сохранить список карт'));
            db()->prepare('UPDATE servers SET start_map=? WHERE id=?')->execute([(string)($r['start_map']??$start),$id]);
            audit('map_pool_save',implode(',',$clean).' | start='.$start,$id);flash('Список карт сохранён: '.count($clean).' шт. Сервер будет использовать только выбранные карты.');redirect('/?page=server&id='.$id.'#maps');
        }
"""
        if marker not in s:
            raise RuntimeError(f'{p}: POST action insertion point missing')
        s=s.replace(marker,block+marker,1)

    old="$serverMaps=is_array($serverMapsResult['maps']??null)?$serverMapsResult['maps']:[];if(!in_array((string)$s['start_map'],$serverMaps,true))array_unshift($serverMaps,(string)$s['start_map']);"
    if '$installedMaps=' not in s:
        new="$serverMaps=is_array($serverMapsResult['maps']??null)?$serverMapsResult['maps']:[];$installedMaps=is_array($serverMapsResult['installed_maps']??null)?$serverMapsResult['installed_maps']:$serverMaps;$allowedMaps=is_array($serverMapsResult['allowed_maps']??null)?$serverMapsResult['allowed_maps']:$serverMaps;$mapPoolEnabled=!empty($serverMapsResult['map_pool_enabled']);if(!in_array((string)$s['start_map'],$serverMaps,true)&&in_array((string)$s['start_map'],$installedMaps,true))array_unshift($serverMaps,(string)$s['start_map']);"
        if old not in s:
            raise RuntimeError(f'{p}: server map variables insertion point missing')
        s=s.replace(old,new,1)

    if 'id="mapPoolForm"' not in s:
        needle='</form></div><div class="map-control"><div class="map-current">'
        if needle not in s:
            raise RuntimeError(f'{p}: map tab insertion point missing')
        html=r'''</form></div><div class="map-pool-editor"><div class="map-pool-head"><div><h3><i class="fa-solid fa-list-check"></i> Разрешённые карты</h3><p>Список строится только из реально существующих cstrike/maps/*.bsp. Выбранные карты синхронизируются с mapcycle.txt и AMXX maps.ini.</p></div><span class="map-pool-count"><b id="mapPoolCount"><?=count($allowedMaps)?></b> / <?=count($installedMaps)?> выбрано</span></div><?php if(can_perm('server.map',$id)):?><form method="post" id="mapPoolForm"><?=csrf_field()?><input type="hidden" name="action" value="save_map_pool"><input type="hidden" name="id" value="<?=$id?>"><div class="map-pool-tools"><div class="map-search"><i class="fa-solid fa-magnifying-glass"></i><input id="mapPoolSearch" class="form-control" placeholder="Фильтр: zm_, de_, cs_..."></div><button type="button" class="btn btn-soft btn-sm" id="mapPoolAll">Выбрать все</button><button type="button" class="btn btn-soft btn-sm" id="mapPoolNone">Снять все</button></div><div id="mapPoolGrid" class="map-pool-grid"><?php foreach($installedMaps as $m):$checked=in_array($m,$allowedMaps,true);?><label class="map-pool-item" data-map-pool-name="<?=e(strtolower($m))?>"><input type="checkbox" name="allowed_maps[]" value="<?=e($m)?>" data-map-pool-check <?=$checked?'checked':''?>><span><i class="fa-solid fa-map"></i><b><?=e($m)?></b><small><?=$checked?'Разрешена':'Не используется'?></small></span></label><?php endforeach;?><?php if(!$installedMaps):?><div class="text-secondary">В cstrike/maps пока нет .bsp карт.</div><?php endif;?></div><div class="map-pool-footer"><label><span>Стартовая карта</span><select class="form-select" id="mapPoolStart" name="pool_start_map"><?=map_options($allowedMaps,(string)$s['start_map'])?></select></label><div class="map-pool-note"><i class="fa-solid fa-shield-halved"></i><span>Быстрый выбор, старт сервера и команды map/changelevel из панели ограничиваются этим списком.</span></div><button class="btn btn-primary"><i class="fa-solid fa-floppy-disk me-2"></i>Сохранить список</button></div></form><?php else:?><div class="map-pool-readonly"><?php foreach($allowedMaps as $m):?><span><?=e($m)?></span><?php endforeach;?></div><?php endif;?></div><div class="map-control"><div class="map-current">'''
        s=s.replace(needle,html,1)

    s=re.sub(r'/assets/style\.css\?v=\d+', '/assets/style.css?v=3160', s)
    s=re.sub(r'/assets/app\.js\?v=\d+', '/assets/app.js?v=3160', s)

    if s != orig:
        p.write_text(s,encoding='utf-8')
    return s != orig


def patch_js(path: Path) -> bool:
    p=Path(path)
    s=p.read_text(encoding='utf-8')
    orig=s
    if 'function initMapPoolEditor()' not in s:
        needle='  async function loadPlugins(){\n'
        block=r'''  function initMapPoolEditor(){
    const form=$('#mapPoolForm'); if(!form)return;
    const checks=()=>$$('[data-map-pool-check]',form);
    const start=$('#mapPoolStart');
    const count=$('#mapPoolCount');
    const refresh=()=>{
      const selected=checks().filter(x=>x.checked).map(x=>x.value);
      if(count)count.textContent=String(selected.length);
      checks().forEach(x=>{const label=x.closest('.map-pool-item');const small=label?.querySelector('small');if(label)label.classList.toggle('selected',x.checked);if(small)small.textContent=x.checked?'Разрешена':'Не используется';});
      if(start){const old=start.value;start.innerHTML=selected.map(m=>`<option value="${esc(m)}">${esc(m)}</option>`).join('');if(selected.includes(old))start.value=old;else if(selected.includes(currentMap))start.value=currentMap;}
    };
    checks().forEach(x=>x.addEventListener('change',refresh));
    $('#mapPoolAll')?.addEventListener('click',()=>{checks().forEach(x=>x.checked=true);refresh();});
    $('#mapPoolNone')?.addEventListener('click',()=>{checks().forEach(x=>x.checked=false);refresh();});
    $('#mapPoolSearch')?.addEventListener('input',e=>{const q=String(e.currentTarget.value||'').trim().toLowerCase();$$('[data-map-pool-name]',form).forEach(x=>x.hidden=!!q&&!String(x.dataset.mapPoolName||'').includes(q));});
    form.addEventListener('submit',e=>{if(!checks().some(x=>x.checked)){e.preventDefault();toast('Выбери хотя бы одну карту',true);}});
    refresh();
  }
  initMapPoolEditor();

'''
        if needle not in s:
            raise RuntimeError(f'{p}: JS insertion point missing')
        s=s.replace(needle,block+needle,1)

    if s != orig:
        p.write_text(s,encoding='utf-8')
    return s != orig


def patch_css(path: Path) -> bool:
    p=Path(path)
    s=p.read_text(encoding='utf-8')
    orig=s
    if '.map-pool-editor{' not in s:
        s += r'''
.map-pool-editor{margin-bottom:16px;padding:16px;border:1px solid #29405f;border-radius:14px;background:linear-gradient(145deg,#0b1829,#0a1422)}.map-pool-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:13px}.map-pool-head h3{margin:0;font-size:16px}.map-pool-head h3 i{color:#7ba2ff;margin-right:7px}.map-pool-head p{margin:5px 0 0;color:var(--muted);font-size:12px}.map-pool-count{white-space:nowrap;padding:7px 10px;border-radius:999px;border:1px solid #304968;background:#0d1b2d;color:#91a8c3;font-size:11px}.map-pool-count b{color:#c5d7ff}.map-pool-tools{display:grid;grid-template-columns:minmax(220px,1fr) auto auto;gap:8px;margin-bottom:10px}.map-pool-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(175px,1fr));gap:8px;max-height:360px;overflow:auto;padding:2px}.map-pool-item{margin:0;cursor:pointer}.map-pool-item input{position:absolute;opacity:0;pointer-events:none}.map-pool-item>span{display:block;padding:11px 12px;border:1px solid #233853;border-radius:11px;background:#0a1523;transition:.15s}.map-pool-item>span i{color:#607d9e;margin-right:6px}.map-pool-item b{font-size:12px}.map-pool-item small{display:block;margin-top:5px;color:#687e98;font-size:10px}.map-pool-item:hover>span{border-color:#43638e}.map-pool-item.selected>span,.map-pool-item input:checked+span{border-color:#4f7dff;background:rgba(79,125,255,.12);box-shadow:0 0 0 1px rgba(79,125,255,.1) inset}.map-pool-item.selected>span i,.map-pool-item input:checked+span i{color:#86a7ff}.map-pool-item input:checked+span small{color:#73d99a}.map-pool-footer{display:grid;grid-template-columns:minmax(180px,260px) 1fr auto;gap:12px;align-items:end;margin-top:13px;padding-top:13px;border-top:1px solid #1f324b}.map-pool-footer label{margin:0}.map-pool-note{display:flex;gap:8px;align-items:center;color:#8197b1;font-size:11px;padding-bottom:8px}.map-pool-note i{color:#65d68c}.map-pool-readonly{display:flex;flex-wrap:wrap;gap:7px}.map-pool-readonly span{padding:6px 9px;border-radius:8px;background:#11223a;border:1px solid #29405f;color:#b9cbff;font-size:11px}@media(max-width:900px){.map-pool-footer{grid-template-columns:1fr}.map-pool-tools{grid-template-columns:1fr 1fr}.map-pool-tools .map-search{grid-column:1/-1}}@media(max-width:600px){.map-pool-head{flex-direction:column}.map-pool-tools{grid-template-columns:1fr}.map-pool-tools .map-search{grid-column:auto}.map-pool-grid{grid-template-columns:1fr 1fr}.map-pool-footer .btn{width:100%}}
'''
    if s != orig:
        p.write_text(s,encoding='utf-8')
    return s != orig


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print('usage: patch_v316.py <controller> <repo_root> [web_root ...]',file=sys.stderr)
        return 2

    ctl=Path(argv[1])
    repo=Path(argv[2])
    web_roots=[Path(x) for x in argv[3:]]

    changed=[]
    if patch_controller(ctl):
        changed.append(str(ctl))

    repo_ctl=repo/'cs16-panel/bin/hyper-cs16-ctl'
    if repo_ctl.resolve() != ctl.resolve() and patch_controller(repo_ctl):
        changed.append(str(repo_ctl))

    repo_index=repo/'cs16-panel/public/index.php'
    repo_js=repo/'cs16-panel/public/assets/app.js'
    repo_css=repo/'cs16-panel/public/assets/style.css'
    if patch_index(repo_index): changed.append(str(repo_index))
    if patch_js(repo_js): changed.append(str(repo_js))
    if patch_css(repo_css): changed.append(str(repo_css))

    for root in web_roots:
        idx=root/'index.php'
        js=root/'assets/app.js'
        css=root/'assets/style.css'
        if idx.is_file() and js.is_file() and css.is_file():
            if patch_index(idx): changed.append(str(idx))
            if patch_js(js): changed.append(str(js))
            if patch_css(css): changed.append(str(css))

    print('PATCHED_FILES='+str(len(changed)))
    for p in changed:
        print('[PATCHED]',p)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))

PY_PATCHER_V316

cat <<EOF
============================================================
 HYPER-HOST CS16 FINAL INSTALL/MAPS FIX v3.16
============================================================
Server:     $SID
Controller: $LIVE_CTL
Repo:       $REPO
Backup:     $BACKUP
Log:        $LOG
EOF

echo
[[ "$SID" =~ ^[0-9]+$ ]] || { echo "[ERROR] Invalid server id: $SID"; false; }
[[ -f "$LIVE_CTL" ]] || { echo "[ERROR] Live controller not found: $LIVE_CTL"; false; }
[[ -f "$REPO/cs16-panel/bin/hyper-cs16-ctl" ]] || { echo "[ERROR] Repository controller not found"; false; }
[[ -f "$REPO/cs16-panel/public/index.php" ]] || { echo "[ERROR] Repository index.php not found"; false; }
[[ -f "$REPO/cs16-panel/public/assets/app.js" ]] || { echo "[ERROR] Repository app.js not found"; false; }
[[ -f "$REPO/cs16-panel/public/assets/style.css" ]] || { echo "[ERROR] Repository style.css not found"; false; }

WEB_ROOTS=()

if [[ "$PATCH_ONLY" != "1" ]]; then
  echo "[1/8] Discovering actual CS16 panel web roots..."

  for root in \
    "/var/www/hyper-host-sites/$DOMAIN/public_html" \
    "/var/www/$DOMAIN/public_html" \
    "/var/www/$DOMAIN"
  do
    if [[ -f "$root/index.php" ]] && grep -q "serverTabs" "$root/index.php" 2>/dev/null; then
      echo "$root" >> "$ROOT_FILE"
    fi
  done

  if command -v nginx >/dev/null 2>&1; then
    nginx -T > "$NGTMP" 2>&1 || true
    python3 - "$NGTMP" "$DOMAIN" >> "$ROOT_FILE" <<'PY_DISCOVER_V316'
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
PY_DISCOVER_V316
  fi

  # Fallback finds only actual CS16 panel pages, not customer websites.
  while IFS= read -r idx; do
    grep -q "serverTabs" "$idx" 2>/dev/null || continue
    grep -q "page==='server'" "$idx" 2>/dev/null || continue
    echo "$(dirname "$idx")" >> "$ROOT_FILE"
  done < <(find /var/www -xdev -type f -name index.php 2>/dev/null || true)

  sort -u "$ROOT_FILE" -o "$ROOT_FILE"
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    [[ -f "$root/index.php" ]] || continue
    [[ -f "$root/assets/app.js" ]] || continue
    [[ -f "$root/assets/style.css" ]] || continue
    grep -q "serverTabs" "$root/index.php" || continue
    WEB_ROOTS+=("$root")
  done < "$ROOT_FILE"

  if [[ "${#WEB_ROOTS[@]}" -eq 0 ]]; then
    echo "[ERROR] No live CS16 panel document root found"
    false
  fi

  printf '  - %s\n' "${WEB_ROOTS[@]}"
else
  echo "[1/8] PATCH_ONLY=1 -> live web discovery skipped"
fi

echo
echo "[2/8] Backing up every file that may be changed..."
backup_one "$LIVE_CTL"
backup_one "$REPO/cs16-panel/bin/hyper-cs16-ctl"
backup_one "$REPO/cs16-panel/public/index.php"
backup_one "$REPO/cs16-panel/public/assets/app.js"
backup_one "$REPO/cs16-panel/public/assets/style.css"

for root in "${WEB_ROOTS[@]}"; do
  backup_one "$root/index.php"
  backup_one "$root/assets/app.js"
  backup_one "$root/assets/style.css"
done

echo "[OK] backup complete"

echo
echo "[3/8] Applying v3.16 in one Python process (no importlib temp-loader)..."
python3 "$PATCHER" "$LIVE_CTL" "$REPO" "${WEB_ROOTS[@]}"

echo
echo "[4/8] Verifying Python + the exact import_mode order..."
python3 -m py_compile "$LIVE_CTL"
python3 -m py_compile "$REPO/cs16-panel/bin/hyper-cs16-ctl"

python3 - "$LIVE_CTL" <<'PY_VERIFY_V316'
import ast,sys
from pathlib import Path
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
tree=ast.parse(s)
fn=next((x for x in tree.body if isinstance(x,ast.FunctionDef) and x.name=='install_custom_build'),None)
if fn is None: raise SystemExit('[ERROR] install_custom_build not found')
assign=[]; load=[]
for n in ast.walk(fn):
    if isinstance(n,ast.Name) and n.id=='import_mode':
        if isinstance(n.ctx,ast.Store): assign.append((n.lineno,n.col_offset))
        elif isinstance(n.ctx,ast.Load): load.append((n.lineno,n.col_offset))
if not assign: raise SystemExit('[ERROR] import_mode assignment missing')
if load and min(load)<min(assign): raise SystemExit(f'[ERROR] import_mode still loaded before assignment: {min(load)} < {min(assign)}')
text=ast.get_source_segment(s,fn) or ''
if 'platform_runtime=_v316_normalize_platform(stage)' not in text: raise SystemExit('[ERROR] v3.16 runtime normalization call missing')
if "import_mode=import_mode+'+managed-runtime-v316'" not in text: raise SystemExit('[ERROR] v3.16 import mode assignment missing')
print('[OK] import_mode is assigned BEFORE every read')
print('[OK] managed runtime v3.16 is installed before server start')
PY_VERIFY_V316

echo
echo "[5/8] Verifying map-pool backend..."
grep -q "def map_pool_set(sid:int,payload:dict)" "$LIVE_CTL"
grep -q "HYPER-HOST v3.16 activate-map whitelist" "$LIVE_CTL"
grep -q "HYPER-HOST v3.16 map-pool RCON guard" "$LIVE_CTL"
grep -q "HYPER-HOST v3.16 start-map whitelist" "$LIVE_CTL"
grep -q "map_pool_reconcile(sid)" "$LIVE_CTL"
grep -q "sp.add_parser('map-pool-set')" "$LIVE_CTL"
echo "[OK] whitelist backend / reconcile / CLI are installed"

echo
echo "[6/8] Verifying PHP and JavaScript..."
php -l "$REPO/cs16-panel/public/index.php" >/dev/null
if command -v node >/dev/null 2>&1; then
  node --check "$REPO/cs16-panel/public/assets/app.js" >/dev/null
fi

grep -q 'id="mapPoolForm"' "$REPO/cs16-panel/public/index.php"
grep -q 'function initMapPoolEditor()' "$REPO/cs16-panel/public/assets/app.js"

for root in "${WEB_ROOTS[@]}"; do
  php -l "$root/index.php" >/dev/null
  grep -q 'id="mapPoolForm"' "$root/index.php"
  grep -q 'function initMapPoolEditor()' "$root/assets/app.js"
  if command -v node >/dev/null 2>&1; then
    node --check "$root/assets/app.js" >/dev/null
  fi
done

echo "[OK] PHP/JS syntax and map selector UI are valid"

if [[ "$PATCH_ONLY" == "1" ]]; then
  echo
  echo "[7/8] PATCH_ONLY -> service reload skipped"
  echo "[8/8] PATCH_ONLY -> current server map inventory skipped"
  trap - ERR
  cleanup_tmp
  trap - EXIT
  echo
  echo "============================================================"
  echo " v3.16 PATCH-ONLY VALIDATION SUCCESS"
  echo "============================================================"
  exit 0
fi

echo
echo "[7/8] Reloading PHP-FPM cache..."
while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*fpm/ {print $1}')
echo "[OK] panel cache reload requested"

echo
echo "[8/8] Checking current server map inventory..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  "$LIVE_CTL" maps "$SID" || echo "[WARN] maps command could not query live state; files are still patched"
else
  echo "[INFO] Server #$SID does not currently exist; feature will work for new servers too."
fi

trap - ERR
cleanup_tmp
trap - EXIT

echo
echo "============================================================"
echo " v3.16 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "FIXED: import_mode is no longer read before assignment."
echo "FIXED: v3.15 no longer uses the broken temporary importlib loader."
echo "FIXED: future uploaded builds normalize runtime before first start."
echo "ADDED: real per-server map whitelist from cstrike/maps/*.bsp."
echo
echo "After this patch:"
echo "  1) re-upload the same assembly that failed with import_mode;"
echo "  2) open Server -> Карты;"
echo "  3) select allowed maps + startup map and save."
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
