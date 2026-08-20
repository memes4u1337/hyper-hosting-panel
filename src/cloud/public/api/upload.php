<?php
declare(strict_types=1);

/** HYPER CLOUD v103 chunk upload API. Always returns JSON. */
require dirname(__DIR__, 2) . '/app/bootstrap.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
@set_time_limit(0);
@ini_set('max_execution_time','0');

function api_json(array $data, int $status = 200): never
{
    http_response_code($status);
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function api_clean_rel(string $value): string
{
    $value = str_replace(["\0", '\\'], ['', '/'], trim($value));
    $parts = [];
    foreach (explode('/', $value) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..' || preg_match('/[\x00-\x1F\x7F]/u', $part)) throw new RuntimeException('Недопустимый путь');
        $parts[] = $part;
    }
    return implode('/', $parts);
}
function api_valid_name(string $name): string
{
    $name = trim(str_replace("\0", '', basename($name)));
    if ($name === '' || in_array($name, ['.','..'], true)) throw new RuntimeException('Некорректное имя файла');
    if (preg_match('/[\\\/\x00-\x1F\x7F]/u', $name)) throw new RuntimeException('Недопустимое имя файла');
    if ((function_exists('mb_strlen') ? mb_strlen($name) : strlen($name)) > 180) throw new RuntimeException('Слишком длинное имя файла');
    return $name;
}
function api_space(): string { return ((string)($_POST['space'] ?? 'private') === 'shared') ? 'shared' : 'private'; }
function api_root(array $user): string
{
    hc_ensure_user_root($user);
    return hc_root_for_user($user, api_space());
}
function api_resolve_dir(array $user, string $rel): array
{
    $rel = api_clean_rel($rel);
    $root = api_root($user);
    $rootReal = realpath($root) ?: $root;
    $path = $root . ($rel !== '' ? '/' . $rel : '');
    $real = realpath($path);
    if ($real === false || !is_dir($real) || is_link($path)) throw new RuntimeException('Папка загрузки не найдена');
    if ($real !== $rootReal && !str_starts_with($real, $rootReal . DIRECTORY_SEPARATOR)) throw new RuntimeException('Недопустимый путь');
    return [$rel, $real];
}
function api_unique_target(string $dir, string $name): string
{
    $target = $dir . '/' . $name;
    if (!file_exists($target) && !is_link($target)) return $target;
    $info = pathinfo($name); $base = (string)($info['filename'] ?? $name); $ext = !empty($info['extension']) ? '.'.$info['extension'] : '';
    for ($i=1; $i<=99999; $i++) { $candidate=$dir.'/'.$base.' ('.$i.')'.$ext; if(!file_exists($candidate)&&!is_link($candidate)) return $candidate; }
    throw new RuntimeException('Не удалось подобрать имя файла');
}
function api_upload_base(array $user): string
{
    $key = preg_replace('/[^A-Za-z0-9_.-]/', '_', (string)($user['storage_key'] ?? 'user')) ?: 'user';
    $dir = rtrim((string)app_config('cloud_meta_dir','/var/lib/hyper-host-cloud'),'/') . '/uploads/' . $key;
    if (!is_dir($dir) && !@mkdir($dir,02770,true) && !is_dir($dir)) throw new RuntimeException('Не удалось подготовить временную папку');
    @chmod($dir,02770); @chown($dir,'www-data'); @chgrp($dir,'www-data');
    return $dir;
}
function api_session_dir(array $user, string $id, bool $create = true): string
{
    $id = strtolower(trim($id));
    if (!preg_match('/^[a-f0-9]{32,64}$/',$id)) throw new RuntimeException('Некорректный идентификатор загрузки');
    $dir = api_upload_base($user).'/'.$id;
    if ($create && !is_dir($dir) && !@mkdir($dir,02770,true) && !is_dir($dir)) throw new RuntimeException('Не удалось создать сессию загрузки');
    return $dir;
}
function api_read_meta(string $dir): array
{
    $raw=@file_get_contents($dir.'/meta.json'); $data=json_decode(is_string($raw)?$raw:'',true); return is_array($data)?$data:[];
}
function api_remove_tree(string $path): void
{
    if (!is_dir($path)) { @unlink($path); return; }
    foreach (scandir($path) ?: [] as $n) { if ($n==='.'||$n==='..') continue; $p=$path.'/'.$n; is_dir($p)&&!is_link($p)?api_remove_tree($p):@unlink($p); }
    @rmdir($path);
}

try {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') api_json(['ok'=>false,'error'=>'Метод не поддерживается'],405);
    $user = current_user();
    if (!$user) api_json(['ok'=>false,'error'=>'Сессия завершена. Войдите в HYPER CLOUD заново.','auth'=>false],401);
    check_csrf();
    $action=(string)($_POST['action']??'');

    if ($action === 'upload_chunk') {
        $id=(string)($_POST['upload_id']??'');
        $index=(int)($_POST['chunk_index']??-1); $total=(int)($_POST['total_chunks']??0);
        if ($index<0 || $total<1 || $index >= $total || $total > 2000000) throw new RuntimeException('Некорректная часть файла');
        $name=api_valid_name((string)($_POST['file_name']??'')); $size=max(0,(int)($_POST['file_size']??0));
        [$targetRel,$targetDir]=api_resolve_dir($user,(string)($_POST['upload_target']??''));
        if (!isset($_FILES['chunk'])) throw new RuntimeException('Часть файла не получена');
        $err=(int)($_FILES['chunk']['error']??UPLOAD_ERR_NO_FILE);
        if ($err!==UPLOAD_ERR_OK) throw new RuntimeException('PHP не принял часть файла (код '.$err.')');
        $tmp=(string)($_FILES['chunk']['tmp_name']??''); if($tmp===''||!is_uploaded_file($tmp)) throw new RuntimeException('Временный файл загрузки недоступен');
        $dir=api_session_dir($user,$id,true); $meta=api_read_meta($dir);
        $expected=['user_id'=>(int)$user['id'],'space'=>api_space(),'file_name'=>$name,'file_size'=>$size,'total_chunks'=>$total,'upload_target'=>$targetRel];
        if (!$meta) {
            $meta=$expected+['created_at'=>time(),'updated_at'=>time()];
            if (@file_put_contents($dir.'/meta.json',json_encode($meta,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),LOCK_EX)===false) throw new RuntimeException('Не удалось создать сессию загрузки');
        } else {
            foreach($expected as $k=>$v) if((string)($meta[$k]??'')!==(string)$v) throw new RuntimeException('Параметры загрузки не совпадают');
        }
        $part=$dir.'/'.sprintf('%08d.part',$index);
        if (!@move_uploaded_file($tmp,$part)) throw new RuntimeException('Не удалось сохранить часть файла');
        @chmod($part,0660); @touch($dir.'/meta.json');
        api_json(['ok'=>true,'chunk'=>$index,'received'=>(int)(filesize($part)?:0)]);
    }

    if ($action === 'upload_complete') {
        $id=(string)($_POST['upload_id']??''); $dir=api_session_dir($user,$id,false); if(!is_dir($dir)) throw new RuntimeException('Сессия загрузки не найдена');
        $meta=api_read_meta($dir); if(!$meta)throw new RuntimeException('Сессия загрузки повреждена');
        if((int)($meta['user_id']??0)!==(int)$user['id'] || (string)($meta['space']??'')!==api_space()) throw new RuntimeException('Загрузка принадлежит другому аккаунту');
        [$targetRel,$targetDir]=api_resolve_dir($user,(string)($meta['upload_target']??''));
        $total=(int)($meta['total_chunks']??0); if($total<1)throw new RuntimeException('Некорректное число частей');
        $name=api_valid_name((string)($meta['file_name']??'')); $expected=max(0,(int)($meta['file_size']??0));
        $final=api_unique_target($targetDir,$name); $tmpFinal=$targetDir.'/.hc-upload-'.preg_replace('/[^a-f0-9]/','',strtolower($id)).'.part';
        $out=@fopen($tmpFinal,'wb'); if(!$out)throw new RuntimeException('Не удалось создать итоговый файл');
        $written=0;
        try {
            for($i=0;$i<$total;$i++) {
                $part=$dir.'/'.sprintf('%08d.part',$i); if(!is_file($part))throw new RuntimeException('Не получена часть '.($i+1).' из '.$total);
                $in=@fopen($part,'rb'); if(!$in)throw new RuntimeException('Не удалось прочитать часть '.($i+1));
                $n=stream_copy_to_stream($in,$out); fclose($in); if($n===false)throw new RuntimeException('Ошибка сборки файла'); $written+=(int)$n;
            }
        } finally { fclose($out); }
        if($expected!==$written){@unlink($tmpFinal);throw new RuntimeException('Файл загружен не полностью: '.human_bytes($written).' из '.human_bytes($expected));}
        if(!@rename($tmpFinal,$final)){@unlink($tmpFinal);throw new RuntimeException('Не удалось завершить загрузку');}
        @chmod($final,0660);@chown($final,'www-data');@chgrp($final,'www-data');
        $finalRel=trim($targetRel.'/'.basename($final),'/'); if(api_space()==='shared')hc_shared_mark($finalRel,(int)$user['id'],'file');
        api_remove_tree($dir); add_event('cloud','Загружен файл: '.$finalRel);
        $query=api_space()==='shared'?('?space=shared'.($targetRel!==''?'&path='.rawurlencode($targetRel):'')):($targetRel!==''?'?path='.rawurlencode($targetRel):'');
        api_json(['ok'=>true,'file'=>basename($final),'path'=>$finalRel,'size'=>$written,'redirect'=>'/'.$query]);
    }

    if ($action === 'upload') {
        [$targetRel,$targetDir]=api_resolve_dir($user,(string)($_POST['upload_target']??''));
        if (!isset($_FILES['files'])) throw new RuntimeException('Выберите файлы');
        $names=is_array($_FILES['files']['name']??null)?$_FILES['files']['name']:[($_FILES['files']['name']??'')];
        $tmps=is_array($_FILES['files']['tmp_name']??null)?$_FILES['files']['tmp_name']:[($_FILES['files']['tmp_name']??'')];
        $errors=is_array($_FILES['files']['error']??null)?$_FILES['files']['error']:[($_FILES['files']['error']??UPLOAD_ERR_NO_FILE)];
        $count=0;
        foreach($names as $i=>$raw){
            $err=(int)($errors[$i]??UPLOAD_ERR_NO_FILE); if($err===UPLOAD_ERR_NO_FILE)continue;
            if($err!==UPLOAD_ERR_OK)throw new RuntimeException('PHP не принял файл '.(string)$raw.' (код '.$err.')');
            $tmp=(string)($tmps[$i]??'');if($tmp===''||!is_uploaded_file($tmp))throw new RuntimeException('Временный файл недоступен');
            $name=api_valid_name((string)$raw);$final=api_unique_target($targetDir,$name);
            if(!@move_uploaded_file($tmp,$final))throw new RuntimeException('Не удалось сохранить '.$name);
            @chmod($final,0660);@chown($final,'www-data');@chgrp($final,'www-data');
            $rel=trim($targetRel.'/'.basename($final),'/');if(api_space()==='shared')hc_shared_mark($rel,(int)$user['id'],'file');$count++;
        }
        if($count<1)throw new RuntimeException('Не удалось загрузить файлы');
        add_event('cloud','Загружено файлов: '.$count.' в /'.$targetRel);
        $query=api_space()==='shared'?('?space=shared'.($targetRel!==''?'&path='.rawurlencode($targetRel):'')):($targetRel!==''?'?path='.rawurlencode($targetRel):'');
        if ((string)($_POST['ajax_upload']??'')==='1') api_json(['ok'=>true,'uploaded'=>$count,'redirect'=>'/'.$query]);
        header('Location: /'.$query); exit;
    }

    if ($action === 'upload_cancel') {
        $dir=api_session_dir($user,(string)($_POST['upload_id']??''),false); if(is_dir($dir))api_remove_tree($dir); api_json(['ok'=>true]);
    }

    api_json(['ok'=>false,'error'=>'Неизвестная операция'],400);
} catch (Throwable $e) {
    error_log('HYPER CLOUD upload: '.$e->getMessage());
    api_json(['ok'=>false,'error'=>$e->getMessage()],400);
}
