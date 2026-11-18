#!/usr/bin/env bash
# HYPER-HOST CS 1.6 — legacy admin command compatibility bridge.
# Only accepts sql-admin-grant / sql-admin-revoke and forwards to SQL commands from V5.
# Does not edit SQL or game data during installation.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) echo 'Usage: sudo bash HH_CS16_SQL_ADMIN_BRIDGE_V13.sh check|apply|verify' >&2; exit 2;; esac
(( EUID == 0 )) || { echo '[V13-ERROR] Run with sudo' >&2; exit 2; }

export HH_V13_MODE="$MODE"
python3 - <<'PY'
import ast
import json
import os
import pathlib
import py_compile
import shutil
import stat
import subprocess
import sys
import tempfile
import time

Path = pathlib.Path
mode = os.environ['HH_V13_MODE']
live = Path('/usr/local/sbin/hyper-cs16-ctl')
pin = Path('/opt/hyper-cs16/working-controller-v12/hyper-cs16-ctl')
helper = Path('/usr/local/libexec/hyper-cs16/sql-admin-legacy-bridge.py')
backup_root = Path('/opt/hyper-cs16/backups')
marker = '# HH_CS16_SQL_ADMIN_BRIDGE_V13'

code = r'''#!/usr/bin/env python3
# HH_CS16_SQL_ADMIN_BRIDGE_V13 — translate legacy panel calls to existing V5 SQL commands.
# No direct SQL access; delegate to sql-admins-save and sql-admins-delete.
import ipaddress
import json
import pathlib
import re
import subprocess
import sys

REAL = '/opt/hyper-cs16/working-controller-v12/hyper-cs16-ctl'
VALID_ACCESS = re.compile(r'[a-uA-U]{1,32}\Z')
VALID_STEAM = re.compile(r'(?:STEAM|VALVE)_[0-9]+:[0-9]+:[0-9]+\Z', re.I)
VALID_KEYS = {'identity','auth','steamid','steam_id','nickname','username','name','access','access_flags','password','auth_type','type','generate_password','flags','auth_flags','index','server','server_id','id'}
KEYMAP = {'--identity':'identity','--auth':'auth','--steamid':'steamid','--steam-id':'steam_id',
          '--nickname':'nickname','--username':'username','--name':'name','--access':'access',
          '--access-flags':'access_flags','--password':'password','--auth-type':'auth_type',
          '--type':'type','--flags':'flags','--auth-flags':'auth_flags','--index':'index',
          '--server':'server','--server-id':'server_id','--id':'id',
          '--generate-password':'generate_password'}

def fail(msg,code=2):
    print(json.dumps({'ok':False,'error':'SQL admin command: '+msg},ensure_ascii=False),flush=True)
    raise SystemExit(code)

def main():
    av=sys.argv[1:]
    if not av or av[0] not in ('sql-admin-grant','sql-admin-revoke'):
        fail('unsupported command')
    op=av.pop(0)
    if '--help' in av or '-h' in av:
        print('Usage: '+op+' SERVER_ID [IDENTITY ACCESS_FLAGS] [--identity NAME --access FLAGS --password PASS]')
        print('       '+op+' SERVER_ID [IDENTITY|INDEX]  (revoke)')
        raise SystemExit(0)
    # Require explicit server ID. Both servers point to the same game database.
    sid=None
    if av and re.fullmatch(r'\d+',av[0]): sid=av.pop(0)
    kwargs={}
    pos=[]
    while av:
        a=av.pop(0)
        if a.startswith('--'):
            k,sep,val=a.partition('=')
            if k not in KEYMAP: fail('unknown option '+k)
            if not sep:
                if k=='--generate-password': val='true'
                elif av: val=av.pop(0)
                else: fail('missing value for '+k)
            kwargs[KEYMAP[k]]=val
        elif a.startswith('-'): fail('unknown option '+a)
        else: pos.append(a)
    if sid is None: sid=str(kwargs.pop('server_id',kwargs.pop('server',kwargs.pop('id',''))))
    if not re.fullmatch(r'[1-9][0-9]{0,6}',sid): fail('invalid server id')
    if int(sid) not in (25,26): fail('only servers 25 and 26 are configured for shared SQL')
    try:
        raw=sys.stdin.buffer.read(131073) if not sys.stdin.isatty() else b''
    except (OSError,ValueError): raw=b''
    if len(raw)>131072: fail('request too large')
    if raw.strip():
        try: payload=json.loads(raw.decode('utf-8'))
        except (UnicodeError, ValueError): fail('invalid JSON request')
        if not isinstance(payload,dict): fail('JSON object expected')
        for k in payload:
            if k not in VALID_KEYS: fail('unknown JSON field '+str(k))
        kwargs={**payload,**kwargs}
    # Some PHP builds pass a single JSON object as a positional argument.
    if len(pos)==1 and pos[0].lstrip().startswith('{'):
        try: extra=json.loads(pos.pop(0))
        except ValueError: fail('invalid JSON positional request')
        if not isinstance(extra,dict) or not set(extra)<=VALID_KEYS: fail('unsupported JSON fields')
        kwargs={**extra,**kwargs}
    if op=='sql-admin-revoke':
        ident=kwargs.get('identity') or kwargs.get('auth') or kwargs.get('steamid') or kwargs.get('nickname') or kwargs.get('name') or kwargs.get('index')
        if ident is None and len(pos)==1: ident=pos[0]
        if ident is None or len(pos)>1: fail('revoke requires exactly one identity or index')
        ident=str(ident).strip()
        if not ident or len(ident.encode('utf-8'))>64 or any(x in ident for x in '\r\n\x00'): fail('invalid identity')
        target=['sql-admins-delete',sid,ident]
        inp=b''
    else:
        # Avoid assuming password/flag positions when PHP's call format is unknown.
        if len(pos)==2:
            kwargs.setdefault('identity',pos[0]); kwargs.setdefault('access_flags',pos[1])
        elif len(pos)==1:
            kwargs.setdefault('identity',pos[0])
        elif len(pos)>2:
            fail('ambiguous positional grant arguments; use named --access and --password')
        ident=str(next((kwargs[k] for k in ('identity','auth','steamid','steam_id','nickname','username','name') if kwargs.get(k)), '')).strip()
        access=str(kwargs.get('access_flags') or kwargs.get('access') or '').strip()
        if not ident or any(x in ident for x in '\r\n\x00'): fail('missing or invalid identity')
        if not VALID_ACCESS.fullmatch(access): fail('missing/invalid access flags (use a-u)')
        auth_type=str(kwargs.get('auth_type') or kwargs.get('type') or '').lower().strip()
        if not auth_type:
            if VALID_STEAM.fullmatch(ident): auth_type='steamid'
            else:
                try: ipaddress.ip_address(ident); auth_type='ip'
                except ValueError: auth_type='name'
        if auth_type not in ('steamid','name','ip'): fail('invalid auth type')
        password=str(kwargs.get('password') or '')
        if len(password.encode('utf-8'))>32 or any(x in password for x in '\r\n\x00'): fail('invalid password')
        generate=str(kwargs.get('generate_password') or '').lower() in ('1','true','yes','on')
        payload={'identity':ident,'auth_type':auth_type,'access_flags':access,'password':password,'generate_password':generate}
        target=['sql-admins-save',sid]
        inp=json.dumps(payload,ensure_ascii=False).encode('utf-8')
    # Existing V5 functions validate DB/table and implement safe upsert/delete.
    if not pathlib.Path(REAL).is_file(): fail('V12 controller missing')
    try:
        r=subprocess.run([sys.executable,REAL,*target],input=inp,capture_output=True,timeout=25)
    except subprocess.TimeoutExpired: fail('controller timed out',1)
    # Preserve exact JSON output expected by the panel; never echo passwords in logs.
    if r.stdout:
        sys.stdout.buffer.write(r.stdout);sys.stdout.buffer.flush()
    if r.stderr:
        sys.stderr.buffer.write(r.stderr);sys.stderr.buffer.flush()
    raise SystemExit(r.returncode)

if __name__=='__main__': main()
'''


def die(s): raise RuntimeError(s)
def say(s): print('[HH-V13] '+s,flush=True)
def regular(p):
    if p.is_symlink() or (p.exists() and not p.is_file()): die('unsafe file type: '+str(p))
    if not p.is_file() or not p.stat().st_size: die('missing/empty: '+str(p))
def run(argv,timeout=15):
    try: return subprocess.run(argv,capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired: die('timeout: '+str(argv[0]))

def validate():
    regular(live); regular(pin)
    source=live.read_text(encoding='utf-8')
    if 'HH-CS16-V12' not in source: die('V12 launcher not detected: refusal to alter unknown controller')
    if "os.execv(sys.executable,[sys.executable,SOURCE]+sys.argv[1:])" not in source:
        die('V12 handoff anchor not found')
    ast.parse(source); compile(source,str(live),'exec')
    pinned=pin.read_text(encoding='utf-8')
    pt=ast.parse(pinned)
    fn={n.name for n in pt.body if isinstance(n,ast.FunctionDef)}
    if not {'sql_admins_save','sql_admins_delete','sql_admins_list'}<=fn:
        die('Pinned controller lacks V5 SQL admin methods')
    if not all(x in pinned for x in ("'sql-admins-save'","'sql-admins-delete'")):
        die('Pinned controller CLI lacks V5 SQL subcommands')
    r=run([sys.executable,str(pin),'--help'],12)
    if r.returncode or 'sql-admins-save' not in r.stdout or 'sql-admins-delete' not in r.stdout:
        die('Pinned V5 CLI help test failed: '+r.stderr[-250:])
    return source

def render_launcher(source):
    if marker in source: return source
    line=("if len(sys.argv)>1 and sys.argv[1] in ('sql-admin-grant','sql-admin-revoke'):\n"
          "    os.execv(sys.executable,[sys.executable,'/usr/local/libexec/hyper-cs16/sql-admin-legacy-bridge.py']+sys.argv[1:])\n")
    anchor="if len(sys.argv)>1 and sys.argv[1]=='bots-enable' and os.path.isfile(BOTS):"
    if source.count(anchor)!=1: die('V12 bots anchor changed; refusing uncertain patch')
    result=source.replace(anchor,marker+'\n'+line+anchor,1)
    ast.parse(result);compile(result,str(live),'exec')
    return result

def atomic(p,data,mode):
    if p.exists() and (p.is_symlink() or not p.is_file()): die('unsafe target '+str(p))
    p.parent.mkdir(mode=0o750,parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.hh-v13-',dir=p.parent)
    try:
        with os.fdopen(fd,'wb') as h:
            h.write(data);h.flush();os.fsync(h.fileno())
        os.chmod(tmp,mode); os.chown(tmp,0,0)
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

try:
    original=validate()
    output=render_launcher(original)
    compile(code,str(helper),'exec')
    if mode=='check':
        say('V12 launcher + V5 SQL admin functions verified; no files changed')
        say('Legacy commands will be translated to sql-admins-save/delete')
        say('CHECK PASSED')
        raise SystemExit(0)
    if mode=='verify':
        regular(helper)
        if marker not in original: die('V13 launcher hook not installed')
        for legacy in ('sql-admin-grant','sql-admin-revoke'):
            h=run([str(live),legacy,'--help'],12)
            if h.returncode or 'Usage:' not in h.stdout:
                die(legacy+' dispatch is not functional: '+h.stderr[-200:])
        say('VERIFY PASSED. No database rows changed by verification.')
        raise SystemExit(0)
    backup_root.mkdir(parents=True,exist_ok=True)
    bp=backup_root/('sql-admin-compat-v13-'+time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid()))
    bp.mkdir(mode=0o700)
    shutil.copy2(live,bp/'launcher.before')
    h_exists=helper.exists()
    if h_exists:
        regular(helper); shutil.copy2(helper,bp/'helper.before')
    say('Backup: '+str(bp))
    try:
        atomic(helper,code.encode('utf-8'),0o700)
        atomic(live,output.encode('utf-8'),0o755)
        for legacy in ('sql-admin-grant','sql-admin-revoke'):
            h=run([str(live),legacy,'--help'],12)
            if h.returncode or 'Usage:' not in h.stdout: die(legacy+' dispatch failed')
        h=run([str(live),'sql-status','25'],18)
        if h.returncode: die('existing sql-status 25 regressed: '+h.stderr[-200:])
        try: obj=json.loads(h.stdout)
        except ValueError: die('sql-status output not JSON')
        if obj.get('database')!='cs16_srv_25' or not obj.get('connected'):
            die('sql-status 25 unexpectedly not connected')
        say('APPLY SUCCESS. SQL-admin command adapter installed; other controller commands unchanged.')
    except Exception:
        shutil.copy2(bp/'launcher.before',live)
        if h_exists: shutil.copy2(bp/'helper.before',helper)
        elif helper.exists(): helper.unlink()
        say('Installation FAILED: launcher/helper rolled back')
        raise
except (RuntimeError, OSError, SyntaxError, ValueError) as e:
    print('[HH-V13-ERROR] '+str(e),file=sys.stderr,flush=True)
    raise SystemExit(1)
PY
