#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
INDEX="$ROOT/cs16-panel/public/index.php"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-sql-admin-panel-v31-${STAMP}"
fail(){ echo "[ERROR] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"
[[ -f "$INDEX" ]] || fail "missing $INDEX"
mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
cp -a "$INDEX" "$BACKUP/index.php.before"
echo "================================================================"
echo " HYPER-HOST SQL ADMIN PANEL v31"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Game/FastDL/nginx/plugins: NOT MODIFIED"
echo "================================================================"

echo "[1/6] Patch controller..."
python3 - "$CTL" <<'PY1'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
begin='# === HYPER-HOST SQL ADMIN MANAGER v31 BEGIN ==='; end='# === HYPER-HOST SQL ADMIN MANAGER v31 END ==='
if begin in s and end in s:
    a=s.index(begin); b=s.index(end,a)+len(end); s=s[:a]+s[b:]
block='''
# === HYPER-HOST SQL ADMIN MANAGER v31 BEGIN ===
def _sql_admin_connect(sid:int):
    c=load_server(sid)
    db_name=str(c.get('sql_db') or _server_sql_names(sid)[0])
    db_user=str(c.get('sql_user') or _server_sql_names(sid)[1])
    pw=str(c.get('sql_password') or '')
    if not pw: raise RuntimeError('SQL сервера не настроен. Сначала подключи SQL на странице SQL / Статистика.')
    try:
        import pymysql
        con=pymysql.connect(host='127.0.0.1',port=3306,user=db_user,password=pw,database=db_name,charset='utf8mb4',autocommit=True,cursorclass=pymysql.cursors.DictCursor,connect_timeout=5)
        return c,con,db_name
    except Exception as exc:
        raise RuntimeError('Не удалось подключиться к SQL сервера: '+str(exc))

def _sql_admin_schema(cur):
    cur.execute("SHOW TABLES LIKE 'admins'")
    if cur.fetchone() is None:
        cur.execute("CREATE TABLE `admins` (`id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, `auth` VARCHAR(96) NOT NULL, `password` VARCHAR(96) NOT NULL DEFAULT '', `access` VARCHAR(32) NOT NULL DEFAULT '', `flags` VARCHAR(32) NOT NULL DEFAULT '', PRIMARY KEY (`id`), UNIQUE KEY `uq_admins_auth` (`auth`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci")
    cur.execute("SHOW COLUMNS FROM `admins`")
    cols=[str(r.get('Field') or '') for r in cur.fetchall()]; low={x.lower():x for x in cols}
    def pick(*names):
        for n in names:
            if n.lower() in low: return low[n.lower()]
        return ''
    schema={'id':pick('id','admin_id'),'identity':pick('auth','identity','steamid','steam_id','steam','nick','nickname','name'),'password':pick('password','passwd','pass','pw'),'access':pick('access','access_flags','permissions','privileges'),'flags':pick('flags','auth_flags','account_flags')}
    missing=[k for k in ('identity','access','flags') if not schema[k]]
    if missing: raise RuntimeError('Таблица admins имеет неподдерживаемую структуру. Колонки: '+', '.join(cols)+'. Не найдены: '+', '.join(missing))
    return schema,cols

def _sql_qcol(name:str)->str:
    if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',name or ''): raise RuntimeError('Некорректное имя SQL-колонки')
    return '`'+name+'`'

def _sql_admin_auth_type(identity:str,flags:str)->str:
    fl=(flags or '').lower()
    if 'c' in fl or STEAM_ID_RE.fullmatch(identity or ''): return 'steamid'
    if 'd' in fl: return 'ip'
    try: ipaddress.ip_address(identity or ''); return 'ip'
    except Exception: return 'name'

def sql_admins_list(sid:int):
    c,con,db_name=_sql_admin_connect(sid)
    try:
        with con.cursor() as cur:
            schema,cols=_sql_admin_schema(cur); order=_sql_qcol(schema['id']) if schema['id'] else _sql_qcol(schema['identity']); cur.execute('SELECT * FROM `admins` ORDER BY '+order+' ASC'); raw=cur.fetchall()
        rows=[]
        for r in raw:
            identity=str(r.get(schema['identity']) or ''); password=str(r.get(schema['password']) or '') if schema['password'] else ''; access=str(r.get(schema['access']) or '').lower(); flags=str(r.get(schema['flags']) or '').lower(); key=str(r.get(schema['id'])) if schema['id'] and r.get(schema['id']) is not None else identity
            rows.append({'key':key,'id':r.get(schema['id']) if schema['id'] else None,'identity':identity,'auth':identity,'auth_type':_sql_admin_auth_type(identity,flags),'has_password':bool(password),'access_flags':access,'access':access,'auth_flags':flags,'flags':flags,'access_labels':[AMXX_ACCESS_LABELS.get(x,x) for x in access if x in AMXX_ACCESS_LABELS]})
        return {'ok':True,'id':sid,'database':db_name,'table':'admins','admins':rows,'rows':rows,'columns':cols,'schema':schema,'password_field':'_pw'}
    finally: con.close()

def sql_admins_save(sid:int,payload:dict):
    require_root(); c,con,db_name=_sql_admin_connect(sid)
    auth_type=str(payload.get('auth_type') or 'steamid').lower(); identity=_validate_admin_identity(str(payload.get('identity') or payload.get('auth') or ''),auth_type); access=_normalize_access_flags(str(payload.get('access_flags') or payload.get('access') or '')); password=str(payload.get('password') or ''); generate=bool(payload.get('generate_password',False)); edit_key=str(payload.get('key') or payload.get('edit_key') or ''); original=str(payload.get('original_identity') or '')
    if any(ch in password for ch in ['"','\r','\n']) or len(password)>96: raise RuntimeError('Некорректный пароль администратора')
    if generate: password=secrets.token_urlsafe(12).replace('-','A').replace('_','B')[:16]
    try:
        with con.cursor() as cur:
            schema,cols=_sql_admin_schema(cur); qi=_sql_qcol(schema['identity']); qid=_sql_qcol(schema['id']) if schema['id'] else ''; existing=None
            if edit_key:
                if schema['id'] and edit_key.isdigit(): cur.execute('SELECT * FROM `admins` WHERE '+qid+'=%s LIMIT 1',(int(edit_key),))
                else: cur.execute('SELECT * FROM `admins` WHERE LOWER('+qi+')=LOWER(%s) LIMIT 1',(original or edit_key,))
                existing=cur.fetchone()
                if existing is None: raise RuntimeError('Администратор уже изменён или удалён. Обнови страницу.')
            if not password and existing is not None and schema['password']: password=str(existing.get(schema['password']) or '')
            if auth_type=='name' and not password: raise RuntimeError('Для авторизации по нику нужен пароль')
            auth_flags='ca' if auth_type=='steamid' and password else 'ce' if auth_type=='steamid' else 'da' if auth_type=='ip' and password else 'de' if auth_type=='ip' else 'a'
            if existing is not None and schema['id']: cur.execute('SELECT 1 FROM `admins` WHERE LOWER('+qi+')=LOWER(%s) AND '+qid+'<>%s LIMIT 1',(identity,existing.get(schema['id'])))
            elif existing is not None: cur.execute('SELECT 1 FROM `admins` WHERE LOWER('+qi+')=LOWER(%s) AND LOWER('+qi+')<>LOWER(%s) LIMIT 1',(identity,str(existing.get(schema['identity']) or '')))
            else: cur.execute('SELECT 1 FROM `admins` WHERE LOWER('+qi+')=LOWER(%s) LIMIT 1',(identity,))
            if cur.fetchone(): raise RuntimeError('Администратор '+identity+' уже существует')
            values={schema['identity']:identity,schema['access']:access,schema['flags']:auth_flags}
            if schema['password']: values[schema['password']]=password
            if existing is not None:
                sets=', '.join(_sql_qcol(k)+'=%s' for k in values); vals=list(values.values())
                if schema['id']: vals.append(existing.get(schema['id'])); cur.execute('UPDATE `admins` SET '+sets+' WHERE '+qid+'=%s',tuple(vals)); out_key=str(existing.get(schema['id']))
                else: old_identity=str(existing.get(schema['identity']) or ''); vals.append(old_identity); cur.execute('UPDATE `admins` SET '+sets+' WHERE LOWER('+qi+')=LOWER(%s)',tuple(vals)); out_key=identity
            else:
                names=list(values); cur.execute('INSERT INTO `admins` ('+', '.join(_sql_qcol(k) for k in names)+') VALUES ('+','.join(['%s']*len(names))+')',tuple(values[k] for k in names)); out_key=str(cur.lastrowid) if schema['id'] and cur.lastrowid else identity
        reload=_reload_amxx_admins(c)
        return {'ok':True,'id':sid,'database':db_name,'table':'admins','key':out_key,'identity':identity,'auth_type':auth_type,'access_flags':access,'auth_flags':auth_flags,'has_password':bool(password),'generated_password':password if generate else '','client_command':f'setinfo _pw "{password}"' if password else '','reload':reload}
    finally: con.close()

def sql_admins_delete(sid:int,key:str):
    require_root(); c,con,db_name=_sql_admin_connect(sid)
    try:
        with con.cursor() as cur:
            schema,cols=_sql_admin_schema(cur); qi=_sql_qcol(schema['identity'])
            if schema['id'] and str(key).isdigit():
                qid=_sql_qcol(schema['id']); cur.execute('SELECT * FROM `admins` WHERE '+qid+'=%s LIMIT 1',(int(key),)); row=cur.fetchone()
                if not row: raise RuntimeError('Администратор не найден')
                removed=str(row.get(schema['identity']) or ''); cur.execute('DELETE FROM `admins` WHERE '+qid+'=%s',(int(key),))
            else:
                cur.execute('SELECT * FROM `admins` WHERE LOWER('+qi+')=LOWER(%s) LIMIT 1',(str(key),)); row=cur.fetchone()
                if not row: raise RuntimeError('Администратор не найден')
                removed=str(row.get(schema['identity']) or ''); cur.execute('DELETE FROM `admins` WHERE LOWER('+qi+')=LOWER(%s)',(removed,))
        reload=_reload_amxx_admins(c); return {'ok':True,'id':sid,'database':db_name,'removed':removed,'reload':reload}
    finally: con.close()
# === HYPER-HOST SQL ADMIN MANAGER v31 END ===
'''
anchor='def server_config_set(args):'
if anchor not in s: raise SystemExit('controller anchor not found')
s=s.replace(anchor,block+'\n\n'+anchor,1)
pa="q=sp.add_parser('admin-delete'); q.add_argument('id',type=int); q.add_argument('index',type=int)"
if pa not in s: raise SystemExit('parser anchor not found')
s=s.replace(pa,pa+"\n    q=sp.add_parser('sql-admins-list'); q.add_argument('id',type=int)\n    q=sp.add_parser('sql-admins-save'); q.add_argument('id',type=int)\n    q=sp.add_parser('sql-admins-delete'); q.add_argument('id',type=int); q.add_argument('key')",1)
da="elif args.cmd=='admin-delete': result=admin_delete(args.id,args.index)"
if da not in s: raise SystemExit('dispatcher anchor not found')
s=s.replace(da,da+"\n        elif args.cmd=='sql-admins-list': result=sql_admins_list(args.id)\n        elif args.cmd=='sql-admins-save':\n            raw=sys.stdin.buffer.read(128*1024+1)\n            if len(raw)>128*1024: raise RuntimeError('Admin payload is too large')\n            try: payload=json.loads(raw.decode('utf-8','replace') or '{}')\n            except Exception: raise RuntimeError('Invalid admin payload')\n            if not isinstance(payload,dict): raise RuntimeError('Invalid admin payload')\n            result=sql_admins_save(args.id,payload)\n        elif args.cmd=='sql-admins-delete': result=sql_admins_delete(args.id,args.key)",1)
p.write_text(s,encoding='utf-8')
print('controller patched')
PY1

echo "[2/6] Patch panel UI..."
python3 - "$INDEX" <<'PY2'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
# POST handlers
anchor="""        if($action==='sql_provision'){
            $id=(int)($_POST['id']??0);require_perm('sql.manage',$id);server_row($id);$r=ctl(['sql-provision',$id],120);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось подключить SQL к серверу'));audit('sql_provision',(string)($r['database']??''),$id);flash('SQL подключён. AMXX sql.cfg обновлён: '.(string)($r['database']??'').' / '.(string)($r['user']??''));redirect('/?page=sql&server_id='.$id);
        }"""
if anchor not in s: raise SystemExit('index POST anchor not found')
handlers=anchor+"""
        if($action==='sql_admin_save'){
            $id=(int)($_POST['id']??0);require_perm('server.admins',$id);server_row($id);$identity=trim((string)($_POST['identity']??''));$authType=(string)($_POST['auth_type']??'steamid');$access=(string)($_POST['access_flags']??'');if($access===''&&is_array($_POST['access_flags_arr']??null))$access=implode('',array_map('strval',$_POST['access_flags_arr']));$password=(string)($_POST['password']??'');$payload=['key'=>(string)($_POST['key']??''),'original_identity'=>(string)($_POST['original_identity']??''),'identity'=>$identity,'auth_type'=>$authType,'access_flags'=>$access,'password'=>$password,'generate_password'=>isset($_POST['generate_password'])];$r=ctl(['sql-admins-save',$id],30,json_encode($payload,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES));if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось сохранить администратора в SQL'));$msg='Администратор '.$identity.' сохранён в SQL.';if(!empty($r['generated_password']))$msg.="\nСгенерированный пароль: ".(string)$r['generated_password'];if(!empty($r['client_command']))$msg.="\nКоманда игроку: ".(string)$r['client_command'];if(isset($r['reload']['ok'])&&!$r['reload']['ok'])$msg.="\nЗапись сохранена, но amx_reloadadmins не ответил. Применится после смены карты/рестарта.";audit('sql_admin_save',$identity,$id);flash($msg);redirect('/?page=admins&server_id='.$id);
        }
        if($action==='sql_admin_delete'){
            $id=(int)($_POST['id']??0);require_perm('server.admins',$id);server_row($id);$key=(string)($_POST['key']??'');if($key==='')throw new RuntimeException('Не передан администратор для удаления');$r=ctl(['sql-admins-delete',$id,$key],30);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось удалить администратора из SQL'));audit('sql_admin_delete',(string)($r['removed']??$key),$id);flash('Администратор '.(string)($r['removed']??$key).' удалён из SQL.');redirect('/?page=admins&server_id='.$id);
        }"""
s=s.replace(anchor,handlers,1)
old="$titles=['dashboard'=>'Игровые серверы','server'=>'Управление сервером','create'=>'Новый сервер','settings'=>'Настройки панели','audit'=>'История действий','notifications'=>'События и Telegram','users'=>'Пользователи и роли','resources'=>'Ресурсы','billing'=>'Биллинг и аренда','api'=>'API панели','reports'=>'Жалобы игроков','sql'=>'SQL и статистика'];"
new="$titles=['dashboard'=>'Игровые серверы','server'=>'Управление сервером','create'=>'Новый сервер','settings'=>'Настройки панели','audit'=>'История действий','notifications'=>'События и Telegram','users'=>'Пользователи и роли','resources'=>'Ресурсы','billing'=>'Биллинг и аренда','api'=>'API панели','reports'=>'Жалобы игроков','sql'=>'SQL и статистика','admins'=>'Администраторы сервера'];"
if old not in s: raise SystemExit('title anchor not found')
s=s.replace(old,new,1)
oldnav="<?php if(can_perm('sql.view')):?><a class=\"<?=$page==='sql'?'active':''?>\" href=\"/?page=sql\"><i class=\"fa-solid fa-database\"></i>SQL / Статистика</a><?php endif;?>"
newnav="<?php if(can_perm('server.admins')):?><a class=\"<?=$page==='admins'?'active':''?>\" href=\"/?page=admins\"><i class=\"fa-solid fa-user-shield\"></i>Админы серверов</a><?php endif;?>"+oldnav
if oldnav not in s: raise SystemExit('sidebar anchor not found')
s=s.replace(oldnav,newnav,1)
tab="<?php if(can_perm('sql.view',$id)):?><li><a class=\"server-tab-link\" href=\"/?page=sql&amp;server_id=<?=$id?>\"><i class=\"fa-solid fa-database me-1\"></i>SQL</a></li><?php endif;?>"
tabnew="<?php if(can_perm('server.admins',$id)):?><li><a class=\"server-tab-link\" href=\"/?page=admins&amp;server_id=<?=$id?>\"><i class=\"fa-solid fa-user-shield me-1\"></i>Админы</a></li><?php endif;?>"+tab
if tab not in s: raise SystemExit('server tab anchor not found')
s=s.replace(tab,tabnew,1)
page_anchor="<?php elseif($page==='sql'):"
if page_anchor not in s: raise SystemExit('SQL page anchor not found')
page_block=r'''<?php elseif($page==='admins'):
$adminSid=max(0,(int)($_GET['server_id']??0));if($adminSid<1&&$servers)$adminSid=(int)$servers[0]['id'];if($adminSid>0){require_perm('server.admins',$adminSid);server_row($adminSid);}$adminData=['ok'=>false,'admins'=>[],'error'=>'Выбери сервер'];if($adminSid>0){try{$adminData=ctl(['sql-admins-list',$adminSid],30);}catch(Throwable $e){$adminData=['ok'=>false,'admins'=>[],'error'=>$e->getMessage()];}}$adminRows=is_array($adminData['admins']??null)?$adminData['admins']:[];$accessMap=['a'=>'Иммунитет','b'=>'Резервный слот','c'=>'Kick','d'=>'Ban','e'=>'Slay / Slap','f'=>'Смена карты','g'=>'CVAR','h'=>'Конфиги','i'=>'Чат','j'=>'Голосования','k'=>'sv_password','l'=>'RCON','m'=>'Custom A','n'=>'Custom B','o'=>'Custom C','p'=>'Custom D','q'=>'Custom E','r'=>'Custom F','s'=>'Custom G','t'=>'Custom H','u'=>'AMXX меню'];?>
<section class="panel-card mb-3"><div class="panel-head"><div><h2>Администраторы сервера</h2><p>Источник: MySQL <code>admins</code>. После изменений выполняется <code>amx_reloadadmins</code>.</p></div><?php if(!empty($adminData['ok'])):?><span class="feature-chip on">SQL CONNECTED</span><?php else:?><span class="feature-chip off">SQL ERROR</span><?php endif;?></div><form method="get" class="d-flex flex-wrap gap-2 align-items-end mb-3"><input type="hidden" name="page" value="admins"><label class="flex-grow-1"><span>Сервер</span><select class="form-select" name="server_id" onchange="this.form.submit()"><?php foreach($servers as $sv):if(!can_perm('server.admins',(int)$sv['id']))continue;?><option value="<?=(int)$sv['id']?>" <?=((int)$sv['id']===$adminSid?'selected':'')?>>#<?=(int)$sv['id']?> — <?=e($sv['name'])?> · <?=e($sv['hostname'])?></option><?php endforeach;?></select></label></form><?php if(empty($adminData['ok'])):?><div class="alert alert-danger"><b>SQL ERROR</b><br><?=e(ctl_error($adminData,'Не удалось прочитать администраторов'))?></div><?php else:?><div class="readonly-settings"><div><small>Database</small><b><?=e((string)($adminData['database']??'—'))?></b></div><div><small>Table</small><b><?=e((string)($adminData['table']??'admins'))?></b></div><div><small>Админов</small><b><?=count($adminRows)?></b></div><div><small>Password field</small><b><?=e((string)($adminData['password_field']??'_pw'))?></b></div></div><?php endif;?></section>
<?php if($adminSid>0&&!empty($adminData['ok'])):?><section class="panel-card mb-3"><div class="panel-head"><div><h2>Добавить администратора</h2><p>SteamID рекомендуется. Для SteamID пароль не обязателен.</p></div></div><form method="post" class="vstack gap-3"><?=csrf_field()?><input type="hidden" name="action" value="sql_admin_save"><input type="hidden" name="id" value="<?=$adminSid?>"><div class="row g-3"><label class="col-md-3"><span>Авторизация</span><select class="form-select" name="auth_type"><option value="steamid">SteamID</option><option value="ip">IP</option><option value="name">Ник + пароль</option></select></label><label class="col-md-5"><span>SteamID / IP / Ник</span><input class="form-control" name="identity" placeholder="STEAM_0:1:123456" required></label><label class="col-md-4"><span>Пароль</span><input class="form-control" name="password" autocomplete="new-password" placeholder="Не нужен для SteamID"></label></div><div><span class="d-block mb-2">Права AMXX</span><div class="d-flex flex-wrap gap-2"><?php foreach($accessMap as $flag=>$label):?><label class="feature-chip"><input class="form-check-input me-1" type="checkbox" name="access_flags_arr[]" value="<?=e($flag)?>"> <b><?=e($flag)?></b> <?=e($label)?></label><?php endforeach;?></div></div><div class="d-flex flex-wrap gap-2"><button class="btn btn-primary"><i class="fa-solid fa-user-plus me-2"></i>Добавить администратора</button><label class="btn btn-soft mb-0"><input class="form-check-input me-2" type="checkbox" name="generate_password" value="1">Сгенерировать пароль</label></div></form></section>
<section class="panel-card"><div class="panel-head"><div><h2>Текущие администраторы</h2><p>Реальные строки SQL, не <code>users.ini</code>.</p></div></div><div class="table-responsive"><table class="table hh-table align-middle"><thead><tr><th>Тип</th><th>Идентификатор</th><th>Права</th><th>Пароль</th><th>Auth flags</th><th></th></tr></thead><tbody><?php foreach($adminRows as $a):?><tr><td><span class="feature-chip on"><?=e(strtoupper((string)($a['auth_type']??'unknown')))?></span></td><td><b><?=e((string)($a['identity']??''))?></b></td><td><code><?=e((string)($a['access_flags']??''))?></code><small class="d-block text-secondary"><?=e(implode(', ',(array)($a['access_labels']??[])))?></small></td><td><?=!empty($a['has_password'])?'<span class="badge text-bg-warning">ЕСТЬ</span>':'<span class="badge text-bg-secondary">НЕТ</span>'?></td><td><code><?=e((string)($a['auth_flags']??''))?></code></td><td class="text-end"><div class="d-flex gap-2 justify-content-end"><button type="button" class="btn btn-soft btn-sm" data-bs-toggle="collapse" data-bs-target="#editAdmin<?=md5((string)($a['key']??''))?>">Изменить</button><form method="post" onsubmit="return confirm('Удалить администратора?')"><?=csrf_field()?><input type="hidden" name="action" value="sql_admin_delete"><input type="hidden" name="id" value="<?=$adminSid?>"><input type="hidden" name="key" value="<?=e((string)($a['key']??''))?>"><button class="btn btn-danger btn-sm">Удалить</button></form></div></td></tr><tr class="collapse" id="editAdmin<?=md5((string)($a['key']??''))?>"><td colspan="6"><form method="post" class="p-3 border rounded vstack gap-3"><?=csrf_field()?><input type="hidden" name="action" value="sql_admin_save"><input type="hidden" name="id" value="<?=$adminSid?>"><input type="hidden" name="key" value="<?=e((string)($a['key']??''))?>"><input type="hidden" name="original_identity" value="<?=e((string)($a['identity']??''))?>"><div class="row g-3"><label class="col-md-3"><span>Тип</span><select class="form-select" name="auth_type"><?php foreach(['steamid'=>'SteamID','ip'=>'IP','name'=>'Ник'] as $v=>$l):?><option value="<?=$v?>" <?=((string)($a['auth_type']??'')===$v?'selected':'')?>><?=$l?></option><?php endforeach;?></select></label><label class="col-md-5"><span>Идентификатор</span><input class="form-control" name="identity" value="<?=e((string)($a['identity']??''))?>" required></label><label class="col-md-4"><span>Новый пароль</span><input class="form-control" name="password" autocomplete="new-password" placeholder="Пусто = оставить текущий"></label></div><label><span>Права</span><input class="form-control font-monospace" name="access_flags" value="<?=e((string)($a['access_flags']??''))?>" pattern="[a-uA-U]+" required></label><div class="d-flex gap-2"><button class="btn btn-primary">Сохранить</button><label class="btn btn-soft mb-0"><input class="form-check-input me-2" type="checkbox" name="generate_password" value="1">Новый случайный пароль</label></div></form></td></tr><?php endforeach;?><?php if(!$adminRows):?><tr><td colspan="6" class="text-center text-secondary py-4">В SQL пока нет администраторов.</td></tr><?php endif;?></tbody></table></div></section><?php endif;?>
'''
s=s.replace(page_anchor,page_block+'\n'+page_anchor,1)
p.write_text(s,encoding='utf-8'); print('index.php patched')
PY2

echo "[3/6] Syntax checks..."
python3 -m py_compile "$CTL"
php -l "$INDEX"

echo "[4/6] Install controller live..."
install -m 0755 "$CTL" "$LIVE"

echo "[5/6] Verify commands..."
HELP="$("$LIVE" --help 2>&1 || true)"
echo "$HELP" | grep -q "sql-admins-list" || fail "sql-admins-list missing"
echo "$HELP" | grep -q "sql-admins-save" || fail "sql-admins-save missing"
echo "$HELP" | grep -q "sql-admins-delete" || fail "sql-admins-delete missing"
echo "SQL admin commands: OK"

echo "[6/6] Read current SQL admins..."
"$LIVE" sql-admins-list "$SID"

echo
echo "================================================================"
echo " [SUCCESS] SQL ADMIN PANEL v31"
echo "================================================================"
echo " Open: /?page=admins&server_id=$SID"
echo " MySQL admins: list/add/edit/delete"
echo " amx_reloadadmins: automatic"
echo " users.ini: NOT USED by this page"
echo " Game/FastDL/nginx/plugins: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
