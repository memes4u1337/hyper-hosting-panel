#!/usr/bin/env bash
# HYPER-HOST CS1.6: add SQL admin management CLI to the existing V4.1 controller.
# No schema changes, no SQL password rotation, no modification of FTP/FastDL/servers.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
[[ "$MODE" == check || "$MODE" == apply ]] || { echo 'Usage: sudo bash HH_CS16_SQL_ADMINS_V5.sh check|apply' >&2; exit 2; }
[[ "$EUID" -eq 0 ]] || { echo '[SQL-ADMINS] Run under sudo.' >&2; exit 2; }
REPO="${HYPER_REPO_DIR:-/root/hyper-hosting-panel}/cs16-panel/bin/hyper-cs16-ctl"
LIVE=/usr/local/sbin/hyper-cs16-ctl
STATE=/var/lib/hyper-cs16/servers/25.json
[[ -f "$REPO" && -f "$LIVE" && -f "$STATE" ]] || { echo '[SQL-ADMINS] Required controller/state files missing.' >&2; exit 1; }
TMPDIR="$(mktemp -d /tmp/hh-sql-admins-v5.XXXXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
export HH_SQL_ADMIN_TMP="$TMPDIR"

# Preflight exact real database/table structure with actual server-25 game credentials.
# Do not create a DB/table and do not output credentials or player records.
python3 - "$STATE" <<'PY'
import json, pathlib, re, sys
try: import pymysql
except ImportError: raise SystemExit('[SQL-ADMINS] python3-pymysql missing; no files changed')
p=pathlib.Path(sys.argv[1]); s=json.loads(p.read_text(encoding='utf-8'))
if s.get('sql_db')!='cs16_srv_25' or not s.get('sql_user') or not s.get('sql_password'):
    raise SystemExit('[SQL-ADMINS] Server 25 must already use cs16_srv_25; no files changed')
root=pathlib.Path(str(s['path'])).resolve()
config=root/'cstrike/addons/amxmodx/configs/sql.cfg'
table='admins'
if config.is_file():
    for ln in config.read_text(encoding='utf-8',errors='replace').splitlines():
        m=re.match(r'^\s*amx_sql_table\s+"?([A-Za-z0-9_]{1,64})"?',ln,re.I)
        if m: table=m.group(1)
if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',table): raise SystemExit('Invalid amx_sql_table; no files changed')
con=pymysql.connect(host=str(s.get('sql_host') or '127.0.0.1'),port=int(s.get('sql_port') or 3306),user=s['sql_user'],password=s['sql_password'],database=s['sql_db'],connect_timeout=5,charset='utf8mb4')
try:
    with con.cursor() as cur:
        cur.execute('SELECT DATABASE()')
        if cur.fetchone()[0]!='cs16_srv_25': raise SystemExit('Wrong active SQL database')
        cur.execute('SHOW FULL TABLES')
        types={row[0]:row[1] for row in cur.fetchall()}
        if table not in types or types[table]!='BASE TABLE':
            raise SystemExit(f'[SQL-ADMINS] Table {table!r} is absent or is a view. No files changed. Confirm AMXX SQL schema.')
        cur.execute('SHOW COLUMNS FROM `'+table+'`')
        cols={row[0]:row for row in cur.fetchall()}
        missing={'auth','password','access','flags'}-cols.keys()
        if missing: raise SystemExit(f'[SQL-ADMINS] Nonstandard SQL admins table {table}: missing columns {sorted(missing)}; no files changed')
        cur.execute('SELECT COUNT(*) FROM `'+table+'`')
        count=cur.fetchone()[0]
    print(f'[SQL-ADMINS] SQL cs16_srv_25/{table} verified: {count} existing rows (read-only)')
finally: con.close()
plugins=root/'cstrike/addons/amxmodx/configs/plugins.ini'
if plugins.is_file():
    active=[ln.strip().split(';')[0].split('//')[0].strip().lower() for ln in plugins.read_text(encoding='utf-8',errors='replace').splitlines()]
    if not any(x.split(' ')[0]=='admin_sql.amxx' for x in active if x):
        print('[SQL-ADMINS] WARNING: admin_sql.amxx not enabled in server #25 plugins.ini; SQL writes will not grant in-game rights until SQL plugin is active')
PY

cat > "$TMPDIR/sql_admins_impl.py" <<'PY'
# HH_SQL_ADMINS_V5_BEGIN
# SQL admins, unlike legacy admin-list/save, are stored in the EXISTING AMX Mod X SQL table.
def _hh_sql_admins_connect(sid):
    import pymysql
    c=load_server(sid)
    name=str(c.get('sql_db') or '')
    user=str(c.get('sql_user') or '')
    password=str(c.get('sql_password') or '')
    if name!='cs16_srv_25' or not user or not password:
        raise RuntimeError('Server must be attached to shared cs16_srv_25 first')
    root=Path(c['path']).resolve()
    cfg=root/'cstrike/addons/amxmodx/configs/sql.cfg'
    table='admins'
    if cfg.is_file():
        for line in cfg.read_text(encoding='utf-8',errors='replace').splitlines():
            m=re.match(r'^\s*amx_sql_table\s+"?([A-Za-z0-9_]{1,64})"?',line,re.I)
            if m: table=m.group(1)
    if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',table):
        raise RuntimeError('Invalid amx_sql_table in sql.cfg')
    con=pymysql.connect(host=str(c.get('sql_host') or '127.0.0.1'),port=int(c.get('sql_port') or 3306),
                        user=user,password=password,database=name,connect_timeout=7,read_timeout=8,
                        write_timeout=8,charset='utf8mb4',autocommit=False,
                        cursorclass=pymysql.cursors.DictCursor)
    try:
        with con.cursor() as cur:
            cur.execute('SHOW COLUMNS FROM `'+table+'`')
            columns={row['Field'] for row in cur.fetchall()}
        if not {'auth','password','access','flags'}<=columns:
            raise RuntimeError('SQL admins table lacks auth,password,access,flags; refusing unsafe changes')
        return c,con,table
    except Exception:
        con.close()
        raise

def _hh_sql_admins_rows(cur,table):
    cur.execute('SELECT `auth`,`password`,`access`,`flags` FROM `'+table+'` ORDER BY `auth`')
    return cur.fetchall()

def _hh_sql_admins_type(identity,flags):
    flags=(flags or '').lower()
    if 'c' in flags: return 'steamid'
    if 'd' in flags: return 'ip'
    return 'name'

def sql_admins_list(sid):
    c,con,table=_hh_sql_admins_connect(sid)
    try:
        with con.cursor() as cur: rows=_hh_sql_admins_rows(cur,table)
        result=[]
        for i,row in enumerate(rows):
            identity=str(row.get('auth') or '')
            access=str(row.get('access') or '')
            flags=str(row.get('flags') or '')
            has_password=bool(row.get('password'))
            result.append({'index':i,'id':i,'identity':identity,'auth':identity,'access_flags':access,
                           'access':access,'auth_flags':flags,'flags':flags,
                           'auth_type':_hh_sql_admins_type(identity,flags),
                           'has_password':has_password})
        return {'ok':True,'database':'cs16_srv_25','table':table,'count':len(result),'admins':result,'rows':result,'items':result}
    finally: con.close()

def _hh_sql_admins_normalize(payload):
    identity=str(payload.get('identity') or payload.get('auth') or payload.get('steamid') or payload.get('steam_id') or payload.get('nickname') or payload.get('username') or payload.get('name') or '').strip()
    auth_type=str(payload.get('auth_type') or ('steamid' if re.fullmatch(r'(?:STEAM|VALVE)_[0-9]+:[0-9]+:[0-9]+',identity,re.I) else 'name')).lower()
    if not identity or any(c in identity for c in '\r\n\x00"\'\\') or len(identity.encode('utf-8'))>32:
        raise RuntimeError('Invalid AMXX SQL identity (max 32 UTF-8 bytes)')
    if auth_type=='steamid':
        if not re.fullmatch(r'(?:STEAM|VALVE)_[0-9]+:[0-9]+:[0-9]+',identity,re.I):
            raise RuntimeError('Expected STEAM_0:1:123456')
        identity=identity.upper()
    elif auth_type=='ip':
        import ipaddress
        identity=str(ipaddress.ip_address(identity))
    elif auth_type!='name': raise RuntimeError('Invalid auth type')
    access=str(payload.get('access_flags') or payload.get('access') or '').lower()
    if not access or not set(access)<=(set('abcdefghijklmnopqrstu')):
        raise RuntimeError('Invalid AMXX access flags')
    access=''.join(x for x in 'abcdefghijklmnopqrstu' if x in access)
    if len(access)>32: raise RuntimeError('Too many access flags')
    return identity,auth_type,access

def sql_admins_save(sid,payload):
    require_root()
    if not isinstance(payload,dict): raise RuntimeError('Invalid admin JSON object')
    identity,auth_type,access=_hh_sql_admins_normalize(payload)
    password=str(payload.get('password') or '')
    generate=bool(payload.get('generate_password'))
    if generate: password=secrets.token_urlsafe(14)[:24]
    if any(ch in password for ch in '\r\n\x00') or len(password.encode('utf-8'))>32:
        raise RuntimeError('Invalid AMXX password (max 32 UTF-8 bytes)')
    c,con,table=_hh_sql_admins_connect(sid)
    lockname='hhcs16:sql-admin:'+hashlib.sha256(identity.casefold().encode()).hexdigest()[:40]
    locked=False
    try:
        with con.cursor() as cur:
            cur.execute('SELECT GET_LOCK(%s,10) AS locked',(lockname,))
            if (cur.fetchone() or {}).get('locked')!=1: raise RuntimeError('Admin update is busy; retry')
            locked=True
            cur.execute('SELECT `auth`,`password` FROM `'+table+'` WHERE LOWER(`auth`)=LOWER(%s) FOR UPDATE',(identity,))
            matches=cur.fetchall()
            if len(matches)>1: raise RuntimeError('SQL already has duplicate auth entries; fix duplicates before writing')
            if matches:
                old=str(matches[0]['password'] or '')
                if not generate and not password: password=old
            if auth_type=='name' and not password:
                raise RuntimeError('Nickname login requires a password')
            flags=('ca' if password else 'ce') if auth_type=='steamid' else (('da' if password else 'de') if auth_type=='ip' else 'a')
            if matches:
                cur.execute('UPDATE `'+table+'` SET `auth`=%s,`password`=%s,`access`=%s,`flags`=%s WHERE `auth`=%s',
                            (identity,password,access,flags,matches[0]['auth']))
            else:
                cur.execute('INSERT INTO `'+table+'` (`auth`,`password`,`access`,`flags`) VALUES (%s,%s,%s,%s)',
                            (identity,password,access,flags))
        con.commit()
        reload=_reload_amxx_admins(c)
        return {'ok':True,'database':'cs16_srv_25','identity':identity,'auth_type':auth_type,
                'access_flags':access,'auth_flags':flags,'created':not bool(matches),'updated':bool(matches),
                'has_password':bool(password),'generated_password':password if generate else '',
                'client_command':f'setinfo _pw "{password}"' if password and (generate or bool(payload.get('password'))) else '',
                'reload':reload}
    except Exception:
        con.rollback()
        raise
    finally:
        if locked:
            try:
                with con.cursor() as cur: cur.execute('SELECT RELEASE_LOCK(%s)',(lockname,))
            except Exception: pass
        con.close()

def sql_admins_delete(sid,index):
    require_root()
    c,con,table=_hh_sql_admins_connect(sid)
    try:
        if isinstance(index,str) and index.isdecimal(): index=int(index)
        with con.cursor() as cur:
            rows=_hh_sql_admins_rows(cur,table)
            if isinstance(index,int):
                if not 0<=index<len(rows): raise RuntimeError('SQL admin index no longer exists')
                identity=str(rows[index]['auth'])
            else: identity=str(index)
            if not identity: raise RuntimeError('SQL admin identity missing')
            cur.execute('SELECT `auth` FROM `'+table+'` WHERE `auth`=%s FOR UPDATE',(identity,))
            matches=cur.fetchall()
            if len(matches)!=1: raise RuntimeError('SQL admin absent or ambiguous; reload the list')
            cur.execute('DELETE FROM `'+table+'` WHERE `auth`=%s',(identity,))
            if cur.rowcount!=1: raise RuntimeError('Unexpected affected row count; deletion rolled back')
        con.commit()
        return {'ok':True,'removed':identity,'reload':_reload_amxx_admins(c)}
    except Exception:
        con.rollback()
        raise
    finally: con.close()
# HH_SQL_ADMINS_V5_END
PY

python3 - "$REPO" "$LIVE" "$TMPDIR" <<'PY'
from pathlib import Path
import ast,sys
repo,live,work=map(Path,sys.argv[1:])
methods=(work/'sql_admins_impl.py').read_text()
for index,path in enumerate((repo,live)):
    source=path.read_text(encoding='utf-8')
    tree=ast.parse(source)
    funcs={n.name for n in tree.body if isinstance(n,ast.FunctionDef)}
    required={'main','load_server','require_root','_reload_amxx_admins'}
    if required-funcs: raise SystemExit(f'[SQL-ADMINS] {path} missing required functions: {sorted(required-funcs)}; no changes')
    if 'HH_SQL25_SHARED_V4_1' not in source and 'HH_SHARED_SQL_PATCH_2026_11' not in source:
        raise SystemExit(f'[SQL-ADMINS] {path} does not contain shared SQL patch; no changes')
    if 'HH_SQL_ADMINS_V5_BEGIN' in source:
        output=source
    else:
        anchor="    q=sp.add_parser('admin-list'); q.add_argument('id',type=int)"
        dispatch="        elif args.cmd=='admin-list': result=admin_list(args.id)"
        main="def main():"
        for name,needle in [('parser',anchor),('dispatch',dispatch),('main',main)]:
            if source.count(needle)!=1: raise SystemExit(f'[SQL-ADMINS] Controller {path} changed: expected one {name} anchor, found {source.count(needle)}; no changes')
        source=source.replace(main, methods+'\n\n'+main,1)
        source=source.replace(anchor,
            "    q=sp.add_parser('sql-admins-list'); q.add_argument('id',type=int)\n"
            "    q=sp.add_parser('sql-admins-save'); q.add_argument('id',type=int)\n"
            "    q=sp.add_parser('sql-admins-delete'); q.add_argument('id',type=int); q.add_argument('index')\n"+anchor,1)
        source=source.replace(dispatch,
            "        elif args.cmd=='sql-admins-list': result=sql_admins_list(args.id)\n"
            "        elif args.cmd=='sql-admins-save':\n"
            "            raw=sys.stdin.buffer.read(131073)\n"
            "            if len(raw)>131072: raise RuntimeError('SQL admin request is too large')\n"
            "            try: payload=json.loads(raw.decode('utf-8') or '{}')\n"
            "            except Exception: raise RuntimeError('Invalid SQL admin JSON')\n"
            "            result=sql_admins_save(args.id,payload)\n"
            "        elif args.cmd=='sql-admins-delete': result=sql_admins_delete(args.id,args.index)\n"+dispatch,1)
        output=source
    ast.parse(output)
    compile(output,str(path),'exec')
    temp=work/('repo-patched' if index==0 else 'live-patched')
    temp.write_text(output,encoding='utf-8')
    print('[SQL-ADMINS] Prepared',path,'idempotent:',output==(path.read_text()))
print('[SQL-ADMINS] Code AST/compile OK; no files modified yet')
PY

if [[ "$MODE" == check ]]; then
  echo '[SQL-ADMINS] CHECK PASSED: run sudo bash HH_CS16_SQL_ADMINS_V5.sh apply'
  exit 0
fi

BACKUP="/opt/hyper-cs16/backups/sql-admins-v5-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 -p "$BACKUP"
cp -a -- "$REPO" "$BACKUP/repo-controller.py"
cp -a -- "$LIVE" "$BACKUP/live-controller.py"
echo "[SQL-ADMINS] Backups: $BACKUP"
rollback() {
  rc=$?
  trap - ERR
  cp -a -- "$BACKUP/repo-controller.py" "$REPO"
  cp -a -- "$BACKUP/live-controller.py" "$LIVE"
  echo '[SQL-ADMINS] Install failed; both controller files restored.' >&2
  exit "$rc"
}
trap rollback ERR
python3 - "$REPO" "$LIVE" "$TMPDIR" <<'PY'
from pathlib import Path
import os,stat,sys,tempfile
repo,live,work=map(Path,sys.argv[1:])
for target,patched in ((repo,work/'repo-patched'),(live,work/'live-patched')):
    old=target.stat()
    fd,tmp=tempfile.mkstemp(prefix='.'+target.name+'.',dir=target.parent)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(patched.read_bytes());f.flush();os.fsync(f.fileno())
        os.chmod(tmp,stat.S_IMODE(old.st_mode))
        os.chown(tmp,old.st_uid,old.st_gid)
        os.replace(tmp,target)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
PY
python3 -m py_compile "$REPO" "$LIVE"
python3 - "$LIVE" <<'PY'
import json,subprocess,sys
ctl=sys.argv[1]
p=subprocess.run([ctl,'sql-admins-list','25'],capture_output=True,text=True,timeout=25)
try: data=json.loads(p.stdout)
except Exception: raise SystemExit('[SQL-ADMINS] Invalid JSON from installed controller: '+p.stderr[-300:])
if p.returncode or not data.get('ok') or not isinstance(data.get('admins'),list):
    raise SystemExit('[SQL-ADMINS] Live list test failed: '+str(data.get('error') or p.stderr[-300:]))
print('[SQL-ADMINS] SQL list works; rows:',len(data['admins']))
PY
trap - ERR
echo '[SQL-ADMINS] COMPLETE. Existing SQL admin data unchanged.'
