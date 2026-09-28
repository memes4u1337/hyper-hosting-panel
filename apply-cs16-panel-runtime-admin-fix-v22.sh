#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
CFGDIR="$CSTRIKE/addons/amxmodx/configs"
PLUGDIR="$CSTRIKE/addons/amxmodx/plugins"
STATE="/var/lib/hyper-cs16/servers/$SID.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-panel-runtime-admin-v22-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"
[[ -d "$CSTRIKE" ]] || fail "missing $CSTRIKE"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -d "$CFGDIR" ]] && cp -a "$CFGDIR" "$BACKUP/amxx-configs.before" || true
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/state.before.json" || true

echo "================================================================"
echo " HYPER-HOST PANEL + SQL ADMINS + SAFE QUICK MAP v22"
echo " Server: #$SID"
echo " FastDL/nginx/site: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"

echo "[1/6] Add SQL admin commands directly to controller..."
python3 - "$CTL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="strict")

if "def sql_admins_list(" not in s:
    anchor="def admin_list(sid:int):"
    pos=s.find(anchor)
    if pos<0:
        raise SystemExit("cannot locate admin_list()")
    block = r"""
def _game_sql_admin_connect(sid:int):
    c=load_server(sid)
    db_name=str(c.get('sql_db') or _server_sql_names(sid)[0])
    db_user=str(c.get('sql_user') or _server_sql_names(sid)[1])
    password=str(c.get('sql_password') or '')
    if not password:
        raise RuntimeError('SQL сервера не настроен. Сначала открой SQL в панели и выполни provisioning.')
    import pymysql
    try:
        con=pymysql.connect(host='127.0.0.1',port=3306,user=db_user,password=password,database=db_name,
            charset='utf8mb4',autocommit=False,cursorclass=pymysql.cursors.DictCursor,connect_timeout=5)
    except Exception as exc:
        raise RuntimeError('Не удалось подключиться к SQL сервера: '+str(exc))
    return c,con,db_name

def _sql_admins_ensure_table(cur):
    cur.execute(
        "CREATE TABLE IF NOT EXISTS `admins` ("
        "`auth` VARCHAR(96) NOT NULL DEFAULT '',"
        "`password` VARCHAR(96) NOT NULL DEFAULT '',"
        "`access` VARCHAR(32) NOT NULL DEFAULT '',"
        "`flags` VARCHAR(32) NOT NULL DEFAULT ''"
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
    )

def _sql_admin_auth_type(auth:str, flags:str=''):
    fl=str(flags or '').lower()
    if 'c' in fl or STEAM_ID_RE.fullmatch(str(auth or '').strip()):
        return 'steamid'
    if 'd' in fl:
        return 'ip'
    try:
        ipaddress.ip_address(str(auth or '').strip())
        return 'ip'
    except Exception:
        return 'name'

def sql_admins_list(sid:int):
    c,con,db_name=_game_sql_admin_connect(sid)
    try:
        with con.cursor() as cur:
            _sql_admins_ensure_table(cur)
            cur.execute("SELECT `auth`,`password`,`access`,`flags` FROM `admins` ORDER BY `auth`")
            raw=cur.fetchall()
        con.commit()
    finally:
        con.close()
    admins=[]
    for i,row in enumerate(raw):
        auth=str(row.get('auth') or '')
        pw=str(row.get('password') or '')
        access=str(row.get('access') or '').lower()
        flags=str(row.get('flags') or '').lower()
        admins.append({
            'index':i,'auth':auth,'identity':auth,'password':pw,'has_password':bool(pw),
            'access':access,'access_flags':access,'flags':flags,'auth_flags':flags,
            'auth_type':_sql_admin_auth_type(auth,flags),
            'access_labels':[AMXX_ACCESS_LABELS.get(x,x) for x in access if x in AMXX_ACCESS_LABELS]
        })
    return {'ok':True,'id':sid,'database':db_name,'table':'admins','admins':admins,'rows':admins,'password_field':'_pw'}

def sql_admins_save(sid:int,payload:dict):
    require_root()
    if not isinstance(payload,dict):
        raise RuntimeError('Некорректные данные администратора')
    auth=str(payload.get('auth') or payload.get('identity') or payload.get('steamid') or payload.get('name') or '').strip()
    auth_type=str(payload.get('auth_type') or '').lower().strip()
    if not auth_type:
        auth_type=_sql_admin_auth_type(auth,str(payload.get('flags') or payload.get('auth_flags') or ''))
    auth=_validate_admin_identity(auth,auth_type)
    access=_normalize_access_flags(str(payload.get('access') or payload.get('access_flags') or ''))
    password=str(payload.get('password') or '')
    generate=bool(payload.get('generate_password',False))
    if generate:
        password=secrets.token_urlsafe(12).replace('-','A').replace('_','B')[:16]
    if any(ch in password for ch in ['"','\r','\n']) or len(password)>96:
        raise RuntimeError('Некорректный пароль администратора')
    supplied=str(payload.get('flags') or payload.get('auth_flags') or '').lower().strip()
    if supplied:
        flags=''.join(dict.fromkeys(x for x in supplied if x.isalpha()))
    elif auth_type=='steamid':
        flags='ca' if password else 'ce'
    elif auth_type=='ip':
        flags='da' if password else 'de'
    else:
        if not password:
            raise RuntimeError('Для авторизации по нику нужен пароль')
        flags='a'
    c,con,db_name=_game_sql_admin_connect(sid)
    try:
        with con.cursor() as cur:
            _sql_admins_ensure_table(cur)
            cur.execute("SELECT `password` FROM `admins` WHERE LOWER(`auth`)=LOWER(%s) LIMIT 1",(auth,))
            old=cur.fetchone()
            if not password and old and bool(payload.get('keep_password',True)):
                password=str(old.get('password') or '')
            cur.execute("DELETE FROM `admins` WHERE LOWER(`auth`)=LOWER(%s)",(auth,))
            cur.execute("INSERT INTO `admins` (`auth`,`password`,`access`,`flags`) VALUES (%s,%s,%s,%s)",
                        (auth,password,access,flags))
        con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()
    reload=_reload_amxx_admins(c)
    return {'ok':True,'id':sid,'database':db_name,'auth':auth,'identity':auth,'auth_type':auth_type,
            'access':access,'access_flags':access,'flags':flags,'auth_flags':flags,'has_password':bool(password),
            'generated_password':password if generate else '',
            'client_command':f'setinfo _pw "{password}"' if password else '','reload':reload}

def sql_admins_delete(sid:int,key=None,payload:dict|None=None):
    require_root()
    payload=payload if isinstance(payload,dict) else {}
    auth=str(payload.get('auth') or payload.get('identity') or payload.get('steamid') or '').strip()
    index=payload.get('index',None)
    if not auth and key not in (None,''):
        k=str(key)
        if k.lstrip('-').isdigit():
            index=int(k)
        else:
            auth=k
    c,con,db_name=_game_sql_admin_connect(sid)
    try:
        with con.cursor() as cur:
            _sql_admins_ensure_table(cur)
            if not auth and index is not None:
                idx=int(index)
                cur.execute("SELECT `auth` FROM `admins` ORDER BY `auth`")
                rows=cur.fetchall()
                if idx<0 or idx>=len(rows):
                    raise RuntimeError('Администратор не найден')
                auth=str(rows[idx].get('auth') or '')
            if not auth:
                raise RuntimeError('Не указан администратор для удаления')
            cur.execute("DELETE FROM `admins` WHERE LOWER(`auth`)=LOWER(%s)",(auth,))
            affected=cur.rowcount
        con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()
    if not affected:
        raise RuntimeError('Администратор не найден')
    reload=_reload_amxx_admins(c)
    return {'ok':True,'id':sid,'database':db_name,'removed':auth,'reload':reload}

"""
    s=s[:pos]+block+s[pos:]

needle="q=sp.add_parser('admin-list'); q.add_argument('id',type=int)"
if "sp.add_parser('sql-admins-list')" not in s:
    repl=(
        "q=sp.add_parser('sql-admins-list'); q.add_argument('id',type=int)\n"
        "    q=sp.add_parser('sql-admins-save'); q.add_argument('id',type=int)\n"
        "    q=sp.add_parser('sql-admins-delete'); q.add_argument('id',type=int); q.add_argument('key',nargs='?')\n"
        "    "+needle
    )
    if needle not in s:
        raise SystemExit("cannot locate admin parser block")
    s=s.replace(needle,repl,1)

dispatch="elif args.cmd=='admin-list': result=admin_list(args.id)"
if "elif args.cmd=='sql-admins-list'" not in s:
    repl=(
        "elif args.cmd=='sql-admins-list': result=sql_admins_list(args.id)\n"
        "        elif args.cmd=='sql-admins-save':\n"
        "            raw=sys.stdin.buffer.read(128*1024+1)\n"
        "            if len(raw)>128*1024: raise RuntimeError('Admin payload is too large')\n"
        "            try: payload=json.loads(raw.decode('utf-8','replace') or '{}')\n"
        "            except Exception: raise RuntimeError('Invalid admin payload')\n"
        "            if not isinstance(payload,dict): raise RuntimeError('Invalid admin payload')\n"
        "            result=sql_admins_save(args.id,payload)\n"
        "        elif args.cmd=='sql-admins-delete':\n"
        "            raw=sys.stdin.buffer.read(128*1024+1)\n"
        "            if len(raw)>128*1024: raise RuntimeError('Admin payload is too large')\n"
        "            payload={}\n"
        "            if raw.strip():\n"
        "                try: payload=json.loads(raw.decode('utf-8','replace'))\n"
        "                except Exception: raise RuntimeError('Invalid admin payload')\n"
        "                if not isinstance(payload,dict): raise RuntimeError('Invalid admin payload')\n"
        "            result=sql_admins_delete(args.id,args.key,payload)\n"
        "        "+dispatch
    )
    if dispatch not in s:
        raise SystemExit("cannot locate admin dispatcher")
    s=s.replace(dispatch,repl,1)

p.write_text(s,encoding="utf-8")
print("SQL admin commands patched")
PY

echo "[2/6] Disable destructive plugin recovery from Quick Map..."
python3 - "$CTL" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="strict")

rx=re.compile(
    r"(?ms)(\s+rollback=old_map if old_map.*?_persist_start_map\(c,rollback\)\n)"
    r"\s+recovery=recover_server\(sid,False\)\n"
    r"\s+raise RuntimeError\(f'Map \{map_name\} could not be started safely\..*?\n"
)
m=rx.search(s)
if m:
    replacement=(
        m.group(1)
        +"    run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)\n"
        +"    run(['systemctl','restart',f'hyper-cs16@{sid}.service'],check=False)\n"
        +"    rb_ok,rb_detail=wait_server_ready(c,25.0)\n"
        +"    raise RuntimeError(f'Map {map_name} could not be started safely. Rolled back to {rollback} WITHOUT changing plugins. Reason: {detail}; rollback_ready={rb_ok}; rollback_detail={rb_detail}')\n"
    )
    s=s[:m.start()]+replacement+s[m.end():]
elif "recovery=recover_server(sid,False)" in s:
    raise SystemExit("found destructive Quick Map recovery but could not patch safely")
else:
    print("Quick Map destructive recovery already absent")

p.write_text(s,encoding="utf-8")
print("Quick Map safe mode patched")
PY

python3 -m py_compile "$CTL"

echo "[3/6] Restore panel-quarantined plugins..."
python3 - "$CFGDIR" "$PLUGDIR" "$BACKUP" <<'PY'
from pathlib import Path
import re,sys,json
cfgdir=Path(sys.argv[1]); plugdir=Path(sys.argv[2]); backup=Path(sys.argv[3])
restored=[]; missing=[]
for f in sorted(cfgdir.glob("plugins*.ini")) if cfgdir.is_dir() else []:
    text=f.read_text(encoding="utf-8",errors="ignore")
    out=[]; changed=False
    for line in text.splitlines():
        m=re.match(r'^\s*;\s*HYPER-HOST QUARANTINE\s*\[[^\]]*\]\s*:\s*([A-Za-z0-9_.-]+\.amxx)\s*$',line,re.I)
        if m:
            name=m.group(1)
            if (plugdir/name).is_file():
                out.append(name); restored.append((f.name,name)); changed=True; continue
            missing.append((f.name,name))
        out.append(line)
    if changed:
        f.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
(backup/"plugin-restore.json").write_text(json.dumps({"restored":restored,"missing":missing},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("restored:",len(restored))
for a,b in restored: print(" ",a,"->",b)
print("missing plugin binaries:",len(missing))
for a,b in missing: print(" MISSING",b)
PY

echo "[4/6] Restore Zombie Plague plugin list if panel disabled it..."
python3 - "$CFGDIR" "$PLUGDIR" "$STATE" <<'PY'
from pathlib import Path
import json,sys
cfg=Path(sys.argv[1]); plug=Path(sys.argv[2]); state=Path(sys.argv[3])
enabled=cfg/"plugins-zplague.ini"; disabled=cfg/"disabled-zplague.ini"
has_zp=(plug/"zombie_plague40.amxx").is_file()
if has_zp and not enabled.exists() and disabled.exists():
    disabled.rename(enabled)
    print("restored disabled-zplague.ini -> plugins-zplague.ini")
if has_zp and not enabled.exists():
    names=[x for x in ("zombie_plague40.amxx","zp_zclasses40.amxx") if (plug/x).is_file()]
    if names:
        enabled.write_text("\n".join(names)+"\n",encoding="utf-8")
        print("created plugins-zplague.ini")
if has_zp and state.exists():
    d=json.loads(state.read_text(encoding="utf-8"))
    if d.get("game_mode")!="zp43":
        d["game_mode"]="zp43"
        tmp=state.with_name("."+state.name+".v22.tmp")
        tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        tmp.replace(state)
        print("game_mode -> zp43")
print("ZP core:",has_zp)
PY

echo "[5/6] Install controller and verify commands..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"
HELP="$("$LIVE" --help 2>&1 || true)"
for cmd in sql-admins-list sql-admins-save sql-admins-delete; do
    echo "$HELP" | grep -q "$cmd" || fail "$cmd missing"
done
echo "SQL admin commands: OK"

echo "[6/6] Restart server + verify..."
systemctl reset-failed "hyper-cs16@${SID}.service" || true
systemctl restart "hyper-cs16@${SID}.service"
sleep 4
"$LIVE" status "$SID" || true
echo "--- meta list ---"
"$LIVE" rcon "$SID" "meta list" || true
echo "--- amxx plugins ---"
"$LIVE" rcon "$SID" "amxx plugins" || true
echo "--- sql admins ---"
"$LIVE" sql-admins-list "$SID"

echo
echo "================================================================"
echo " [SUCCESS] v22"
echo " FastDL/nginx/site were NOT modified."
echo " Backup: $BACKUP"
echo "================================================================"
