#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
INDEX="$ROOT/cs16-panel/public/index.php"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-gamecms-admins-v37-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"
[[ -f "$INDEX" ]] || fail "missing $INDEX"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
cp -a "$INDEX" "$BACKUP/index.php.before"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE GAMECMS ADMINS FINAL v37"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Game/FastDL/YaPB/AMXX/Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Patch current admin backend to real GameCMS tables..."
python3 - "$CTL" <<'PYADMIN'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="strict")
block='def _game_admin_sql_connect(sid:int):\n    c=load_server(sid)\n    db_name=str(c.get(\'sql_db\') or _server_sql_names(sid)[0])\n    db_user=str(c.get(\'sql_user\') or _server_sql_names(sid)[1])\n    password=str(c.get(\'sql_password\') or \'\')\n    if not password:\n        raise RuntimeError(\'SQL сервера не настроен. Подключи SQL для этого сервера в панели.\')\n    try:\n        import pymysql\n        con=pymysql.connect(\n            host=\'127.0.0.1\',port=3306,user=db_user,password=password,database=db_name,\n            charset=\'utf8mb4\',autocommit=True,cursorclass=pymysql.cursors.DictCursor,connect_timeout=5\n        )\n    except Exception as exc:\n        raise RuntimeError(\'Не удалось подключиться к SQL сервера: \'+str(exc))\n    return c,con,db_name\n\ndef _gm_server_id(cur,c):\n    port=int(c.get(\'port\') or 0)\n    public_ip=str(c.get(\'public_ip\') or \'\').strip()\n\n    cur.execute("SELECT `id`,`address` FROM `gm_serverinfo` ORDER BY `id`")\n    rows=cur.fetchall()\n\n    wanted_port=\':\'+str(port)\n    for row in rows:\n        address=str(row.get(\'address\') or \'\').strip()\n        if wanted_port and address.endswith(wanted_port):\n            if not public_ip or address.startswith(public_ip+\':\'):\n                return int(row.get(\'id\'))\n\n    if len(rows)==1:\n        return int(rows[0].get(\'id\'))\n\n    cur.execute("SELECT DISTINCT `server_id` FROM `gm_admins_servers` WHERE `server_id` IS NOT NULL ORDER BY `server_id`")\n    ids=[int(x.get(\'server_id\')) for x in cur.fetchall() if x.get(\'server_id\') is not None]\n    if len(ids)==1:\n        return ids[0]\n\n    raise RuntimeError(\'Не удалось определить gm_serverinfo.id для этого игрового сервера\')\n\ndef _gm_admin_rows(cur,gm_server_id:int):\n    cur.execute(\n        "SELECT "\n        "a.`id`,a.`username`,a.`password`,a.`access`,a.`flags`,a.`steamid`,a.`nickname`,"\n        "a.`created`,a.`expired`,a.`days`,s.`custom_flags`,s.`use_static_bantime` "\n        "FROM `gm_amxadmins` a "\n        "INNER JOIN `gm_admins_servers` s ON s.`admin_id`=a.`id` "\n        "WHERE s.`server_id`=%s "\n        "ORDER BY a.`id` ASC",\n        (gm_server_id,)\n    )\n    return cur.fetchall()\n\ndef _gm_identity(row):\n    steamid=str(row.get(\'steamid\') or \'\').strip()\n    username=str(row.get(\'username\') or \'\').strip()\n    nickname=str(row.get(\'nickname\') or \'\').strip()\n\n    if STEAM_ID_RE.fullmatch(steamid):\n        return steamid\n    if username:\n        return username\n    if nickname:\n        return nickname\n    return steamid\n\ndef _gm_auth_type(row):\n    steamid=str(row.get(\'steamid\') or \'\').strip()\n    if STEAM_ID_RE.fullmatch(steamid):\n        return \'steamid\'\n    return \'name\'\n\ndef admin_list(sid:int):\n    c,con,db_name=_game_admin_sql_connect(sid)\n    try:\n        with con.cursor() as cur:\n            gm_sid=_gm_server_id(cur,c)\n            raw=_gm_admin_rows(cur,gm_sid)\n\n        admins=[]\n        for index,row in enumerate(raw):\n            identity=_gm_identity(row)\n            access=str(row.get(\'custom_flags\') or row.get(\'access\') or \'\').lower()\n            password=str(row.get(\'password\') or \'\')\n            admins.append({\n                \'index\':index,\n                \'db_id\':int(row.get(\'id\')),\n                \'identity\':identity,\n                \'username\':str(row.get(\'username\') or \'\'),\n                \'steamid\':str(row.get(\'steamid\') or \'\'),\n                \'nickname\':str(row.get(\'nickname\') or \'\'),\n                \'access_flags\':access,\n                \'auth_flags\':str(row.get(\'flags\') or \'\'),\n                \'auth_type\':_gm_auth_type(row),\n                \'has_password\':bool(password),\n                \'created\':int(row.get(\'created\') or 0),\n                \'expired\':int(row.get(\'expired\') or 0),\n                \'days\':int(row.get(\'days\') or 0),\n                \'access_labels\':[AMXX_ACCESS_LABELS.get(x,x) for x in access if x in AMXX_ACCESS_LABELS]\n            })\n\n        return {\n            \'ok\':True,\n            \'admins\':admins,\n            \'password_field\':\'_pw\',\n            \'source\':\'gamecms\',\n            \'database\':db_name,\n            \'table\':\'gm_amxadmins + gm_admins_servers\',\n            \'gm_server_id\':gm_sid\n        }\n    finally:\n        con.close()\n\ndef _validate_admin_identity(identity:str,auth_type:str):\n    identity=identity.strip()\n    if not identity or len(identity)>32 or \'"\' in identity or chr(10) in identity or chr(13) in identity:\n        raise RuntimeError(\'Некорректный идентификатор администратора\')\n    if auth_type==\'steamid\':\n        if not STEAM_ID_RE.fullmatch(identity):\n            raise RuntimeError(\'Для SteamID нужен формат STEAM_0:1:123456\')\n        return identity.upper()\n    if auth_type==\'name\':\n        return identity\n    if auth_type==\'ip\':\n        try:\n            return str(ipaddress.ip_address(identity))\n        except ValueError:\n            raise RuntimeError(\'Некорректный IP администратора\')\n    raise RuntimeError(\'Неизвестный тип авторизации\')\n\ndef _normalize_access_flags(flags:str):\n    flags=\'\'.join(dict.fromkeys((flags or \'\').lower()))\n    bad=[x for x in flags if x not in AMXX_ALLOWED_ACCESS]\n    if bad:\n        raise RuntimeError(\'Недопустимые AMXX права: \'+\'\'.join(bad))\n    if not flags:\n        raise RuntimeError(\'Выбери хотя бы одно право администратора\')\n    return \'\'.join(x for x in \'abcdefghijklmnopqrstu\' if x in flags)\n\ndef _ensure_password_field(root:Path):\n    p=root/\'cstrike/addons/amxmodx/configs/amxx.cfg\'\n    p.parent.mkdir(parents=True,exist_ok=True)\n    text=p.read_text(encoding=\'utf-8\',errors=\'ignore\') if p.exists() else \'\'\n    rx=re.compile(r\'^\\s*amx_password_field\\s+.*$\',re.I|re.M)\n    line=\'amx_password_field "_pw"\'\n    if rx.search(text):\n        text=rx.sub(line,text,1)\n    else:\n        text=text.rstrip()+(\'\\n\\n\' if text.strip() else \'\')+line+\'\\n\'\n    p.write_text(text,encoding=\'utf-8\')\n\ndef _reload_amxx_admins(c):\n    try:\n        r=rcon_cmd(int(c[\'id\']),\'amx_reloadadmins\')\n        return {\'ok\':bool(r.get(\'ok\')),\'output\':str(r.get(\'output\',\'\'))[-1000:]}\n    except Exception as exc:\n        return {\'ok\':False,\'error\':str(exc)}\n\ndef admin_save(sid:int,payload:dict):\n    require_root()\n    import hashlib,time\n\n    c,con,db_name=_game_admin_sql_connect(sid)\n\n    auth_type=str(payload.get(\'auth_type\',\'name\')).lower()\n    identity=_validate_admin_identity(str(payload.get(\'identity\',\'\')),auth_type)\n    access=_normalize_access_flags(str(payload.get(\'access_flags\',\'\')))\n\n    try:\n        edit_index=int(payload.get(\'index\',-1))\n    except Exception:\n        edit_index=-1\n\n    plain_password=str(payload.get(\'password\',\'\'))\n    generate=bool(payload.get(\'generate_password\',False))\n\n    if \'"\' in plain_password or chr(10) in plain_password or chr(13) in plain_password or len(plain_password)>32:\n        raise RuntimeError(\'Некорректный пароль администратора\')\n\n    try:\n        with con.cursor() as cur:\n            gm_sid=_gm_server_id(cur,c)\n            rows=_gm_admin_rows(cur,gm_sid)\n\n            existing=None\n            if edit_index>=0:\n                if edit_index>=len(rows):\n                    raise RuntimeError(\'Запись администратора уже изменилась. Обнови список.\')\n                existing=rows[edit_index]\n\n            existing_hash=str(existing.get(\'password\') or \'\') if existing else \'\'\n            password_changed=generate or plain_password!=\'\'\n\n            if generate:\n                plain_password=secrets.token_urlsafe(10).replace(\'-\',\'A\').replace(\'_\',\'B\')[:14]\n\n            if plain_password:\n                password_hash=hashlib.md5(plain_password.encode(\'utf-8\')).hexdigest()\n            else:\n                password_hash=existing_hash\n\n            if auth_type==\'name\' and not password_hash:\n                raise RuntimeError(\'Для администратора по нику обязательно задай пароль\')\n\n            username=identity\n            nickname=identity\n            steamid=identity if auth_type==\'steamid\' else identity\n\n            for n,row in enumerate(rows):\n                if n==edit_index:\n                    continue\n                vals={\n                    str(row.get(\'username\') or \'\').casefold(),\n                    str(row.get(\'steamid\') or \'\').casefold(),\n                    str(row.get(\'nickname\') or \'\').casefold()\n                }\n                if identity.casefold() in vals:\n                    raise RuntimeError(f\'Администратор {identity} уже существует\')\n\n            now=int(time.time())\n\n            if existing is None:\n                cur.execute(\n                    "INSERT INTO `gm_amxadmins` "\n                    "(`username`,`password`,`access`,`flags`,`steamid`,`nickname`,`icq`,`ashow`,`created`,`expired`,`days`) "\n                    "VALUES (%s,%s,%s,%s,%s,%s,0,1,%s,0,0)",\n                    (username,password_hash,access,\'a\',steamid,nickname,now)\n                )\n                admin_id=int(cur.lastrowid)\n                cur.execute(\n                    "INSERT INTO `gm_admins_servers` "\n                    "(`admin_id`,`server_id`,`custom_flags`,`use_static_bantime`) "\n                    "VALUES (%s,%s,\'\',\'yes\')",\n                    (admin_id,gm_sid)\n                )\n            else:\n                admin_id=int(existing.get(\'id\'))\n                cur.execute(\n                    "UPDATE `gm_amxadmins` SET "\n                    "`username`=%s,`password`=%s,`access`=%s,`flags`=\'a\',`steamid`=%s,`nickname`=%s "\n                    "WHERE `id`=%s LIMIT 1",\n                    (username,password_hash,access,steamid,nickname,admin_id)\n                )\n                cur.execute(\n                    "UPDATE `gm_admins_servers` SET `custom_flags`=\'\' "\n                    "WHERE `admin_id`=%s AND `server_id`=%s",\n                    (admin_id,gm_sid)\n                )\n\n            rows_after=_gm_admin_rows(cur,gm_sid)\n            new_index=-1\n            for n,row in enumerate(rows_after):\n                if int(row.get(\'id\'))==admin_id:\n                    new_index=n\n                    break\n\n        if password_hash:\n            _ensure_password_field(Path(c[\'path\']))\n            normalize_permissions(Path(c[\'path\']))\n\n        reload=_reload_amxx_admins(c)\n\n        return {\n            \'ok\':True,\n            \'index\':new_index,\n            \'db_id\':admin_id,\n            \'identity\':identity,\n            \'auth_type\':auth_type,\n            \'access_flags\':access,\n            \'auth_flags\':\'a\',\n            \'has_password\':bool(password_hash),\n            \'generated_password\':plain_password if generate else \'\',\n            \'client_command\':f\'setinfo _pw "{plain_password}"\' if plain_password and password_changed else \'\',\n            \'reload\':reload,\n            \'source\':\'gamecms\',\n            \'database\':db_name,\n            \'gm_server_id\':gm_sid\n        }\n    finally:\n        con.close()\n\ndef admin_delete(sid:int,index:int):\n    require_root()\n\n    c,con,db_name=_game_admin_sql_connect(sid)\n\n    try:\n        with con.cursor() as cur:\n            gm_sid=_gm_server_id(cur,c)\n            rows=_gm_admin_rows(cur,gm_sid)\n\n            if index<0 or index>=len(rows):\n                raise RuntimeError(\'Администратор не найден\')\n\n            row=rows[index]\n            admin_id=int(row.get(\'id\'))\n            removed=_gm_identity(row)\n\n            cur.execute(\n                "DELETE FROM `gm_admins_servers` WHERE `admin_id`=%s AND `server_id`=%s",\n                (admin_id,gm_sid)\n            )\n\n            cur.execute(\n                "SELECT COUNT(*) AS c FROM `gm_admins_servers` WHERE `admin_id`=%s",\n                (admin_id,)\n            )\n            refs=int((cur.fetchone() or {}).get(\'c\') or 0)\n\n            if refs==0:\n                cur.execute("DELETE FROM `gm_amxadmins` WHERE `id`=%s LIMIT 1",(admin_id,))\n\n        reload=_reload_amxx_admins(c)\n\n        return {\n            \'ok\':True,\n            \'removed\':removed,\n            \'db_id\':admin_id,\n            \'reload\':reload,\n            \'source\':\'gamecms\',\n            \'database\':db_name,\n            \'gm_server_id\':gm_sid\n        }\n    finally:\n        con.close()'

m=re.search(r"(?ms)^def _game_admin_sql_connect\(sid:int\):.*?(?=^def server_config_set\(args\):)",s)
if not m:
    m=re.search(r"(?ms)^def admin_list\(sid:int\):.*?(?=^def server_config_set\(args\):)",s)
if not m:
    raise SystemExit("cannot locate current admin backend")

s=s[:m.start()]+block+"\n"+s[m.end():]
p.write_text(s,encoding="utf-8")
print("GameCMS admin backend patched")
PYADMIN

echo "[2/5] Update admin text in panel..."
python3 - "$INDEX" <<'PYPANEL'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')

repls={
    'Управление администраторами из SQL <code>admins</code>.':
        'Администраторы из SQL <code>gm_amxadmins</code> с привязкой через <code>gm_admins_servers</code>.',
    'Управление <code>users.ini</code> без ручного редактирования.':
        'Администраторы из SQL <code>gm_amxadmins</code> с привязкой через <code>gm_admins_servers</code>.'
}
for a,b in repls.items():
    s=s.replace(a,b)

p.write_text(s,encoding='utf-8')
print('panel admin labels patched')
PYPANEL

echo "[3/5] Validate syntax BEFORE live install..."
python3 -m py_compile "$CTL"
php -l "$INDEX"

echo "[4/5] Install validated controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[5/5] Read REAL current admins from GameCMS..."
"$LIVE" admin-list "$SID"

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE GAMECMS ADMINS v37"
echo "================================================================"
echo " Source: gm_amxadmins + gm_admins_servers"
echo " gm_server_id: auto-detected from gm_serverinfo/port"
echo " Existing admins: displayed"
echo " Add: creates gm_amxadmins + gm_admins_servers"
echo " Edit: updates identity/password/access"
echo " Delete: removes server link; deletes admin row if no links remain"
echo " Passwords: MD5-compatible with existing GameCMS rows"
echo " amx_reloadadmins: automatic"
echo " Other server systems: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
