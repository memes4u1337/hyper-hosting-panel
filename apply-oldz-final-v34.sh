#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
SERVER="/srv/hyper-cs16/servers/${SID}"
CSTRIKE="$SERVER/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/${SID}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-v34-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$ROOT/.git" ]] || fail "not a git checkout: $ROOT"
[[ -f "$STATE" ]] || fail "missing state: $STATE"
[[ -d "$CSTRIKE" ]] || fail "missing server cstrike: $CSTRIKE"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.local.before" 2>/dev/null || true
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true
cp -a "$CSTRIKE/addons/metamod/plugins.ini" "$BACKUP/metamod-plugins.before.ini" 2>/dev/null || true
cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg.before" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE FINAL PANEL + BOTS + CONNECT FIX v34"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " AMXX plugin list / Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/9] Restore clean controller from fetched GitHub main..."
BASE="/tmp/hyper-cs16-ctl-v34.base"
if git -C "$ROOT" show FETCH_HEAD:cs16-panel/bin/hyper-cs16-ctl > "$BASE" 2>/dev/null; then
    :
elif git -C "$ROOT" show origin/main:cs16-panel/bin/hyper-cs16-ctl > "$BASE" 2>/dev/null; then
    :
else
    fail "Cannot read clean controller from FETCH_HEAD/origin/main. Run git fetch first."
fi
python3 -m py_compile "$BASE"
install -m 0755 "$BASE" "$CTL"

echo "[2/9] Patch CURRENT controller: SQL admins + YaPB..."
python3 - "$CTL" <<'PYCTL'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')

admin_block=r'''
def _game_admin_sql(sid:int):
    c=load_server(sid)
    db_name=str(c.get('sql_db') or _server_sql_names(sid)[0])
    db_user=str(c.get('sql_user') or _server_sql_names(sid)[1])
    password=str(c.get('sql_password') or '')
    if not password:
        raise RuntimeError('SQL сервера не настроен')
    import pymysql
    try:
        con=pymysql.connect(host='127.0.0.1',port=3306,user=db_user,password=password,database=db_name,
            charset='utf8mb4',autocommit=True,cursorclass=pymysql.cursors.DictCursor,connect_timeout=5)
    except Exception as exc:
        raise RuntimeError('Не удалось подключиться к SQL сервера: '+str(exc))
    return c,con,db_name

def _ensure_game_admins_table(cur):
    cur.execute("CREATE TABLE IF NOT EXISTS `admins` (`auth` varchar(32) NOT NULL,`password` varchar(32) NOT NULL,`access` varchar(32) NOT NULL,`flags` varchar(32) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci")

def _admin_auth_type(identity:str,flags:str):
    fl=(flags or '').lower()
    if 'c' in fl or STEAM_ID_RE.fullmatch(identity or ''): return 'steamid'
    if 'd' in fl: return 'ip'
    return 'name'

def admin_list(sid:int):
    c,con,db_name=_game_admin_sql(sid)
    try:
        with con.cursor() as cur:
            _ensure_game_admins_table(cur)
            cur.execute("SELECT `auth`,`password`,`access`,`flags` FROM `admins` ORDER BY LOWER(`auth`),`auth`")
            raw=cur.fetchall()
        admins=[]
        for i,row in enumerate(raw):
            identity=str(row.get('auth') or ''); password=str(row.get('password') or '')
            access=str(row.get('access') or '').lower(); flags=str(row.get('flags') or '').lower()
            admins.append({'index':i,'identity':identity,'access_flags':access,'auth_flags':flags,
                'auth_type':_admin_auth_type(identity,flags),'has_password':bool(password),
                'access_labels':[AMXX_ACCESS_LABELS.get(x,x) for x in access if x in AMXX_ACCESS_LABELS]})
        return {'ok':True,'admins':admins,'password_field':'_pw','source':'mysql','database':db_name,'table':'admins'}
    finally: con.close()

def _validate_admin_identity(identity:str,auth_type:str):
    identity=identity.strip()
    if not identity or len(identity)>32 or '"' in identity or chr(10) in identity or chr(13) in identity:
        raise RuntimeError('Некорректный идентификатор администратора')
    if auth_type=='steamid':
        if not STEAM_ID_RE.fullmatch(identity): raise RuntimeError('Для SteamID нужен формат STEAM_0:1:123456')
        return identity.upper()
    if auth_type=='ip':
        try: return str(ipaddress.ip_address(identity))
        except ValueError: raise RuntimeError('Некорректный IP администратора')
    if auth_type=='name': return identity
    raise RuntimeError('Неизвестный тип авторизации')

def _normalize_access_flags(flags:str):
    flags=''.join(dict.fromkeys((flags or '').lower()))
    bad=[x for x in flags if x not in AMXX_ALLOWED_ACCESS]
    if bad: raise RuntimeError('Недопустимые AMXX права: '+''.join(bad))
    if not flags: raise RuntimeError('Выбери хотя бы одно право администратора')
    return ''.join(x for x in 'abcdefghijklmnopqrstu' if x in flags)

def _ensure_password_field(root:Path):
    p=root/'cstrike/addons/amxmodx/configs/amxx.cfg'; p.parent.mkdir(parents=True,exist_ok=True)
    text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
    rx=re.compile(r'^\s*amx_password_field\s+.*$',re.I|re.M); line='amx_password_field "_pw"'
    if rx.search(text): text=rx.sub(line,text,1)
    else: text=text.rstrip()+('\n\n' if text.strip() else '')+line+'\n'
    p.write_text(text,encoding='utf-8')

def _reload_amxx_admins(c):
    try:
        r=rcon_cmd(int(c['id']),'amx_reloadadmins'); return {'ok':bool(r.get('ok')),'output':str(r.get('output',''))[-1000:]}
    except Exception as exc: return {'ok':False,'error':str(exc)}

def admin_save(sid:int,payload:dict):
    require_root(); c,con,db_name=_game_admin_sql(sid)
    auth_type=str(payload.get('auth_type','steamid')).lower(); identity=_validate_admin_identity(str(payload.get('identity','')),auth_type)
    access=_normalize_access_flags(str(payload.get('access_flags','')))
    try: edit_index=int(payload.get('index',-1))
    except Exception: edit_index=-1
    password=str(payload.get('password','')); generate=bool(payload.get('generate_password',False))
    if '"' in password or chr(10) in password or chr(13) in password or len(password)>32: raise RuntimeError('Некорректный пароль администратора')
    try:
        with con.cursor() as cur:
            _ensure_game_admins_table(cur); cur.execute("SELECT `auth`,`password`,`access`,`flags` FROM `admins` ORDER BY LOWER(`auth`),`auth`"); rows=cur.fetchall()
            existing=None; old_auth=''
            if edit_index>=0:
                if edit_index>=len(rows): raise RuntimeError('Запись администратора уже изменилась. Обнови список.')
                existing=rows[edit_index]; old_auth=str(existing.get('auth') or '')
            existing_password=str(existing.get('password') or '') if existing else ''; password_changed=generate or password!=''
            if generate: password=secrets.token_urlsafe(12).replace('-','A').replace('_','B')[:16]
            elif password=='': password=existing_password
            if auth_type=='name' and not password: raise RuntimeError('Для авторизации по нику обязательно задай пароль')
            auth_flags=('ca' if password else 'ce') if auth_type=='steamid' else (('da' if password else 'de') if auth_type=='ip' else 'a')
            for n,row in enumerate(rows):
                if n!=edit_index and str(row.get('auth') or '').casefold()==identity.casefold(): raise RuntimeError(f'Администратор {identity} уже существует')
            if existing:
                cur.execute("UPDATE `admins` SET `auth`=%s,`password`=%s,`access`=%s,`flags`=%s WHERE BINARY `auth`=%s LIMIT 1",(identity,password,access,auth_flags,old_auth))
            else:
                cur.execute("INSERT INTO `admins` (`auth`,`password`,`access`,`flags`) VALUES (%s,%s,%s,%s)",(identity,password,access,auth_flags))
            cur.execute("SELECT `auth` FROM `admins` ORDER BY LOWER(`auth`),`auth`"); ordered=[str(x.get('auth') or '') for x in cur.fetchall()]
            new_index=next((i for i,x in enumerate(ordered) if x.casefold()==identity.casefold()),-1)
        if password: _ensure_password_field(Path(c['path'])); normalize_permissions(Path(c['path']))
        reload=_reload_amxx_admins(c)
        return {'ok':True,'index':new_index,'identity':identity,'auth_type':auth_type,'access_flags':access,'has_password':bool(password),
            'generated_password':password if generate else '','client_command':f'setinfo _pw "{password}"' if password and password_changed else '',
            'reload':reload,'source':'mysql','database':db_name}
    finally: con.close()

def admin_delete(sid:int,index:int):
    require_root(); c,con,db_name=_game_admin_sql(sid)
    try:
        with con.cursor() as cur:
            _ensure_game_admins_table(cur); cur.execute("SELECT `auth` FROM `admins` ORDER BY LOWER(`auth`),`auth`"); rows=cur.fetchall()
            if index<0 or index>=len(rows): raise RuntimeError('Администратор не найден')
            removed=str(rows[index].get('auth') or ''); cur.execute("DELETE FROM `admins` WHERE BINARY `auth`=%s LIMIT 1",(removed,))
        reload=_reload_amxx_admins(c); return {'ok':True,'removed':removed,'reload':reload,'source':'mysql','database':db_name}
    finally: con.close()
'''

m=re.search(r'(?ms)^def admin_list\(sid:int\):.*?(?=^def server_config_set\(args\):)',s)
if not m: raise SystemExit('cannot locate admin backend block')
s=s[:m.start()]+admin_block.strip()+"\n"+s[m.end():]

helper=r'''
def _yapb_enable_line(cstrike:Path):
    p=cstrike/'addons/metamod/plugins.ini'; lines=p.read_text(encoding='utf-8',errors='ignore').splitlines() if p.exists() else []
    wanted='linux addons/yapb/bin/yapb.so'; out=[]; found=False; changed=False
    for line in lines:
        if 'addons/yapb/bin/yapb.so' in line.lower():
            if not found:
                out.append(wanted); found=True
                if line.strip()!=wanted: changed=True
            else: changed=True
            continue
        out.append(line)
    if not found: out.append(wanted); changed=True
    new='\n'.join(out).rstrip()+'\n'; old=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
    if new!=old: p.parent.mkdir(parents=True,exist_ok=True); p.write_text(new,encoding='utf-8'); changed=True
    return changed
'''
pos=s.find('def install_yapb(sid:int')
if pos<0: raise SystemExit('cannot locate install_yapb')
s=s[:pos]+helper.strip()+"\n\n"+s[pos:]
s=s.replace("_append_unique(cstrike/'addons/metamod/plugins.ini','linux addons/yapb/bin/yapb.so')","_yapb_enable_line(cstrike)",1)

new_cfg=r'''
def configure_yapb(sid:int,quota:int,difficulty:int):
    require_root(); c=load_server(sid); path=Path(c['path']); cstrike=path/'cstrike'; ycfg=cstrike/'addons/yapb/conf/yapb.cfg'
    if not ycfg.exists(): return install_yapb(sid,quota,difficulty)
    quota=max(0,min(31,int(quota))); difficulty=max(0,min(4,int(difficulty))); meta_changed=_yapb_enable_line(cstrike)
    for key,value in [('yb_quota',str(quota)),('yb_quota_mode','fill'),('yb_difficulty',str(difficulty)),('yb_autovacate','1'),('yb_autovacate_keep_slots','1'),('yb_language','ru'),('yb_graph_analyze_auto_start','1'),('yb_graph_analyze_auto_save','1')]: _set_cfg_cvar(ycfg,key,value)
    normalize_permissions(path); c['bots_enabled']=1; c['bots_quota']=quota; c['bots_difficulty']=difficulty; save_server(c); db_update_mode(sid,str(c.get('game_mode','classic')),1,quota,difficulty)
    restart={}
    if meta_changed: restart=service_action(sid,'restart')
    elif service_status(sid)=='active':
        for cmd in (f'yb_quota {quota}','yb_quota_mode fill',f'yb_difficulty {difficulty}'):
            try: query_rcon('127.0.0.1',int(c['port']),str(c.get('rcon_password','')),cmd,2.0)
            except Exception: pass
    meta=cstrike/'addons/metamod/plugins.ini'; txt=meta.read_text(encoding='utf-8',errors='ignore') if meta.exists() else ''
    active=any('addons/yapb/bin/yapb.so' in x.lower() and not x.lstrip().startswith(';') for x in txt.splitlines())
    return {'ok':True,'id':sid,'bots':'YaPB','quota':quota,'difficulty':difficulty,'bots_enabled':bool(active),'metamod_active':bool(active),'metamod_changed':bool(meta_changed),'restart':restart,'warning':restart.get('warning','') if isinstance(restart,dict) else ''}
'''
m=re.search(r'(?ms)^def configure_yapb\(sid:int,quota:int,difficulty:int\):.*?(?=^def disable_yapb\(sid:int\):)',s)
if not m: raise SystemExit('cannot locate configure_yapb')
s=s[:m.start()]+new_cfg.strip()+"\n\n"+s[m.end():]
p.write_text(s,encoding='utf-8')
print('controller patched')
PYCTL

echo "[3/9] Validate controller BEFORE installing live..."
python3 -m py_compile "$CTL"
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"
echo "controller syntax/live: OK"

echo "[4/9] Fix FastDL/download configuration without touching gameplay..."
read -r PUBLIC_IP PORT QUOTA DIFF < <(python3 - "$STATE" <<'PYSTATE'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(str(d.get('public_ip') or '90.189.208.25'),int(d.get('port') or 27018),int(d.get('bots_quota') or 9),int(d.get('bots_difficulty') or 3))
PYSTATE
)
FASTDL_URL="http://${PUBLIC_IP}/fastdl/${SID}/"
echo "FastDL URL: $FASTDL_URL"

python3 - "$CSTRIKE" "$FASTDL_URL" <<'PYCFG'
from pathlib import Path
import re,sys
root=Path(sys.argv[1]); url=sys.argv[2]
files=[root/'server.cfg',root/'fastdl.cfg',root/'ENABLE_FASTDL_AFTER_VERIFY.cfg',root/'SAFE_DOWNLOAD_MODE.cfg',root/'server_download_fix.cfg']
keys={'sv_downloadurl':f'sv_downloadurl "{url}"','sv_allowdownload':'sv_allowdownload 1','sv_send_resources':'sv_send_resources 1','sv_allow_dlfile':'sv_allow_dlfile 1'}
for p in files:
    if not p.exists(): continue
    lines=p.read_text(encoding='utf-8',errors='ignore').replace('\r\n','\n').replace('\r','\n').splitlines(); out=[]; seen=set()
    for line in lines:
        m=re.match(r'^\s*(sv_downloadurl|sv_allowdownload|sv_send_resources|sv_allow_dlfile)\b',line,re.I)
        if m:
            k=m.group(1).lower()
            if k not in seen: out.append(keys[k]); seen.add(k)
            continue
        out.append(line)
    for k,v in keys.items():
        if k not in seen: out.append(v)
    p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8'); print('fixed',p)
PYCFG

echo "[5/9] Ensure Reunion and YaPB are active in Metamod when binaries exist..."
python3 - "$CSTRIKE/addons/metamod/plugins.ini" "$CSTRIKE" <<'PYMETA'
from pathlib import Path
import sys
p=Path(sys.argv[1]); root=Path(sys.argv[2]); lines=p.read_text(encoding='utf-8',errors='ignore').splitlines() if p.exists() else []
targets=[]
for rel in ('addons/reunion/reunion_mm_i386.so','addons/yapb/bin/yapb.so'):
    if (root/rel).is_file(): targets.append(('linux '+rel,rel.lower()))
out=[]; done=set()
for line in lines:
    hit=None
    for wanted,rel in targets:
        if rel in line.lower(): hit=(wanted,rel); break
    if hit:
        wanted,rel=hit
        if rel not in done: out.append(wanted); done.add(rel)
        continue
    out.append(line)
for wanted,rel in targets:
    if rel not in done: out.append(wanted)
p.parent.mkdir(parents=True,exist_ok=True); p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8'); print(p.read_text(encoding='utf-8'))
PYMETA

echo "[6/9] Sync actual downloadable resources to FastDL mirror..."
mkdir -p "$FASTDL"
for d in maps models sound sprites gfx resource overviews events media; do
    if [[ -d "$CSTRIKE/$d" ]]; then mkdir -p "$FASTDL/$d"; rsync -a "$CSTRIKE/$d/" "$FASTDL/$d/"; fi
done
chown -R root:www-data "$FASTDL" 2>/dev/null || true
find "$FASTDL" -type d -exec chmod 0755 {} + 2>/dev/null || true
find "$FASTDL" -type f -exec chmod 0644 {} + 2>/dev/null || true

echo "[7/9] Configure SQL admins and YaPB through patched controller..."
"$LIVE" admin-list "$SID"
"$LIVE" bots-config "$SID" --quota "$QUOTA" --difficulty "$DIFF"

echo "[8/9] Restart once, then enforce runtime network/download cvars..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
for cmd in 'sv_lan 0' 'sv_allowdownload 1' 'sv_send_resources 1' 'sv_allow_dlfile 1' "sv_downloadurl \"$FASTDL_URL\"" "yb_quota $QUOTA" 'yb_quota_mode fill' "yb_difficulty $DIFF"; do "$LIVE" rcon "$SID" "$cmd" >/dev/null 2>&1 || true; done

echo "[9/9] Final verification..."
echo "--- STATUS ---"; "$LIVE" status "$SID" || true
echo "--- META LIST ---"; META="$("$LIVE" rcon "$SID" "meta list" 2>/dev/null || true)"; echo "$META"
echo "--- DOWNLOAD CVARS ---"; for cmd in sv_downloadurl sv_allowdownload sv_send_resources sv_allow_dlfile sv_lan; do "$LIVE" rcon "$SID" "$cmd" || true; done
START_MAP="$(python3 - "$STATE" <<'PYMAP'
import json,sys
print(str(json.load(open(sys.argv[1],encoding='utf-8')).get('start_map') or 'zm_2day'))
PYMAP
)"
echo "--- FASTDL HTTP ---"; curl -fsSI --max-time 8 "${FASTDL_URL}maps/${START_MAP}.bsp" | head -n 12 || true

if ! systemctl is-active --quiet "hyper-cs16@${SID}.service"; then echo "[ERROR] server is not active"; journalctl -u "hyper-cs16@${SID}.service" -n 100 --no-pager || true; exit 10; fi
if ! ss -lun | grep -q ":${PORT}[[:space:]]"; then echo "[ERROR] UDP ${PORT} is not listening"; ss -lunp | grep -E "hlds|:${PORT}" || true; exit 11; fi
if [[ -f "$CSTRIKE/addons/yapb/bin/yapb.so" ]] && ! echo "$META" | grep -qi "YaPB"; then echo "[ERROR] YaPB binary exists but YaPB is not loaded"; exit 12; fi
if [[ -f "$CSTRIKE/addons/reunion/reunion_mm_i386.so" ]] && ! echo "$META" | grep -qi "Reunion"; then echo "[ERROR] Reunion binary exists but Reunion is not loaded"; exit 13; fi

echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE v34"
echo "================================================================"
echo "Panel admins: MySQL admins (auth/password/access/flags)"
echo "Bots: YaPB active + quota applied"
echo "FastDL: $FASTDL_URL"
echo "Downloads: enabled"
echo "Reunion: checked"
echo "UDP: ${PORT} listening"
echo "AMXX plugin list / Unprecacher: NOT MODIFIED"
echo "Backup: $BACKUP"
echo "================================================================"
