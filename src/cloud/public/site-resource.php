<?php
declare(strict_types=1);
require __DIR__.'/../app/bootstrap.php';
require __DIR__.'/../app/filelib.php';
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: private, no-store, max-age=0');
header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()');

try {
    $token=(string)($_GET['t']??'');
    $payload=hcfl_preview_verify($token);
    $uid=(int)($payload['uid']??0);$user=hc_cloud_user_by_id($uid);if(!$user)throw new RuntimeException('Предпросмотр недоступен');
    $space=hcfl_space((string)($payload['space']??'private'));
    $root=hcfl_clean_rel((string)($payload['root']??''));
    $resource=hcfl_clean_rel((string)($_GET['r']??''));if($resource==='')throw new RuntimeException('Ресурс не найден');
    $archive=hcfl_clean_rel((string)($payload['archive']??''));
    $full=trim(($root!==''?$root.'/':'').$resource,'/');
    $actualFull=$full;

    if($archive!=='') {
        [,,$archivePath]=hcfl_resolve($user,$space,$archive,true);
        if(!is_file($archivePath)||!hcfl_archive_name($archivePath))throw new RuntimeException('Архив недоступен');
        $candidate=$full;
        try{$data=hcfl_archive_read_bytes($archivePath,$candidate,134217728);}catch(Throwable $first){
            if(pathinfo($resource,PATHINFO_EXTENSION)!=='')throw $first;
            $candidate=rtrim($full,'/').'/index.html';$data=hcfl_archive_read_bytes($archivePath,$candidate,134217728);
        }
        $body=(string)$data['content'];$actualFull=(string)$data['entry'];
    } else {
        $candidate=$full;
        try{[,,$path]=hcfl_resolve_casefold($user,$space,$candidate);}catch(Throwable $first){
            if(pathinfo($resource,PATHINFO_EXTENSION)!=='')throw $first;
            $candidate=rtrim($full,'/').'/index.html';[,,$path]=hcfl_resolve_casefold($user,$space,$candidate);
        }
        if(is_dir($path)){$candidate=rtrim($candidate,'/').'/index.html';[,,$path]=hcfl_resolve_casefold($user,$space,$candidate);}
        if(!is_file($path))throw new RuntimeException('Ресурс не найден');
        $size=(int)(@filesize($path)?:0);if($size>134217728)throw new RuntimeException('Ресурс слишком большой для предпросмотра');
        $body=@file_get_contents($path);if(!is_string($body))throw new RuntimeException('Ресурс недоступен');
        $actualFull=$candidate;
    }

    if(!hcfl_web_asset_allowed($actualFull))throw new RuntimeException('Тип ресурса запрещён');
    $ext=strtolower(pathinfo($actualFull,PATHINFO_EXTENSION));
    if(in_array($ext,['html','htm'],true)){
        $body=hcfl_rewrite_html($body,$actualFull,$root,$token);
        header("Content-Security-Policy: sandbox allow-scripts allow-forms allow-modals allow-popups allow-downloads; default-src 'self' data: blob: https:; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: blob: https:; media-src 'self' blob: https:; font-src 'self' data: https:; connect-src 'self' https:; frame-src https:; object-src 'none'; base-uri 'none'");
    } elseif($ext==='css') {
        $body=hcfl_rewrite_css($body,$actualFull,$root,$token);
    } elseif(in_array($ext,['js','mjs','cjs'],true)) {
        $body=hcfl_rewrite_js($body,$actualFull,$root,$token);
    }
    header('Content-Type: '.hcfl_mime_name($actualFull));
    header('Content-Length: '.strlen($body));
    echo $body;
} catch(Throwable $e) {
    error_log('HYPER CLOUD site-resource: '.$e->getMessage().' r='.(string)($_GET['r']??''));
    http_response_code(404);header('Content-Type: text/plain; charset=utf-8');echo 'Resource unavailable';
}
