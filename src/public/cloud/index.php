<?php
declare(strict_types=1);

/**
 * HYPER CLOUD v100 — standalone cloud with visible deletion controls and an in-cloud text/archive editor.
 * This page intentionally does NOT use render_page() and has its own UI shell.
 */
require __DIR__ . '/../../app/bootstrap.php';

header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');

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

    if (str_ends_with(strtolower($path), '.zip') && is_executable('/usr/bin/unzip')) {
        $out = []; $code = 0;
        exec('/usr/bin/unzip -Z -1 '.escapeshellarg($path).' 2>/dev/null', $out, $code);
        if ($code === 0) {
            foreach ($out as $raw) {
                if (count($entries) >= $limit) break;
                $raw = rtrim((string)$raw);
                if ($raw !== '') $entries[] = ['name'=>$raw,'size'=>0,'packed'=>0,'modified'=>'—'];
            }
            if ($entries) return ['ok'=>true,'entries'=>$entries,'truncated'=>count($out)>$limit,'engine'=>'unzip'];
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

function hc_is_editable_text_name(string $name): bool
{
    if (str_ends_with($name, '/')) return false;
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    return in_array($ext, [
        'txt','log','md','json','xml','csv','ini','env','conf','yml','yaml',
        'php','phtml','py','js','mjs','cjs','ts','tsx','jsx','css','scss','sass','less',
        'html','htm','sql','sh','bash','zsh','bat','ps1','c','cpp','h','hpp','java','go','rs',
        'vue','svelte','twig','tpl','htaccess','gitignore','dockerfile'
    ], true) || in_array(strtolower(basename($name)), ['.env','.htaccess','.gitignore','dockerfile','makefile'], true);
}

function hc_archive_entry_clean(string $entry): string
{
    $entry = str_replace("\\", '/', str_replace("\0", '', trim($entry)));
    if ($entry === '' || str_starts_with($entry, '/') || preg_match('/^[A-Za-z]:\//', $entry)) {
        throw new RuntimeException('Недопустимый путь внутри архива');
    }
    $parts = [];
    foreach (explode('/', $entry) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..' || preg_match('/[\x00-\x1F\x7F]/u', $part)) throw new RuntimeException('Недопустимый путь внутри архива');
        $parts[] = $part;
    }
    if (!$parts) throw new RuntimeException('Файл внутри архива не найден');
    return implode('/', $parts);
}

function hc_archive_writer(string $archivePath): string
{
    $name = strtolower(basename($archivePath));
    if (str_ends_with($name, '.zip') && class_exists('ZipArchive')) return 'ziparchive';
    if (str_ends_with($name, '.zip') && is_executable('/usr/bin/zip')) return 'zipcli';
    if ((str_ends_with($name, '.zip') || str_ends_with($name, '.7z')) && is_executable('/usr/bin/7z')) return '7z';
    if ((str_ends_with($name, '.zip') || str_ends_with($name, '.7z')) && is_executable('/usr/bin/7zz')) return '7zz';
    if (str_ends_with($name, '.rar') && is_executable('/usr/bin/rar')) return 'rar';
    return '';
}

function hc_archive_entry_read(string $archivePath, string $entry, int $limit = 2097152): array
{
    $entry = hc_archive_entry_clean($entry);
    if (!hc_is_editable_text_name($entry)) throw new RuntimeException('Этот тип файла нельзя открыть в редакторе');

    if (str_ends_with(strtolower($archivePath), '.zip') && class_exists('ZipArchive')) {
        $zip = new ZipArchive();
        if ($zip->open($archivePath) === true) {
            $idx = $zip->locateName($entry, 0);
            if ($idx === false) { $zip->close(); throw new RuntimeException('Файл внутри архива не найден'); }
            $st = $zip->statIndex($idx);
            if (is_array($st) && (int)($st['size'] ?? 0) > $limit) { $zip->close(); throw new RuntimeException('Файл слишком большой для редактора'); }
            $data = $zip->getFromIndex($idx, $limit + 1);
            $zip->close();
            if (!is_string($data)) throw new RuntimeException('Не удалось прочитать файл из архива');
            if (strlen($data) > $limit) throw new RuntimeException('Файл слишком большой для редактора');
            if (str_contains($data, "\0")) throw new RuntimeException('Бинарный файл нельзя открыть в редакторе');
            return ['content'=>$data,'writable'=>hc_archive_writer($archivePath)!=='','entry'=>$entry];
        }
    }

    if (str_ends_with(strtolower($archivePath), '.zip') && is_executable('/usr/bin/unzip')) {
        $names = []; $listCode = 0;
        exec('/usr/bin/unzip -Z -1 '.escapeshellarg($archivePath).' 2>/dev/null', $names, $listCode);
        if ($listCode === 0 && in_array($entry, array_map('rtrim', $names), true)) {
            $cmd = 'timeout 12s /usr/bin/unzip -p '.escapeshellarg($archivePath).' '.escapeshellarg($entry).' 2>/dev/null | head -c '.($limit + 1);
            $data = shell_exec($cmd);
            if ($data === null) $data = '';
            if (!is_string($data)) throw new RuntimeException('Не удалось прочитать файл из ZIP');
            if (strlen($data) > $limit) throw new RuntimeException('Файл слишком большой для редактора');
            if (str_contains($data, "\0")) throw new RuntimeException('Бинарный файл нельзя открыть в редакторе');
            return ['content'=>$data,'writable'=>hc_archive_writer($archivePath)!=='','entry'=>$entry];
        }
    }
    $bin = is_executable('/usr/bin/7z') ? '/usr/bin/7z' : (is_executable('/usr/bin/7zz') ? '/usr/bin/7zz' : '');
    if ($bin === '') throw new RuntimeException('Для чтения этого архива нужен 7-Zip или unzip');
    $cmd = 'timeout 12s '.escapeshellarg($bin).' x -so -bd -y -- '.escapeshellarg($archivePath).' '.escapeshellarg($entry).' 2>/dev/null | head -c '.($limit + 1);
    $data = shell_exec($cmd);
    if (!is_string($data)) throw new RuntimeException('Не удалось прочитать файл из архива');
    if (strlen($data) > $limit) throw new RuntimeException('Файл слишком большой для редактора');
    if (str_contains($data, "\0")) throw new RuntimeException('Бинарный файл нельзя открыть в редакторе');
    return ['content'=>$data,'writable'=>hc_archive_writer($archivePath)!=='','entry'=>$entry];
}

function hc_archive_backup(string $archivePath): string
{
    $dir = hc_meta_dir() . '/archive-backups';
    if (!is_dir($dir) && !@mkdir($dir, 02770, true) && !is_dir($dir)) throw new RuntimeException('Не удалось создать папку резервных копий');
    @chown($dir, 'www-data'); @chgrp($dir, 'www-data'); @chmod($dir, 02770);
    $backup = $dir . '/' . date('Ymd-His') . '-' . substr(hash('sha256', $archivePath . microtime(true)), 0, 10) . '-' . basename($archivePath);
    if (!@copy($archivePath, $backup)) throw new RuntimeException('Не удалось создать резервную копию архива');
    @chmod($backup, 0660); @chown($backup, 'www-data'); @chgrp($backup, 'www-data');
    $files = glob($dir . '/*') ?: [];
    usort($files, static fn($a,$b)=>(@filemtime($b)?:0)<=> (@filemtime($a)?:0));
    foreach (array_slice($files, 40) as $old) @unlink($old);
    return $backup;
}

function hc_archive_entry_write(string $archivePath, string $entry, string $content): void
{
    $entry = hc_archive_entry_clean($entry);
    if (!hc_is_editable_text_name($entry)) throw new RuntimeException('Этот тип файла нельзя сохранять из редактора');
    if (strlen($content) > 2097152) throw new RuntimeException('Максимальный размер файла для редактора — 2 МБ');
    if (str_contains($content, "\0")) throw new RuntimeException('Бинарные данные запрещены');

    // Ensure the entry exists before touching the archive.
    hc_archive_entry_read($archivePath, $entry, 2097152);
    $writer = hc_archive_writer($archivePath);
    if ($writer === '') throw new RuntimeException('Этот формат архива доступен только для чтения. ZIP и 7Z можно редактировать; RAR — если на сервере установлен rar.');
    $backup = hc_archive_backup($archivePath);

    try {
        if ($writer === 'ziparchive') {
            $zip = new ZipArchive();
            if ($zip->open($archivePath) !== true) throw new RuntimeException('Не удалось открыть ZIP для записи');
            $idx = $zip->locateName($entry, 0);
            if ($idx === false) { $zip->close(); throw new RuntimeException('Файл внутри ZIP не найден'); }
            if (!$zip->deleteIndex($idx) || !$zip->addFromString($entry, $content)) { $zip->close(); throw new RuntimeException('Не удалось обновить файл внутри ZIP'); }
            if (!$zip->close()) throw new RuntimeException('Не удалось сохранить ZIP');
        } elseif ($writer === 'zipcli') {
            $tmp = sys_get_temp_dir() . '/hc-zip-' . bin2hex(random_bytes(8));
            $entryPath = $tmp . '/' . $entry;
            if (!@mkdir(dirname($entryPath), 0700, true) && !is_dir(dirname($entryPath))) throw new RuntimeException('Не удалось подготовить временную папку');
            if (@file_put_contents($entryPath, $content, LOCK_EX) === false) throw new RuntimeException('Не удалось подготовить файл для архива');
            $cmd = 'cd '.escapeshellarg($tmp).' && /usr/bin/zip -q -u '.escapeshellarg($archivePath).' '.escapeshellarg('./'.$entry).' 2>/dev/null';
            exec($cmd, $out, $code);
            hc_rrmdir($tmp);
            if ($code !== 0) throw new RuntimeException('zip не смог обновить архив');
        } elseif ($writer === '7z' || $writer === '7zz') {
            $tmp = sys_get_temp_dir() . '/hc-archive-' . bin2hex(random_bytes(8));
            $entryPath = $tmp . '/' . $entry;
            if (!@mkdir(dirname($entryPath), 0700, true) && !is_dir(dirname($entryPath))) throw new RuntimeException('Не удалось подготовить временную папку');
            if (@file_put_contents($entryPath, $content, LOCK_EX) === false) throw new RuntimeException('Не удалось подготовить файл для архива');
            $bin = $writer === '7z' ? '/usr/bin/7z' : '/usr/bin/7zz';
            $cmd = 'cd '.escapeshellarg($tmp).' && '.escapeshellarg($bin).' u -y -bd -- '.escapeshellarg($archivePath).' '.escapeshellarg($entry).' >/dev/null 2>&1';
            exec($cmd, $out, $code);
            hc_rrmdir($tmp);
            if ($code !== 0) throw new RuntimeException('7-Zip не смог обновить архив');
        } elseif ($writer === 'rar') {
            $tmp = sys_get_temp_dir() . '/hc-rar-' . bin2hex(random_bytes(8));
            $entryPath = $tmp . '/' . $entry;
            if (!@mkdir(dirname($entryPath), 0700, true) && !is_dir(dirname($entryPath))) throw new RuntimeException('Не удалось подготовить временную папку');
            if (@file_put_contents($entryPath, $content, LOCK_EX) === false) throw new RuntimeException('Не удалось подготовить файл для архива');
            $cmd = 'cd '.escapeshellarg($tmp).' && /usr/bin/rar u -idq -- '.escapeshellarg($archivePath).' '.escapeshellarg($entry).' >/dev/null 2>&1';
            exec($cmd, $out, $code);
            hc_rrmdir($tmp);
            if ($code !== 0) throw new RuntimeException('RAR не смог обновить архив');
        }
    } catch (Throwable $e) {
        @copy($backup, $archivePath);
        throw $e;
    }
    @chmod($archivePath, 0660); @chown($archivePath, 'www-data'); @chgrp($archivePath, 'www-data');
}

function hc_write_text_file(string $path, string $content): void
{
    if (!is_file($path) || is_link($path)) throw new RuntimeException('Файл недоступен');
    if (!hc_is_text($path) || !hc_is_editable_text_name(basename($path))) throw new RuntimeException('Этот файл нельзя редактировать');
    if (strlen($content) > 2097152) throw new RuntimeException('Максимальный размер файла для редактора — 2 МБ');
    if (str_contains($content, "\0")) throw new RuntimeException('Бинарные данные запрещены');
    $tmp = dirname($path) . '/.hc-edit-' . bin2hex(random_bytes(8));
    if (@file_put_contents($tmp, $content, LOCK_EX) === false) throw new RuntimeException('Не удалось записать изменения');
    $mode = @fileperms($path); if (is_int($mode)) @chmod($tmp, $mode & 0777); else @chmod($tmp, 0660);
    @chown($tmp, 'www-data'); @chgrp($tmp, 'www-data');
    if (!@rename($tmp, $path)) { @unlink($tmp); throw new RuntimeException('Не удалось заменить файл'); }
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

function hc_archive_entry_icon(string $name): string
{
    if (str_ends_with($name, '/')) return 'fa-folder';
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    return match ($ext) {
        'zip','rar','7z','tar','gz','tgz','bz2','xz' => 'fa-file-zipper',
        'jpg','jpeg','png','gif','webp','svg' => 'fa-file-image',
        'pdf' => 'fa-file-pdf',
        'mp4','webm','mov','mkv' => 'fa-file-video',
        'mp3','ogg','wav','flac' => 'fa-file-audio',
        'php','py','js','css','html','sql','json','xml','sh','md','txt' => 'fa-file-code',
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

function hc_meta_dir(): string
{
    $dir = rtrim((string)app_config('cloud_meta_dir', '/var/lib/hyper-host-cloud'), '/');
    return $dir !== '' ? $dir : '/var/lib/hyper-host-cloud';
}

function hc_share_store_path(): string
{
    $dir = hc_meta_dir();
    if (!is_dir($dir)) {
        @mkdir($dir, 02770, true);
        @chown($dir, 'www-data'); @chgrp($dir, 'www-data'); @chmod($dir, 02770);
    }
    return $dir . '/shares.json';
}

function hc_share_store_load(): array
{
    $file = hc_share_store_path();
    if (!is_file($file)) return [];
    $fh = @fopen($file, 'rb');
    if ($fh === false) return [];
    @flock($fh, LOCK_SH);
    $raw = stream_get_contents($fh);
    @flock($fh, LOCK_UN); fclose($fh);
    $data = json_decode(is_string($raw) ? $raw : '', true);
    return is_array($data) ? $data : [];
}

function hc_share_store_mutate(callable $callback): mixed
{
    $file = hc_share_store_path();
    $fh = @fopen($file, 'c+');
    if ($fh === false) throw new RuntimeException('Не удалось открыть реестр общего доступа');
    if (!@flock($fh, LOCK_EX)) { fclose($fh); throw new RuntimeException('Не удалось заблокировать реестр общего доступа'); }
    rewind($fh);
    $raw = stream_get_contents($fh);
    $shares = json_decode(is_string($raw) ? $raw : '', true);
    if (!is_array($shares)) $shares = [];
    $result = $callback($shares);
    $json = json_encode($shares, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
    if (!is_string($json)) { @flock($fh, LOCK_UN); fclose($fh); throw new RuntimeException('Не удалось сохранить реестр общего доступа'); }
    rewind($fh); ftruncate($fh, 0);
    if (fwrite($fh, $json . "\n") === false) { @flock($fh, LOCK_UN); fclose($fh); throw new RuntimeException('Не удалось записать реестр общего доступа'); }
    fflush($fh); @flock($fh, LOCK_UN); fclose($fh);
    @chmod($file, 0660); @chown($file, 'www-data'); @chgrp($file, 'www-data');
    return $result;
}

function hc_share_index_by_path(?array $shares = null): array
{
    $shares ??= hc_share_store_load();
    $out = [];
    foreach ($shares as $token => $entry) {
        if (!is_string($token) || !is_array($entry)) continue;
        $rel = (string)($entry['path'] ?? '');
        if ($rel === '') continue;
        $entry['token'] = $token;
        $out[$rel] = $entry;
    }
    return $out;
}

function hc_share_enable(string $rel, int $userId): string
{
    $rel = hc_clean_rel($rel);
    if ($rel === '') throw new RuntimeException('Корень нельзя публиковать');
    [,,$path] = hc_resolve($rel, true);
    if (!is_file($path) || is_link($path)) throw new RuntimeException('Доступ по ссылке можно открыть только для файла');
    return (string)hc_share_store_mutate(function(array &$shares) use ($rel,$userId): string {
        foreach ($shares as $token => $entry) {
            if (is_array($entry) && (string)($entry['path'] ?? '') === $rel && preg_match('/^[a-f0-9]{48}$/', (string)$token)) return (string)$token;
        }
        do { $token = bin2hex(random_bytes(24)); } while (isset($shares[$token]));
        $shares[$token] = ['path'=>$rel,'created_at'=>date(DATE_ATOM),'created_by'=>$userId];
        return $token;
    });
}

function hc_share_disable(string $rel): void
{
    $rel = hc_clean_rel($rel);
    hc_share_store_mutate(function(array &$shares) use ($rel): void {
        foreach (array_keys($shares) as $token) {
            $entry = $shares[$token] ?? null;
            if (is_array($entry) && (string)($entry['path'] ?? '') === $rel) unset($shares[$token]);
        }
    });
}

function hc_share_repath_tree(string $oldRel, string $newRel): void
{
    $oldRel = hc_clean_rel($oldRel); $newRel = hc_clean_rel($newRel);
    if ($oldRel === '' || $newRel === '') return;
    hc_share_store_mutate(function(array &$shares) use ($oldRel,$newRel): void {
        foreach ($shares as &$entry) {
            if (!is_array($entry)) continue;
            $path = (string)($entry['path'] ?? '');
            if ($path === $oldRel) $entry['path'] = $newRel;
            elseif (str_starts_with($path, $oldRel . '/')) $entry['path'] = $newRel . substr($path, strlen($oldRel));
        }
        unset($entry);
    });
}

function hc_share_revoke_tree(string $rel): void
{
    $rel = hc_clean_rel($rel);
    if ($rel === '') return;
    hc_share_store_mutate(function(array &$shares) use ($rel): void {
        foreach (array_keys($shares) as $token) {
            $entry = $shares[$token] ?? null;
            $path = is_array($entry) ? (string)($entry['path'] ?? '') : '';
            if ($path === $rel || str_starts_with($path, $rel . '/')) unset($shares[$token]);
        }
    });
}

function hc_share_lookup(string $token): ?array
{
    if (!preg_match('/^[a-f0-9]{48}$/', $token)) return null;
    $shares = hc_share_store_load();
    $entry = $shares[$token] ?? null;
    if (!is_array($entry)) return null;
    try {
        $rel = hc_clean_rel((string)($entry['path'] ?? ''));
        [,,$path] = hc_resolve($rel, true);
        if (!is_file($path) || is_link($path)) return null;
        $entry['token'] = $token; $entry['path'] = $rel; $entry['file'] = $path;
        return $entry;
    } catch (Throwable) { return null; }
}

function hc_public_share_url(string $token): string
{
    return '/cloud/?s=' . rawurlencode($token);
}

function hc_public_headers(): void
{
    header('X-Frame-Options: DENY');
    header('X-Robots-Tag: noindex, nofollow, noarchive');
    header("Content-Security-Policy: default-src 'self' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; font-src https://cdnjs.cloudflare.com data:; img-src 'self' data:; script-src 'none'; frame-src 'self'; media-src 'self'; base-uri 'none'; form-action 'self'");
}

function hc_public_error_page(): never
{
    http_response_code(404);
    hc_public_headers();
    ?>
<!doctype html><html lang="ru" data-bs-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ссылка недоступна — HYPER CLOUD</title><meta name="robots" content="noindex,nofollow,noarchive"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" integrity="sha384-sRIl4kxILFvY47J16cr9ZwB07vP4J8+LH7qKQnuqkuIAvNWLzeN8tE5YBujZqJLB" crossorigin="anonymous"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css"><link rel="stylesheet" href="/cloud/cloud.css?v=100"></head><body class="hc-public-body hc-public-error-body">
<main class="hc-public-page"><section class="hc-public-card hc-public-error-card"><div class="hc-public-brand"><span><i class="fa-solid fa-cloud"></i></span><b>HYPER CLOUD</b></div><div class="hc-public-error-icon"><i class="fa-solid fa-link-slash"></i></div><h1>Ссылка недоступна</h1><p>Доступ закрыт или файл больше не существует.</p></section></main></body></html><?php
    exit;
}

function hc_public_share_page(array $share): never
{
    $path = (string)$share['file'];
    $token = (string)$share['token'];
    $name = basename($path);
    $size = (float)(filesize($path) ?: 0);
    $mime = hc_mime($path);
    $kind = hc_kind($path);
    $download = hc_public_share_url($token) . '&download=1';
    $inline = hc_public_share_url($token) . '&inline=1';
    http_response_code(200);
    hc_public_headers();
    ?>
<!doctype html><html lang="ru" data-bs-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?= e($name) ?> — HYPER CLOUD</title><meta name="robots" content="noindex,nofollow,noarchive"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" integrity="sha384-sRIl4kxILFvY47J16cr9ZwB07vP4J8+LH7qKQnuqkuIAvNWLzeN8tE5YBujZqJLB" crossorigin="anonymous"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css"><link rel="stylesheet" href="/cloud/cloud.css?v=100"></head><body class="hc-public-body">
<main class="hc-public-page"><section class="hc-public-card"><div class="hc-public-brand"><span><i class="fa-solid fa-cloud"></i></span><b>HYPER CLOUD</b></div>
<div class="hc-public-file"><div class="hc-public-file-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($path)) ?>"></i></div><div><h1><?= e($name) ?></h1><p><?= e(human_bytes($size)) ?> <span>•</span> <?= e(date('d.m.Y H:i', (int)(filemtime($path) ?: time()))) ?></p></div></div>
<?php if(str_starts_with($mime,'image/')): ?><div class="hc-public-preview image"><img src="<?= e($inline) ?>" alt=""></div>
<?php elseif($mime==='application/pdf'): ?><div class="hc-public-preview document"><iframe src="<?= e($inline) ?>" title="<?= e($name) ?>"></iframe></div>
<?php elseif(str_starts_with($mime,'video/')): ?><div class="hc-public-preview media"><video controls preload="metadata" src="<?= e($inline) ?>"></video></div>
<?php elseif(str_starts_with($mime,'audio/')): ?><div class="hc-public-audio"><audio controls preload="metadata" src="<?= e($inline) ?>"></audio></div><?php endif; ?>
<a class="hc-public-download" href="<?= e($download) ?>"><i class="fa-solid fa-download"></i><span>Скачать</span><small><?= e(human_bytes($size)) ?></small></a></section></main></body></html><?php
    exit;
}

// Public token route is intentionally processed BEFORE panel authentication.
$publicToken = strtolower(trim((string)($_GET['s'] ?? '')));
if ($publicToken !== '') {
    $publicShare = hc_share_lookup($publicToken);
    if (!$publicShare) hc_public_error_page();
    if (isset($_GET['download'])) hc_stream_file((string)$publicShare['file'], false);
    if (isset($_GET['inline'])) hc_stream_file((string)$publicShare['file'], true);
    hc_public_share_page($publicShare);
}

if (!current_user()) {
    $_SESSION['after_login'] = '/cloud/';
    redirect('/?page=login');
}
$user = require_auth();
header('X-Frame-Options: DENY');
header('Referrer-Policy: same-origin');

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
        } elseif ($action === 'save_text') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            [,,$target] = hc_resolve($targetRel, true);
            $content = (string)($_POST['content'] ?? '');
            hc_write_text_file($target, $content);
            add_event('cloud','Изменён файл: '.$targetRel);
            flash('Файл сохранён','success');
            $returnView = (string)($_POST['return_view'] ?? 'disk');
            $params = ['preview'=>$targetRel,'edit'=>'1'];
            if ($returnView !== 'disk' && in_array($returnView,['recent','archives','images','shared'],true)) $params['view']=$returnView;
            elseif ($current !== '') $params['path']=$current;
            redirect(hc_url($params));
        } elseif ($action === 'archive_save') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            [,,$target] = hc_resolve($targetRel, true);
            if (!is_file($target) || !hc_is_archive($target)) throw new RuntimeException('Архив не найден');
            $entry = hc_archive_entry_clean((string)($_POST['archive_entry'] ?? ''));
            $content = (string)($_POST['content'] ?? '');
            hc_archive_entry_write($target, $entry, $content);
            add_event('cloud','Изменён файл внутри архива: '.$targetRel.' :: '.$entry);
            flash('Изменения сохранены в архив','success');
            $returnView = (string)($_POST['return_view'] ?? 'disk');
            $params = ['preview'=>$targetRel,'archive_entry'=>$entry];
            if ($returnView !== 'disk' && in_array($returnView,['recent','archives','images','shared'],true)) $params['view']=$returnView;
            elseif ($current !== '') $params['path']=$current;
            redirect(hc_url($params));
        } elseif ($action === 'rename') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            if ($targetRel === '') throw new RuntimeException('Корень переименовать нельзя');
            [,,$target] = hc_resolve($targetRel,true);
            $name = hc_valid_name((string)($_POST['new_name'] ?? ''));
            $newPath = dirname($target).'/'.$name;
            if (file_exists($newPath) || is_link($newPath)) throw new RuntimeException('Такое имя уже занято');
            if (!@rename($target,$newPath)) throw new RuntimeException('Не удалось переименовать');
            $newRel = trim((dirname($targetRel)==='.'?'':dirname($targetRel)).'/'.$name,'/');
            hc_share_repath_tree($targetRel, $newRel);
            add_event('cloud','Переименовано: '.$targetRel.' → '.$name);
            flash('Переименовано','success');
        } elseif ($action === 'delete') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            if ($targetRel === '') throw new RuntimeException('Корень удалить нельзя');
            [,,$target] = hc_resolve($targetRel,true);
            hc_share_revoke_tree($targetRel);
            hc_rrmdir($target);
            add_event('cloud','Удалено: '.$targetRel);
            flash('Удалено','success');
            $returnView = (string)($_POST['return_view'] ?? 'disk');
            if ($returnView !== 'disk' && in_array($returnView,['recent','archives','images','shared'],true)) redirect(hc_url(['view'=>$returnView]));
            redirect(hc_url($current !== '' ? ['path'=>$current] : []));
        } elseif ($action === 'share_enable') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            $token = hc_share_enable($targetRel, (int)($user['id'] ?? 0));
            add_event('cloud','Открыт доступ по ссылке: '.$targetRel);
            flash('Доступ по ссылке включён','success');
            $current = hc_clean_rel((string)($_POST['path'] ?? ''));
            $returnView = (string)($_POST['return_view'] ?? 'disk');
            $params = ['share_open'=>$targetRel];
            if ($returnView !== 'disk' && in_array($returnView,['recent','archives','images','shared'],true)) $params['view']=$returnView;
            elseif ($current !== '') $params['path']=$current;
            redirect(hc_url($params));
        } elseif ($action === 'share_disable') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            hc_share_disable($targetRel);
            add_event('cloud','Закрыт доступ по ссылке: '.$targetRel);
            flash('Файл снова приватный','success');
            $current = hc_clean_rel((string)($_POST['path'] ?? ''));
            $returnView = (string)($_POST['return_view'] ?? 'disk');
            $params = ['share_open'=>$targetRel];
            if ($returnView !== 'disk' && in_array($returnView,['recent','archives','images','shared'],true)) $params['view']=$returnView;
            elseif ($current !== '') $params['path']=$current;
            redirect(hc_url($params));
        } else {
            throw new RuntimeException('Неизвестное действие');
        }
    } catch (Throwable $e) {
        flash($e->getMessage(),'danger');
    }
    redirect(hc_url(['path'=>$current]));
}

$view = (string)($_GET['view'] ?? 'disk');
if (!in_array($view,['disk','recent','archives','images','shared'],true)) $view = 'disk';
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
} elseif ($view === 'shared') {
    $allShares = hc_share_store_load();
    foreach (hc_share_index_by_path($allShares) as $sharedRel => $shareEntry) {
        try {
            [,,$sharedPath] = hc_resolve($sharedRel, true);
            if (!is_file($sharedPath) || is_link($sharedPath)) continue;
            $rows[] = ['name'=>basename($sharedPath),'path'=>$sharedPath,'rel'=>$sharedRel,'mtime'=>(int)(filemtime($sharedPath)?:0),'size'=>(int)(filesize($sharedPath)?:0),'dir'=>dirname($sharedRel)==='.'?'':dirname($sharedRel),'is_dir'=>false];
        } catch (Throwable) {}
    }
    usort($rows, static fn($a,$b)=>$b['mtime']<=>$a['mtime']);
} else {
    $rows = hc_recursive_files($root,$view);
    foreach ($rows as &$r) $r['is_dir']=false;
    unset($r);
}

$shares = hc_share_store_load();
$shareByPath = hc_share_index_by_path($shares);
$shareOpenRel = hc_clean_rel((string)($_GET['share_open'] ?? ''));

$previewRel = hc_clean_rel((string)($_GET['preview'] ?? ''));
$previewPath = null;
if ($previewRel !== '') {
    try { [,,$previewPath]=hc_resolve($previewRel,true); if(!is_file($previewPath)) $previewPath=null; } catch(Throwable) { $previewPath=null; }
}
$editText = ((string)($_GET['edit'] ?? '')) === '1';
$archiveEntry = '';
$archiveEntryData = null;
$archiveEntryError = '';
if ($previewPath && hc_is_archive($previewPath) && isset($_GET['archive_entry'])) {
    try {
        $archiveEntry = hc_archive_entry_clean((string)$_GET['archive_entry']);
        $archiveEntryData = hc_archive_entry_read($previewPath, $archiveEntry, 2097152);
    } catch (Throwable $e) {
        $archiveEntryError = $e->getMessage();
    }
}

$diskTotal = (float)(@disk_total_space($root) ?: 0);
$diskFree = (float)(@disk_free_space($root) ?: 0);
$diskUsed = max(0.0,$diskTotal-$diskFree);
$diskPct = $diskTotal > 0 ? min(100,($diskUsed/$diskTotal)*100) : 0;
$flash = flash();
$viewTitle = ['disk'=>'Мой диск','recent'=>'Последние','archives'=>'Архивы','images'=>'Изображения','shared'=>'Доступ по ссылке'][$view];
?>
<!doctype html>
<html lang="ru" data-bs-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#f7f9ff">
<title><?= e($viewTitle) ?> — HYPER CLOUD</title>
<link rel="preconnect" href="https://cdn.jsdelivr.net" crossorigin>
<link rel="preconnect" href="https://cdnjs.cloudflare.com" crossorigin>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" integrity="sha384-sRIl4kxILFvY47J16cr9ZwB07vP4J8+LH7qKQnuqkuIAvNWLzeN8tE5YBujZqJLB" crossorigin="anonymous">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css">
<link rel="stylesheet" href="/cloud/cloud.css?v=100">
</head>
<body data-share-open="<?= e($shareOpenRel) ?>">
<div class="hc-app" id="hcApp">
  <aside class="hc-sidebar" id="hcSidebar">
    <div class="hc-brand"><div class="hc-brand-mark"><i class="fa-solid fa-cloud"></i></div><div><b>HYPER CLOUD</b></div></div>
    <button class="hc-create" type="button" data-open-dialog="createDialog"><i class="fa-solid fa-plus"></i><span>Создать</span></button>
    <nav class="hc-nav">
      <a class="<?= $view==='disk'?'active':'' ?>" href="/cloud/"><i class="fa-regular fa-hard-drive"></i><span>Мой диск</span></a>
      <a class="<?= $view==='recent'?'active':'' ?>" href="<?= e(hc_url(['view'=>'recent'])) ?>"><i class="fa-regular fa-clock"></i><span>Последние</span></a>
      <a class="<?= $view==='archives'?'active':'' ?>" href="<?= e(hc_url(['view'=>'archives'])) ?>"><i class="fa-regular fa-file-zipper"></i><span>Архивы</span></a>
      <a class="<?= $view==='images'?'active':'' ?>" href="<?= e(hc_url(['view'=>'images'])) ?>"><i class="fa-regular fa-image"></i><span>Изображения</span></a>
      <a class="<?= $view==='shared'?'active':'' ?>" href="<?= e(hc_url(['view'=>'shared'])) ?>"><i class="fa-solid fa-link"></i><span>Доступ по ссылке</span><em><?= count($shareByPath) ?></em></a>
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
          <?php if($view==='disk'): ?><div class="hc-breadcrumb"><?= hc_breadcrumb($rel) ?></div><?php endif; ?>
        </div>
        <div class="hc-toolbar">
          <?php if($view==='disk' && $rel!==''): $up=dirname($rel); if($up==='.')$up=''; ?><a class="hc-btn ghost" href="<?= e(hc_url(['path'=>$up])) ?>"><i class="fa-solid fa-arrow-left"></i><span>Назад</span></a><?php endif; ?>
          <button class="hc-btn ghost" type="button" id="hcViewToggle" title="Переключить вид"><i class="fa-solid fa-table-cells-large"></i></button>
          <button class="hc-btn primary" type="button" data-open-dialog="uploadDialog"><i class="fa-solid fa-cloud-arrow-up"></i><span>Загрузить</span></button>
        </div>
      </div>

      <section class="hc-files-section">
        <div class="hc-section-head"><div><b><?= $view==='disk' ? e($rel===''?'Файлы и папки':basename($rel)) : e($viewTitle) ?></b><span id="hcItemCount"><?= count($rows) ?> элементов</span></div><?php if($view==='disk'): ?><button class="hc-link-btn" type="button" data-open-dialog="folderDialog"><i class="fa-solid fa-folder-plus"></i>Новая папка</button><?php endif; ?></div>

        <div class="hc-grid" id="hcFilesGrid">
          <?php foreach($rows as $row): $kind=hc_kind($row['path']); $isDir=(bool)$row['is_dir']; $share=$isDir?null:($shareByPath[$row['rel']]??null); $shareToken=is_array($share)?(string)($share['token']??''):''; $shareUrl=$shareToken!==''?hc_public_share_url($shareToken):''; $openHref=$isDir?hc_url(['path'=>$row['rel']]):hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$row['rel']],static fn($v)=>$v!==null)); ?>
          <article class="hc-file-card" data-file-name="<?= e(hc_lower($row['name'])) ?>" data-kind="<?= e($kind) ?>">
            <a class="hc-file-open" href="<?= e($openHref) ?>">
              <div class="hc-file-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($row['path'])) ?>"></i><?php if($kind==='image'): ?><img loading="lazy" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$row['rel']])) ?>" alt=""><?php endif; ?></div>
              <div class="hc-file-info"><div class="hc-file-name-line"><b title="<?= e($row['name']) ?>"><?= e($row['name']) ?></b><?php if(!$isDir): ?><span class="hc-privacy-pill <?= $shareToken!==''?'shared':'private' ?>" title="<?= $shareToken!==''?'Доступ по ссылке включён':'Приватный файл' ?>"><i class="fa-solid <?= $shareToken!==''?'fa-link':'fa-lock' ?>"></i><?= $shareToken!==''?'По ссылке':'Приватный' ?></span><?php endif; ?></div><span><?= $isDir ? 'Папка' : e(human_bytes((float)$row['size'])) ?> · <?= e(date('d.m.Y H:i',$row['mtime']?:time())) ?></span><?php if(!$isDir && $row['dir']!==''): ?><small>/<?= e($row['dir']) ?></small><?php endif; ?></div>
            </a>
            <div class="hc-file-actions">
              <?php if(!$isDir): ?><a title="Скачать" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>"><i class="fa-solid fa-download"></i></a><?php endif; ?>
              <button type="button" class="hc-delete-quick" title="Удалить" data-delete-target="<?= e($row['rel']) ?>" data-delete-name="<?= e($row['name']) ?>"><i class="fa-regular fa-trash-can"></i></button>
              <button type="button" title="Действия" data-menu-for="menu-<?= md5($row['rel']) ?>"><i class="fa-solid fa-ellipsis-vertical"></i></button>
            </div>
            <div class="hc-context-menu" id="menu-<?= md5($row['rel']) ?>">
              <?php if($isDir): ?><a href="<?= e(hc_url(['path'=>$row['rel']])) ?>"><i class="fa-regular fa-folder-open"></i>Открыть</a><?php else: ?><a href="<?= e($openHref) ?>"><i class="fa-regular fa-eye"></i>Открыть</a><a href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>"><i class="fa-solid fa-download"></i>Скачать</a><button type="button" class="hc-share-action <?= $shareToken!==''?'active':'' ?>" data-share-target="<?= e($row['rel']) ?>" data-share-name="<?= e($row['name']) ?>" data-share-url="<?= e($shareUrl) ?>" data-share-enabled="<?= $shareToken!==''?'1':'0' ?>"><i class="fa-solid <?= $shareToken!==''?'fa-link':'fa-lock' ?>"></i>Доступ</button><?php endif; ?>
              <button type="button" data-rename-target="<?= e($row['rel']) ?>" data-rename-name="<?= e($row['name']) ?>"><i class="fa-solid fa-pen"></i>Переименовать</button>
              <button class="danger" type="button" data-delete-target="<?= e($row['rel']) ?>" data-delete-name="<?= e($row['name']) ?>"><i class="fa-regular fa-trash-can"></i>Удалить</button>
            </div>
          </article>
          <?php endforeach; ?>
        </div>

        <div class="hc-list" id="hcFilesList" hidden>
          <?php foreach($rows as $row): $kind=hc_kind($row['path']); $isDir=(bool)$row['is_dir']; $share=$isDir?null:($shareByPath[$row['rel']]??null); $shareToken=is_array($share)?(string)($share['token']??''):''; $shareUrl=$shareToken!==''?hc_public_share_url($shareToken):''; $openHref=$isDir?hc_url(['path'=>$row['rel']]):hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$row['rel']],static fn($v)=>$v!==null)); ?>
          <div class="hc-list-row" data-file-name="<?= e(hc_lower($row['name'])) ?>"><a href="<?= e($openHref) ?>"><span class="hc-mini-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($row['path'])) ?>"></i></span><b><?= e($row['name']) ?></b></a><span><?= $isDir?'Папка':e(human_bytes((float)$row['size'])) ?></span><span><?= e(date('d.m.Y H:i',$row['mtime']?:time())) ?></span><div class="hc-list-actions"><?php if(!$isDir): ?><button type="button" class="hc-list-share <?= $shareToken!==''?'active':'' ?>" data-share-target="<?= e($row['rel']) ?>" data-share-name="<?= e($row['name']) ?>" data-share-url="<?= e($shareUrl) ?>" data-share-enabled="<?= $shareToken!==''?'1':'0' ?>" title="Доступ"><i class="fa-solid <?= $shareToken!==''?'fa-link':'fa-lock' ?>"></i></button><a class="hc-icon-btn" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>" title="Скачать"><i class="fa-solid fa-download"></i></a><?php endif; ?><button type="button" class="hc-icon-btn danger" data-delete-target="<?= e($row['rel']) ?>" data-delete-name="<?= e($row['name']) ?>" title="Удалить"><i class="fa-regular fa-trash-can"></i></button></div></div>
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

<dialog data-modal-lock="true" class="hc-dialog hc-small-dialog" id="createDialog">
  <div class="hc-dialog-head"><div><span>Создать</span><b>Что добавить в облако?</b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div>
  <div class="hc-dialog-body">
    <div class="hc-create-grid">
      <button type="button" data-open-dialog="uploadDialog"><span><i class="fa-solid fa-cloud-arrow-up"></i></span><b>Загрузить файлы</b><small>С компьютера или Drag & Drop</small></button>
      <button type="button" data-open-dialog="folderDialog"><span><i class="fa-solid fa-folder-plus"></i></span><b>Новая папка</b><small>Создать в текущем каталоге</small></button>
    </div>
  </div>
</dialog>

<dialog data-modal-lock="true" class="hc-dialog" id="uploadDialog">
  <form method="post" enctype="multipart/form-data" id="hcUploadForm">
    <input type="hidden" name="action" value="upload"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>">
    <div class="hc-dialog-head"><div><span>Загрузка</span><b>Добавить файлы в облако</b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div>
    <div class="hc-dialog-body">
      <label class="hc-field"><span>Куда загрузить</span><select name="upload_target" id="hcUploadTarget"><option value=""<?= $rel===''?' selected':'' ?>>☁ Корень облака</option><?php foreach($folderTree as $folder): $fpath=(string)$folder['path']; ?><option value="<?= e($fpath) ?>"<?= $fpath===$rel?' selected':'' ?>><?= e(str_repeat('— ',min((int)$folder['depth']+1,10)).$folder['name'].($fpath===$rel?' · текущая':'')) ?></option><?php endforeach; ?></select></label>
      <label class="hc-upload-zone" id="hcUploadZone"><input type="file" id="hcFilesInput" name="files[]" multiple hidden><span><i class="fa-solid fa-cloud-arrow-up"></i></span><b>Перетащите файлы сюда</b><p>или нажмите, чтобы выбрать с компьютера</p></label>
      <div class="hc-upload-queue" id="hcUploadQueue" hidden><div class="hc-upload-queue-head"><b id="hcQueueCount"></b><span id="hcQueueSize"></span></div><div id="hcQueueFiles"></div></div>
    </div>
    <div class="hc-dialog-foot"><span class="hc-modal-hint"><i class="fa-solid fa-lock"></i> Закрытие только по крестику</span><button type="submit" class="hc-btn primary" id="hcUploadSubmit" disabled><i class="fa-solid fa-cloud-arrow-up"></i>Загрузить</button></div>
  </form>
</dialog>

<dialog data-modal-lock="true" class="hc-dialog hc-small-dialog" id="folderDialog">
  <form method="post"><input type="hidden" name="action" value="mkdir"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>"><div class="hc-dialog-head"><div><span>Новая папка</span><b>Создать в <?= e($rel!==''?'/'.$rel:'корне облака') ?></b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div><div class="hc-dialog-body"><label class="hc-field"><span>Название</span><input name="name" maxlength="180" placeholder="Например: Документы" autofocus required></label></div><div class="hc-dialog-foot"><span class="hc-modal-hint"><i class="fa-solid fa-lock"></i> Закрытие только по крестику</span><button class="hc-btn primary">Создать</button></div></form>
</dialog>

<dialog data-modal-lock="true" class="hc-dialog hc-small-dialog" id="renameDialog">
  <form method="post"><input type="hidden" name="action" value="rename"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>"><input type="hidden" name="target" id="hcRenameTarget"><div class="hc-dialog-head"><div><span>Переименование</span><b>Новое имя</b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div><div class="hc-dialog-body"><label class="hc-field"><span>Имя</span><input name="new_name" id="hcRenameName" maxlength="180" required></label></div><div class="hc-dialog-foot"><span class="hc-modal-hint"><i class="fa-solid fa-lock"></i> Закрытие только по крестику</span><button class="hc-btn primary">Сохранить</button></div></form>
</dialog>

<dialog data-modal-lock="true" class="hc-dialog hc-small-dialog hc-delete-dialog" id="deleteDialog">
  <form method="post"><input type="hidden" name="action" value="delete"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="return_view" value="<?= e($view) ?>"><input type="hidden" name="target" id="hcDeleteTarget"><div class="hc-dialog-head"><div><span>Удаление</span><b id="hcDeleteName">Файл</b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div><div class="hc-dialog-body"><div class="hc-delete-warning"><span><i class="fa-regular fa-trash-can"></i></span><div><b>Удалить безвозвратно?</b><p>Файл или папка будут удалены из облака.</p></div></div></div><div class="hc-dialog-foot"><span></span><button class="hc-btn danger-solid" type="submit"><i class="fa-regular fa-trash-can"></i>Удалить</button></div></form>
</dialog>

<dialog data-modal-lock="true" class="hc-dialog hc-share-dialog" id="shareDialog">
  <div class="hc-dialog-head hc-share-head"><div><span>Доступ к файлу</span><b id="hcShareName">Файл</b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div>
  <div class="hc-dialog-body">
    <div class="hc-share-state" id="hcSharePrivate"><span class="hc-share-state-icon private"><i class="fa-solid fa-lock"></i></span><div><b>Приватный</b><p>Доступ только после входа.</p></div></div>
    <div class="hc-share-state" id="hcSharePublic" hidden><span class="hc-share-state-icon public"><i class="fa-solid fa-link"></i></span><div><b>Ссылка активна</b><p>Файл доступен по публичной ссылке.</p></div></div>
    <div class="hc-share-linkbox" id="hcShareLinkBox" hidden><label>Публичная ссылка</label><div><input type="text" id="hcShareUrl" readonly><button type="button" id="hcCopyShare"><i class="fa-regular fa-copy"></i><span>Копировать</span></button></div></div>
  </div>
  <div class="hc-dialog-foot hc-share-foot">
    <form method="post" id="hcShareEnableForm"><input type="hidden" name="action" value="share_enable"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="return_view" value="<?= e($view) ?>"><input type="hidden" name="target" id="hcShareEnableTarget"><button class="hc-btn primary" type="submit"><i class="fa-solid fa-link"></i>Открыть доступ по ссылке</button></form>
    <form method="post" id="hcShareDisableForm" hidden><input type="hidden" name="action" value="share_disable"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="return_view" value="<?= e($view) ?>"><input type="hidden" name="target" id="hcShareDisableTarget"><button class="hc-btn danger-soft" type="submit"><i class="fa-solid fa-link-slash"></i>Закрыть доступ</button></form>
  </div>
</dialog>

<?php if($previewPath): $mime=hc_mime($previewPath); $previewIsArchive=hc_is_archive($previewPath); $previewIsText=!$previewIsArchive && hc_is_text($previewPath) && hc_is_editable_text_name(basename($previewPath)) && (filesize($previewPath)?:0)<=2*1024*1024; ?>
<div class="hc-preview-backdrop" id="hcPreview" data-preview-open>
  <section class="hc-preview-panel<?= $previewIsArchive?' is-archive':'' ?><?= ($editText || $archiveEntry!=='')?' is-editor':'' ?>">
    <header><div><span><?= ($editText || $archiveEntry!=='')?'Редактор':'Просмотр' ?></span><b><?= e($archiveEntry!==''?basename($archiveEntry):basename($previewPath)) ?></b><small><?= $archiveEntry!=='' ? e(basename($previewPath)) : e(human_bytes((float)(filesize($previewPath)?:0))) ?></small></div><div><?php $previewShare=$shareByPath[$previewRel]??null; $previewShareToken=is_array($previewShare)?(string)($previewShare['token']??''):''; ?><?php if($previewIsText && !$editText): ?><a class="hc-btn soft" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel,'edit'=>'1'],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-code"></i>Редактировать</a><?php endif; ?><?php if($archiveEntry===''): ?><button type="button" class="hc-btn <?= $previewShareToken!==''?'share-on':'soft' ?>" data-share-target="<?= e($previewRel) ?>" data-share-name="<?= e(basename($previewPath)) ?>" data-share-url="<?= e($previewShareToken!==''?hc_public_share_url($previewShareToken):'') ?>" data-share-enabled="<?= $previewShareToken!==''?'1':'0' ?>"><i class="fa-solid <?= $previewShareToken!==''?'fa-link':'fa-lock' ?>"></i>Доступ</button><a class="hc-btn soft" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$previewRel])) ?>"><i class="fa-solid fa-download"></i>Скачать</a><button type="button" class="hc-btn danger-soft hc-preview-delete" data-delete-target="<?= e($previewRel) ?>" data-delete-name="<?= e(basename($previewPath)) ?>"><i class="fa-regular fa-trash-can"></i>Удалить</button><?php endif; ?><a class="hc-preview-close" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$archiveEntry!==''?$previewRel:null],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-xmark"></i></a></div></header>
    <div class="hc-preview-body<?= $previewIsArchive?' is-archive':'' ?><?= ($editText || $archiveEntry!=='')?' is-editor':'' ?>">
      <?php if($previewIsArchive && $archiveEntry!==''): ?>
        <?php if($archiveEntryError!==''): ?><div class="hc-preview-fallback"><i class="fa-solid fa-triangle-exclamation"></i><b>Не удалось открыть файл</b><p><?= e($archiveEntryError) ?></p><a class="hc-btn soft" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-arrow-left"></i>К архиву</a></div>
        <?php else: $archiveWritable=(bool)($archiveEntryData['writable']??false); $archiveContent=(string)($archiveEntryData['content']??''); ?>
          <form method="post" class="hc-editor-form" data-editor-form><input type="hidden" name="action" value="archive_save"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="return_view" value="<?= e($view) ?>"><input type="hidden" name="target" value="<?= e($previewRel) ?>"><input type="hidden" name="archive_entry" value="<?= e($archiveEntry) ?>">
            <div class="hc-editor-toolbar"><a class="hc-editor-back" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-arrow-left"></i>Архив</a><div><span class="hc-editor-lang"><?= e(strtoupper(pathinfo($archiveEntry,PATHINFO_EXTENSION) ?: 'TXT')) ?></span><span id="hcEditorLines">1 строка</span></div><?php if($archiveWritable): ?><button class="hc-btn primary" type="submit"><i class="fa-solid fa-floppy-disk"></i>Сохранить</button><?php else: ?><span class="hc-editor-readonly"><i class="fa-solid fa-lock"></i>Только чтение</span><?php endif; ?></div>
            <textarea class="hc-code-editor" name="content" spellcheck="false" autocomplete="off" autocapitalize="off" <?= $archiveWritable?'':'readonly' ?>><?= e($archiveContent) ?></textarea>
          </form>
        <?php endif; ?>
      <?php elseif($previewIsArchive): $archive=hc_archive_entries($previewPath); $archiveWritable=hc_archive_writer($previewPath)!==''; ?>
        <?php if(!empty($archive['ok'])): ?>
          <div class="hc-archive-head"><span class="hc-archive-main-icon"><i class="fa-solid fa-file-zipper"></i></span><div><b><?= e(basename($previewPath)) ?></b><span><?= count($archive['entries']) ?> элементов</span></div></div>
          <div class="hc-archive-table"><table><thead><tr><th>Имя</th><th>Размер</th><th>Изменён</th><th></th></tr></thead><tbody><?php foreach($archive['entries'] as $entry): $entryName=(string)($entry['name']??''); $canEdit=hc_is_editable_text_name($entryName) && !str_ends_with($entryName,'/') && (int)($entry['size']??0)<=2*1024*1024; $entryHref=$canEdit?hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel,'archive_entry'=>$entryName],static fn($v)=>$v!==null)):''; ?><tr><td><?php if($canEdit): ?><a class="hc-archive-open" href="<?= e($entryHref) ?>"><?php endif; ?><span class="hc-archive-entry-icon"><i class="fa-solid <?= e(hc_archive_entry_icon($entryName)) ?>"></i></span><b><?= e($entryName) ?></b><?php if($canEdit): ?></a><?php endif; ?></td><td><?= str_ends_with($entryName,'/') ? '—' : e(human_bytes((float)($entry['size']??0))) ?></td><td><?= e((string)($entry['modified']??'—')) ?></td><td><?php if($canEdit): ?><a class="hc-archive-edit-btn" href="<?= e($entryHref) ?>" title="<?= $archiveWritable?'Редактировать':'Открыть' ?>"><i class="fa-solid <?= $archiveWritable?'fa-pen-to-square':'fa-eye' ?>"></i></a><?php endif; ?></td></tr><?php endforeach; ?></tbody></table></div>
          <?php if(!empty($archive['truncated'])): ?><div class="hc-preview-note">Показаны первые 1000 элементов.</div><?php endif; ?>
        <?php else: ?><div class="hc-preview-fallback"><i class="fa-solid fa-file-circle-xmark"></i><b>Не удалось открыть архив</b><p><?= e((string)($archive['error']??'')) ?></p></div><?php endif; ?>
      <?php elseif($previewIsText && $editText): $txt=@file_get_contents($previewPath,false,null,0,2*1024*1024); ?>
        <form method="post" class="hc-editor-form" data-editor-form><input type="hidden" name="action" value="save_text"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="return_view" value="<?= e($view) ?>"><input type="hidden" name="target" value="<?= e($previewRel) ?>"><div class="hc-editor-toolbar"><a class="hc-editor-back" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-arrow-left"></i>Просмотр</a><div><span class="hc-editor-lang"><?= e(strtoupper(pathinfo($previewPath,PATHINFO_EXTENSION) ?: 'TXT')) ?></span><span id="hcEditorLines">1 строка</span></div><button class="hc-btn primary" type="submit"><i class="fa-solid fa-floppy-disk"></i>Сохранить</button></div><textarea class="hc-code-editor" name="content" spellcheck="false" autocomplete="off" autocapitalize="off"><?= e(is_string($txt)?$txt:'') ?></textarea></form>
      <?php elseif(str_starts_with($mime,'image/')): ?><img class="hc-preview-image" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>" alt="">
      <?php elseif($mime==='application/pdf'): ?><iframe class="hc-preview-frame" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></iframe>
      <?php elseif(str_starts_with($mime,'video/')): ?><video class="hc-preview-media" controls preload="metadata" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></video>
      <?php elseif(str_starts_with($mime,'audio/')): ?><div class="hc-audio-wrap"><audio controls preload="metadata" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></audio></div>
      <?php elseif($previewIsText): $txt=@file_get_contents($previewPath,false,null,0,2*1024*1024); ?><pre class="hc-code-preview"><?= e(is_string($txt)?$txt:'') ?></pre>
      <?php else: ?><div class="hc-preview-fallback"><i class="fa-solid fa-file-arrow-down"></i><b>Предпросмотр недоступен</b><a class="hc-btn primary" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$previewRel])) ?>">Скачать файл</a></div><?php endif; ?>
    </div>
  </section>
</div>
<?php endif; ?>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/js/bootstrap.bundle.min.js" integrity="sha384-FKyoEForCGlyvwx9Hj09JcYn3nv7wiPVlz7YYwJrWVcXK/BmnVDxM+D2scQbITxI" crossorigin="anonymous" defer></script>
<script src="/cloud/cloud.js?v=100" defer></script>
</body>
</html>
