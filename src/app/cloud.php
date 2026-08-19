<?php
declare(strict_types=1);

/**
 * HYPER-HOST Cloud Storage v94
 * Separate private storage mounted at /var/www/hyper-host-cloud.
 */

function hh_cloud_root(): string
{
    $root = rtrim((string)app_config('cloud_dir', '/var/www/hyper-host-cloud'), '/');
    return $root !== '' ? $root : '/var/www/hyper-host-cloud';
}

function hh_cloud_clean_rel(string $value): string
{
    $value = str_replace("\0", '', $value);
    $value = str_replace('\\', '/', trim($value));
    $parts = [];
    foreach (explode('/', $value) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') throw new RuntimeException('Недопустимый путь');
        if (preg_match('/[\x00-\x1F\x7F]/u', $part)) throw new RuntimeException('Недопустимое имя файла');
        $parts[] = $part;
    }
    return implode('/', $parts);
}

function hh_cloud_resolve(string $rel = '', bool $mustExist = false): array
{
    $root = hh_cloud_root();
    $rel = hh_cloud_clean_rel($rel);
    if (!is_dir($root)) {
        @mkdir($root, 0770, true);
    }
    $rootReal = realpath($root) ?: $root;
    $path = $root . ($rel !== '' ? '/' . $rel : '');

    if ($mustExist && !file_exists($path) && !is_link($path)) {
        throw new RuntimeException('Файл или папка не найдены');
    }

    if (file_exists($path) || is_link($path)) {
        $real = realpath($path);
        if ($real === false) {
            if (is_link($path)) throw new RuntimeException('Символические ссылки в облаке запрещены');
            $real = $path;
        }
        if ($real !== $rootReal && !str_starts_with($real, $rootReal . DIRECTORY_SEPARATOR)) {
            throw new RuntimeException('Выход за пределы облака запрещён');
        }
    } else {
        $parent = dirname($path);
        $parentReal = realpath($parent);
        if ($parentReal === false || ($parentReal !== $rootReal && !str_starts_with($parentReal, $rootReal . DIRECTORY_SEPARATOR))) {
            throw new RuntimeException('Недопустимый путь');
        }
    }

    return [$root, $rel, $path];
}

function hh_cloud_valid_name(string $name): string
{
    $name = trim(str_replace("\0", '', $name));
    if ($name === '' || in_array($name, ['.', '..'], true)) throw new RuntimeException('Укажите имя');
    if (preg_match('/[\\\/\x00-\x1F\x7F]/u', $name)) throw new RuntimeException('В имени нельзя использовать / или \\');
    if (mb_strlen($name) > 180) throw new RuntimeException('Слишком длинное имя');
    return $name;
}

function hh_cloud_unique_target(string $dir, string $name): string
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
    throw new RuntimeException('Не удалось подобрать свободное имя файла');
}

function hh_cloud_url(array $params = []): string
{
    return '/?' . http_build_query(array_merge(['page' => 'cloud'], $params), '', '&', PHP_QUERY_RFC3986);
}

function hh_cloud_mime(string $path): string
{
    if (class_exists('finfo')) {
        $f = new finfo(FILEINFO_MIME_TYPE);
        $mime = $f->file($path);
        if (is_string($mime) && $mime !== '') return $mime;
    }
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    return match ($ext) {
        'jpg', 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'gif' => 'image/gif', 'webp' => 'image/webp', 'svg' => 'image/svg+xml',
        'pdf' => 'application/pdf', 'mp4' => 'video/mp4', 'webm' => 'video/webm', 'mp3' => 'audio/mpeg', 'ogg' => 'audio/ogg',
        'txt', 'log', 'md', 'json', 'xml', 'csv', 'ini', 'env', 'conf', 'yml', 'yaml', 'php', 'py', 'js', 'css', 'html', 'htm', 'sql', 'sh' => 'text/plain; charset=utf-8',
        default => 'application/octet-stream',
    };
}

function hh_cloud_is_archive(string $path): bool
{
    $name = strtolower(basename($path));
    foreach (['.zip', '.rar', '.7z', '.tar', '.tar.gz', '.tgz', '.tar.bz2', '.tbz2', '.tar.xz', '.txz', '.gz', '.bz2', '.xz'] as $ext) {
        if (str_ends_with($name, $ext)) return true;
    }
    return false;
}

function hh_cloud_archive_entries(string $path, int $limit = 1000): array
{
    $entries = [];
    $lower = strtolower($path);
    if (str_ends_with($lower, '.zip') && class_exists('ZipArchive')) {
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
            return ['ok' => true, 'entries' => $entries, 'truncated' => $truncated, 'engine' => 'ZipArchive'];
        }
    }

    $commands = [];
    if (is_executable('/usr/bin/7z')) $commands[] = ['/usr/bin/7z', 'l', '-slt', '--', $path];
    if (is_executable('/usr/bin/7zz')) $commands[] = ['/usr/bin/7zz', 'l', '-slt', '--', $path];
    if (is_executable('/usr/bin/bsdtar')) $commands[] = ['/usr/bin/bsdtar', '-tf', $path];

    foreach ($commands as $cmd) {
        $line = implode(' ', array_map('escapeshellarg', $cmd)) . ' 2>&1';
        $out = [];
        $code = 0;
        exec($line, $out, $code);
        if ($code !== 0 && !$out) continue;

        if (str_contains($cmd[0], '7z')) {
            $current = [];
            foreach ($out as $raw) {
                $raw = rtrim((string)$raw);
                if ($raw === '') {
                    if (!empty($current['Path'])) {
                        $n = (string)$current['Path'];
                        if ($n !== $path && $n !== basename($path)) {
                            $entries[] = [
                                'name' => $n,
                                'size' => (int)($current['Size'] ?? 0),
                                'packed' => (int)($current['Packed Size'] ?? 0),
                                'modified' => (string)($current['Modified'] ?? '—'),
                            ];
                            if (count($entries) >= $limit) break;
                        }
                    }
                    $current = [];
                    continue;
                }
                if (preg_match('/^([^=]+) = (.*)$/', $raw, $m)) $current[trim($m[1])] = $m[2];
            }
            if ($entries) return ['ok' => true, 'entries' => $entries, 'truncated' => count($entries) >= $limit, 'engine' => basename($cmd[0])];
        } else {
            foreach ($out as $raw) {
                if (count($entries) >= $limit) break;
                $raw = trim((string)$raw);
                if ($raw === '') continue;
                $entries[] = ['name' => $raw, 'size' => 0, 'packed' => 0, 'modified' => '—'];
            }
            if ($entries) return ['ok' => true, 'entries' => $entries, 'truncated' => count($entries) >= $limit, 'engine' => 'bsdtar'];
        }
    }
    return ['ok' => false, 'entries' => [], 'truncated' => false, 'engine' => '', 'error' => 'Не удалось прочитать архив. Установите p7zip-full/libarchive-tools.'];
}

function hh_cloud_stream_file(string $path, bool $inline = false): never
{
    if (!is_file($path) || is_link($path) || !is_readable($path)) throw new RuntimeException('Файл недоступен');
    while (ob_get_level() > 0) @ob_end_clean();
    @set_time_limit(0);
    $size = (int)filesize($path);
    $start = 0;
    $end = max(0, $size - 1);
    $status = 200;
    $range = (string)($_SERVER['HTTP_RANGE'] ?? '');
    if ($size > 0 && preg_match('/bytes=(\d*)-(\d*)/', $range, $m)) {
        if ($m[1] === '' && $m[2] !== '') {
            $suffix = min((int)$m[2], $size);
            $start = $size - $suffix;
        } else {
            $start = $m[1] !== '' ? (int)$m[1] : 0;
            $end = $m[2] !== '' ? min((int)$m[2], $size - 1) : $size - 1;
        }
        if ($start < 0 || $start > $end || $start >= $size) {
            header('Content-Range: bytes */' . $size);
            http_response_code(416);
            exit;
        }
        $status = 206;
    }
    $length = $size > 0 ? ($end - $start + 1) : 0;
    http_response_code($status);
    header('Content-Type: ' . hh_cloud_mime($path));
    header('Accept-Ranges: bytes');
    header('X-Content-Type-Options: nosniff');
    if ($inline) header("Content-Security-Policy: sandbox; default-src 'none'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'unsafe-inline'");
    header('Cache-Control: private, max-age=0, must-revalidate');
    if ($status === 206) header('Content-Range: bytes ' . $start . '-' . $end . '/' . $size);
    header('Content-Length: ' . $length);
    $name = basename($path);
    $fallback = preg_replace('/[^A-Za-z0-9._-]+/', '_', $name) ?: 'download';
    $disposition = $inline ? 'inline' : 'attachment';
    header("Content-Disposition: {$disposition}; filename=\"{$fallback}\"; filename*=UTF-8''" . rawurlencode($name));

    $fh = fopen($path, 'rb');
    if ($fh === false) exit;
    if ($start > 0) fseek($fh, $start);
    $remaining = $length;
    while (!feof($fh) && $remaining > 0) {
        $chunk = fread($fh, min(1024 * 1024, $remaining));
        if ($chunk === false || $chunk === '') break;
        echo $chunk;
        $remaining -= strlen($chunk);
        flush();
        if (connection_aborted()) break;
    }
    fclose($fh);
    exit;
}

function hh_cloud_rrmdir(string $path): void
{
    if (is_link($path) || is_file($path)) {
        if (!@unlink($path)) throw new RuntimeException('Не удалось удалить файл');
        return;
    }
    if (!is_dir($path)) return;
    foreach (scandir($path) ?: [] as $item) {
        if ($item === '.' || $item === '..') continue;
        hh_cloud_rrmdir($path . '/' . $item);
    }
    if (!@rmdir($path)) throw new RuntimeException('Не удалось удалить папку');
}

function hh_cloud_handle_get(string $action): never
{
    $rel = (string)($_GET['path'] ?? '');
    [, , $path] = hh_cloud_resolve($rel, true);
    if ($action === 'download') hh_cloud_stream_file($path, false);
    if ($action === 'raw') hh_cloud_stream_file($path, true);
    http_response_code(404);
    exit;
}

function hh_cloud_handle_post(string $action): never
{
    try {
        $current = hh_cloud_clean_rel((string)($_POST['path'] ?? ''));
        [, , $dir] = hh_cloud_resolve($current, true);
        if (!is_dir($dir)) throw new RuntimeException('Текущая папка не найдена');

        if ($action === 'cloud_mkdir') {
            $name = hh_cloud_valid_name((string)($_POST['name'] ?? ''));
            $target = $dir . '/' . $name;
            if (file_exists($target) || is_link($target)) throw new RuntimeException('Папка или файл с таким именем уже существует');
            if (!mkdir($target, 02770, false)) throw new RuntimeException('Не удалось создать папку');
            @chown($target, 'www-data'); @chgrp($target, 'www-data'); @chmod($target, 02770);
            add_event('cloud', 'Создана папка: ' . ($current !== '' ? $current . '/' : '') . $name);
            flash('Папка создана: ' . $name, 'success');
        } elseif ($action === 'cloud_upload') {
            if (!isset($_FILES['files'])) throw new RuntimeException('Выберите файлы');
            $names = is_array($_FILES['files']['name'] ?? null) ? $_FILES['files']['name'] : [$_FILES['files']['name'] ?? ''];
            $tmps = is_array($_FILES['files']['tmp_name'] ?? null) ? $_FILES['files']['tmp_name'] : [$_FILES['files']['tmp_name'] ?? ''];
            $errors = is_array($_FILES['files']['error'] ?? null) ? $_FILES['files']['error'] : [$_FILES['files']['error'] ?? UPLOAD_ERR_NO_FILE];
            $uploaded = 0;
            foreach ($names as $i => $rawName) {
                $error = (int)($errors[$i] ?? UPLOAD_ERR_NO_FILE);
                if ($error === UPLOAD_ERR_NO_FILE) continue;
                if ($error !== UPLOAD_ERR_OK) {
                    $msg = match ($error) {
                        UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE => 'Файл превышает лимит загрузки сервера',
                        UPLOAD_ERR_PARTIAL => 'Файл загрузился не полностью',
                        UPLOAD_ERR_NO_TMP_DIR => 'На сервере отсутствует временная папка загрузки',
                        UPLOAD_ERR_CANT_WRITE => 'Сервер не смог записать временный файл',
                        default => 'Ошибка загрузки файла',
                    };
                    throw new RuntimeException($msg . ': ' . (string)$rawName);
                }
                $tmp = (string)($tmps[$i] ?? '');
                if ($tmp === '' || !is_uploaded_file($tmp)) continue;
                $name = hh_cloud_valid_name(basename((string)$rawName));
                $target = hh_cloud_unique_target($dir, $name);
                if (!move_uploaded_file($tmp, $target)) throw new RuntimeException('Не удалось сохранить: ' . $name);
                @chmod($target, 0660); @chown($target, 'www-data'); @chgrp($target, 'www-data');
                $uploaded++;
            }
            if ($uploaded < 1) throw new RuntimeException('Не удалось загрузить ни одного файла');
            add_event('cloud', 'Загружено файлов: ' . $uploaded . ' в /' . $current);
            flash('Загружено файлов: ' . $uploaded, 'success');
        } elseif ($action === 'cloud_delete') {
            $targetRel = hh_cloud_clean_rel((string)($_POST['target'] ?? ''));
            if ($targetRel === '') throw new RuntimeException('Корень облака удалить нельзя');
            [, , $target] = hh_cloud_resolve($targetRel, true);
            hh_cloud_rrmdir($target);
            add_event('cloud', 'Удалено: ' . $targetRel);
            flash('Удалено: ' . basename($targetRel), 'success');
        } elseif ($action === 'cloud_rename') {
            $targetRel = hh_cloud_clean_rel((string)($_POST['target'] ?? ''));
            [, , $target] = hh_cloud_resolve($targetRel, true);
            $name = hh_cloud_valid_name((string)($_POST['new_name'] ?? ''));
            $newPath = dirname($target) . '/' . $name;
            if (file_exists($newPath) || is_link($newPath)) throw new RuntimeException('Такое имя уже занято');
            if (!@rename($target, $newPath)) throw new RuntimeException('Не удалось переименовать');
            add_event('cloud', 'Переименовано: ' . $targetRel . ' → ' . $name);
            flash('Переименовано', 'success');
        } else {
            throw new RuntimeException('Неизвестное действие облака');
        }
    } catch (Throwable $e) {
        flash($e->getMessage(), 'danger');
    }
    redirect(hh_cloud_url(['path' => $current ?? '']));
}

function hh_cloud_item_icon(string $path): string
{
    if (is_dir($path)) return 'fa-folder text-warning';
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    return match ($ext) {
        'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz' => 'fa-file-zipper text-warning',
        'jpg', 'jpeg', 'png', 'gif', 'webp', 'svg' => 'fa-file-image text-info',
        'pdf' => 'fa-file-pdf text-danger',
        'mp4', 'webm', 'mov', 'mkv' => 'fa-file-video text-primary',
        'mp3', 'ogg', 'wav', 'flac' => 'fa-file-audio text-success',
        'php', 'py', 'js', 'css', 'html', 'sql', 'json', 'xml', 'sh' => 'fa-file-code text-info',
        default => 'fa-file text-secondary',
    };
}

function hh_cloud_is_text(string $path): bool
{
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    if (in_array($ext, ['txt','log','md','json','xml','csv','ini','env','conf','yml','yaml','php','py','js','ts','css','scss','html','htm','sql','sh','bat','ps1','c','cpp','h','hpp','java','go','rs'], true)) return true;
    $sample = @file_get_contents($path, false, null, 0, 4096);
    return is_string($sample) && !str_contains($sample, "\0");
}

function hh_cloud_breadcrumb(string $rel): string
{
    $html = '<a href="' . e(hh_cloud_url()) . '"><i class="fa-solid fa-cloud"></i> Облако</a>';
    $walk = '';
    foreach (array_filter(explode('/', $rel), static fn($v) => $v !== '') as $part) {
        $walk = trim($walk . '/' . $part, '/');
        $html .= '<span>/</span><a href="' . e(hh_cloud_url(['path' => $walk])) . '">' . e($part) . '</a>';
    }
    return $html;
}

function view_cloud(): void
{
    $rel = hh_cloud_clean_rel((string)($_GET['path'] ?? ''));
    [$root, , $dir] = hh_cloud_resolve($rel, true);
    if (!is_dir($dir)) { $rel = dirname($rel); if ($rel === '.') $rel = ''; [, , $dir] = hh_cloud_resolve($rel, true); }
    $items = array_values(array_filter(scandir($dir) ?: [], static fn($v) => $v !== '.' && $v !== '..'));
    usort($items, static function(string $a, string $b) use ($dir): int {
        $ad = is_dir($dir . '/' . $a); $bd = is_dir($dir . '/' . $b);
        if ($ad !== $bd) return $ad ? -1 : 1;
        return strnatcasecmp($a, $b);
    });
    $previewRel = hh_cloud_clean_rel((string)($_GET['preview'] ?? ''));
    $previewPath = null;
    if ($previewRel !== '') {
        try { [, , $previewPath] = hh_cloud_resolve($previewRel, true); if (!is_file($previewPath)) $previewPath = null; } catch (Throwable) { $previewPath = null; }
    }
    $diskTotal = (float)(@disk_total_space($root) ?: 0);
    $diskFree = (float)(@disk_free_space($root) ?: 0);
    $folderBytes = 0; $fileCount = 0; $folderCount = 0;
    foreach ($items as $it) { $p = $dir . '/' . $it; if (is_dir($p)) $folderCount++; elseif (is_file($p)) { $fileCount++; $folderBytes += (float)(filesize($p) ?: 0); } }
    ?>
<style>
.cloud-page{display:grid;gap:18px}.cloud-hero{position:relative;overflow:hidden;padding:24px;border:1px solid rgba(92,142,255,.18);background:linear-gradient(135deg,rgba(33,55,96,.88),rgba(16,24,43,.96));border-radius:22px}.cloud-hero:after{content:"";position:absolute;width:260px;height:260px;border-radius:50%;right:-80px;top:-120px;background:rgba(74,125,255,.18);filter:blur(10px)}.cloud-hero-top{position:relative;z-index:1;display:flex;justify-content:space-between;gap:20px;align-items:flex-start;flex-wrap:wrap}.cloud-kicker{font-size:12px;letter-spacing:.16em;text-transform:uppercase;color:#87a8ff;font-weight:800}.cloud-hero h2{margin:8px 0 5px;font-size:30px}.cloud-path{display:flex;gap:8px;flex-wrap:wrap;align-items:center;color:#9baccc}.cloud-path a{color:#d8e4ff;text-decoration:none}.cloud-stats{position:relative;z-index:1;display:grid;grid-template-columns:repeat(3,minmax(110px,1fr));gap:10px;min-width:min(100%,430px)}.cloud-stat{padding:12px 14px;border:1px solid rgba(255,255,255,.08);background:rgba(8,14,28,.45);border-radius:15px}.cloud-stat span{display:block;color:#8899ba;font-size:12px}.cloud-stat b{display:block;margin-top:4px}.cloud-grid{display:grid;grid-template-columns:minmax(260px,330px) minmax(0,1fr);gap:18px}.cloud-side{display:grid;gap:16px;align-content:start}.cloud-card{background:rgba(16,23,39,.92);border:1px solid rgba(255,255,255,.07);border-radius:20px;padding:18px}.cloud-drop{display:block;border:1px dashed rgba(110,154,255,.42);border-radius:16px;padding:20px;text-align:center;background:rgba(64,102,190,.08)}.cloud-drop i{font-size:34px;color:#79a0ff}.cloud-drop b,.cloud-drop span{display:block}.cloud-drop span{font-size:12px;color:#8999b8;margin-top:4px}.cloud-file-table td{vertical-align:middle}.cloud-name{display:flex;align-items:center;gap:11px;min-width:230px}.cloud-name i{width:24px;text-align:center;font-size:18px}.cloud-name a{color:#e7eeff;text-decoration:none;font-weight:650}.cloud-actions{display:flex;gap:6px;justify-content:flex-end;flex-wrap:wrap}.cloud-empty{text-align:center;padding:48px 20px;color:#8798b9}.cloud-preview{margin-top:18px}.cloud-preview-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:14px}.cloud-preview-body{border:1px solid rgba(255,255,255,.07);border-radius:16px;background:#0a101c;overflow:hidden}.cloud-preview-body pre{margin:0;padding:18px;max-height:620px;overflow:auto;color:#dbe7ff;font-size:13px;white-space:pre-wrap;word-break:break-word}.cloud-preview-img{display:block;max-width:100%;max-height:70vh;margin:auto}.cloud-preview-frame{width:100%;height:70vh;border:0;background:white}.cloud-archive{max-height:560px;overflow:auto}.cloud-archive table{margin:0}.cloud-archive small{color:#8ea0c2}.cloud-rename{display:flex;gap:6px;min-width:210px}.cloud-rename input{min-width:120px}.cloud-size{white-space:nowrap;color:#aab8d2}.cloud-meta{font-size:12px;color:#8394b5}.cloud-up{display:inline-flex;align-items:center;gap:8px;text-decoration:none}.cloud-progress{height:7px;background:rgba(255,255,255,.07);border-radius:999px;overflow:hidden;margin-top:12px}.cloud-progress i{display:block;height:100%;background:linear-gradient(90deg,#4f7dff,#65d4ff)}
@media(max-width:980px){.cloud-grid{grid-template-columns:1fr}.cloud-stats{width:100%;min-width:0}}@media(max-width:620px){.cloud-stats{grid-template-columns:1fr}.cloud-card{padding:13px}.cloud-hero{padding:18px}.cloud-file-table td:nth-child(2),.cloud-file-table th:nth-child(2){display:none}.cloud-actions{justify-content:flex-start}}
</style>
<div class="cloud-page">
  <section class="cloud-hero">
    <div class="cloud-hero-top">
      <div>
        <div class="cloud-kicker"><i class="fa-solid fa-cloud me-2"></i>HYPER CLOUD</div>
        <h2>Личное облако сервера</h2>
        <div class="cloud-path"><?= hh_cloud_breadcrumb($rel) ?></div>
      </div>
      <div class="cloud-stats">
        <div class="cloud-stat"><span>Файлы здесь</span><b><?= (int)$fileCount ?></b><small><?= e(human_bytes($folderBytes)) ?></small></div>
        <div class="cloud-stat"><span>Папки здесь</span><b><?= (int)$folderCount ?></b><small>/<?= e($rel) ?></small></div>
        <div class="cloud-stat"><span>Свободно на диске</span><b><?= e(human_bytes($diskFree)) ?></b><small>из <?= e(human_bytes($diskTotal)) ?></small></div>
      </div>
    </div>
    <?php $used = max(0.0, $diskTotal - $diskFree); $pct = $diskTotal > 0 ? min(100, ($used / $diskTotal) * 100) : 0; ?>
    <div class="cloud-progress"><i style="width:<?= e((string)round($pct,1)) ?>%"></i></div>
  </section>

  <div class="cloud-grid">
    <aside class="cloud-side">
      <section class="cloud-card">
        <h3 class="h5 mb-3"><i class="fa-solid fa-cloud-arrow-up me-2 text-primary"></i>Загрузить</h3>
        <form method="post" enctype="multipart/form-data">
          <?= csrf_field() ?><input type="hidden" name="action" value="cloud_upload"><input type="hidden" name="path" value="<?= e($rel) ?>">
          <label class="cloud-drop"><i class="fa-solid fa-arrow-up-from-bracket"></i><b class="mt-2">Выберите файлы</b><span>Можно несколько сразу: ZIP, RAR, фото, документы и любые другие файлы</span><input class="form-control mt-3" type="file" name="files[]" multiple required></label>
          <button class="btn btn-primary w-100 mt-3"><i class="fa-solid fa-cloud-arrow-up me-2"></i>Загрузить в облако</button>
        </form>
      </section>
      <section class="cloud-card">
        <h3 class="h5 mb-3"><i class="fa-solid fa-folder-plus me-2 text-warning"></i>Новая папка</h3>
        <form method="post" class="vstack gap-2"><?= csrf_field() ?><input type="hidden" name="action" value="cloud_mkdir"><input type="hidden" name="path" value="<?= e($rel) ?>"><input class="form-control" name="name" placeholder="Например: Документы" maxlength="180" required><button class="btn btn-soft"><i class="fa-solid fa-plus me-2"></i>Создать папку</button></form>
      </section>
      <section class="cloud-card">
        <div class="cloud-meta">Физическое хранилище</div><code><?= e($root) ?></code>
        <div class="cloud-meta mt-3">Архивы можно открыть прямо в панели и посмотреть список файлов внутри без распаковки.</div>
      </section>
    </aside>

    <section class="cloud-card">
      <div class="d-flex align-items-center justify-content-between gap-2 flex-wrap mb-2">
        <h3 class="h5 m-0"><i class="fa-solid fa-folder-open me-2"></i><?= $rel === '' ? 'Моё облако' : e(basename($rel)) ?></h3>
        <?php if ($rel !== ''): $up = dirname($rel); if ($up === '.') $up = ''; ?><a class="btn btn-sm btn-soft cloud-up" href="<?= e(hh_cloud_url(['path'=>$up])) ?>"><i class="fa-solid fa-arrow-left"></i>Назад</a><?php endif; ?>
      </div>
      <div class="table-responsive">
        <table class="table table-dark-soft cloud-file-table align-middle mb-0">
          <thead><tr><th>Имя</th><th>Размер</th><th>Изменён</th><th class="text-end">Действия</th></tr></thead>
          <tbody>
          <?php foreach ($items as $name): $p = $dir . '/' . $name; $childRel = trim($rel . '/' . $name, '/'); $isDir = is_dir($p); ?>
            <tr>
              <td><div class="cloud-name"><i class="fa-solid <?= e(hh_cloud_item_icon($p)) ?>"></i><?php if($isDir): ?><a href="<?= e(hh_cloud_url(['path'=>$childRel])) ?>"><?= e($name) ?></a><?php else: ?><a href="<?= e(hh_cloud_url(['path'=>$rel,'preview'=>$childRel])) ?>"><?= e($name) ?></a><?php endif; ?></div></td>
              <td class="cloud-size"><?= $isDir ? 'папка' : e(human_bytes((float)(filesize($p) ?: 0))) ?></td>
              <td class="cloud-meta"><?= e(date('d.m.Y H:i', filemtime($p) ?: time())) ?></td>
              <td><div class="cloud-actions">
                <?php if(!$isDir): ?><a class="btn btn-sm btn-soft" title="Открыть" href="<?= e(hh_cloud_url(['path'=>$rel,'preview'=>$childRel])) ?>"><i class="fa-solid fa-eye"></i></a><a class="btn btn-sm btn-soft" title="Скачать" href="<?= e(hh_cloud_url(['cloud_action'=>'download','path'=>$childRel])) ?>"><i class="fa-solid fa-download"></i></a><?php endif; ?>
                <button class="btn btn-sm btn-soft" type="button" data-bs-toggle="collapse" data-bs-target="#rename-<?= md5($childRel) ?>" title="Переименовать"><i class="fa-solid fa-pen"></i></button>
                <form method="post" onsubmit="return confirm('Удалить <?= e(addslashes($name)) ?>?')"><?= csrf_field() ?><input type="hidden" name="action" value="cloud_delete"><input type="hidden" name="path" value="<?= e($rel) ?>"><input type="hidden" name="target" value="<?= e($childRel) ?>"><button class="btn btn-sm btn-outline-danger" title="Удалить"><i class="fa-solid fa-trash"></i></button></form>
              </div><div class="collapse mt-2" id="rename-<?= md5($childRel) ?>"><form method="post" class="cloud-rename"><?= csrf_field() ?><input type="hidden" name="action" value="cloud_rename"><input type="hidden" name="path" value="<?= e($rel) ?>"><input type="hidden" name="target" value="<?= e($childRel) ?>"><input class="form-control form-control-sm" name="new_name" value="<?= e($name) ?>" required><button class="btn btn-sm btn-primary"><i class="fa-solid fa-check"></i></button></form></div></td>
            </tr>
          <?php endforeach; ?>
          <?php if(!$items): ?><tr><td colspan="4"><div class="cloud-empty"><i class="fa-regular fa-folder-open fa-2x mb-3"></i><div>Папка пустая</div><small>Загрузите файлы или создайте папку</small></div></td></tr><?php endif; ?>
          </tbody>
        </table>
      </div>

      <?php if($previewPath): $mime = hh_cloud_mime($previewPath); ?>
      <div class="cloud-preview">
        <div class="cloud-preview-head"><div><div class="cloud-meta">Просмотр файла</div><b><?= e(basename($previewPath)) ?></b> <span class="cloud-meta">· <?= e(human_bytes((float)(filesize($previewPath) ?: 0))) ?></span></div><a class="btn btn-sm btn-primary" href="<?= e(hh_cloud_url(['cloud_action'=>'download','path'=>$previewRel])) ?>"><i class="fa-solid fa-download me-2"></i>Скачать</a></div>
        <div class="cloud-preview-body">
          <?php if(hh_cloud_is_archive($previewPath)): $archive = hh_cloud_archive_entries($previewPath); ?>
            <div class="p-3 border-bottom border-secondary-subtle"><b><i class="fa-solid fa-box-archive me-2"></i>Содержимое архива</b><span class="cloud-meta ms-2"><?= e((string)($archive['engine'] ?? '')) ?></span></div>
            <?php if(!empty($archive['ok'])): ?><div class="cloud-archive table-responsive"><table class="table table-dark-soft table-sm"><thead><tr><th>Файл внутри архива</th><th>Размер</th><th>Сжат</th><th>Дата</th></tr></thead><tbody><?php foreach($archive['entries'] as $entry): ?><tr><td><i class="fa-regular fa-file me-2"></i><?= e((string)$entry['name']) ?></td><td><?= e(human_bytes((float)($entry['size']??0))) ?></td><td><?= e(human_bytes((float)($entry['packed']??0))) ?></td><td><small><?= e((string)($entry['modified']??'—')) ?></small></td></tr><?php endforeach; ?></tbody></table></div><?php if(!empty($archive['truncated'])): ?><div class="p-3 cloud-meta">Показаны первые 1000 элементов.</div><?php endif; ?><?php else: ?><div class="p-4 text-danger"><?= e((string)($archive['error'] ?? 'Архив не удалось прочитать')) ?></div><?php endif; ?>
          <?php elseif(str_starts_with($mime,'image/')): ?><img class="cloud-preview-img" src="<?= e(hh_cloud_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>" alt="preview">
          <?php elseif($mime === 'application/pdf'): ?><iframe class="cloud-preview-frame" src="<?= e(hh_cloud_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></iframe>
          <?php elseif(str_starts_with($mime,'video/')): ?><video class="w-100" style="max-height:70vh" controls preload="metadata" src="<?= e(hh_cloud_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></video>
          <?php elseif(str_starts_with($mime,'audio/')): ?><div class="p-4"><audio class="w-100" controls preload="metadata" src="<?= e(hh_cloud_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></audio></div>
          <?php elseif(hh_cloud_is_text($previewPath) && (filesize($previewPath) ?: 0) <= 2*1024*1024): $txt=@file_get_contents($previewPath, false, null, 0, 2*1024*1024); ?><pre><?= e(is_string($txt)?$txt:'') ?></pre>
          <?php else: ?><div class="p-5 text-center"><i class="fa-solid fa-file-arrow-down fa-3x text-primary mb-3"></i><h4>Предпросмотр для этого типа не поддерживается</h4><p class="cloud-meta">Файл можно скачать без изменений.</p><a class="btn btn-primary" href="<?= e(hh_cloud_url(['cloud_action'=>'download','path'=>$previewRel])) ?>">Скачать файл</a></div><?php endif; ?>
        </div>
      </div>
      <?php endif; ?>
    </section>
  </div>
</div>
<?php
}
