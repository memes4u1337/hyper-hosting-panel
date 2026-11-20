#!/usr/bin/env bash
# HYPER-HOST CS 1.6 / V17: display AMXX SQL admins expiration from V16 registry.
# Only modifies the sql_admins_list Python source; never touches SQL rows, grants, FTP or games.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) printf '%s\n' 'Usage: sudo bash HH_CS16_ADMIN_EXPIRY_STATUS_V17.sh check|apply|verify'; exit 2;; esac
if (( EUID != 0 )); then echo '[V17-ERROR] Run with sudo' >&2; exit 2; fi
export HH_V17_MODE="$MODE"
python3 - <<'PY'
import ast, datetime as dt, json, os, pathlib, re, shutil, stat, subprocess, sys, tempfile, time
P=pathlib.Path
MODE=os.environ['HH_V17_MODE']
PHP=P('/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/index.php')
REG=P('/var/lib/hyper-cs16/sql-admin-expirations/registry.json')
CLI=P('/usr/local/sbin/hyper-cs16-ctl')
BACKUP_ROOT=P('/opt/hyper-cs16/backups')
MARK='# HH_SQL_ADMINS_V5_END'
FIX_START='# HH_CS16_ADMIN_EXPIRY_LIST_V17_BEGIN'
FIX_END='# HH_CS16_ADMIN_EXPIRY_LIST_V17_END'

# Exact V16 registry schema. This is admin expiration metadata, not an AMXX SQL schema migration.
ADAPTER=r'''
# HH_CS16_ADMIN_EXPIRY_LIST_V17_BEGIN
_hh_v17_previous_sql_admins_list = sql_admins_list
def sql_admins_list(sid):
    import datetime as _hhdt
    import json as _hhjson
    from pathlib import Path as _hhpath
    response = _hh_v17_previous_sql_admins_list(sid)
    regpath = _hhpath('/var/lib/hyper-cs16/sql-admin-expirations/registry.json')
    registry = {'version':1,'entries':{}}
    if regpath.is_file():
        registry = _hhjson.loads(regpath.read_text(encoding='utf-8'))
    if not isinstance(registry,dict) or registry.get('version')!=1 or not isinstance(registry.get('entries'),dict):
        raise RuntimeError('Admin expiry registry format invalid; refusing incorrect status')
    now = _hhdt.datetime.now(_hhdt.timezone.utc)
    data = response.get('admins') or []
    for row in data:
        identity = str(row.get('identity') or row.get('auth') or '').casefold()
        entry = registry['entries'].get(identity)
        if entry:
            stamp = str(entry.get('expires_at') or '')
            expires = _hhdt.datetime.fromisoformat(stamp)
            if expires.tzinfo is None:
                raise RuntimeError('Invalid timezone in admin expiry registry')
            expires = expires.astimezone(_hhdt.timezone.utc)
            expired = expires <= now
            expiry_iso = expires.isoformat()
            label = expires.strftime('%d.%m.%Y %H:%M UTC')
        else:
            # V16 has no expiration record for permanent and previously existing AMXX admins.
            expired = False
            expiry_iso = '9999-12-31T23:59:59+00:00'
            label = 'Навсегда'
        row.update({'expires_at':expiry_iso,'expire_at':expiry_iso,'expiry_at':expiry_iso,
                    'expired':expired,'is_expired':expired,'active':not expired,
                    'forever':entry is None,'status':'expired' if expired else 'active',
                    'duration_label':label,'expires_label':label})
    response['_hh_v17_expiry_metadata'] = True
    return response
# HH_CS16_ADMIN_EXPIRY_LIST_V17_END
'''

class Stop(Exception): pass

def fail(message): raise Stop(message)
def log(s): print('[HH-ADMIN17] '+s,flush=True)
def run(argv,timeout=30):
    try: return subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=timeout)
    except subprocess.TimeoutExpired: fail('CLI timed out (no files modified)')
def list_data():
    p=run([str(CLI),'sql-admins-list','25'],timeout=30)
    if p.returncode:
        fail('Current sql-admins-list does not run; status code not changed. Error type: '+(p.stderr.splitlines()[-1][:180] if p.stderr.strip() else 'nonzero status'))
    try: d=json.loads(p.stdout)
    except ValueError: fail('sql-admins-list is not returning JSON')
    if not isinstance(d,dict) or d.get('ok') is not True or not isinstance(d.get('admins'),list):
        fail('sql-admins-list response is not an admin list')
    return d

try:
    if not PHP.is_file() or PHP.is_symlink(): fail('Installed PHP page missing/unsafe path')
    if not CLI.is_file(): fail('Installed controller missing')
    phpsrc=PHP.read_text(errors='replace')
    # Do not patch the CLI if this page isn't actually using it for the admin list.
    if 'sql-admins-list' not in phpsrc:
        matches=[]
        for i,line in enumerate(phpsrc.splitlines(),1):
            if re.search(r'(?i)sql.admin.list|истекл|expir|duration_label',line):
                matches.append(f'{i}: '+line.strip()[:200])
        log('Installed PHP does not contain sql-admins-list; no changes. The page has a different data source.')
        for line in matches[:8]: log('Source hint '+line)
        fail('Need the SQL-admin listing/status expression from installed PHP; refusing an unrelated patch')
    if REG.exists():
        r=json.loads(REG.read_text(encoding='utf8'))
        if r.get('version')!=1 or not isinstance(r.get('entries'),dict): fail('Unexpected registry format')
        active=expired=0
        for obj in r['entries'].values():
            when=dt.datetime.fromisoformat(str(obj['expires_at']))
            if when.tzinfo is None: fail('Registry has timezone-less expiration')
            if when.astimezone(dt.timezone.utc)>dt.datetime.now(dt.timezone.utc): active+=1
            else: expired+=1
        log(f'V16 registry: future={active}, expired={expired} (no SteamIDs/passwords shown)')
    else:
        log('No V16 expiry registry on disk: existing admins will be treated as permanent')
    current=list_data()
    log('SQL admin list connected: '+str(len(current['admins']))+' records')

    # Find Python implementations, never touch shell wrappers or unrelated scripts.
    roots=[P('/root/hyper-hosting-panel/cs16-panel/bin'), P('/usr/local/sbin'), P('/usr/local/libexec/hyper-cs16'),P('/opt/hyper-cs16')]
    paths=set()
    for root in roots:
        if not root.is_dir(): continue
        for directory,subdirs,files in os.walk(root):
            subdirs[:]=[d for d in subdirs if d not in ('backups','servers','gamefiles','fastdl','base','cache','__pycache__','logs','steamcmd','downloads','temp')]
            depth=len(P(directory).relative_to(root).parts)
            if depth>=5: subdirs[:]=[]
            for name in files:
                if not ('hyper-cs16-ctl' in name or 'working-controller' in name or name.endswith('.py')): continue
                p=P(directory)/name
                try:
                    if p.is_symlink() or p.stat().st_size>2000000 or p.stat().st_size<500: continue
                    s=p.read_text(encoding='utf-8')
                    if MARK not in s or 'def sql_admins_list(' not in s: continue
                    tr=ast.parse(s)
                    if not any(isinstance(n,ast.FunctionDef) and n.name=='sql_admins_list' for n in tr.body): continue
                    paths.add(p)
                except (OSError,UnicodeError,SyntaxError): continue
    if not paths: fail('V5 SQL admin list implementation not found; controller files untouched')
    paths=sorted(paths)
    staged={}
    for p in paths:
        s=p.read_text(encoding='utf-8')
        if FIX_START in s:
            if s.count(FIX_START)!=1 or s.count(FIX_END)!=1: fail('Multiple V17 markers in '+str(p))
            updated=s
        else:
            if s.count(MARK)!=1: fail('Ambiguous V5 marker in '+str(p))
            updated=s.replace(MARK,MARK+'\n'+ADAPTER,1)
        compile(updated,str(p),'exec')
        staged[p]=updated
    log('V5 implementation candidates: '+str(len(paths)))
    for p in paths: log('  '+str(p))
    if MODE=='check':
        log('CHECK PASSED; no SQL, PHP, controller or registry files changed')
        log('APPLY will update only V5 admin-list source files and verify live CLI response')
        sys.exit(0)
    if MODE=='verify':
        if not current.get('_hh_v17_expiry_metadata'):
            fail('Live CLI has no V17 expiry metadata')
        for row in current['admins']:
            if not all(k in row for k in ('expires_at','forever','is_expired','status','duration_label')):
                fail('Admin list is missing V17 status fields')
            entry=(r.get('entries',{}) if REG.exists() else {}).get(str(row.get('identity') or '').casefold())
            if entry and row['expires_at'] != dt.datetime.fromisoformat(entry['expires_at']).astimezone(dt.timezone.utc).isoformat():
                fail('V17 status does not match expiry registry')
        log('VERIFY PASSED: CLI returns real expiration data (including permanent grants)')
        sys.exit(0)
    if current.get('_hh_v17_expiry_metadata'):
        log('Already installed in live CLI; no changes needed')
        sys.exit(0)
    BACKUP_ROOT.mkdir(parents=True,exist_ok=True)
    bdir=BACKUP_ROOT/('admin-expiry-v17-'+time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid()))
    bdir.mkdir(mode=0o700)
    saved={}
    for i,p in enumerate(paths):
        f=bdir/('file_'+str(i)+'.before')
        shutil.copy2(p,f); saved[p]=f
    (bdir/'source-paths.json').write_text(json.dumps([str(p) for p in paths],indent=2))
    log('Backup: '+str(bdir))
    try:
        for p,updated in staged.items():
            st=p.stat()
            fd,tmp=tempfile.mkstemp(prefix='.hhadmin17-',dir=p.parent)
            try:
                with os.fdopen(fd,'w') as file:
                    file.write(updated);file.flush();os.fsync(file.fileno())
                os.chmod(tmp,stat.S_IMODE(st.st_mode));os.chown(tmp,st.st_uid,st.st_gid)
                os.replace(tmp,p)
            finally:
                if os.path.exists(tmp): os.unlink(tmp)
        now=list_data()
        if not now.get('_hh_v17_expiry_metadata'): fail('Live CLI did not receive V17 fields; reverting every file')
        if [r.get('identity') for r in now['admins']] != [r.get('identity') for r in current['admins']]:
            fail('Admin list changed unexpectedly; reverting')
        for row in now['admins']:
            if 'expires_at' not in row or 'is_expired' not in row:
                fail('Incomplete status projection; reverting')
        log('APPLY SUCCESS: expiration status now comes from V16 registry')
        log('No admin permissions, SQL rows, PHP page, FTP, FastDL or game processes were changed')
    except BaseException:
        for p,backup in saved.items():
            shutil.copy2(backup,p)
        log('ROLLBACK: original Python sources restored')
        raise
except Stop as exc:
    print('[HH-ADMIN17-ERROR] '+str(exc),file=sys.stderr)
    sys.exit(1)
PY
