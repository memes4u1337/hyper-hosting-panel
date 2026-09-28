#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
INDEX="$ROOT/cs16-panel/public/index.php"
LIVE="/usr/local/sbin/hyper-cs16-ctl"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-admin-sql-final-v36-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$ROOT/.git" ]] || fail "not a git checkout: $ROOT"
[[ -f "$INDEX" ]] || fail "missing $INDEX"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before" 2>/dev/null || true
cp -a "$INDEX" "$BACKUP/index.php.before"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE SQL ADMINS PANEL FINAL v36"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Game/FastDL/YaPB/AMXX/Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/6] Restore clean controller from current fetched main..."
BASE="/tmp/hyper-cs16-ctl-v36.base"

if git -C "$ROOT" show FETCH_HEAD:cs16-panel/bin/hyper-cs16-ctl > "$BASE" 2>/dev/null; then
    :
elif git -C "$ROOT" show origin/main:cs16-panel/bin/hyper-cs16-ctl > "$BASE" 2>/dev/null; then
    :
else
    fail "cannot read controller from FETCH_HEAD/origin/main; run git fetch first"
fi

python3 -m py_compile "$BASE"
install -m 0755 "$BASE" "$CTL"

echo "[2/6] Replace ONLY AMXX admin backend with MySQL admins..."
python3 - "$CTL" <<'PYADMIN'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="strict")

block='def _game_admin_sql_connect(sid:int):\n    c=load_server(sid)\n    db_name=str(c.get(\'sql_db\') or _server_sql_names(sid)[0])\n    db_user=str(c.get(\'sql_user\') or _server_sql_names(sid)[1])\n    password=str(c.get(\'sql_password\') or \'\')\n    if not password:\n        raise RuntimeError(\'SQL сервера не настроен. Подключи SQL для этого сервера в панели.\')\n    try:\n        import pymysql\n        con=pymysql.connect(\n            host=\'127.0.0.1\',port=3306,user=db_user,password=password,database=db_name,\n            charset=\'utf8mb4\',autocommit=True,cursorclass=pymysql.cursors.DictCursor,connect_timeout=5\n        )\n    except Exception as exc:\n        raise RuntimeError(\'Не удалось подключиться к SQL сервера: \'+str(exc))\n    return c,con,db_name\n\ndef _ensure_game_admins_table(cur):\n    cur.execute(\n        "CREATE TABLE IF NOT EXISTS `admins` ("\n        "`auth` varchar(32) NOT NULL,"\n        "`password` varchar(32) NOT NULL,"\n        "`access` varchar(32) NOT NULL,"\n        "`flags` varchar(32) NOT NULL"\n        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT=\'AMX Mod X Admins\'"\n    )\n\ndef _sql_admin_rows(cur):\n    cur.execute("SELECT `auth`,`password`,`access`,`flags` FROM `admins` ORDER BY LOWER(`auth`),`auth`")\n    return cur.fetchall()\n\ndef _sql_admin_auth_type(identity:str,flags:str):\n    fl=(flags or \'\').lower()\n    if \'c\' in fl or STEAM_ID_RE.fullmatch(identity or \'\'):\n        return \'steamid\'\n    if \'d\' in fl:\n        return \'ip\'\n    return \'name\'\n\ndef admin_list(sid:int):\n    c,con,db_name=_game_admin_sql_connect(sid)\n    try:\n        with con.cursor() as cur:\n            _ensure_game_admins_table(cur)\n            raw=_sql_admin_rows(cur)\n        admins=[]\n        for index,row in enumerate(raw):\n            identity=str(row.get(\'auth\') or \'\')\n            password=str(row.get(\'password\') or \'\')\n            access=str(row.get(\'access\') or \'\').lower()\n            flags=str(row.get(\'flags\') or \'\').lower()\n            admins.append({\n                \'index\':index,\n                \'identity\':identity,\n                \'access_flags\':access,\n                \'auth_flags\':flags,\n                \'auth_type\':_sql_admin_auth_type(identity,flags),\n                \'has_password\':bool(password),\n                \'access_labels\':[AMXX_ACCESS_LABELS.get(x,x) for x in access if x in AMXX_ACCESS_LABELS]\n            })\n        return {\n            \'ok\':True,\'admins\':admins,\'password_field\':\'_pw\',\n            \'source\':\'mysql\',\'database\':db_name,\'table\':\'admins\'\n        }\n    finally:\n        con.close()\n\ndef _validate_admin_identity(identity:str,auth_type:str):\n    identity=identity.strip()\n    if not identity or len(identity)>32 or \'"\' in identity or chr(10) in identity or chr(13) in identity:\n        raise RuntimeError(\'Некорректный идентификатор администратора\')\n    if auth_type==\'steamid\':\n        if not STEAM_ID_RE.fullmatch(identity):\n            raise RuntimeError(\'Для SteamID нужен формат STEAM_0:1:123456\')\n        return identity.upper()\n    if auth_type==\'ip\':\n        try:\n            return str(ipaddress.ip_address(identity))\n        except ValueError:\n            raise RuntimeError(\'Некорректный IP администратора\')\n    if auth_type==\'name\':\n        return identity\n    raise RuntimeError(\'Неизвестный тип авторизации\')\n\ndef _normalize_access_flags(flags:str):\n    flags=\'\'.join(dict.fromkeys((flags or \'\').lower()))\n    bad=[x for x in flags if x not in AMXX_ALLOWED_ACCESS]\n    if bad:\n        raise RuntimeError(\'Недопустимые AMXX права: \'+\'\'.join(bad))\n    if not flags:\n        raise RuntimeError(\'Выбери хотя бы одно право администратора\')\n    return \'\'.join(x for x in \'abcdefghijklmnopqrstu\' if x in flags)\n\ndef _ensure_password_field(root:Path):\n    p=root/\'cstrike/addons/amxmodx/configs/amxx.cfg\'\n    p.parent.mkdir(parents=True,exist_ok=True)\n    text=p.read_text(encoding=\'utf-8\',errors=\'ignore\') if p.exists() else \'\'\n    rx=re.compile(r\'^\\s*amx_password_field\\s+.*$\',re.I|re.M)\n    line=\'amx_password_field "_pw"\'\n    if rx.search(text):\n        text=rx.sub(line,text,1)\n    else:\n        text=text.rstrip()+(\'\\n\\n\' if text.strip() else \'\')+line+\'\\n\'\n    p.write_text(text,encoding=\'utf-8\')\n\ndef _reload_amxx_admins(c):\n    try:\n        r=rcon_cmd(int(c[\'id\']),\'amx_reloadadmins\')\n        return {\'ok\':bool(r.get(\'ok\')),\'output\':str(r.get(\'output\',\'\'))[-1000:]}\n    except Exception as exc:\n        return {\'ok\':False,\'error\':str(exc)}\n\ndef admin_save(sid:int,payload:dict):\n    require_root()\n    c,con,db_name=_game_admin_sql_connect(sid)\n    auth_type=str(payload.get(\'auth_type\',\'steamid\')).lower()\n    identity=_validate_admin_identity(str(payload.get(\'identity\',\'\')),auth_type)\n    access=_normalize_access_flags(str(payload.get(\'access_flags\',\'\')))\n    try:\n        edit_index=int(payload.get(\'index\',-1))\n    except Exception:\n        edit_index=-1\n    password=str(payload.get(\'password\',\'\'))\n    generate=bool(payload.get(\'generate_password\',False))\n    if \'"\' in password or chr(10) in password or chr(13) in password or len(password)>32:\n        raise RuntimeError(\'Некорректный пароль администратора\')\n    try:\n        with con.cursor() as cur:\n            _ensure_game_admins_table(cur)\n            rows=_sql_admin_rows(cur)\n            existing=None\n            old_auth=\'\'\n            existing_password=\'\'\n            if edit_index>=0:\n                if edit_index>=len(rows):\n                    raise RuntimeError(\'Запись администратора уже изменилась. Обнови список.\')\n                existing=rows[edit_index]\n                old_auth=str(existing.get(\'auth\') or \'\')\n                existing_password=str(existing.get(\'password\') or \'\')\n            password_changed=generate or password!=\'\'\n            if generate:\n                password=secrets.token_urlsafe(12).replace(\'-\',\'A\').replace(\'_\',\'B\')[:16]\n            elif password==\'\':\n                password=existing_password\n            if auth_type==\'name\' and not password:\n                raise RuntimeError(\'Для авторизации по нику обязательно задай пароль\')\n            if auth_type==\'steamid\':\n                auth_flags=\'ca\' if password else \'ce\'\n            elif auth_type==\'ip\':\n                auth_flags=\'da\' if password else \'de\'\n            else:\n                auth_flags=\'a\'\n            for n,row in enumerate(rows):\n                if n==edit_index:\n                    continue\n                if str(row.get(\'auth\') or \'\').casefold()==identity.casefold():\n                    raise RuntimeError(f\'Администратор {identity} уже существует\')\n            if existing is None:\n                cur.execute(\n                    "INSERT INTO `admins` (`auth`,`password`,`access`,`flags`) VALUES (%s,%s,%s,%s)",\n                    (identity,password,access,auth_flags)\n                )\n            else:\n                cur.execute(\n                    "UPDATE `admins` SET `auth`=%s,`password`=%s,`access`=%s,`flags`=%s "\n                    "WHERE BINARY `auth`=%s LIMIT 1",\n                    (identity,password,access,auth_flags,old_auth)\n                )\n            rows_after=_sql_admin_rows(cur)\n            new_index=-1\n            for n,row in enumerate(rows_after):\n                if str(row.get(\'auth\') or \'\').casefold()==identity.casefold():\n                    new_index=n\n                    break\n        if password:\n            _ensure_password_field(Path(c[\'path\']))\n            normalize_permissions(Path(c[\'path\']))\n        reload=_reload_amxx_admins(c)\n        return {\n            \'ok\':True,\'index\':new_index,\'identity\':identity,\'auth_type\':auth_type,\n            \'access_flags\':access,\'auth_flags\':auth_flags,\'has_password\':bool(password),\n            \'generated_password\':password if generate else \'\',\n            \'client_command\':f\'setinfo _pw "{password}"\' if password and password_changed else \'\',\n            \'reload\':reload,\'source\':\'mysql\',\'database\':db_name,\'table\':\'admins\'\n        }\n    finally:\n        con.close()\n\ndef admin_delete(sid:int,index:int):\n    require_root()\n    c,con,db_name=_game_admin_sql_connect(sid)\n    try:\n        with con.cursor() as cur:\n            _ensure_game_admins_table(cur)\n            rows=_sql_admin_rows(cur)\n            if index<0 or index>=len(rows):\n                raise RuntimeError(\'Администратор не найден\')\n            removed=str(rows[index].get(\'auth\') or \'\')\n            cur.execute("DELETE FROM `admins` WHERE BINARY `auth`=%s LIMIT 1",(removed,))\n        reload=_reload_amxx_admins(c)\n        return {\n            \'ok\':True,\'removed\':removed,\'reload\':reload,\n            \'source\':\'mysql\',\'database\':db_name,\'table\':\'admins\'\n        }\n    finally:\n        con.close()'

m=re.search(r"(?ms)^def admin_list\(sid:int\):.*?(?=^def server_config_set\(args\):)",s)
if not m:
    raise SystemExit("cannot locate admin_list/admin_save/admin_delete block")

s=s[:m.start()]+block+"\n"+s[m.end():]
p.write_text(s,encoding="utf-8")
print("SQL admin backend patched")
PYADMIN

echo "[3/6] Update ONLY admin text in panel..."
python3 - "$INDEX" <<'PYPANEL'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')
s=s.replace(
    'Управление <code>users.ini</code> без ручного редактирования.',
    'Управление администраторами из SQL <code>admins</code>.'
)
s=s.replace(
    'server.cfg, AMXX, админы и список плагинов',
    'server.cfg, AMXX и список плагинов'
)
s=s.replace(
    "['server.cfg','amxx.cfg','users.ini','plugins.ini','modules.ini','mapcycle.txt','maps.ini']",
    "['server.cfg','amxx.cfg','plugins.ini','modules.ini','mapcycle.txt','maps.ini']"
)
p.write_text(s,encoding='utf-8')
print('panel labels patched')
PYPANEL

echo "[4/6] Validate BEFORE live install..."
python3 -m py_compile "$CTL"
php -l "$INDEX"

echo "[5/6] Install validated controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[6/6] Read admins from real server SQL..."
"$LIVE" admin-list "$SID"

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE SQL ADMINS PANEL v36"
echo "================================================================"
echo " Panel UI: existing admin modal/table"
echo " Source: MySQL cs16_srv_${SID}.admins"
echo " Columns: auth / password / access / flags"
echo " Add admin: YES"
echo " Edit rights/password: YES"
echo " Remove rights: edit access flags"
echo " Delete admin: YES"
echo " amx_reloadadmins after save/delete: YES"
echo " users.ini backend: DISABLED"
echo " Game/FastDL/YaPB/AMXX/Unprecacher: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
