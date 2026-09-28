#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"

CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-panel-admins-bots-v33-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" || true

echo "================================================================"
echo " OLD ZOMBIE PANEL ADMINS + BOTS FINAL v33"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " index.php: NOT MODIFIED"
echo " FastDL/nginx/AMXX plugins: NOT MODIFIED"
echo "================================================================"

echo "[1/7] Repair controller source and switch panel admins to SQL..."

python3 - "$CTL" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="strict")

for ver in ("v31","v32"):
    s=re.sub(
        rf'(?ms)^# === HYPER-HOST SQL ADMIN MANAGER {re.escape(ver)} BEGIN ===.*?^# === HYPER-HOST SQL ADMIN MANAGER {re.escape(ver)} END ===\s*',
        '',
        s
    )

admin_block = r'''
def _sql_admin_connect(sid:int):
    c=load_server(sid)
    db_name=str(c.get('sql_db') or _server_sql_names(sid)[0])
    db_user=str(c.get('sql_user') or _server_sql_names(sid)[1])
    password=str(c.get('sql_password') or '')
    if not password:
        raise RuntimeError('SQL сервера не настроен. Сначала подключи SQL в панели.')
    try:
        import pymysql
        con=pymysql.connect(
            host='127.0.0.1',
            port=3306,
            user=db_user,
            password=password,
            database=db_name,
            charset='utf8mb4',
            autocommit=True,
            cursorclass=pymysql.cursors.DictCursor,
            connect_timeout=5
        )
        return c,con,db_name
    except Exception as exc:
        raise RuntimeError('Не удалось подключиться к SQL сервера: '+str(exc))

def _sql_admin_schema(cur):
    cur.execute("SHOW TABLES LIKE 'admins'")
    if cur.fetchone() is None:
        cur.execute(
            "CREATE TABLE `admins` ("
            "`id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,"
            "`auth` VARCHAR(96) NOT NULL,"
            "`password` VARCHAR(96) NOT NULL DEFAULT '',"
            "`access` VARCHAR(32) NOT NULL DEFAULT '',"
            "`flags` VARCHAR(32) NOT NULL DEFAULT '',"
            "PRIMARY KEY (`id`),"
            "UNIQUE KEY `uq_admins_auth` (`auth`)"
            ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
        )

    cur.execute("SHOW COLUMNS FROM `admins`")
    rows=cur.fetchall()
    cols=[str(x.get('Field') or '') for x in rows]
    lower={x.lower():x for x in cols}

    def pick(*names):
        for name in names:
            if name.lower() in lower:
                return lower[name.lower()]
        return ''

    schema={
        'id':pick('id','admin_id'),
        'identity':pick('auth','identity','steamid','steam_id','steam','nick','nickname','name'),
        'password':pick('password','passwd','pass','pw'),
        'access':pick('access','access_flags','permissions','privileges'),
        'flags':pick('flags','auth_flags','account_flags'),
    }

    missing=[x for x in ('identity','access','flags') if not schema[x]]
    if missing:
        raise RuntimeError(
            'Таблица admins имеет неподдерживаемую структуру. '
            'Колонки: '+', '.join(cols)+'. Не найдены: '+', '.join(missing)
        )
    return schema,cols

def _sql_admin_qcol(name:str)->str:
    if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',str(name or '')):
        raise RuntimeError('Некорректная SQL-колонка')
    return '`'+name+'`'

def _sql_admin_rows(cur,schema):
    order=_sql_admin_qcol(schema['id']) if schema['id'] else _sql_admin_qcol(schema['identity'])
    cur.execute('SELECT * FROM `admins` ORDER BY '+order+' ASC')
    return cur.fetchall()

def _sql_admin_auth_type(identity:str,auth_flags:str)->str:
    flags=(auth_flags or '').lower()
    if 'c' in flags or STEAM_ID_RE.fullmatch(identity or ''):
        return 'steamid'
    if 'd' in flags:
        return 'ip'
    try:
        ipaddress.ip_address(identity or '')
        return 'ip'
    except Exception:
        return 'name'

def admin_list(sid:int):
    c,con,db_name=_sql_admin_connect(sid)
    try:
        with con.cursor() as cur:
            schema,cols=_sql_admin_schema(cur)
            raw=_sql_admin_rows(cur,schema)

        admins=[]
        for index,row in enumerate(raw):
            identity=str(row.get(schema['identity']) or '')
            access=str(row.get(schema['access']) or '').lower()
            flags=str(row.get(schema['flags']) or '').lower()
            password=str(row.get(schema['password']) or '') if schema['password'] else ''
            admins.append({
                'index':index,
                'identity':identity,
                'access_flags':access,
                'auth_flags':flags,
                'auth_type':_sql_admin_auth_type(identity,flags),
                'has_password':bool(password),
                'access_labels':[AMXX_ACCESS_LABELS.get(x,x) for x in access if x in AMXX_ACCESS_LABELS],
            })

        return {
            'ok':True,
            'admins':admins,
            'password_field':'_pw',
            'source':'mysql',
            'database':db_name,
            'table':'admins',
            'columns':cols
        }
    finally:
        con.close()

def _validate_admin_identity(identity:str,auth_type:str):
    identity=identity.strip()
    if not identity or len(identity)>96 or '"' in identity or chr(10) in identity or chr(13) in identity:
        raise RuntimeError('Некорректный идентификатор администратора')
    if auth_type=='steamid':
        if not STEAM_ID_RE.fullmatch(identity):
            raise RuntimeError('Для SteamID нужен формат STEAM_0:1:123456')
        return identity.upper()
    if auth_type=='ip':
        try:
            return str(ipaddress.ip_address(identity))
        except ValueError:
            raise RuntimeError('Некорректный IP администратора')
    if auth_type=='name':
        if len(identity)>64:
            raise RuntimeError('Ник администратора слишком длинный')
        return identity
    raise RuntimeError('Неизвестный тип авторизации')

def _normalize_access_flags(flags:str):
    flags=''.join(dict.fromkeys((flags or '').lower()))
    bad=[x for x in flags if x not in AMXX_ALLOWED_ACCESS]
    if bad:
        raise RuntimeError('Недопустимые AMXX права: '+''.join(bad))
    if not flags:
        raise RuntimeError('Выбери хотя бы одно право администратора')
    return ''.join(x for x in 'abcdefghijklmnopqrstu' if x in flags)

def _ensure_password_field(root:Path):
    p=root/'cstrike/addons/amxmodx/configs/amxx.cfg'
    p.parent.mkdir(parents=True,exist_ok=True)
    text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
    rx=re.compile(r'^\s*amx_password_field\s+.*$',re.I|re.M)
    line='amx_password_field "_pw"'
    if rx.search(text):
        text=rx.sub(line,text,1)
    else:
        text=text.rstrip()+('\n\n' if text.strip() else '')+line+'\n'
    p.write_text(text,encoding='utf-8')

def _reload_amxx_admins(c):
    try:
        r=rcon_cmd(int(c['id']),'amx_reloadadmins')
        return {'ok':bool(r.get('ok')),'output':str(r.get('output',''))[-1000:]}
    except Exception as exc:
        return {'ok':False,'error':str(exc)}

def admin_save(sid:int,payload:dict):
    require_root()
    c,con,db_name=_sql_admin_connect(sid)

    auth_type=str(payload.get('auth_type','steamid')).lower()
    identity=_validate_admin_identity(str(payload.get('identity','')),auth_type)
    access=_normalize_access_flags(str(payload.get('access_flags','')))

    try:
        edit_index=int(payload.get('index',-1))
    except Exception:
        edit_index=-1

    password=str(payload.get('password',''))
    generate=bool(payload.get('generate_password',False))

    if '"' in password or chr(10) in password or chr(13) in password or len(password)>96:
        raise RuntimeError('Некорректный пароль администратора')

    try:
        with con.cursor() as cur:
            schema,cols=_sql_admin_schema(cur)
            rows=_sql_admin_rows(cur,schema)

            existing=None
            old_identity=''
            existing_password=''

            if edit_index>=0:
                if edit_index>=len(rows):
                    raise RuntimeError('Запись администратора уже изменилась. Обнови список.')
                existing=rows[edit_index]
                old_identity=str(existing.get(schema['identity']) or '')
                if schema['password']:
                    existing_password=str(existing.get(schema['password']) or '')

            password_changed=generate or password!=''
            if generate:
                password=secrets.token_urlsafe(12).replace('-','A').replace('_','B')[:16]
            elif password=='':
                password=existing_password

            if auth_type=='name' and not password:
                raise RuntimeError('Для авторизации по нику обязательно задай пароль')

            if auth_type=='steamid':
                auth_flags='ca' if password else 'ce'
            elif auth_type=='ip':
                auth_flags='da' if password else 'de'
            else:
                auth_flags='a'

            qi=_sql_admin_qcol(schema['identity'])

            for n,row in enumerate(rows):
                if n==edit_index:
                    continue
                if str(row.get(schema['identity']) or '').casefold()==identity.casefold():
                    raise RuntimeError(f'Администратор {identity} уже существует')

            values={
                schema['identity']:identity,
                schema['access']:access,
                schema['flags']:auth_flags,
            }
            if schema['password']:
                values[schema['password']]=password

            if existing is None:
                names=list(values)
                cur.execute(
                    'INSERT INTO `admins` ('+', '.join(_sql_admin_qcol(x) for x in names)+') '
                    'VALUES ('+','.join(['%s']*len(names))+')',
                    tuple(values[x] for x in names)
                )
            else:
                sets=', '.join(_sql_admin_qcol(k)+'=%s' for k in values)
                vals=list(values.values())
                if schema['id']:
                    qid=_sql_admin_qcol(schema['id'])
                    vals.append(existing.get(schema['id']))
                    cur.execute('UPDATE `admins` SET '+sets+' WHERE '+qid+'=%s',tuple(vals))
                else:
                    vals.append(old_identity)
                    cur.execute(
                        'UPDATE `admins` SET '+sets+' WHERE LOWER('+qi+')=LOWER(%s)',
                        tuple(vals)
                    )

            rows_after=_sql_admin_rows(cur,schema)
            new_index=-1
            for n,row in enumerate(rows_after):
                if str(row.get(schema['identity']) or '').casefold()==identity.casefold():
                    new_index=n
                    break

        if password:
            _ensure_password_field(Path(c['path']))
            normalize_permissions(Path(c['path']))

        reload=_reload_amxx_admins(c)
        return {
            'ok':True,
            'index':new_index,
            'identity':identity,
            'auth_type':auth_type,
            'access_flags':access,
            'has_password':bool(password),
            'generated_password':password if generate else '',
            'client_command':f'setinfo _pw "{password}"' if password and password_changed else '',
            'reload':reload,
            'source':'mysql',
            'database':db_name
        }
    finally:
        con.close()

def admin_delete(sid:int,index:int):
    require_root()
    c,con,db_name=_sql_admin_connect(sid)
    try:
        with con.cursor() as cur:
            schema,cols=_sql_admin_schema(cur)
            rows=_sql_admin_rows(cur,schema)

            if index<0 or index>=len(rows):
                raise RuntimeError('Администратор не найден')

            row=rows[index]
            removed=str(row.get(schema['identity']) or '')

            if schema['id']:
                qid=_sql_admin_qcol(schema['id'])
                cur.execute('DELETE FROM `admins` WHERE '+qid+'=%s',(row.get(schema['id']),))
            else:
                qi=_sql_admin_qcol(schema['identity'])
                cur.execute('DELETE FROM `admins` WHERE LOWER('+qi+')=LOWER(%s)',(removed,))

        reload=_reload_amxx_admins(c)
        return {'ok':True,'removed':removed,'reload':reload,'source':'mysql','database':db_name}
    finally:
        con.close()
'''

pattern=r'(?ms)^def admin_list\(sid:int\):.*?(?=^def server_config_set\(args\):)'
m=re.search(pattern,s)
if not m:
    raise SystemExit('admin backend block not found')
s=s[:m.start()]+admin_block.strip()+"\n"+s[m.end():]

helper = r'''
def _enable_yapb_metamod(cstrike:Path):
    p=cstrike/'addons/metamod/plugins.ini'
    p.parent.mkdir(parents=True,exist_ok=True)
    lines=p.read_text(encoding='utf-8',errors='ignore').splitlines() if p.exists() else []
    wanted='linux addons/yapb/bin/yapb.so'
    out=[]
    found=False
    changed=False

    for line in lines:
        if 'addons/yapb/bin/yapb.so' in line.lower():
            if not found:
                out.append(wanted)
                found=True
                if line.strip()!=wanted:
                    changed=True
            else:
                changed=True
            continue
        out.append(line)

    if not found:
        out.append(wanted)
        changed=True

    new_text='\n'.join(out).rstrip()+'\n'
    old_text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
    if new_text!=old_text:
        p.write_text(new_text,encoding='utf-8')
        changed=True
    return changed
'''

if 'def _enable_yapb_metamod(cstrike:Path):' not in s:
    pos=s.find('def install_yapb(sid:int')
    if pos<0:
        raise SystemExit('install_yapb not found')
    s=s[:pos]+helper.strip()+"\n\n"+s[pos:]

s=s.replace(
    "_append_unique(cstrike/'addons/metamod/plugins.ini','linux addons/yapb/bin/yapb.so')",
    "_enable_yapb_metamod(cstrike)"
)

cfg_pattern=r'(?ms)^def configure_yapb\(sid:int,quota:int,difficulty:int\):.*?(?=^def disable_yapb\(sid:int\):)'
cfg_match=re.search(cfg_pattern,s)
if not cfg_match:
    raise SystemExit('configure_yapb block not found')

new_cfg = r'''
def configure_yapb(sid:int,quota:int,difficulty:int):
    require_root()
    c=load_server(sid)
    path=Path(c['path'])
    cstrike=path/'cstrike'
    ycfg=cstrike/'addons/yapb/conf/yapb.cfg'

    if not ycfg.exists():
        return install_yapb(sid,quota,difficulty)

    quota=max(0,min(31,int(quota)))
    difficulty=max(0,min(4,int(difficulty)))

    meta_changed=_enable_yapb_metamod(cstrike)

    for key,value in [
        ('yb_quota',str(quota)),
        ('yb_quota_mode','fill'),
        ('yb_difficulty',str(difficulty)),
        ('yb_autovacate','1'),
        ('yb_autovacate_keep_slots','1'),
        ('yb_language','ru'),
        ('yb_graph_analyze_auto_start','1'),
        ('yb_graph_analyze_auto_save','1'),
    ]:
        _set_cfg_cvar(ycfg,key,value)

    normalize_permissions(path)

    c['bots_enabled']=1
    c['bots_quota']=quota
    c['bots_difficulty']=difficulty
    save_server(c)
    db_update_mode(sid,str(c.get('game_mode','classic')),1,quota,difficulty)

    restart={}
    rcon_results=[]

    if meta_changed:
        restart=service_action(sid,'restart')
    elif service_status(sid)=='active':
        for command in (
            f'yb_quota {quota}',
            'yb_quota_mode fill',
            f'yb_difficulty {difficulty}',
        ):
            try:
                rcon_results.append(query_rcon(
                    '127.0.0.1',
                    int(c['port']),
                    str(c.get('rcon_password','')),
                    command,
                    2.0
                ))
            except Exception as exc:
                rcon_results.append({'ok':False,'error':str(exc)})

    meta_file=cstrike/'addons/metamod/plugins.ini'
    meta_text=meta_file.read_text(encoding='utf-8',errors='ignore') if meta_file.exists() else ''
    meta_active=any(
        'addons/yapb/bin/yapb.so' in line.lower() and not line.lstrip().startswith(';')
        for line in meta_text.splitlines()
    )

    return {
        'ok':True,
        'id':sid,
        'bots':'YaPB',
        'quota':quota,
        'difficulty':difficulty,
        'bots_enabled':bool(meta_active),
        'metamod_active':bool(meta_active),
        'metamod_changed':bool(meta_changed),
        'restart':restart,
        'rcon':rcon_results,
        'warning':restart.get('warning','') if isinstance(restart,dict) else ''
    }
'''

s=s[:cfg_match.start()]+new_cfg.strip()+"\n\n"+s[cfg_match.end():]

p.write_text(s,encoding="utf-8")
print("controller source patched")
PY

echo "[2/7] Validate controller syntax BEFORE live install..."
python3 -m py_compile "$CTL"
echo "python syntax: OK"

echo "[3/7] Install validated controller as live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"
echo "live controller: OK"

echo "[4/7] Verify SQL admin list through current panel command..."
"$LIVE" admin-list "$SID"

echo "[5/7] Repair YaPB activation/config on server #$SID..."
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
QUOTA="9"
DIFF="3"
if [[ -f "$STATE" ]]; then
  read -r QUOTA DIFF < <(python3 - "$STATE" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
    print(int(d.get('bots_quota',9)),int(d.get('bots_difficulty',3)))
except Exception:
    print(9,3)
PY
)
fi

"$LIVE" bots-config "$SID" --quota "$QUOTA" --difficulty "$DIFF"

echo "[6/7] Verify YaPB is actually loaded..."
META_OUT="$("$LIVE" rcon "$SID" "meta list" 2>/dev/null || true)"
echo "$META_OUT"

if ! echo "$META_OUT" | grep -qi "YaPB"; then
    echo "[WARN] YaPB not visible yet; restarting once..."
    systemctl restart "hyper-cs16@${SID}.service"
    sleep 3
    META_OUT="$("$LIVE" rcon "$SID" "meta list" 2>/dev/null || true)"
    echo "$META_OUT"
fi

if ! echo "$META_OUT" | grep -qi "YaPB"; then
    echo "[ERROR] YaPB still is not loaded. Current metamod/plugins.ini:"
    cat "/srv/hyper-cs16/servers/${SID}/cstrike/addons/metamod/plugins.ini" || true
    exit 4
fi

echo "[7/7] Push quota immediately and show final status..."
"$LIVE" rcon "$SID" "yb_quota $QUOTA" || true
"$LIVE" rcon "$SID" "yb_quota_mode fill" || true
"$LIVE" rcon "$SID" "yb_difficulty $DIFF" || true
"$LIVE" status "$SID" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE PANEL ADMINS + BOTS v33"
echo "================================================================"
echo "Admins UI: existing panel UI, now backed by MySQL admins"
echo "admin-list/save/delete: SQL"
echo "amx_reloadadmins: automatic"
echo "YaPB: active in Metamod"
echo "bots-config: returns bots_enabled=true correctly"
echo "index.php: NOT MODIFIED"
echo "FastDL/nginx/AMXX plugins: NOT MODIFIED"
echo "Backup: $BACKUP"
echo "================================================================"
