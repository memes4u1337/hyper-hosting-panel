#!/usr/bin/env bash
# HYPER-HOST: V15 - repair V14 SQL admin JSON adapter ONLY.
# Does not edit the cs16 controller, game files, FTP, database, Nginx or services.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) echo 'Usage: sudo bash HH_CS16_SQL_ADMIN_ALIAS_V15.sh check|apply|verify' >&2; exit 2;; esac
if [[ $EUID -ne 0 ]]; then echo '[HH-ADMIN15-ERROR] Run with sudo' >&2; exit 2; fi
export HH15_MODE="$MODE"
python3 - <<'PYINSTALL'
import os, pathlib, tempfile, shutil, stat, subprocess, sys, time, ast
P=pathlib.Path
live=P('/usr/local/sbin/hyper-cs16-ctl')
helper=P('/usr/local/libexec/hyper-cs16/sql-admin-alias-v14.py')
backup_root=P('/opt/hyper-cs16/backups')
mode=os.environ['HH15_MODE']

def fail(message):
    print('[HH-ADMIN15-ERROR] '+str(message),file=sys.stderr,flush=True)
    raise SystemExit(1)
def say(message): print('[HH-ADMIN15] '+message,flush=True)
def test(args,timeout=15):
    try: return subprocess.run(args,input=b'',capture_output=True,timeout=timeout)
    except subprocess.TimeoutExpired: fail('Timeout from CLI - nothing modified')
def safe_file(p):
    if not p.is_file() or p.is_symlink() or not p.stat().st_size:
        fail('Missing or unsafe path: '+str(p))

# This helper is dispatched only by the already installed V14 controller hook.
# No database connection or SQL changes are made by installation/check/verify.
BRIDGE=r'''#!/usr/bin/env python3
# HH_CS16_SQL_ADMIN_ALIAS_V15: compatible JSON input for the V14 dispatcher.
import ipaddress
import json
import re
import subprocess
import sys

LIVE='/usr/local/sbin/hyper-cs16-ctl'
ALLOWED={'sql-admin-grant','sql-admin-revoke'}
ACCESS=re.compile(r'[a-uA-U]{1,32}\Z')
STEAM=re.compile(r'(?:STEAM|VALVE)_[0-9]+:[0-9]+:[0-9]+\Z',re.I)

# GUI naming variations; names are never trusted as values.
ALIASES={
 'identity':'identity','identifier':'identity','player':'identity','target':'identity','admin_auth':'identity','admin':'identity',
 'auth':'auth','steamid':'steamid','steam_id':'steamid','steam':'steamid',
 'nickname':'nickname','nick':'nickname','username':'username','login':'username','name':'name',
 'access':'access','access_flags':'access_flags','accessflags':'access_flags',
 'permissions':'access_flags','privileges':'access_flags','admin_access':'access_flags',
 'password':'password','pass':'password','pw':'password',
 'auth_type':'auth_type','authtype':'auth_type','identity_type':'auth_type',
 'generate_password':'generate_password','generatepassword':'generate_password',
 'index':'index','admin_index':'index','admin_id':'index','row_index':'index',
 'server_id':'server_id','serverid':'server_id','server':'server_id',
 'id':'id',
 'flags':'flags','auth_flags':'auth_flags',
}
CONTAINERS={'payload','data','admin','record','fields','values','params','request','body'}
# Additional metadata may be included by UI; never derive privileges from these.
METADATA={'action','operation','op','cmd','csrf','_csrf','token','comment','description','reason',
          'created_at','updated_at','expires_at','expires','duration','days','source','reload',
          'server_name','display_name','label','notes','commentary','table','database',
          'auth_flags','flags','type_flags','account_flags'}
FLAGS={'--identity':'identity','--identifier':'identity','--auth':'auth',
       '--steamid':'steamid','--steam-id':'steamid','--nickname':'nickname','--name':'name',
       '--username':'username','--access':'access','--access-flags':'access_flags',
       '--password':'password','--auth-type':'auth_type','--type':'auth_type',
       '--index':'index','--server':'server_id','--server-id':'server_id',
       '--admin-id':'index','--generate-password':'generate_password'}

def fail(msg, **details):
    result={'ok':False,'error':'SQL admin alias: '+msg}
    result.update(details)
    print(json.dumps(result,ensure_ascii=False,separators=(',',':')))
    raise SystemExit(2)

def keynorm(key):
    # Strip punctuation and make camelCase/underscore aliases comparable.
    return re.sub(r'[^a-z0-9_]', '', re.sub(r'([a-z0-9])([A-Z])',r'\1_\2',str(key)).lower().replace('-','_'))

def safe_keys(obj):
    # Names only, no data values, protects admin credentials in error output.
    if not isinstance(obj,dict): return []
    return sorted(re.sub('[^A-Za-z0-9_-]','?',str(k))[:48] for k in obj)[:50]

def flatten(obj,depth=0):
    if not isinstance(obj,dict): fail('JSON object expected',json_type=type(obj).__name__)
    if depth>3: fail('JSON nesting too deep')
    known={}; ignored=[]
    # Process nested objects first, then override with explicit top-level fields.
    for key,val in obj.items():
        nk=keynorm(key)
        if nk in CONTAINERS and isinstance(val,dict):
            child,rest=flatten(val,depth+1)
            known.update(child);ignored.extend(rest)
    for key,val in obj.items():
        nk=keynorm(key)
        if nk in CONTAINERS and isinstance(val,dict): continue
        canon=ALIASES.get(nk)
        if canon:
            if isinstance(val,(str,int,float,bool)) or val is None: known[canon]=val
            elif canon=='access_flags' and isinstance(val,list) and all(isinstance(x,str) for x in val):
                known[canon]=''.join(val)
            else: fail('Unsupported value type for '+nk,field=nk,value_type=type(val).__name__)
        else: ignored.append(nk)
    return known,sorted(set(ignored))

def get(options,keys):
    for k in keys:
        value=options.get(k)
        if value is not None and str(value).strip()!='': return value
    return ''

def asbool(x): return x is True or str(x).strip().lower() in ('true','1','yes','on')

def main():
    av=sys.argv[1:]
    if not av or av[0] not in ALLOWED: fail('Unsupported operation')
    op=av.pop(0)
    if '--help' in av or '-h' in av:
        print('Usage: '+op+' SERVER_ID [IDENTITY ACCESS_FLAGS] [--identity ID --access FLAGS --password PASS]')
        print('       JSON request via stdin: identity/auth/steamid, access/access_flags, password')
        return
    sid=None
    if av and re.fullmatch(r'[0-9]+',av[0]): sid=av.pop(0)
    opts={};pos=[]
    while av:
        item=av.pop(0)
        if item.startswith('--'):
            flag,sep,val=item.partition('=')
            canon=FLAGS.get(flag)
            if canon is None: fail('Unknown CLI option',option=flag)
            if not sep:
                if flag=='--generate-password': val='true'
                elif av: val=av.pop(0)
                else: fail('Missing CLI option value',option=flag)
            opts[canon]=val
        elif item.startswith('-'): fail('Unknown CLI argument')
        else: pos.append(item)
    # PHP's ctl() supplies optional JSON via stdin. It closes stdin on exit.
    raw=sys.stdin.buffer.read(131073) if not sys.stdin.isatty() else b''
    if len(raw)>131072: fail('Request too large')
    payload={}
    if raw.strip():
        try: payload=json.loads(raw.decode('utf-8'))
        except (UnicodeError,ValueError): fail('Invalid JSON request')
    if len(pos)==1 and pos[0].lstrip().startswith('{'):
        try: extra=json.loads(pos.pop(0))
        except ValueError: fail('Invalid positional JSON')
        if payload: fail('Two JSON payloads provided')
        payload=extra
    if isinstance(payload,list):
        if len(payload)==1 and isinstance(payload[0],dict): payload=payload[0]
        else: fail('Unsupported JSON array',array_length=len(payload))
    if payload:
        parsed,unknown=flatten(payload)
        # Do not silently discard fields that could affect administrator privileges.
        unsupported=[k for k in unknown if k not in METADATA]
        if unsupported:
            fail('Unrecognized JSON fields; field names only',fields=unsupported,received_keys=safe_keys(payload))
        opts={**parsed,**opts}
    if sid is None:
        sid=str(get(opts,('server_id','id'))).strip()
    if not re.fullmatch(r'[1-9][0-9]{0,6}',str(sid)): fail('Server ID missing/invalid')
    if int(sid) not in (25,26): fail('This adapter supports only shared SQL servers 25/26')
    if op=='sql-admin-revoke':
        # id with explicit SERVER_ID is the admin row identifier, not the server id.
        if opts.get('id') is not None and 'index' not in opts and ('server_id' in opts or sid is not None):
            opts['index']=opts['id']
        ident=get(opts,('index','identity','auth','steamid','nickname','username','name'))
        if not ident and len(pos)==1: ident=pos.pop(0)
        if pos: fail('Ambiguous revoke arguments')
        ident=str(ident).strip()
        if not ident or len(ident.encode('utf-8'))>64 or any(x in ident for x in '\r\n\x00'):
            fail('Invalid revoke identity/index')
        target=['sql-admins-delete',str(sid),ident]
        request=b''
    else:
        if len(pos)==2:
            opts.setdefault('identity',pos[0]);opts.setdefault('access_flags',pos[1])
        elif len(pos)==3:
            opts.setdefault('identity',pos[0]);opts.setdefault('access_flags',pos[1]);opts.setdefault('password',pos[2])
        elif len(pos)==1: opts.setdefault('identity',pos[0])
        elif pos: fail('Ambiguous grant arguments')
        ident=str(get(opts,('identity','auth','steamid','nickname','username','name'))).strip()
        access=str(get(opts,('access_flags','access'))).strip()
        if not ident or len(ident.encode('utf-8'))>32 or any(x in ident for x in '\r\n\x00'):
            fail('Missing/invalid identity',recognized_fields=sorted(opts))
        if not ACCESS.fullmatch(access): fail('Missing/invalid access flags a-u',recognized_fields=sorted(opts))
        auth_type=str(get(opts,('auth_type',))).lower().strip()
        if not auth_type:
            if STEAM.fullmatch(ident): auth_type='steamid'
            else:
                try: ipaddress.ip_address(ident);auth_type='ip'
                except ValueError: auth_type='name'
        if auth_type not in ('steamid','name','ip'): fail('Invalid authentication type')
        password=str(opts.get('password') or '')
        if len(password.encode('utf-8'))>32 or any(c in password for c in '\r\n\x00'):
            fail('Invalid password')
        pl={'identity':ident,'access_flags':access,'auth_type':auth_type,
            'password':password,'generate_password':asbool(opts.get('generate_password'))}
        target=['sql-admins-save',str(sid)]
        request=json.dumps(pl,ensure_ascii=False).encode('utf-8')
    try:
        r=subprocess.run([sys.executable,LIVE,*target],input=request,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=40)
    except subprocess.TimeoutExpired: fail('SQL controller timed out')
    if r.stdout: sys.stdout.buffer.write(r.stdout);sys.stdout.buffer.flush()
    if r.stderr: sys.stderr.buffer.write(r.stderr);sys.stderr.buffer.flush()
    raise SystemExit(r.returncode)

if __name__=='__main__': main()
'''

try:
    safe_file(live)
    safe_file(helper)
    old=helper.read_text(encoding='utf-8')
    if 'HH_CS16_SQL_ADMIN_ALIAS_V14' not in old and 'HH_CS16_SQL_ADMIN_ALIAS_V15' not in old:
        fail('Unknown helper version. Refusing to overwrite unrelated code')
    if 'sql-admin-grant' not in old or 'sql-admin-revoke' not in old:
        fail('Current helper is not an admin alias adapter')
    compile(BRIDGE,str(helper),'exec')
    # Be certain V14 dispatcher is present, without touching it.
    src=live.read_text(encoding='utf-8')
    if 'HH_CS16_SQL_ADMIN_ALIAS_V14' not in src:
        fail('V14 dispatch hook not found; script changes no files')
    if mode=='check':
        say('V14 hook found; replacing only its JSON helper')
        say('No changes to controllers, game files, SQL, FTP, FastDL or bots')
        say('CHECK PASSED')
        raise SystemExit(0)
    if mode=='verify':
        if 'HH_CS16_SQL_ADMIN_ALIAS_V15' not in old: fail('V15 helper not installed')
        for op in ('sql-admin-grant','sql-admin-revoke'):
            r=test([sys.executable,str(helper),op,'--help'])
            if r.returncode!=0 or b'Usage:' not in r.stdout: fail('Helper self-test failed for '+op)
        say('VERIFY PASSED; aliases parse; no database rows changed')
        raise SystemExit(0)
    # File-only atomic replace with rollback and a private backup.
    backup_root.mkdir(parents=True,exist_ok=True)
    backup=backup_root/('sql-admin-json-v15-'+time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid()))
    backup.mkdir(mode=0o700)
    shutil.copy2(helper,backup/'helper.before')
    say('Backup: '+str(backup/'helper.before'))
    fd,tmp=tempfile.mkstemp(prefix='.hh-admin-v15-',dir=helper.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            f.write(BRIDGE);f.flush();os.fsync(f.fileno())
        os.chown(tmp,helper.stat().st_uid,helper.stat().st_gid)
        os.chmod(tmp,stat.S_IMODE(helper.stat().st_mode))
        os.replace(tmp,helper)
        for op in ('sql-admin-grant','sql-admin-revoke'):
            r=test([sys.executable,str(helper),op,'--help'])
            if r.returncode!=0 or b'Usage:' not in r.stdout:
                raise RuntimeError(op+' helper test failed')
        say('APPLY SUCCESS; V14 JSON helper updated; SQL untouched')
    except Exception:
        shutil.copy2(backup/'helper.before',helper)
        say('ROLLBACK: original helper restored')
        raise
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
except (OSError,ValueError,SyntaxError,RuntimeError) as e:
    fail(str(e))
PYINSTALL
