<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';

function api_bearer_user(): array {
    $h=(string)($_SERVER['HTTP_AUTHORIZATION']??'');
    if(!preg_match('/^Bearer\s+(.+)$/i',$h,$m)) json_out(['ok'=>false,'error'=>'Bearer token required'],401);
    $token=trim($m[1]); if(strlen($token)<24) json_out(['ok'=>false,'error'=>'Invalid token'],401);
    $hash=hash('sha256',$token);
    $st=db()->prepare('SELECT t.id token_id,u.id,u.username,u.role,u.balance,u.active FROM api_tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=? AND t.enabled=1 LIMIT 1');$st->execute([$hash]);$u=$st->fetch();
    if(!$u || !(int)$u['active']) json_out(['ok'=>false,'error'=>'Token disabled'],401);
    db()->prepare('UPDATE api_tokens SET last_used_at=NOW() WHERE id=?')->execute([(int)$u['token_id']]); return $u;
}
function api_can(array $u,string $perm,?int $sid=null): bool {
    $p=role_permissions((string)$u['role']); if(in_array('*',$p,true))return true; if(!in_array($perm,$p,true))return false;
    if($sid!==null && !in_array((string)$u['role'],['owner','admin'],true))return user_has_server((int)$u['id'],$sid); return true;
}
function api_require(array $u,string $perm,?int $sid=null): void { if(!api_can($u,$perm,$sid))json_out(['ok'=>false,'error'=>'forbidden'],403); }
function api_audit(array $u,string $action,string $details='',?int $serverId=null): void { try{$st=db()->prepare('INSERT INTO audit_logs(user_id,server_id,action,details,ip) VALUES(?,?,?,?,?)');$st->execute([(int)$u['id'],$serverId,$action,$details,client_ip()]);}catch(Throwable){} }
function raw_body(): array { $x=json_decode((string)file_get_contents('php://input'),true); return is_array($x)?$x:$_POST; }
function api_server(int $id,array $u): array { $s=server_row_raw($id); api_require($u,'servers.view',$id); return $s; }

$u=api_bearer_user(); $action=(string)($_GET['action']??'servers'); $method=$_SERVER['REQUEST_METHOD']??'GET';
try{
    if($method==='GET' && $action==='servers'){
        if(in_array((string)$u['role'],['owner','admin'],true))$rows=db()->query('SELECT id,name,hostname,public_ip,port,slots,status_cache,current_map,players_online,cpu_percent,memory_mb,disk_mb,uptime_seconds FROM servers ORDER BY id DESC')->fetchAll();
        else{$st=db()->prepare('SELECT s.id,s.name,s.hostname,s.public_ip,s.port,s.slots,s.status_cache,s.current_map,s.players_online,s.cpu_percent,s.memory_mb,s.disk_mb,s.uptime_seconds FROM servers s JOIN server_users su ON su.server_id=s.id WHERE su.user_id=? ORDER BY s.id DESC');$st->execute([(int)$u['id']]);$rows=$st->fetchAll();}
        json_out(['ok'=>true,'servers'=>$rows]);
    }
    $id=(int)($_GET['server_id']??0);
    if($method==='GET' && in_array($action,['stats','ranking'],true)){
        if($id<1)json_out(['ok'=>false,'error'=>'server_id required'],400);api_server($id,$u);api_require($u,'sql.view',$id);
        if($action==='stats'){
            $st=db()->prepare('SELECT s.id,s.name,s.hostname,s.status_cache,s.current_map,s.players_online,s.max_players,s.ping_ms,s.uptime_seconds,(SELECT MAX(players) FROM server_stats ss WHERE ss.server_id=s.id AND ss.recorded_at>=NOW()-INTERVAL 24 HOUR) peak_24h,(SELECT ROUND(AVG(players),1) FROM server_stats ss WHERE ss.server_id=s.id AND ss.recorded_at>=NOW()-INTERVAL 24 HOUR) avg_24h,(SELECT COUNT(*) FROM player_stats ps WHERE ps.server_id=s.id) players_known FROM servers s WHERE s.id=?');$st->execute([$id]);json_out(['ok'=>true,'stats'=>$st->fetch()]);
        }
        $st=db()->prepare('SELECT name,steam_id,kills,deaths,headshots,suicides,current_score,play_seconds,sessions,last_seen,GREATEST(0,kills*2+headshots-deaths+FLOOR(play_seconds/600)) rating,ROUND(kills/GREATEST(deaths,1),2) kd FROM player_stats WHERE server_id=? ORDER BY rating DESC,kills DESC,play_seconds DESC LIMIT 100');$st->execute([$id]);json_out(['ok'=>true,'server_id'=>$id,'ranking'=>$st->fetchAll()]);
    }
    if($method==='GET' && in_array($action,['status','players'],true)){
        if($id<1)json_out(['ok'=>false,'error'=>'server_id required'],400);api_server($id,$u);
        api_require($u,$action==='players'?'server.players':'servers.view',$id);json_out(ctl([$action,$id],15));
    }
    if($method==='POST' && in_array($action,['start','stop','restart'],true)){
        $d=raw_body();$id=(int)($d['server_id']??$id);api_server($id,$u);api_require($u,'server.power',$id);$r=ctl([$action,$id],120);api_audit($u,'api_server_'.$action,'token '.(int)$u['token_id'],$id);json_out($r,empty($r['ok'])?400:200);
    }
    if($method==='POST' && $action==='change-map'){
        $d=raw_body();$id=(int)($d['server_id']??$id);api_server($id,$u);api_require($u,'server.map',$id);$map=trim((string)($d['map']??''));if(!preg_match('/^[A-Za-z0-9_-]{1,64}$/',$map))throw new RuntimeException('invalid map');$r=ctl(['activate-map',$id,$map],45);if(empty($r['ok'])){event_log('map_failed','API: не удалось запустить карту '.$map,$id,'danger');json_out($r,400);}db()->prepare('UPDATE servers SET start_map=?,current_map=? WHERE id=?')->execute([$map,$map,$id]);api_audit($u,'api_change_map',$map,$id);json_out($r);
    }
    if($method==='POST' && $action==='report'){
        $d=raw_body();$id=(int)($d['server_id']??$id);api_server($id,$u);api_require($u,'reports.create',$id);$reason=trim((string)($d['reason']??''));if($reason==='')throw new RuntimeException('reason required');$name=trim((string)($d['player_name']??''));$steam=trim((string)($d['steam_id']??''));$details=trim((string)($d['details']??''));$st=db()->prepare('INSERT INTO player_reports(server_id,player_name,steam_id,reason,details,created_by) VALUES(?,?,?,?,?,?)');$st->execute([$id,$name,$steam,$reason,$details,(int)$u['id']]);event_log('player_report','Новая жалоба: '.$reason,$id,'warning',['player'=>$name,'steam_id'=>$steam]);api_audit($u,'api_report',$reason,$id);json_out(['ok'=>true,'id'=>(int)db()->lastInsertId()]);
    }
    if($method==='POST' && $action==='create-server'){
        api_require($u,'servers.create');$d=raw_body();$name=trim((string)($d['name']??''));$hostname=trim((string)($d['hostname']??$name));$port=(int)($d['port']??27015);$slots=(int)($d['slots']??16);$map=trim((string)($d['map']??'de_dust2'));$profile=(string)($d['profile']??'classic');
        if($name===''||$port<27015||$port>27100||$slots<1||$slots>32||!preg_match('/^[A-Za-z0-9_-]{1,64}$/',$map))throw new RuntimeException('invalid server parameters');
        $st=db()->prepare("INSERT INTO servers(owner_user_id,name,hostname,public_ip,port,slots,start_map,build_profile,status_cache) VALUES(?,?,?,?,?,?,?,?, 'installing')");$st->execute([(int)$u['id'],$name,$hostname,(string)cfg('public_ip',''),$port,$slots,$map,in_array($profile,['classic','rehlds'],true)?$profile:'classic']);$sid=(int)db()->lastInsertId();db()->prepare('INSERT IGNORE INTO server_users(server_id,user_id) VALUES(?,?)')->execute([$sid,(int)$u['id']]);
        $r=ctl(['server-create',$sid,'--name',$name,'--port',$port,'--slots',$slots,'--map',$map,'--hostname',$hostname,'--password','','--profile',$profile],1800);if(empty($r['ok'])){db()->prepare("UPDATE servers SET status_cache='failed' WHERE id=?")->execute([$sid]);json_out($r,400);}db()->prepare("UPDATE servers SET installed=1,status_cache='starting',ftp_user=?,ftp_password=? WHERE id=?")->execute([(string)($r['ftp_user']??''),(string)($r['ftp_password']??''),$sid]);api_audit($u,'api_server_create',$name,$sid);json_out(['ok'=>true,'server_id'=>$sid]+$r);
    }
    if($method==='POST' && $action==='delete-server'){
        $d=raw_body();$id=(int)($d['server_id']??$id);api_server($id,$u);api_require($u,'server.delete',$id);$r=ctl(['delete',$id],180);if(empty($r['ok']))json_out($r,400);db()->prepare('DELETE FROM servers WHERE id=?')->execute([$id]);api_audit($u,'api_server_delete','#'.$id,null);json_out(['ok'=>true,'id'=>$id]);
    }
    json_out(['ok'=>false,'error'=>'unknown action'],404);
}catch(Throwable $e){json_out(['ok'=>false,'error'=>$e->getMessage()],400);}
