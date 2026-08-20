<?php
declare(strict_types=1);

/** HYPER CLOUD v107 hardened standalone bootstrap. */
ini_set('session.use_strict_mode', '1');
ini_set('session.use_only_cookies', '1');
session_name('HYPERCLOUDSESSID');
session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/',
    'domain' => '',
    'secure' => true,
    'httponly' => true,
    'samesite' => 'Lax',
]);
session_start();
if (!isset($_SESSION['hc_started_at'])) $_SESSION['hc_started_at'] = time();
if (!isset($_SESSION['hc_last_seen'])) $_SESSION['hc_last_seen'] = time();
if ((time() - (int)$_SESSION['hc_last_seen']) > 28800 || (time() - (int)$_SESSION['hc_started_at']) > 86400) {
    $_SESSION = [];
    session_regenerate_id(true);
    $_SESSION['hc_started_at'] = time();
}
$_SESSION['hc_last_seen'] = time();
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
    $pdo->exec("CREATE TABLE IF NOT EXISTS auth_attempts (id INTEGER PRIMARY KEY AUTOINCREMENT, login_key TEXT NOT NULL, success INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)");
    $pdo->exec("CREATE INDEX IF NOT EXISTS idx_auth_attempts_key_time ON auth_attempts(login_key,created_at)");
}
function hc_panel_auth_helper(array $payload): array
{
    $helper = '/usr/local/sbin/hyper-cloud-panel-auth';
    if (!is_executable($helper)) return ['ok'=>false,'exists'=>false];
    $spec = [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']];
    $proc = @proc_open(['/usr/bin/sudo','-n',$helper], $spec, $pipes, null, ['PATH'=>'/usr/sbin:/usr/bin:/sbin:/bin']);
    if (!is_resource($proc)) return ['ok'=>false,'exists'=>false];
    fwrite($pipes[0], json_encode($payload, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES)); fclose($pipes[0]);
    $out = stream_get_contents($pipes[1]); fclose($pipes[1]);
    $err = stream_get_contents($pipes[2]); fclose($pipes[2]);
    $code = proc_close($proc);
    $data = json_decode((string)$out, true);
    if ($code !== 0 || !is_array($data)) { error_log('HYPER CLOUD auth helper failed: '.trim((string)$err)); return ['ok'=>false,'exists'=>false]; }
    return $data;
}
function hc_panel_user_exists(string $username): bool
{
    $r = hc_panel_auth_helper(['action'=>'exists','username'=>trim($username)]);
    return !empty($r['exists']);
}
function hc_login_key(string $username): string
{
    $ip = (string)($_SERVER['REMOTE_ADDR'] ?? 'unknown');
    return hash('sha256', strtolower(trim($username)).'|'.$ip);
}
function hc_auth_guard(string $username): void
{
    $key=hc_login_key($username);$now=time();$since=$now-900;
    $db=hc_db();$db->prepare('DELETE FROM auth_attempts WHERE created_at < ?')->execute([$now-86400]);
    $st=$db->prepare('SELECT COUNT(*) FROM auth_attempts WHERE login_key=? AND success=0 AND created_at>=?');$st->execute([$key,$since]);
    if((int)$st->fetchColumn()>=8) throw new RuntimeException('Слишком много попыток. Попробуйте через несколько минут.');
}
function hc_auth_record(string $username,bool $success): void
{
    $key=hc_login_key($username);$db=hc_db();
    if($success){$db->prepare('DELETE FROM auth_attempts WHERE login_key=?')->execute([$key]);return;}
    $db->prepare('INSERT INTO auth_attempts(login_key,success,created_at) VALUES(?,0,?)')->execute([$key,time()]);
}

function hc_registration_guard(): void
{
    $ip=(string)($_SERVER['REMOTE_ADDR']??'unknown');$key='register:'.hash('sha256',$ip);$now=time();$db=hc_db();
    $db->prepare('DELETE FROM auth_attempts WHERE created_at < ?')->execute([$now-86400]);
    $st=$db->prepare('SELECT COUNT(*) FROM auth_attempts WHERE login_key=? AND created_at>=?');$st->execute([$key,$now-3600]);
    if((int)$st->fetchColumn()>=10)throw new RuntimeException('Слишком много регистраций с этого адреса. Попробуйте позже.');
    $db->prepare('INSERT INTO auth_attempts(login_key,success,created_at) VALUES(?,1,?)')->execute([$key,$now]);
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
    $id=(int)($_SESSION['hc_user_id']??0);
    if($id<1) return null;
    $u=hc_cloud_user_by_id($id);
    if(!$u){unset($_SESSION['hc_user_id']);return null;}
    return $u;
}
function require_auth(): array
{
    $u=current_user(); if(!$u) redirect('/?auth=login'); return $u;
}
function hc_login(string $username,string $password,string $totp=''): array
{
    $username=trim($username);if($username===''||$password==='')throw new RuntimeException('Введите логин и пароль');
    hc_auth_guard($username);
    $panel=hc_panel_auth_helper(['action'=>'login','username'=>$username,'password'=>$password,'totp'=>$totp,'ip'=>(string)($_SERVER['REMOTE_ADDR']??'')]);
    if(!empty($panel['ok'])){
        $panelUser=['id'=>(int)($panel['id']??0),'username'=>(string)($panel['username']??$username)];
        $u=hc_upsert_panel_cloud_user($panelUser);$_SESSION['hc_user_id']=(int)$u['id'];session_regenerate_id(true);$_SESSION['hc_started_at']=time();$_SESSION['hc_last_seen']=time();hc_ensure_user_root($u);hc_auth_record($username,true);add_event('auth','Вход администратора');return $u;
    }
    $u=hc_cloud_user_by_username($username);
    if(!$u || (string)($u['auth_source']??'')!=='cloud' || !password_verify($password,(string)($u['password_hash']??''))){hc_auth_record($username,false);throw new RuntimeException('Неверные данные для входа');}
    hc_db()->prepare("UPDATE cloud_users SET last_login_at=datetime('now','localtime') WHERE id=?")->execute([(int)$u['id']]);
    $_SESSION['hc_user_id']=(int)$u['id'];session_regenerate_id(true);$_SESSION['hc_started_at']=time();$_SESSION['hc_last_seen']=time();hc_ensure_user_root($u);hc_auth_record($username,true);add_event('auth','Вход в HYPER CLOUD');return hc_cloud_user_by_id((int)$u['id'])??$u;
}
function hc_register(string $username,string $email,string $password,string $password2): array
{
    $username=trim($username);$email=trim($email);
    if(!preg_match('/^[A-Za-z0-9_.-]{3,40}$/',$username))throw new RuntimeException('Логин: 3–40 символов, буквы, цифры, . _ -');
    if($email!==''&&!filter_var($email,FILTER_VALIDATE_EMAIL))throw new RuntimeException('Некорректный e-mail');
    if(strlen($password)<12)throw new RuntimeException('Пароль должен быть не короче 12 символов');
    if(!hash_equals($password,$password2))throw new RuntimeException('Пароли не совпадают');
    if(hc_panel_user_exists($username))throw new RuntimeException('Этот логин уже занят');
    if(hc_cloud_user_by_username($username))throw new RuntimeException('Этот логин уже занят');
    hc_registration_guard();
    $db=hc_db();$hash=password_hash($password,PASSWORD_DEFAULT);
    $db->prepare("INSERT INTO cloud_users(username,email,display_name,password_hash,auth_source,role,storage_key) VALUES(?,?,?,?,'cloud','user','pending')")->execute([$username,$email,$username,$hash]);
    $id=(int)$db->lastInsertId();$key='user-'.$id.'-'.bin2hex(random_bytes(8));$db->prepare('UPDATE cloud_users SET storage_key=? WHERE id=?')->execute([$key,$id]);
    $u=hc_cloud_user_by_id($id)??throw new RuntimeException('Не удалось создать аккаунт');$_SESSION['hc_user_id']=$id;session_regenerate_id(true);$_SESSION['hc_started_at']=time();$_SESSION['hc_last_seen']=time();hc_ensure_user_root($u);add_event('auth','Регистрация аккаунта HYPER CLOUD');return $u;
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
function hc_shared_tree_has_foreign_owner(string $rel,int $ownerId): bool
{
    $rel=trim(str_replace('\\','/',$rel),'/');if($rel==='')return true;
    $st=hc_db()->prepare('SELECT 1 FROM shared_entries WHERE (rel_path=? OR rel_path LIKE ?) AND owner_user_id<>? LIMIT 1');
    $st->execute([$rel,$rel.'/%',$ownerId]);return (bool)$st->fetchColumn();
}
function hc_assert_shared_tree_modify(string $rel): void
{
    if(hc_space()!=='shared')return;$u=current_user();if(!$u)throw new RuntimeException('Требуется авторизация');if(hc_is_panel_admin($u))return;
    if(hc_shared_owner($rel)!==(int)$u['id'])throw new RuntimeException('Изменять эту папку может только её владелец');
    if(hc_shared_tree_has_foreign_owner($rel,(int)$u['id']))throw new RuntimeException('В папке есть файлы других пользователей');
}
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
