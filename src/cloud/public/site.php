<?php
declare(strict_types=1);
require __DIR__.'/../app/bootstrap.php';
require __DIR__.'/../app/filelib.php';
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: private, no-store, max-age=0');
header('X-Frame-Options: SAMEORIGIN');
header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()');
header("Content-Security-Policy: default-src 'self'; frame-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'self'");

$user=require_auth();$space=hcfl_space((string)($_GET['space']??'private'));$rel='';$entry='';$error='';$src='';$title='Предпросмотр сайта';
try{
    $rel=hcfl_clean_rel((string)($_GET['path']??''));if($rel==='')throw new RuntimeException('HTML-файл не выбран');
    [,,$path]=hcfl_resolve($user,$space,$rel,true);if(!is_file($path))throw new RuntimeException('Файл не найден');
    $entry=trim((string)($_GET['entry']??''));
    if($entry!==''){
        if(!hcfl_archive_name($path))throw new RuntimeException('Архив не найден');$entry=hcfl_entry_clean($entry);if(!hcfl_html_name($entry))throw new RuntimeException('Выбранный файл не является HTML');
        // Preflight with the same archive reader used by site-resource.php. This
        // catches unsupported/corrupt archives before the browser opens the frame.
        $read=hcfl_archive_read_bytes($path,$entry,134217728);$current=(string)$read['entry'];$root=dirname($current);if($root==='.')$root='';
        $payload=['uid'=>(int)$user['id'],'space'=>$space,'archive'=>$rel,'root'=>$root];$resource=$root!==''?(string)substr($current,strlen($root)+1):$current;$title=basename($current);
    }else{
        if(!hcfl_html_name($path))throw new RuntimeException('Выбранный файл не является HTML');$size=(int)(@filesize($path)?:0);if($size>134217728)throw new RuntimeException('HTML-файл слишком большой для предпросмотра');
        $probe=@file_get_contents($path);if(!is_string($probe))throw new RuntimeException('Не удалось прочитать HTML-файл');$root=dirname($rel);if($root==='.')$root='';$payload=['uid'=>(int)$user['id'],'space'=>$space,'archive'=>'','root'=>$root];$resource=$root!==''?(string)substr($rel,strlen($root)+1):$rel;$title=basename($rel);
    }
    $token=hcfl_preview_token($payload,3600);$src=hcfl_preview_url($token,$resource);
}catch(Throwable $e){$error=$e->getMessage();error_log('HYPER CLOUD site preview: '.$error.' path='.$rel.' entry='.$entry);http_response_code(400);}
?><!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=e($title)?></title><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#fff}.frame{display:block;width:100%;height:100%;border:0;background:#fff}.err{min-height:100%;display:grid;place-items:center;padding:24px;box-sizing:border-box;background:#090e1a;color:#e7edf8;font-family:Inter,system-ui,-apple-system,Segoe UI,sans-serif}.card{width:min(520px,100%);padding:34px;border:1px solid #283651;border-radius:24px;background:#10182a;text-align:center;box-shadow:0 30px 80px rgba(0,0,0,.38)}.card b{display:block;font-size:20px;margin-bottom:10px}.card p{margin:0;color:#94a2ba;line-height:1.6}</style></head><body><?php if($error!==''):?><div class="err"><div class="card"><b>Не удалось открыть страницу</b><p><?=e($error)?></p></div></div><?php else:?><iframe class="frame" sandbox="allow-scripts allow-forms allow-modals allow-popups allow-downloads" referrerpolicy="no-referrer" src="<?=e($src)?>"></iframe><?php endif;?></body></html>
