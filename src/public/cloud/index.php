<?php
declare(strict_types=1);

/**
 * HYPER CLOUD v96 — standalone private cloud for HYPER-HOST.
 * This page intentionally does NOT use render_page() and has its own UI shell.
 */
require __DIR__ . '/../../app/bootstrap.php';

if (!current_user()) {
    $_SESSION['after_login'] = '/cloud/';
    redirect('/?page=login');
}
$user = require_auth();

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');

function hc_csrf_field(): string
{
    return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">';
}

function hc_root(): string
{
    $root = rtrim((string)app_config('cloud_dir', '/var/www/hyper-host-cloud'), '/');
    return $root !== '' ? $root : '/var/www/hyper-host-cloud';
}

function hc_clean_rel(string $value): string
{
    $value = str_replace("\0", '', $value);
    $value = str_replace('\\', '/', trim($value));
    $parts = [];
    foreach (explode('/', $value) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') throw new RuntimeException('Недопустимый путь');
        if (preg_match('/[\x00-\x1F\x7F]/u', $part)) throw new RuntimeException('Недопустимое имя');
        $parts[] = $part;
    }
    return implode('/', $parts);
}

function hc_resolve(string $rel = '', bool $mustExist = false): array
{
    $root = hc_root();
    if (!is_dir($root)) @mkdir($root, 02770, true);
    $rel = hc_clean_rel($rel);
    $rootReal = realpath($root) ?: $root;
    $path = $root . ($rel !== '' ? '/' . $rel : '');

    if ($mustExist && !file_exists($path) && !is_link($path)) {
        throw new RuntimeException('Файл или папка не найдены');
    }

    if (file_exists($path) || is_link($path)) {
        if (is_link($path)) throw new RuntimeException('Символические ссылки в облаке запрещены');
        $real = realpath($path);
        if ($real === false || ($real !== $rootReal && !str_starts_with($real, $rootReal . DIRECTORY_SEPARATOR))) {
            throw new RuntimeException('Выход за пределы облака запрещён');
        }
    } else {
        $parentReal = realpath(dirname($path));
        if ($parentReal === false || ($parentReal !== $rootReal && !str_starts_with($parentReal, $rootReal . DIRECTORY_SEPARATOR))) {
            throw new RuntimeException('Недопустимый путь');
        }
    }
    return [$root, $rel, $path];
}


function hc_strlen(string $value): int
{
    return function_exists('mb_strlen') ? mb_strlen($value) : strlen($value);
}

function hc_lower(string $value): string
{
    return function_exists('mb_strtolower') ? mb_strtolower($value) : strtolower($value);
}

function hc_initial(string $value): string
{
    $char = function_exists('mb_substr') ? mb_substr($value, 0, 1) : substr($value, 0, 1);
    return function_exists('mb_strtoupper') ? mb_strtoupper($char) : strtoupper($char);
}

function hc_valid_name(string $name): string
{
    $name = trim(str_replace("\0", '', $name));
    if ($name === '' || in_array($name, ['.', '..'], true)) throw new RuntimeException('Укажите имя');
    if (preg_match('/[\\\/\x00-\x1F\x7F]/u', $name)) throw new RuntimeException('В имени нельзя использовать / или \\');
    if (hc_strlen($name) > 180) throw new RuntimeException('Слишком длинное имя');
    return $name;
}

function hc_unique_target(string $dir, string $name): string
{
    $target = $dir . '/' . $name;
    if (!file_exists($target) && !is_link($target)) return $target;
    $info = pathinfo($name);
    $base = (string)($info['filename'] ?? $name);
    $ext = isset($info['extension']) && $info['extension'] !== '' ? '.' . $info['extension'] : '';
    for ($i = 1; $i <= 9999; $i++) {
        $candidate = $dir . '/' . $base . ' (' . $i . ')' . $ext;
        if (!file_exists($candidate) && !is_link($candidate)) return $candidate;
    }
    throw new RuntimeException('Не удалось подобрать свободное имя');
}

function hc_url(array $params = []): string
{
    return '/cloud/' . ($params ? '?' . http_build_query($params, '', '&', PHP_QUERY_RFC3986) : '');
}

function hc_mime(string $path): string
{
    if (class_exists('finfo')) {
        $f = new finfo(FILEINFO_MIME_TYPE);
        $mime = $f->file($path);
        if (is_string($mime) && $mime !== '') return $mime;
    }
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    return match ($ext) {
        'jpg','jpeg' => 'image/jpeg', 'png' => 'image/png', 'gif' => 'image/gif', 'webp' => 'image/webp', 'svg' => 'image/svg+xml',
        'pdf' => 'application/pdf', 'mp4' => 'video/mp4', 'webm' => 'video/webm', 'mp3' => 'audio/mpeg', 'ogg' => 'audio/ogg',
        default => 'application/octet-stream',
    };
}

function hc_is_archive(string $path): bool
{
    $name = strtolower(basename($path));
    foreach (['.zip','.rar','.7z','.tar','.tar.gz','.tgz','.tar.bz2','.tbz2','.tar.xz','.txz','.gz','.bz2','.xz'] as $ext) {
        if (str_ends_with($name, $ext)) return true;
    }
    return false;
}

function hc_is_image(string $path): bool
{
    return str_starts_with(hc_mime($path), 'image/');
}

function hc_is_text(string $path): bool
{
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    if (in_array($ext, ['txt','log','md','json','xml','csv','ini','env','conf','yml','yaml','php','py','js','ts','css','scss','html','htm','sql','sh','bat','ps1','c','cpp','h','hpp','java','go','rs'], true)) return true;
    $sample = @file_get_contents($path, false, null, 0, 4096);
    return is_string($sample) && !str_contains($sample, "\0");
}

function hc_archive_entries(string $path, int $limit = 1000): array
{
    $entries = [];
    if (str_ends_with(strtolower($path), '.zip') && class_exists('ZipArchive')) {
        $zip = new ZipArchive();
        if ($zip->open($path) === true) {
            $count = min($zip->numFiles, $limit);
            for ($i = 0; $i < $count; $i++) {
                $st = $zip->statIndex($i);
                if (!is_array($st)) continue;
                $entries[] = [
                    'name' => (string)($st['name'] ?? ''),
                    'size' => (int)($st['size'] ?? 0),
                    'packed' => (int)($st['comp_size'] ?? 0),
                    'modified' => !empty($st['mtime']) ? date('d.m.Y H:i', (int)$st['mtime']) : '—',
                ];
            }
            $truncated = $zip->numFiles > $limit;
            $zip->close();
            return ['ok'=>true,'entries'=>$entries,'truncated'=>$truncated,'engine'=>'ZipArchive'];
        }
    }

    $commands = [];
    if (is_executable('/usr/bin/7z')) $commands[] = ['/usr/bin/7z','l','-slt','--',$path];
    if (is_executable('/usr/bin/7zz')) $commands[] = ['/usr/bin/7zz','l','-slt','--',$path];
    if (is_executable('/usr/bin/bsdtar')) $commands[] = ['/usr/bin/bsdtar','-tf',$path];

    foreach ($commands as $cmd) {
        $line = implode(' ', array_map('escapeshellarg', $cmd)) . ' 2>&1';
        $out = []; $code = 0; exec($line, $out, $code);
        if ($code !== 0 && !$out) continue;
        if (str_contains($cmd[0], '7z')) {
            $current = [];
            foreach ($out as $raw) {
                $raw = rtrim((string)$raw);
                if ($raw === '') {
                    if (!empty($current['Path'])) {
                        $n = (string)$current['Path'];
                        if ($n !== $path && $n !== basename($path)) {
                            $entries[] = ['name'=>$n,'size'=>(int)($current['Size']??0),'packed'=>(int)($current['Packed Size']??0),'modified'=>(string)($current['Modified']??'—')];
                            if (count($entries) >= $limit) break;
                        }
                    }
                    $current = [];
                    continue;
                }
                if (preg_match('/^([^=]+) = (.*)$/', $raw, $m)) $current[trim($m[1])] = $m[2];
            }
            if ($entries) return ['ok'=>true,'entries'=>$entries,'truncated'=>count($entries)>=$limit,'engine'=>basename($cmd[0])];
        } else {
            foreach ($out as $raw) {
                if (count($entries) >= $limit) break;
                $raw = trim((string)$raw);
                if ($raw !== '') $entries[] = ['name'=>$raw,'size'=>0,'packed'=>0,'modified'=>'—'];
            }
            if ($entries) return ['ok'=>true,'entries'=>$entries,'truncated'=>count($entries)>=$limit,'engine'=>'bsdtar'];
        }
    }
    return ['ok'=>false,'entries'=>[],'truncated'=>false,'engine'=>'','error'=>'Не удалось прочитать архив. Установите p7zip-full/libarchive-tools.'];
}

function hc_stream_file(string $path, bool $inline = false): never
{
    if (!is_file($path) || is_link($path) || !is_readable($path)) throw new RuntimeException('Файл недоступен');
    while (ob_get_level() > 0) @ob_end_clean();
    @set_time_limit(0);
    $size = (int)filesize($path); $start = 0; $end = max(0, $size - 1); $status = 200;
    $range = (string)($_SERVER['HTTP_RANGE'] ?? '');
    if ($size > 0 && preg_match('/bytes=(\d*)-(\d*)/', $range, $m)) {
        if ($m[1] === '' && $m[2] !== '') { $suffix = min((int)$m[2], $size); $start = $size - $suffix; }
        else { $start = $m[1] !== '' ? (int)$m[1] : 0; $end = $m[2] !== '' ? min((int)$m[2], $size - 1) : $size - 1; }
        if ($start < 0 || $start > $end || $start >= $size) { header('Content-Range: bytes */'.$size); http_response_code(416); exit; }
        $status = 206;
    }
    $length = $size > 0 ? ($end - $start + 1) : 0;
    http_response_code($status);
    header('Content-Type: ' . hc_mime($path));
    header('Accept-Ranges: bytes');
    header('Cache-Control: private, no-store');
    header('X-Content-Type-Options: nosniff');
    if ($inline) header("Content-Security-Policy: sandbox; default-src 'none'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'unsafe-inline'");
    if ($status === 206) header('Content-Range: bytes '.$start.'-'.$end.'/'.$size);
    header('Content-Length: ' . $length);
    $name = basename($path);
    $fallback = preg_replace('/[^A-Za-z0-9._-]+/', '_', $name) ?: 'download';
    $disposition = $inline ? 'inline' : 'attachment';
    header("Content-Disposition: {$disposition}; filename=\"{$fallback}\"; filename*=UTF-8''" . rawurlencode($name));
    $fh = fopen($path, 'rb'); if ($fh === false) exit;
    if ($start > 0) fseek($fh, $start);
    $remaining = $length;
    while (!feof($fh) && $remaining > 0) {
        $chunk = fread($fh, min(1024 * 1024, $remaining));
        if ($chunk === false || $chunk === '') break;
        echo $chunk; $remaining -= strlen($chunk); flush();
        if (connection_aborted()) break;
    }
    fclose($fh); exit;
}

function hc_rrmdir(string $path): void
{
    if (is_link($path)) throw new RuntimeException('Символические ссылки запрещены');
    if (is_file($path)) { if (!@unlink($path)) throw new RuntimeException('Не удалось удалить файл'); return; }
    if (!is_dir($path)) return;
    foreach (scandir($path) ?: [] as $item) {
        if ($item === '.' || $item === '..') continue;
        hc_rrmdir($path . '/' . $item);
    }
    if (!@rmdir($path)) throw new RuntimeException('Не удалось удалить папку');
}

function hc_folder_tree(string $root, int $limit = 500, int $maxDepth = 20): array
{
    $result = []; $seen = 0;
    $walk = function(string $dir, string $rel, int $depth) use (&$walk,&$result,&$seen,$limit,$maxDepth): void {
        if ($seen >= $limit || $depth > $maxDepth) return;
        $names = array_values(array_filter(scandir($dir) ?: [], static fn($v)=>$v!=='.'&&$v!=='..'));
        natcasesort($names);
        foreach ($names as $name) {
            if ($seen >= $limit) break;
            $path = $dir.'/'.$name;
            if (!is_dir($path) || is_link($path)) continue;
            $childRel = trim($rel.'/'.$name,'/');
            $result[] = ['path'=>$childRel,'name'=>$name,'depth'=>$depth];
            $seen++; $walk($path,$childRel,$depth+1);
        }
    };
    $walk($root,'',0); return $result;
}

function hc_recursive_files(string $root, string $mode, int $limit = 250): array
{
    $rows = [];
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $file) {
        if (count($rows) >= $limit) break;
        if (!$file instanceof SplFileInfo || !$file->isFile() || $file->isLink()) continue;
        $path = $file->getPathname();
        $ok = match ($mode) {
            'archives' => hc_is_archive($path),
            'images' => hc_is_image($path),
            default => true,
        };
        if (!$ok) continue;
        $rel = ltrim(str_replace('\\','/',substr($path, strlen(rtrim($root,'/')))), '/');
        $rows[] = ['name'=>$file->getFilename(),'path'=>$path,'rel'=>$rel,'mtime'=>$file->getMTime(),'size'=>$file->getSize(),'dir'=>dirname($rel)==='.'?'':dirname($rel)];
    }
    usort($rows, static fn($a,$b)=>$b['mtime']<=>$a['mtime']);
    return $rows;
}

function hc_icon(string $path): string
{
    if (is_dir($path)) return 'fa-folder';
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    return match ($ext) {
        'zip','rar','7z','tar','gz','tgz','bz2','xz' => 'fa-file-zipper',
        'jpg','jpeg','png','gif','webp','svg' => 'fa-file-image',
        'pdf' => 'fa-file-pdf',
        'mp4','webm','mov','mkv' => 'fa-file-video',
        'mp3','ogg','wav','flac' => 'fa-file-audio',
        'php','py','js','css','html','sql','json','xml','sh' => 'fa-file-code',
        default => 'fa-file',
    };
}

function hc_kind(string $path): string
{
    if (is_dir($path)) return 'folder';
    if (hc_is_archive($path)) return 'archive';
    if (hc_is_image($path)) return 'image';
    $mime = hc_mime($path);
    if ($mime === 'application/pdf') return 'pdf';
    if (str_starts_with($mime,'video/')) return 'video';
    if (str_starts_with($mime,'audio/')) return 'audio';
    if (hc_is_text($path)) return 'code';
    return 'file';
}

function hc_breadcrumb(string $rel): string
{
    $parts = ['<a href="/cloud/">Мой диск</a>'];
    $walk = '';
    foreach (array_filter(explode('/',$rel), static fn($v)=>$v!=='') as $part) {
        $walk = trim($walk.'/'.$part,'/');
        $parts[] = '<span>›</span><a href="'.e(hc_url(['path'=>$walk])).'">'.e($part).'</a>';
    }
    return implode('', $parts);
}

// Protected downloads / previews.
$cloudAction = (string)($_GET['cloud_action'] ?? '');
if ($cloudAction !== '') {
    try {
        $relAction = hc_clean_rel((string)($_GET['path'] ?? ''));
        [,,$actionPath] = hc_resolve($relAction, true);
        if ($cloudAction === 'download') hc_stream_file($actionPath, false);
        if ($cloudAction === 'raw') hc_stream_file($actionPath, true);
        http_response_code(404); exit('Not found');
    } catch (Throwable $e) {
        http_response_code(404); exit('File unavailable');
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $action = (string)($_POST['action'] ?? '');
    $current = '';
    try {
        $current = hc_clean_rel((string)($_POST['path'] ?? ''));
        [,,$dir] = hc_resolve($current, true);
        if (!is_dir($dir)) throw new RuntimeException('Текущая папка не найдена');

        if ($action === 'mkdir') {
            $name = hc_valid_name((string)($_POST['name'] ?? ''));
            $target = $dir.'/'.$name;
            if (file_exists($target) || is_link($target)) throw new RuntimeException('Такое имя уже занято');
            if (!mkdir($target, 02770, false)) throw new RuntimeException('Не удалось создать папку');
            @chown($target,'www-data'); @chgrp($target,'www-data'); @chmod($target,02770);
            add_event('cloud','Создана папка: '.trim($current.'/'.$name,'/'));
            flash('Папка создана','success');
        } elseif ($action === 'upload') {
            $uploadTarget = hc_clean_rel((string)($_POST['upload_target'] ?? $current));
            [,,$uploadDir] = hc_resolve($uploadTarget, true);
            if (!is_dir($uploadDir) || is_link($uploadDir)) throw new RuntimeException('Папка загрузки не найдена');
            if (!isset($_FILES['files'])) throw new RuntimeException('Выберите файлы');
            $names = is_array($_FILES['files']['name'] ?? null) ? $_FILES['files']['name'] : [$_FILES['files']['name'] ?? ''];
            $tmps = is_array($_FILES['files']['tmp_name'] ?? null) ? $_FILES['files']['tmp_name'] : [$_FILES['files']['tmp_name'] ?? ''];
            $errors = is_array($_FILES['files']['error'] ?? null) ? $_FILES['files']['error'] : [$_FILES['files']['error'] ?? UPLOAD_ERR_NO_FILE];
            $uploaded = 0;
            foreach ($names as $i=>$rawName) {
                $error = (int)($errors[$i] ?? UPLOAD_ERR_NO_FILE);
                if ($error === UPLOAD_ERR_NO_FILE) continue;
                if ($error !== UPLOAD_ERR_OK) {
                    $msg = match($error) {
                        UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE => 'Файл превышает лимит сервера',
                        UPLOAD_ERR_PARTIAL => 'Файл загрузился не полностью',
                        UPLOAD_ERR_NO_TMP_DIR => 'Нет временной папки PHP',
                        UPLOAD_ERR_CANT_WRITE => 'Не удалось записать временный файл',
                        default => 'Ошибка загрузки',
                    };
                    throw new RuntimeException($msg.': '.(string)$rawName);
                }
                $tmp = (string)($tmps[$i] ?? '');
                if ($tmp === '' || !is_uploaded_file($tmp)) continue;
                $name = hc_valid_name(basename((string)$rawName));
                $target = hc_unique_target($uploadDir,$name);
                if (!move_uploaded_file($tmp,$target)) throw new RuntimeException('Не удалось сохранить '.$name);
                @chmod($target,0660); @chown($target,'www-data'); @chgrp($target,'www-data');
                $uploaded++;
            }
            if ($uploaded < 1) throw new RuntimeException('Не удалось загрузить ни одного файла');
            add_event('cloud','Загружено файлов: '.$uploaded.' в /'.$uploadTarget);
            flash('Загружено файлов: '.$uploaded,'success');
        } elseif ($action === 'rename') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            if ($targetRel === '') throw new RuntimeException('Корень переименовать нельзя');
            [,,$target] = hc_resolve($targetRel,true);
            $name = hc_valid_name((string)($_POST['new_name'] ?? ''));
            $newPath = dirname($target).'/'.$name;
            if (file_exists($newPath) || is_link($newPath)) throw new RuntimeException('Такое имя уже занято');
            if (!@rename($target,$newPath)) throw new RuntimeException('Не удалось переименовать');
            add_event('cloud','Переименовано: '.$targetRel.' → '.$name);
            flash('Переименовано','success');
        } elseif ($action === 'delete') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            if ($targetRel === '') throw new RuntimeException('Корень удалить нельзя');
            [,,$target] = hc_resolve($targetRel,true);
            hc_rrmdir($target);
            add_event('cloud','Удалено: '.$targetRel);
            flash('Удалено','success');
        } else {
            throw new RuntimeException('Неизвестное действие');
        }
    } catch (Throwable $e) {
        flash($e->getMessage(),'danger');
    }
    redirect(hc_url(['path'=>$current]));
}

$view = (string)($_GET['view'] ?? 'disk');
if (!in_array($view,['disk','recent','archives','images'],true)) $view = 'disk';
$rel = hc_clean_rel((string)($_GET['path'] ?? ''));
[$root,,$dir] = hc_resolve($rel, true);
if (!is_dir($dir)) { $rel=''; [,,$dir]=hc_resolve('',true); }
$folderTree = hc_folder_tree($root);

$rows = [];
if ($view === 'disk') {
    foreach (array_values(array_filter(scandir($dir) ?: [], static fn($v)=>$v!=='.'&&$v!=='..')) as $name) {
        $path = $dir.'/'.$name; if (is_link($path)) continue;
        $childRel = trim($rel.'/'.$name,'/');
        $rows[] = ['name'=>$name,'path'=>$path,'rel'=>$childRel,'mtime'=>(int)(filemtime($path)?:0),'size'=>is_file($path)?(int)(filesize($path)?:0):0,'dir'=>$rel,'is_dir'=>is_dir($path)];
    }
    usort($rows, static function($a,$b){ if($a['is_dir']!==$b['is_dir']) return $a['is_dir']?-1:1; return strnatcasecmp($a['name'],$b['name']); });
} else {
    $rows = hc_recursive_files($root,$view);
    foreach ($rows as &$r) $r['is_dir']=false;
    unset($r);
}

$previewRel = hc_clean_rel((string)($_GET['preview'] ?? ''));
$previewPath = null;
if ($previewRel !== '') {
    try { [,,$previewPath]=hc_resolve($previewRel,true); if(!is_file($previewPath)) $previewPath=null; } catch(Throwable) { $previewPath=null; }
}

$diskTotal = (float)(@disk_total_space($root) ?: 0);
$diskFree = (float)(@disk_free_space($root) ?: 0);
$diskUsed = max(0.0,$diskTotal-$diskFree);
$diskPct = $diskTotal > 0 ? min(100,($diskUsed/$diskTotal)*100) : 0;
$flash = flash();
$viewTitle = ['disk'=>'Мой диск','recent'=>'Последние','archives'=>'Архивы','images'=>'Изображения'][$view];
?>
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= e($viewTitle) ?> — HYPER CLOUD</title>
<link rel="preconnect" href="https://cdnjs.cloudflare.com" crossorigin>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css">
<link rel="stylesheet" href="/cloud/cloud.css?v=96">
</head>
<body>
<div class="hc-app" id="hcApp">
  <aside class="hc-sidebar" id="hcSidebar">
    <div class="hc-brand"><div class="hc-brand-mark"><i class="fa-solid fa-cloud"></i></div><div><b>HYPER CLOUD</b><span>private storage</span></div></div>
    <button class="hc-create" type="button" data-open-dialog="createDialog"><i class="fa-solid fa-plus"></i><span>Создать</span></button>
    <nav class="hc-nav">
      <a class="<?= $view==='disk'?'active':'' ?>" href="/cloud/"><i class="fa-regular fa-hard-drive"></i><span>Мой диск</span></a>
      <a class="<?= $view==='recent'?'active':'' ?>" href="<?= e(hc_url(['view'=>'recent'])) ?>"><i class="fa-regular fa-clock"></i><span>Последние</span></a>
      <a class="<?= $view==='archives'?'active':'' ?>" href="<?= e(hc_url(['view'=>'archives'])) ?>"><i class="fa-regular fa-file-zipper"></i><span>Архивы</span></a>
      <a class="<?= $view==='images'?'active':'' ?>" href="<?= e(hc_url(['view'=>'images'])) ?>"><i class="fa-regular fa-image"></i><span>Изображения</span></a>
    </nav>
    <div class="hc-side-spacer"></div>
    <div class="hc-storage">
      <div class="hc-storage-title"><span>Хранилище сервера</span><b><?= e(human_bytes($diskUsed)) ?></b></div>
      <div class="hc-storage-bar"><i style="width:<?= e((string)round($diskPct,1)) ?>%"></i></div>
      <small>Свободно <?= e(human_bytes($diskFree)) ?> из <?= e(human_bytes($diskTotal)) ?></small>
    </div>
    <a class="hc-back-panel" href="/"><i class="fa-solid fa-arrow-left"></i><span>Вернуться в HYPER-HOST</span></a>
  </aside>

  <section class="hc-shell">
    <header class="hc-header">
      <button class="hc-mobile-menu" type="button" id="hcMenuButton"><i class="fa-solid fa-bars"></i></button>
      <div class="hc-search"><i class="fa-solid fa-magnifying-glass"></i><input id="hcSearch" type="search" placeholder="Поиск в текущем списке" autocomplete="off"></div>
      <div class="hc-user"><div class="hc-avatar"><?= e(hc_initial((string)($user['username'] ?? 'A'))) ?></div><div class="hc-user-copy"><b><?= e((string)($user['username'] ?? 'admin')) ?></b><span>HYPER-HOST</span></div><a class="hc-icon-btn" title="Выйти" href="/?page=logout"><i class="fa-solid fa-arrow-right-from-bracket"></i></a></div>
    </header>

    <main class="hc-main" id="hcMain">
      <?php if($flash): ?><div class="hc-toast <?= e((string)$flash['type']) ?>"><i class="fa-solid fa-circle-info"></i><span><?= e((string)$flash['message']) ?></span></div><?php endif; ?>

      <div class="hc-title-row">
        <div>
          <div class="hc-eyebrow">HYPER CLOUD</div>
          <h1><?= e($viewTitle) ?></h1>
          <?php if($view==='disk'): ?><div class="hc-breadcrumb"><?= hc_breadcrumb($rel) ?></div><?php else: ?><p class="hc-subtitle">Файлы из всего облака, собранные в одном месте.</p><?php endif; ?>
        </div>
        <div class="hc-toolbar">
          <?php if($view==='disk' && $rel!==''): $up=dirname($rel); if($up==='.')$up=''; ?><a class="hc-btn ghost" href="<?= e(hc_url(['path'=>$up])) ?>"><i class="fa-solid fa-arrow-left"></i><span>Назад</span></a><?php endif; ?>
          <button class="hc-btn ghost" type="button" id="hcViewToggle" title="Переключить вид"><i class="fa-solid fa-table-cells-large"></i></button>
          <button class="hc-btn primary" type="button" data-open-dialog="uploadDialog"><i class="fa-solid fa-cloud-arrow-up"></i><span>Загрузить</span></button>
        </div>
      </div>

      <?php if($view==='disk' && $rel===''): ?>
      <section class="hc-welcome">
        <div><span class="hc-welcome-icon"><i class="fa-solid fa-cloud-arrow-up"></i></span><div><b>Перетащите файлы прямо сюда</b><p>Drag & Drop работает на всей рабочей области. Файлы попадут в выбранную папку.</p></div></div>
        <button class="hc-btn soft" type="button" data-open-dialog="uploadDialog">Выбрать файлы</button>
      </section>
      <?php endif; ?>

      <section class="hc-files-section">
        <div class="hc-section-head"><div><b><?= $view==='disk' ? e($rel===''?'Файлы и папки':basename($rel)) : e($viewTitle) ?></b><span id="hcItemCount"><?= count($rows) ?> элементов</span></div><?php if($view==='disk'): ?><button class="hc-link-btn" type="button" data-open-dialog="folderDialog"><i class="fa-solid fa-folder-plus"></i>Новая папка</button><?php endif; ?></div>

        <div class="hc-grid" id="hcFilesGrid">
          <?php foreach($rows as $row): $kind=hc_kind($row['path']); $isDir=(bool)$row['is_dir']; $openHref=$isDir?hc_url(['path'=>$row['rel']]):hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$row['rel']],static fn($v)=>$v!==null)); ?>
          <article class="hc-file-card" data-file-name="<?= e(hc_lower($row['name'])) ?>" data-kind="<?= e($kind) ?>">
            <a class="hc-file-open" href="<?= e($openHref) ?>">
              <div class="hc-file-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($row['path'])) ?>"></i><?php if($kind==='image'): ?><img loading="lazy" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$row['rel']])) ?>" alt=""><?php endif; ?></div>
              <div class="hc-file-info"><b title="<?= e($row['name']) ?>"><?= e($row['name']) ?></b><span><?= $isDir ? 'Папка' : e(human_bytes((float)$row['size'])) ?> · <?= e(date('d.m.Y H:i',$row['mtime']?:time())) ?></span><?php if(!$isDir && $row['dir']!==''): ?><small>/<?= e($row['dir']) ?></small><?php endif; ?></div>
            </a>
            <div class="hc-file-actions">
              <?php if(!$isDir): ?><a title="Скачать" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>"><i class="fa-solid fa-download"></i></a><?php endif; ?>
              <button type="button" title="Действия" data-menu-for="menu-<?= md5($row['rel']) ?>"><i class="fa-solid fa-ellipsis-vertical"></i></button>
            </div>
            <div class="hc-context-menu" id="menu-<?= md5($row['rel']) ?>">
              <?php if($isDir): ?><a href="<?= e(hc_url(['path'=>$row['rel']])) ?>"><i class="fa-regular fa-folder-open"></i>Открыть</a><?php else: ?><a href="<?= e($openHref) ?>"><i class="fa-regular fa-eye"></i>Открыть</a><a href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>"><i class="fa-solid fa-download"></i>Скачать</a><?php endif; ?>
              <button type="button" data-rename-target="<?= e($row['rel']) ?>" data-rename-name="<?= e($row['name']) ?>"><i class="fa-solid fa-pen"></i>Переименовать</button>
              <form method="post" onsubmit="return confirm('Удалить «<?= e(addslashes($row['name'])) ?>»?')"><?= hc_csrf_field() ?><input type="hidden" name="action" value="delete"><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="target" value="<?= e($row['rel']) ?>"><button class="danger" type="submit"><i class="fa-regular fa-trash-can"></i>Удалить</button></form>
            </div>
          </article>
          <?php endforeach; ?>
        </div>

        <div class="hc-list" id="hcFilesList" hidden>
          <?php foreach($rows as $row): $kind=hc_kind($row['path']); $isDir=(bool)$row['is_dir']; $openHref=$isDir?hc_url(['path'=>$row['rel']]):hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$row['rel']],static fn($v)=>$v!==null)); ?>
          <div class="hc-list-row" data-file-name="<?= e(hc_lower($row['name'])) ?>"><a href="<?= e($openHref) ?>"><span class="hc-mini-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($row['path'])) ?>"></i></span><b><?= e($row['name']) ?></b></a><span><?= $isDir?'Папка':e(human_bytes((float)$row['size'])) ?></span><span><?= e(date('d.m.Y H:i',$row['mtime']?:time())) ?></span><div><?php if(!$isDir): ?><a class="hc-icon-btn" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>"><i class="fa-solid fa-download"></i></a><?php endif; ?></div></div>
          <?php endforeach; ?>
        </div>

        <?php if(!$rows): ?><div class="hc-empty" id="hcEmpty"><span><i class="fa-regular fa-folder-open"></i></span><b>Здесь пока пусто</b><p>Создайте папку или загрузите файлы.</p><button class="hc-btn primary" type="button" data-open-dialog="uploadDialog">Загрузить файлы</button></div><?php endif; ?>
        <div class="hc-empty hc-search-empty" id="hcSearchEmpty" hidden><span><i class="fa-solid fa-magnifying-glass"></i></span><b>Ничего не найдено</b><p>Измените запрос поиска.</p></div>
      </section>
    </main>
  </section>
</div>

<div class="hc-drop-overlay" id="hcDropOverlay"><div><span><i class="fa-solid fa-cloud-arrow-up"></i></span><b>Отпустите файлы</b><p>Они будут добавлены в облако</p></div></div>
<div class="hc-mobile-backdrop" id="hcMobileBackdrop"></div>

<dialog class="hc-dialog hc-small-dialog" id="createDialog">
  <div class="hc-dialog-head"><div><span>Создать</span><b>Что добавить в облако?</b></div><button type="button" data-close-dialog><i class="fa-solid fa-xmark"></i></button></div>
  <div class="hc-dialog-body">
    <div class="hc-create-grid">
      <button type="button" data-open-dialog="uploadDialog"><span><i class="fa-solid fa-cloud-arrow-up"></i></span><b>Загрузить файлы</b><small>С компьютера или Drag & Drop</small></button>
      <button type="button" data-open-dialog="folderDialog"><span><i class="fa-solid fa-folder-plus"></i></span><b>Новая папка</b><small>Создать в текущем каталоге</small></button>
    </div>
  </div>
</dialog>

<dialog class="hc-dialog" id="uploadDialog">
  <form method="post" enctype="multipart/form-data" id="hcUploadForm">
    <input type="hidden" name="action" value="upload"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>">
    <div class="hc-dialog-head"><div><span>Загрузка</span><b>Добавить файлы в облако</b></div><button type="button" data-close-dialog><i class="fa-solid fa-xmark"></i></button></div>
    <div class="hc-dialog-body">
      <label class="hc-field"><span>Куда загрузить</span><select name="upload_target" id="hcUploadTarget"><option value=""<?= $rel===''?' selected':'' ?>>☁ Корень облака</option><?php foreach($folderTree as $folder): $fpath=(string)$folder['path']; ?><option value="<?= e($fpath) ?>"<?= $fpath===$rel?' selected':'' ?>><?= e(str_repeat('— ',min((int)$folder['depth']+1,10)).$folder['name'].($fpath===$rel?' · текущая':'')) ?></option><?php endforeach; ?></select></label>
      <label class="hc-upload-zone" id="hcUploadZone"><input type="file" id="hcFilesInput" name="files[]" multiple hidden><span><i class="fa-solid fa-cloud-arrow-up"></i></span><b>Перетащите файлы сюда</b><p>или нажмите, чтобы выбрать с компьютера</p></label>
      <div class="hc-upload-queue" id="hcUploadQueue" hidden><div class="hc-upload-queue-head"><b id="hcQueueCount"></b><span id="hcQueueSize"></span></div><div id="hcQueueFiles"></div></div>
    </div>
    <div class="hc-dialog-foot"><button type="button" class="hc-btn ghost" data-close-dialog>Отмена</button><button type="submit" class="hc-btn primary" id="hcUploadSubmit" disabled><i class="fa-solid fa-cloud-arrow-up"></i>Загрузить</button></div>
  </form>
</dialog>

<dialog class="hc-dialog hc-small-dialog" id="folderDialog">
  <form method="post"><input type="hidden" name="action" value="mkdir"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>"><div class="hc-dialog-head"><div><span>Новая папка</span><b>Создать в <?= e($rel!==''?'/'.$rel:'корне облака') ?></b></div><button type="button" data-close-dialog><i class="fa-solid fa-xmark"></i></button></div><div class="hc-dialog-body"><label class="hc-field"><span>Название</span><input name="name" maxlength="180" placeholder="Например: Документы" autofocus required></label></div><div class="hc-dialog-foot"><button type="button" class="hc-btn ghost" data-close-dialog>Отмена</button><button class="hc-btn primary">Создать</button></div></form>
</dialog>

<dialog class="hc-dialog hc-small-dialog" id="renameDialog">
  <form method="post"><input type="hidden" name="action" value="rename"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>"><input type="hidden" name="target" id="hcRenameTarget"><div class="hc-dialog-head"><div><span>Переименование</span><b>Новое имя</b></div><button type="button" data-close-dialog><i class="fa-solid fa-xmark"></i></button></div><div class="hc-dialog-body"><label class="hc-field"><span>Имя</span><input name="new_name" id="hcRenameName" maxlength="180" required></label></div><div class="hc-dialog-foot"><button type="button" class="hc-btn ghost" data-close-dialog>Отмена</button><button class="hc-btn primary">Сохранить</button></div></form>
</dialog>

<?php if($previewPath): $mime=hc_mime($previewPath); ?>
<div class="hc-preview-backdrop" id="hcPreview" data-preview-open>
  <section class="hc-preview-panel">
    <header><div><span>Просмотр</span><b><?= e(basename($previewPath)) ?></b><small><?= e(human_bytes((float)(filesize($previewPath)?:0))) ?></small></div><div><a class="hc-btn soft" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$previewRel])) ?>"><i class="fa-solid fa-download"></i>Скачать</a><a class="hc-preview-close" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-xmark"></i></a></div></header>
    <div class="hc-preview-body">
      <?php if(hc_is_archive($previewPath)): $archive=hc_archive_entries($previewPath); ?>
        <div class="hc-archive-head"><i class="fa-solid fa-box-archive"></i><div><b>Содержимое архива</b><span><?= e((string)($archive['engine']??'')) ?></span></div></div>
        <?php if(!empty($archive['ok'])): ?><div class="hc-archive-table"><table><thead><tr><th>Файл</th><th>Размер</th><th>Сжат</th><th>Дата</th></tr></thead><tbody><?php foreach($archive['entries'] as $entry): ?><tr><td><?= e((string)$entry['name']) ?></td><td><?= e(human_bytes((float)($entry['size']??0))) ?></td><td><?= e(human_bytes((float)($entry['packed']??0))) ?></td><td><?= e((string)($entry['modified']??'—')) ?></td></tr><?php endforeach; ?></tbody></table></div><?php if(!empty($archive['truncated'])): ?><div class="hc-preview-note">Показаны первые 1000 элементов.</div><?php endif; ?><?php else: ?><div class="hc-preview-fallback"><i class="fa-solid fa-triangle-exclamation"></i><b>Архив не удалось прочитать</b><p><?= e((string)($archive['error']??'')) ?></p></div><?php endif; ?>
      <?php elseif(str_starts_with($mime,'image/')): ?><img class="hc-preview-image" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>" alt="">
      <?php elseif($mime==='application/pdf'): ?><iframe class="hc-preview-frame" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></iframe>
      <?php elseif(str_starts_with($mime,'video/')): ?><video class="hc-preview-media" controls preload="metadata" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></video>
      <?php elseif(str_starts_with($mime,'audio/')): ?><div class="hc-audio-wrap"><audio controls preload="metadata" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></audio></div>
      <?php elseif(hc_is_text($previewPath) && (filesize($previewPath)?:0)<=2*1024*1024): $txt=@file_get_contents($previewPath,false,null,0,2*1024*1024); ?><pre class="hc-code-preview"><?= e(is_string($txt)?$txt:'') ?></pre>
      <?php else: ?><div class="hc-preview-fallback"><i class="fa-solid fa-file-arrow-down"></i><b>Предпросмотр недоступен</b><p>Файл можно скачать без изменений.</p><a class="hc-btn primary" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$previewRel])) ?>">Скачать файл</a></div><?php endif; ?>
    </div>
  </section>
</div>
<?php endif; ?>

<script src="/cloud/cloud.js?v=96" defer></script>
</body>
</html>
