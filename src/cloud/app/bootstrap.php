<?php
declare(strict_types=1);

/** HYPER CLOUD v104 standalone bootstrap. */
session_name('HYPERCLOUDSESSID');
session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/',
    'domain' => '',
    'secure' => (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off'),
    'httponly' => true,
    'samesite' => 'Lax',
]);
session_start();
date_default_timezone_set('Europe/Moscow');

$hcConfig = [
    'storage_root' => '/var/www/hyper-host-cloud',
    'cloud_meta_dir' => '/var/lib/hyper-host-cloud',
    'cloud_db_path' => '/var/lib/hyper-host-cloud/cloud.sqlite',
    'panel_config' => '/var/www/hyper-host/app/config.php',
    'panel_url' => 'https://panel.hyper-host.pw',
    'cloud_url' => 'https://cloud.hyper-host.pw',
];
$externalConfig = '/etc/hyper-host/cloud.php';
if (is_file($externalConfig)) {
    $extra = require $externalConfig;
    if (is_array($extra)) $hcConfig = array_replace($hcConfig, $extra);
}

function app_config(?string $key = null, mixed $default = null): mixed
{
    global $hcConfig;
    if ($key === null) return $hcConfig;
    if ($key === 'cloud_dir') return $hcConfig['storage_root'] ?? $default;
    return $hcConfig[$key] ?? $default;
}
function e(?string $value): string { return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function redirect(string $path): never { header('Location: '.$path); exit; }
function human_bytes(float $bytes): string {
    $units=['B','KB','MB','GB','TB']; $i=0;
    while($bytes>=1024 && $i<count($units)-1){$bytes/=1024;$i++;}
    return rtrim(rtrim(number_format($bytes,$i===0?0:2,'.',''),'0'),'.').' '.$units[$i];
}
function csrf_token(): string {
    if (empty($_SESSION['hc_csrf'])) $_SESSION['hc_csrf']=bin2hex(random_bytes(32));
    return (string)$_SESSION['hc_csrf'];
}
function check_csrf(): void {
    $token=(string)($_POST['_csrf']??'');
    if ($token==='' || !hash_equals((string)($_SESSION['hc_csrf']??''),$token)) {
        if (str_contains(strtolower((string)($_SERVER['HTTP_ACCEPT']??'')),'application/json') || strtolower((string)($_SERVER['HTTP_X_REQUESTED_WITH']??''))==='xmlhttprequest') {
            http_response_code(419); header('Content-Type: application/json; charset=utf-8'); echo json_encode(['ok'=>false,'error'=>'Сессия устарела. Обновите страницу.'],JSON_UNESCAPED_UNICODE); exit;
        }
        http_response_code(419); exit('CSRF token error');
    }
}
function flash(?string $message=null,string $type='ok'): ?array {
    if ($message!==null){$_SESSION['hc_flash']=['message'=>$message,'type'=>$type];return null;}
    $f=$_SESSION['hc_flash']??null; unset($_SESSION['hc_flash']); return is_array($f)?$f:null;
}

function hc_db(): PDO
{
    static $pdo=null; if($pdo instanceof PDO) return $pdo;
    $path=(string)app_config('cloud_db_path','/var/lib/hyper-host-cloud/cloud.sqlite');
    $dir=dirname($path); if(!is_dir($dir)) @mkdir($dir,02770,true);
    $pdo=new PDO('sqlite:'.$path);
    $pdo->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
    $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE,PDO::FETCH_ASSOC);
    $pdo->exec('PRAGMA foreign_keys=ON');
    $pdo->exec('PRAGMA journal_mode=WAL');
    $pdo->exec('PRAGMA busy_timeout=10000');
    hc_init_schema($pdo);
    return $pdo;
}
function hc_init_schema(PDO $pdo): void
{
    static $done=false; if($done)return; $done=true;
    $pdo->exec("CREATE TABLE IF NOT EXISTS cloud_users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL COLLATE NOCASE UNIQUE,
        email TEXT NOT NULL DEFAULT '',
        display_name TEXT NOT NULL DEFAULT '',
        password_hash TEXT NULL,
        auth_source TEXT NOT NULL DEFAULT 'cloud',
        panel_user_id INTEGER NULL UNIQUE,
        role TEXT NOT NULL DEFAULT 'user',
        storage_key TEXT NOT NULL UNIQUE,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        last_login_at TEXT NULL
    )");
    $pdo->exec("CREATE TABLE IF NOT EXISTS cloud_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NULL,type TEXT NOT NULL,message TEXT NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )");
    $pdo->exec("CREATE TABLE IF NOT EXISTS shared_entries (
        rel_path TEXT PRIMARY KEY, owner_user_id INTEGER NOT NULL, entry_type TEXT NOT NULL DEFAULT 'file', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )");
    $pdo->exec("CREATE TABLE IF NOT EXISTS public_shares (
        token TEXT PRIMARY KEY, owner_user_id INTEGER NOT NULL, space TEXT NOT NULL DEFAULT 'private', rel_path TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )");
    $pdo->exec("CREATE INDEX IF NOT EXISTS idx_public_shares_owner ON public_shares(owner_user_id,space,rel_path)");
}
function hc_panel_config(): array
{
    static $cfg=null; if(is_array($cfg))return $cfg;
    $path=(string)app_config('panel_config','/var/www/hyper-host/app/config.php');
    if(!is_file($path)) return $cfg=[];
    $data=require $path; return $cfg=is_array($data)?$data:[];
}
function hc_panel_db(): ?PDO
{
    static $pdo=false; if($pdo instanceof PDO)return $pdo; if($pdo===null)return null;
    $cfg=hc_panel_config(); $path=(string)($cfg['db_path']??'');
    if($path===''||!is_file($path)){ $pdo=null; return null; }
    try{ $pdo=new PDO('sqlite:'.$path); $pdo->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION); $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE,PDO::FETCH_ASSOC); return $pdo; }
    catch(Throwable){$pdo=null;return null;}
}
function hc_panel_user_by_username(string $username): ?array
{
    $pdo=hc_panel_db(); if(!$pdo)return null;
    try{$st=$pdo->prepare('SELECT * FROM users WHERE lower(username)=lower(?) LIMIT 1');$st->execute([$username]);$r=$st->fetch();return is_array($r)?$r:null;}catch(Throwable){return null;}
}
function hc_base32_decode(string $base32): string
{
    $alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';$base32=strtoupper((string)preg_replace('/[^A-Z2-7]/','',$base32));$bits='';
    for($i=0;$i<strlen($base32);$i++){ $v=strpos($alphabet,$base32[$i]); if($v===false)continue; $bits.=str_pad(decbin($v),5,'0',STR_PAD_LEFT); }
    $out=''; for($i=0;$i+8<=strlen($bits);$i+=8)$out.=chr(bindec(substr($bits,$i,8))); return $out;
}
function hc_totp_code(string $secret,?int $slice=null): string
{
    $slice??=(int)floor(time()/30);$key=hc_base32_decode($secret);if($key==='')return '';
    $time=pack('N*',0).pack('N*',$slice);$hash=hash_hmac('sha1',$time,$key,true);$offset=ord(substr($hash,-1))&0x0F;$tr=unpack('N',substr($hash,$offset,4))[1]&0x7FFFFFFF;
    return str_pad((string)($tr%1000000),6,'0',STR_PAD_LEFT);
}
function hc_verify_totp(string $secret,string $code): bool
{
    $code=(string)preg_replace('/\D/','',$code); if(strlen($code)!==6)return false;$slice=(int)floor(time()/30);
    for($i=-1;$i<=1;$i++) if(hash_equals(hc_totp_code($secret,$slice+$i),$code)) return true; return false;
}
function hc_panel_2fa_required(): bool
{
    $pdo=hc_panel_db(); if(!$pdo)return false;
    try{$st=$pdo->prepare("SELECT value FROM settings WHERE key='security_2fa_enabled'");$st->execute();return (string)($st->fetchColumn()?:'0')==='1';}catch(Throwable){return false;}
}
function hc_panel_2fa_secret(): string
{
    $pdo=hc_panel_db(); if(!$pdo)return '';
    try{$st=$pdo->prepare("SELECT value FROM settings WHERE key='security_2fa_secret'");$st->execute();return (string)($st->fetchColumn()?:'');}catch(Throwable){return '';}
}
function hc_storage_key_for_panel(int $panelId): string { return 'panel-'.$panelId; }
function hc_storage_key_for_cloud(int $id): string { return 'user-'.$id; }
function hc_upsert_panel_cloud_user(array $panelUser): array
{
    $panelId=(int)($panelUser['id']??0);if($panelId<1)throw new RuntimeException('Некорректный аккаунт панели');
    $username=(string)($panelUser['username']??('panel'.$panelId));$db=hc_db();
    $st=$db->prepare('SELECT * FROM cloud_users WHERE panel_user_id=? LIMIT 1');$st->execute([$panelId]);$row=$st->fetch();
    if(!$row){
        $st=$db->prepare("INSERT INTO cloud_users(username,email,display_name,password_hash,auth_source,panel_user_id,role,storage_key,last_login_at) VALUES(?,?,?,?, 'panel',?,'panel_admin',?,datetime('now','localtime'))");
        $st->execute([$username,'',$username,null,$panelId,hc_storage_key_for_panel($panelId)]);
        $id=(int)$db->lastInsertId();
    }else{
        $id=(int)$row['id'];$db->prepare("UPDATE cloud_users SET username=?,display_name=?,role='panel_admin',is_active=1,last_login_at=datetime('now','localtime') WHERE id=?")->execute([$username,$username,$id]);
    }
    return hc_cloud_user_by_id($id)??throw new RuntimeException('Не удалось создать профиль облака');
}
function hc_cloud_user_by_id(int $id): ?array
{
    $st=hc_db()->prepare('SELECT * FROM cloud_users WHERE id=? AND is_active=1 LIMIT 1');$st->execute([$id]);$r=$st->fetch();return is_array($r)?$r:null;
}
function hc_cloud_user_by_username(string $username): ?array
{
    $st=hc_db()->prepare('SELECT * FROM cloud_users WHERE lower(username)=lower(?) AND is_active=1 LIMIT 1');$st->execute([$username]);$r=$st->fetch();return is_array($r)?$r:null;
}
function current_user(): ?array
{
    $id=(int)($_SESSION['hc_user_id']??0); return $id>0?hc_cloud_user_by_id($id):null;
}
function require_auth(): array
{
    $u=current_user(); if(!$u) redirect('/?auth=login'); return $u;
}
function hc_login(string $username,string $password,string $totp=''): array
{
    $username=trim($username);if($username===''||$password==='')throw new RuntimeException('Введите логин и пароль');
    $panel=hc_panel_user_by_username($username);
    if($panel && password_verify($password,(string)($panel['password_hash']??''))){
        if(hc_panel_2fa_required()){
            $secret=hc_panel_2fa_secret();if($secret===''||!hc_verify_totp($secret,$totp))throw new RuntimeException('Введите корректный 2FA-код панели');
        }
        $u=hc_upsert_panel_cloud_user($panel);$_SESSION['hc_user_id']=(int)$u['id'];session_regenerate_id(true);hc_ensure_user_root($u);add_event('auth','Вход через аккаунт HYPER-HOST');return $u;
    }
    $u=hc_cloud_user_by_username($username);
    if(!$u || (string)($u['auth_source']??'')!=='cloud' || !password_verify($password,(string)($u['password_hash']??''))) throw new RuntimeException('Неверный логин или пароль');
    hc_db()->prepare("UPDATE cloud_users SET last_login_at=datetime('now','localtime') WHERE id=?")->execute([(int)$u['id']]);
    $_SESSION['hc_user_id']=(int)$u['id'];session_regenerate_id(true);hc_ensure_user_root($u);add_event('auth','Вход в HYPER CLOUD');return hc_cloud_user_by_id((int)$u['id'])??$u;
}
function hc_register(string $username,string $email,string $password,string $password2): array
{
    $username=trim($username);$email=trim($email);
    if(!preg_match('/^[A-Za-z0-9_.-]{3,40}$/',$username))throw new RuntimeException('Логин: 3–40 символов, буквы, цифры, . _ -');
    if($email!==''&&!filter_var($email,FILTER_VALIDATE_EMAIL))throw new RuntimeException('Некорректный e-mail');
    if(strlen($password)<10)throw new RuntimeException('Пароль должен быть не короче 10 символов');
    if(!hash_equals($password,$password2))throw new RuntimeException('Пароли не совпадают');
    if(hc_panel_user_by_username($username))throw new RuntimeException('Этот логин уже используется аккаунтом панели');
    if(hc_cloud_user_by_username($username))throw new RuntimeException('Этот логин уже занят');
    $db=hc_db();$hash=password_hash($password,PASSWORD_DEFAULT);
    $db->prepare("INSERT INTO cloud_users(username,email,display_name,password_hash,auth_source,role,storage_key) VALUES(?,?,?,?,'cloud','user','pending')")->execute([$username,$email,$username,$hash]);
    $id=(int)$db->lastInsertId();$key=hc_storage_key_for_cloud($id);$db->prepare('UPDATE cloud_users SET storage_key=? WHERE id=?')->execute([$key,$id]);
    $u=hc_cloud_user_by_id($id)??throw new RuntimeException('Не удалось создать аккаунт');$_SESSION['hc_user_id']=$id;session_regenerate_id(true);hc_ensure_user_root($u);add_event('auth','Регистрация аккаунта HYPER CLOUD');return $u;
}
function hc_logout(): never { $_SESSION=[]; if(ini_get('session.use_cookies')){ $p=session_get_cookie_params();setcookie(session_name(),'',time()-42000,$p['path'],$p['domain'],$p['secure'],$p['httponly']); } session_destroy();redirect('/?auth=login'); }
function hc_is_panel_admin(?array $user=null): bool { $user??=current_user(); return is_array($user)&&(string)($user['auth_source']??'')==='panel'; }
function hc_storage_base(): string { return rtrim((string)app_config('storage_root','/var/www/hyper-host-cloud'),'/'); }
function hc_space(): string { return (($GLOBALS['HC_SPACE']??'private')==='shared')?'shared':'private'; }
function hc_root_for_user(array $user,string $space='private'): string
{
    $base=hc_storage_base(); if($space==='shared')return $base.'/shared';
    $key=preg_replace('/[^A-Za-z0-9_.-]/','_', (string)($user['storage_key']??'')); if($key==='')throw new RuntimeException('Не задано хранилище пользователя');
    return $base.'/users/'.$key;
}
function hc_ensure_user_root(array $user): void
{
    foreach([hc_storage_base(),hc_storage_base().'/users',hc_storage_base().'/shared',hc_root_for_user($user,'private')] as $dir){if(!is_dir($dir))@mkdir($dir,02770,true);@chmod($dir,02770);}
}
function hc_shared_owner(string $rel): int
{
    $rel=trim(str_replace('\\','/',$rel),'/');if($rel==='')return 0;
    $st=hc_db()->prepare('SELECT owner_user_id FROM shared_entries WHERE rel_path=? LIMIT 1');$st->execute([$rel]);return (int)($st->fetchColumn()?:0);
}
function hc_shared_mark(string $rel,int $owner,string $type='file'): void
{
    $rel=trim(str_replace('\\','/',$rel),'/');if($rel==='')return;
    hc_db()->prepare("INSERT INTO shared_entries(rel_path,owner_user_id,entry_type,created_at) VALUES(?,?,?,datetime('now','localtime')) ON CONFLICT(rel_path) DO UPDATE SET owner_user_id=excluded.owner_user_id,entry_type=excluded.entry_type")->execute([$rel,$owner,$type]);
}
function hc_shared_repath_tree(string $old,string $new): void
{
    $rows=hc_db()->prepare("SELECT rel_path,owner_user_id,entry_type FROM shared_entries WHERE rel_path=? OR rel_path LIKE ?");$rows->execute([$old,$old.'/%']);$all=$rows->fetchAll();
    hc_db()->beginTransaction();try{hc_db()->prepare("DELETE FROM shared_entries WHERE rel_path=? OR rel_path LIKE ?")->execute([$old,$old.'/%']);$ins=hc_db()->prepare('INSERT OR REPLACE INTO shared_entries(rel_path,owner_user_id,entry_type) VALUES(?,?,?)');foreach($all as $r){$p=(string)$r['rel_path'];$np=$p===$old?$new:$new.substr($p,strlen($old));$ins->execute([$np,(int)$r['owner_user_id'],(string)$r['entry_type']]);}hc_db()->commit();}catch(Throwable $e){hc_db()->rollBack();throw $e;}
}
function hc_shared_remove_tree(string $rel): void { hc_db()->prepare("DELETE FROM shared_entries WHERE rel_path=? OR rel_path LIKE ?")->execute([$rel,$rel.'/%']); }
function hc_can_modify(string $rel): bool
{
    if(hc_space()!=='shared')return true;$u=current_user();if(!$u)return false;if(hc_is_panel_admin($u))return true;return hc_shared_owner($rel)===(int)$u['id'];
}
function hc_assert_can_modify(string $rel): void { if(!hc_can_modify($rel))throw new RuntimeException('Изменять этот файл может владелец или администратор'); }
function add_event(string $type,string $message): void
{
    try{hc_db()->prepare('INSERT INTO cloud_events(user_id,type,message,created_at) VALUES(?,?,?,datetime("now","localtime"))')->execute([(int)(current_user()['id']??0),$type,$message]);}catch(Throwable){}
}
function hc_panel_url(): string { return rtrim((string)app_config('panel_url','https://panel.hyper-host.pw'),'/'); }
