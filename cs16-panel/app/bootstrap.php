<?php
declare(strict_types=1);

session_name('HYPERCS16SESSID');
ini_set('session.cookie_httponly', '1');
ini_set('session.cookie_samesite', 'Lax');
if (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ini_set('session.cookie_secure', '1');
session_start();
date_default_timezone_set('Europe/Moscow');

$configFile = '/etc/hyper-cs16/panel.php';
if (!is_file($configFile)) { http_response_code(500); exit('CS16 panel is not installed. Run install-cs16-panel.sh'); }
$config = require $configFile;

function cfg(string $k, mixed $d=null): mixed { global $config; return $config[$k] ?? $d; }
function db(): PDO {
    static $pdo = null;
    if ($pdo instanceof PDO) return $pdo;
    $dsn='mysql:host='.cfg('db_host','127.0.0.1').';port='.(int)cfg('db_port',3306).';dbname='.cfg('db_name','hyper_cs16').';charset=utf8mb4';
    $pdo=new PDO($dsn,(string)cfg('db_user'),(string)cfg('db_password'),[
        PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES=>false,
    ]);
    return $pdo;
}
function e(mixed $v): string { return htmlspecialchars((string)$v, ENT_QUOTES|ENT_SUBSTITUTE, 'UTF-8'); }
function json_out(array $v,int $status=200): never { http_response_code($status); header('Content-Type: application/json; charset=utf-8'); echo json_encode($v,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES); exit; }
function redirect(string $u): never { header('Location: '.$u); exit; }
function csrf_token(): string { if(empty($_SESSION['csrf'])) $_SESSION['csrf']=bin2hex(random_bytes(32)); return (string)$_SESSION['csrf']; }
function csrf_field(): string { return '<input type="hidden" name="_csrf" value="'.e(csrf_token()).'">'; }
function check_csrf(): void { $t=(string)($_POST['_csrf']??''); if($t===''||!hash_equals((string)($_SESSION['csrf']??''),$t)){ http_response_code(419); exit('CSRF token error'); } }
function flash(?string $m=null,string $type='success'): ?array { if($m!==null){$_SESSION['flash']=['message'=>$m,'type'=>$type];return null;} $f=$_SESSION['flash']??null; unset($_SESSION['flash']); return is_array($f)?$f:null; }
function current_user(): ?array {
    $id=(int)($_SESSION['uid']??0); if($id<1) return null;
    $st=db()->prepare('SELECT id,username,role,balance,active,created_at FROM users WHERE id=?'); $st->execute([$id]); $u=$st->fetch(); if(!$u || !(int)($u['active']??1)) return null; return $u;
}
function require_auth(bool $json=false): array { $u=current_user(); if(!$u){ if($json) json_out(['ok'=>false,'error'=>'auth required'],401); redirect('/?page=login'); } return $u; }
function role_label(string $role): string { return ['owner'=>'Владелец','admin'=>'Администратор','support'=>'Техподдержка','client'=>'Клиент'][$role]??$role; }
function role_permissions(string $role): array {
    if($role==='owner') return ['*'];
    if($role==='admin') return ['servers.view','servers.create','server.power','server.map','server.players','server.logs','server.plugins','server.admins','server.config','server.ftp','server.maintenance','server.delete','users.manage','resources.manage','billing.manage','billing.view','notifications.manage','history.view','api.manage','reports.create','reports.manage'];
    if($role==='support') return ['servers.view','server.power','server.map','server.players','server.logs','server.plugins','history.view','reports.create','reports.manage'];
    return ['servers.view','server.power','server.map','server.players','server.logs','billing.view','history.view','api.manage','reports.create'];
}
function user_has_server(int $userId,int $serverId): bool {
    $st=db()->prepare('SELECT 1 FROM server_users WHERE user_id=? AND server_id=? LIMIT 1');$st->execute([$userId,$serverId]);return (bool)$st->fetchColumn();
}
function can_perm(string $perm,?int $serverId=null,?array $u=null): bool {
    $u=$u?:current_user(); if(!$u) return false; $role=(string)$u['role'];$perms=role_permissions($role);
    if(in_array('*',$perms,true)) return true; if(!in_array($perm,$perms,true)) return false;
    if($serverId!==null && !in_array($role,['owner','admin'],true)) return user_has_server((int)$u['id'],$serverId);
    return true;
}
function require_perm(string $perm,?int $serverId=null,bool $json=false): void { if(!can_perm($perm,$serverId)){ if($json) json_out(['ok'=>false,'error'=>'Недостаточно прав'],403); http_response_code(403); exit('Недостаточно прав'); } }
function client_ip(): string { return substr((string)($_SERVER['HTTP_X_FORWARDED_FOR']??$_SERVER['REMOTE_ADDR']??''),0,64); }
function audit(string $action,string $details='',?int $serverId=null): void {
    $uid=(int)($_SESSION['uid']??0) ?: null;
    try { $st=db()->prepare('INSERT INTO audit_logs(user_id,server_id,action,details,ip) VALUES(?,?,?,?,?)'); $st->execute([$uid,$serverId,$action,$details,client_ip()]); } catch(Throwable) {}
}
function event_log(string $type,string $message,?int $serverId=null,string $severity='info',array $meta=[]): void {
    $uid=(int)($_SESSION['uid']??0) ?: null; $severity=in_array($severity,['info','warning','danger','success'],true)?$severity:'info';
    $notifyMap=['server_down'=>'notify_server_down','server_recovered'=>'notify_recovered','plugin_disabled'=>'notify_plugin_disabled','map_failed'=>'notify_map_failed','resource_high'=>'notify_resource_high','player_report'=>'notify_report','billing_expired'=>'notify_billing','billing_renewed'=>'notify_billing','billing_soon'=>'notify_billing'];
    $notifyEnabled=true; if(isset($notifyMap[$type]))$notifyEnabled=setting($notifyMap[$type],'1')==='1';
    $tg=(setting('telegram_enabled','0')==='1' && $notifyEnabled)?'pending':'disabled';
    try{$st=db()->prepare('INSERT INTO panel_events(server_id,user_id,event_type,severity,message,meta_json,telegram_status) VALUES(?,?,?,?,?,?,?)');$st->execute([$serverId,$uid,substr($type,0,64),$severity,mb_substr($message,0,500),json_encode($meta,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES)?:'{}',$tg]);}catch(Throwable){}
}
function setting_bool(string $key,bool $default=false): bool { return setting($key,$default?'1':'0')==='1'; }
function ctl(array $args,int $timeout=120,?string $stdin=null): array {
    $cmd=['sudo','-n','/usr/local/sbin/hyper-cs16-ctl']; foreach($args as $a)$cmd[]=(string)$a;
    $escaped=implode(' ',array_map('escapeshellarg',$cmd));
    $des=[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']];
    $p=proc_open($escaped,$des,$pipes,null,['PATH'=>'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']);
    if(!is_resource($p)) return ['ok'=>false,'error'=>'Cannot start control process'];
    if($stdin!==null){ $len=strlen($stdin); $off=0; while($off<$len){ $n=fwrite($pipes[0],substr($stdin,$off,65536)); if($n===false||$n===0) break; $off+=$n; } }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1],false); stream_set_blocking($pipes[2],false); $out='';$err='';$start=microtime(true);
    while(true){ $status=proc_get_status($p); $out.=stream_get_contents($pipes[1]); $err.=stream_get_contents($pipes[2]); if(!$status['running']) break; if(microtime(true)-$start>$timeout){ proc_terminate($p,15); usleep(300000); proc_terminate($p,9); $err.="\nTimeout"; break; } usleep(50000); }
    $out.=stream_get_contents($pipes[1]);$err.=stream_get_contents($pipes[2]); fclose($pipes[1]);fclose($pipes[2]); $code=proc_close($p);
    $text=trim($out); $data=json_decode($text,true);
    if(is_array($data)){ if($code!==0 && !isset($data['ok']))$data['ok']=false; return $data; }
    return ['ok'=>$code===0,'output'=>$text,'error'=>trim($err)?:($code===0?'':'Control command failed'),'code'=>$code];
}
function stage_upload(array $file,string $prefix,string $extension,int $maxBytes): array {
    if(empty($file['tmp_name'])||!is_uploaded_file((string)$file['tmp_name'])) throw new RuntimeException('Файл не выбран');
    if((int)($file['error']??UPLOAD_ERR_OK)!==UPLOAD_ERR_OK) throw new RuntimeException('Ошибка загрузки файла');
    $size=(int)($file['size']??0); if($size<1||$size>$maxBytes) throw new RuntimeException('Недопустимый размер файла');
    $original=basename((string)($file['name']??'')); $ext=strtolower(pathinfo($original,PATHINFO_EXTENSION));
    if($ext!==ltrim(strtolower($extension),'.')) throw new RuntimeException('Недопустимое расширение файла');
    $dir='/var/lib/hyper-cs16/uploads'; if(!is_dir($dir)) throw new RuntimeException('Upload staging не настроен. Повтори install-cs16-panel.sh');
    $token=$prefix.'-'.bin2hex(random_bytes(16)).$extension; $dst=$dir.'/'.$token;
    if(!move_uploaded_file((string)$file['tmp_name'],$dst)) throw new RuntimeException('Не удалось поместить файл в staging');
    @chmod($dst,0640); return [$token,$original];
}
function all_servers(): array {
    $u=current_user(); if(!$u)return []; if(in_array((string)$u['role'],['owner','admin'],true))return db()->query('SELECT * FROM servers ORDER BY id DESC')->fetchAll();
    $st=db()->prepare('SELECT s.* FROM servers s JOIN server_users su ON su.server_id=s.id WHERE su.user_id=? ORDER BY s.id DESC');$st->execute([(int)$u['id']]);return $st->fetchAll();
}
function server_row_raw(int $id): array { $st=db()->prepare('SELECT * FROM servers WHERE id=?');$st->execute([$id]);$s=$st->fetch(); if(!$s){http_response_code(404);exit('Server not found');}return $s; }
function server_row(int $id): array { $s=server_row_raw($id); if(!can_perm('servers.view',$id)){http_response_code(403);exit('Недостаточно прав к серверу');} return $s; }

function setting(string $key,string $default=''): string { $st=db()->prepare('SELECT setting_value FROM settings WHERE setting_key=?');$st->execute([$key]);$r=$st->fetch();return $r?(string)$r['setting_value']:$default; }
function set_setting(string $key,string $value): void { $st=db()->prepare('INSERT INTO settings(setting_key,setting_value) VALUES(?,?) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)');$st->execute([$key,$value]); }
function human_duration(int $s): string { $d=intdiv($s,86400);$s%=86400;$h=intdiv($s,3600);$m=intdiv($s%3600,60); return ($d?$d.'д ':'').($h?$h.'ч ':'').$m.'м'; }
function fmt_mb(float $mb): string { return $mb>=1024?number_format($mb/1024,1,',',' ').' ГБ':number_format($mb,0,',',' ').' МБ'; }
