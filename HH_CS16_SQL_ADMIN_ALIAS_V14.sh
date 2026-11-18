#!/usr/bin/env bash
# HYPER-HOST CS 1.6: minimal, version-agnostic SQL admin command alias.
# Does NOT replace controllers, require V12, edit game/SQL files, or touch services.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) echo 'Usage: sudo bash HH_CS16_SQL_ADMIN_ALIAS_V14.sh check|apply|verify' >&2; exit 2;; esac
if (( EUID != 0 )); then echo '[HH-ADMIN14-ERROR] Run with sudo' >&2; exit 2; fi
export HH_ADMIN14_MODE="$MODE"
python3 - <<'PY'
import ast
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

Path=pathlib.Path
MODE=os.environ['HH_ADMIN14_MODE']
LIVE=Path(os.environ.get('HH_ADMIN14_LIVE','/usr/local/sbin/hyper-cs16-ctl'))
HELPER=Path(os.environ.get('HH_ADMIN14_HELPER','/usr/local/libexec/hyper-cs16/sql-admin-alias-v14.py'))
BACKUPS=Path(os.environ.get('HH_ADMIN14_BACKUPS','/opt/hyper-cs16/backups'))
MARKER='# HH_CS16_SQL_ADMIN_ALIAS_V14'

# The helper is deliberately separate: the installed controller retains every original
# function (including fastdl_clean), argument, and command handler unchanged.
BRIDGE=r'''#!/usr/bin/env python3
# HH_CS16_SQL_ADMIN_ALIAS_V14 — adapter, never writes SQL itself.
import ipaddress
import json
import pathlib
import re
import subprocess
import sys

LIVE=__LIVE__
ACCESS=re.compile(r'[a-uA-U]{1,32}\Z')
STEAM=re.compile(r'(?:STEAM|VALVE)_[0-9]+:[0-9]+:[0-9]+\Z',re.I)
KEYS={'identity','auth','steamid','steam_id','nickname','username','name','access','access_flags','password','auth_type','type','generate_password','flags','auth_flags','index','server','server_id','id'}
OPTIONS={'--identity':'identity','--auth':'auth','--steamid':'steamid','--steam-id':'steam_id','--nickname':'nickname','--username':'username','--name':'name','--access':'access','--access-flags':'access_flags','--password':'password','--auth-type':'auth_type','--type':'type','--flags':'flags','--auth-flags':'auth_flags','--index':'index','--server':'server','--server-id':'server_id','--id':'id','--generate-password':'generate_password'}

def fail(text):
    print(json.dumps({'ok':False,'error':'SQL admin alias: '+text},ensure_ascii=False))
    raise SystemExit(2)

def main():
    av=sys.argv[1:]
    if not av or av[0] not in ('sql-admin-grant','sql-admin-revoke'): fail('Unsupported operation')
    op=av.pop(0)
    if '--help' in av or '-h' in av:
        print('Usage: '+op+' SERVER_ID [IDENTITY ACCESS_FLAGS] [--identity ID --access FLAGS --password PASS]')
        print('       sql-admin-revoke SERVER_ID [IDENTITY|INDEX]')
        return
    sid=None
    if av and re.fullmatch(r'[0-9]+',av[0]): sid=av.pop(0)
    opts={}
    pos=[]
    while av:
        tok=av.pop(0)
        if tok.startswith('--'):
            flag,eq,value=tok.partition('=')
            if flag not in OPTIONS: fail('Unknown option: '+flag)
            if not eq:
                if flag=='--generate-password': value='true'
                elif av: value=av.pop(0)
                else: fail('Missing value for '+flag)
            opts[OPTIONS[flag]]=value
        elif tok.startswith('-'): fail('Unknown argument')
        else: pos.append(tok)
    # stdin is JSON if supplied (e.g. by panel); no credentials are logged.
    raw=sys.stdin.buffer.read(131073) if not sys.stdin.isatty() else b''
    if len(raw)>131072: fail('Request too large')
    if raw.strip():
        try: payload=json.loads(raw.decode('utf-8'))
        except (UnicodeError,ValueError): fail('Invalid JSON request')
        if not isinstance(payload,dict) or not set(payload)<=KEYS: fail('Unsupported JSON object')
        opts={**payload,**opts}
    if len(pos)==1 and pos[0].startswith('{'):
        try: payload=json.loads(pos.pop(0))
        except ValueError: fail('Invalid positional JSON')
        if not isinstance(payload,dict) or not set(payload)<=KEYS: fail('Unsupported JSON fields')
        opts={**payload,**opts}
    if sid is None: sid=str(opts.pop('server_id',opts.pop('server',opts.pop('id',''))))
    if not re.fullmatch(r'[1-9][0-9]{0,6}',sid): fail('Server ID missing/invalid')
    # Do not assume which SQL database a random other server uses.
    if int(sid) not in (25,26): fail('Only servers 25 and 26 use verified shared SQL')
    if op=='sql-admin-revoke':
        ident=next((opts[k] for k in ('identity','auth','steamid','steam_id','nickname','name','index') if opts.get(k) is not None),'')
        if not ident and len(pos)==1: ident=pos.pop(0)
        if pos: fail('Ambiguous revoke arguments')
        ident=str(ident).strip()
        if not ident or len(ident.encode())>64 or any(c in ident for c in '\r\n\x00'): fail('Invalid identity/index')
        cmd=['sql-admins-delete',sid,ident]
        request=b''
    else:
        if len(pos)==2:
            opts.setdefault('identity',pos[0]);opts.setdefault('access_flags',pos[1])
        elif len(pos)==1: opts.setdefault('identity',pos[0])
        elif len(pos)>2: fail('Ambiguous grant arguments; use named options or JSON')
        ident=str(next((opts[k] for k in ('identity','auth','steamid','steam_id','nickname','username','name') if opts.get(k)), '')).strip()
        access=str(opts.get('access_flags') or opts.get('access') or '').strip()
        if not ident or len(ident.encode('utf-8'))>32 or any(x in ident for x in '\r\n\x00'): fail('Missing/invalid identity')
        if not ACCESS.fullmatch(access): fail('Missing/invalid access flags a-u')
        auth_type=str(opts.get('auth_type') or opts.get('type') or '').lower().strip()
        if not auth_type:
            if STEAM.fullmatch(ident): auth_type='steamid'
            else:
                try: ipaddress.ip_address(ident);auth_type='ip'
                except ValueError: auth_type='name'
        if auth_type not in ('steamid','ip','name'): fail('Invalid authentication type')
        password=str(opts.get('password') or '')
        if len(password.encode('utf-8'))>32 or any(c in password for c in '\r\n\x00'): fail('Invalid password')
        generate=str(opts.get('generate_password') or '').lower() in ('true','1','yes','on')
        payload={'identity':ident,'access_flags':access,'auth_type':auth_type,'password':password,'generate_password':generate}
        cmd=['sql-admins-save',sid]
        request=json.dumps(payload,ensure_ascii=False).encode('utf-8')
    try:
        p=subprocess.run([sys.executable,LIVE,*cmd],input=request,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=40)
    except subprocess.TimeoutExpired: fail('Controller timed out')
    if p.stdout: sys.stdout.buffer.write(p.stdout);sys.stdout.buffer.flush()
    if p.stderr: sys.stderr.buffer.write(p.stderr);sys.stderr.buffer.flush()
    raise SystemExit(p.returncode)

if __name__=='__main__': main()
'''
BRIDGE=BRIDGE.replace('__LIVE__',repr(str(LIVE)))


def say(x): print('[HH-ADMIN14] '+x,flush=True)
def fail(x): raise RuntimeError(x)
def regular(p,required=True):
    if p.is_symlink() or (p.exists() and not p.is_file()): fail('Unsafe path: '+str(p))
    if required and (not p.is_file() or p.stat().st_size==0): fail('Missing file: '+str(p))
def run(cmd,timeout=14):
    try: return subprocess.run([str(x) for x in cmd],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired: fail('CLI timed out during: '+str(cmd[1] if len(cmd)>1 else '--help'))
def base_check():
    regular(LIVE)
    s=LIVE.read_text(encoding='utf-8')
    if not s.startswith('#!') or 'python' not in s.splitlines()[0].lower():
        fail('Installed CLI is not a Python executable; abort without changes')
    tree=ast.parse(s,filename=str(LIVE))
    compile(tree,str(LIVE),'exec')
    res=run([LIVE,'--help'])
    if res.returncode: fail('Existing CLI --help fails; restore CLI first. No changes made.')
    for cmd in ('sql-admins-save','sql-admins-delete','sql-admins-list'):
        if cmd not in res.stdout: fail('Existing CLI lacks '+cmd+'; abort without changes')
    # A current launcher may have a future import, a module docstring, or both.
    insert_after=1  # shebang line (zero-indexed split at 1)
    for node in tree.body:
        if isinstance(node,ast.ImportFrom) and node.module=='__future__':
            insert_after=max(insert_after,node.end_lineno)
        if node is tree.body[0] and isinstance(node,ast.Expr) and isinstance(node.value,(ast.Constant,)) and isinstance(node.value.value,str):
            insert_after=max(insert_after,node.end_lineno)
    return s,insert_after

def hook(insert_after,s):
    if MARKER in s: return s
    lines=s.splitlines(keepends=True)
    body=(MARKER+'\n'
          'import sys as _hh14_sys\n'
          'if len(_hh14_sys.argv)>1 and _hh14_sys.argv[1] in ("sql-admin-grant","sql-admin-revoke"):\n'
          '    import os as _hh14_os\n'
          '    _hh14_os.execv(_hh14_sys.executable,[_hh14_sys.executable,'+repr(str(HELPER))+']+_hh14_sys.argv[1:])\n')
    out=''.join(lines[:insert_after])+body+''.join(lines[insert_after:])
    ast.parse(out)
    compile(out,str(LIVE),'exec')
    return out

def atomic(p,data,mode):
    if p.exists() and (p.is_symlink() or not p.is_file()): fail('Unsafe target: '+str(p))
    p.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    fd,tmp=tempfile.mkstemp(prefix='.hh-admin14-',dir=p.parent)
    try:
        with os.fdopen(fd,'wb') as fh:
            fh.write(data);fh.flush();os.fsync(fh.fileno())
        if p.exists():
            st=p.stat();os.chown(tmp,st.st_uid,st.st_gid)
        else: os.chown(tmp,0,0)
        os.chmod(tmp,mode)
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def alias_tests():
    for cmd in ('sql-admin-grant','sql-admin-revoke'):
        r=run([LIVE,cmd,'--help'])
        if r.returncode!=0 or 'Usage:' not in r.stdout:
            fail(cmd+' dispatch failed: '+r.stderr[-200:])
    h=run([LIVE,'--help'])
    if h.returncode or 'sql-admins-save' not in h.stdout: fail('Existing --help regressed')

try:
    original,offset=base_check()
    new=hook(offset,original)
    compile(BRIDGE,str(HELPER),'exec')
    if MODE=='check':
        say('Existing controller --help works; SQL admin save/delete/list available')
        say('No V12 marker or pinned controller required; no SQL touched')
        say('Will add grant/revoke aliases only; original functions remain unchanged')
        if new==original: say('Hook already present; will verify helper')
        say('CHECK PASSED; nothing changed')
        sys.exit(0)
    if MODE=='verify':
        regular(HELPER)
        if MARKER not in original: fail('Alias not installed')
        alias_tests()
        say('VERIFY PASSED; aliases available. No SQL rows modified by test.')
        sys.exit(0)
    # Apply. Preserve original CLI and helper and revert both if any test fails.
    BACKUPS.mkdir(parents=True,exist_ok=True)
    snap=BACKUPS/('sql-admin-alias-v14-'+time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid()))
    snap.mkdir(mode=0o700)
    shutil.copy2(LIVE,snap/'controller.before')
    had_helper=HELPER.exists()
    if had_helper:
        regular(HELPER);shutil.copy2(HELPER,snap/'helper.before')
    say('Backup: '+str(snap))
    live_mode=stat.S_IMODE(LIVE.stat().st_mode)
    try:
        atomic(HELPER,BRIDGE.encode('utf-8'),0o700)
        if new!=original: atomic(LIVE,new.encode('utf-8'),live_mode)
        alias_tests()
        say('APPLY SUCCESS: sql-admin-grant/revoke supported; other CLI behavior unchanged')
        say('No SQL inserts/deletes performed by installer')
    except Exception:
        shutil.copy2(snap/'controller.before',LIVE)
        if had_helper: shutil.copy2(snap/'helper.before',HELPER)
        elif HELPER.exists(): HELPER.unlink()
        say('ERROR: Both files restored from backup')
        raise
except (OSError,ValueError,SyntaxError,RuntimeError) as e:
    print('[HH-ADMIN14-ERROR] '+str(e),file=sys.stderr,flush=True)
    sys.exit(1)
PY
