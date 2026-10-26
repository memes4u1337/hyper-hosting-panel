#!/usr/bin/env bash
# HYPER-HOST CS2 v4 - AJAX admin + secure SFTP per instance
# Patch requires CS2 Shared Storage v3. Does not change existing CS1.6, CS2 game assets, SteamCMD or game services.
set -Eeuo pipefail
[[ ${EUID:-999} == 0 ]] || { echo '[ERROR] Run as root'; exit 1; }
for app in php python3 systemctl grep install cp chmod chown usermod passwd sshd; do
  if [[ $app == sshd ]]; then
    [[ -x /usr/sbin/sshd ]] || { echo '[ERROR] OpenSSH server not found. Install openssh-server first'; exit 1; }
  else command -v "$app" >/dev/null || { echo "[ERROR] Missing $app"; exit 1; };fi
done
[[ -f /etc/hyper-cs16/panel.php ]] || { echo '[ERROR] Missing HYPER-HOST panel.php'; exit 1; }
DOMAIN=$(php -r '$c=require "/etc/hyper-cs16/panel.php";echo $c["domain"]??"";')
[[ $DOMAIN =~ ^[a-zA-Z0-9.-]+$ ]] || { echo '[ERROR] Invalid domain'; exit 1; }
WEB="/var/www/hyper-host-sites/$DOMAIN/public_html"
PANEL="$WEB/cs2.php"
CTL=/usr/local/sbin/hyper-cs2-ctl
[[ -f $CTL && ! -L $CTL && -f $PANEL && ! -L $PANEL ]] || { echo '[ERROR] CS2 page/controller not found'; exit 1; }
grep -q 'def mount_overlay_unlocked' "$CTL" || { echo '[ERROR] Apply CS2 Shared Storage v3 before v4'; exit 1; }
[[ -e /srv/hyper-cs2/base && -d /srv/hyper-cs2/servers ]] || { echo '[ERROR] CS2 directories are missing'; exit 1; }
[[ -f /etc/ssh/sshd_config && ! -L /etc/ssh/sshd_config ]] || { echo '[ERROR] OpenSSH config missing or symlinked'; exit 1; }
/usr/sbin/sshd -t || { echo '[ERROR] SSH config currently invalid. No changes applied'; exit 1; }
TMP=$(mktemp -d /tmp/hyper-cs2-v4.XXXXXXXX)
trap 'rm -rf "$TMP"' EXIT
BACKUP="/root/hyper-cs2-v4-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs2-ctl"
cp -a "$PANEL" "$BACKUP/cs2.php"
cp -a /etc/ssh/sshd_config "$BACKUP/sshd_config"
rollback_v4() {
  local code=$?
  trap - ERR
  echo "[ERROR] v4 installation failed (exit $code); restoring controller, PHP and SSH config from $BACKUP" >&2
  cp -a "$BACKUP/hyper-cs2-ctl" "$CTL" || true
  cp -a "$BACKUP/cs2.php" "$PANEL" || true
  cp -a "$BACKUP/sshd_config" /etc/ssh/sshd_config || true
  /usr/sbin/sshd -t || true
  if systemctl is-active --quiet ssh; then systemctl reload ssh || true
  elif systemctl is-active --quiet sshd; then systemctl reload sshd || true; fi
  exit "$code"
}
trap rollback_v4 ERR
cat > "$TMP/addon.py" <<'HYPER_CS2_SFTP_ADDON_V4'
# HYPER-HOST v4 SFTP isolated per CS2 instance (injected before def main())
import grp, secrets

SFTP_GROUP='hypercs2sftp'

def sftp_info(i):
    c=load(i)
    uname=user(i)
    try:
        info=pwd.getpwnam(uname)
    except KeyError:
        return {'ok':True,'enabled':False,'ready':False,'username':uname,'message':'Сначала дождитесь подготовки игрового сервера'}
    try:
        g=grp.getgrnam(SFTP_GROUP)
        member=uname in g.gr_mem or info.pw_gid==g.gr_gid
    except KeyError:
        member=False
    locked=True
    try:
        for line in pathlib.Path('/etc/shadow').read_text().splitlines():
            if line.startswith(uname+':'):
                shadow=line.split(':',2)[1]
                locked=not bool(shadow) or shadow.startswith(('!','*'))
                break
    except OSError: pass
    port=22;configured=False
    sshd=shutil.which('sshd') or '/usr/sbin/sshd'
    try:
        cfg=cp([sshd,'-T','-C',f'user={uname},host=localhost,addr=127.0.0.1'],check=False,timeout=5)
        if cfg.returncode==0:
            d=dict((line.split(' ',1) for line in cfg.stdout.splitlines() if ' ' in line))
            try: port=int(d.get('port','22').split()[0])
            except ValueError: port=22
            configured=(d.get('chrootdirectory','') in ('%h',str(gamepath(i)))
                        and d.get('forcecommand','').startswith('internal-sftp')
                        and d.get('passwordauthentication','').lower()=='yes')
    except Exception: pass
    return {'ok':True,'enabled':member and not locked and configured,'configured':configured,'ready':bool(gamepath(i).is_dir()),
            'username':uname,'port':port,'remote_dir':'/gamefiles/game/csgo',
            'protocol':'SFTP','mode':storage_mode(c)}

def sftp_chroot_preflight(i):
    root=gamepath(i)
    if not root.exists() or root.is_symlink(): fail('Не найдена папка сервера или обнаружена ссылка')
    if storage_mode(load(i))=='overlay':
        with base_lock(shared=True):
            if base_busy(): fail('Общая сборка CS2 сейчас обновляется')
            mount_overlay_unlocked(i)
    if not (root/'gamefiles/game/csgo').is_dir(): fail('Не подготовлена игровая директория CS2')
    # OpenSSH requires root-owned, non-writable-by-group/other chroot path.
    # Changing owners of ROOT/SERVERS globally is unsafe; verify each component.
    for part in [pathlib.Path('/srv'),ROOT,SERVERS]:
        st=part.stat()
        if part.is_symlink() or st.st_uid!=0 or st.st_mode&0o022:
            fail('SFTP chroot требует root-owned директорию без групповой записи: '+str(part))
    st=root.stat()
    if st.st_mode&0o022 or st.st_uid!=0:
        # Fix only this instance's outer directory. Never recursively chown the game.
        os.chown(root,0,0)
        os.chmod(root,0o755)
    if root.is_symlink() or root.stat().st_mode&0o022: fail('Некорректные права SFTP chroot')

def sftp_enable(i):
    if load(i).get('state')!='ready': fail('Дождитесь завершения установки сервера')
    sftp_chroot_preflight(i)
    uname=user(i)
    try: grp.getgrnam(SFTP_GROUP)
    except KeyError: fail('Не установлена системная группа SFTP (повторите патч v4)')
    password=secrets.token_urlsafe(24)
    cp(['usermod','-a','-G',SFTP_GROUP,uname],timeout=10)
    if not sftp_info(i)['configured']:
        fail('Текущая конфигурация sshd не обеспечивает ChrootDirectory, internal-sftp и парольный вход для группы. Пароль не активирован.')
    p=subprocess.run(['chpasswd'],input=f'{uname}:{password}\n',text=True,capture_output=True,timeout=10)
    if p.returncode: fail('Не удалось установить пароль SFTP: '+p.stderr[-400:])
    data=sftp_info(i)
    if not data['enabled']: fail('SFTP учётная запись не активировалась; проверьте sshd и PAM')
    output({**data,'password':password,'message':'Пароль показан один раз. Сохраните его в менеджере паролей.'})

def sftp_disable(i):
    load(i)
    uname=user(i)
    try: pwd.getpwnam(uname)
    except KeyError: fail('Системный пользователь CS2 ещё не создан')
    cp(['passwd','-l',uname],timeout=10)
    cp(['gpasswd','-d',uname,SFTP_GROUP],check=False,timeout=10)
    output({'ok':True,'enabled':False,'username':uname,'message':'Доступ для новых подключений заблокирован. Существующие SFTP-сеансы могут оставаться открытыми.'})
HYPER_CS2_SFTP_ADDON_V4
cat > "$TMP/cs2.php" <<'HYPER_CS2_AJAX_PANEL_V4'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$user=require_auth();
$isAdmin=in_array((string)$user['role'],['owner','admin'],true);
$isAjax=(isset($_GET['ajax'])||strtolower((string)($_SERVER['HTTP_X_REQUESTED_WITH']??''))==='xmlhttprequest');
function cs4json(array $v,int $code=200):void {http_response_code($code);header('Content-Type: application/json; charset=utf-8');header('Cache-Control: private, no-store');echo json_encode($v,JSON_UNESCAPED_UNICODE|JSON_INVALID_UTF8_SUBSTITUTE);exit;}
function cs4ctl(array $args,?string $input=null,int $timeout=30):array {
  $cmd=['sudo','-n','/usr/local/sbin/hyper-cs2-ctl'];foreach($args as $a)$cmd[]=(string)$a;
  $p=proc_open(implode(' ',array_map('escapeshellarg',$cmd)),[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes,null,['PATH'=>'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']);
  if(!is_resource($p))return ['ok'=>false,'error'=>'Контроллер недоступен'];
  fwrite($pipes[0],$input??'');fclose($pipes[0]);
  stream_set_blocking($pipes[1],false);stream_set_blocking($pipes[2],false);
  $start=microtime(true);$out='';$err='';$timed=false;
  do{$status=proc_get_status($p);$out.=stream_get_contents($pipes[1]);$err.=stream_get_contents($pipes[2]);if(!$status['running'])break;if(microtime(true)-$start>$timeout){proc_terminate($p);$timed=true;break;}usleep(40000);}while(true);
  $out.=stream_get_contents($pipes[1]);$err.=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);proc_close($p);
  $v=json_decode(trim($out),true);
  return is_array($v)?$v:['ok'=>false,'error'=>$timed?'Время ожидания превышено':(trim($err)?:trim($out)?:'Ошибка контроллера')];
}
function cs4row(int $id):array{
  global $user,$isAdmin;
  if($id<1)throw new RuntimeException('Некорректный ID');
  $q=db()->prepare('SELECT * FROM cs2_servers WHERE id=?');$q->execute([$id]);$r=$q->fetch();
  if(!$r)throw new RuntimeException('Сервер CS2 #'.$id.' не найден');
  if(!$isAdmin&&(int)$r['owner_user_id']!==(int)$user['id'])throw new RuntimeException('Нет доступа к серверу');
  return $r;
}
function cs4require(bool $allowed):void{if(!$allowed)throw new RuntimeException('Недостаточно прав для операции');}
function cs4post(array $row,int $id,string $action):array{
  global $isAdmin,$user;
  if($action==='power'){
    cs4require(can_perm('server.power')||(int)$row['owner_user_id']===(int)$user['id']);
    $op=(string)($_POST['op']??'');if(!in_array($op,['start','stop','restart'],true))throw new RuntimeException('Неверное действие');
    $r=cs4ctl([$op,$id],null,110);return $r+['message'=>['start'=>'Запуск сервера выполнен','stop'=>'Сервер остановлен','restart'=>'Сервер перезапущен'][$op]];
  }
  if($action==='update'){
    cs4require($isAdmin); // shared base update affects ALL tenants
    $r=cs4ctl(['update',$id]);return $r+['message'=>'Обновление общей CS2 запущено. Все серверы могут быть временно остановлены.'];
  }
  if($action==='settings'){
    $p=['name'=>(string)($_POST['name']??$row['name']),'hostname'=>(string)($_POST['hostname']??$row['hostname']),
      'port'=>(int)($_POST['port']??$row['port']),'slots'=>(int)($_POST['slots']??$row['slots']),
      'map'=>(string)($_POST['map']??$row['start_map']),'mode'=>(string)($_POST['mode']??$row['game_mode'])];
    foreach(['token','password','rcon'] as $key){$v=(string)($_POST[$key]??'');if($v!=='')$p[$key]=$v;}
    $r=cs4ctl(['settings',$id],json_encode($p,JSON_UNESCAPED_UNICODE));
    if(!empty($r['ok']))db()->prepare('UPDATE cs2_servers SET name=?,hostname=?,port=?,slots=?,start_map=?,game_mode=? WHERE id=?')->execute([$p['name'],$p['hostname'],$p['port'],$p['slots'],$p['map'],$p['mode'],$id]);
    return $r+['message'=>'Настройки сохранены. Примените их перезапуском сервера.'];
  }
  if($action==='rcon')return cs4ctl(['rcon',$id],(string)($_POST['command']??''),20);
  if($action==='save_cfg')return cs4ctl(['config-save',$id],(string)($_POST['config']??''))+['message'=>'server.cfg сохранён. Для применения нужен перезапуск.'];
  if($action==='sftp-enable'||$action==='sftp-reset')return cs4ctl(['sftp-enable',$id],null,35);
  if($action==='sftp-disable')return cs4ctl(['sftp-disable',$id],null,20);
  if($action==='delete'){
    cs4require(can_perm('server.delete'));
    if((string)($_POST['confirm']??'')!=='DELETE')throw new RuntimeException('Для удаления введи DELETE');
    $r=cs4ctl(['delete',$id],null,120);
    if(!empty($r['ok'])){db()->prepare('DELETE FROM cs2_servers WHERE id=?')->execute([$id]);audit('cs2_delete','#'.$id);$r['redirect']='/cs2.php';$r['message']='Сервер удалён';}
    return $r;
  }
  throw new RuntimeException('Неизвестное действие');
}
if(isset($_GET['ajax'])){
  try{
    $act=(string)$_GET['ajax'];$id=(int)($_GET['id']??0);
    if($act==='base'){$v=cs4ctl(['base-status']);cs4json($v);}
    $r=cs4row($id);
    if($act==='status'){$v=cs4ctl(['status',$id]);cs4json($v);}
    if($act==='logs'){$v=cs4ctl(['logs',$id]);cs4json($v);}
    if($act==='config'){$v=cs4ctl(['config-get',$id]);cs4json($v);}
    if($act==='sftp'){$v=cs4ctl(['sftp-status',$id]);cs4json($v);}
    throw new RuntimeException('Неизвестный запрос');
  }catch(Throwable $e){cs4json(['ok'=>false,'error'=>$e->getMessage()],400);}
}
if($_SERVER['REQUEST_METHOD']==='POST'){
  try{
    check_csrf();$act=(string)($_POST['action']??'');$id=(int)($_POST['id']??0);
    if($act==='install_base'){require_perm('servers.create');$r=cs4ctl(['base-start']);$r['message']='Установка CS2 запущена';}
    elseif($act==='create'){
      require_perm('servers.create');
      $p=['name'=>trim((string)($_POST['name']??'')),'hostname'=>trim((string)($_POST['hostname']??'')),
        'port'=>(int)($_POST['port']??27101),'slots'=>(int)($_POST['slots']??10),'map'=>(string)($_POST['map']??'de_dust2'),
        'mode'=>(string)($_POST['mode']??'competitive'),'token'=>(string)($_POST['token']??''),
        'password'=>(string)($_POST['password']??''),'rcon'=>(string)($_POST['rcon']??'')];
      if($p['name']===''||$p['hostname']===''||$p['rcon']==='')throw new RuntimeException('Заполни название, hostname и RCON-пароль');
      $maps=cs4ctl(['maps']);if(empty($maps['base_ready'])||!in_array($p['map'],$maps['maps']??[],true))throw new RuntimeException('Базовая CS2 пока не готова или карта отсутствует');
      $pdo=db();$pdo->prepare('INSERT INTO cs2_servers(owner_user_id,name,hostname,port,slots,start_map,game_mode) VALUES(?,?,?,?,?,?,?)')
        ->execute([(int)$user['id'],$p['name'],$p['hostname'],$p['port'],$p['slots'],$p['map'],$p['mode']]);
      $id=(int)$pdo->lastInsertId();$r=cs4ctl(['create',$id],json_encode($p,JSON_UNESCAPED_UNICODE));
      if(empty($r['ok'])){$pdo->prepare('DELETE FROM cs2_servers WHERE id=?')->execute([$id]);}
      else{$r['redirect']='/cs2.php?id='.$id;$r['message']='Подготовка сервера запущена';audit('cs2_create','#'.$id);}
    }else{$row=cs4row($id);$r=cs4post($row,$id,$act);if(!empty($r['ok']))audit('cs2_'.$act,'#'.$id);}
    if(empty($r['ok']))throw new RuntimeException((string)($r['error']??'Неизвестная ошибка'));
    if($isAjax)cs4json($r);
    flash((string)($r['message']??'Операция выполнена'));redirect((string)($r['redirect']??('/cs2.php'.($id?'?id='.$id:''))));
  }catch(Throwable $e){if($isAjax)cs4json(['ok'=>false,'error'=>$e->getMessage()],400);flash($e->getMessage(),'danger');redirect('/cs2.php'.(!empty($id)?'?id='.(int)$id:''));}
}
$all=cs4ctl(['list']);$live=[];foreach(($all['servers']??[]) as $s)$live[(int)$s['id']]=$s;
if($isAdmin)$rows=db()->query('SELECT * FROM cs2_servers ORDER BY id DESC')->fetchAll();
else{$q=db()->prepare('SELECT * FROM cs2_servers WHERE owner_user_id=? ORDER BY id DESC');$q->execute([(int)$user['id']]);$rows=$q->fetchAll();}
$id=(int)($_GET['id']??0);$row=null;$status=[];$config=['text'=>''];
if($id){try{$row=cs4row($id);$status=$live[$id]??cs4ctl(['status',$id]);$config=cs4ctl(['config-get',$id]);}catch(Throwable $e){flash($e->getMessage(),'danger');redirect('/cs2.php');}}
$maps=array_values(array_filter($all['maps']??[],fn($v)=>is_string($v)&&preg_match('/^[A-Za-z0-9_]{1,64}$/',$v)));
$base=$all['base']??['state'=>'missing','ready'=>false,'maps_count'=>0];$ready=!empty($base['ready']);
$ip=(string)cfg('public_ip');$flash=flash();
$modeNames=['competitive'=>'Соревновательный','casual'=>'Обычный','deathmatch'=>'Бой насмерть','wingman'=>'Напарники'];
?><!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>CS2 · HYPER-HOST</title>
<style>
:root{--bg:#070b15;--surface:#11182a;--surface2:#17223a;--line:#26354f;--muted:#91a4c2;--txt:#f0f5ff;--blue:#4288ff;--purple:#735aff;--green:#32d99d;--red:#fb6577;--amber:#ffbf64}*{box-sizing:border-box}html,body{margin:0;min-height:100%;background:var(--bg);color:var(--txt);font:14px/1.5 system-ui,-apple-system,Segoe UI,Arial,sans-serif}a{color:#81b4ff;text-decoration:none}button,input,select,textarea{font:inherit}button{cursor:pointer}button:disabled{cursor:not-allowed;opacity:.45} .app{max-width:1540px;margin:auto;padding:26px 28px 70px} .top{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap;margin-bottom:26px}.brand{font-size:11px;letter-spacing:.18em;font-weight:800;color:#83b3ff}.heading{font-size:clamp(25px,3vw,36px);font-weight:800;letter-spacing:-.035em;margin:4px 0 2px}.muted{color:var(--muted)}.small{font-size:12px}.topright{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;border:1px solid #40516d;border-radius:11px;padding:10px 16px;color:#f4f7ff;background:#1b2941;font-weight:700;white-space:nowrap;transition:background .15s,border-color .15s,transform .15s}.btn:hover:not(:disabled){background:#273b60;border-color:#5a81ca;transform:translateY(-1px)}.btn.primary{background:linear-gradient(120deg,#2675fa,#6049ee);border-color:#5d65f9}.btn.green{background:#115d49;border-color:#197e60}.btn.red{background:#4a2231;border-color:#804159}.btn.amber{background:#48371c;border-color:#8b6738}.btn.ghost{background:transparent}.btn.sm{padding:7px 12px;font-size:12px;border-radius:9px}.card{background:linear-gradient(145deg,var(--surface),#10182a);border:1px solid var(--line);border-radius:18px;box-shadow:0 16px 50px #02071332;padding:23px}.card h2{font-size:19px;margin:0 0 16px;letter-spacing:-.015em}.stack{display:grid;gap:16px}.grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:18px}.col8{grid-column:span 8}.col7{grid-column:span 7}.col6{grid-column:span 6}.col5{grid-column:span 5}.col4{grid-column:span 4}.col12{grid-column:span 12}.flex{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.between{justify-content:space-between}.badge{display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border:1px solid #40516c;border-radius:99px;color:#c0cee5;background:#18233a;font-size:12px;font-weight:700}.badge.good{color:#60e8bb;border-color:#1e765c;background:#0d382d}.badge.bad{color:#ff9ba4;border-color:#824050;background:#381c2b}.badge.wait{color:#ffd18c;border-color:#806039;background:#422e1b}.dot{width:7px;height:7px;border-radius:50%;background:currentColor}.hero{padding:26px;background:radial-gradient(ellipse at 80% -80%,#4b48aa65,transparent 55%),linear-gradient(120deg,#162640,#11182a)}.hero h2{font-size:26px;margin:0 0 5px}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:18px 0}.metric{background:#0c1425;border:1px solid #263550;border-radius:13px;padding:16px}.metric .value{font-size:23px;font-weight:800;letter-spacing:-.02em;margin-top:5px}.metric .label{font-size:12px;color:#a2b5d4}.navtabs{display:flex;gap:5px;padding:5px;background:#101b2d;border:1px solid var(--line);border-radius:13px;overflow-x:auto;margin:20px 0}.tab{flex:1;min-width:105px;padding:11px 14px;background:transparent;border:0;border-radius:9px;color:#9caec9;font-weight:700}.tab:hover{color:#fff;background:#1a2a46}.tab.active{background:#30436b;color:white}.panel{display:none}.panel.active{display:block}.formgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}.field{display:grid;gap:7px}.field.full{grid-column:1/-1}.field label{font-weight:700;font-size:12px;color:#b8c9e5}.field input,.field select,.field textarea,.terminal-input{width:100%;min-width:0;border-radius:10px;padding:11px 12px;color:#edf4ff;background:#0a1223;border:1px solid #344563;outline:none}.field input:focus,.field select:focus,.field textarea:focus,.terminal-input:focus{border-color:#488dff;box-shadow:0 0 0 3px #2877ee33}.field textarea{min-height:330px;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;resize:vertical}.field select option{color:#fff;background:#111b2d}.hint{font-size:12px;color:#9eb0cc}.terminal{padding:17px;background:#050a13;border:1px solid #22324a;color:#91f1bd;min-height:180px;max-height:460px;overflow:auto;border-radius:13px;white-space:pre-wrap;word-break:break-word;font:12px/1.7 ui-monospace,SFMono-Regular,Consolas,monospace}.notice{padding:14px;border:1px solid #38557f;background:#122441;border-radius:11px;color:#c5defe}.notice.warn{background:#392b19;border-color:#715433;color:#ffdb9c}.srvcard{display:block;color:inherit;transition:border-color .15s}.srvcard:hover{border-color:#5082dc}.srvcard h3{margin:0;font-size:18px}.pill{color:#7fc6ff;font-size:12px;font-weight:700}.statgroup{display:flex;align-items:center;flex-wrap:wrap;gap:9px}.split{display:grid;grid-template-columns:1fr auto;gap:16px;align-items:center}.sidebarline{border-top:1px solid var(--line);padding-top:16px;margin-top:18px}.mono{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}.secretreveal{padding:15px;background:#142841;border:1px solid #3b5a7c;border-radius:12px;margin:12px 0}.alertbox{padding:11px 15px;border-radius:11px;background:#382232;border:1px solid #764155;color:#ffb5bf;white-space:pre-wrap}.toastbox{position:fixed;right:22px;bottom:22px;max-width:420px;z-index:1000;border-radius:13px;padding:14px 18px;background:#163c33;color:#a7ffe0;border:1px solid #2a977a;box-shadow:0 12px 45px #0009}.toastbox.error{background:#48252b;color:#ffd4d8;border-color:#c45b71}.hidden{display:none!important}.spinner{display:inline-block;width:14px;height:14px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:spin .75s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}.footer{margin-top:30px;text-align:center;color:#7c8dac;font-size:12px}@media(max-width:950px){.col8,.col7,.col6,.col5,.col4{grid-column:span 12}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:550px){.app{padding:15px 12px 40px}.card{padding:17px;border-radius:14px}.metrics{gap:8px}.metric{padding:11px}.metric .value{font-size:19px}.formgrid{grid-template-columns:1fr}.split{grid-template-columns:1fr}.tab{min-width:96px;padding:10px 8px}.hero h2{font-size:22px}}
</style></head><body><main class="app">
<header class="top"><div><div class="brand">HYPER-HOST / GAME HOSTING</div><div class="heading">Counter-Strike <span style="color:#669bff">2</span></div><div class="muted small">Steam Dedicated Server · App 730 · Shared Storage</div></div><div class="topright"><a class="btn ghost" href="/">← CS 1.6</a><a class="btn <?=$id?'':'primary'?>" href="/cs2.php">Все серверы</a></div></header>
<?php if(is_array($flash)&&!empty($flash['message'])):?><div class="notice" style="margin-bottom:16px"><?=e((string)$flash['message'])?></div><?php endif;?>
<section class="card" style="margin-bottom:18px"><div class="split"><div><div class="flex"><strong style="font-size:19px">Общая сборка CS2</strong><span id="base-badge" class="badge <?=$ready?'good':'wait'?>"><?= $ready?'Установлена':'Проверяется / устанавливается' ?></span></div><div class="muted small" style="margin-top:5px">SteamCMD App 730 · /srv/hyper-cs2/base · карт CS2: <span id="mapcount"><?=(int)($base['maps_count']??0)?></span></div><div class="hint" id="base-message" style="margin-top:8px"><?= $ready?'Одна сборка для всех серверов. Конфигурации и дополнения клиентов изолированы.':'Создание доступно после завершения загрузки и проверки сборки.' ?></div></div><div><?php if(can_perm('servers.create')):?><form method="post" class="ajaxform" data-quiet="1"><?=csrf_field()?><input type="hidden" name="action" value="install_base"><button class="btn ghost" type="submit">Проверить / установить</button></form><?php endif;?></div></div></section>
<?php if(!$row):?>
<div class="flex between" style="margin:24px 0 14px"><div><h2 style="margin:0">Мои игровые серверы</h2><div class="muted small"><?=count($rows)?> сервер(ов)</div></div></div>
<div class="grid" style="margin-bottom:20px"><?php if(!$rows):?><div class="col12 card"><h2>Серверов пока нет</h2><div class="muted">Создай первый CS2-сервер после установки базовой сборки.</div></div><?php endif;?><?php foreach($rows as $s):$ss=$live[(int)$s['id']]??[];$run=!empty($ss['running']);?><a class="card srvcard col4" href="/cs2.php?id=<?=(int)$s['id']?>"><div class="flex between"><h3><?=e($s['name'])?></h3><span class="badge <?=$run?'good':'wait'?>"><?=$run?'Онлайн':e((string)($ss['state']??'Офлайн'))?></span></div><div class="muted small" style="margin:11px 0"><?=e($ip)?>:<?=(int)$s['port']?> · <?=e($s['start_map'])?></div><div class="flex"><span class="pill"><?=(int)$s['slots']?> слотов</span><span class="pill"><?=e($modeNames[$s['game_mode']]??$s['game_mode'])?></span></div></a><?php endforeach;?></div>
<?php if(can_perm('servers.create')):?><section class="card"><div class="flex between"><h2 style="margin:0">Создать сервер CS2</h2><span class="badge <?=$ready?'good':'wait'?>"><?=$ready?'Можно создавать':'Ожидаем установку'?></span></div><p class="muted">Новая игровая папка использует общую сборку через OverlayFS, без повторной загрузки десятков гигабайт.</p><form method="post" class="ajaxform formgrid" style="margin-top:18px"><?=csrf_field()?><input type="hidden" name="action" value="create"><div class="field"><label>Название</label><input name="name" value="HYPER-HOST CS2" maxlength="96" required></div><div class="field"><label>Имя игрового сервера (hostname)</label><input name="hostname" value="HYPER-HOST | Counter-Strike 2" maxlength="160" required></div><div class="field"><label>UDP порт</label><input type="number" name="port" value="27101" min="27015" max="27200" required></div><div class="field"><label>Слоты</label><input type="number" name="slots" value="10" min="2" max="32" required></div><div class="field"><label>Карта CS2</label><select name="map" required><?php foreach($maps as $m):?><option value="<?=e($m)?>" <?=$m==='de_dust2'?'selected':''?>><?=e($m)?></option><?php endforeach;?></select></div><div class="field"><label>Режим</label><select name="mode"><?php foreach($modeNames as $k=>$v):?><option value="<?=e($k)?>"><?=e($v)?></option><?php endforeach;?></select></div><div class="field"><label>Steam GSLT (App 730)</label><input type="password" name="token" autocomplete="new-password" placeholder="Для публичного сервера"></div><div class="field"><label>RCON пароль</label><input type="password" name="rcon" minlength="8" required autocomplete="new-password"></div><div class="field full"><label>Пароль входа в игру (необязательно)</label><input type="password" name="password" autocomplete="new-password"></div><div class="field full"><button type="submit" class="btn primary" <?=$ready?'':'disabled'?>>＋ Создать игровой сервер</button></div></form></section><?php endif;?>
<?php else:?>
<section class="card hero"><div class="split"><div><div class="muted small">ИГРОВОЙ СЕРВЕР #<?=$id?></div><h2 id="server-name"><?=e($row['name'])?></h2><div class="flex"><span id="server-badge" class="badge <?=!empty($status['running'])?'good':'wait'?>"><span class="dot"></span><span id="state-text"><?=!empty($status['running'])?'Работает':e((string)($status['state']??'Ожидание'))?></span></span><span class="muted small mono" id="connect-label"><?=e($ip)?>:<?=(int)$row['port']?></span><button class="btn ghost sm" type="button" data-copy="<?=e($ip.':'.(int)$row['port'])?>">Скопировать адрес</button></div></div><div class="flex"><form method="post" class="ajaxform flex powerform"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="power"><button class="btn green" name="op" value="start" type="submit">▶ Запустить</button><button class="btn amber" name="op" value="restart" type="submit">↻ Рестарт</button><button class="btn red" name="op" value="stop" type="submit">■ Остановить</button></form></div></div><div id="server-error" class="alertbox <?=empty($status['error'])?'hidden':''?>" style="margin-top:15px"><?=e((string)($status['error']??''))?></div></section>
<div class="metrics"><div class="metric"><div class="label">Статус</div><div class="value" id="service-value"><?=e((string)($status['service']??'unknown'))?></div></div><div class="metric"><div class="label">Игроки</div><div class="value" id="players-value"><?=isset($status['players'])?(int)$status['players'].' / '.(int)($status['max_players']??$row['slots']):'—'?></div></div><div class="metric"><div class="label">CPU</div><div class="value" id="cpu-value"><?=e((string)($status['cpu']??0))?>%</div></div><div class="metric"><div class="label">Оперативная память</div><div class="value" id="ram-value"><?=e((string)($status['ram_mb']??0))?> МБ</div></div></div>
<nav class="navtabs" aria-label="Разделы сервера"><button type="button" class="tab active" data-tab="overview">Обзор</button><button type="button" class="tab" data-tab="console">Консоль</button><button type="button" class="tab" data-tab="files">Файлы / SFTP</button><button type="button" class="tab" data-tab="settings">Настройки</button><button type="button" class="tab" data-tab="config">server.cfg</button><button type="button" class="tab" data-tab="logs">Логи</button></nav>
<section class="panel active" data-panel="overview"><div class="grid"><div class="col8 card"><h2>Информация о сервере</h2><div class="stack"><div class="flex between"><span class="muted">Адрес</span><strong class="mono"><?=e($ip)?>:<?=(int)$row['port']?></strong></div><div class="flex between"><span class="muted">Стартовая карта</span><strong id="current-map"><?=e($row['start_map'])?></strong></div><div class="flex between"><span class="muted">Режим</span><strong><?=e($modeNames[$row['game_mode']]??$row['game_mode'])?></strong></div><div class="flex between"><span class="muted">Хранилище</span><strong><?=($status['storage']??'')==='overlay'?'Общая сборка / OverlayFS':'Отдельная копия'?></strong></div><div class="flex between"><span class="muted">Время работы</span><strong id="uptime">—</strong></div><div class="flex between"><span class="muted">Игровые файлы</span><strong class="mono small">/srv/hyper-cs2/servers/<?=$id?>/gamefiles</strong></div></div><div class="notice" style="margin-top:20px">Обновление статуса автоматически каждые 7 секунд, без перезагрузки страницы.</div></div><div class="col4 card"><h2>Быстрые действия</h2><div class="stack"><button class="btn" type="button" data-gotab="console">⌘ Открыть RCON-консоль</button><button class="btn" type="button" data-gotab="files">⇪ Настроить SFTP-доступ</button><button class="btn" type="button" data-gotab="logs">☷ Журнал запуска</button><?php if($isAdmin):?><form method="post" class="ajaxform" data-confirm="Обновление общей CS2 остановит ВСЕ серверы OverlayFS на время обновления. Продолжить?"><?=csrf_field()?><input type="hidden" name="action" value="update"><input type="hidden" name="id" value="<?=$id?>"><button class="btn ghost" style="width:100%">↻ Обновить общую CS2</button></form><?php endif;?></div></div></div></section>
<section class="panel" data-panel="console"><div class="card"><h2>RCON консоль</h2><p class="muted small">Удалённые команды для запущенного CS2. Например: <span class="mono">status</span> или <span class="mono">changelevel de_dust2</span>.</p><form method="post" class="ajaxform flex" data-result="console-out"><?=csrf_field()?><input type="hidden" name="action" value="rcon"><input type="hidden" name="id" value="<?=$id?>"><input class="terminal-input" style="flex:1;min-width:220px" name="command" placeholder="Введите RCON команду..." maxlength="300" required><button class="btn primary">Выполнить</button></form><pre id="console-out" class="terminal" style="margin-top:16px">Результат команды появится здесь.</pre></div></section>
<section class="panel" data-panel="files"><div class="grid"><div class="col7 card"><h2>Доступ к файлам CS2 через SFTP</h2><div class="notice">SFTP — защищённый файловый протокол через SSH. Работает с FileZilla и WinSCP. Обычный незашифрованный FTP не используется.</div><div class="formgrid" style="margin:20px 0"><div class="field"><label>Хост</label><input id="sftp-host" readonly value="<?=e($ip)?>"></div><div class="field"><label>Протокол</label><input readonly value="SFTP — SSH File Transfer"></div><div class="field"><label>Порт SSH</label><input id="sftp-port" readonly value="22"></div><div class="field"><label>Логин</label><input id="sftp-user" readonly value="cs2s<?=$id?>"></div><div class="field full"><label>Стартовая папка</label><input id="sftp-dir" class="mono" readonly value="/gamefiles/game/csgo"></div></div><div class="flex"><span id="sftp-badge" class="badge wait">Проверяется</span><form method="post" class="ajaxform" data-sftp="1"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="sftp-enable"><button class="btn primary" id="sftp-enable">Включить / сменить пароль</button></form><form method="post" class="ajaxform" data-sftp="1" data-confirm="Отключить вход по SFTP для данного сервера?"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="sftp-disable"><button class="btn red">Отключить</button></form></div><div class="secretreveal hidden" id="sftp-secret"><strong>Новый SFTP пароль — показывается только сейчас!</strong><div class="flex" style="margin-top:9px"><code id="sftp-password" class="mono" style="font-size:15px;overflow-wrap:anywhere"></code><button class="btn sm" type="button" id="copy-password">Скопировать</button></div><div class="hint">После закрытия страницы пароль нельзя посмотреть — можно только создать новый.</div></div></div><div class="col5 card"><h2>Как подключиться</h2><div class="stack"><div><strong>1.</strong> Открой FileZilla или WinSCP</div><div><strong>2.</strong> Выбери протокол <b>SFTP</b> (не FTP)</div><div><strong>3.</strong> Введи IP, порт SSH и логин из панели</div><div><strong>4.</strong> Введи сгенерированный пароль</div><div><strong>5.</strong> Загружай конфиги и плагины в <code>addons/</code> и <code>cfg/</code></div></div><div class="notice warn" style="margin-top:20px">В общую базовую сборку записывать нельзя. Изменения сохраняются только в слое конкретного сервера. При обновлении общей базы активные SFTP-подключения следует закрыть.</div></div></div></section>
<section class="panel" data-panel="settings"><div class="card"><h2>Настройки сервера</h2><form method="post" class="ajaxform formgrid"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="settings"><div class="field"><label>Название в панели</label><input name="name" maxlength="96" value="<?=e($row['name'])?>" required></div><div class="field"><label>Hostname в игре</label><input name="hostname" maxlength="160" value="<?=e($row['hostname'])?>" required></div><div class="field"><label>UDP порт</label><input type="number" name="port" min="27015" max="27200" value="<?=(int)$row['port']?>" required></div><div class="field"><label>Слоты</label><input type="number" name="slots" min="2" max="32" value="<?=(int)$row['slots']?>" required></div><div class="field"><label>Стартовая карта</label><select name="map"><?php foreach($maps as $m):?><option value="<?=e($m)?>" <?=$m===$row['start_map']?'selected':''?>><?=e($m)?></option><?php endforeach;?></select></div><div class="field"><label>Режим</label><select name="mode"><?php foreach($modeNames as $k=>$v):?><option value="<?=e($k)?>" <?=$k===$row['game_mode']?'selected':''?>><?=e($v)?></option><?php endforeach;?></select></div><div class="field"><label>Новый GSLT (пусто = оставить)</label><input type="password" name="token" autocomplete="new-password"></div><div class="field"><label>Новый RCON пароль (пусто = оставить)</label><input type="password" name="rcon" autocomplete="new-password"></div><div class="field full"><label>Новый пароль входа в игру (пусто = оставить)</label><input type="password" name="password" autocomplete="new-password"></div><div class="field full"><button class="btn primary">Сохранить настройки</button><div class="hint" style="margin-top:6px">После изменения карты, режима и других параметров требуется перезапуск.</div></div></form></div><?php if(can_perm('server.delete')):?><div class="card" style="margin-top:18px;border-color:#6a3345"><h2 style="color:#ffa6b5">Удалить сервер</h2><p class="muted small">Безвозвратно удалятся настройки и индивидуальные файлы этого CS2-сервера. Общая сборка CS2 не удаляется.</p><form method="post" class="ajaxform flex" data-confirm="Удалить сервер и все его индивидуальные файлы? Действие необратимо."><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="delete"><input class="terminal-input" style="max-width:300px" name="confirm" placeholder="Введите DELETE" required><button class="btn red">Удалить сервер</button></form></div><?php endif;?></section>
<section class="panel" data-panel="config"><div class="card"><h2>Редактор server.cfg</h2><p class="muted small">Секреты RCON и GSLT скрыты и редактируются во вкладке «Настройки». Изменения сохраняются отдельно для этого сервера.</p><form method="post" class="ajaxform"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="save_cfg"><div class="field"><textarea name="config" spellcheck="false" id="cfg-editor" class="mono" maxlength="32768"><?=e((string)($config['text']??''))?></textarea></div><div class="flex" style="margin-top:14px"><button class="btn primary">Сохранить server.cfg</button><button type="button" class="btn ghost" id="reload-cfg">Обновить из сервера</button></div></form></div></section>
<section class="panel" data-panel="logs"><div class="card"><div class="flex between"><h2 style="margin:0">Логи запуска и работы</h2><button type="button" class="btn sm" id="reload-logs">↻ Обновить</button></div><p class="hint">Журнал systemd игрового сервера. Обновление каждые 8 секунд при открытой вкладке.</p><pre class="terminal" id="logs-out">Загрузка журнала...</pre></div></section>
<?php endif;?><footer class="footer">HYPER-HOST · CS2 v4 AJAX & SFTP · <a href="/">CS 1.6</a></footer></main><div id="toast" class="toastbox hidden" role="status" aria-live="polite"></div>
<script>
(()=>{'use strict';const id=<?=$id?>;const $=(s)=>document.querySelector(s);const $$=(s)=>Array.from(document.querySelectorAll(s));let tab='overview',busy=false,logPending=false;const esc=(s)=>String(s??'');
function toast(message,error=false){const t=$('#toast');if(!t)return;t.textContent=esc(message);t.classList.toggle('error',error);t.classList.remove('hidden');clearTimeout(window.csToastTimer);window.csToastTimer=setTimeout(()=>t.classList.add('hidden'),5000)}
async function get(action){let u='?ajax='+encodeURIComponent(action)+'&id='+encodeURIComponent(id);const r=await fetch(u,{credentials:'same-origin',cache:'no-store',headers:{'Accept':'application/json'}});const j=await r.json();if(!r.ok||j.ok===false)throw new Error(j.error||'Ошибка запроса');return j;}
async function send(form,submitter){if(busy)return;const msg=form.dataset.confirm;if(msg&&!confirm(msg))return;busy=true;const fd=new FormData(form);if(submitter&&submitter.name)fd.set(submitter.name,submitter.value);const btn=submitter||form.querySelector('button[type=submit],button');const old=btn?.innerHTML;if(btn){btn.disabled=true;btn.innerHTML='<span class="spinner"></span> Выполняется';}
try{const r=await fetch(location.pathname+location.search,{method:'POST',credentials:'same-origin',headers:{'X-Requested-With':'XMLHttpRequest','Accept':'application/json'},body:fd});const text=await r.text();let j;try{j=JSON.parse(text)}catch{throw new Error('Сервер вернул не JSON (HTTP '+r.status+'). Проверь PHP-лог.')}if(!r.ok||!j.ok)throw new Error(j.error||'Ошибка операции');if(j.password&&$('#sftp-secret')){$('#sftp-secret').classList.remove('hidden');$('#sftp-password').textContent=j.password;}
if(form.dataset.result==='console-out'&&$('#console-out'))$('#console-out').textContent=j.output||'(пустой ответ RCON)';if(j.redirect){location.assign(j.redirect);return;}toast(j.message||'Операция выполнена');if(form.dataset.sftp)loadSftp();if(id)refresh();else refreshBase();}
catch(e){toast(e.message,true)}finally{busy=false;if(btn){btn.disabled=false;btn.innerHTML=old;}}}
$$('.ajaxform').forEach(form=>form.addEventListener('submit',e=>{e.preventDefault();send(form,e.submitter)}));
$$('[data-tab]').forEach(b=>b.addEventListener('click',()=>openTab(b.dataset.tab)));
$$('[data-gotab]').forEach(b=>b.addEventListener('click',()=>openTab(b.dataset.gotab)));
function openTab(next){tab=next;$$('[data-tab]').forEach(b=>b.classList.toggle('active',b.dataset.tab===next));$$('[data-panel]').forEach(p=>p.classList.toggle('active',p.dataset.panel===next));if(next==='logs')loadLogs();if(next==='files')loadSftp();}
$$('[data-copy]').forEach(b=>b.addEventListener('click',()=>copy(b.dataset.copy)));
function copy(text){if(navigator.clipboard&&window.isSecureContext)navigator.clipboard.writeText(text).then(()=>toast('Скопировано')).catch(()=>toast('Не удалось скопировать',true));else toast('Скопируй значение вручную',true)}
$('#copy-password')?.addEventListener('click',()=>copy($('#sftp-password').textContent));
function prettyTime(sec){sec=Number(sec||0);if(!sec)return '—';const h=Math.floor(sec/3600),m=Math.floor(sec%3600/60);return h+' ч '+m+' мин';}
async function refresh(){if(!id||busy||document.hidden)return;try{const s=await get('status');const badge=$('#server-badge');badge.classList.toggle('good',!!s.running);badge.classList.toggle('wait',!s.running);$('#state-text').textContent=s.running?'Онлайн':s.state==='installing'?'Установка сервера':s.state==='failed'?'Ошибка установки':'Остановлен';$('#service-value').textContent=esc(s.service||'unknown');$('#players-value').textContent=s.players!==undefined?s.players+' / '+(s.max_players??s.slots):'—';$('#cpu-value').textContent=(s.cpu??0)+'%';$('#ram-value').textContent=(s.ram_mb??0)+' МБ';$('#current-map').textContent=s.current_map||s.map||'—';$('#uptime').textContent=prettyTime(s.uptime);$('#server-error').textContent=s.error||'';$('#server-error').classList.toggle('hidden',!s.error);}
catch(e){if(!document.hidden)toast('Статус: '+e.message,true)}}
async function loadLogs(){if(!id||logPending)return;logPending=true;try{const j=await get('logs');const box=$('#logs-out');if(box){const atBottom=box.scrollTop+box.clientHeight>=box.scrollHeight-40;box.textContent=j.logs||'Нет записей';if(atBottom)box.scrollTop=box.scrollHeight;}}catch(e){toast(e.message,true)}finally{logPending=false}}
async function loadSftp(){if(!id)return;try{const x=await get('sftp');$('#sftp-badge').textContent=x.enabled?'SFTP включён':x.ready?'SFTP отключён':'Сервер ещё устанавливается';$('#sftp-badge').classList.toggle('good',!!x.enabled);$('#sftp-badge').classList.toggle('wait',!x.enabled);$('#sftp-port').value=x.port||22;$('#sftp-user').value=x.username||('cs2s'+id);$('#sftp-dir').value=x.remote_dir||'/gamefiles/game/csgo';}catch(e){toast(e.message,true)}}
async function refreshBase(){try{const b=await get('base');$('#base-badge').textContent=b.ready?'Установлена':b.state==='installing'?'Устанавливается':'Не готова';$('#base-badge').classList.toggle('good',!!b.ready);$('#base-badge').classList.toggle('wait',!b.ready);$('#mapcount').textContent=b.maps_count??0;}catch(e){console.debug(e)}}
$('#reload-logs')?.addEventListener('click',loadLogs);$('#reload-cfg')?.addEventListener('click',async()=>{if(!confirm('Заменить несохранённый текст текущим server.cfg?'))return;try{$('#cfg-editor').value=(await get('config')).text||'';toast('Конфигурация обновлена')}catch(e){toast(e.message,true)}});
if(id){refresh();setInterval(()=>{if(tab==='logs')loadLogs();},8000);setInterval(refresh,7000);}setInterval(refreshBase,15000);
})();
</script></body></html>
HYPER_CS2_AJAX_PANEL_V4
python3 - "$CTL" "$TMP/addon.py" "$TMP/controller" <<'PATCH_PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);addon=pathlib.Path(sys.argv[2]).read_text();src=p.read_text()
if 'HYPER-HOST v4 SFTP isolated' not in src:
    old='def main():\n'
    if src.count(old)!=1: raise SystemExit('[ERROR] CS2 controller structure changed: no main()')
    src=src.replace(old,addon+'\n\n'+old,1)
    mark="'config-save','rcon','delete','logs']"
    if src.count(mark)!=1: raise SystemExit('[ERROR] CS2 controller actions changed')
    src=src.replace(mark,"'config-save','rcon','delete','logs','sftp-status','sftp-enable','sftp-reset','sftp-disable']",1)
    mark2="    if act=='_mount': return mount_overlay(i)"
    if src.count(mark2)!=1: raise SystemExit('[ERROR] CS2 controller routing changed')
    addition="    if act=='sftp-status': return output(sftp_info(i))\n    if act in ('sftp-enable','sftp-reset'): return sftp_enable(i)\n    if act=='sftp-disable': return sftp_disable(i)\n"
    src=src.replace(mark2,addition+mark2,1)
    # Include asynchronous provisioning logs; otherwise "installing/inactive" has no useful diagnostics in UI.
    old_log="['journalctl','-u',unit(i),'-n','100','--no-pager','-o','cat']"
    new_log="['journalctl','-u',unit(i),'-u',installunit(i),'-n','140','--no-pager','-o','cat']"
    if src.count(old_log)!=1: raise SystemExit('[ERROR] CS2 controller logs route changed')
    src=src.replace(old_log,new_log,1)
else:
    print('[OK] Controller already contains v4 SFTP extension')
pathlib.Path(sys.argv[3]).write_text(src)
PATCH_PY
python3 -m py_compile "$TMP/controller"
php -l "$TMP/cs2.php"
# Add SFTP-only OpenSSH Match section at the end of main config; using a drop-in
# at the beginning of Debian sshd_config would incorrectly apply Match to subsequent global directives.
# Never change SSH port, root login, or default authentication rules.
if ! grep -q '^# HYPER-HOST CS2 SFTP v4 BEGIN$' /etc/ssh/sshd_config; then
  cat >> /etc/ssh/sshd_config <<'SFTP_MATCH'

# HYPER-HOST CS2 SFTP v4 BEGIN
Match Group hypercs2sftp
    ChrootDirectory %h
    ForceCommand internal-sftp -d /gamefiles/game/csgo -u 0027
    PasswordAuthentication yes
    PermitTTY no
    X11Forwarding no
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTunnel no
# HYPER-HOST CS2 SFTP v4 END
SFTP_MATCH
fi
if ! /usr/sbin/sshd -t; then
    cp -a "$BACKUP/sshd_config" /etc/ssh/sshd_config
    /usr/sbin/sshd -t || true
    echo '[ERROR] SSH syntax check failed. Original sshd_config restored. CS2 unchanged.' >&2
    exit 1
fi
if ! getent group hypercs2sftp >/dev/null; then
    groupadd --system hypercs2sftp
fi
# Reload, not restart; existing SSH connections continue.
if systemctl is-active --quiet ssh; then
    systemctl reload ssh || { echo '[WARN] ssh reload failed: check sudo systemctl status ssh'; }
elif systemctl is-active --quiet sshd; then
    systemctl reload sshd || { echo '[WARN] sshd reload failed: check sudo systemctl status sshd'; }
else
    echo '[WARN] SSH service not active: SFTP will require an active OpenSSH daemon'
fi
install -m 0755 "$TMP/controller" "$CTL"
install -m 0644 "$TMP/cs2.php" "$PANEL"
chown www-data:www-data "$PANEL"
python3 -m py_compile "$CTL"
php -l "$PANEL"
echo
printf '%s
' '====================================================' ' HYPER-HOST CS2 AJAX + SFTP v4 INSTALLED' " Panel: https://$DOMAIN/cs2.php" " Backup: $BACKUP" ' Status: sudo hyper-cs2-ctl doctor' ' SFTP: FileZilla / WinSCP, SFTP over SSH' ' CS 1.6 and CS2 SteamCMD/download untouched.' '===================================================='
"$CTL" doctor || true
