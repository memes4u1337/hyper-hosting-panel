#!/usr/bin/env python3
from pathlib import Path
import ast, sys

URL_FUNC = r"""def _fastdl_url(c:dict)->str:
    sid=int(c.get('id') or 0)
    public=''
    try:
        rt=load_runtime(); public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()
    except Exception:
        public=str(c.get('public_ip') or '').strip()
    try:
        ip=ipaddress.ip_address(public)
        if ip.version==4 and not ip.is_unspecified:
            return f'http://{public}/fastdl/{sid}/'
    except Exception:
        pass
    return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'
"""

CFG_FUNC = r"""def _fastdl_apply_cfg(c:dict, root:Path|None=None)->dict:
    root=Path(root or c['path'])
    cfg=root/'cstrike/server.cfg'; cfg.parent.mkdir(parents=True,exist_ok=True)
    text=cfg.read_text(encoding='utf-8',errors='ignore') if cfg.exists() else ''
    text=text.replace('\\r\\n','\\n').replace('\\r','\\n')
    begin='// HYPER-HOST FASTDL BEGIN'; end='// HYPER-HOST FASTDL END'
    text=re.sub(r'(?ims)^\\s*// HYPER-HOST FASTDL BEGIN\\s*$.*?^\\s*// HYPER-HOST FASTDL END\\s*$\\n?', '', text)
    managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
    kept=[]; replaced=[]
    for line in text.splitlines():
        m=re.match(r'^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s+',line)
        if m and m.group(1).lower() in managed:
            replaced.append(line.strip()); continue
        kept.append(line)
    url=_fastdl_url(c).rstrip('/')+'/'
    block=[
        begin,
        '// HYPER-HOST R10: HTTP FastDL only. No slow game-channel fallback.',
        'sv_allowdownload 1',
        'sv_allowupload 0',
        'sv_send_resources 1',
        'sv_allow_dlfile 0',
        f'sv_downloadurl "{url}"',
        end,
    ]
    cfg.write_text('\\n'.join(kept).rstrip()+'\\n\\n'+'\\n'.join(block)+'\\n',encoding='utf-8')
    return {'ok':True,'url':url,'config':str(cfg),'replaced':replaced}
"""

SYNC_BLOCK = r"""def _r10_fastdl_file_error(fp:Path)->str:
    try:
        b=fp.read_bytes()[:32]
    except Exception as exc:
        return 'read error: '+str(exc)
    low=b.lstrip().lower()
    if low.startswith(b'<!doctype') or low.startswith(b'<html'):
        return 'HTML response saved as a game asset'
    ext=fp.suffix.lower()
    if ext=='.bsp' and (len(b)<4 or int.from_bytes(b[:4],'little')!=30): return 'invalid BSP30 header'
    if ext=='.spr' and b[:4]!=b'IDSP': return 'invalid SPR header'
    if ext=='.wav' and not (b[:4]==b'RIFF' and b[8:12]==b'WAVE'): return 'invalid RIFF/WAVE header'
    if ext=='.wad' and b[:4] not in (b'WAD2',b'WAD3'): return 'invalid WAD header'
    if ext=='.mdl':
        valid=b[:4] in (b'IDST',b'IDSQ') or (len(b)>=4 and int.from_bytes(b[:4],'little')==30)
        if not valid: return 'invalid MDL/brush-model header'
    return ''


def _r10_fastdl_validate_tree(root:Path)->list[dict]:
    bad=[]
    for fp in root.rglob('*'):
        if not fp.is_file(): continue
        err=_r10_fastdl_file_error(fp)
        if err:
            bad.append({'file':fp.relative_to(root).as_posix(),'error':err,'bytes':fp.stat().st_size})
            if len(bad)>=50: break
    return bad


def _r10_fastdl_lowercase_aliases(root:Path)->int:
    made=0
    files=[p for p in root.rglob('*') if p.is_file()]
    for fp in files:
        rel=fp.relative_to(root)
        low=Path(*[part.lower() for part in rel.parts])
        if low==rel: continue
        dst=root/low
        if dst.exists(): continue
        try:
            dst.parent.mkdir(parents=True,exist_ok=True)
            try: os.link(fp,dst)
            except OSError: shutil.copy2(fp,dst)
            made+=1
        except OSError:
            pass
    return made


def _r10_disable_fastdl_killers(server_root:Path)->dict:
    import zlib
    cstrike=server_root/'cstrike'; cfg=cstrike/'addons/amxmodx/configs'; plug=cstrike/'addons/amxmodx/plugins'
    names={'oldz_safe_download_r8.amxx','oldz_download_guard.amxx'}
    killers=set()
    for name in names:
        p=plug/name
        if not p.is_file(): continue
        b=p.read_bytes(); decoded=b''
        for off in range(0,min(80,len(b))):
            try:
                decoded=zlib.decompress(b[off:]); break
            except Exception:
                pass
        if decoded and all(x in decoded for x in (b'force_safe_downloads',b'task_guard',b'set_cvar_string')):
            killers.add(name.lower())
    changed=[]
    if killers and cfg.is_dir():
        for f in sorted(cfg.glob('plugins*.ini')):
            if not f.is_file(): continue
            lines=f.read_text(encoding='utf-8',errors='ignore').splitlines(); out=[]; touched=False
            for line in lines:
                st=line.strip(); body=st.lstrip(';').strip(); token=body.split(';',1)[0].strip().split()[0] if body else ''
                if token.lower() in killers and st and not st.startswith(';'):
                    out.append('; HYPER-HOST R10 disabled FastDL killer: '+st); touched=True
                else: out.append(line)
            if touched:
                f.write_text('\\n'.join(out).rstrip()+'\\n',encoding='utf-8'); changed.append(f.name)
    return {'killers':sorted(killers),'changed_files':changed}


def fastdl_sync(sid:int, configure:bool=True):
    require_root(); c=load_server(sid); root=Path(c['path']); cstrike=root/'cstrike'
    if not cstrike.is_dir(): raise RuntimeError(f'cstrike directory is missing: {cstrike}')
    FASTDL_ROOT.mkdir(parents=True,exist_ok=True)
    dest=FASTDL_ROOT/str(sid)
    token=secrets.token_hex(6)
    stage=FASTDL_ROOT/f'.{sid}.r10-stage-{token}'
    old=FASTDL_ROOT/f'.{sid}.r10-old-{token}'
    copied_dirs=[]
    try:
        stage.mkdir(parents=True,exist_ok=False)
        for name in FASTDL_DIRS:
            src=cstrike/name
            if not src.is_dir(): continue
            dd=stage/name; dd.mkdir(parents=True,exist_ok=True)
            cp=run(['rsync','-a','--safe-links',str(src)+'/',str(dd)+'/'],check=False,timeout=1200)
            if cp.returncode!=0: raise RuntimeError('FastDL rsync failed for '+str(src)+': '+(cp.stdout or '')[-2500:])
            copied_dirs.append(name)
        for src in cstrike.iterdir():
            if src.is_file() and src.suffix.lower()=='.wad': shutil.copy2(src,stage/src.name)

        bad=_r10_fastdl_validate_tree(stage)
        if bad: raise RuntimeError('FastDL refused corrupt assets: '+json.dumps(bad,ensure_ascii=False))
        aliases=_r10_fastdl_lowercase_aliases(stage)
        bad_after=_r10_fastdl_validate_tree(stage)
        if bad_after: raise RuntimeError('FastDL validation failed after aliases: '+json.dumps(bad_after,ensure_ascii=False))

        cfg_result=_fastdl_apply_cfg(c,root) if configure else {'url':_fastdl_url(c)}
        run(['chown','-R','root:www-data',str(stage)],check=False)
        run(['find',str(stage),'-type','d','-exec','chmod','0755','{}','+'],check=False)
        run(['find',str(stage),'-type','f','-exec','chmod','0644','{}','+'],check=False)
        files=0; total=0
        for fp in stage.rglob('*'):
            try:
                if fp.is_file(): files+=1; total+=fp.stat().st_size
            except OSError: pass

        if dest.exists(): os.replace(dest,old)
        os.replace(stage,dest)
        if old.exists(): shutil.rmtree(old,ignore_errors=True)
    except Exception:
        if stage.exists(): shutil.rmtree(stage,ignore_errors=True)
        if old.exists() and not dest.exists(): os.replace(old,dest)
        raise

    c['fastdl_url']=(cfg_result.get('url') or _fastdl_url(c)).rstrip('/')+'/'
    c['fastdl_last_sync']=int(time.time()); c['fastdl_files']=files; c['fastdl_bytes']=total
    save_server(c)
    runtime_applied=False; runtime_errors=[]
    if service_status(sid)=='active' and udp_listening(int(c.get('port') or 0)):
        for cmd in ['sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 0',f'sv_downloadurl "{c["fastdl_url"]}"']:
            try: query_rcon('127.0.0.1',int(c['port']),str(c.get('rcon_password','')),cmd,2.0)
            except Exception as exc: runtime_errors.append(str(exc))
        runtime_applied=not runtime_errors
    return {'ok':True,'id':sid,'url':c['fastdl_url'],'root':str(dest),'files':files,'bytes':total,
            'dirs':copied_dirs,'lowercase_aliases':aliases,'config':cfg_result,
            'runtime_applied':runtime_applied,'runtime_errors':runtime_errors[:5]}
"""

def replace_func(src:str,name:str,new:str)->str:
    tree=ast.parse(src)
    node=None
    for n in tree.body:
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name:
            node=n; break
    if node is None: raise RuntimeError(f'function {name} not found')
    lines=src.splitlines(keepends=True)
    return ''.join(lines[:node.lineno-1])+new.rstrip()+'\n\n'+''.join(lines[node.end_lineno:])

def patch(path:Path):
    if not path.is_file(): return
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    src=replace_func(src,'_fastdl_url',URL_FUNC)
    src=replace_func(src,'_fastdl_apply_cfg',CFG_FUNC)
    src=replace_func(src,'fastdl_sync',SYNC_BLOCK)
    anchor='        plugin_comment_fix=_normalize_plugin_comment_syntax(stage)'
    if '_r10_disable_fastdl_killers(stage)' not in src:
        if anchor not in src: raise RuntimeError('custom-build plugin_comment_fix anchor not found')
        src=src.replace(anchor,anchor+'\n        fastdl_killer_fix=_r10_disable_fastdl_killers(stage)',1)
    compile(src,str(path),'exec')
    tmp=path.with_name(path.name+'.r10tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    tmp.chmod(path.stat().st_mode)
    tmp.replace(path)
    print('[OK] controller patched',path)

for arg in sys.argv[1:]: patch(Path(arg))
