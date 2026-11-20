#!/usr/bin/env bash
# HH-CS16 SQL Admin Delete V18 - adapt the V16 revoke handler to V5's 0-based list indices.
# Deliberately does NOT modify SQL rows, servers, PHP or other controller code at install time.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) echo 'Usage: sudo bash HH_CS16_SQL_ADMIN_DELETE_V18.sh check|apply|verify' >&2; exit 2 ;; esac
if (( EUID != 0 )); then echo '[HH-ADMIN18-ERROR] Run with sudo' >&2; exit 2; fi
HH_V18_MODE="$MODE" python3 - <<'PY'
import ast
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

HELPER = Path('/usr/local/libexec/hyper-cs16/sql-admin-alias-v14.py')
PANEL = Path('/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/index.php')
CLI = Path('/usr/local/sbin/hyper-cs16-ctl')
BACKUPS = Path('/opt/hyper-cs16/backups')
MARK = '# HH_CS16_SQL_ADMIN_DELETE_INDEX_V18'
MODE = os.environ['HH_V18_MODE']

NEW_FUNCTION = '''def resolve_row_id(cfg,numeric_id):
    # HH_CS16_SQL_ADMIN_DELETE_INDEX_V18
    # In V5 sql_admins_list(), "id" and "index" are zero-based positions
    # in SELECT ... ORDER BY auth. The AMXX admins table has NO SQL id column.
    if not isinstance(numeric_id,str) or not numeric_id.isdecimal():
        raise UserError('Invalid admin list index')
    index=int(numeric_id)
    if index<0 or index>100000:
        raise UserError('Invalid admin list index')
    table=table_for(cfg)
    if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',table):
        raise UserError('Invalid admin table name')
    db=sql_connect(cfg)
    try:
        with db.cursor() as cur:
            # EXACTLY the same ordering as V5 _hh_sql_admins_rows.
            cur.execute('SELECT `auth` FROM `'+table+'` ORDER BY `auth`')
            rows=cur.fetchall()
            if index>=len(rows):
                raise UserError('Admin list changed; refresh the page')
            identity=str(rows[index].get('auth') or '')
            if not identity:
                raise UserError('Selected admin has no identity')
            # V5 interprets a numeric string as another list index. Refuse
            # rather than risking removal of the wrong numeric nickname.
            if identity.isdecimal():
                raise UserError('Numeric nickname cannot be removed safely by V5')
            cur.execute('SELECT COUNT(*) AS n FROM `'+table+'` WHERE `auth`=%s',(identity,))
            count=cur.fetchone()
            if int((count or {}).get('n') or 0)!=1:
                raise UserError('Selected admin is missing or duplicated; nothing deleted')
        # V16 passes the verified identity to V5 sql-admins-delete, which
        # locks and deletes exactly one matching auth row and reloads AMXX.
        return identity
    finally:
        db.close()
'''

class Abort(Exception):
    pass

def log(s):
    print('[HH-ADMIN18] '+s, flush=True)

def stop(s):
    raise Abort(s)

def read(path):
    if not path.is_file() or path.is_symlink():
        stop('Expected regular file missing or symlink: '+str(path))
    return path.read_text(encoding='utf-8')

def get_function(source):
    try: tr=ast.parse(source)
    except SyntaxError: stop('Existing helper contains invalid Python syntax')
    nodes=[x for x in tr.body if isinstance(x,ast.FunctionDef) and x.name=='resolve_row_id']
    if len(nodes)!=1: stop('Expected exactly one resolve_row_id in V16 helper')
    return nodes[0]

def stage(source):
    node=get_function(source)
    lines=source.splitlines(keepends=True)
    old=''.join(lines[node.lineno-1:node.end_lineno])
    if MARK in old:
        return source, False
    if 'Admin table has no id column; unsafe deletion refused' not in old:
        stop('Unknown resolver; refusing to replace code from an unexpected version')
    replaced=''.join(lines[:node.lineno-1])+NEW_FUNCTION+'\n'+''.join(lines[node.end_lineno:])
    try: compile(replaced,str(HELPER),'exec')
    except SyntaxError: stop('Generated helper has invalid Python syntax')
    return replaced, True

def load_helper(path):
    spec=importlib.util.spec_from_file_location('hh_v18_testing_helper',str(path))
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def check_runtime():
    if not CLI.is_file() or not PANEL.is_file(): stop('Panel/controller missing')
    php = read(PANEL)
    if "ctl(['sql-admin-revoke',$id,$adminId]" not in php:
        stop('Installed PHP does not use V16 sql-admin-revoke endpoint')
    if 'sql-admins-list' not in php:
        stop('PHP admin list source not recognized; no modification')
    chk = subprocess.run(['php','-l',str(PANEL)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=15)
    if chk.returncode: stop('Existing PHP contains a syntax error')
    proc=subprocess.run([str(CLI),'sql-admins-list','25'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=35)
    if proc.returncode: stop('Live sql-admins-list failed; cannot verify index mapping')
    try: data=json.loads(proc.stdout)
    except ValueError: stop('Live admin list returned non-JSON data')
    users=data.get('admins') if isinstance(data,dict) and data.get('ok') is True else None
    if not isinstance(users,list): stop('Live admin list response missing admins')
    for i,u in enumerate(users):
        if not isinstance(u,dict) or u.get('index')!=i or u.get('id')!=i:
            stop('Admin IDs are not V5 zero-based indices; refusing unsafe deletion')
    # Read-only comparison to the ACTUAL AMXX table used by V5.
    helper=load_helper(HELPER)
    try:
        cfg=helper.load_config(25)
        table=helper.table_for(cfg)
        if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',table): stop('Invalid AMXX admin table name')
        db=helper.sql_connect(cfg)
        try:
            with db.cursor() as cur:
                cur.execute('SELECT `auth` FROM `'+table+'` ORDER BY `auth`')
                actual=[str(r.get('auth') or '') for r in cur.fetchall()]
        finally: db.close()
    except Abort: raise
    except Exception: stop('Cannot read AMXX SQL admins for comparison')
    expected=[str(u.get('auth') or u.get('identity') or '') for u in users]
    if actual!=expected: stop('SQL order differs from panel admin list; deletion remains disabled')
    log(f'Admin list verified: {len(users)} indexed records, same SQL sort order (no identities shown)')
    return helper, users

def selftest(module):
    # Database mocked. Tests cannot change any real SQL rows.
    class Cursor:
        def __init__(self,rows): self.rows=rows; self.query=''; self.params=None
        def __enter__(self): return self
        def __exit__(self,*a): return False
        def execute(self,sql,params=None): self.query=sql; self.params=params
        def fetchall(self): return [{'auth':u} for u in self.rows]
        def fetchone(self):
            identity=self.params[0]
            return {'n':sum(u==identity for u in self.rows)}
    class DB:
        def __init__(self,rows): self.rows=rows; self.closed=False
        def cursor(self): return Cursor(self.rows)
        def close(self): self.closed=True
    old_connect=module.sql_connect
    old_table=module.table_for
    rows=['STEAM_0:1:111','STEAM_0:1:222']
    try:
        module.sql_connect=lambda cfg:DB(rows)
        module.table_for=lambda cfg:'admins'
        assert module.resolve_row_id({},'0')==rows[0]
        assert module.resolve_row_id({},'1')==rows[1]
        for bad in ('2','-1','abc'):
            try: module.resolve_row_id({},bad)
            except module.UserError: pass
            else: stop('Selftest failed to reject index '+bad)
        rows[:]=['STEAM_0:1:111','STEAM_0:1:111']
        try: module.resolve_row_id({},'0')
        except module.UserError: pass
        else: stop('Selftest failed to reject duplicate auth')
        rows[:]=['12345']
        try: module.resolve_row_id({},'0')
        except module.UserError: pass
        else: stop('Selftest failed to reject numeric nickname')
    finally:
        module.sql_connect=old_connect
        module.table_for=old_table
    log('Read-only selftest: index 0/1 and safety checks PASSED')

try:
    original=read(HELPER)
    if 'HYPER-HOST SQL Admin V16' not in original:
        stop('V16 helper signature not found')
    proposed,changed=stage(original)
    if MODE=='verify' and changed: stop('V18 resolver is not installed')
    runtime,users=check_runtime()
    if MODE=='verify':
        selftest(runtime)
        log('VERIFY PASSED: index-based removal installed; no SQL rows modified')
        sys.exit(0)
    if not changed:
        selftest(runtime)
        log('Already installed; no changes required')
        sys.exit(0)
    if MODE=='check':
        log('CHECK PASSED: V16 uses an SQL id that does not exist in V5; replacement prepared')
        log('APPLY changes only the V16 JSON helper; SQL, PHP, games and expiry registry untouched')
        sys.exit(0)
    # mode=apply: check the staged code using a separately created temp file.
    BACKUPS.mkdir(parents=True,exist_ok=True)
    bdir=BACKUPS/('admin-delete-v18-'+dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid()))
    bdir.mkdir(mode=0o700)
    backup=bdir/'sql-admin-alias-v14.py.before'
    shutil.copy2(HELPER,backup)
    log('Backup: '+str(bdir))
    st=HELPER.stat()
    fd,tmp=tempfile.mkstemp(prefix='.hh-admin18-',suffix='.py',dir=HELPER.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            f.write(proposed);f.flush();os.fsync(f.fileno())
        os.chmod(tmp,stat.S_IMODE(st.st_mode))
        os.chown(tmp,st.st_uid,st.st_gid)
        module=load_helper(Path(tmp))
        selftest(module)
        # No SQL updates during testing. Check all actual mappings before switching.
        check_runtime()
        os.replace(tmp,HELPER)
        tmp=None
        try:
            module=load_helper(HELPER)
            selftest(module)
            check_runtime()
        except BaseException:
            shutil.copy2(backup,HELPER)
            log('ROLLBACK: original V16 helper restored')
            raise
    finally:
        if tmp and os.path.exists(tmp): os.unlink(tmp)
    log('APPLY SUCCESS: SQL admin deletion now resolves V5 index to unique auth')
    log('No admins deleted by installation; grant, expiry registry, PHP, FTP and game settings unchanged')
except Abort as e:
    print('[HH-ADMIN18-ERROR] '+str(e),file=sys.stderr)
    sys.exit(1)
except subprocess.TimeoutExpired:
    print('[HH-ADMIN18-ERROR] Controller check timed out; no SQL rows changed',file=sys.stderr)
    sys.exit(1)
PY
