#!/usr/bin/env bash
# HYPER-HOST / CS 1.6 — repair broken panel controller bridge; retain one shared game SQL.
# Usage: sudo bash HH_CS16_SQL25_PANEL_RECOVERY_V12.sh check|apply|verify
# Does not create/drop/restore MySQL databases, touch YaPB/FTP/FastDL, or restart game services.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) echo 'Usage: sudo bash HH_CS16_SQL25_PANEL_RECOVERY_V12.sh check|apply|verify' >&2; exit 2;; esac
if (( EUID != 0 )); then echo '[HH-V12 ERROR] Run with sudo' >&2; exit 2; fi
python3 - "$MODE" <<'PY'
import ast
import json
import os
import pwd
import grp
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MODE=sys.argv[1]
SRC=Path('/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl')
LIVE=Path('/usr/local/sbin/hyper-cs16-ctl')
PIN=Path('/opt/hyper-cs16/working-controller-v12/hyper-cs16-ctl')
BOT_HELPER=Path('/usr/local/sbin/hh-cs16-bots-enable')
SHARED=Path('/etc/hyper-cs16/shared-sql.json')
STATE=Path('/var/lib/hyper-cs16/servers')
BACKUPS=Path('/opt/hyper-cs16/backups')
EXPECTED_DB='cs16_srv_25'
EXPECTED_USER='cs16_s25'


def say(msg): print('[HH-V12] '+msg,flush=True)
def die(msg): raise RuntimeError(msg)
def readjson(p): return json.loads(p.read_text(encoding='utf-8'))
def regular(p,required=True):
    if p.is_symlink() or (p.exists() and not p.is_file()): die('Unsafe file type: '+str(p))
    if required and (not p.is_file() or not p.stat().st_size): die('File missing/empty: '+str(p))
def call(args,timeout=12):
    try: return subprocess.run([str(a) for a in args],capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired: die('Command timed out: '+str(args[0])+' '+str(args[1] if len(args)>1 else ''))
def check_help(command):
    r=call([*command,'--help'],12)
    if r.returncode!=0 or not all(x in r.stdout for x in ('sql-status','sql-table','server-create','delete','bots-config')):
        die('Full source controller --help failed or missing required commands (stderr: '+r.stderr[-300:].strip()+')')
    return True

def check_source():
    regular(SRC); regular(LIVE); regular(SHARED)
    source=SRC.read_text(encoding='utf-8')
    if not source.startswith('#!') or 'python' not in source.splitlines()[0]:
        die('Local repository controller lacks Python shebang')
    tree=ast.parse(source,filename=str(SRC)); compile(tree,str(SRC),'exec')
    fn={n.name:n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
    required={'main','sql_status','sql_provision','sql_table','server_create','server_delete','load_server','save_server','_write_amxx_sql_cfg','_sql_meta_update'}
    if required-set(fn): die('Local source is incomplete: '+', '.join(sorted(required-set(fn))))
    provision=ast.get_source_segment(source,fn['sql_provision']) or ''
    if not any(s in provision for s in ('HH_SQL25_SHARED_V4_1','HH_SHARED_SQL_PATCH_2026_11')):
        die('Local source has no shared SQL25 patch marker; do not install upstream raw source')
    literals=' '.join(n.value.upper() for n in ast.walk(fn['sql_provision']) if isinstance(n,ast.Constant) and isinstance(n.value,str))
    if any(x in literals for x in ('CREATE DATABASE','DROP DATABASE','ALTER USER','DROP USER','CREATE USER')):
        die('Local sql_provision may create/drop/alter SQL users or databases')
    delete=ast.get_source_segment(source,fn['server_delete']) or ''
    if 'DROP DATABASE' in delete.upper() or 'DROP USER' in delete.upper():
        die('Local source contains unsafe SQL cleanup in server_delete')
    check_help([sys.executable,str(SRC)])
    return source

def sql_verify(source_cfg):
    try: import pymysql
    except ImportError: die('python3-pymysql not installed')
    host=str(source_cfg.get('host') or '127.0.0.1')
    port=int(source_cfg.get('port') or 3306)
    if host not in ('127.0.0.1','localhost') or port!=3306: die('Unexpected source SQL host/port')
    if source_cfg.get('database')!=EXPECTED_DB or source_cfg.get('user')!=EXPECTED_USER or not source_cfg.get('password'):
        die('Shared SQL settings mismatch: expected existing cs16_srv_25 / cs16_s25')
    try:
        conn=pymysql.connect(host='127.0.0.1',port=3306,user=source_cfg['user'],password=source_cfg['password'],database=source_cfg['database'],connect_timeout=6,read_timeout=10,write_timeout=10)
        try:
            with conn.cursor() as cur:
                cur.execute('SELECT DATABASE()'); current=cur.fetchone()[0]
                cur.execute('SHOW FULL TABLES'); count=len(cur.fetchall())
        finally: conn.close()
    except Exception as exc: die('Shared game SQL login failed: '+type(exc).__name__)
    if current!=EXPECTED_DB or count<1: die('Shared source database unavailable or empty')
    return count

def get_states(shared):
    states={}
    for sid in (25,26):
        p=STATE/f'{sid}.json'; regular(p); c=readjson(p)
        root=Path(f'/srv/hyper-cs16/servers/{sid}')
        if not root.is_dir() or root.is_symlink() or Path(str(c.get('path') or '')).resolve()!=root.resolve():
            die(f'Server #{sid} path/state mismatch')
        if sid==25 and (c.get('sql_db'),c.get('sql_user'),c.get('sql_password')) != (EXPECTED_DB,EXPECTED_USER,shared['password']):
            die('Source server #25 SQL credentials differ from verified shared SQL')
        states[sid]=c
    return states

def quote_cfg(v):
    v=str(v)
    if any(x in v for x in ('\r','\n','"','\\')): die('Unsafe SQL config value (won\'t print password)')
    return '"'+v+'"'

def build_sql_cfg(old,shared):
    settings={
       'amx_sql_host':quote_cfg('127.0.0.1'),
       'amx_sql_user':quote_cfg(EXPECTED_USER),
       'amx_sql_pass':quote_cfg(shared['password']),
       'amx_sql_db':quote_cfg(EXPECTED_DB),
       'amx_sql_table':quote_cfg('admins'),
       'amx_sql_type':quote_cfg('mysql')}
    lines=old.splitlines(keepends=True)
    for key,val in settings.items():
        rx=re.compile(r'^\s*'+re.escape(key)+r'(?=\s|$)',re.I)
        matches=[i for i,line in enumerate(lines) if rx.match(line)]
        line=f'{key} {val}\n'
        if matches:
            lines[matches[0]]=line
            for i in matches[1:]: lines[i]='; duplicate disabled by HH-V12: '+lines[i].lstrip()
        else:
            if lines and not lines[-1].endswith('\n'): lines.append('\n')
            lines.append(line)
    return ''.join(lines)

def launcher():
    return '''#!/usr/bin/env python3
# HH-CS16-V12: stable launcher, no chained .real wrappers or Python-as-shell execution.
import os
import sys
SOURCE='/opt/hyper-cs16/working-controller-v12/hyper-cs16-ctl'
BOTS='/usr/local/sbin/hh-cs16-bots-enable'
if len(sys.argv)>1 and sys.argv[1]=='bots-enable' and os.path.isfile(BOTS):
    os.execv(sys.executable,[sys.executable,BOTS]+sys.argv[2:])
os.execv(sys.executable,[sys.executable,SOURCE]+sys.argv[1:])
'''

def atomic(p,data,mode=None):
    p.parent.mkdir(parents=True,exist_ok=True)
    if p.is_symlink() or (p.exists() and not p.is_file()): die('Unsafe write target: '+str(p))
    fd,tmp=tempfile.mkstemp(prefix='.hh-v12-',dir=p.parent)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        if p.exists():
            st=p.stat();os.chown(tmp,st.st_uid,st.st_gid)
            os.chmod(tmp,stat.S_IMODE(st.st_mode) if mode is None else mode)
        else:
            os.chown(tmp,0,0);os.chmod(tmp,0o750 if mode is None else mode)
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def cli_sql(ctl,sid):
    r=call([str(ctl),'sql-status',str(sid)],18)
    if r.returncode:
        die(f'CLI sql-status #{sid} failed (exit={r.returncode}; error='+r.stderr.strip()[-250:]+')')
    try: data=json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError,IndexError): die(f'CLI sql-status #{sid} returned invalid JSON')
    if not data.get('ok') or not data.get('connected') or data.get('database')!=EXPECTED_DB or data.get('user')!=EXPECTED_USER or len(data.get('tables') or [])<1:
        die(f'CLI sql-status #{sid} does not confirm shared connected database')
    return len(data['tables'])

def backup(files):
    BACKUPS.mkdir(parents=True,exist_ok=True)
    name='sql25-panel-v12-'+time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid())
    snap=BACKUPS/name;snap.mkdir(mode=0o700)
    existed={}
    for p in files:
        existed[p]=p.exists()
        if p.exists():
            regular(p)
            dst=snap/str(p).lstrip('/')
            dst.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(p,dst)
    return snap,existed

def rollback(files,snap,existed):
    for p in reversed(files):
        saved=snap/str(p).lstrip('/')
        try:
            if existed.get(p) and saved.is_file():
                shutil.copy2(saved,p)
            elif not existed.get(p) and p.exists():
                p.unlink()
        except Exception as exc:
            say('ROLLBACK ERROR '+str(p)+': '+type(exc).__name__)

def panel_sudo_smoke():
    try: pwd.getpwnam('www-data')
    except KeyError: return 'www-data not found; direct CLI verified'
    if not shutil.which('runuser') or not shutil.which('sudo'):
        return 'sudo/runuser not found; direct CLI verified'
    r=call(['runuser','-u','www-data','--','sudo','-n',str(LIVE),'sql-status','25'],18)
    if r.returncode: die('PHP/www-data sudo SQL test failed: '+r.stderr.strip()[-250:])
    try: d=json.loads(r.stdout.strip().splitlines()[-1])
    except (IndexError,ValueError): die('PHP/www-data SQL test returned invalid JSON')
    if not d.get('connected') or d.get('database')!=EXPECTED_DB: die('PHP/www-data SQL not connected')
    return 'PHP/www-data sudo SQL call verified'

try:
    if MODE=='verify':
        regular(LIVE); regular(PIN)
        if 'HH-CS16-V12' not in LIVE.read_text(encoding='utf-8'):
            die('Stable V12 launcher not installed')
        check_help([str(LIVE)])
        for sid in (25,26):
            n=cli_sql(LIVE,sid)
            say(f'SERVER #{sid}: CONNECTED -> {EXPECTED_DB}, tables={n}')
        say(panel_sudo_smoke())
        say('VERIFY PASSED. Both servers use the same existing SQL database.')
        sys.exit(0)

    check_source()
    shared=readjson(SHARED)
    count=sql_verify(shared)
    states=get_states(shared)
    say(f'Existing {EXPECTED_DB} verified with {count} tables/views; nothing created or dropped')
    for sid in (25,26):
        c=states[sid]
        say(f'SERVER #{sid} current state: {c.get("sql_db", "unset")} / {c.get("sql_user", "unset")}')
    if MODE=='check':
        say('CHECK PASSED: verified local patched controller, shared SQL and both game directories')
        say('APPLY will back up the broken runtime CLI and deploy a stable Python launcher (no nested .real wrappers).')
        sys.exit(0)

    config_files={sid:Path(f'/srv/hyper-cs16/servers/{sid}/cstrike/addons/amxmodx/configs/sql.cfg') for sid in (25,26)}
    for p in config_files.values():
        regular(p,False)
        if not p.parent.is_dir(): die('Missing AMXX config directory: '+str(p.parent))
    files=[LIVE,PIN,STATE/'25.json',STATE/'26.json',*config_files.values()]
    for p in files: regular(p,False)
    snap,existed=backup(files)
    say('Backup: '+str(snap))
    changed=[]
    try:
        # Pin the locally patched V4.1 controller BEFORE changing the live entry point.
        safe_code=SRC.read_bytes()
        atomic(PIN,safe_code,mode=0o700)
        changed.append(PIN)
        check_help([sys.executable,str(PIN)])

        for sid in (25,26):
            p=STATE/f'{sid}.json'
            c=dict(states[sid])
            c.update(sql_enabled=True,sql_host='127.0.0.1',sql_port=3306,
                     sql_db=EXPECTED_DB,sql_user=EXPECTED_USER,sql_password=shared['password'],
                     sql_config_path=str(config_files[sid]))
            updated=(json.dumps(c,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
            if p.read_bytes()!=updated:
                atomic(p,updated)
                changed.append(p)
            cfg=config_files[sid]
            old=cfg.read_text(encoding='utf-8',errors='replace') if cfg.exists() else ''
            new=build_sql_cfg(old,shared)
            if new!=old:
                atomic(cfg,new.encode('utf-8'),mode=None if cfg.exists() else 0o640)
                if not existed[cfg]:
                    try: os.chown(cfg,0,grp.getgrnam('cs16').gr_gid)
                    except KeyError: pass
                changed.append(cfg)

        code=launcher()
        ast.parse(code);compile(code,str(LIVE),'exec')
        # The old runtime controller is retained unchanged in the protected backup.
        atomic(LIVE,code.encode('utf-8'),mode=0o755)
        changed.append(LIVE)
        check_help([str(LIVE)])
        for sid in (25,26):
            n=cli_sql(LIVE,sid)
            say(f'SERVER #{sid}: CONNECTED -> {EXPECTED_DB}, tables={n}')
        say(panel_sudo_smoke())
        say('APPLY SUCCESS: SQL panel now uses stable CLI; 25 and 26 share '+EXPECTED_DB)
        say('No MySQL databases recreated/deleted. No game services restarted; FTP, FastDL and YaPB files untouched.')
        say('Reload the SQL panel page (Ctrl+F5).')
    except Exception:
        rollback(changed,snap,existed)
        say('APPLY failed; modified files restored from backup '+str(snap))
        raise
except Exception as exc:
    print('[HH-V12 ERROR] '+str(exc),file=sys.stderr,flush=True)
    sys.exit(1)
PY
