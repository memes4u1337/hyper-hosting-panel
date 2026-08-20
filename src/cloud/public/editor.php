<?php
declare(strict_types=1);
require __DIR__.'/../app/bootstrap.php';
require __DIR__.'/../app/filelib.php';
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: private, no-store, max-age=0');
header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()');
header("Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; font-src 'self' https://cdnjs.cloudflare.com data:; img-src 'self' data:; frame-ancestors 'self'; base-uri 'none'; form-action 'self'");

$user=require_auth();
$space=hcfl_space((string)($_GET['space']??$_POST['space']??'private'));
$rel='';$entry='';$content='';$error='';$saved=false;$readonly=false;$path='';$isArchive=false;
try{
    $rel=hcfl_clean_rel((string)($_GET['path']??$_POST['path']??''));
    if($rel==='')throw new RuntimeException('Файл не выбран');
    [,,$path]=hcfl_resolve($user,$space,$rel,true);if(!is_file($path))throw new RuntimeException('Файл не найден');
    $entry=trim((string)($_GET['entry']??$_POST['entry']??''));$isArchive=$entry!=='';
    $readonly=!hcfl_can_modify($user,$space,$rel);
    if($_SERVER['REQUEST_METHOD']==='POST'){
        check_csrf();if($readonly)throw new RuntimeException('Нет прав на изменение файла');
        $new=(string)($_POST['content']??'');
        if($isArchive){$entry=hcfl_entry_clean($entry);hcfl_archive_write($path,$entry,$new);$content=(string)hcfl_archive_read_bytes($path,$entry,67108864)['content'];}
        else{if(!hcfl_editable_name(basename($path)))throw new RuntimeException('Этот тип файла нельзя редактировать');hcfl_write_text($path,$new);$content=hcfl_read_text($path);}
        $saved=true;add_event('cloud','Изменён файл: '.$rel.($isArchive?' → '.$entry:''));
    } else {
        if($isArchive){$entry=hcfl_entry_clean($entry);if(!hcfl_editable_name($entry))throw new RuntimeException('Этот тип файла нельзя редактировать');$content=(string)hcfl_archive_read_bytes($path,$entry,67108864)['content'];if(str_contains($content,"\0"))throw new RuntimeException('Бинарный файл нельзя редактировать');}
        else{$content=hcfl_read_text($path);}
    }
}catch(Throwable $e){$error=$e->getMessage();http_response_code(400);}
$name=$entry!==''?basename($entry):($path!==''?basename($path):'Редактор');$ext=strtolower(pathinfo($name,PATHINFO_EXTENSION));$lang=strtoupper($ext!==''?$ext:'TXT');$siteHref='';
if($error===''&&hcfl_html_name($name)){$q=['space'=>$space,'path'=>$rel];if($entry!=='')$q['entry']=$entry;$siteHref='/site.php?'.http_build_query($q,'','&',PHP_QUERY_RFC3986);}
$return='/?'.http_build_query(array_filter(['space'=>$space==='shared'?'shared':null,'preview'=>$rel],fn($v)=>$v!==null),'','&',PHP_QUERY_RFC3986);
?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=e($name)?> — HYPER CLOUD</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css"><link rel="stylesheet" href="/cloud.css?v=109">
<style>
body.hc-editor-page{background:#0b1020;color:#e8eefc;min-height:100vh;overflow:hidden}.hc-code-shell{height:100vh;display:flex;flex-direction:column}.hc-code-top{height:72px;display:flex;align-items:center;gap:14px;padding:0 22px;border-bottom:1px solid rgba(255,255,255,.08);background:rgba(13,19,37,.96);backdrop-filter:blur(20px)}.hc-code-back,.hc-code-action{height:42px;display:inline-flex;align-items:center;gap:9px;padding:0 14px;border-radius:13px;border:1px solid rgba(255,255,255,.09);color:#e8eefc;text-decoration:none;background:rgba(255,255,255,.05)}.hc-code-action.primary{background:linear-gradient(135deg,#4f6cff,#725bff);border:0;box-shadow:0 10px 28px rgba(79,108,255,.28)}.hc-code-title{min-width:0;flex:1}.hc-code-title b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:15px}.hc-code-title span{display:block;color:#8290ad;font-size:12px;margin-top:2px}.hc-code-badge{padding:7px 10px;border-radius:9px;background:rgba(92,115,255,.14);color:#aebaff;font:700 11px/1 ui-monospace,SFMono-Regular,Menlo,monospace}.hc-editor-area{position:relative;flex:1;min-height:0;background:#0a0f1d}.hc-editor-area textarea{width:100%;height:100%;resize:none;border:0;outline:0;padding:24px 30px 80px;background:#0a0f1d;color:#e8eefc;font:14px/1.7 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;tab-size:4;caret-color:#8da0ff}.hc-editor-area textarea::selection{background:#334bb8}.hc-editor-status{position:absolute;right:18px;bottom:16px;display:flex;gap:8px;pointer-events:none}.hc-editor-status span{padding:7px 10px;border-radius:9px;background:rgba(18,26,48,.9);border:1px solid rgba(255,255,255,.07);font-size:11px;color:#8997b5}.hc-editor-alert{margin:22px;border-radius:18px;padding:18px 20px;background:#301824;border:1px solid #6f293e;color:#ffc4d0}.hc-editor-ok{position:fixed;right:22px;top:88px;z-index:5;padding:12px 15px;border-radius:13px;background:#12392d;border:1px solid #2f7f63;color:#a7f1d5;box-shadow:0 14px 35px rgba(0,0,0,.25)}@media(max-width:700px){.hc-code-top{padding:0 10px}.hc-code-action span,.hc-code-back span{display:none}.hc-editor-area textarea{padding:18px 16px 70px}}
</style></head><body class="hc-editor-page">
<?php if($saved):?><div class="hc-editor-ok"><i class="fa-solid fa-circle-check me-2"></i>Сохранено</div><?php endif;?>
<div class="hc-code-shell"><header class="hc-code-top"><a class="hc-code-back" href="<?=e($return)?>"><i class="fa-solid fa-arrow-left"></i><span>Назад</span></a><div class="hc-code-title"><b><?=e($name)?></b><span><?=e($entry!==''?basename($rel).' / '.$entry:$rel)?></span></div><span class="hc-code-badge"><?=e($lang)?></span><?php if($siteHref!==''):?><a class="hc-code-action" target="_blank" rel="noopener" href="<?=e($siteHref)?>"><i class="fa-solid fa-display"></i><span>Открыть сайт</span></a><?php endif;?><?php if(!$readonly&&$error===''):?><button form="hcEditForm" class="hc-code-action primary" type="submit"><i class="fa-solid fa-floppy-disk"></i><span>Сохранить</span></button><?php endif;?></header>
<?php if($error!==''):?><div class="hc-editor-alert"><b><i class="fa-solid fa-triangle-exclamation me-2"></i>Не удалось открыть редактор</b><div class="mt-2"><?=e($error)?></div></div><?php else:?><form id="hcEditForm" method="post" class="hc-editor-area"><input type="hidden" name="_csrf" value="<?=e(csrf_token())?>"><input type="hidden" name="space" value="<?=e($space)?>"><input type="hidden" name="path" value="<?=e($rel)?>"><?php if($entry!==''):?><input type="hidden" name="entry" value="<?=e($entry)?>"><?php endif;?><textarea id="hcCode" name="content" spellcheck="false" autocomplete="off" autocapitalize="off" <?=$readonly?'readonly':''?>><?=e($content)?></textarea><div class="hc-editor-status"><span id="hcLineInfo">1 строка</span><span><?=$readonly?'Только чтение':'Ctrl+S — сохранить'?></span></div></form><?php endif;?></div>
<script>const ta=document.getElementById('hcCode'),form=document.getElementById('hcEditForm'),info=document.getElementById('hcLineInfo');function upd(){if(!ta||!info)return;const n=(ta.value.match(/\n/g)||[]).length+1;info.textContent=n+' '+(n%10===1&&n%100!==11?'строка':'строк')}if(ta){upd();ta.addEventListener('input',upd);ta.addEventListener('keydown',e=>{if(e.key==='Tab'){e.preventDefault();const a=ta.selectionStart,b=ta.selectionEnd;ta.setRangeText('    ',a,b,'end')}if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='s'&&form){e.preventDefault();form.requestSubmit()}})}setTimeout(()=>document.querySelector('.hc-editor-ok')?.remove(),2300);</script></body></html>
