#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
CFG="/srv/hyper-cs16/servers/${SID}/cstrike/addons/amxmodx/configs"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-admin-sync-v39-${STAMP}"

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
echo " OLD ZOMBIE ADMIN SQL + FILE SYNC FINAL v39"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Game/FastDL/YaPB/AMXX plugin list/Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Patch GameCMS admin bridge with file synchronization..."
python3 - "$CTL" <<'PYV39'

from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')

MARK_BEGIN="# === OLDZ SQL FILE SYNC v39 BEGIN ==="
MARK_END="# === OLDZ SQL FILE SYNC v39 END ==="

if MARK_BEGIN in s and MARK_END in s:
    a=s.index(MARK_BEGIN)
    b=s.index(MARK_END,a)+len(MARK_END)
    s=s[:a]+s[b:]

helper=r"""
# === OLDZ SQL FILE SYNC v39 BEGIN ===
def _v39_valid_steamid(value):
    value=str(value or '').strip()
    return value.upper() if STEAM_ID_RE.fullmatch(value) else ''

def _v39_resolve_steam2(cur,row):
    direct=_v39_valid_steamid(row.get('steamid'))
    if direct:
        return direct

    candidates=[]
    for key in ('username','nickname'):
        value=str(row.get(key) or '').strip()
        if value and value.casefold() not in [x.casefold() for x in candidates]:
            candidates.append(value)

    for value in candidates:
        cur.execute(
            "SELECT `steam2` FROM `oz_users` "
            "WHERE LOWER(`username`)=LOWER(%s) "
            "OR LOWER(`game_nick`)=LOWER(%s) "
            "ORDER BY CASE WHEN LOWER(`username`)=LOWER(%s) THEN 0 ELSE 1 END, `id` ASC LIMIT 1",
            (value,value,value)
        )
        found=cur.fetchone()
        steam=_v39_valid_steamid((found or {}).get('steam2'))
        if steam:
            return steam

    return ''

def _v39_password_hash(value):
    import hashlib,re as _re
    value=str(value or '')
    if not value:
        return ''
    if _re.fullmatch(r'[0-9a-fA-F]{32}',value):
        return value.lower()
    return hashlib.md5(value.encode('utf-8')).hexdigest()

def _v39_migrate_legacy_admins(sid:int):
    import time
    c,con,db_name=_game_admin_sql_connect(sid)
    migrated=[]
    try:
        with con.cursor() as cur:
            gm_sid=_gm_server_id(cur,c)

            cur.execute("SHOW TABLES LIKE 'admins'")
            if cur.fetchone() is None:
                return {'ok':True,'migrated':[],'gm_server_id':gm_sid}

            cur.execute("SELECT `auth`,`password`,`access`,`flags` FROM `admins` ORDER BY `auth`")
            legacy=cur.fetchall()

            current=_gm_admin_rows(cur,gm_sid)

            def existing_keys(rows):
                keys=set()
                for row in rows:
                    for key in ('username','nickname','steamid'):
                        value=str(row.get(key) or '').strip()
                        if value:
                            keys.add(value.casefold())
                return keys

            keys=existing_keys(current)

            for row in legacy:
                auth=str(row.get('auth') or '').strip()
                if not auth or auth.casefold() in keys:
                    continue

                access=str(row.get('access') or '').strip().lower()
                if not access:
                    continue

                pw_hash=_v39_password_hash(row.get('password'))
                steam=_v39_valid_steamid(auth)

                username=auth
                nickname=auth
                steamid=steam if steam else auth

                cur.execute(
                    "INSERT INTO `gm_amxadmins` "
                    "(`username`,`password`,`access`,`flags`,`steamid`,`nickname`,`icq`,`ashow`,`created`,`expired`,`days`) "
                    "VALUES (%s,%s,%s,'a',%s,%s,0,1,%s,0,0)",
                    (username,pw_hash,access,steamid,nickname,int(time.time()))
                )
                admin_id=int(cur.lastrowid)

                cur.execute(
                    "INSERT INTO `gm_admins_servers` "
                    "(`admin_id`,`server_id`,`custom_flags`,`use_static_bantime`) "
                    "VALUES (%s,%s,'','yes')",
                    (admin_id,gm_sid)
                )

                keys.add(auth.casefold())
                migrated.append({'id':admin_id,'auth':auth})

        return {'ok':True,'migrated':migrated,'gm_server_id':gm_sid}
    finally:
        con.close()

def _v39_quote(value):
    return str(value or '').replace('\\','\\\\').replace('"','\\"')

def _v39_detect_vip_flags(config_dir:Path):
    for name in ('vips.ini','vip.ini'):
        p=config_dir/name
        if not p.exists():
            continue
        for line in p.read_text(encoding='utf-8',errors='ignore').splitlines():
            line=line.strip()
            if not line or line.startswith(';'):
                continue
            parts=re.findall(r'"([^"]*)"',line)
            if len(parts)>=3 and parts[2]:
                return parts[2]
    return 'abcdek'

def _v39_atomic_write(path:Path,text:str):
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_name(path.name+'.v39.tmp')
    tmp.write_text(text,encoding='utf-8')
    tmp.replace(path)

def _v39_sync_admin_files(sid:int):
    c,con,db_name=_game_admin_sql_connect(sid)
    try:
        with con.cursor() as cur:
            gm_sid=_gm_server_id(cur,c)
            rows=_gm_admin_rows(cur,gm_sid)

            resolved=[]
            for row in rows:
                item=dict(row)
                item['_steam2']=_v39_resolve_steam2(cur,row)
                resolved.append(item)

        config_dir=Path(c['path'])/'cstrike/addons/amxmodx/configs'
        users_path=config_dir/'users.ini'
        vips_path=config_dir/'vips.ini'
        vip_path=config_dir/'vip.ini'

        vip_flags=_v39_detect_vip_flags(config_dir)

        users_lines=[
            '; AUTO-GENERATED BY HYPER-HOST / OLD ZOMBIE v39',
            '; Source: GameCMS gm_amxadmins + gm_admins_servers',
            '; Manual edits may be overwritten by the panel.',
            ''
        ]
        vip_lines=[
            '; AUTO-GENERATED BY HYPER-HOST / OLD ZOMBIE v39',
            '; VIP source: GameCMS admins with AMXX flag "t"',
            '; Format: "auth" "password" "vip_flags" "auth_flags"',
            ''
        ]

        synced_users=0
        synced_vips=0
        unresolved=[]

        for row in resolved:
            steam=str(row.get('_steam2') or '')
            access=str(row.get('custom_flags') or row.get('access') or '').lower()

            if not steam:
                unresolved.append(str(row.get('username') or row.get('nickname') or row.get('id')))
                continue

            users_lines.append(
                f'"{_v39_quote(steam)}" "" "{_v39_quote(access)}" "ce"'
            )
            synced_users+=1

            if 't' in access:
                vip_lines.append(
                    f'"{_v39_quote(steam)}" "" "{_v39_quote(vip_flags)}" "ce"'
                )
                synced_vips+=1

        users_lines.append('')
        vip_lines.append('')

        _v39_atomic_write(users_path,'\n'.join(users_lines))
        _v39_atomic_write(vips_path,'\n'.join(vip_lines))

        # Some old builds/panels refer to vip.ini (singular).
        # Keep it mirrored too, while zm_vip itself normally reads vips.ini.
        _v39_atomic_write(vip_path,'\n'.join(vip_lines))

        try:
            normalize_permissions(Path(c['path']))
        except Exception:
            pass

        reload_admins=_reload_amxx_admins(c)
        try:
            reload_vips=rcon_cmd(int(c['id']),'amx_reloadvips')
        except Exception as exc:
            reload_vips={'ok':False,'error':str(exc)}

        return {
            'ok':True,
            'database':db_name,
            'gm_server_id':gm_sid,
            'users_ini':str(users_path),
            'vips_ini':str(vips_path),
            'vip_ini':str(vip_path),
            'users_count':synced_users,
            'vips_count':synced_vips,
            'vip_flags':vip_flags,
            'unresolved':unresolved,
            'reload_admins':reload_admins,
            'reload_vips':reload_vips
        }
    finally:
        con.close()
# === OLDZ SQL FILE SYNC v39 END ===
"""

anchor='def sql_admins_list(sid:int):'
pos=s.find(anchor)
if pos<0:
    raise SystemExit('sql_admins_list() from v38 not found')
s=s[:pos]+helper.strip()+"\n\n"+s[pos:]

old="""def sql_admins_list(sid:int):
    result=admin_list(sid)"""
new="""def sql_admins_list(sid:int):
    migration=_v39_migrate_legacy_admins(sid)
    sync=_v39_sync_admin_files(sid)
    result=admin_list(sid)"""
if old not in s:
    raise SystemExit('cannot patch sql_admins_list()')
s=s.replace(old,new,1)

old="""    out['table']='gm_amxadmins + gm_admins_servers'
    return out

def sql_admins_save"""
new="""    out['table']='gm_amxadmins + gm_admins_servers'
    out['migration']=migration
    out['file_sync']=sync
    return out

def sql_admins_save"""
if old not in s:
    raise SystemExit('cannot patch sql_admins_list return')
s=s.replace(old,new,1)

old="""    result=admin_save(sid,p)
    out=dict(result)"""
new="""    result=admin_save(sid,p)
    sync=_v39_sync_admin_files(sid)
    fresh=admin_list(sid)
    out=dict(result)
    out['admins']=fresh.get('admins',[])
    out['rows']=fresh.get('admins',[])
    out['file_sync']=sync"""
if old not in s:
    raise SystemExit('cannot patch sql_admins_save result')
s=s.replace(old,new,1)

old="""    result=admin_delete(sid,index)
    out=dict(result)"""
new="""    result=admin_delete(sid,index)
    sync=_v39_sync_admin_files(sid)
    fresh=admin_list(sid)
    out=dict(result)
    out['admins']=fresh.get('admins',[])
    out['rows']=fresh.get('admins',[])
    out['file_sync']=sync"""
if old not in s:
    raise SystemExit('cannot patch sql_admins_delete result')
s=s.replace(old,new,1)

p.write_text(s,encoding='utf-8')
print('v39 SQL/file sync patched')
PYV39

echo "[2/5] Validate controller BEFORE live install..."
python3 -m py_compile "$CTL"

echo "[3/5] Install validated controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[4/5] Force migration + SQL reread + users.ini/vips.ini sync..."
"$LIVE" sql-admins-list "$SID"

echo "[5/5] Show generated files..."
echo "--- users.ini ---"
cat "$CFG/users.ini" || true
echo "--- vips.ini ---"
cat "$CFG/vips.ini" || true
echo "--- vip.ini ---"
cat "$CFG/vip.ini" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE ADMIN SYNC v39"
echo "================================================================"
echo " SQL source: gm_amxadmins + gm_admins_servers"
echo " Real SteamID fallback: oz_users.steam2"
echo " Legacy admins table: auto-migrated if it contains missing admins"
echo " Panel list: forced fresh SQL read"
echo " users.ini: generated from SQL"
echo " vips.ini: generated for admins containing AMXX flag t"
echo " vip.ini: mirrored for compatibility"
echo " amx_reloadadmins + amx_reloadvips: automatic"
echo " Other server systems: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
