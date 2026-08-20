<?php
declare(strict_types=1);

/** HYPER CLOUD v108 — isolated file/editor/preview helpers. */

function hcfl_space(?string $space): string { return $space === 'shared' ? 'shared' : 'private'; }
function hcfl_clean_rel(string $value): string
{
    $value = str_replace("\0", '', str_replace('\\', '/', trim($value)));
    $parts=[];
    foreach (explode('/', $value) as $part) {
        if ($part==='' || $part==='.') continue;
        if ($part==='..' || preg_match('/[\x00-\x1F\x7F]/u',$part)) throw new RuntimeException('Недопустимый путь');
        $parts[]=$part;
    }
    return implode('/',$parts);
}
function hcfl_root(array $user,string $space): string
{
    $space=hcfl_space($space); hc_ensure_user_root($user); $root=hc_root_for_user($user,$space);
    if(!is_dir($root) && !@mkdir($root,02770,true) && !is_dir($root)) throw new RuntimeException('Хранилище недоступно');
    return $root;
}
function hcfl_resolve(array $user,string $space,string $rel,bool $mustExist=true): array
{
    $root=hcfl_root($user,$space);$rel=hcfl_clean_rel($rel);$rootReal=realpath($root)?:$root;$path=$root.($rel!==''?'/'.$rel:'');
    if($mustExist && !file_exists($path) && !is_link($path)) throw new RuntimeException('Файл не найден');
    if(file_exists($path)||is_link($path)) {
        if(is_link($path)) throw new RuntimeException('Символические ссылки запрещены');
        $real=realpath($path); if($real===false || ($real!==$rootReal && !str_starts_with($real,$rootReal.DIRECTORY_SEPARATOR))) throw new RuntimeException('Недопустимый путь');
    } else {
        $parent=realpath(dirname($path)); if($parent===false || ($parent!==$rootReal && !str_starts_with($parent,$rootReal.DIRECTORY_SEPARATOR))) throw new RuntimeException('Недопустимый путь');
    }
    return [$root,$rel,$path];
}
function hcfl_can_modify(array $user,string $space,string $rel): bool
{
    if(hcfl_space($space)==='private') return true;
    if(hc_is_panel_admin($user)) return true;
    return hc_shared_owner(hcfl_clean_rel($rel)) === (int)$user['id'];
}
function hcfl_assert_modify(array $user,string $space,string $rel): void
{
    if(!hcfl_can_modify($user,$space,$rel)) throw new RuntimeException('Недостаточно прав для изменения файла');
}
function hcfl_editable_name(string $name): bool
{
    if(str_ends_with($name,'/')) return false;
    $ext=strtolower(pathinfo($name,PATHINFO_EXTENSION));
    return in_array($ext,['txt','log','md','json','xml','csv','ini','env','conf','yml','yaml','php','phtml','py','js','mjs','cjs','ts','tsx','jsx','css','scss','sass','less','html','htm','sql','sh','bash','zsh','bat','ps1','c','cpp','h','hpp','java','go','rs','vue','svelte','twig','tpl'],true)
        || in_array(strtolower(basename($name)),['.env','.htaccess','.gitignore','dockerfile','makefile'],true);
}
function hcfl_html_name(string $name): bool { return in_array(strtolower(pathinfo($name,PATHINFO_EXTENSION)),['html','htm'],true); }
function hcfl_archive_name(string $name): bool
{
    $n=strtolower($name);foreach(['.zip','.rar','.7z','.tar','.tar.gz','.tgz','.tar.bz2','.tbz2','.tar.xz','.txz'] as $e)if(str_ends_with($n,$e))return true;return false;
}
function hcfl_entry_clean(string $entry): string
{
    $entry=str_replace('\\','/',str_replace("\0",'',trim($entry)));
    if($entry===''||str_starts_with($entry,'/')||preg_match('/^[A-Za-z]:\//',$entry)) throw new RuntimeException('Недопустимый путь внутри архива');
    $parts=[];foreach(explode('/',$entry) as $p){if($p===''||$p==='.')continue;if($p==='..'||preg_match('/[\x00-\x1F\x7F]/u',$p))throw new RuntimeException('Недопустимый путь внутри архива');$parts[]=$p;}
    if(!$parts)throw new RuntimeException('Файл внутри архива не найден');return implode('/',$parts);
}
function hcfl_capture(array $argv,int $limit=0,?string $cwd=null): array
{
    if(!function_exists('proc_open')) throw new RuntimeException('Архиватор недоступен');
    $spec=[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']];$p=@proc_open($argv,$spec,$pipes,$cwd,['PATH'=>'/usr/sbin:/usr/bin:/sbin:/bin']);
    if(!is_resource($p)) throw new RuntimeException('Не удалось запустить архиватор');fclose($pipes[0]);
    $out=$limit>0?stream_get_contents($pipes[1],$limit+1):stream_get_contents($pipes[1]);fclose($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[2]);$code=proc_close($p);
    return ['ok'=>$code===0,'data'=>is_string($out)?$out:'','error'=>trim((string)$err),'code'=>$code];
}
function hcfl_archive_entries(string $archive,int $limit=0): array
{
    $rows=[];$lower=strtolower($archive);
    if(str_ends_with($lower,'.zip') && class_exists('ZipArchive')){
        $z=new ZipArchive();if($z->open($archive)===true){for($i=0;$i<$z->numFiles;$i++){if($limit>0&&count($rows)>=$limit)break;$s=$z->statIndex($i);if(!is_array($s))continue;$rows[]=['name'=>(string)($s['name']??''),'size'=>(int)($s['size']??0),'modified'=>isset($s['mtime'])?date('d.m.Y H:i',(int)$s['mtime']):'—'];}$z->close();return ['ok'=>true,'entries'=>$rows,'truncated'=>$limit>0&&count($rows)>=$limit];}
    }
    $bin=is_executable('/usr/bin/7z')?'/usr/bin/7z':(is_executable('/usr/bin/7zz')?'/usr/bin/7zz':'');
    if($bin!==''){
        $r=hcfl_capture([$bin,'l','-slt','-bd',$archive]);if($r['ok']){
            $cur=[];foreach(preg_split('/\R/',(string)$r['data'])?:[] as $line){if(trim($line)===''){if(isset($cur['Path'])&&$cur['Path']!==$archive){$name=(string)$cur['Path'];$rows[]=['name'=>$name,'size'=>(int)($cur['Size']??0),'modified'=>(string)($cur['Modified']??'—')];if($limit>0&&count($rows)>=$limit)break;}$cur=[];continue;}if(preg_match('/^([^=]+) = (.*)$/',$line,$m))$cur[trim($m[1])]=$m[2];}
            if(isset($cur['Path'])&&$cur['Path']!==$archive&&($limit===0||count($rows)<$limit))$rows[]=['name'=>(string)$cur['Path'],'size'=>(int)($cur['Size']??0),'modified'=>(string)($cur['Modified']??'—')];
            if($rows)return ['ok'=>true,'entries'=>$rows,'truncated'=>$limit>0&&count($rows)>=$limit];
        }
    }
    if(is_executable('/usr/bin/bsdtar')){
        $r=hcfl_capture(['/usr/bin/bsdtar','-tf',$archive]);if($r['ok']){foreach(preg_split('/\R/',trim((string)$r['data']))?:[] as $name){if($name==='')continue;$rows[]=['name'=>$name,'size'=>0,'modified'=>'—'];if($limit>0&&count($rows)>=$limit)break;}if($rows)return ['ok'=>true,'entries'=>$rows,'truncated'=>$limit>0&&count($rows)>=$limit];}
    }
    return ['ok'=>false,'entries'=>[],'truncated'=>false];
}
function hcfl_archive_lookup(string $archive,string $entry): array
{
    $canonical=hcfl_entry_clean($entry);$lower=strtolower($archive);
    if(str_ends_with($lower,'.zip')&&class_exists('ZipArchive')){$z=new ZipArchive();if($z->open($archive)===true){for($i=0;$i<$z->numFiles;$i++){$s=$z->statIndex($i);if(!is_array($s))continue;$raw=(string)($s['name']??'');if($raw===''||str_ends_with($raw,'/'))continue;try{$c=hcfl_entry_clean($raw);}catch(Throwable){continue;}if($c===$canonical){$ret=['canonical'=>$canonical,'actual'=>$raw,'size'=>(int)($s['size']??0),'index'=>$i];$z->close();return $ret;}}$z->close();}}
    $list=hcfl_archive_entries($archive,0);foreach($list['entries']??[] as $row){$raw=(string)($row['name']??'');if($raw===''||str_ends_with($raw,'/'))continue;try{$c=hcfl_entry_clean($raw);}catch(Throwable){continue;}if($c===$canonical)return ['canonical'=>$canonical,'actual'=>$raw,'size'=>(int)($row['size']??0),'index'=>null];}
    throw new RuntimeException('Файл внутри архива не найден');
}
function hcfl_archive_read_bytes(string $archive,string $entry,int $limit=0): array
{
    $f=hcfl_archive_lookup($archive,$entry);$actual=(string)$f['actual'];$canonical=(string)$f['canonical'];$lower=strtolower($archive);
    if(str_ends_with($lower,'.zip')&&class_exists('ZipArchive')){$z=new ZipArchive();if($z->open($archive)===true){$stream=$z->getStream($actual);if(is_resource($stream)){$data=$limit>0?stream_get_contents($stream,$limit+1):stream_get_contents($stream);fclose($stream);$z->close();if(!is_string($data))$data='';if($limit>0&&strlen($data)>$limit)throw new RuntimeException('Файл слишком большой для этой операции');return ['content'=>$data,'entry'=>$canonical,'actual'=>$actual,'size'=>strlen($data)];}$z->close();}}
    $tries=[];if(str_ends_with($lower,'.zip')&&is_executable('/usr/bin/unzip'))$tries[]=['/usr/bin/unzip','-p',$archive,$actual];
    if(is_executable('/usr/bin/7z'))$tries[]=['/usr/bin/7z','x','-so','-bd','-y',$archive,$actual];if(is_executable('/usr/bin/7zz'))$tries[]=['/usr/bin/7zz','x','-so','-bd','-y',$archive,$actual];if(is_executable('/usr/bin/bsdtar'))$tries[]=['/usr/bin/bsdtar','-xOf',$archive,$actual];
    foreach($tries as $argv){$r=hcfl_capture($argv,$limit);if($r['ok']){$data=(string)$r['data'];if($limit>0&&strlen($data)>$limit)throw new RuntimeException('Файл слишком большой для этой операции');return ['content'=>$data,'entry'=>$canonical,'actual'=>$actual,'size'=>strlen($data)];}}
    throw new RuntimeException('Не удалось прочитать файл из архива');
}
function hcfl_archive_writer(string $archive): string
{
    $n=strtolower($archive);if(str_ends_with($n,'.zip')&&class_exists('ZipArchive'))return 'zip';if((str_ends_with($n,'.zip')||str_ends_with($n,'.7z'))&&is_executable('/usr/bin/7z'))return '7z';if((str_ends_with($n,'.zip')||str_ends_with($n,'.7z'))&&is_executable('/usr/bin/7zz'))return '7zz';if(str_ends_with($n,'.rar')&&is_executable('/usr/bin/rar'))return 'rar';return '';
}
function hcfl_rrmdir(string $dir): void { if(!is_dir($dir)){@unlink($dir);return;}foreach(scandir($dir)?:[] as $n){if($n==='.'||$n==='..')continue;$p=$dir.'/'.$n;is_dir($p)&&!is_link($p)?hcfl_rrmdir($p):@unlink($p);}@rmdir($dir); }
function hcfl_archive_backup(string $archive): string
{
    $dir=rtrim((string)app_config('cloud_meta_dir','/var/lib/hyper-host-cloud'),'/').'/archive-backups';if(!is_dir($dir))@mkdir($dir,02770,true);
    $backup=$dir.'/'.date('Ymd-His').'-'.substr(hash('sha256',$archive.microtime(true)),0,10).'-'.basename($archive);$ok=false;
    if(is_executable('/usr/bin/cp')){$r=hcfl_capture(['/usr/bin/cp','--reflink=always','--preserve=mode,timestamps',$archive,$backup]);$ok=$r['ok']&&is_file($backup);}
    if(!$ok){$size=(float)(@filesize($archive)?:0);$free=(float)(@disk_free_space($dir)?:0);if($size<=0||$free>$size+128*1024*1024)$ok=@copy($archive,$backup);}
    if(!$ok){@unlink($backup);return '';}@chmod($backup,0660);$all=glob($dir.'/*')?:[];usort($all,fn($a,$b)=>(@filemtime($b)?:0)<=>(@filemtime($a)?:0));foreach(array_slice($all,20) as $old)@unlink($old);return $backup;
}
function hcfl_archive_write(string $archive,string $entry,string $content): void
{
    $entry=hcfl_entry_clean($entry);if(!hcfl_editable_name($entry)||str_contains($content,"\0"))throw new RuntimeException('Этот файл нельзя сохранить');$found=hcfl_archive_lookup($archive,$entry);$actual=(string)$found['actual'];$writer=hcfl_archive_writer($archive);if($writer==='')throw new RuntimeException('На сервере нет архиватора для записи этого формата');$backup=hcfl_archive_backup($archive);
    try{
        if($writer==='zip'){$z=new ZipArchive();if($z->open($archive)!==true)throw new RuntimeException('Не удалось открыть ZIP');$idx=$z->locateName($actual,0);if($idx===false){$z->close();throw new RuntimeException('Файл внутри ZIP не найден');}$tmp=tempnam((string)app_config('cloud_meta_dir','/var/lib/hyper-host-cloud'),'hc-edit-');if($tmp===false||file_put_contents($tmp,$content,LOCK_EX)===false){if($tmp)@unlink($tmp);$z->close();throw new RuntimeException('Не удалось подготовить изменения');}if(!$z->deleteIndex($idx)||!$z->addFile($tmp,$actual)){@unlink($tmp);$z->close();throw new RuntimeException('Не удалось обновить ZIP');}if(!$z->close()){@unlink($tmp);throw new RuntimeException('Не удалось сохранить ZIP');}@unlink($tmp);
        } else {$tmp=rtrim((string)app_config('cloud_meta_dir','/var/lib/hyper-host-cloud'),'/').'/tmp-edit-'.bin2hex(random_bytes(8));$fs=ltrim(str_replace('\\','/',$actual),'/');$target=$tmp.'/'.$fs;if(!@mkdir(dirname($target),0700,true)&&!is_dir(dirname($target)))throw new RuntimeException('Не удалось подготовить редактор');if(file_put_contents($target,$content,LOCK_EX)===false)throw new RuntimeException('Не удалось подготовить изменения');if($writer==='7z'||$writer==='7zz'){$bin=$writer==='7z'?'/usr/bin/7z':'/usr/bin/7zz';$r=hcfl_capture([$bin,'u','-y','-bd',$archive,$fs],0,$tmp);}else{$r=hcfl_capture(['/usr/bin/rar','u','-idq',$archive,$fs],0,$tmp);}hcfl_rrmdir($tmp);if(!$r['ok'])throw new RuntimeException('Архиватор не смог сохранить изменения');}
    }catch(Throwable $e){if($backup!==''&&is_file($backup))@copy($backup,$archive);throw $e;}
    @chmod($archive,0660);
}
function hcfl_read_text(string $path,int $max=67108864): string
{
    if(!is_file($path)||is_link($path)||!hcfl_editable_name(basename($path)))throw new RuntimeException('Файл нельзя открыть в редакторе');
    $size=(int)(@filesize($path)?:0);if($size>$max)throw new RuntimeException('Файл слишком большой для браузерного редактора');$data=@file_get_contents($path);if(!is_string($data))throw new RuntimeException('Не удалось прочитать файл');if(str_contains($data,"\0"))throw new RuntimeException('Бинарный файл нельзя редактировать');return $data;
}
function hcfl_write_text(string $path,string $content): void
{
    if(!is_file($path)||is_link($path)||!hcfl_editable_name(basename($path))||str_contains($content,"\0"))throw new RuntimeException('Файл нельзя сохранить');$tmp=dirname($path).'/.hc-edit-'.bin2hex(random_bytes(8));if(file_put_contents($tmp,$content,LOCK_EX)===false)throw new RuntimeException('Не удалось записать изменения');$mode=@fileperms($path);@chmod($tmp,is_int($mode)?($mode&0777):0660);if(!@rename($tmp,$path)){@unlink($tmp);throw new RuntimeException('Не удалось заменить файл');}
}
function hcfl_mime_name(string $name): string
{
    $ext=strtolower(pathinfo(parse_url($name,PHP_URL_PATH)?:$name,PATHINFO_EXTENSION));return match($ext){'html','htm'=>'text/html; charset=utf-8','css'=>'text/css; charset=utf-8','js','mjs','cjs'=>'application/javascript; charset=utf-8','json','map'=>'application/json; charset=utf-8','xml'=>'application/xml; charset=utf-8','jpg','jpeg'=>'image/jpeg','png'=>'image/png','gif'=>'image/gif','webp'=>'image/webp','svg'=>'image/svg+xml','ico'=>'image/x-icon','mp4'=>'video/mp4','webm'=>'video/webm','mp3'=>'audio/mpeg','ogg'=>'audio/ogg','wav'=>'audio/wav','woff'=>'font/woff','woff2'=>'font/woff2','ttf'=>'font/ttf','otf'=>'font/otf',default=>'application/octet-stream'};
}
function hcfl_web_asset_allowed(string $name): bool
{
    $ext=strtolower(pathinfo($name,PATHINFO_EXTENSION));return in_array($ext,['html','htm','css','js','mjs','cjs','json','map','xml','jpg','jpeg','png','gif','webp','svg','ico','avif','mp4','webm','mov','mp3','ogg','wav','woff','woff2','ttf','otf'],true);
}

function hcfl_b64u_encode(string $data): string { return rtrim(strtr(base64_encode($data),'+/','-_'),'='); }
function hcfl_b64u_decode(string $data): string|false { $s=strtr($data,'-_','+/');$pad=strlen($s)%4;if($pad)$s.=str_repeat('=',4-$pad);return base64_decode($s,true); }
function hcfl_preview_key(): string
{
    static $key=null;if(is_string($key)&&strlen($key)>=32)return $key;
    $dir=rtrim((string)app_config('cloud_meta_dir','/var/lib/hyper-host-cloud'),'/');if(!is_dir($dir))@mkdir($dir,02770,true);$file=$dir.'/preview.key';$raw=@file_get_contents($file);
    if(!is_string($raw)||strlen($raw)<32){$raw=random_bytes(48);if(@file_put_contents($file,$raw,LOCK_EX)===false)throw new RuntimeException('Не удалось создать ключ предпросмотра');@chmod($file,0600);}
    $key=$raw;return $key;
}
function hcfl_preview_token(array $payload,int $ttl=1800): string
{
    $payload['exp']=time()+max(60,min($ttl,7200));$payload['v']=1;$json=json_encode($payload,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);$body=hcfl_b64u_encode($json);$sig=hcfl_b64u_encode(hash_hmac('sha256',$body,hcfl_preview_key(),true));return $body.'.'.$sig;
}
function hcfl_preview_verify(string $token): array
{
    if(strlen($token)>4096||!str_contains($token,'.'))throw new RuntimeException('Ссылка предпросмотра недействительна');[$body,$sig]=explode('.',$token,2);$calc=hcfl_b64u_encode(hash_hmac('sha256',$body,hcfl_preview_key(),true));if(!hash_equals($calc,$sig))throw new RuntimeException('Ссылка предпросмотра недействительна');$raw=hcfl_b64u_decode($body);$data=is_string($raw)?json_decode($raw,true):null;if(!is_array($data)||(int)($data['exp']??0)<time())throw new RuntimeException('Ссылка предпросмотра устарела');return $data;
}
function hcfl_preview_resolve_url(string $baseRel,string $url,string $siteRoot=''): ?string
{
    $url=trim(html_entity_decode($url,ENT_QUOTES|ENT_HTML5,'UTF-8'));if($url===''||str_starts_with($url,'#')||str_starts_with($url,'//'))return null;if(preg_match('~^(?:data|blob|javascript|mailto|tel|about):~i',$url)||preg_match('~^[a-z][a-z0-9+.-]*:~i',$url))return null;
    $path=parse_url($url,PHP_URL_PATH);if(!is_string($path)||$path==='')return null;$path=rawurldecode($path);$root=hcfl_clean_rel($siteRoot);$base=hcfl_clean_rel($baseRel);
    $parts=str_starts_with($path,'/')?($root!==''?explode('/',$root):[]):($base!==''?explode('/',$base):[]);$min=$root!==''?count(explode('/',$root)):0;
    foreach(explode('/',str_replace('\\','/',$path)) as $p){if($p===''||$p==='.')continue;if($p==='..'){if(count($parts)>$min)array_pop($parts);else return null;continue;}if(preg_match('/[\x00-\x1F\x7F]/u',$p))return null;$parts[]=$p;}
    $full=implode('/',$parts);if($root!==''&&$full!==$root&&!str_starts_with($full,$root.'/'))return null;return $root!==''?(string)substr($full,strlen($root)+($full===$root?0:1)):$full;
}
function hcfl_preview_url(string $token,string $resource): string { return '/site-resource.php?t='.rawurlencode($token).'&r='.rawurlencode($resource); }
function hcfl_rewrite_css(string $css,string $currentRel,string $siteRoot,string $token): string
{
    $base=dirname($currentRel);if($base==='.')$base='';$fn=static function(array $m)use($base,$siteRoot,$token){$q=$m[1]??'';$u=trim((string)($m[2]??''));$r=hcfl_preview_resolve_url($base,$u,$siteRoot);return $r===null?$m[0]:'url('.$q.hcfl_preview_url($token,$r).$q.')';};
    $css=preg_replace_callback('~url\(\s*([\'\"]?)([^)\'\"]+)\1\s*\)~i',$fn,$css)??$css;
    $css=preg_replace_callback('~@import\s+([\'\"])([^\'\"]+)\1~i',static function(array $m)use($base,$siteRoot,$token){$r=hcfl_preview_resolve_url($base,(string)$m[2],$siteRoot);return $r===null?$m[0]:'@import '.$m[1].hcfl_preview_url($token,$r).$m[1];},$css)??$css;return $css;
}
function hcfl_rewrite_js(string $js,string $currentRel,string $siteRoot,string $token): string
{
    $base=dirname($currentRel);if($base==='.')$base='';$rewrite=static function(string $url)use($base,$siteRoot,$token){$r=hcfl_preview_resolve_url($base,$url,$siteRoot);return $r===null?$url:hcfl_preview_url($token,$r);};
    $js=preg_replace_callback('~\b(from\s*|import\s*\(\s*|import\s*)([\'\"])(\.{0,2}/[^\'\"]+)\2~',static function(array $m)use($rewrite){return $m[1].$m[2].$rewrite((string)$m[3]).$m[2];},$js)??$js;
    $js=preg_replace_callback('~\b(fetch|new\s+Worker)\s*\(\s*([\'\"])([^\'\"]+)\2~',static function(array $m)use($rewrite){return $m[1].'('.$m[2].$rewrite((string)$m[3]).$m[2];},$js)??$js;return $js;
}
function hcfl_rewrite_html(string $html,string $currentRel,string $siteRoot,string $token): string
{
    $base=dirname($currentRel);if($base==='.')$base='';
    $attrs='(?:src|href|poster|action|data-src)';
    $html=preg_replace_callback('~\b('.$attrs.')\s*=\s*([\'\"])(.*?)\2~is',static function(array $m)use($base,$siteRoot,$token){$url=(string)$m[3];$r=hcfl_preview_resolve_url($base,$url,$siteRoot);return $r===null?$m[0]:$m[1].'='.$m[2].hcfl_preview_url($token,$r).$m[2];},$html)??$html;
    $html=preg_replace_callback('~\bsrcset\s*=\s*([\'\"])(.*?)\1~is',static function(array $m)use($base,$siteRoot,$token){$items=[];foreach(explode(',',(string)$m[2]) as $part){$bits=preg_split('/\s+/',trim($part),2);$u=$bits[0]??'';$r=hcfl_preview_resolve_url($base,$u,$siteRoot);$items[]=($r===null?$u:hcfl_preview_url($token,$r)).(isset($bits[1])?' '.$bits[1]:'');}return 'srcset='.$m[1].implode(', ',$items).$m[1];},$html)??$html;
    $html=preg_replace_callback('~\bstyle\s*=\s*([\'\"])(.*?)\1~is',static function(array $m)use($currentRel,$siteRoot,$token){return 'style='.$m[1].hcfl_rewrite_css((string)$m[2],$currentRel,$siteRoot,$token).$m[1];},$html)??$html;
    return $html;
}
