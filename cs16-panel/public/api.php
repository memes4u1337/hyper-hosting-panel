<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
require_auth(true);
$id=(int)($_REQUEST['server_id']??$_REQUEST['id']??0);
$view=(string)($_REQUEST['view']??'status');
try {
    if($_SERVER['REQUEST_METHOD']==='POST'){
        check_csrf(); if($id<1) json_out(['ok'=>false,'error'=>'server_id required'],400); server_row($id);
        if($view==='rcon'){
            $cmd=trim((string)($_POST['command']??'')); if($cmd===''||strlen($cmd)>512)throw new RuntimeException('Некорректная команда');$r=ctl(['rcon',$id,$cmd],20);audit('rcon',$cmd,$id);json_out($r,empty($r['ok'])?400:200);
        }
        if($view==='change-map'){
            $map=trim((string)($_POST['map']??''));if(!preg_match('/^[A-Za-z0-9_-]{1,64}$/',$map))throw new RuntimeException('Некорректная карта');$r=ctl(['change-map',$id,$map],20);audit('change_map',$map,$id);json_out($r,empty($r['ok'])?400:200);
        }
        if($view==='kick'){
            $uid=(int)($_POST['userid']??-1);$r=ctl(['kick',$id,$uid],20);audit('player_kick','#'.$uid,$id);json_out($r,empty($r['ok'])?400:200);
        }
        if($view==='ban'){
            $uid=(int)($_POST['userid']??-1);$minutes=max(0,min(10080,(int)($_POST['minutes']??30)));$r=ctl(['ban',$id,$uid,'--minutes',$minutes],20);audit('player_ban','#'.$uid.' '.$minutes.'m',$id);json_out($r,empty($r['ok'])?400:200);
        }
        if($view==='plugin-toggle'){
            $plugin=(string)($_POST['plugin']??'');$state=(string)($_POST['state']??'off');$r=ctl(['plugin-toggle',$id,$plugin,$state==='on'?'on':'off'],30);audit('plugin_toggle',$plugin.'='.$state,$id);json_out($r,empty($r['ok'])?400:200);
        }
        if($view==='config-save'){
            $name=(string)($_POST['name']??'');$content=(string)($_POST['content']??'');$allowed=['server.cfg','amxx.cfg','users.ini','plugins.ini','modules.ini','mapcycle.txt','maps.ini'];if(!in_array($name,$allowed,true))throw new RuntimeException('Файл запрещён');if(strlen($content)>524288)throw new RuntimeException('Файл слишком большой');$r=ctl(['config-write',$id,$name],30,$content);audit('config_save',$name,$id);json_out($r,empty($r['ok'])?400:200);
        }
        json_out(['ok'=>false,'error'=>'Unknown API action'],404);
    }
    if($id<1 && $view!=='doctor') json_out(['ok'=>false,'error'=>'server_id required'],400);
    if($id>0) server_row($id);
    if($view==='status') json_out(ctl(['status',$id],10));
    if($view==='players') json_out(ctl(['players',$id],10));
    if($view==='maps') json_out(ctl(['maps',$id],10));
    if($view==='plugins') json_out(ctl(['plugins',$id],10));
    if($view==='logs') json_out(ctl(['logs',$id,'--lines',200],10));
    if($view==='network') json_out(ctl(['network',$id],15));
    if($view==='ftp-test') json_out(ctl(['ftp-test',$id],20));
    if($view==='config'){
        $name=(string)($_GET['name']??'server.cfg');$allowed=['server.cfg','amxx.cfg','users.ini','plugins.ini','modules.ini','mapcycle.txt','maps.ini'];if(!in_array($name,$allowed,true))throw new RuntimeException('Файл запрещён');json_out(ctl(['config-read',$id,$name],10));
    }
    if($view==='history'){
        $hours=max(1,min(168,(int)($_GET['hours']??24)));$st=db()->prepare('SELECT recorded_at,players,max_players,cpu_percent,memory_mb,ping_ms,map_name FROM server_stats WHERE server_id=? AND recorded_at>=NOW()-INTERVAL '.$hours.' HOUR ORDER BY recorded_at ASC LIMIT 2500');$st->execute([$id]);json_out(['ok'=>true,'rows'=>$st->fetchAll()]);
    }
    if($view==='player-history'){
        $st=db()->prepare('SELECT name,steam_id,last_seen,first_seen,visits FROM player_history WHERE server_id=? ORDER BY last_seen DESC LIMIT 200');$st->execute([$id]);json_out(['ok'=>true,'rows'=>$st->fetchAll()]);
    }
    if($view==='doctor') json_out(ctl(['doctor'],40));
    json_out(['ok'=>false,'error'=>'Unknown view'],404);
} catch(Throwable $ex){ json_out(['ok'=>false,'error'=>$ex->getMessage()],400); }
