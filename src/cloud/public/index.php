<?php
declare(strict_types=1);

/**
 * HYPER CLOUD v108 — hardened standalone multi-user cloud on cloud.hyper-host.pw.
 * Panel administrators can sign in with panel credentials; cloud registrations stay cloud-only.
 */
require __DIR__ . '/../app/bootstrap.php';

$GLOBALS['HC_SPACE'] = ((string)($_GET['space'] ?? $_POST['space'] ?? 'private') === 'shared') ? 'shared' : 'private';

header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: private, no-store, max-age=0');
header('Pragma: no-cache');
header('X-Robots-Tag: noindex, nofollow, noarchive');
header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()');
header("Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; script-src 'self' https://cdn.jsdelivr.net; font-src 'self' https://cdnjs.cloudflare.com data:; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; frame-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'");

function hc_csrf_field(): string
{
    return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">';
}

function hc_root(): string
{
    $user = current_user();
    if (!$user) throw new RuntimeException('Требуется авторизация');
    hc_ensure_user_root($user);
    $root = hc_root_for_user($user, hc_space());
    if (!is_dir($root)) @mkdir($root, 02770, true);
    return $root;
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
    if (hc_space() === 'shared' && !array_key_exists('space', $params)) $params['space'] = 'shared';
    if (array_key_exists('space', $params) && $params['space'] === 'private') unset($params['space']);
    return '/' . ($params ? '?' . http_build_query($params, '', '&', PHP_QUERY_RFC3986) : '');
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

function hc_mime_name(string $name): string
{
    $ext = strtolower(pathinfo(parse_url($name, PHP_URL_PATH) ?: $name, PATHINFO_EXTENSION));
    return match ($ext) {
        'html','htm' => 'text/html; charset=utf-8',
        'css' => 'text/css; charset=utf-8',
        'js','mjs','cjs' => 'application/javascript; charset=utf-8',
        'json','map' => 'application/json; charset=utf-8',
        'xml' => 'application/xml; charset=utf-8',
        'txt','md','log','csv','ini','env','conf','yml','yaml','php','phtml','py','ts','tsx','jsx','sql','sh' => 'text/plain; charset=utf-8',
        'jpg','jpeg' => 'image/jpeg', 'png' => 'image/png', 'gif' => 'image/gif', 'webp' => 'image/webp', 'svg' => 'image/svg+xml', 'ico' => 'image/x-icon',
        'pdf' => 'application/pdf', 'mp4' => 'video/mp4', 'webm' => 'video/webm', 'mov' => 'video/quicktime',
        'mp3' => 'audio/mpeg', 'ogg' => 'audio/ogg', 'wav' => 'audio/wav',
        'woff' => 'font/woff', 'woff2' => 'font/woff2', 'ttf' => 'font/ttf', 'otf' => 'font/otf',
        default => 'application/octet-stream',
    };
}

function hc_detect_site_root_rel(string $rel): string
{
    $rel = hc_clean_rel($rel);
    $dir = dirname($rel);
    if ($dir === '.') $dir = '';
    $candidate = $dir;
    while (true) {
        foreach (['index.html','index.htm'] as $idx) {
            $test = trim(($candidate !== '' ? $candidate . '/' : '') . $idx, '/');
            try {
                [,,$path] = hc_resolve($test, false);
                if (is_file($path) && !is_link($path)) return $candidate;
            } catch (Throwable) {}
        }
        if ($candidate === '') break;
        $next = dirname($candidate);
        $candidate = $next === '.' ? '' : $next;
    }
    return $dir;
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

function hc_is_html_name(string $name): bool
{
    return in_array(strtolower(pathinfo($name, PATHINFO_EXTENSION)), ['html', 'htm'], true);
}

function hc_preview_join_rel(string $baseRel, string $url, string $siteRootRel = ''): ?string
{
    $url = trim(html_entity_decode($url, ENT_QUOTES | ENT_HTML5, 'UTF-8'));
    if ($url === '' || str_starts_with($url, '#') || str_starts_with($url, '//')) return null;
    if (preg_match('~^(?:data|blob|javascript|mailto|tel|about):~i', $url)) return null;
    if (preg_match('~^[a-z][a-z0-9+.-]*:~i', $url)) return null;

    $pathOnly = parse_url($url, PHP_URL_PATH);
    if (!is_string($pathOnly) || $pathOnly === '') return null;
    $pathOnly = rawurldecode($pathOnly);
    $siteRootRel = hc_clean_rel($siteRootRel);
    $parts = str_starts_with($pathOnly, '/')
        ? ($siteRootRel !== '' ? explode('/', $siteRootRel) : [])
        : ($baseRel !== '' ? explode('/', hc_clean_rel($baseRel)) : []);
    foreach (explode('/', str_replace('\\', '/', $pathOnly)) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') {
            $rootDepth = $siteRootRel !== '' ? count(explode('/', $siteRootRel)) : 0;
            if (count($parts) <= $rootDepth) return null;
            array_pop($parts);
            continue;
        }
        if (preg_match('/[\x00-\x1F\x7F]/u', $part)) return null;
        $parts[] = $part;
    }
    if (!$parts) return '';
    try { return hc_clean_rel(implode('/', $parts)); } catch (Throwable) { return null; }
}

function hc_preview_url(string $baseRel, string $url, bool $navigation = false, string $siteRootRel = ''): string
{
    $resolved = hc_preview_join_rel($baseRel, $url, $siteRootRel);
    if ($resolved === null) return $url;
    try {
        [,,$candidate] = hc_resolve($resolved, false);
        if (is_dir($candidate) && !is_link($candidate)) {
            foreach (['index.html','index.htm'] as $index) {
                $try = rtrim($resolved, '/') . ($resolved !== '' ? '/' : '') . $index;
                [,,$tryPath] = hc_resolve($try, false);
                if (is_file($tryPath) && !is_link($tryPath)) { $resolved = $try; break; }
            }
        }
    } catch (Throwable) {}
    $isHtml = hc_is_html_name($resolved);
    $params = ['cloud_action' => ($navigation && $isHtml) ? 'html_preview' : 'html_asset', 'path' => $resolved];
    if ($siteRootRel !== '') $params['site_root'] = $siteRootRel;
    return hc_url($params);
}

function hc_preview_srcset(string $baseRel, string $value, string $siteRootRel = ''): string
{
    $parts = [];
    foreach (explode(',', $value) as $item) {
        $item = trim($item);
        if ($item === '') continue;
        if (preg_match('/^(\S+)(\s+.+)?$/', $item, $m)) {
            $parts[] = hc_preview_url($baseRel, $m[1], false, $siteRootRel) . ($m[2] ?? '');
        } else $parts[] = $item;
    }
    return implode(', ', $parts);
}

function hc_preview_css_rewrite(string $css, string $baseRel, string $siteRootRel = ''): string
{
    $css = preg_replace_callback('~url\(\s*([\'\"]?)(.*?)\1\s*\)~i', static function(array $m) use ($baseRel, $siteRootRel): string {
        $u = trim((string)$m[2]);
        if ($u === '' || str_starts_with($u, '#')) return $m[0];
        $rewritten = hc_preview_url($baseRel, $u, false, $siteRootRel);
        return 'url("' . str_replace(['\\','"'], ['\\\\','\\"'], $rewritten) . '")';
    }, $css) ?? $css;
    $css = preg_replace_callback('~@import\s+([\'\"])(.*?)\1~i', static function(array $m) use ($baseRel, $siteRootRel): string {
        return '@import "' . str_replace(['\\','"'], ['\\\\','\\"'], hc_preview_url($baseRel, (string)$m[2], false, $siteRootRel)) . '"';
    }, $css) ?? $css;
    return $css;
}

function hc_preview_js_rewrite(string $js, string $baseRel, string $siteRootRel = ''): string
{
    // Covers common ES-module imports/exports and dynamic import(). Normal scripts remain untouched.
    $resolver = static fn(string $u): string => hc_preview_url($baseRel, $u, false, $siteRootRel);
    $js = preg_replace_callback('~(\b(?:import|export)\s+(?:[^\'\";]+?\s+from\s+)?)([\'\"])(\.?\.?/[^\'\"]+|/[^\'\"]+)\2~', static function(array $m) use ($resolver): string {
        return $m[1] . $m[2] . $resolver((string)$m[3]) . $m[2];
    }, $js) ?? $js;
    $js = preg_replace_callback('~(\bimport\s*\(\s*)([\'\"])(\.?\.?/[^\'\"]+|/[^\'\"]+)\2(\s*\))~', static function(array $m) use ($resolver): string {
        return $m[1] . $m[2] . $resolver((string)$m[3]) . $m[2] . $m[4];
    }, $js) ?? $js;
    $js = preg_replace_callback('~(\bfetch\s*\(\s*)([\'"])(\.?\.?/[^\'"]+|/[^\'"]+)\2~', static function(array $m) use ($resolver): string {
        return $m[1] . $m[2] . $resolver((string)$m[3]) . $m[2];
    }, $js) ?? $js;
    return $js;
}

function hc_html_rewrite_document(string $html, callable $assetUrl, callable $navUrl, callable $srcsetRewrite, callable $cssRewrite): string
{
    $domRewritten = false;
    if (class_exists('DOMDocument')) {
        $previous = libxml_use_internal_errors(true);
        $dom = new DOMDocument('1.0', 'UTF-8');
        $loaded = @$dom->loadHTML('<?xml encoding="UTF-8">' . $html, LIBXML_NONET | LIBXML_COMPACT);
        if ($loaded) {
            $assetAttrs = [
                'img'=>['src','srcset'], 'script'=>['src'], 'link'=>['href'], 'source'=>['src','srcset'],
                'video'=>['src','poster'], 'audio'=>['src'], 'track'=>['src'], 'embed'=>['src'], 'input'=>['src']
            ];
            foreach ($assetAttrs as $tag=>$attrs) {
                foreach ($dom->getElementsByTagName($tag) as $node) {
                    foreach ($attrs as $attr) {
                        if (!$node->hasAttribute($attr)) continue;
                        $value = $node->getAttribute($attr);
                        $node->setAttribute($attr, $attr === 'srcset' ? $srcsetRewrite($value) : $assetUrl($value));
                    }
                }
            }
            foreach ($dom->getElementsByTagName('a') as $node) {
                if ($node->hasAttribute('href')) $node->setAttribute('href', $navUrl($node->getAttribute('href')));
            }
            foreach ($dom->getElementsByTagName('iframe') as $node) {
                if ($node->hasAttribute('src')) $node->setAttribute('src', $navUrl($node->getAttribute('src')));
            }
            foreach ($dom->getElementsByTagName('form') as $node) {
                if ($node->hasAttribute('action')) $node->setAttribute('action', '#');
            }
            foreach ($dom->getElementsByTagName('*') as $node) {
                if ($node->hasAttribute('style')) $node->setAttribute('style', $cssRewrite($node->getAttribute('style')));
            }
            foreach ($dom->getElementsByTagName('style') as $node) $node->nodeValue = $cssRewrite((string)$node->textContent);
            // Existing <base> can break the protected virtual paths, so remove it.
            $bases = [];
            foreach ($dom->getElementsByTagName('base') as $base) $bases[] = $base;
            foreach ($bases as $base) $base->parentNode?->removeChild($base);
            $out = $dom->saveHTML();
            if (is_string($out) && $out !== '') {
                $html = preg_replace('/^<\?xml[^>]*>\s*/i', '', $out) ?? $out;
                $domRewritten = true;
            }
        }
        libxml_clear_errors();
        libxml_use_internal_errors($previous);
    }

    if (!$domRewritten) {
        $html = preg_replace_callback('~(<(?:img|script|source|video|audio|track|embed|input)\b[^>]*?\s(?:src|poster)\s*=\s*)([\'\"])(.*?)\2~is', static fn(array $m): string => $m[1].$m[2].e($assetUrl(html_entity_decode((string)$m[3],ENT_QUOTES|ENT_HTML5,'UTF-8'))).$m[2], $html) ?? $html;
        $html = preg_replace_callback('~(<link\b[^>]*?\shref\s*=\s*)([\'\"])(.*?)\2~is', static fn(array $m): string => $m[1].$m[2].e($assetUrl(html_entity_decode((string)$m[3],ENT_QUOTES|ENT_HTML5,'UTF-8'))).$m[2], $html) ?? $html;
        $html = preg_replace_callback('~(<a\b[^>]*?\shref\s*=\s*)([\'\"])(.*?)\2~is', static fn(array $m): string => $m[1].$m[2].e($navUrl(html_entity_decode((string)$m[3],ENT_QUOTES|ENT_HTML5,'UTF-8'))).$m[2], $html) ?? $html;
        $html = preg_replace_callback('~(<iframe\b[^>]*?\ssrc\s*=\s*)([\'\"])(.*?)\2~is', static fn(array $m): string => $m[1].$m[2].e($navUrl(html_entity_decode((string)$m[3],ENT_QUOTES|ENT_HTML5,'UTF-8'))).$m[2], $html) ?? $html;
        $html = preg_replace_callback('~(\ssrcset\s*=\s*)([\'\"])(.*?)\2~is', static fn(array $m): string => $m[1].$m[2].e($srcsetRewrite(html_entity_decode((string)$m[3],ENT_QUOTES|ENT_HTML5,'UTF-8'))).$m[2], $html) ?? $html;
        $html = preg_replace_callback('~(<style\b[^>]*>)(.*?)(</style>)~is', static fn(array $m): string => $m[1].$cssRewrite((string)$m[2]).$m[3], $html) ?? $html;
        $html = preg_replace_callback('~(\sstyle\s*=\s*)([\'\"])(.*?)\2~is', static fn(array $m): string => $m[1].$m[2].e($cssRewrite(html_entity_decode((string)$m[3],ENT_QUOTES|ENT_HTML5,'UTF-8'))).$m[2], $html) ?? $html;
        $html = preg_replace('~<base\b[^>]*>~i', '', $html) ?? $html;
    }
    return $html;
}

function hc_html_preview_output(string $rel, string $path, string $siteRootRel = ''): never
{
    if (!is_file($path) || is_link($path) || !hc_is_html_name($path)) throw new RuntimeException('HTML-файл недоступен');
    $html = @file_get_contents($path);
    if (!is_string($html)) throw new RuntimeException('Не удалось прочитать HTML-файл');
    $siteRootRel = $siteRootRel !== '' ? hc_clean_rel($siteRootRel) : hc_detect_site_root_rel($rel);
    $baseRel = dirname($rel) === '.' ? '' : dirname($rel);
    $html = hc_html_rewrite_document(
        $html,
        static fn(string $u): string => hc_preview_url($baseRel,$u,false,$siteRootRel),
        static fn(string $u): string => hc_preview_url($baseRel,$u,true,$siteRootRel),
        static fn(string $v): string => hc_preview_srcset($baseRel,$v,$siteRootRel),
        static fn(string $css): string => hc_preview_css_rewrite($css,$baseRel,$siteRootRel)
    );

    while (ob_get_level() > 0) @ob_end_clean();
    header_remove('X-Frame-Options');
    header('X-Frame-Options: SAMEORIGIN');
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: private, no-store, max-age=0');
    header('X-Robots-Tag: noindex, nofollow, noarchive');
    header("Content-Security-Policy: sandbox allow-scripts allow-forms allow-modals allow-popups allow-downloads; default-src 'self' data: blob: https:; script-src 'self' 'unsafe-inline' 'unsafe-eval' https: blob:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: blob: https:; font-src 'self' data: https:; media-src 'self' blob: data: https:; connect-src 'self' https: wss:; frame-src 'self' https:; object-src 'none'; base-uri 'none'");
    echo $html;
    exit;
}

function hc_html_asset_output(string $rel, string $path, string $siteRootRel = ''): never
{
    if (!is_file($path) || is_link($path) || !is_readable($path)) throw new RuntimeException('Ресурс недоступен');
    $siteRootRel = $siteRootRel !== '' ? hc_clean_rel($siteRootRel) : hc_detect_site_root_rel($rel);
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    if ($ext === 'css') {
        $css = @file_get_contents($path);
        if (!is_string($css)) throw new RuntimeException('CSS недоступен');
        $baseRel = dirname($rel) === '.' ? '' : dirname($rel);
        while (ob_get_level() > 0) @ob_end_clean();
        header('Content-Type: text/css; charset=utf-8'); header('Cache-Control: private, no-store, max-age=0'); header('X-Content-Type-Options: nosniff');
        echo hc_preview_css_rewrite($css,$baseRel,$siteRootRel); exit;
    }
    if (in_array($ext,['js','mjs','cjs'],true)) {
        $js = @file_get_contents($path);
        if (!is_string($js)) throw new RuntimeException('JS недоступен');
        $baseRel = dirname($rel) === '.' ? '' : dirname($rel);
        while (ob_get_level() > 0) @ob_end_clean();
        header('Content-Type: application/javascript; charset=utf-8'); header('Cache-Control: private, no-store, max-age=0'); header('X-Content-Type-Options: nosniff');
        echo hc_preview_js_rewrite($js,$baseRel,$siteRootRel); exit;
    }
    hc_stream_file($path, true);
}

function hc_archive_preview_join(string $baseEntryDir, string $url, string $siteRoot = ''): ?string
{
    $url=trim(html_entity_decode($url,ENT_QUOTES|ENT_HTML5,'UTF-8'));
    if ($url==='' || str_starts_with($url,'#') || str_starts_with($url,'//')) return null;
    if (preg_match('~^(?:data|blob|javascript|mailto|tel|about):~i',$url) || preg_match('~^[a-z][a-z0-9+.-]*:~i',$url)) return null;
    $pathOnly=parse_url($url,PHP_URL_PATH);
    if (!is_string($pathOnly) || $pathOnly==='') return null;
    $pathOnly=rawurldecode($pathOnly); $siteRoot=$siteRoot!==''?hc_archive_entry_clean($siteRoot):'';
    $parts=str_starts_with($pathOnly,'/') ? ($siteRoot!==''?explode('/',$siteRoot):[]) : ($baseEntryDir!==''?explode('/',hc_archive_entry_clean($baseEntryDir)):[]);
    foreach (explode('/',str_replace('\\','/',$pathOnly)) as $part) {
        if ($part==='' || $part==='.') continue;
        if ($part==='..') { $rootDepth=$siteRoot!==''?count(explode('/',$siteRoot)):0; if (count($parts)<=$rootDepth) return null; array_pop($parts); continue; }
        if (preg_match('/[\x00-\x1F\x7F]/u',$part)) return null;
        $parts[]=$part;
    }
    if (!$parts) return '';
    try { return hc_archive_entry_clean(implode('/',$parts)); } catch(Throwable) { return null; }
}

function hc_archive_detect_site_root(string $archivePath, string $entry): string
{
    $entry=hc_archive_entry_clean($entry); $dir=dirname($entry); if ($dir==='.') $dir='';
    $list=hc_archive_entries($archivePath,0); $set=[];
    if (!empty($list['ok'])) foreach ($list['entries'] as $row) { try { $n=hc_archive_entry_clean((string)($row['name']??'')); $set[$n]=true; } catch(Throwable) {} }
    $candidate=$dir;
    while (true) {
        foreach (['index.html','index.htm'] as $idx) { $n=trim(($candidate!==''?$candidate.'/':'').$idx,'/'); if (isset($set[$n])) return $candidate; }
        if ($candidate==='') break; $next=dirname($candidate); $candidate=$next==='.'?'':$next;
    }
    return $dir;
}

function hc_archive_preview_url(string $archiveRel, string $baseEntryDir, string $url, bool $navigation=false, string $siteRoot=''): string
{
    $resolved=hc_archive_preview_join($baseEntryDir,$url,$siteRoot);
    if ($resolved===null) return $url;
    $isHtml=hc_is_html_name($resolved);
    $params=['cloud_action'=>($navigation && $isHtml)?'archive_html_preview':'archive_html_asset','path'=>$archiveRel,'entry'=>$resolved];
    if ($siteRoot!=='') $params['site_root']=$siteRoot;
    return hc_url($params);
}

function hc_archive_preview_srcset(string $archiveRel,string $baseEntryDir,string $value,string $siteRoot=''): string
{
    $parts=[]; foreach(explode(',',$value) as $item) { $item=trim($item); if($item==='')continue; if(preg_match('/^(\S+)(\s+.+)?$/',$item,$m)) $parts[]=hc_archive_preview_url($archiveRel,$baseEntryDir,$m[1],false,$siteRoot).($m[2]??''); else $parts[]=$item; }
    return implode(', ',$parts);
}

function hc_archive_preview_css_rewrite(string $css,string $archiveRel,string $baseEntryDir,string $siteRoot=''): string
{
    $css=preg_replace_callback('~url\(\s*([\'\"]?)(.*?)\1\s*\)~i',static function(array $m)use($archiveRel,$baseEntryDir,$siteRoot):string{$u=trim((string)$m[2]);if($u===''||str_starts_with($u,'#'))return $m[0];$r=hc_archive_preview_url($archiveRel,$baseEntryDir,$u,false,$siteRoot);return 'url("'.str_replace(['\\','"'],['\\\\','\\"'],$r).'")';},$css)??$css;
    $css=preg_replace_callback('~@import\s+([\'\"])(.*?)\1~i',static fn(array $m):string=>'@import "'.str_replace(['\\','"'],['\\\\','\\"'],hc_archive_preview_url($archiveRel,$baseEntryDir,(string)$m[2],false,$siteRoot)).'"',$css)??$css;
    return $css;
}

function hc_archive_preview_js_rewrite(string $js,string $archiveRel,string $baseEntryDir,string $siteRoot=''): string
{
    $resolver=static fn(string $u):string=>hc_archive_preview_url($archiveRel,$baseEntryDir,$u,false,$siteRoot);
    $js=preg_replace_callback('~(\b(?:import|export)\s+(?:[^\'\";]+?\s+from\s+)?)([\'\"])(\.?\.?/[^\'\"]+|/[^\'\"]+)\2~',static fn(array $m):string=>$m[1].$m[2].$resolver((string)$m[3]).$m[2],$js)??$js;
    $js=preg_replace_callback('~(\bimport\s*\(\s*)([\'\"])(\.?\.?/[^\'\"]+|/[^\'\"]+)\2(\s*\))~',static fn(array $m):string=>$m[1].$m[2].$resolver((string)$m[3]).$m[2].$m[4],$js)??$js;
    $js=preg_replace_callback('~(\bfetch\s*\(\s*)([\'"])(\.?\.?/[^\'"]+|/[^\'"]+)\2~',static fn(array $m):string=>$m[1].$m[2].$resolver((string)$m[3]).$m[2],$js)??$js;
    return $js;
}

function hc_archive_html_preview_output(string $archiveRel,string $archivePath,string $entry,string $siteRoot=''): never
{
    $entry=hc_archive_entry_clean($entry); if(!hc_is_html_name($entry)) throw new RuntimeException('Это не HTML-файл');
    $data=hc_archive_entry_bytes($archivePath,$entry,0); $html=(string)$data['content'];
    $siteRoot=$siteRoot!==''?hc_archive_entry_clean($siteRoot):hc_archive_detect_site_root($archivePath,$entry);
    $base=dirname($entry); if($base==='.')$base='';
    $html=hc_html_rewrite_document($html,
        static fn(string $u):string=>hc_archive_preview_url($archiveRel,$base,$u,false,$siteRoot),
        static fn(string $u):string=>hc_archive_preview_url($archiveRel,$base,$u,true,$siteRoot),
        static fn(string $v):string=>hc_archive_preview_srcset($archiveRel,$base,$v,$siteRoot),
        static fn(string $css):string=>hc_archive_preview_css_rewrite($css,$archiveRel,$base,$siteRoot));
    while(ob_get_level()>0)@ob_end_clean(); header_remove('X-Frame-Options'); header('X-Frame-Options: SAMEORIGIN'); header('Content-Type: text/html; charset=utf-8'); header('Cache-Control: private, no-store, max-age=0'); header('X-Robots-Tag: noindex, nofollow, noarchive');
    header("Content-Security-Policy: sandbox allow-scripts allow-forms allow-modals allow-popups allow-downloads; default-src 'self' data: blob: https:; script-src 'self' 'unsafe-inline' 'unsafe-eval' https: blob:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: blob: https:; font-src 'self' data: https:; media-src 'self' blob: data: https:; connect-src 'self' https: wss:; frame-src 'self' https:; object-src 'none'; base-uri 'none'"); echo $html; exit;
}

function hc_archive_html_asset_output(string $archiveRel,string $archivePath,string $entry,string $siteRoot=''): never
{
    $entry=hc_archive_entry_clean($entry); $data=hc_archive_entry_bytes($archivePath,$entry,0); $content=(string)$data['content']; $siteRoot=$siteRoot!==''?hc_archive_entry_clean($siteRoot):''; $base=dirname($entry); if($base==='.')$base=''; $ext=strtolower(pathinfo($entry,PATHINFO_EXTENSION));
    if($ext==='css')$content=hc_archive_preview_css_rewrite($content,$archiveRel,$base,$siteRoot);
    elseif(in_array($ext,['js','mjs','cjs'],true))$content=hc_archive_preview_js_rewrite($content,$archiveRel,$base,$siteRoot);
    while(ob_get_level()>0)@ob_end_clean(); header('Content-Type: '.hc_mime_name($entry)); header('Content-Length: '.strlen($content)); header('Cache-Control: private, no-store, max-age=0'); header('X-Content-Type-Options: nosniff'); echo $content; exit;
}

function hc_archive_entries(string $path, int $limit = 1000): array
{
    $entries = [];
    if (str_ends_with(strtolower($path), '.zip') && class_exists('ZipArchive')) {
        $zip = new ZipArchive();
        if ($zip->open($path) === true) {
            $count = $limit > 0 ? min($zip->numFiles, $limit) : $zip->numFiles;
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
            $truncated = $limit > 0 && $zip->numFiles > $limit;
            $zip->close();
            return ['ok'=>true,'entries'=>$entries,'truncated'=>$truncated,'engine'=>'ZipArchive'];
        }
    }

    if (str_ends_with(strtolower($path), '.zip') && is_executable('/usr/bin/unzip')) {
        $out = []; $code = 0;
        exec('/usr/bin/unzip -Z -1 '.escapeshellarg($path).' 2>/dev/null', $out, $code);
        if ($code === 0) {
            foreach ($out as $raw) {
                if ($limit > 0 && count($entries) >= $limit) break;
                $raw = rtrim((string)$raw);
                if ($raw !== '') $entries[] = ['name'=>$raw,'size'=>0,'packed'=>0,'modified'=>'—'];
            }
            if ($entries) return ['ok'=>true,'entries'=>$entries,'truncated'=>$limit > 0 && count($out)>$limit,'engine'=>'unzip'];
        }
    }

    $commands = [];
    if (is_executable('/usr/bin/7z')) $commands[] = ['/usr/bin/7z','l','-slt',$path];
    if (is_executable('/usr/bin/7zz')) $commands[] = ['/usr/bin/7zz','l','-slt',$path];
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
                            if ($limit > 0 && count($entries) >= $limit) break;
                        }
                    }
                    $current = [];
                    continue;
                }
                if (preg_match('/^([^=]+) = (.*)$/', $raw, $m)) $current[trim($m[1])] = $m[2];
            }
            if (($limit <= 0 || count($entries) < $limit) && !empty($current['Path'])) {
                $n=(string)$current['Path'];
                if ($n!==$path && $n!==basename($path)) $entries[]=['name'=>$n,'size'=>(int)($current['Size']??0),'packed'=>(int)($current['Packed Size']??0),'modified'=>(string)($current['Modified']??'—')];
            }
            if ($entries) return ['ok'=>true,'entries'=>$entries,'truncated'=>$limit > 0 && count($entries)>=$limit,'engine'=>basename($cmd[0])];
        } else {
            foreach ($out as $raw) {
                if ($limit > 0 && count($entries) >= $limit) break;
                $raw = trim((string)$raw);
                if ($raw !== '') $entries[] = ['name'=>$raw,'size'=>0,'packed'=>0,'modified'=>'—'];
            }
            if ($entries) return ['ok'=>true,'entries'=>$entries,'truncated'=>$limit > 0 && count($entries)>=$limit,'engine'=>'bsdtar'];
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

function hc_archive_entry_lookup(string $archivePath, string $entry): array
{
    $canonical = hc_archive_entry_clean($entry);
    if (str_ends_with(strtolower($archivePath), '.zip') && class_exists('ZipArchive')) {
        $zip = new ZipArchive();
        if ($zip->open($archivePath) === true) {
            for ($i=0; $i<$zip->numFiles; $i++) {
                $st = $zip->statIndex($i);
                if (!is_array($st)) continue;
                $raw = (string)($st['name'] ?? '');
                if ($raw === '' || str_ends_with($raw,'/')) continue;
                try { $clean = hc_archive_entry_clean($raw); } catch (Throwable) { continue; }
                if ($clean === $canonical) {
                    $result=['canonical'=>$canonical,'actual'=>$raw,'size'=>(int)($st['size']??0),'index'=>$i];
                    $zip->close(); return $result;
                }
            }
            $zip->close();
        }
    }
    $list = hc_archive_entries($archivePath, 0);
    if (!empty($list['ok'])) {
        foreach ($list['entries'] as $row) {
            $raw=(string)($row['name']??'');
            if ($raw==='' || str_ends_with($raw,'/')) continue;
            try { $clean=hc_archive_entry_clean($raw); } catch (Throwable) { continue; }
            if ($clean===$canonical) return ['canonical'=>$canonical,'actual'=>$raw,'size'=>(int)($row['size']??0),'index'=>null];
        }
    }
    throw new RuntimeException('Файл внутри архива не найден');
}

function hc_archive_capture_command(string $command, int $limit = 0): array
{
    if (!function_exists('proc_open')) {
        $tmp=tempnam(sys_get_temp_dir(),'hc-cap-'); if($tmp===false)return ['ok'=>false,'data'=>''];
        exec($command.' > '.escapeshellarg($tmp).' 2>/dev/null',$ignore,$code);
        $data=@file_get_contents($tmp); @unlink($tmp); return ['ok'=>$code===0,'data'=>is_string($data)?$data:''];
    }
    $spec=[0=>['pipe','r'],1=>['pipe','w'],2=>['file','/dev/null','a']];$proc=@proc_open($command,$spec,$pipes);if(!is_resource($proc))return ['ok'=>false,'data'=>''];
    fclose($pipes[0]);$data=$limit>0?stream_get_contents($pipes[1],$limit+1):stream_get_contents($pipes[1]);fclose($pipes[1]);$code=proc_close($proc);
    return ['ok'=>$code===0,'data'=>is_string($data)?$data:''];
}

function hc_archive_entry_bytes(string $archivePath, string $entry, int $limit = 0): array
{
    $found=hc_archive_entry_lookup($archivePath,$entry);
    $canonical=(string)$found['canonical']; $actual=(string)$found['actual'];
    $knownSize=(int)($found['size']??0);

    if (str_ends_with(strtolower($archivePath),'.zip') && class_exists('ZipArchive')) {
        $zip=new ZipArchive();
        if ($zip->open($archivePath)===true) {
            $stream=$zip->getStream($actual);
            if (is_resource($stream)) {
                $data = $limit > 0 ? stream_get_contents($stream, $limit + 1) : stream_get_contents($stream);
                fclose($stream); $zip->close();
                if (!is_string($data)) $data='';
                if ($limit > 0 && strlen($data)>$limit) throw new RuntimeException('Не удалось полностью прочитать файл');
                return ['content'=>$data,'entry'=>$canonical,'actual'=>$actual,'size'=>strlen($data),'writable'=>hc_archive_writer($archivePath)!==''];
            }
            $idx=$found['index'];
            if (is_int($idx)) {
                $data=$limit>0?$zip->getFromIndex($idx,$limit+1):$zip->getFromIndex($idx); $zip->close();
                if (is_string($data)) {
                    if ($limit>0 && strlen($data)>$limit) throw new RuntimeException('Не удалось полностью прочитать файл');
                    return ['content'=>$data,'entry'=>$canonical,'actual'=>$actual,'size'=>strlen($data),'writable'=>hc_archive_writer($archivePath)!==''];
                }
            } else $zip->close();
        }
    }

    $result=['ok'=>false,'data'=>''];
    if (str_ends_with(strtolower($archivePath),'.zip') && is_executable('/usr/bin/unzip')) {
        $cmd='/usr/bin/unzip -p '.escapeshellarg($archivePath).' '.escapeshellarg($actual);
        $result=hc_archive_capture_command($cmd,$limit);
    }
    if (!$result['ok'] && is_executable('/usr/bin/7z')) {
        $cmd='/usr/bin/7z x -so -bd -y '.escapeshellarg($archivePath).' '.escapeshellarg($actual);
        $result=hc_archive_capture_command($cmd,$limit);
    }
    if (!$result['ok'] && is_executable('/usr/bin/7zz')) {
        $cmd='/usr/bin/7zz x -so -bd -y '.escapeshellarg($archivePath).' '.escapeshellarg($actual);
        $result=hc_archive_capture_command($cmd,$limit);
    }
    if (!$result['ok'] && is_executable('/usr/bin/bsdtar')) {
        $cmd='/usr/bin/bsdtar -xOf '.escapeshellarg($archivePath).' '.escapeshellarg($actual);
        $result=hc_archive_capture_command($cmd,$limit);
    }
    if (!$result['ok']) throw new RuntimeException('Не удалось прочитать файл из архива');
    $data=(string)$result['data'];
    if ($limit>0 && strlen($data)>$limit) throw new RuntimeException('Не удалось полностью прочитать файл');
    return ['content'=>$data,'entry'=>$canonical,'actual'=>$actual,'size'=>strlen($data),'writable'=>hc_archive_writer($archivePath)!==''];
}

function hc_archive_entry_read(string $archivePath, string $entry, int $limit = 0): array
{
    $entry=hc_archive_entry_clean($entry);
    if (!hc_is_editable_text_name($entry)) throw new RuntimeException('Этот тип файла нельзя открыть в редакторе');
    $result=hc_archive_entry_bytes($archivePath,$entry,$limit);
    $data=(string)$result['content'];
    if (str_contains($data,"\0")) throw new RuntimeException('Бинарный файл нельзя открыть в редакторе');
    return $result;
}

function hc_archive_backup(string $archivePath): string
{
    $dir = hc_meta_dir() . '/archive-backups';
    if (!is_dir($dir) && !@mkdir($dir, 02770, true) && !is_dir($dir)) return '';
    @chown($dir, 'hypercloud'); @chgrp($dir, 'hypercloud'); @chmod($dir, 02770);
    $backup = $dir . '/' . date('Ymd-His') . '-' . substr(hash('sha256', $archivePath . microtime(true)), 0, 10) . '-' . basename($archivePath);

    $ok = false;
    // On filesystems with reflink support this is instant even for very large archives.
    if (is_executable('/usr/bin/cp')) {
        $cmd='/usr/bin/cp --reflink=always --preserve=mode,timestamps '.escapeshellarg($archivePath).' '.escapeshellarg($backup).' 2>/dev/null';
        exec($cmd,$out,$code); $ok=$code===0 && is_file($backup);
    }
    if (!$ok) {
        $size=(float)(@filesize($archivePath)?:0); $free=(float)(@disk_free_space($dir)?:0);
        // A backup must never make a huge archive impossible to edit. If there is not enough free disk, save without backup.
        if ($size <= 0 || $free > $size + 128*1024*1024) $ok=@copy($archivePath,$backup);
    }
    if (!$ok) { @unlink($backup); return ''; }
    @chmod($backup, 0660); @chown($backup, 'hypercloud'); @chgrp($backup, 'hypercloud');
    $files = glob($dir . '/*') ?: [];
    usort($files, static fn($a,$b)=>(@filemtime($b)?:0)<=> (@filemtime($a)?:0));
    foreach (array_slice($files, 10) as $old) @unlink($old);
    return $backup;
}

function hc_archive_entry_write(string $archivePath, string $entry, string $content): void
{
    $entry=hc_archive_entry_clean($entry);
    if (!hc_is_editable_text_name($entry)) throw new RuntimeException('Этот тип файла нельзя сохранять из редактора');
        if (str_contains($content,"\0")) throw new RuntimeException('Бинарные данные запрещены');
    $found=hc_archive_entry_lookup($archivePath,$entry);
    $actual=(string)$found['actual'];
    $writer=hc_archive_writer($archivePath);
    if ($writer==='') throw new RuntimeException('Этот формат архива доступен только для чтения. ZIP и 7Z можно редактировать; RAR — если установлен rar.');
    $backup=hc_archive_backup($archivePath);
    try {
        if ($writer==='ziparchive') {
            $zip=new ZipArchive();
            if ($zip->open($archivePath)!==true) throw new RuntimeException('Не удалось открыть ZIP для записи');
            $idx=$zip->locateName($actual,0);
            if ($idx===false) { $zip->close(); throw new RuntimeException('Файл внутри ZIP не найден'); }
            $tmpFile=tempnam(sys_get_temp_dir(),'hc-zip-edit-');
            if ($tmpFile===false || @file_put_contents($tmpFile,$content,LOCK_EX)===false) { if(is_string($tmpFile))@unlink($tmpFile); $zip->close(); throw new RuntimeException('Не удалось подготовить изменения'); }
            if (!$zip->deleteIndex($idx) || !$zip->addFile($tmpFile,$actual)) { @unlink($tmpFile); $zip->close(); throw new RuntimeException('Не удалось обновить файл внутри ZIP'); }
            if (!$zip->close()) { @unlink($tmpFile); throw new RuntimeException('Не удалось сохранить ZIP'); }
            @unlink($tmpFile);
        } else {
            // Preserve the exact stored path (including a harmless leading ./), otherwise CLI tools can create a duplicate entry.
            hc_archive_entry_clean($actual);
            $tmp=sys_get_temp_dir().'/hc-archive-'.bin2hex(random_bytes(8));
            $actualFs=ltrim(str_replace('\\','/',$actual),'/');
            $entryPath=$tmp.'/'.$actualFs;
            if (!@mkdir(dirname($entryPath),0700,true) && !is_dir(dirname($entryPath))) throw new RuntimeException('Не удалось подготовить временную папку');
            if (@file_put_contents($entryPath,$content,LOCK_EX)===false) throw new RuntimeException('Не удалось подготовить файл для архива');
            if ($writer==='zipcli') $cmd='cd '.escapeshellarg($tmp).' && /usr/bin/zip -q -u '.escapeshellarg($archivePath).' '.escapeshellarg($actualFs).' 2>/dev/null';
            elseif ($writer==='7z' || $writer==='7zz') { $bin=$writer==='7z'?'/usr/bin/7z':'/usr/bin/7zz'; $cmd='cd '.escapeshellarg($tmp).' && '.escapeshellarg($bin).' u -y -bd '.escapeshellarg($archivePath).' '.escapeshellarg($actualFs).' >/dev/null 2>&1'; }
            else $cmd='cd '.escapeshellarg($tmp).' && /usr/bin/rar u -idq '.escapeshellarg($archivePath).' '.escapeshellarg($actualFs).' >/dev/null 2>&1';
            exec($cmd,$out,$code); hc_rrmdir($tmp);
            if ($code!==0) throw new RuntimeException('Архиватор не смог сохранить изменения');
        }
    } catch (Throwable $e) {
        if ($backup !== '' && is_file($backup)) @copy($backup,$archivePath); throw $e;
    }
    @chmod($archivePath,0660); @chown($archivePath,'hypercloud'); @chgrp($archivePath,'hypercloud');
}

function hc_write_text_file(string $path, string $content): void
{
    if (!is_file($path) || is_link($path)) throw new RuntimeException('Файл недоступен');
    if (!hc_is_text($path) || !hc_is_editable_text_name(basename($path))) throw new RuntimeException('Этот файл нельзя редактировать');
        if (str_contains($content, "\0")) throw new RuntimeException('Бинарные данные запрещены');
    $tmp = dirname($path) . '/.hc-edit-' . bin2hex(random_bytes(8));
    if (@file_put_contents($tmp, $content, LOCK_EX) === false) throw new RuntimeException('Не удалось записать изменения');
    $mode = @fileperms($path); if (is_int($mode)) @chmod($tmp, $mode & 0777); else @chmod($tmp, 0660);
    @chown($tmp, 'hypercloud'); @chgrp($tmp, 'hypercloud');
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
    if ($inline) { header_remove('X-Frame-Options'); header('X-Frame-Options: SAMEORIGIN'); header("Content-Security-Policy: sandbox; default-src 'none'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'unsafe-inline'; frame-ancestors 'self'"); }
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
        'jpg','jpeg','png','gif','webp','svg','avif' => 'fa-file-image',
        'pdf' => 'fa-file-pdf',
        'mp4','webm','mov','mkv' => 'fa-file-video',
        'mp3','ogg','wav','flac' => 'fa-file-audio',
        'html','htm' => 'fa-file-code',
        'php','phtml' => 'fa-file-code',
        'css','scss','sass','less' => 'fa-file-code',
        'js','mjs','cjs','ts','tsx','jsx' => 'fa-file-code',
        'json','xml','yml','yaml','csv' => 'fa-code',
        'sql' => 'fa-database',
        'py' => 'fa-terminal',
        'md','txt','log','ini','conf','env' => 'fa-file-lines',
        default => 'fa-file',
    };
}
function hc_archive_entry_icon(string $name): string
{
    if (str_ends_with($name, '/')) return 'fa-folder';
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    return match ($ext) {
        'zip','rar','7z','tar','gz','tgz','bz2','xz' => 'fa-file-zipper',
        'jpg','jpeg','png','gif','webp','svg','avif' => 'fa-file-image',
        'pdf' => 'fa-file-pdf',
        'mp4','webm','mov','mkv' => 'fa-file-video',
        'mp3','ogg','wav','flac' => 'fa-file-audio',
        'html','htm' => 'fa-file-code', 'php','phtml' => 'fa-file-code',
        'css','scss','sass','less' => 'fa-file-code', 'js','mjs','cjs','ts','tsx','jsx' => 'fa-file-code',
        'json','xml','yml','yaml','csv' => 'fa-code', 'sql' => 'fa-database', 'py' => 'fa-terminal',
        'md','txt','log','ini','conf','env' => 'fa-file-lines', default => 'fa-file',
    };
}
function hc_kind(string $path): string
{
    if (is_dir($path)) return 'folder';
    if (hc_is_archive($path)) return 'archive';
    if (hc_is_image($path)) return 'image';
    $ext=strtolower(pathinfo($path,PATHINFO_EXTENSION));
    if(in_array($ext,['html','htm'],true))return 'html';
    if(in_array($ext,['php','phtml'],true))return 'php';
    if(in_array($ext,['css','scss','sass','less'],true))return 'css';
    if(in_array($ext,['js','mjs','cjs','ts','tsx','jsx'],true))return 'js';
    if(in_array($ext,['json','xml','yml','yaml','csv','sql'],true))return 'data';
    $mime = hc_mime($path);
    if ($mime === 'application/pdf') return 'pdf';
    if (str_starts_with($mime,'video/')) return 'video';
    if (str_starts_with($mime,'audio/')) return 'audio';
    if (hc_is_text($path)) return 'code';
    return 'file';
}

function hc_breadcrumb(string $rel): string
{
    $parts = ['<a href="'.e(hc_url([])).'">'.(hc_space()==='shared'?'Общие файлы':'Мои файлы').'</a>'];
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

function hc_share_store_load(): array
{
    $user = current_user(); if (!$user) return [];
    $space = hc_space();
    if ($space === 'shared') {
        $st = hc_db()->prepare('SELECT token,owner_user_id,space,rel_path AS path,created_at FROM public_shares WHERE space=? ORDER BY created_at DESC');
        $st->execute([$space]);
    } else {
        $st = hc_db()->prepare('SELECT token,owner_user_id,space,rel_path AS path,created_at FROM public_shares WHERE owner_user_id=? AND space=? ORDER BY created_at DESC');
        $st->execute([(int)$user['id'],$space]);
    }
    $out=[]; foreach($st->fetchAll() as $r) $out[(string)$r['token']]=$r; return $out;
}

function hc_share_index_by_path(?array $shares = null): array
{
    $shares ??= hc_share_store_load(); $out=[];
    foreach($shares as $token=>$entry){if(!is_array($entry))continue;$rel=(string)($entry['path']??'');if($rel==='')continue;$entry['token']=(string)$token;$out[$rel]=$entry;}
    return $out;
}

function hc_share_enable(string $rel, int $userId): string
{
    $rel=hc_clean_rel($rel); if($rel==='')throw new RuntimeException('Корень нельзя публиковать');
    hc_assert_can_modify($rel); [,,$path]=hc_resolve($rel,true); if(!is_file($path)||is_link($path))throw new RuntimeException('Ссылку можно создать только на файл');
    $space=hc_space();
    if($space==='private'){$st=hc_db()->prepare('SELECT token FROM public_shares WHERE owner_user_id=? AND space=? AND rel_path=? LIMIT 1');$st->execute([$userId,$space,$rel]);}
    else{$st=hc_db()->prepare('SELECT token FROM public_shares WHERE space=? AND rel_path=? LIMIT 1');$st->execute([$space,$rel]);}
    $existing=$st->fetchColumn();if(is_string($existing)&&$existing!=='')return $existing;
    do{$token=bin2hex(random_bytes(24));$q=hc_db()->prepare('SELECT 1 FROM public_shares WHERE token=?');$q->execute([$token]);}while($q->fetchColumn());
    hc_db()->prepare("INSERT INTO public_shares(token,owner_user_id,space,rel_path,created_at) VALUES(?,?,?,?,datetime('now','localtime'))")->execute([$token,$userId,$space,$rel]); return $token;
}
function hc_share_disable(string $rel): void
{
    $rel=hc_clean_rel($rel); hc_assert_can_modify($rel); $u=current_user();if(!$u)return;
    if(hc_space()==='private')hc_db()->prepare('DELETE FROM public_shares WHERE owner_user_id=? AND space=? AND rel_path=?')->execute([(int)$u['id'],'private',$rel]);
    else hc_db()->prepare('DELETE FROM public_shares WHERE space=? AND rel_path=?')->execute(['shared',$rel]);
}
function hc_share_repath_tree(string $oldRel,string $newRel): void
{
    $oldRel=hc_clean_rel($oldRel);$newRel=hc_clean_rel($newRel);if($oldRel===''||$newRel==='')return;$u=current_user();if(!$u)return;
    if(hc_space()==='private'){$st=hc_db()->prepare('SELECT token,rel_path FROM public_shares WHERE owner_user_id=? AND space=? AND (rel_path=? OR rel_path LIKE ?)');$st->execute([(int)$u['id'],'private',$oldRel,$oldRel.'/%']);}
    else{$st=hc_db()->prepare('SELECT token,rel_path FROM public_shares WHERE space=? AND (rel_path=? OR rel_path LIKE ?)');$st->execute(['shared',$oldRel,$oldRel.'/%']);}
    $upd=hc_db()->prepare('UPDATE public_shares SET rel_path=? WHERE token=?');
    foreach($st->fetchAll() as $r){$path=(string)$r['rel_path'];$next=$path===$oldRel?$newRel:$newRel.substr($path,strlen($oldRel));$upd->execute([$next,(string)$r['token']]);}
}
function hc_share_revoke_tree(string $rel): void
{
    $rel=hc_clean_rel($rel);if($rel==='')return;$u=current_user();if(!$u)return;
    if(hc_space()==='private')hc_db()->prepare('DELETE FROM public_shares WHERE owner_user_id=? AND space=? AND (rel_path=? OR rel_path LIKE ?)')->execute([(int)$u['id'],'private',$rel,$rel.'/%']);
    else hc_db()->prepare('DELETE FROM public_shares WHERE space=? AND (rel_path=? OR rel_path LIKE ?)')->execute(['shared',$rel,$rel.'/%']);
}
function hc_share_lookup(string $token): ?array
{
    if(!preg_match('/^[a-f0-9]{48}$/',$token))return null;
    $st=hc_db()->prepare('SELECT * FROM public_shares WHERE token=? LIMIT 1');$st->execute([$token]);$entry=$st->fetch();if(!is_array($entry))return null;
    $owner=hc_cloud_user_by_id((int)$entry['owner_user_id']);if(!$owner)return null;
    try{
        $rel=hc_clean_rel((string)$entry['rel_path']);$root=hc_root_for_user($owner,(string)$entry['space']);$rootReal=realpath($root)?:$root;$path=$root.($rel!==''?'/'.$rel:'');$real=realpath($path);
        if($real===false||!is_file($real)||is_link($path)||($real!==$rootReal&&!str_starts_with($real,$rootReal.DIRECTORY_SEPARATOR)))return null;
        return ['token'=>$token,'path'=>$rel,'file'=>$real,'space'=>(string)$entry['space'],'owner_user_id'=>(int)$entry['owner_user_id'],'created_at'=>(string)$entry['created_at']];
    }catch(Throwable){return null;}
}

function hc_public_share_url(string $token): string
{
    return '/?s=' . rawurlencode($token);
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
<!doctype html><html lang="ru" data-bs-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ссылка недоступна — HYPER CLOUD</title><meta name="robots" content="noindex,nofollow,noarchive"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" integrity="sha384-sRIl4kxILFvY47J16cr9ZwB07vP4J8+LH7qKQnuqkuIAvNWLzeN8tE5YBujZqJLB" crossorigin="anonymous"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css"><link rel="stylesheet" href="/cloud.css?v=107"></head><body class="hc-public-body hc-public-error-body">
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
<!doctype html><html lang="ru" data-bs-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?= e($name) ?> — HYPER CLOUD</title><meta name="robots" content="noindex,nofollow,noarchive"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" integrity="sha384-sRIl4kxILFvY47J16cr9ZwB07vP4J8+LH7qKQnuqkuIAvNWLzeN8tE5YBujZqJLB" crossorigin="anonymous"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css"><link rel="stylesheet" href="/cloud.css?v=107"></head><body class="hc-public-body">
<main class="hc-public-page"><section class="hc-public-card"><div class="hc-public-brand"><span><i class="fa-solid fa-cloud"></i></span><b>HYPER CLOUD</b></div>
<div class="hc-public-file"><div class="hc-public-file-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($path)) ?>"></i></div><div><h1><?= e($name) ?></h1><p><?= e(human_bytes($size)) ?> <span>•</span> <?= e(date('d.m.Y H:i', (int)(filemtime($path) ?: time()))) ?></p></div></div>
<?php if(str_starts_with($mime,'image/')): ?><div class="hc-public-preview image"><img src="<?= e($inline) ?>" alt=""></div>
<?php elseif($mime==='application/pdf'): ?><div class="hc-public-preview document"><iframe src="<?= e($inline) ?>" title="<?= e($name) ?>"></iframe></div>
<?php elseif(str_starts_with($mime,'video/')): ?><div class="hc-public-preview media"><video controls preload="metadata" src="<?= e($inline) ?>"></video></div>
<?php elseif(str_starts_with($mime,'audio/')): ?><div class="hc-public-audio"><audio controls preload="metadata" src="<?= e($inline) ?>"></audio></div><?php endif; ?>
<a class="hc-public-download" href="<?= e($download) ?>"><i class="fa-solid fa-download"></i><span>Скачать</span><small><?= e(human_bytes($size)) ?></small></a></section></main></body></html><?php
    exit;
}

// Public token route is intentionally processed BEFORE Cloud authentication.
$publicToken = strtolower(trim((string)($_GET['s'] ?? '')));
if ($publicToken !== '') {
    $publicShare = hc_share_lookup($publicToken);
    if (!$publicShare) hc_public_error_page();
    if (isset($_GET['download'])) hc_stream_file((string)$publicShare['file'], false);
    if (isset($_GET['inline'])) { $pm=hc_mime((string)$publicShare['file']); if(!str_starts_with($pm,'image/') && $pm!=='application/pdf' && !str_starts_with($pm,'video/') && !str_starts_with($pm,'audio/')) hc_public_error_page(); hc_stream_file((string)$publicShare['file'], true); }
    hc_public_share_page($publicShare);
}

function hc_render_auth_page(string $mode='login', string $error=''): never
{
    $register=$mode==='register';$flash=flash();if($error===''&&$flash)$error=(string)($flash['message']??'');
    http_response_code(200);header('X-Frame-Options: DENY');header('Cache-Control: no-store');
    ?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?= $register?'Регистрация':'Вход' ?> — HYPER CLOUD</title><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css"><link rel="stylesheet" href="/cloud.css?v=107"></head><body class="hc-auth-body">
<div class="hc-auth-wrap"><section class="hc-auth-card"><div class="hc-auth-brand"><span><i class="fa-solid fa-cloud"></i></span><div><b>HYPER CLOUD</b><small>cloud.hyper-host.pw</small></div></div><div class="hc-auth-copy"><h1><?= $register?'Создать аккаунт':'Вход в облако' ?></h1></div>
<?php if($error!==''): ?><div class="hc-auth-error"><i class="fa-solid fa-circle-exclamation"></i><?= e($error) ?></div><?php endif; ?>
<form method="post" action="/?auth=<?= $register?'register':'login' ?>" class="hc-auth-form"><?= '<input type="hidden" name="_csrf" value="'.e(csrf_token()).'">' ?>
<label><span>Логин</span><div><i class="fa-regular fa-user"></i><input name="username" autocomplete="username" required autofocus></div></label>
<?php if($register): ?><label><span>E-mail</span><div><i class="fa-regular fa-envelope"></i><input type="email" name="email" autocomplete="email"></div></label><?php endif; ?>
<label><span>Пароль</span><div><i class="fa-solid fa-lock"></i><input type="password" name="password" autocomplete="<?= $register?'new-password':'current-password' ?>" required></div></label>
<?php if($register): ?><label><span>Повторите пароль</span><div><i class="fa-solid fa-lock"></i><input type="password" name="password2" autocomplete="new-password" required></div></label><?php else: ?><label><span>Код подтверждения <small>если используется</small></span><div><i class="fa-solid fa-shield-halved"></i><input name="totp" inputmode="numeric" maxlength="6" autocomplete="one-time-code" placeholder="000000"></div></label><?php endif; ?>
<button type="submit"><i class="fa-solid <?= $register?'fa-user-plus':'fa-arrow-right-to-bracket' ?>"></i><?= $register?'Создать аккаунт':'Войти' ?></button></form>
<div class="hc-auth-switch"><?php if($register): ?>Уже есть аккаунт? <a href="/?auth=login">Войти</a><?php else: ?>Нет аккаунта? <a href="/?auth=register">Регистрация</a><?php endif; ?></div>
</section></div></body></html><?php exit;
}

$authAction=(string)($_GET['auth']??'');
if($authAction==='logout') hc_logout();
if($authAction==='login'||$authAction==='register'){
    if(current_user())redirect('/');
    if($_SERVER['REQUEST_METHOD']==='POST'){
        try{check_csrf();if($authAction==='login')hc_login((string)($_POST['username']??''),(string)($_POST['password']??''),(string)($_POST['totp']??''));else hc_register((string)($_POST['username']??''),(string)($_POST['email']??''),(string)($_POST['password']??''),(string)($_POST['password2']??''));redirect('/');}
        catch(Throwable $e){hc_render_auth_page($authAction,$e->getMessage());}
    }
    hc_render_auth_page($authAction);
}
if(!current_user()) hc_render_auth_page('login');
$user=require_auth();hc_ensure_user_root($user);
// v108: editor and website preview are isolated endpoints. Old URLs are redirected
// before the legacy preview block can execute, preventing editor/HTML HTTP 500s.
if ((string)($_GET['edit'] ?? '') === '1' && !empty($_GET['preview'])) {
    redirect('/editor.php?'.http_build_query(['space'=>hc_space(),'path'=>hc_clean_rel((string)$_GET['preview'])],'','&',PHP_QUERY_RFC3986));
}
if (!empty($_GET['archive_entry']) && !empty($_GET['preview'])) {
    redirect('/editor.php?'.http_build_query(['space'=>hc_space(),'path'=>hc_clean_rel((string)$_GET['preview']),'entry'=>(string)$_GET['archive_entry']],'','&',PHP_QUERY_RFC3986));
}
header('X-Frame-Options: DENY');
header('Referrer-Policy: same-origin');

// Protected downloads / previews.
$cloudAction = (string)($_GET['cloud_action'] ?? '');
if ($cloudAction !== '') {
    try {
        $relAction = hc_clean_rel((string)($_GET['path'] ?? ''));
        [,,$actionPath] = hc_resolve($relAction, true);
        $siteRootAction = hc_clean_rel((string)($_GET['site_root'] ?? ''));
        if ($cloudAction === 'download') hc_stream_file($actionPath, false);
        if ($cloudAction === 'raw') hc_stream_file($actionPath, true);
        if ($cloudAction === 'html_preview') redirect('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$relAction],'','&',PHP_QUERY_RFC3986));
        if ($cloudAction === 'html_asset') hc_html_asset_output($relAction, $actionPath, $siteRootAction);
        if ($cloudAction === 'archive_html_preview') redirect('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$relAction,'entry'=>(string)($_GET['entry']??'')],'','&',PHP_QUERY_RFC3986));
        if ($cloudAction === 'archive_html_asset') hc_archive_html_asset_output($relAction, $actionPath, (string)($_GET['entry'] ?? ''), $siteRootAction);
        http_response_code(404); exit('Not found');
    } catch (Throwable $e) {
        http_response_code(404); exit('File unavailable');
    }
}

function hc_json(array $payload, int $status=200): never
{
    while(ob_get_level()>0)@ob_end_clean();http_response_code($status);header('Content-Type: application/json; charset=utf-8');header('Cache-Control: no-store');echo json_encode($payload,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);exit;
}
function hc_upload_session_dir(string $uploadId): string
{
    if(!preg_match('/^[a-f0-9]{32}$/',$uploadId))throw new RuntimeException('Некорректный ID загрузки');$user=require_auth();$key=preg_replace('/[^A-Za-z0-9_.-]/','_', (string)$user['storage_key']);
    $base=hc_meta_dir().'/uploads/'.$key;if(!is_dir($base))@mkdir($base,02770,true);$dir=$base.'/'.$uploadId;if(!is_dir($dir))@mkdir($dir,02770,true);@chmod($dir,02770);return $dir;
}
function hc_upload_cleanup_dir(string $dir): void
{
    if(!is_dir($dir))return;foreach(scandir($dir)?:[] as $n){if($n==='.'||$n==='..')continue;$p=$dir.'/'.$n;if(is_file($p))@unlink($p);} @rmdir($dir);
}
function hc_upload_meta(string $dir): array
{
    $raw=@file_get_contents($dir.'/meta.json');$data=json_decode(is_string($raw)?$raw:'',true);return is_array($data)?$data:[];
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $action = (string)($_POST['action'] ?? '');
    $isAjaxUpload = in_array($action,['upload','upload_chunk','upload_complete'],true) && ((string)($_POST['ajax_upload'] ?? '') === '1' || str_starts_with($action,'upload_'));
    $current = '';
    try {
        $current = hc_clean_rel((string)($_POST['path'] ?? ''));
        [,,$dir] = hc_resolve($current, true);
        if (!is_dir($dir)) throw new RuntimeException('Текущая папка не найдена');

        if ($action === 'upload_chunk') {
            $uploadId=strtolower(trim((string)($_POST['upload_id']??'')));$chunkIndex=(int)($_POST['chunk_index']??-1);$totalChunks=(int)($_POST['total_chunks']??0);$fileName=hc_valid_name(basename((string)($_POST['file_name']??'')));$fileSize=max(0,(int)($_POST['file_size']??0));$uploadTarget=hc_clean_rel((string)($_POST['upload_target']??$current));
            if($chunkIndex<0||$totalChunks<1||$chunkIndex>=$totalChunks)throw new RuntimeException('Некорректный номер части файла');[,,$uploadDir]=hc_resolve($uploadTarget,true);if(!is_dir($uploadDir)||is_link($uploadDir))throw new RuntimeException('Папка загрузки не найдена');
            if(!isset($_FILES['chunk'])||(int)($_FILES['chunk']['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK)throw new RuntimeException('Часть файла не получена');$tmp=(string)($_FILES['chunk']['tmp_name']??'');if($tmp===''||!is_uploaded_file($tmp))throw new RuntimeException('Временный файл загрузки недоступен');
            $session=hc_upload_session_dir($uploadId);$meta=hc_upload_meta($session);$expected=['file_name'=>$fileName,'file_size'=>$fileSize,'total_chunks'=>$totalChunks,'upload_target'=>$uploadTarget,'space'=>hc_space(),'user_id'=>(int)$user['id']];
            if(!$meta){if(@file_put_contents($session.'/meta.json',json_encode($expected,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),LOCK_EX)===false)throw new RuntimeException('Не удалось подготовить загрузку');}
            else foreach($expected as $k=>$v)if((string)($meta[$k]??'')!==(string)$v)throw new RuntimeException('Параметры загрузки изменились');
            $part=$session.'/'.sprintf('%08d.part',$chunkIndex);if(!move_uploaded_file($tmp,$part))throw new RuntimeException('Не удалось сохранить часть файла');@chmod($part,0660);
            hc_json(['ok'=>true,'chunk'=>$chunkIndex,'received'=>(int)(filesize($part)?:0)]);
        } elseif ($action === 'upload_complete') {
            $uploadId=strtolower(trim((string)($_POST['upload_id']??'')));$session=hc_upload_session_dir($uploadId);$meta=hc_upload_meta($session);if(!$meta)throw new RuntimeException('Сессия загрузки не найдена');
            if((int)($meta['user_id']??0)!==(int)$user['id']||(string)($meta['space']??'')!==hc_space())throw new RuntimeException('Загрузка принадлежит другому сеансу');$uploadTarget=hc_clean_rel((string)($meta['upload_target']??''));[,,$uploadDir]=hc_resolve($uploadTarget,true);if(!is_dir($uploadDir))throw new RuntimeException('Папка загрузки не найдена');
            $total=(int)($meta['total_chunks']??0);$name=hc_valid_name((string)($meta['file_name']??''));$target=hc_unique_target($uploadDir,$name);$temp=$uploadDir.'/.hc-upload-'.$uploadId.'.part';$out=@fopen($temp,'wb');if(!$out)throw new RuntimeException('Не удалось создать файл назначения');$written=0;
            try{for($i=0;$i<$total;$i++){$part=$session.'/'.sprintf('%08d.part',$i);if(!is_file($part))throw new RuntimeException('Не получена часть '.($i+1).' из '.$total);$in=@fopen($part,'rb');if(!$in)throw new RuntimeException('Не удалось прочитать часть файла');$n=stream_copy_to_stream($in,$out);fclose($in);if($n===false)throw new RuntimeException('Ошибка сборки файла');$written+=(int)$n;}}finally{fclose($out);}
            $expected=max(0,(int)($meta['file_size']??0));if($expected>0&&$written!==$expected){@unlink($temp);throw new RuntimeException('Размер загруженного файла не совпал');}if(!@rename($temp,$target)){@unlink($temp);throw new RuntimeException('Не удалось завершить загрузку');}@chmod($target,0660);@chown($target,'hypercloud');@chgrp($target,'hypercloud');
            $finalRel=trim($uploadTarget.'/'.basename($target),'/');if(hc_space()==='shared')hc_shared_mark($finalRel,(int)$user['id'],'file');hc_upload_cleanup_dir($session);add_event('cloud','Загружен файл: '.$finalRel);hc_json(['ok'=>true,'file'=>basename($target),'path'=>$finalRel,'size'=>$written,'redirect'=>hc_url($current!==''?['path'=>$current]:[])]);
        } elseif ($action === 'mkdir') {
            $name = hc_valid_name((string)($_POST['name'] ?? ''));
            $target = $dir.'/'.$name;
            if (file_exists($target) || is_link($target)) throw new RuntimeException('Такое имя уже занято');
            if (!mkdir($target, 02770, false)) throw new RuntimeException('Не удалось создать папку');
            @chown($target,'hypercloud'); @chgrp($target,'hypercloud'); @chmod($target,02770);
            if(hc_space()==='shared') hc_shared_mark(trim($current.'/'.$name,'/'),(int)$user['id'],'dir');
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
                @chmod($target,0660); @chown($target,'hypercloud'); @chgrp($target,'hypercloud');
                if(hc_space()==='shared') hc_shared_mark(trim($uploadTarget.'/'.basename($target),'/'),(int)$user['id'],'file');
                $uploaded++;
            }
            if ($uploaded < 1) throw new RuntimeException('Не удалось загрузить ни одного файла');
            add_event('cloud','Загружено файлов: '.$uploaded.' в /'.$uploadTarget);
            flash('Загружено файлов: '.$uploaded,'success');
            if ($isAjaxUpload) {
                header('Content-Type: application/json; charset=utf-8');
                echo json_encode(['ok'=>true,'uploaded'=>$uploaded,'redirect'=>hc_url($current !== '' ? ['path'=>$current] : [])], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                exit;
            }
        } elseif ($action === 'save_text') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            [,,$target] = hc_resolve($targetRel, true);
            hc_assert_can_modify($targetRel);
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
            hc_assert_can_modify($targetRel);
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
            hc_assert_can_modify($targetRel);
            if(is_dir($target)) hc_assert_shared_tree_modify($targetRel);
            $name = hc_valid_name((string)($_POST['new_name'] ?? ''));
            $newPath = dirname($target).'/'.$name;
            if (file_exists($newPath) || is_link($newPath)) throw new RuntimeException('Такое имя уже занято');
            if (!@rename($target,$newPath)) throw new RuntimeException('Не удалось переименовать');
            $newRel = trim((dirname($targetRel)==='.'?'':dirname($targetRel)).'/'.$name,'/');
            hc_share_repath_tree($targetRel, $newRel);
            if(hc_space()==='shared') hc_shared_repath_tree($targetRel,$newRel);
            add_event('cloud','Переименовано: '.$targetRel.' → '.$name);
            flash('Переименовано','success');
        } elseif ($action === 'delete') {
            $targetRel = hc_clean_rel((string)($_POST['target'] ?? ''));
            if ($targetRel === '') throw new RuntimeException('Корень удалить нельзя');
            [,,$target] = hc_resolve($targetRel,true);
            hc_assert_can_modify($targetRel);
            if(is_dir($target)) hc_assert_shared_tree_modify($targetRel);
            hc_share_revoke_tree($targetRel);
            hc_rrmdir($target);
            if(hc_space()==='shared') hc_shared_remove_tree($targetRel);
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
        if (($isAjaxUpload ?? false) && in_array(($action ?? ''),['upload','upload_chunk','upload_complete'],true)) {
            http_response_code(400);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['ok'=>false,'error'=>$e->getMessage()], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            exit;
        }
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
if($editText && $previewRel!=='' && !hc_can_modify($previewRel)) $editText=false;
$archiveEntry = '';
$archiveEntryData = null;
$archiveEntryError = '';
if ($previewPath && hc_is_archive($previewPath) && isset($_GET['archive_entry'])) {
    try {
        hc_assert_can_modify($previewRel);
        $archiveEntry = hc_archive_entry_clean((string)$_GET['archive_entry']);
        $archiveEntryData = hc_archive_entry_read($previewPath, $archiveEntry, 0);
    } catch (Throwable $e) {
        $archiveEntryError = $e->getMessage();
    }
}

$diskTotal = (float)(@disk_total_space($root) ?: 0);
$diskFree = (float)(@disk_free_space($root) ?: 0);
$diskUsed = max(0.0,$diskTotal-$diskFree);
$diskPct = $diskTotal > 0 ? min(100,($diskUsed/$diskTotal)*100) : 0;
$flash = flash();
$viewTitle = $view==='disk' && hc_space()==='shared' ? 'Общие файлы' : ['disk'=>'Мои файлы','recent'=>'Недавние','archives'=>'Архивы','images'=>'Изображения','shared'=>'Публичные ссылки'][$view];
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
<link rel="stylesheet" href="/cloud.css?v=107">
</head>
<body data-share-open="<?= e($shareOpenRel) ?>">
<div class="hc-app" id="hcApp">
  <aside class="hc-sidebar" id="hcSidebar">
    <div class="hc-brand"><div class="hc-brand-mark"><i class="fa-solid fa-cloud"></i></div><div><b>HYPER CLOUD</b></div></div>
    <button class="hc-create" type="button" data-open-dialog="createDialog"><i class="fa-solid fa-plus"></i><span>Создать</span></button>
    <nav class="hc-nav">
      <div class="hc-nav-label">ФАЙЛЫ</div>
      <a class="<?= $view==='disk'&&hc_space()==='private'?'active':'' ?>" href="/?space=private"><i class="fa-solid fa-folder-open"></i><span>Мои файлы</span></a>
      <a class="<?= $view==='disk'&&hc_space()==='shared'?'active':'' ?>" href="/?space=shared"><i class="fa-solid fa-people-group"></i><span>Общие файлы</span></a>
      <a class="<?= $view==='recent'?'active':'' ?>" href="<?= e(hc_url(['view'=>'recent'])) ?>"><i class="fa-solid fa-clock-rotate-left"></i><span>Недавние</span></a>
      <a class="<?= $view==='archives'?'active':'' ?>" href="<?= e(hc_url(['view'=>'archives'])) ?>"><i class="fa-solid fa-box-archive"></i><span>Архивы</span></a>
      <a class="<?= $view==='images'?'active':'' ?>" href="<?= e(hc_url(['view'=>'images'])) ?>"><i class="fa-solid fa-images"></i><span>Изображения</span></a>
      <div class="hc-nav-label access">ДОСТУП</div>
      <a class="<?= $view==='shared'?'active':'' ?>" href="<?= e(hc_url(['view'=>'shared'])) ?>"><i class="fa-solid fa-link"></i><span>Публичные ссылки</span><em><?= count($shareByPath) ?></em></a>
    </nav>
    <div class="hc-side-spacer"></div>
    <div class="hc-storage">
      <div class="hc-storage-title"><span>Свободное место</span><b><?= e(human_bytes($diskFree)) ?></b></div>
      <div class="hc-storage-bar"><i style="width:<?= e((string)round($diskPct,1)) ?>%"></i></div>
      <small>Использовано <?= e(human_bytes($diskUsed)) ?> из <?= e(human_bytes($diskTotal)) ?></small>
    </div>
    <?php if(hc_is_panel_admin($user)): ?><a class="hc-back-panel" href="<?= e(hc_panel_url()) ?>"><i class="fa-solid fa-server"></i><span>HYPER-HOST</span><i class="fa-solid fa-arrow-up-right-from-square hc-back-arrow"></i></a><?php endif; ?>
  </aside>

  <section class="hc-shell">
    <header class="hc-header">
      <button class="hc-mobile-menu" type="button" id="hcMenuButton"><i class="fa-solid fa-bars"></i></button>
      <div class="hc-search"><i class="fa-solid fa-magnifying-glass"></i><input id="hcSearch" type="search" placeholder="Поиск в текущем списке" autocomplete="off"></div>
      <div class="hc-user"><div class="hc-avatar"><?= e(hc_initial((string)($user['username'] ?? 'A'))) ?></div><div class="hc-user-copy"><b><?= e((string)($user['username'] ?? 'admin')) ?></b><span><?= hc_is_panel_admin($user)?'Администратор':'Пользователь' ?></span></div><a class="hc-icon-btn" title="Выйти" href="/?auth=logout"><i class="fa-solid fa-arrow-right-from-bracket"></i></a></div>
    </header>

    <main class="hc-main" id="hcMain">
      <?php if($flash): ?><div class="hc-toast <?= e((string)$flash['type']) ?>"><i class="fa-solid fa-circle-info"></i><span><?= e((string)$flash['message']) ?></span></div><?php endif; ?>

      <div class="hc-title-row">
        <div>
          <div class="hc-eyebrow"><?= hc_space()==='shared'?'ОБЩЕЕ ПРОСТРАНСТВО':'HYPER CLOUD' ?></div>
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
          <?php foreach($rows as $row): $kind=hc_kind($row['path']); $isDir=(bool)$row['is_dir']; $isHtmlFile=!$isDir&&hc_is_html_name($row['name']); $canModify=hc_can_modify($row['rel']); $isEditableFile=!$isDir&&$canModify&&hc_is_editable_text_name($row['name']); $share=$isDir?null:($shareByPath[$row['rel']]??null); $shareToken=is_array($share)?(string)($share['token']??''):''; $shareUrl=$shareToken!==''?hc_public_share_url($shareToken):''; $previewHref=$isDir?hc_url(['path'=>$row['rel']]):hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$row['rel']],static fn($v)=>$v!==null)); $openHref=$isHtmlFile?('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$row['rel']],'','&',PHP_QUERY_RFC3986)):$previewHref; $editHref=$isEditableFile?('/editor.php?'.http_build_query(['space'=>hc_space(),'path'=>$row['rel']],'','&',PHP_QUERY_RFC3986)):''; $extLabel=$isDir?'':strtoupper((string)pathinfo($row['name'],PATHINFO_EXTENSION)); if(strlen($extLabel)>7)$extLabel=substr($extLabel,0,7); ?>
          <article class="hc-file-card" data-file-name="<?= e(hc_lower($row['name'])) ?>" data-kind="<?= e($kind) ?>">
            <a class="hc-file-open" href="<?= e($openHref) ?>"<?= $isHtmlFile?' target="_blank" rel="noopener"':'' ?>>
              <div class="hc-file-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($row['path'])) ?>"></i><?php if(!$isDir && $kind!=='image' && $extLabel!==''): ?><small class="hc-ext-chip"><?= e($extLabel) ?></small><?php endif; ?><?php if($kind==='image'): ?><img loading="lazy" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$row['rel']])) ?>" alt=""><?php endif; ?></div>
              <div class="hc-file-info"><div class="hc-file-name-line"><b title="<?= e($row['name']) ?>"><?= e($row['name']) ?></b><?php if(!$isDir): ?><span class="hc-privacy-pill <?= $shareToken!==''?'shared':'private' ?>" title="<?= $shareToken!==''?'Доступ по ссылке включён':'Приватный файл' ?>"><i class="fa-solid <?= $shareToken!==''?'fa-link':'fa-lock' ?>"></i><?= $shareToken!==''?'По ссылке':'Приватный' ?></span><?php endif; ?></div><span><?= $isDir ? 'Папка' : e(human_bytes((float)$row['size'])) ?> · <?= e(date('d.m.Y H:i',$row['mtime']?:time())) ?></span><?php if(!$isDir && $row['dir']!==''): ?><small>/<?= e($row['dir']) ?></small><?php endif; ?></div>
            </a>
            <div class="hc-file-actions">
              <?php if(!$isDir): ?><?php if($isHtmlFile): ?><a class="hc-site-quick" title="Открыть сайт" target="_blank" rel="noopener" href="<?= e($openHref) ?>"><i class="fa-solid fa-globe"></i><span>Сайт</span></a><?php endif; ?><?php if($isEditableFile): ?><a title="Редактировать код" href="<?= e($editHref) ?>"><i class="fa-solid fa-code"></i></a><?php endif; ?><a title="Скачать" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>"><i class="fa-solid fa-download"></i></a><?php endif; ?>
              <?php if($canModify): ?><button type="button" class="hc-delete-quick" title="Удалить" data-delete-target="<?= e($row['rel']) ?>" data-delete-name="<?= e($row['name']) ?>"><i class="fa-regular fa-trash-can"></i></button><?php endif; ?>
              <button type="button" title="Действия" data-menu-for="menu-<?= md5($row['rel']) ?>"><i class="fa-solid fa-ellipsis-vertical"></i></button>
            </div>
            <div class="hc-context-menu" id="menu-<?= md5($row['rel']) ?>">
              <?php if($isDir): ?><a href="<?= e(hc_url(['path'=>$row['rel']])) ?>"><i class="fa-regular fa-folder-open"></i>Открыть</a><?php else: ?><?php if($isHtmlFile): ?><a target="_blank" rel="noopener" href="<?= e($openHref) ?>"><i class="fa-solid fa-globe"></i>Открыть как сайт</a><?php else: ?><a href="<?= e($openHref) ?>"><i class="fa-regular fa-eye"></i>Открыть</a><?php endif; ?><?php if($isEditableFile): ?><a href="<?= e($editHref) ?>"><i class="fa-solid fa-code"></i>Редактировать код</a><?php endif; ?><a href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>"><i class="fa-solid fa-download"></i>Скачать</a><?php if($canModify): ?><button type="button" class="hc-share-action <?= $shareToken!==''?'active':'' ?>" data-share-target="<?= e($row['rel']) ?>" data-share-name="<?= e($row['name']) ?>" data-share-url="<?= e($shareUrl) ?>" data-share-enabled="<?= $shareToken!==''?'1':'0' ?>"><i class="fa-solid <?= $shareToken!==''?'fa-link':'fa-lock' ?>"></i>Доступ</button><?php endif; ?><?php endif; ?>
              <?php if($canModify): ?><button type="button" data-rename-target="<?= e($row['rel']) ?>" data-rename-name="<?= e($row['name']) ?>"><i class="fa-solid fa-pen"></i>Переименовать</button>
              <button class="danger" type="button" data-delete-target="<?= e($row['rel']) ?>" data-delete-name="<?= e($row['name']) ?>"><i class="fa-regular fa-trash-can"></i>Удалить</button><?php endif; ?>
            </div>
          </article>
          <?php endforeach; ?>
        </div>

        <div class="hc-list" id="hcFilesList" hidden>
          <?php foreach($rows as $row): $kind=hc_kind($row['path']); $isDir=(bool)$row['is_dir']; $isHtmlFile=!$isDir&&hc_is_html_name($row['name']); $canModify=hc_can_modify($row['rel']); $isEditableFile=!$isDir&&$canModify&&hc_is_editable_text_name($row['name']); $share=$isDir?null:($shareByPath[$row['rel']]??null); $shareToken=is_array($share)?(string)($share['token']??''):''; $shareUrl=$shareToken!==''?hc_public_share_url($shareToken):''; $previewHref=$isDir?hc_url(['path'=>$row['rel']]):hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$row['rel']],static fn($v)=>$v!==null)); $openHref=$isHtmlFile?('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$row['rel']],'','&',PHP_QUERY_RFC3986)):$previewHref; $editHref=$isEditableFile?('/editor.php?'.http_build_query(['space'=>hc_space(),'path'=>$row['rel']],'','&',PHP_QUERY_RFC3986)):''; $extLabel=$isDir?'':strtoupper((string)pathinfo($row['name'],PATHINFO_EXTENSION)); if(strlen($extLabel)>7)$extLabel=substr($extLabel,0,7); ?>
          <div class="hc-list-row" data-file-name="<?= e(hc_lower($row['name'])) ?>"><a href="<?= e($openHref) ?>"<?= $isHtmlFile?' target="_blank" rel="noopener"':'' ?>><span class="hc-mini-icon <?= e($kind) ?>"><i class="fa-solid <?= e(hc_icon($row['path'])) ?>"></i></span><b><?= e($row['name']) ?></b></a><span><?= $isDir?'Папка':e(human_bytes((float)$row['size'])) ?></span><span><?= e(date('d.m.Y H:i',$row['mtime']?:time())) ?></span><div class="hc-list-actions"><?php if(!$isDir): ?><?php if($isHtmlFile): ?><a class="hc-icon-btn" target="_blank" rel="noopener" href="<?= e($openHref) ?>" title="Открыть сайт"><i class="fa-solid fa-globe"></i></a><?php endif; ?><?php if($isEditableFile): ?><a class="hc-icon-btn" href="<?= e($editHref) ?>" title="Редактировать код"><i class="fa-solid fa-code"></i></a><?php endif; ?><?php if($canModify): ?><button type="button" class="hc-list-share <?= $shareToken!==''?'active':'' ?>" data-share-target="<?= e($row['rel']) ?>" data-share-name="<?= e($row['name']) ?>" data-share-url="<?= e($shareUrl) ?>" data-share-enabled="<?= $shareToken!==''?'1':'0' ?>" title="Доступ"><i class="fa-solid <?= $shareToken!==''?'fa-link':'fa-lock' ?>"></i></button><?php endif; ?><a class="hc-icon-btn" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$row['rel']])) ?>" title="Скачать"><i class="fa-solid fa-download"></i></a><?php endif; ?><?php if($canModify): ?><button type="button" class="hc-icon-btn danger" data-delete-target="<?= e($row['rel']) ?>" data-delete-name="<?= e($row['name']) ?>" title="Удалить"><i class="fa-regular fa-trash-can"></i></button><?php endif; ?></div></div>
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
  <form method="post" enctype="multipart/form-data" id="hcUploadForm" action="/api/upload.php">
    <input type="hidden" name="action" value="upload"><input type="hidden" name="space" value="<?= e(hc_space()) ?>"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>">
    <div class="hc-dialog-head"><div><span>Загрузка</span><b>Добавить файлы в облако</b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div>
    <div class="hc-dialog-body">
      <label class="hc-field"><span>Куда загрузить</span><select name="upload_target" id="hcUploadTarget"><option value=""<?= $rel===''?' selected':'' ?>><?= hc_space()==='shared'?'👥 Общая папка':'☁ Корень облака' ?></option><?php foreach($folderTree as $folder): $fpath=(string)$folder['path']; ?><option value="<?= e($fpath) ?>"<?= $fpath===$rel?' selected':'' ?>><?= e(str_repeat('— ',min((int)$folder['depth']+1,10)).$folder['name'].($fpath===$rel?' · текущая':'')) ?></option><?php endforeach; ?></select></label>
      <label class="hc-upload-zone" id="hcUploadZone"><input type="file" id="hcFilesInput" name="files[]" multiple hidden><span><i class="fa-solid fa-cloud-arrow-up"></i></span><b>Перетащите файлы сюда</b><p>или нажмите, чтобы выбрать с компьютера</p></label>
      <div class="hc-upload-queue" id="hcUploadQueue" hidden><div class="hc-upload-queue-head"><b id="hcQueueCount"></b><span id="hcQueueSize"></span></div><div id="hcQueueFiles"></div></div>
      <div class="hc-upload-progress" id="hcUploadProgress" hidden>
        <div class="hc-upload-progress-head"><span><i class="fa-solid fa-cloud-arrow-up"></i><b id="hcUploadStatus">Подготовка</b></span><strong id="hcUploadPercent">0%</strong></div>
        <div class="hc-upload-progress-track"><span id="hcUploadProgressBar"></span></div>
        <div class="hc-upload-progress-meta"><span id="hcUploadTransferred">0 B / 0 B</span><span id="hcUploadSpeed">—</span></div>
      </div>
    </div>
    <div class="hc-dialog-foot"><span></span><button type="submit" class="hc-btn primary" id="hcUploadSubmit" disabled><i class="fa-solid fa-cloud-arrow-up"></i>Загрузить</button></div>
  </form>
</dialog>

<dialog data-modal-lock="true" class="hc-dialog hc-small-dialog" id="folderDialog">
  <form method="post"><input type="hidden" name="action" value="mkdir"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>"><div class="hc-dialog-head"><div><span>Новая папка</span><b>Создать в <?= e($rel!==''?'/'.$rel:'корне облака') ?></b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div><div class="hc-dialog-body"><label class="hc-field"><span>Название</span><input name="name" maxlength="180" placeholder="Например: Документы" autofocus required></label></div><div class="hc-dialog-foot"><span></span><button class="hc-btn primary">Создать</button></div></form>
</dialog>

<dialog data-modal-lock="true" class="hc-dialog hc-small-dialog" id="renameDialog">
  <form method="post"><input type="hidden" name="action" value="rename"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($rel) ?>"><input type="hidden" name="target" id="hcRenameTarget"><div class="hc-dialog-head"><div><span>Переименование</span><b>Новое имя</b></div><button type="button" class="hc-modal-close" data-close-dialog aria-label="Закрыть" title="Закрыть"><i class="fa-solid fa-xmark"></i></button></div><div class="hc-dialog-body"><label class="hc-field"><span>Имя</span><input name="new_name" id="hcRenameName" maxlength="180" required></label></div><div class="hc-dialog-foot"><span></span><button class="hc-btn primary">Сохранить</button></div></form>
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

<?php if($previewPath): $previewCanModify=hc_can_modify($previewRel); $mime=hc_mime($previewPath); $previewIsArchive=hc_is_archive($previewPath); $previewIsHtml=!$previewIsArchive && hc_is_html_name($previewPath); $previewIsText=!$previewIsArchive && hc_is_text($previewPath) && hc_is_editable_text_name(basename($previewPath)) ; ?>
<div class="hc-preview-backdrop" id="hcPreview" data-preview-open>
  <section class="hc-preview-panel<?= $previewIsArchive?' is-archive':'' ?><?= ($editText || $archiveEntry!=='')?' is-editor':'' ?>">
    <header><div><span><?= ($editText || $archiveEntry!=='')?'Редактор':'Просмотр' ?></span><b><?= e($archiveEntry!==''?basename($archiveEntry):basename($previewPath)) ?></b><small><?= $archiveEntry!=='' ? e(basename($previewPath)) : e(human_bytes((float)(filesize($previewPath)?:0))) ?></small></div><div><?php $previewShare=$shareByPath[$previewRel]??null; $previewShareToken=is_array($previewShare)?(string)($previewShare['token']??''):''; ?><?php if($previewIsHtml && !$editText): ?><a class="hc-btn soft" target="_blank" rel="noopener" href="<?= e('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$previewRel],'','&',PHP_QUERY_RFC3986)) ?>"><i class="fa-solid fa-arrow-up-right-from-square"></i>Открыть</a><?php endif; ?><?php if($previewIsText && !$editText && $previewCanModify): ?><a class="hc-btn soft" href="<?= e('/editor.php?'.http_build_query(['space'=>hc_space(),'path'=>$previewRel],'','&',PHP_QUERY_RFC3986)) ?>"><i class="fa-solid fa-code"></i>Редактировать</a><?php endif; ?><?php if($archiveEntry==='' && $previewCanModify): ?><button type="button" class="hc-btn <?= $previewShareToken!==''?'share-on':'soft' ?>" data-share-target="<?= e($previewRel) ?>" data-share-name="<?= e(basename($previewPath)) ?>" data-share-url="<?= e($previewShareToken!==''?hc_public_share_url($previewShareToken):'') ?>" data-share-enabled="<?= $previewShareToken!==''?'1':'0' ?>"><i class="fa-solid <?= $previewShareToken!==''?'fa-link':'fa-lock' ?>"></i>Доступ</button><a class="hc-btn soft" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$previewRel])) ?>"><i class="fa-solid fa-download"></i>Скачать</a><button type="button" class="hc-btn danger-soft hc-preview-delete" data-delete-target="<?= e($previewRel) ?>" data-delete-name="<?= e(basename($previewPath)) ?>"><i class="fa-regular fa-trash-can"></i>Удалить</button><?php endif; ?><?php if($archiveEntry==='' && !$previewCanModify): ?><a class="hc-btn soft" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$previewRel])) ?>"><i class="fa-solid fa-download"></i>Скачать</a><?php endif; ?><a class="hc-preview-close" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$archiveEntry!==''?$previewRel:null],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-xmark"></i></a></div></header>
    <div class="hc-preview-body<?= $previewIsArchive?' is-archive':'' ?><?= ($editText || $archiveEntry!=='')?' is-editor':'' ?>">
      <?php if($previewIsArchive && $archiveEntry!==''): ?>
        <?php if($archiveEntryError!==''): ?><div class="hc-preview-fallback"><i class="fa-solid fa-triangle-exclamation"></i><b>Не удалось открыть файл</b><p><?= e($archiveEntryError) ?></p><a class="hc-btn soft" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-arrow-left"></i>К архиву</a></div>
        <?php else: $archiveWritable=$previewCanModify&&(bool)($archiveEntryData['writable']??false); $archiveContent=(string)($archiveEntryData['content']??''); ?>
          <form method="post" class="hc-editor-form" data-editor-form><input type="hidden" name="action" value="archive_save"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="return_view" value="<?= e($view) ?>"><input type="hidden" name="target" value="<?= e($previewRel) ?>"><input type="hidden" name="archive_entry" value="<?= e($archiveEntry) ?>">
            <div class="hc-editor-toolbar"><a class="hc-editor-back" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-arrow-left"></i>Архив</a><?php if(hc_is_html_name($archiveEntry)): ?><a class="hc-editor-site" target="_blank" rel="noopener" href="<?= e('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$previewRel,'entry'=>$archiveEntry],'','&',PHP_QUERY_RFC3986)) ?>"><i class="fa-solid fa-globe"></i>Открыть сайт</a><?php endif; ?><div><span class="hc-editor-lang"><?= e(strtoupper(pathinfo($archiveEntry,PATHINFO_EXTENSION) ?: 'TXT')) ?></span><span id="hcEditorLines">1 строка</span></div><?php if($archiveWritable): ?><button class="hc-btn primary" type="submit"><i class="fa-solid fa-floppy-disk"></i>Сохранить</button><?php else: ?><span class="hc-editor-readonly"><i class="fa-solid fa-lock"></i>Только чтение</span><?php endif; ?></div>
            <textarea class="hc-code-editor" name="content" spellcheck="false" autocomplete="off" autocapitalize="off" <?= $archiveWritable?'':'readonly' ?>><?= e($archiveContent) ?></textarea>
          </form>
        <?php endif; ?>
      <?php elseif($previewIsArchive): $archive=hc_archive_entries($previewPath,0); $archiveWritable=$previewCanModify&&hc_archive_writer($previewPath)!==''; ?>
        <?php if(!empty($archive['ok'])): ?>
          <div class="hc-archive-head"><span class="hc-archive-main-icon"><i class="fa-solid fa-file-zipper"></i></span><div><b><?= e(basename($previewPath)) ?></b><span><?= count($archive['entries']) ?> элементов</span></div></div>
          <div class="hc-archive-table"><table><thead><tr><th>Имя</th><th>Размер</th><th>Изменён</th><th></th></tr></thead><tbody>
          <?php foreach($archive['entries'] as $entry):
            $entryName=(string)($entry['name']??''); $entryDir=str_ends_with($entryName,'/');
            try{$entryCanonical=$entryDir?'':hc_archive_entry_clean($entryName);}catch(Throwable){$entryCanonical='';}
            $canEdit=$previewCanModify&&$entryCanonical!==''&&hc_is_editable_text_name($entryCanonical);
            $entryIsHtml=$entryCanonical!==''&&hc_is_html_name($entryCanonical);
            $entryEditHref=$canEdit?('/editor.php?'.http_build_query(['space'=>hc_space(),'path'=>$previewRel,'entry'=>$entryCanonical],'','&',PHP_QUERY_RFC3986)):'';
            $entrySiteHref=$entryIsHtml?('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$previewRel,'entry'=>$entryCanonical],'','&',PHP_QUERY_RFC3986)):'';
          ?>
          <tr><td>
            <?php if($entryIsHtml): ?><a class="hc-archive-open" target="_blank" rel="noopener" href="<?= e($entrySiteHref) ?>">
            <?php elseif($canEdit): ?><a class="hc-archive-open" href="<?= e($entryEditHref) ?>"><?php endif; ?>
            <span class="hc-archive-entry-icon"><i class="fa-solid <?= e(hc_archive_entry_icon($entryName)) ?>"></i></span><b><?= e($entryName) ?></b>
            <?php if($entryIsHtml||$canEdit): ?></a><?php endif; ?>
          </td><td><?= $entryDir?'—':e(human_bytes((float)($entry['size']??0))) ?></td><td><?= e((string)($entry['modified']??'—')) ?></td><td><div class="hc-archive-actions">
            <?php if($entryIsHtml): ?><a class="hc-archive-edit-btn" target="_blank" rel="noopener" href="<?= e($entrySiteHref) ?>" title="Открыть как сайт"><i class="fa-solid fa-globe"></i></a><?php endif; ?>
            <?php if($canEdit): ?><a class="hc-archive-edit-btn" href="<?= e($entryEditHref) ?>" title="Редактировать код"><i class="fa-solid fa-code"></i></a><?php endif; ?>
          </div></td></tr>
          <?php endforeach; ?></tbody></table></div>
          <?php if(!empty($archive['truncated'])): ?><div class="hc-preview-note">Архив очень большой — показана первая часть списка.</div><?php endif; ?>
        <?php else: ?><div class="hc-preview-fallback"><i class="fa-solid fa-file-circle-xmark"></i><b>Не удалось открыть архив</b><p><?= e((string)($archive['error']??'')) ?></p></div><?php endif; ?>
      <?php elseif($previewIsText && $editText && $previewCanModify): $txt=@file_get_contents($previewPath); ?>
        <form method="post" class="hc-editor-form" data-editor-form><input type="hidden" name="action" value="save_text"><?= hc_csrf_field() ?><input type="hidden" name="path" value="<?= e($view==='disk'?$rel:'') ?>"><input type="hidden" name="return_view" value="<?= e($view) ?>"><input type="hidden" name="target" value="<?= e($previewRel) ?>"><div class="hc-editor-toolbar"><a class="hc-editor-back" href="<?= e(hc_url(array_filter(['path'=>$view==='disk'?$rel:null,'view'=>$view!=='disk'?$view:null,'preview'=>$previewRel],static fn($v)=>$v!==null))) ?>"><i class="fa-solid fa-arrow-left"></i>Просмотр</a><?php if($previewIsHtml): ?><a class="hc-editor-site" target="_blank" rel="noopener" href="<?= e('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$previewRel],'','&',PHP_QUERY_RFC3986)) ?>"><i class="fa-solid fa-globe"></i>Открыть сайт</a><?php endif; ?><div><span class="hc-editor-lang"><?= e(strtoupper(pathinfo($previewPath,PATHINFO_EXTENSION) ?: 'TXT')) ?></span><span id="hcEditorLines">1 строка</span></div><button class="hc-btn primary" type="submit"><i class="fa-solid fa-floppy-disk"></i>Сохранить</button></div><textarea class="hc-code-editor" name="content" spellcheck="false" autocomplete="off" autocapitalize="off"><?= e(is_string($txt)?$txt:'') ?></textarea></form>
      <?php elseif($previewIsHtml): ?>
        <div class="hc-html-site-preview">
          <div class="hc-html-browserbar"><span class="hc-html-dots"><i></i><i></i><i></i></span><div class="hc-html-address"><i class="fa-solid fa-lock"></i><span>/<?= e($previewRel) ?></span></div><button type="button" class="hc-html-refresh" data-html-refresh title="Обновить предпросмотр"><i class="fa-solid fa-rotate-right"></i></button></div>
          <iframe class="hc-html-frame" id="hcHtmlFrame" sandbox="allow-scripts allow-forms allow-modals allow-popups allow-downloads" referrerpolicy="no-referrer" src="<?= e('/site.php?'.http_build_query(['space'=>hc_space(),'path'=>$previewRel],'','&',PHP_QUERY_RFC3986)) ?>" title="Предпросмотр <?= e(basename($previewPath)) ?>"></iframe>
        </div>
      <?php elseif(str_starts_with($mime,'image/')): ?><img class="hc-preview-image" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>" alt="">
      <?php elseif($mime==='application/pdf'): ?><iframe class="hc-preview-frame" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></iframe>
      <?php elseif(str_starts_with($mime,'video/')): ?><video class="hc-preview-media" controls preload="metadata" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></video>
      <?php elseif(str_starts_with($mime,'audio/')): ?><div class="hc-audio-wrap"><audio controls preload="metadata" src="<?= e(hc_url(['cloud_action'=>'raw','path'=>$previewRel])) ?>"></audio></div>
      <?php elseif($previewIsText): $txt=@file_get_contents($previewPath); ?><pre class="hc-code-preview"><?= e(is_string($txt)?$txt:'') ?></pre>
      <?php else: ?><div class="hc-preview-fallback"><i class="fa-solid fa-file-arrow-down"></i><b>Предпросмотр недоступен</b><a class="hc-btn primary" href="<?= e(hc_url(['cloud_action'=>'download','path'=>$previewRel])) ?>">Скачать файл</a></div><?php endif; ?>
    </div>
  </section>
</div>
<?php endif; ?>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/js/bootstrap.bundle.min.js" integrity="sha384-FKyoEForCGlyvwx9Hj09JcYn3nv7wiPVlz7YYwJrWVcXK/BmnVDxM+D2scQbITxI" crossorigin="anonymous" defer></script>
<script src="/cloud.js?v=107" defer></script>
</body>
</html>
