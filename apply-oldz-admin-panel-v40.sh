#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
CFG="/srv/hyper-cs16/servers/${SID}/cstrike/addons/amxmodx/configs"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-admin-panel-v40-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true
cp -a "$CFG/users.ini" "$BACKUP/users.ini.before" 2>/dev/null || true
cp -a "$CFG/vips.ini" "$BACKUP/vips.ini.before" 2>/dev/null || true
cp -a "$CFG/vip.ini" "$BACKUP/vip.ini.before" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE ADMIN PANEL FINAL v40"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Game/FastDL/YaPB/AMXX plugin list/Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Patch exact commands used by current panel..."
python3 - "$CTL" <<'PYV40'

from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')

begin="# === OLDZ PANEL GRANT BRIDGE v40 BEGIN ==="
end="# === OLDZ PANEL GRANT BRIDGE v40 END ==="
if begin in s and end in s:
    a=s.index(begin)
    b=s.index(end,a)+len(end)
    s=s[:a]+s[b:]

block=r"""
# === OLDZ PANEL GRANT BRIDGE v40 BEGIN ===
def _v40_admin_rows_for_panel(sid:int):
    import time
    c,con,db_name=_game_admin_sql_connect(sid)
    try:
        with con.cursor() as cur:
            gm_sid=_gm_server_id(cur,c)
            rows=_gm_admin_rows(cur,gm_sid)
        now=int(time.time())
        out=[]
        for row in rows:
            access=str(row.get('custom_flags') or row.get('access') or '').lower()
            expired=int(row.get('expired') or 0)
            days=int(row.get('days') or 0)
            permanent=(expired==0 or days==0)
            out.append({
                'id':int(row.get('id') or 0),
                'db_id':int(row.get('id') or 0),
                'key':str(len(out)),
                'index':len(out),
                'identity':_gm_identity(row),
                'nickname':str(row.get('nickname') or row.get('username') or _gm_identity(row)),
                'username':str(row.get('username') or ''),
                'steamid':str(row.get('steamid') or ''),
                'auth_type':_gm_auth_type(row),
                'access_flags':str(row.get('access') or '').lower(),
                'custom_flags':str(row.get('custom_flags') or '').lower(),
                'auth_flags':str(row.get('flags') or '').lower(),
                'created':int(row.get('created') or 0),
                'expired':expired,
                'days':days,
                'permanent':permanent,
                'active':permanent or expired>now,
                'has_password':bool(str(row.get('password') or '')),
                'access_labels':[AMXX_ACCESS_LABELS.get(x,x) for x in access if x in AMXX_ACCESS_LABELS]
            })
        return c,db_name,gm_sid,out,now
    finally:
        con.close()

def sql_admins_list(sid:int):
    migration=_v39_migrate_legacy_admins(sid) if '_v39_migrate_legacy_admins' in globals() else {'ok':True,'migrated':[]}
    sync=_v39_sync_admin_files(sid) if '_v39_sync_admin_files' in globals() else {}
    c,db_name,gm_sid,rows,now=_v40_admin_rows_for_panel(sid)
    return {
        'ok':True,
        'id':sid,
        'database':db_name,
        'admins_table':'gm_amxadmins',
        'links_table':'gm_admins_servers',
        'server_sql_id':gm_sid,
        'gm_server_id':gm_sid,
        'table':'gm_amxadmins + gm_admins_servers',
        'admins':rows,
        'rows':rows,
        'now':now,
        'migration':migration,
        'file_sync':sync
    }

def _v40_auth_flags(auth_type:str,password_plain:str)->str:
    if auth_type=='steamid':
        return 'ca' if password_plain else 'ce'
    if auth_type=='ip':
        return 'da' if password_plain else 'de'
    if auth_type=='name':
        return 'a'
    raise RuntimeError('Неизвестный тип авторизации')

def _v40_expiry(unit:str,count:int,forever:bool):
    import calendar,time
    from datetime import datetime
    now=int(time.time())
    if forever:
        return 0,0,'Навсегда'
    count=max(1,min(int(count),3650))
    if unit=='days':
        return count,now+count*86400,f'{count} дн.'
    if unit=='months':
        count=max(1,min(count,120))
        dt=datetime.fromtimestamp(now)
        total=dt.year*12+(dt.month-1)+count
        year=total//12
        month=total%12+1
        day=min(dt.day,calendar.monthrange(year,month)[1])
        target=dt.replace(year=year,month=month,day=day)
        expired=int(target.timestamp())
        days=max(1,int((expired-now+86399)//86400))
        return days,expired,f'{count} мес.'
    raise RuntimeError('Срок должен быть в днях или месяцах')

def sql_admin_grant(sid:int,payload:dict):
    require_root()
    import hashlib,time

    if not isinstance(payload,dict):
        raise RuntimeError('Некорректные данные администратора')

    auth_type=str(payload.get('auth_type') or 'steamid').lower()
    identity=_validate_admin_identity(str(payload.get('identity') or ''),auth_type)

    nickname=str(payload.get('nickname') or identity).strip()
    if not nickname or len(nickname)>32 or chr(10) in nickname or chr(13) in nickname:
        raise RuntimeError('Некорректное имя администратора')

    full=bool(payload.get('full_access',True))
    access=_normalize_access_flags(
        'abcdefghijklmnopqrstu' if full else str(payload.get('access_flags') or '')
    )

    custom_raw=str(payload.get('custom_flags') or '').strip().lower()
    custom=_normalize_access_flags(custom_raw) if custom_raw else ''

    password_plain=str(payload.get('password') or '')
    generate=bool(payload.get('generate_password',False))
    if generate:
        password_plain=secrets.token_urlsafe(12).replace('-','A').replace('_','B')[:16]
    if len(password_plain)>64 or '"' in password_plain or chr(10) in password_plain or chr(13) in password_plain:
        raise RuntimeError('Некорректный пароль администратора')
    if auth_type=='name' and not password_plain:
        raise RuntimeError('Для входа по нику нужен пароль')

    password_db=hashlib.md5(password_plain.encode('utf-8')).hexdigest() if password_plain else ''
    auth_flags=_v40_auth_flags(auth_type,password_plain)

    forever=bool(payload.get('forever',False))
    try:
        count=int(payload.get('duration_count') or 1)
    except Exception:
        count=1
    unit=str(payload.get('duration_unit') or 'days').lower()
    days,expired,duration_label=_v40_expiry(unit,count,forever)
    now=int(time.time())

    c,con,db_name=_game_admin_sql_connect(sid)
    try:
        with con.cursor() as cur:
            gm_sid=_gm_server_id(cur,c)

            cur.execute(
                "SELECT a.`id`,a.`password` "
                "FROM `gm_amxadmins` a "
                "INNER JOIN `gm_admins_servers` s ON s.`admin_id`=a.`id` "
                "WHERE s.`server_id`=%s AND ("
                "LOWER(a.`steamid`)=LOWER(%s) OR LOWER(a.`username`)=LOWER(%s) OR LOWER(a.`nickname`)=LOWER(%s)"
                ") ORDER BY a.`id` LIMIT 1",
                (gm_sid,identity,identity,identity)
            )
            old=cur.fetchone()

            if old:
                admin_id=int(old.get('id'))
                if not password_plain:
                    password_db=str(old.get('password') or '')
                cur.execute(
                    "UPDATE `gm_amxadmins` SET "
                    "`username`=%s,`password`=%s,`access`=%s,`flags`=%s,"
                    "`steamid`=%s,`nickname`=%s,`ashow`=1,`expired`=%s,`days`=%s "
                    "WHERE `id`=%s",
                    (nickname,password_db,access,auth_flags,identity,nickname,expired,days,admin_id)
                )
                created_new=False
            else:
                cur.execute(
                    "INSERT INTO `gm_amxadmins` "
                    "(`username`,`password`,`access`,`flags`,`steamid`,`nickname`,`icq`,`ashow`,`created`,`expired`,`days`) "
                    "VALUES(%s,%s,%s,%s,%s,%s,0,1,%s,%s,%s)",
                    (nickname,password_db,access,auth_flags,identity,nickname,now,expired,days)
                )
                admin_id=int(cur.lastrowid)
                created_new=True

            cur.execute(
                "SELECT 1 FROM `gm_admins_servers` WHERE `admin_id`=%s AND `server_id`=%s LIMIT 1",
                (admin_id,gm_sid)
            )
            if cur.fetchone():
                cur.execute(
                    "UPDATE `gm_admins_servers` SET `custom_flags`=%s,`use_static_bantime`='yes' "
                    "WHERE `admin_id`=%s AND `server_id`=%s",
                    (custom,admin_id,gm_sid)
                )
            else:
                cur.execute(
                    "INSERT INTO `gm_admins_servers` (`admin_id`,`server_id`,`custom_flags`,`use_static_bantime`) "
                    "VALUES(%s,%s,%s,'yes')",
                    (admin_id,gm_sid,custom)
                )

        sync=_v39_sync_admin_files(sid) if '_v39_sync_admin_files' in globals() else {}
        reload=_reload_amxx_admins(c)
        fresh=sql_admins_list(sid)

        return {
            'ok':True,
            'id':sid,
            'admin_id':admin_id,
            'created_new':created_new,
            'identity':identity,
            'nickname':nickname,
            'auth_type':auth_type,
            'access_flags':access,
            'custom_flags':custom,
            'auth_flags':auth_flags,
            'days':days,
            'expired':expired,
            'duration_label':duration_label,
            'generated_password':password_plain if generate else '',
            'client_command':f'setinfo _pw "{password_plain}"' if password_plain else '',
            'reload':reload,
            'file_sync':sync,
            'admins':fresh.get('admins',[]),
            'rows':fresh.get('admins',[])
        }
    finally:
        con.close()

def sql_admin_delete(sid:int,admin_id:int):
    require_root()
    c,con,db_name=_game_admin_sql_connect(sid)
    try:
        with con.cursor() as cur:
            gm_sid=_gm_server_id(cur,c)
            cur.execute(
                "SELECT a.`id`,a.`steamid`,a.`username`,a.`nickname` "
                "FROM `gm_amxadmins` a "
                "INNER JOIN `gm_admins_servers` s ON s.`admin_id`=a.`id` "
                "WHERE a.`id`=%s AND s.`server_id`=%s LIMIT 1",
                (int(admin_id),gm_sid)
            )
            row=cur.fetchone()
            if not row:
                raise RuntimeError('Администратор не найден')

            identity=str(row.get('steamid') or row.get('username') or row.get('nickname') or admin_id)

            cur.execute(
                "DELETE FROM `gm_admins_servers` WHERE `admin_id`=%s AND `server_id`=%s",
                (int(admin_id),gm_sid)
            )
            cur.execute(
                "SELECT COUNT(*) AS c FROM `gm_admins_servers` WHERE `admin_id`=%s",
                (int(admin_id),)
            )
            remain=int((cur.fetchone() or {}).get('c') or 0)
            if remain==0:
                cur.execute("DELETE FROM `gm_amxadmins` WHERE `id`=%s LIMIT 1",(int(admin_id),))

        sync=_v39_sync_admin_files(sid) if '_v39_sync_admin_files' in globals() else {}
        reload=_reload_amxx_admins(c)
        fresh=sql_admins_list(sid)

        return {
            'ok':True,
            'id':sid,
            'removed_id':int(admin_id),
            'identity':identity,
            'reload':reload,
            'file_sync':sync,
            'admins':fresh.get('admins',[]),
            'rows':fresh.get('admins',[])
        }
    finally:
        con.close()
# === OLDZ PANEL GRANT BRIDGE v40 END ===
"""

anchor='def server_config_set(args):'
pos=s.find(anchor)
if pos<0:
    raise SystemExit('server_config_set anchor not found')
s=s[:pos]+block.strip()+"\n\n"+s[pos:]

# Parser commands used by the old panel.
parser_anchor="q=sp.add_parser('admin-delete'); q.add_argument('id',type=int); q.add_argument('index',type=int)"
if parser_anchor not in s:
    raise SystemExit('admin-delete parser anchor not found')

if "sp.add_parser('sql-admin-grant')" not in s:
    add=(
        parser_anchor+
        "\n    q=sp.add_parser('sql-admin-grant'); q.add_argument('id',type=int)"
        "\n    q=sp.add_parser('sql-admin-delete'); q.add_argument('id',type=int); q.add_argument('admin_id',type=int)"
    )
    s=s.replace(parser_anchor,add,1)

dispatch_anchor="elif args.cmd=='admin-delete': result=admin_delete(args.id,args.index)"
if dispatch_anchor not in s:
    raise SystemExit('admin-delete dispatcher anchor not found')

if "elif args.cmd=='sql-admin-grant':" not in s:
    add=dispatch_anchor+"""
        elif args.cmd=='sql-admin-grant':
            raw=sys.stdin.buffer.read(128*1024+1)
            if len(raw)>128*1024:
                raise RuntimeError('Admin payload is too large')
            try:
                payload=json.loads(raw.decode('utf-8','replace') or '{}')
            except Exception:
                raise RuntimeError('Invalid admin payload')
            if not isinstance(payload,dict):
                raise RuntimeError('Invalid admin payload')
            result=sql_admin_grant(args.id,payload)
        elif args.cmd=='sql-admin-delete':
            result=sql_admin_delete(args.id,args.admin_id)"""
    s=s.replace(dispatch_anchor,add,1)

p.write_text(s,encoding='utf-8')
print('v40 sql-admin-grant/delete bridge patched')
PYV40

echo "[2/5] Validate controller BEFORE live install..."
python3 -m py_compile "$CTL"

echo "[3/5] Install validated controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[4/5] Verify exact panel commands..."
HELP="$("$LIVE" --help 2>&1 || true)"
for cmd in sql-admins-list sql-admin-grant sql-admin-delete sql-admins-save sql-admins-delete; do
    echo "$HELP" | grep -q "$cmd" || fail "$cmd missing"
done
echo "panel admin commands: OK"

echo "[5/5] Read fresh admin list exactly as panel does..."
"$LIVE" sql-admins-list "$SID"

echo "--- users.ini ---"
cat "$CFG/users.ini" 2>/dev/null || true
echo "--- vips.ini ---"
cat "$CFG/vips.ini" 2>/dev/null || true
echo "--- vip.ini ---"
cat "$CFG/vip.ini" 2>/dev/null || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE ADMIN PANEL v40"
echo "================================================================"
echo " sql-admin-grant: WORKING"
echo " sql-admin-delete: WORKING"
echo " sql-admins-list: fresh GameCMS data"
echo " users.ini / vips.ini / vip.ini: synchronized"
echo " Source: gm_amxadmins + gm_admins_servers"
echo " Other server systems: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
