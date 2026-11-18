#!/usr/bin/env bash
# HYPER-HOST CS1.6 #26: direct SQL25 + existing YaPB setup.
# Does NOT call, replace, or repair hyper-cs16-ctl.
# Usage: sudo bash HH_CS16_26_SQL25_YAPB_DIRECT.sh check|apply|verify
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) echo 'Usage: sudo bash HH_CS16_26_SQL25_YAPB_DIRECT.sh check|apply|verify' >&2; exit 2;; esac
if [[ $EUID -ne 0 ]]; then echo '[HH-26 ERROR] Run through sudo' >&2; exit 2; fi
python3 - "$MODE" <<'PY'
import json, os, re, shutil, socket, stat, subprocess, sys, tempfile, time
from pathlib import Path

MODE=sys.argv[1]
# Test-root override is solely for isolated tests; never changes the production defaults.
PREFIX=Path(os.environ.get('HH_FIX_TEST_ROOT','/'))
def loc(path): return PREFIX / str(path).lstrip('/')
STATE25=loc('/var/lib/hyper-cs16/servers/25.json')
STATE26=loc('/var/lib/hyper-cs16/servers/26.json')
SHARED=loc('/etc/hyper-cs16/shared-sql.json')
RUNTIME=loc('/etc/hyper-cs16/runtime.json')
GAME=loc('/srv/hyper-cs16/servers/26')
CFG=GAME/'cstrike/addons/amxmodx/configs/sql.cfg'
MARKER=GAME/'cstrike/addons/amxmodx/configs/hyper_sql.cfg'
MODULES=GAME/'cstrike/addons/amxmodx/configs/modules.ini'
MM=GAME/'cstrike/addons/metamod/plugins.ini'
BOT=GAME/'cstrike/addons/yapb/conf/yapb.cfg'
LIB=GAME/'cstrike/addons/yapb/bin/yapb.so'
BACKUP=loc('/opt/hyper-cs16/backups')
UNIT='hyper-cs16@26.service'
FILES=(STATE26,CFG,MARKER,MODULES,MM,BOT)

def log(m): print('[HH-26] '+m, flush=True)
def die(m): raise RuntimeError(m)
def readjson(p): return json.loads(p.read_text(encoding='utf-8'))
def text(p): return p.read_text(encoding='utf-8',errors='replace') if p.exists() else ''
def guarded(p,required=False):
    if p.is_symlink() or (p.exists() and not p.is_file()): die('Unexpected symlink/type: '+str(p))
    if required and (not p.is_file() or p.stat().st_size==0): die('Missing file: '+str(p))

def sql_connect(rt, db=None, source=None):
    import pymysql
    if source is None:
        user=rt.get('db_user'); pw=rt.get('db_password'); database=rt.get('db_name')
        host=rt.get('db_host','127.0.0.1'); port=rt.get('db_port',3306)
    else:
        user=source['user'];pw=source['password'];database=source['database'];host='127.0.0.1';port=3306
    if db is not None: database=db
    if not (user and database and pw is not None): die('Panel SQL configuration incomplete')
    return pymysql.connect(host=host,port=int(port),user=user,password=pw,database=database,
                           charset='utf8mb4',connect_timeout=8,read_timeout=10,write_timeout=10,
                           autocommit=False)

def prepare():
    for p in (STATE25,STATE26,SHARED,RUNTIME,MM,BOT,LIB): guarded(p,True)
    for p in FILES: guarded(p)
    if not GAME.is_dir() or GAME.is_symlink(): die('Game directory not found: '+str(GAME))
    a,b,c,rt=map(readjson,(STATE25,STATE26,SHARED,RUNTIME))
    if a.get('sql_db')!='cs16_srv_25' or c.get('database')!='cs16_srv_25': die('SQL #25 is not cs16_srv_25')
    if c.get('user')!='cs16_s25': die('Unexpected SQL source user')
    if not c.get('password') or (a.get('sql_user'),a.get('sql_password')) != (c['user'],c['password']):
        die('Source credentials missing or different between #25 and shared config')
    if (c.get('host') or '127.0.0.1') not in ('localhost','127.0.0.1') or int(c.get('port') or 3306)!=3306:
        die('Unexpected source SQL host/port')
    expected=Path('/srv/hyper-cs16/servers/26')
    if Path(str(b.get('path') or '')).resolve()!= (GAME.resolve() if PREFIX!=Path('/') else expected.resolve()):
        # In a local fixture b.path is the logical absolute server path.
        if not (PREFIX!=Path('/') and b.get('path')==str(expected)):
            die('Server #26 state path does not match its game directory')
    try:
        import pymysql  # noqa
    except ImportError: die('Missing python3-pymysql (install the package before running APPLY)')
    conn=sql_connect(rt,source=c)
    try:
        with conn.cursor() as cur:
            cur.execute('SHOW FULL TABLES')
            count=len(cur.fetchall())
            cur.execute('SELECT DATABASE()')
            db=cur.fetchone()[0]
        if db!='cs16_srv_25' or count<1: die('Source SQL is empty or wrong database')
    finally: conn.close()
    # Verify panel database schema before any file changes.
    panel=sql_connect(rt)
    try:
        with panel.cursor() as cur:
            cur.execute('SHOW COLUMNS FROM server_sql_connections')
            cols={x[0] for x in cur.fetchall()}
            req={'server_id','db_host','db_port','db_name','db_user','config_path','status','last_error','last_check_at'}
            if not req.issubset(cols): die('Unexpected server_sql_connections schema')
            cur.execute('SHOW COLUMNS FROM servers')
            cols={x[0] for x in cur.fetchall()}
            if not {'id','bots_enabled','bots_quota','bots_difficulty'}.issubset(cols): die('Unexpected servers table schema')
            cur.execute('SELECT COUNT(*) FROM servers WHERE id=%s',(26,))
            if cur.fetchone()[0]!=1: die('Panel server #26 entry missing')
    finally: panel.close()
    if not (LIB.is_file() and BOT.is_file()): die('Installed YaPB is incomplete')
    if not MM.is_file(): die('Metamod plugins.ini missing')
    if PREFIX==Path('/') and MODE in ('check','apply'):
        unit=subprocess.run(['systemctl','show','-p','ExecStart',UNIT],capture_output=True,text=True,timeout=12)
        if unit.returncode: die('Cannot inspect systemd service #26')
        if re.search(r'(?<![\w.-])hyper-cs16-ctl(?:\.real)?(?![\w.-])',unit.stdout):
            die('Game service ExecStart calls the broken hyper-cs16-ctl; refusing unsafe restart')
    return a,b,c,rt,count

def cvars(original, pairs):
    lines=original.splitlines(keepends=True)
    for key,value in pairs.items():
        rex=re.compile(r'^\s*'+re.escape(key)+r'(?=\s|$)',re.I)
        matches=[i for i,line in enumerate(lines) if rex.match(line)]
        entry=f'{key} {value}\n'
        if matches:
            lines[matches[0]]=entry
            for idx in matches[1:]: lines[idx]='; duplicate disabled by HH-26: '+lines[idx].lstrip()
        else:
            if lines and not lines[-1].endswith('\n'): lines.append('\n')
            lines.append(entry)
    return ''.join(lines)

def new_contents(b,c):
    for field in ('user','password','database'):
        if ('\n' in str(c[field]) or '\r' in str(c[field]) or '"' in str(c[field])
                or '\\' in str(c[field])): die('Unsafe character in source SQL credentials')
    state=dict(b)
    state.update(sql_enabled=True,sql_host='127.0.0.1',sql_port=3306,sql_db='cs16_srv_25',
                 sql_user='cs16_s25',sql_password=c['password'],sql_config_path=str(Path('/srv/hyper-cs16/servers/26/cstrike/addons/amxmodx/configs/sql.cfg')),
                 bots_enabled=1,bots_quota=10,bots_difficulty=3)
    sqlcfg=cvars(text(CFG),{
        'amx_sql_host':'"127.0.0.1"','amx_sql_user':'"cs16_s25"',
        'amx_sql_pass':'"'+c['password']+'"','amx_sql_db':'"cs16_srv_25"',
        'amx_sql_table':'"admins"','amx_sql_type':'"mysql"'})
    marker='; HYPER-HOST shared SQL connection (CS1.6 #26)\n; Database: cs16_srv_25\n; User: cs16_s25\n; Host: 127.0.0.1:3306\n'
    modules=text(MODULES)
    if not any(re.fullmatch(r'\s*mysql(?:_amxx_i386\.so)?\s*',line,re.I)
               for line in modules.splitlines() if not line.lstrip().startswith((';','//','#'))):
        modules=modules.rstrip('\n')+'\nmysql\n'
    # Remove only repeated YaPB entries; leave every other Metamod plugin untouched.
    mm_lines=[]; found=False
    for line in text(MM).splitlines():
        if re.search(r'addons[/\\]yapb[/\\]bin[/\\]yapb\.so',line,re.I):
            if not found:
                mm_lines.append('linux addons/yapb/bin/yapb.so');found=True
            else:
                mm_lines.append('; '+line.lstrip('; ').strip())
        else: mm_lines.append(line)
    if not found: mm_lines.append('linux addons/yapb/bin/yapb.so')
    mm='\n'.join(mm_lines).rstrip()+'\n'
    bot=cvars(text(BOT),{'yb_quota':'10','yb_quota_mode':'fill','yb_difficulty':'3',
                         'yb_join_after_player':'0','yb_autovacate':'1'})
    return {STATE26:json.dumps(state,ensure_ascii=False,indent=2)+'\n',CFG:sqlcfg,
            MARKER:marker,MODULES:modules,MM:mm,BOT:bot}

def atomic_write(p, value):
    p.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=p.parent,prefix='.hh26-')
    try:
        with os.fdopen(fd,'w',encoding='utf-8',newline='\n') as f:
            f.write(value);f.flush();os.fsync(f.fileno())
        if p.exists():
            st=p.stat();os.chown(tmp,st.st_uid,st.st_gid);os.chmod(tmp,stat.S_IMODE(st.st_mode))
        else:
            owner=CFG.parent.stat() if p in (CFG,MARKER) else p.parent.stat()
            os.chown(tmp,owner.st_uid,owner.st_gid)
            os.chmod(tmp,0o640 if p==MARKER else 0o644)
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def snapshot():
    BACKUP.mkdir(parents=True,exist_ok=True)
    folder=BACKUP/('direct-sql25-yapb26-'+time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid()))
    folder.mkdir(mode=0o700)
    originals={}
    for p in FILES:
        originals[p]=(p.exists(),p.read_bytes() if p.exists() else b'')
        if p.exists():
            dest=folder/p.relative_to(PREFIX)
            dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(p,dest)
    return folder,originals

def update_panel(rt, rollback=False, previous=None):
    con=sql_connect(rt)
    try:
        with con.cursor() as cur:
            if rollback:
                oldconn,oldbots=previous
                if oldconn is None:
                    cur.execute('DELETE FROM server_sql_connections WHERE server_id=%s',(26,))
                else:
                    cur.execute('UPDATE server_sql_connections SET db_host=%s,db_port=%s,db_name=%s,db_user=%s,config_path=%s,status=%s,last_error=%s,last_check_at=%s WHERE server_id=%s',tuple(oldconn)+(26,))
                cur.execute('UPDATE servers SET bots_enabled=%s,bots_quota=%s,bots_difficulty=%s WHERE id=%s',tuple(oldbots)+(26,))
            else:
                cur.execute('SELECT db_host,db_port,db_name,db_user,config_path,status,last_error,last_check_at FROM server_sql_connections WHERE server_id=%s',(26,))
                oldconn=cur.fetchone()
                cur.execute('SELECT bots_enabled,bots_quota,bots_difficulty FROM servers WHERE id=%s',(26,))
                oldbots=cur.fetchone()
                cur.execute('INSERT INTO server_sql_connections(server_id,db_host,db_port,db_name,db_user,config_path,status,last_error,last_check_at) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,NOW()) ON DUPLICATE KEY UPDATE db_host=VALUES(db_host),db_port=VALUES(db_port),db_name=VALUES(db_name),db_user=VALUES(db_user),config_path=VALUES(config_path),status=VALUES(status),last_error=VALUES(last_error),last_check_at=NOW()',
                        (26,'127.0.0.1',3306,'cs16_srv_25','cs16_s25','/srv/hyper-cs16/servers/26/cstrike/addons/amxmodx/configs/sql.cfg','ready',''))
                cur.execute('UPDATE servers SET bots_enabled=%s,bots_quota=%s,bots_difficulty=%s WHERE id=%s',(1,10,3,26))
        con.commit()
        if not rollback: return (oldconn,oldbots)
    except Exception:
        con.rollback();raise
    finally: con.close()

def systemctl(*args,timeout=90):
    if PREFIX!=Path('/'):
        if args and args[0]=='restart' and os.environ.get('HH_FIX_TEST_FAIL_RESTART')=='1':
            return subprocess.CompletedProcess(args,1,stdout='',stderr='synthetic test failure')
        return subprocess.CompletedProcess(args,0,stdout='active\n',stderr='')
    return subprocess.run(['systemctl',*args],capture_output=True,text=True,timeout=timeout)

def query_a2s_bots(port):
    # Optional real-time measurement. No failure if the game is still loading,
    # if A2S is filtered, or if the server uses a nonstandard protocol.
    if PREFIX!=Path('/'):
        return None
    if not (1<=int(port)<=65535): return None
    packet=b'\xff\xff\xff\xffTSource Engine Query\x00'
    try:
        sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        sock.settimeout(1.8)
        with sock:
            sock.sendto(packet,('127.0.0.1',int(port)))
            data,_=sock.recvfrom(4096)
            if data.startswith(b'\xff\xff\xff\xffA') and len(data)>=9:
                sock.sendto(packet+data[5:9],('127.0.0.1',int(port)))
                data,_=sock.recvfrom(4096)
        if not data.startswith(b'\xff\xff\xff\xffI'): return None
        pos=6  # header + response-type + protocol byte
        for _ in range(4):
            pos=data.index(b'\x00',pos)+1
        # app ID uint16, players uint8, maxplayers uint8, bots uint8
        if pos+5>len(data): return None
        return data[pos+4]
    except (OSError,ValueError,IndexError,socket.timeout): return None

def main():
    a,b,c,rt,count=prepare()
    contents=new_contents(b,c)
    log(f'Source database cs16_srv_25 verified: {count} tables/views')
    log('Target #26: '+str(b.get('sql_db') or '(not set)')+' -> cs16_srv_25')
    log('Installed YaPB found; quota=10, difficulty=3, join_after_player=0')
    if MODE=='check':
        log('CHECK PASSED; nothing changed. No controller/wrapper will be touched.')
        return
    if MODE=='verify':
        state=readjson(STATE26)
        if state.get('sql_db')!='cs16_srv_25' or state.get('sql_user')!='cs16_s25': die('Server #26 state is not shared SQL')
        if 'amx_sql_db "cs16_srv_25"' not in text(CFG): die('AMXX sql.cfg has wrong database')
        if not re.search(r'(?im)^\s*linux\s+addons/yapb/bin/yapb\.so\s*$',text(MM)): die('YaPB not enabled in Metamod')
        if not re.search(r'(?m)^yb_quota\s+10\s*$',text(BOT)): die('YaPB quota is not 10')
        panel=sql_connect(rt)
        try:
            with panel.cursor() as cur:
                cur.execute('SELECT db_name,status FROM server_sql_connections WHERE server_id=%s',(26,))
                sqlrow=cur.fetchone()
                cur.execute('SELECT bots_enabled,bots_quota,bots_difficulty FROM servers WHERE id=%s',(26,))
                botsrow=cur.fetchone()
            if sqlrow!=('cs16_srv_25','ready') or tuple(map(int,botsrow or ()))!=(1,10,3):
                die('Panel SQL/bots metadata does not match game server #26')
        finally: panel.close()
        unit=systemctl('is-active',UNIT,timeout=15)
        if unit.returncode: die('CS1.6 service #26 not active')
        observed=query_a2s_bots(state.get('port') or b.get('port') or 0)
        log('VERIFY PASSED: SQL state/config + YaPB files + game service active.')
        log('A2S bot count: '+(str(observed) if observed is not None else 'not available; check game console'))
        return
    snap,originals=snapshot()
    log('Backup: '+str(snap))
    written=[]; previous=None; updated=False
    try:
        for p,data in contents.items():
            if text(p)!=data:
                atomic_write(p,data)
                written.append(p)
        # Verify the database state and config before modifying panel metadata.
        state=readjson(STATE26)
        if (state.get('sql_db'),state.get('sql_user'))!=('cs16_srv_25','cs16_s25'):
            die('SQL state did not persist')
        previous=update_panel(rt);updated=True
        # Restart once only, so YaPB loads from plugins.ini and new AMXX SQL config.
        action=systemctl('restart',UNIT,timeout=100)
        if action.returncode: die('Game restart failed: '+action.stderr[-700:])
        active=systemctl('is-active',UNIT,timeout=15)
        if active.returncode: die('Game service #26 is not active after restart')
        log('SUCCESS: #26 -> cs16_srv_25; panel metadata updated; YaPB enabled; service active.')
        log('No game database created/copied/deleted. No hyper-cs16-ctl files changed.')
        observed=query_a2s_bots(state.get('port') or 0)
        log('A2S bot count: '+(str(observed) if observed is not None else 'not available; check game console'))
    except Exception as exc:
        log('ERROR: '+str(exc))
        # Restore every modified file, preserving original ownership/mode from backup.
        for p in written:
            saved=snap/p.relative_to(PREFIX)
            if saved.is_file(): shutil.copy2(saved,p)
            elif p.exists(): p.unlink()
        if updated:
            try: update_panel(rt,rollback=True,previous=previous)
            except Exception as e: log('WARNING: panel metadata rollback failed: '+str(e))
        if PREFIX==Path('/'):
            try: systemctl('restart',UNIT,timeout=100)
            except Exception: pass
        die('Restored changed files from '+str(snap)+'; cause: '+str(exc))

try: main()
except Exception as exc:
    print('[HH-26 ERROR] '+str(exc),file=sys.stderr,flush=True)
    sys.exit(1)
PY
