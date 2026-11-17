#!/usr/bin/env bash
# HYPER-HOST CS1.6: use the existing cs16_srv_25 DB on new game instances,
# or export its tables/data to a portable SQL dump. No CREATE/DROP DATABASE.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
SID="${2:-}"
REPO="${HYPER_REPO_DIR:-/root/hyper-hosting-panel}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL=/usr/local/sbin/hyper-cs16-ctl
STATE=/var/lib/hyper-cs16/servers
SHARED=/etc/hyper-cs16/shared-sql.json
BASE_NAME=cs16_srv_25
BACKUPS=/opt/hyper-cs16/backups
export HH_SQL25_STATE="$STATE" HH_SQL25_SHARED="$SHARED" HH_SQL25_DB="$BASE_NAME"

log() { printf '[SQL25] %s\n' "$*"; }
fail() { printf '[SQL25-ERROR] %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: sudo bash HH_CS16_SQL25_DATA_V4.sh check
       sudo bash HH_CS16_SQL25_DATA_V4.sh install
       sudo bash HH_CS16_SQL25_DATA_V4.sh attach NEW_CS16_SERVER_ID
       sudo bash HH_CS16_SQL25_DATA_V4.sh export

install = enforce existing shared SQL for NEW CS 1.6 servers, never create a new DB.
attach  = connect ONE already-created CS1.6 server to cs16_srv_25.
export  = make full .sql.gz containing database schema, data, triggers, routines, events.
The 25 database is NOT cloned or modified; every attached server sees the SAME data.
USAGE
}
[[ $EUID -eq 0 ]] || fail 'Run under sudo/root on the Linux game host.'
case "$MODE" in check|install|attach|export) ;; *) usage; exit 2 ;; esac
if [[ $MODE == attach ]]; then
  [[ $SID =~ ^[0-9]+$ ]] && ((10#$SID > 0)) || fail 'attach requires a numeric CS 1.6 server ID.'
fi
[[ -f "$REPO_CTL" && -f "$LIVE_CTL" ]] || fail 'CS1.6 panel repository/runtime controller missing.'
[[ -d "$STATE" ]] || fail 'CS1.6 state directory is missing.'
command -v python3 >/dev/null || fail 'Python 3 missing'

WORK="$(mktemp -d /tmp/hh-sql25.XXXXXXXX)"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# Pull credentials ONLY from the existing server 25 or existing shared config;
# do not print passwords. Preflight tests all table metadata and actual SQL login.
python3 - "$WORK/source.json" <<'PY'
import os,sys,json,pathlib,re
state=pathlib.Path(os.environ['HH_SQL25_STATE'])
shared=pathlib.Path(os.environ['HH_SQL25_SHARED'])
name=os.environ['HH_SQL25_DB']
server25=state/'25.json'
source=None
if server25.exists():
    c=json.loads(server25.read_text(encoding='utf-8'))
    if c.get('sql_db')==name and c.get('sql_user') and c.get('sql_password'):
        source={'host':c.get('sql_host') or '127.0.0.1','port':int(c.get('sql_port') or 3306),
                'database':name,'user':c['sql_user'],'password':c['sql_password']}
if shared.exists():
    current=json.loads(shared.read_text(encoding='utf-8'))
    if current.get('database')!=name:
        raise SystemExit('Existing shared-sql.json references another database: refusing to override')
    if not all(current.get(k) for k in ('user','password')):
        raise SystemExit('Existing shared-sql.json has incomplete SQL credentials')
    if source and (source['user']!=current['user'] or source['password']!=current['password']):
        raise SystemExit('Credentials differ between server 25 and shared-sql.json. Resolve before changing anything.')
    if not source: source=current
if not source: raise SystemExit('Source database credentials missing in server 25 and shared-sql.json')
if str(source.get('host')) not in ('127.0.0.1','localhost') or int(source.get('port',3306)) != 3306:
    raise SystemExit('Only the local MySQL source 127.0.0.1:3306 is supported')
if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',source['user']): raise SystemExit('Invalid SQL username')
try: import pymysql
except ImportError: raise SystemExit('python3-pymysql is required (apt install python3-pymysql)')
con=pymysql.connect(host='127.0.0.1',port=3306,user=source['user'],password=source['password'],
                    database=name,charset='utf8mb4',connect_timeout=8)
with con.cursor() as cur:
    cur.execute('SHOW FULL TABLES')
    entries=cur.fetchall()
    cur.execute('SELECT DATABASE()')
    if cur.fetchone()[0]!=name: raise SystemExit('MySQL returned a wrong database')
con.close()
if not entries: raise SystemExit('Database exists but has no tables or views; refusing to seed servers from an empty DB')
p=pathlib.Path(sys.argv[1]); p.write_text(json.dumps(source)); p.chmod(0o600)
print('[SQL25] Database cs16_srv_25 is accessible, tables/views:',len(entries),'(no SQL data changed)')
PY

# No changes to service files before passing all checks.
if [[ $MODE == check ]]; then
  python3 - "$REPO_CTL" "$LIVE_CTL" <<'PY'
import ast,sys,pathlib
for path in map(pathlib.Path,sys.argv[1:]):
    source=path.read_text(encoding='utf-8'); t=ast.parse(source)
    fn=next((x for x in t.body if isinstance(x,ast.FunctionDef) and x.name=='sql_provision'),None)
    if fn is None: raise SystemExit('Controller is missing sql_provision: '+str(path))
    body=ast.get_source_segment(source,fn) or ''
    safe=('HH_SHARED_SQL_PATCH_2026_11' in body or 'HH_SQL25_SHARED_V4' in body) and 'CREATE DATABASE' not in body and 'ALTER USER' not in body
    delete=next((x for x in t.body if isinstance(x,ast.FunctionDef) and x.name=='server_delete'),None)
    deletion=ast.get_source_segment(source,delete) if delete else ''
    preserve=bool(deletion) and 'DROP DATABASE' not in deletion and 'DROP USER' not in deletion
    print('[SQL25] Controller',str(path),'shared mode:',safe,'database-delete protected:',preserve)
print('[SQL25] CHECK PASSED; existing SQL verified; no files changed.')
PY
  exit 0
fi

if [[ $MODE == export ]]; then
  DUMP="$(command -v mariadb-dump || command -v mysqldump || true)"
  [[ -n "$DUMP" ]] || fail 'Need mariadb-dump or mysqldump to export the full SQL data.'
  OUTDIR="${HH_SQL25_DUMP_DIR:-/root/hyper-cs16-sql-backups}"
  mkdir -p "$OUTDIR"; chmod 0700 "$OUTDIR"
  OUTPUT="$OUTDIR/cs16_srv_25_$(date +%Y%m%d-%H%M%S)-$$.sql.gz"
  TMPFILE="$OUTPUT.partial"
  # A private defaults file avoids leaking SQL passwords via command line / shell history.
  python3 - "$WORK/source.json" "$WORK/mysql.cnf" <<'PY'
import json,sys,pathlib
src=json.loads(pathlib.Path(sys.argv[1]).read_text())
def quote(x):
    x=str(x)
    if '\n' in x or '\r' in x: raise SystemExit('Invalid credential containing line break')
    return '"'+x.replace('\\','\\\\').replace('"','\\"')+'"'
p=pathlib.Path(sys.argv[2]); p.write_text('[client]\nuser='+quote(src['user'])+'\npassword='+quote(src['password'])+'\nhost=127.0.0.1\nport=3306\n',encoding='utf-8');p.chmod(0o600)
PY
  # Do not allow a partly written dump to masquerade as a successful backup.
  trap 'rm -f -- "$TMPFILE"; cleanup' EXIT
  log 'Exporting ALL tables and rows, views, triggers, stored procedures and events.'
  "$DUMP" --defaults-extra-file="$WORK/mysql.cnf" \
    --single-transaction --quick --skip-lock-tables \
    --routines --events --triggers --hex-blob --default-character-set=utf8mb4 \
    --databases "$BASE_NAME" | gzip -c > "$TMPFILE"
  gzip -t "$TMPFILE"
  [[ -s "$TMPFILE" ]] || fail 'Dump is empty.'
  mv -n "$TMPFILE" "$OUTPUT"
  chmod 0600 "$OUTPUT"
  log "Export complete: $OUTPUT"
  log 'Keep this dump private: it contains the full game database and possibly player records.'
  exit 0
fi

# install modifies only the 2 controller scripts + a global shared SQL config.
# Preserves and verifies the original database and SQL account; no CREATE/GRANT/DROP statements.
if [[ $MODE == install ]]; then
  mkdir -p "$BACKUPS"
  SNAP="$BACKUPS/sql25-v4-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -m 0700 "$SNAP"
  cp -a -- "$REPO_CTL" "$SNAP/repo-controller.py"
  cp -a -- "$LIVE_CTL" "$SNAP/live-controller.py"
  [[ -f "$SHARED" ]] && cp -a -- "$SHARED" "$SNAP/shared-sql.json"
  log "Created controller backup: $SNAP"
  python3 - "$REPO_CTL" "$LIVE_CTL" "$WORK/source.json" "$SHARED" <<'PY'
import ast,os,pathlib,sys,tempfile,json,stat
source_path,live_path,credentials_path,config_path=map(pathlib.Path,sys.argv[1:])
credentials=json.loads(credentials_path.read_text())
new_sql='''def sql_provision(sid:int, rotate:bool=False):
    # HH_SQL25_SHARED_V4 -- share existing cs16_srv_25, including ALL rows and tables.
    require_root()
    if rotate: raise RuntimeError('Shared database password rotation is prohibited')
    c=load_server(sid); root=Path(c['path'])
    if not root.is_dir(): raise RuntimeError(f'Server directory missing: {root}')
    d=json.loads((ETC_ROOT/'shared-sql.json').read_text(encoding='utf-8'))
    host=str(d.get('host') or '127.0.0.1'); port=int(d.get('port') or 3306)
    db_name=str(d.get('database') or ''); db_user=str(d.get('user') or ''); password=str(d.get('password') or '')
    if host not in ('127.0.0.1','localhost') or port!=3306 or db_name!='cs16_srv_25':
        raise RuntimeError('Existing SQL source must be cs16_srv_25 on local MySQL')
    if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',db_user) or not password:
        raise RuntimeError('Invalid shared SQL credentials')
    try:
        import pymysql
        con=pymysql.connect(host='127.0.0.1',port=3306,user=db_user,password=password,database=db_name,connect_timeout=8,charset='utf8mb4')
        with con.cursor() as cur:
            cur.execute('SELECT DATABASE()')
            if cur.fetchone()[0]!=db_name: raise RuntimeError('Database name mismatch')
            cur.execute('SHOW TABLES')
            if not cur.fetchone(): raise RuntimeError('Shared database has no tables')
        con.close()
        path=_write_amxx_sql_cfg(c,db_name,db_user,password)
        c.update(sql_enabled=True,sql_host='127.0.0.1',sql_port=3306,sql_db=db_name,
                 sql_user=db_user,sql_password=password,sql_config_path=path)
        save_server(c); normalize_permissions(root)
        _sql_meta_update(sid,db_name,db_user,path,'ready','')
        return {'ok':True,'id':sid,'database':db_name,'host':'127.0.0.1',
                'port':3306,'user':db_user,'password':password,'config_path':path,'shared_existing_database':True}
    except Exception as exc:
        _sql_meta_update(sid,db_name,db_user,str(root/'cstrike/addons/amxmodx/configs/sql.cfg'),'error',str(exc))
        raise
'''
def function(src,name):
    t=ast.parse(src)
    f=[n for n in t.body if isinstance(n,ast.FunctionDef) and n.name==name]
    if len(f)!=1: raise SystemExit('Expected exactly one top-level function '+name)
    return f[0]
def replace(src,func,replacement):
    lines=src.splitlines(keepends=True)
    return ''.join(lines[:func.lineno-1])+replacement.rstrip()+'\n\n'+''.join(lines[func.end_lineno:])
def patch_script(src):
    # Recognize the function names and never replace unrelated code.
    for required in ('sql_provision','server_delete','_write_amxx_sql_cfg','_sql_meta_update'):
        function(src,required)
    sqlfn=function(src,'sql_provision')
    s=replace(src,sqlfn,new_sql)
    deletefn=function(s,'server_delete')
    deletetext=ast.get_source_segment(s,deletefn) or ''
    if 'DROP DATABASE' in deletetext or 'DROP USER' in deletetext:
        # Remove just the SQL cleanup, not the game-server deletion logic.
        lines=s.splitlines(keepends=True)
        delete_lines=lines[deletefn.lineno-1:deletefn.end_lineno]
        delete_str=''.join(delete_lines)
        start=delete_str.find("    sql_cleanup_warning=''\n")
        ret=delete_str.find('    return {',start)
        if start<0 or ret<0: raise SystemExit('Unexpected SQL deletion code; refusing unsafe install')
        chunk=delete_str[start:ret]
        if 'DROP DATABASE' not in chunk or 'DROP USER' not in chunk:
            raise SystemExit('Unexpected SQL deletion structure; refusing unsafe install')
        delete_str=delete_str[:start]+"    # HH_SQL25_PRESERVE_DELETE_V4: never delete game SQL when deleting a game instance.\n    sql_cleanup_warning=''\n"+delete_str[ret:]
        s=''.join(lines[:deletefn.lineno-1])+delete_str+''.join(lines[deletefn.end_lineno:])
    final=ast.parse(s)
    sqltxt=ast.get_source_segment(s,function(s,'sql_provision')) or ''
    deletetxt=ast.get_source_segment(s,function(s,'server_delete')) or ''
    if 'CREATE DATABASE' in sqltxt or 'ALTER USER' in sqltxt or 'DROP DATABASE' in deletetxt or 'DROP USER' in deletetxt:
        raise SystemExit('Unsafe CREATE/ALTER/DROP SQL remains in game-server lifecycle')
    compile(final,'<patched-controller>','exec')
    return s
prepared={}
for p in (source_path,live_path):
    prepared[p]=patch_script(p.read_text(encoding='utf-8'))
# SQL configuration installed before controllers; atomic file replacement for each.
def write_atomic(p,data,mode):
    p.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix='.sql25-',dir=p.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        if p.exists():
            st=p.stat();os.chown(name,st.st_uid,st.st_gid)
        os.chmod(name,mode);os.replace(name,p)
    finally:
        try: os.unlink(name)
        except FileNotFoundError: pass
if not config_path.exists():
    write_atomic(config_path,json.dumps(credentials,indent=2,ensure_ascii=False)+'\n',0o600)
for p,code in prepared.items():
    mode=stat.S_IMODE(p.stat().st_mode)
    write_atomic(p,code,mode)
print('[SQL25] Controllers patched for all NEW servers. Source database/data untouched.')
print('[SQL25] Shared database protected against deletion with a game server.')
PY
  log 'Install completed. New CS1.6 servers will connect to cs16_srv_25.'
  log 'For an existing new instance use: sudo bash HH_CS16_SQL25_DATA_V4.sh attach SERVER_ID'
  exit 0
fi

if [[ $MODE == attach ]]; then
  [[ "$SID" != 25 ]] || fail 'Server 25 is the source; no need to attach it.'
  [[ -f "$STATE/$SID.json" ]] || fail "Server $SID does not exist in CS1.6 state. Create it in the panel first."
  python3 - "$LIVE_CTL" <<'PY'
import pathlib,ast,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
t=ast.parse(s); f=next((n for n in t.body if isinstance(n,ast.FunctionDef) and n.name=='sql_provision'),None)
b=ast.get_source_segment(s,f) if f else ''
if not b or 'HH_SQL25_SHARED_V4' not in b or any(x in b for x in ('CREATE DATABASE','DROP DATABASE','ALTER USER')):
    raise SystemExit('Controller not installed in safe shared mode; run install first. NO SQL was changed.')
PY
  mkdir -p "$BACKUPS"
  SNAP="$BACKUPS/sql25-attach-$SID-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -m 0700 "$SNAP"
  cp -a -- "$STATE/$SID.json" "$SNAP/server.json"
  CFG="/srv/hyper-cs16/servers/$SID/cstrike/addons/amxmodx/configs/sql.cfg"
  [[ -f "$CFG" ]] && cp -a -- "$CFG" "$SNAP/sql.cfg" || true
  log "Saved server $SID configuration to $SNAP"
  python3 - "$SID" "$LIVE_CTL" "$STATE/$SID.json" <<'PY'
import subprocess,sys,json,pathlib
sid,ctl,state=sys.argv[1:]
proc=subprocess.run([ctl,'sql-provision',sid],capture_output=True,text=True,timeout=90)
if proc.returncode!=0: raise SystemExit('SQL attach failed (no database created): '+(proc.stderr or 'controller exited with error')[-700:])
c=json.loads(pathlib.Path(state).read_text(encoding='utf-8'))
if c.get('sql_db')!='cs16_srv_25': raise SystemExit('Server state does not reference cs16_srv_25 after attach')
print('[SQL25] CS1.6 #'+sid+' connected to cs16_srv_25, with ALL original tables and data.')
print('[SQL25] SQL configuration path:',c.get('sql_config_path','unknown'))
PY
  exit 0
fi
