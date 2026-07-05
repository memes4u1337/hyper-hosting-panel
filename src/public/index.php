<?php
declare(strict_types=1);
require __DIR__ . '/../app/bootstrap.php';

$page = (string)($_GET['page'] ?? 'dashboard');
$action = $_POST['action'] ?? $_GET['action'] ?? null;

if ($page === 'logout') { session_destroy(); redirect('/?page=login'); }

if ($page === 'login') {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        check_csrf();
        $username = trim((string)($_POST['username'] ?? ''));
        $password = (string)($_POST['password'] ?? '');
        $code = trim((string)($_POST['totp'] ?? ''));
        if (!ip_allowed()) { auth_log($username, 'blocked_ip'); flash('Вход с этого IP запрещён', 'danger'); redirect('/?page=login'); }
        $stmt = db()->prepare('SELECT * FROM users WHERE username = ?'); $stmt->execute([$username]); $u = $stmt->fetch();
        if ($u && password_verify($password, (string)$u['password_hash'])) {
            if (setting_get('security_2fa_enabled', '0') === '1') {
                $secret = setting_get('security_2fa_secret', '');
                if ($secret === '' || !verify_totp($secret, $code)) { auth_log($username, 'bad_2fa'); flash('Неверный 2FA-код', 'danger'); redirect('/?page=login'); }
            }
            $_SESSION['user_id'] = (int)$u['id']; auth_log($username, 'success'); add_event('auth', 'Вход в панель: '.$username); redirect('/');
        }
        auth_log($username, 'failed'); flash('Неверный логин или пароль', 'danger'); redirect('/?page=login');
    }
    render_login(); exit;
}

$user = require_auth();
if ($_SERVER['REQUEST_METHOD'] === 'POST') { check_csrf(); handle_post((string)$action); }
render_page($page, $user);

function csrf_field(): string { return '<input type="hidden" name="_csrf" value="'.e(csrf_token()).'">'; }
function host_name(): string { return panel_host_for_connections(); }
function default_ftp_password(): string { return 'Hh-' . bin2hex(random_bytes(5)) . '!'; }
function back_to_current(): never { redirect($_SERVER['HTTP_REFERER'] ?? '/'); }

function handle_post(string $action): void
{
    try {
        switch ($action) {
            case 'add_site': {
                $domain = strtolower(trim((string)($_POST['domain'] ?? ''))); $aliases = strtolower(trim((string)($_POST['aliases'] ?? ''))); $phpv = trim((string)($_POST['php_version'] ?? ''));
                if (!is_valid_domain($domain)) throw new RuntimeException('Неверный домен');
                foreach (array_filter(array_map('trim', explode(',', $aliases))) as $alias) if (!is_valid_domain($alias)) throw new RuntimeException('Неверный alias: '.$alias);
                $res = run_ctl(['add-site', $domain, $aliases, $phpv], 180); if ($res['code'] !== 0) throw new RuntimeException($res['output']);
                $root = rtrim((string)app_config('sites_dir'), '/') . '/' . $domain . '/public_html'; upsert_site_row_v5($domain, $aliases, $root, 0, $phpv);
                add_event('site','Создан сайт: '.$domain); flash('Сайт создан, папка public_html готова: '.$domain,'success'); redirect('/?page=sites');
            }
            case 'delete_site': {
                $id=(int)($_POST['id']??0); $mode=!empty($_POST['delete_files'])?'--delete-files':'--keep-files'; $st=db()->prepare('SELECT * FROM sites WHERE id=?'); $st->execute([$id]); $s=$st->fetch(); if(!$s) throw new RuntimeException('Сайт не найден');
                $res=run_ctl(['delete-site',$s['domain'],$mode],120); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('DELETE FROM sites WHERE id=?')->execute([$id]); flash('Сайт удалён','success'); redirect('/?page=sites');
            }
            case 'ssl_fix_site': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM sites WHERE id=?'); $st->execute([$id]); $site=$st->fetch(); if(!$site) throw new RuntimeException('Сайт не найден');
                hh_clear_cache();
                $res=run_ctl(['ssl-fix-site',$site['domain']],120); if($res['code']!==0) throw new RuntimeException($res['output']);
                hh_clear_cache();
                flash('ACME challenge для SSL исправлен. Теперь снова проверь DNS/SSL.', 'success'); redirect('/?page=ssl');
            }
            case 'ssl_site': {
                $id=(int)($_POST['id']??0); $email=trim((string)($_POST['email']??'')); if(!filter_var($email,FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Укажи нормальный email');
                $st=db()->prepare('SELECT * FROM sites WHERE id=?'); $st->execute([$id]); $s=$st->fetch(); if(!$s) throw new RuntimeException('Сайт не найден');
                $res=run_ctl(['ssl-site',$s['domain'],$email],300); if($res['code']!==0) throw new RuntimeException($res['output']); hh_clear_cache(); db()->prepare('UPDATE sites SET ssl_enabled=1 WHERE id=?')->execute([$id]); add_event('ssl','Выпущен SSL: '.$s['domain']); flash('SSL выпущен','success'); redirect('/?page=ssl');
            }
            case 'create_folder': {
                $name=trim((string)($_POST['name']??'')); if(!is_valid_folder_name($name)) throw new RuntimeException('Неверное имя папки');
                $res=run_ctl(['create-folder',$name],120); if($res['code']!==0) throw new RuntimeException($res['output']); $path=rtrim((string)app_config('sites_dir'),'/').'/'.$name.'/public_html'; upsert_folder_row($name,$path); flash('Папка создана: '.$name,'success'); redirect('/?page=sites');
            }
            case 'delete_folder': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM folders WHERE id=?'); $st->execute([$id]); $f=$st->fetch(); if(!$f) throw new RuntimeException('Папка не найдена'); $res=run_ctl(['delete-folder',$f['name']],120); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('DELETE FROM folders WHERE id=?')->execute([$id]); redirect('/?page=sites');
            }
            case 'create_ftp': {
                $username=trim((string)($_POST['username']??'')); $password=(string)($_POST['password']??''); if($username===''||!is_valid_name($username)) throw new RuntimeException('Неверный FTP логин'); if(strlen($password)<8) throw new RuntimeException('Пароль FTP минимум 8 символов');
                $res=run_ctl(['create-ftp',$username,$password,'all-sites'],240); if($res['code']!==0) throw new RuntimeException($res['output']); $final=str_starts_with($username,'hhftp_')?$username:'hhftp_'.$username; $home=rtrim((string)app_config('ftp_dir','/var/www/hyper-host-ftp'),'/').'/'.$final; upsert_ftp_row($final,$home,$password,host_name()); add_event('ftp','Создан FTP: '.$final); flash("FTP создан. Хост: ".host_name()." | Имя пользователя: {$final} | Пароль: {$password}",'success'); redirect('/?page=ftp');
            }
            case 'delete_ftp': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM ftp_accounts WHERE id=?'); $st->execute([$id]); $f=$st->fetch(); if(!$f) throw new RuntimeException('FTP не найден'); $res=run_ctl(['delete-ftp',$f['username']],120); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('DELETE FROM ftp_accounts WHERE id=?')->execute([$id]); redirect('/?page=ftp');
            }
            case 'reset_ftp_password': {
                $id=(int)($_POST['id']??0); $pass=(string)($_POST['password']??''); if(strlen($pass)<8) throw new RuntimeException('Пароль минимум 8 символов'); $st=db()->prepare('SELECT * FROM ftp_accounts WHERE id=?'); $st->execute([$id]); $f=$st->fetch(); if(!$f) throw new RuntimeException('FTP не найден'); $res=run_ctl(['ftp-password',$f['username'],$pass],120); if($res['code']!==0) throw new RuntimeException($res['output']); upsert_ftp_row((string)$f['username'],(string)$f['target_path'],$pass,host_name()); flash('Пароль FTP обновлён','success'); redirect('/?page=ftp');
            }
            case 'create_db': {
                $db=trim((string)($_POST['db_name']??'')); $du=trim((string)($_POST['db_user']??'')); $pass=(string)($_POST['password']??''); $remote=!empty($_POST['remote_allowed'])?'1':'0'; if(!is_valid_db_name($db)||!is_valid_db_name($du)) throw new RuntimeException('Имя базы/пользователя: латиница, цифры, _'); if(strlen($pass)<10) throw new RuntimeException('Пароль базы минимум 10 символов'); $res=run_ctl(['create-db',$db,$du,$pass,$remote],180); if($res['code']!==0) throw new RuntimeException($res['output']); upsert_db_row($db,$du,(int)$remote); flash('База создана','success'); redirect('/?page=databases');
            }
            case 'delete_db': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM databases WHERE id=?'); $st->execute([$id]); $r=$st->fetch(); if(!$r) throw new RuntimeException('База не найдена'); $res=run_ctl(['delete-db',$r['db_name'],$r['db_user']],180); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('DELETE FROM databases WHERE id=?')->execute([$id]); redirect('/?page=databases');
            }
            case 'mysql_external': {
                $state=(string)($_POST['state']??'disable'); $res=run_ctl(['mysql-external',$state],180); if($res['code']!==0) throw new RuntimeException($res['output']); setting_set('mysql_external',$state==='enable'?'1':'0'); redirect('/?page=databases');
            }
            case 'create_bot': {
                $name=trim((string)($_POST['name']??''));
                $runtime=(string)($_POST['runtime']??'python');
                $main=trim((string)($_POST['main_file']??''));
                $mem=(int)($_POST['memory_limit_mb']??0);
                $proc=(int)($_POST['process_limit']??0);
                if(!is_valid_name($name)) throw new RuntimeException('Неверное имя бота');
                if(!in_array($runtime,['python','node','php','custom'],true)) throw new RuntimeException('Неверный runtime');
                if($main==='') $main = $runtime==='node' ? 'index.js' : ($runtime==='php' ? 'bot.php' : 'bot.py');
                $main=basename($main);
                $botTmp=bot_uploaded_tmp('bot_file');
                $envTmp=bot_uploaded_tmp('env_file');
                $reqTmp=bot_uploaded_tmp('requirements_file');
                if($botTmp==='') {
                    // Если главный файл уже загружен через FTP/файловый менеджер, можно запустить без повторной загрузки.
                    $res=run_ctl(['bot-create',$name,$runtime,$main,(string)$mem,(string)$proc],600);
                } else {
                    $res=run_ctl(['bot-deploy',$name,$runtime,$main,$botTmp,$envTmp,$reqTmp,(string)$mem],900);
                }
                if($res['code']!==0) throw new RuntimeException($res['output']);
                hh_clear_cache();
                $path=rtrim((string)app_config('bots_dir'),'/').'/'.$name;
                upsert_bot_row_v5($name,$runtime,$path,$main,$mem,$proc);
                add_event('bot','Создан/обновлён PM2 бот: '.$name);
                flash("Бот {$name} загружен, зависимости установлены и PM2 запущен 24/7",'success');
                redirect('/?page=bots');
            }
            case 'bot_action': {
                $id=(int)($_POST['id']??0); $act=(string)($_POST['bot_action']??''); $st=db()->prepare('SELECT * FROM bots WHERE id=?'); $st->execute([$id]); $b=$st->fetch(); if(!$b) throw new RuntimeException('Бот не найден'); $res=($act==='install')?run_ctl(['bot-install-requirements',$b['name'],$b['runtime']],600):run_ctl(['bot',$act,$b['name']],120); if($res['code']!==0) throw new RuntimeException($res['output']); hh_clear_cache(); flash('Команда выполнена: '.$act.'. PM2 сохранён для 24/7 работы.','success'); redirect('/?page=bots');
            }
            case 'pm2_persist': {
                $res=run_ctl(['pm2-persist'],180); if($res['code']!==0) throw new RuntimeException($res['output']); hh_clear_cache(); flash('PM2 24/7 включён: боты продолжат работать после выхода из панели, закрытия SSH и перезагрузки сервера.','success'); redirect('/?page=bots');
            }
            case 'delete_bot': {
                $id=(int)($_POST['id']??0);
                $deleteFiles=!empty($_POST['delete_files']);
                $st=db()->prepare('SELECT * FROM bots WHERE id=?'); $st->execute([$id]); $b=$st->fetch(); if(!$b) throw new RuntimeException('Бот не найден');
                if($deleteFiles){
                    $confirm=trim((string)($_POST['confirm_name']??''));
                    if($confirm !== (string)$b['name']) throw new RuntimeException('Для удаления файлов введи точное имя бота: '.$b['name']);
                }
                $mode=$deleteFiles?'--delete-files':'--keep-files';
                $res=run_ctl(['bot-delete',$b['name'],$mode],180); if($res['code']!==0) throw new RuntimeException($res['output']);
                hh_clear_cache();
                db()->prepare('DELETE FROM bots WHERE id=?')->execute([$id]);
                add_event('bot', $deleteFiles ? 'Удалён бот с файлами: '.$b['name'] : 'Удалён бот из PM2, файлы сохранены: '.$b['name']);
                flash($deleteFiles ? 'Бот удалён из PM2 и файлы удалены с сервера' : 'Бот удалён из PM2, файлы оставлены на сервере','success');
                redirect('/?page=bots');
            }
            case 'save_file': { fm_save_file(); back_to_current(); }
            case 'upload_file': { fm_upload_file(); back_to_current(); }
            case 'mkdir_file': { fm_mkdir(); back_to_current(); }
            case 'delete_file': { fm_delete(); back_to_current(); }
            case 'backup_run': { $target=(string)($_POST['target']??'all'); $res=run_ctl(['backup-run',$target],600); if($res['code']!==0) throw new RuntimeException($res['output']); add_event('backup',$res['output']); flash($res['output'],'success'); redirect('/?page=backups'); }
            case 'backup_job': { $name=trim((string)($_POST['name']??'')); $schedule=trim((string)($_POST['schedule']??'')); $target=(string)($_POST['target']??'all'); if(!is_valid_name($name)||$schedule==='') throw new RuntimeException('Неверные данные backup'); db()->prepare('INSERT INTO backup_jobs(name,target,schedule,enabled) VALUES(?,?,?,1) ON CONFLICT(name) DO UPDATE SET target=excluded.target,schedule=excluded.schedule,enabled=1')->execute([$name,$target,$schedule]); $res=run_ctl(['backup-schedule',$name,$schedule,$target],120); if($res['code']!==0) throw new RuntimeException($res['output']); redirect('/?page=backups'); }
            case 'delete_backup_job': { $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM backup_jobs WHERE id=?'); $st->execute([$id]); $j=$st->fetch(); if($j){ run_ctl(['backup-delete-schedule',$j['name']],60); db()->prepare('DELETE FROM backup_jobs WHERE id=?')->execute([$id]); } redirect('/?page=backups'); }
            case 'network_fix': { $domain=strtolower(trim((string)($_POST['domain']??''))); $ip=trim((string)($_POST['public_ip']??'')); if($domain!=='' && !is_valid_domain($domain)) throw new RuntimeException('Неверный домен'); if($ip!=='' && !filter_var($ip,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)) throw new RuntimeException('Неверный IP'); hh_clear_cache(); $res=run_ctl(['network-fix',$domain,$ip],180); if($res['code']!==0) throw new RuntimeException($res['output']); if($ip!=='') setting_set('public_ip_override',$ip); flash('Сеть исправлена: nginx слушает все IP, firewall открыт, DNS/ACME подготовлены','success'); redirect('/?page=network'); }
            case 'save_panel_domain': { $domain=strtolower(trim((string)($_POST['panel_domain']??''))); if(!is_valid_domain($domain)) throw new RuntimeException('Неверный домен панели'); $res=run_ctl(['panel-domain','set',$domain],120); if($res['code']!==0) throw new RuntimeException($res['output']); setting_set('panel_domain_override',$domain); hh_clear_cache(); flash('Домен панели сохранён: '.$domain,'success'); redirect('/?page=network'); }
            case 'dns_wizard': { $domain=strtolower(trim((string)($_POST['domain']??''))); $ip=trim((string)($_POST['public_ip']??'')); $panel=trim((string)($_POST['panel_subdomain']??'panel')); if(!is_valid_domain($domain)) throw new RuntimeException('Неверный домен'); if($ip!=='' && !filter_var($ip,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)) throw new RuntimeException('Неверный IP'); $primary='ns1.'.$domain.'.'; $admin='admin.'.$domain.'.'; db()->prepare('INSERT INTO dns_zones(domain,primary_ns,admin_email) VALUES(?,?,?) ON CONFLICT(domain) DO UPDATE SET primary_ns=excluded.primary_ns,admin_email=excluded.admin_email')->execute([$domain,$primary,$admin]); $res=run_ctl(['dns-wizard',$domain,$ip,$panel],180); if($res['code']!==0) throw new RuntimeException($res['output']); flash("DNS-зона создана. У регистратора поставь NS: ns1.$domain и ns2.$domain. Если просит glue — IP $ip",'success'); redirect('/?page=dns'); }
            case 'create_dns_zone': { $domain=strtolower(trim((string)($_POST['domain']??''))); if(!is_valid_domain($domain)) throw new RuntimeException('Неверный домен'); db()->prepare('INSERT INTO dns_zones(domain,primary_ns,admin_email) VALUES(?,?,?) ON CONFLICT(domain) DO UPDATE SET primary_ns=excluded.primary_ns,admin_email=excluded.admin_email')->execute([$domain, trim((string)($_POST['primary_ns']??'ns1.local.')), trim((string)($_POST['admin_email']??'admin.local.'))]); dns_apply_zone($domain); redirect('/?page=dns'); }
            case 'add_dns_record': { $zone=(int)($_POST['zone_id']??0); $type=strtoupper(trim((string)($_POST['type']??'A'))); $name=trim((string)($_POST['name']??'@')); $value=trim((string)($_POST['value']??'')); $ttl=(int)($_POST['ttl']??3600); if($value==='') throw new RuntimeException('Значение DNS записи пустое'); db()->prepare('INSERT INTO dns_records(zone_id,type,name,value,ttl) VALUES(?,?,?,?,?)')->execute([$zone,$type,$name,$value,$ttl]); $z=db()->prepare('SELECT domain FROM dns_zones WHERE id=?'); $z->execute([$zone]); $zr=$z->fetch(); if($zr) dns_apply_zone((string)$zr['domain']); redirect('/?page=dns'); }
            case 'delete_dns_record': { $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT z.domain FROM dns_records r JOIN dns_zones z ON z.id=r.zone_id WHERE r.id=?'); $st->execute([$id]); $z=$st->fetch(); db()->prepare('DELETE FROM dns_records WHERE id=?')->execute([$id]); if($z) dns_apply_zone((string)$z['domain']); redirect('/?page=dns'); }
            case 'delete_dns_zone': { $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM dns_zones WHERE id=?'); $st->execute([$id]); $z=$st->fetch(); if($z){ run_ctl(['dns-delete',$z['domain']],60); db()->prepare('DELETE FROM dns_zones WHERE id=?')->execute([$id]); } redirect('/?page=dns'); }
            case 'ssl_renew_all': { hh_clear_cache(); $res=run_ctl(['ssl-renew-all'],300); if($res['code']!==0) throw new RuntimeException($res['output']); hh_clear_cache(); flash('SSL автопродление проверено','success'); redirect('/?page=ssl'); }
            case 'save_public_ip': { $ip=trim((string)($_POST['public_ip']??'')); if($ip!=='' && !filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) throw new RuntimeException('Неверный публичный IPv4'); $res=$ip===''?run_ctl(['public-ip','clear'],60):run_ctl(['public-ip','set',$ip],60); if($res['code']!==0) throw new RuntimeException($res['output']); setting_set('public_ip_override',$ip); hh_clear_cache(); flash($ip===''?'Публичный IP сброшен':'Публичный IP сохранён: '.$ip,'success'); redirect('/?page=ssl'); }
            case 'set_site_php': { $id=(int)($_POST['id']??0); $ver=(string)($_POST['php_version']??''); $st=db()->prepare('SELECT * FROM sites WHERE id=?'); $st->execute([$id]); $s=$st->fetch(); if(!$s) throw new RuntimeException('Сайт не найден'); $res=run_ctl(['site-php',$s['domain'],$ver],120); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('UPDATE sites SET php_version=? WHERE id=?')->execute([$ver,$id]); redirect('/?page=php'); }
            case 'create_cron': { $name=trim((string)($_POST['name']??'')); $schedule=trim((string)($_POST['schedule']??'')); $cmd=trim((string)($_POST['command']??'')); if(!is_valid_name($name)||$schedule===''||$cmd==='') throw new RuntimeException('Неверные данные cron'); db()->prepare('INSERT INTO cron_tasks(name,schedule,command,enabled) VALUES(?,?,?,1) ON CONFLICT(name) DO UPDATE SET schedule=excluded.schedule,command=excluded.command,enabled=1')->execute([$name,$schedule,$cmd]); $res=run_ctl(['cron-set',$name,$schedule,$cmd],60); if($res['code']!==0) throw new RuntimeException($res['output']); redirect('/?page=cron'); }
            case 'delete_cron': { $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM cron_tasks WHERE id=?'); $st->execute([$id]); $c=$st->fetch(); if($c){ run_ctl(['cron-delete',$c['name']],60); db()->prepare('DELETE FROM cron_tasks WHERE id=?')->execute([$id]); } redirect('/?page=cron'); }
            case 'save_security': { setting_set('security_ip_allowlist', trim((string)($_POST['ip_allowlist']??''))); $enabled=!empty($_POST['enable_2fa'])?'1':'0'; if($enabled==='1' && setting_get('security_2fa_secret','')==='') setting_set('security_2fa_secret',base32_random()); setting_set('security_2fa_enabled',$enabled); flash('Безопасность сохранена','success'); redirect('/?page=security'); }
            case 'reset_2fa_secret': { setting_set('security_2fa_secret',base32_random()); flash('2FA secret обновлён','success'); redirect('/?page=security'); }
            case 'repair_panel':
                hh_clear_cache(); { $res=run_ctl(['repair'],240); if($res['code']!==0) throw new RuntimeException($res['output']); flash('Ремонт выполнен: права, ACL, FTP, сервисы проверены','success'); redirect('/?page=settings'); }
            case 'sync_resources':
                hh_clear_cache(); { sync_resources(); flash('Ресурсы синхронизированы','success'); redirect('/?page=dashboard'); }
            case 'change_password': { $current=(string)($_POST['current_password']??''); $new=(string)($_POST['new_password']??''); if(strlen($new)<10) throw new RuntimeException('Новый пароль минимум 10 символов'); $uid=(int)($_SESSION['user_id']??0); $st=db()->prepare('SELECT * FROM users WHERE id=?'); $st->execute([$uid]); $u=$st->fetch(); if(!$u||!password_verify($current,(string)$u['password_hash'])) throw new RuntimeException('Текущий пароль неверный'); db()->prepare('UPDATE users SET password_hash=? WHERE id=?')->execute([password_hash($new,PASSWORD_DEFAULT),$uid]); flash('Пароль панели изменён','success'); redirect('/?page=settings'); }
        }
    } catch (Throwable $e) { flash($e->getMessage(), 'danger'); redirect('/?page=' . ($_GET['page'] ?? 'dashboard')); }
}

function sync_resources(): void
{
    $data=run_ctl_json(['sync-json'],90); if(isset($data['_error'])) throw new RuntimeException((string)$data['_error']);
    foreach(($data['sites']??[]) as $s) upsert_site_row_v5((string)$s['domain'],(string)($s['aliases']??''),(string)$s['root_path'],(int)($s['ssl_enabled']??0),(string)($s['php_version']??''));
    foreach(($data['folders']??[]) as $f) upsert_folder_row((string)$f['name'],(string)$f['path']);
    foreach(($data['ftp']??[]) as $f) upsert_ftp_row((string)$f['username'],(string)$f['target_path'],'',(string)($f['host']??host_name()));
    foreach(($data['databases']??[]) as $d) upsert_db_row((string)$d['db_name'],(string)$d['db_user'],(int)($d['remote_allowed']??0));
    foreach(($data['bots']??[]) as $b) upsert_bot_row_v5((string)$b['name'],(string)$b['runtime'],(string)$b['path'],(string)$b['start_command'],(int)($b['memory_limit_mb']??0));
}

function dns_apply_zone(string $domain): void
{
    $st=db()->prepare('SELECT * FROM dns_zones WHERE domain=?'); $st->execute([$domain]); $z=$st->fetch(); if(!$z) return;
    $rs=db()->prepare('SELECT type,name,value,ttl FROM dns_records WHERE zone_id=? ORDER BY id'); $rs->execute([(int)$z['id']]); $records=$rs->fetchAll();
    $res=run_ctl(['dns-apply',$domain,json_encode($records, JSON_UNESCAPED_UNICODE),(string)$z['primary_ns'],(string)$z['admin_email']],120); if($res['code']!==0) throw new RuntimeException($res['output']);
}

function bot_uploaded_tmp(string $field): string
{
    if (empty($_FILES[$field]['tmp_name']) || !is_uploaded_file($_FILES[$field]['tmp_name'])) return '';
    $dir = '/tmp/hyper-host-bot-uploads';
    if (!is_dir($dir)) mkdir($dir, 0700, true);
    $name = basename((string)$_FILES[$field]['name']);
    if ($name === '' || preg_match('/[\\\/]/', $name)) throw new RuntimeException('Неверное имя файла бота');
    $target = $dir . '/' . bin2hex(random_bytes(8)) . '-' . $name;
    if (!move_uploaded_file($_FILES[$field]['tmp_name'], $target)) throw new RuntimeException('Не удалось загрузить файл бота: ' . $name);
    @chmod($target, 0600);
    return $target;
}

function fm_save_file(): void
{
    [$rk,$root,$rel,$path]=fm_resolve((string)($_POST['root']??'sites'),(string)($_POST['path']??'')); if(is_dir($path)) throw new RuntimeException('Это папка');
    $content=(string)($_POST['content']??''); $ok=@file_put_contents($path,$content,LOCK_EX); if($ok===false){ run_ctl(['repair'],180); $ok=@file_put_contents($path,$content,LOCK_EX); }
    if($ok===false) throw new RuntimeException('Не удалось сохранить файл. Нажми Настройки → Починить права и сервисы.'); flash('Файл сохранён','success');
}
function fm_upload_file(): void
{
    [$rk,$root,$rel,$path]=fm_resolve((string)($_POST['root']??'sites'),(string)($_POST['path']??''));
    if(!is_dir($path)) throw new RuntimeException('Папка не найдена');
    $files=[];
    if(isset($_FILES['files'])) {
        $count=is_array($_FILES['files']['name'])?count($_FILES['files']['name']):0;
        for($i=0;$i<$count;$i++) $files[]=['name'=>$_FILES['files']['name'][$i]??'', 'tmp'=>$_FILES['files']['tmp_name'][$i]??'', 'error'=>$_FILES['files']['error'][$i]??UPLOAD_ERR_NO_FILE];
    } elseif(isset($_FILES['file'])) {
        $files[]=['name'=>$_FILES['file']['name']??'', 'tmp'=>$_FILES['file']['tmp_name']??'', 'error'=>$_FILES['file']['error']??UPLOAD_ERR_NO_FILE];
    }
    $okCount=0;
    foreach($files as $f){
        if((int)$f['error']!==UPLOAD_ERR_OK || !is_uploaded_file((string)$f['tmp'])) continue;
        $name=basename((string)$f['name']);
        if($name==='' || !preg_match('/^[^\\\/]+$/',$name)) throw new RuntimeException('Неверное имя файла');
        $dst=$path.'/'.$name;
        if(!move_uploaded_file((string)$f['tmp'],$dst)){
            run_ctl(['repair'],180);
            if(!move_uploaded_file((string)$f['tmp'],$dst)) throw new RuntimeException('Не удалось загрузить файл: '.$name);
        }
        @chmod($dst,0664);
        $okCount++;
    }
    if($okCount<1) throw new RuntimeException('Файл не выбран');
    run_ctl(['repair'],180);
    flash('Загружено файлов: '.$okCount,'success');
}
function fm_mkdir(): void
{
    [$rk,$root,$rel,$path]=fm_resolve((string)($_POST['root']??'sites'),(string)($_POST['path']??'')); $name=trim((string)($_POST['name']??'')); if(!is_valid_folder_name($name)) throw new RuntimeException('Неверное имя папки'); if(!mkdir($path.'/'.$name,0775,true)&&!is_dir($path.'/'.$name)){ run_ctl(['repair'],180); if(!mkdir($path.'/'.$name,0775,true)&&!is_dir($path.'/'.$name)) throw new RuntimeException('Не удалось создать папку'); } flash('Папка создана','success');
}
function fm_delete(): void
{
    [$rk,$root,$rel,$path]=fm_resolve((string)($_POST['root']??'sites'),(string)($_POST['path']??'')); if($rel==='') throw new RuntimeException('Нельзя удалить корень'); rrmdir($path); flash('Удалено','success');
}
function rrmdir(string $path): void { if(is_dir($path)&&!is_link($path)){ foreach(scandir($path)?:[] as $i){ if($i==='.'||$i==='..') continue; rrmdir($path.'/'.$i);} if(!@rmdir($path)){ run_ctl(['repair'],180); @rmdir($path); } } else { if(!@unlink($path)){ run_ctl(['repair'],180); @unlink($path); } } }

function render_login(): void
{
    $flash=flash(); $need2fa=setting_get('security_2fa_enabled','0')==='1'; ?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HYPER-HOST</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet"><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet"><link href="/assets/style.css" rel="stylesheet"></head><body class="login-body"><div class="login-shell"><div class="login-card card-glass"><div class="brand-mark"><i class="fa-solid fa-bolt"></i></div><h1>HYPER-HOST</h1><p>powered by memes4u1337</p><?php if($flash): ?><div class="alert alert-<?= e($flash['type']) ?> py-2"><?= e($flash['message']) ?></div><?php endif; ?><form method="post" class="vstack gap-3"><?= csrf_field() ?><input class="form-control form-control-lg" name="username" placeholder="Логин" autofocus required><input class="form-control form-control-lg" type="password" name="password" placeholder="Пароль" required><?php if($need2fa): ?><input class="form-control form-control-lg" name="totp" placeholder="2FA код" inputmode="numeric"><?php endif; ?><button class="btn btn-primary btn-lg w-100"><i class="fa-solid fa-right-to-bracket me-2"></i>Войти</button></form></div></div></body></html><?php
}

function render_page(string $page, array $user): void
{
    $titles=['dashboard'=>'Дашборд','files'=>'Файловый менеджер','sites'=>'Сайты и папки','ftp'=>'FTP','databases'=>'Базы данных','bots'=>'Боты PM2 24/7','bot_logs'=>'Логи бота','backups'=>'Backup','dns'=>'DNS','network'=>'Сеть и доступ','ssl'=>'SSL','php'=>'PHP-версии','cron'=>'Cron','logs'=>'Логи сайтов','security'=>'Безопасность','settings'=>'Настройки']; $title=$titles[$page]??'Дашборд'; $flash=flash(); ?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?= e($title) ?> — HYPER-HOST</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet"><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet"><link href="/assets/style.css" rel="stylesheet"></head><body><div class="app-shell"><aside class="sidebar"><div class="brand"><div class="brand-icon"><i class="fa-solid fa-bolt"></i></div><div><b>HYPER-HOST</b><span>powered by memes4u1337</span></div></div><nav class="nav flex-column gap-1 mt-4"><?= nav_item('dashboard','fa-gauge-high','Дашборд',$page) ?><?= nav_item('files','fa-folder-open','Файлы',$page) ?><?= nav_item('sites','fa-globe','Сайты',$page) ?><?= nav_item('ftp','fa-network-wired','FTP',$page) ?><?= nav_item('databases','fa-database','Базы',$page) ?><?= nav_item('bots','fa-robot','Боты PM2',$page) ?><?= nav_item('backups','fa-box-archive','Backup',$page) ?><?= nav_item('dns','fa-diagram-project','DNS',$page) ?><?= nav_item('network','fa-tower-broadcast','Сеть',$page) ?><?= nav_item('ssl','fa-shield-halved','SSL',$page) ?><?= nav_item('php','fa-code','PHP',$page) ?><?= nav_item('cron','fa-clock','Cron',$page) ?><?= nav_item('logs','fa-file-lines','Логи',$page) ?><?= nav_item('security','fa-lock','Безопасность',$page) ?><?= nav_item('settings','fa-sliders','Настройки',$page) ?></nav><div class="sidebar-footer"><a href="/?page=logout" class="btn btn-outline-light w-100"><i class="fa-solid fa-arrow-right-from-bracket me-2"></i>Выйти</a></div></aside><main class="content"><header class="topbar"><div><h1><?= e($title) ?></h1><div class="small muted">Сервер: <code><?= e(host_name()) ?></code> <span class="speed-badge"><i class="fa-solid fa-bolt"></i> fast mode</span></div></div><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="sync_resources"><button class="btn btn-soft"><i class="fa-solid fa-rotate me-2"></i>Синхронизация</button></form></header><?php if($flash): ?><div class="alert alert-<?= e($flash['type']) ?> shadow-sm"><i class="fa-solid fa-circle-info me-2"></i><?= nl2br(e($flash['message'])) ?></div><?php endif; ?><?php route_view($page); ?></main></div><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script><script src="/assets/app.js"></script></body></html><?php
}
function nav_item(string $id,string $icon,string $label,string $page): string { $active=$id===$page?' active':''; return '<a class="nav-link'.$active.'" href="/?page='.e($id).'"><i class="fa-solid '.e($icon).'"></i><span>'.e($label).'</span></a>'; }
function route_view(string $page): void { match($page){ 'files'=>view_files(), 'sites'=>view_sites(), 'ftp'=>view_ftp(), 'databases'=>view_databases(), 'bots'=>view_bots(), 'bot_logs'=>view_bot_logs(), 'backups'=>view_backups(), 'dns'=>view_dns(), 'network'=>view_network(), 'ssl'=>view_ssl(), 'php'=>view_php(), 'cron'=>view_cron(), 'logs'=>view_logs(), 'security'=>view_security(), 'settings'=>view_settings(), default=>view_dashboard(), }; }
function stat_card(string $icon,string $label,string $value,string $sub=''): void { ?><div class="stat-card"><div class="stat-icon"><i class="fa-solid <?= e($icon) ?>"></i></div><div><span><?= e($label) ?></span><b><?= e($value) ?></b><?php if($sub): ?><em><?= e($sub) ?></em><?php endif; ?></div></div><?php }
function progress_block(string $label,float $used,float $total): string { $p=percent($used,$total); return '<div class="usage"><div class="d-flex justify-content-between"><span>'.e($label).'</span><b>'.e(human_bytes($used).' / '.human_bytes($total)).'</b></div><div class="progress"><div class="progress-bar" style="width:'.$p.'%"></div></div></div>'; }

function view_dashboard(): void
{ $stats=run_ctl_json_cached(['stats-json'],8,45); $events=db()->query('SELECT * FROM events ORDER BY id DESC LIMIT 8')->fetchAll(); $sites=table_count('sites'); $ftp=table_count('ftp_accounts'); $bots=table_count('bots'); $backups=table_count('backup_jobs'); ?>
<div class="dashboard-hero mb-4">
  <div>
    <div class="eyebrow"><i class="fa-solid fa-rocket"></i> HYPER-HOST Control Center</div>
    <h2>Сервер под контролем</h2>
    <p>Сайты, SSL, FTP, базы, боты и backup — всё в одном быстром интерфейсе.</p>
  </div>
  <div class="hero-actions">
    <a class="btn btn-primary" href="/?page=sites"><i class="fa-solid fa-plus me-2"></i>Сайт</a>
    <a class="btn btn-soft" href="/?page=bots"><i class="fa-solid fa-robot me-2"></i>Бот</a>
    <a class="btn btn-soft" href="/?page=ssl"><i class="fa-solid fa-shield-halved me-2"></i>SSL</a>
  </div>
</div>
<div class="row g-3 mb-4">
  <div class="col-md-3"><?php stat_card('fa-globe','Сайты',(string)$sites,'домены') ?></div>
  <div class="col-md-3"><?php stat_card('fa-network-wired','FTP',(string)$ftp,'аккаунты') ?></div>
  <div class="col-md-3"><?php stat_card('fa-robot','Боты',(string)$bots,'PM2 24/7') ?></div>
  <div class="col-md-3"><?php stat_card('fa-box-archive','Backup',(string)$backups,'задачи') ?></div>
</div>
<div class="quick-grid mb-4">
  <a class="quick-card" href="/?page=files"><i class="fa-solid fa-folder-open"></i><b>Файлы</b><span>Загрузка и редактор</span></a>
  <a class="quick-card" href="/?page=databases"><i class="fa-solid fa-database"></i><b>Базы</b><span>MySQL/phpMyAdmin</span></a>
  <a class="quick-card" href="/?page=backups"><i class="fa-solid fa-box-archive"></i><b>Backup</b><span>Архивы и расписание</span></a>
  <a class="quick-card" href="/?page=settings"><i class="fa-solid fa-screwdriver-wrench"></i><b>Ремонт</b><span>Права и сервисы</span></a>
</div>
<div class="row g-4"><div class="col-xl-8"><div class="panel-card"><div class="card-title-row"><h2><i class="fa-solid fa-microchip me-2"></i>Железо сервера</h2><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="repair_panel"><button class="btn btn-primary btn-sm"><i class="fa-solid fa-screwdriver-wrench me-1"></i>Починить</button></form></div><?php if(isset($stats['_error'])): ?><div class="alert alert-warning"><?= e($stats['_error']) ?></div><?php else: ?><div class="hardware-grid"><div><span>CPU</span><b><?= e((string)$stats['cpu_model']) ?></b></div><div><span>Ядра</span><b><?= e((string)$stats['cpu_cores']) ?></b></div><div><span>Uptime</span><b><?= e((string)$stats['uptime']) ?></b></div><div><span>PM2</span><b><?= e((string)($stats['pm2_version']?:'not installed')) ?></b></div></div><?= progress_block('RAM',(float)$stats['mem_used'],(float)$stats['mem_total']) ?><?= progress_block('Диск /',(float)$stats['disk_used'],(float)$stats['disk_total']) ?><div class="service-row mt-3"><?php foreach(($stats['services']??[]) as $name=>$st): ?><span class="badge rounded-pill text-bg-<?= $st==='active'?'success':'danger' ?>"><?= e($name) ?>: <?= e((string)$st) ?></span><?php endforeach; ?></div><?php endif; ?></div></div><div class="col-xl-4"><div class="panel-card"><h2><i class="fa-solid fa-clock-rotate-left me-2"></i>Последние события</h2><?php foreach($events as $ev): ?><div class="event"><b><?= e($ev['type']) ?></b><span><?= e($ev['message']) ?></span><small><?= e($ev['created_at']) ?></small></div><?php endforeach; if(!$events): ?><div class="empty">Событий пока нет</div><?php endif; ?></div></div></div><?php }

function view_files(): void
{ $rootKey=(string)($_GET['root']??'sites'); $rel=safe_rel_path((string)($_GET['path']??'')); [$rootKey,$root,$rel,$path]=fm_resolve($rootKey,$rel); $items=is_dir($path)?array_values(array_diff(scandir($path)?:[],['.','..'])):[]; sort($items); $currentDir=is_dir($path)?$rel:dirname($rel); if($currentDir==='.')$currentDir=''; ?>
<div class="file-manager-layout">
  <section class="panel-card pc-panel">
    <h2><i class="fa-solid fa-desktop me-2"></i>Мой ПК</h2>
    <p class="muted">Выбери один или несколько файлов с компьютера и загрузи в текущую папку сервера.</p>
    <form method="post" enctype="multipart/form-data" class="upload-dropzone">
      <?= csrf_field() ?><input type="hidden" name="action" value="upload_file"><input type="hidden" name="root" value="<?= e($rootKey) ?>"><input type="hidden" name="path" value="<?= e($currentDir) ?>">
      <i class="fa-solid fa-cloud-arrow-up"></i>
      <b>Загрузка в серверную папку</b>
      <span><?= e($root.'/'.$currentDir) ?></span>
      <input class="form-control mt-3" type="file" name="files[]" multiple required>
      <button class="btn btn-primary w-100 mt-3">Загрузить на сервер</button>
    </form>
    <div class="panel-card mini-card mt-3"><h2>Новая папка</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="mkdir_file"><input type="hidden" name="root" value="<?= e($rootKey) ?>"><input type="hidden" name="path" value="<?= e($currentDir) ?>"><input class="form-control" name="name" placeholder="assets" required><button class="btn btn-soft">Создать папку</button></form></div>
  </section>
  <section class="panel-card server-panel">
    <div class="card-title-row"><h2><i class="fa-solid fa-server me-2"></i>Сервер</h2><div class="btn-group"><?php foreach(file_manager_roots() as $k=>$r): ?><a class="btn btn-sm <?= $rootKey===$k?'btn-primary':'btn-soft' ?>" href="/?page=files&root=<?= e($k) ?>"><?= e($r['label']) ?></a><?php endforeach; ?></div></div>
    <div class="breadcrumb-line mt-2"><code><?= e($root.'/'.$rel) ?></code></div>
    <?php if(is_dir($path)): ?><div class="table-responsive mt-3"><table class="table table-dark-soft align-middle"><tbody><?php if($rel!==''): $up=dirname($rel); if($up==='.')$up=''; ?><tr><td colspan="4"><a href="/?page=files&root=<?= e($rootKey) ?>&path=<?= e($up) ?>"><i class="fa-solid fa-arrow-left me-2"></i>назад</a></td></tr><?php endif; foreach($items as $it): $p=$path.'/'.$it; $r=trim($rel.'/'.$it,'/'); ?><tr><td><i class="fa-solid <?= is_dir($p)?'fa-folder text-warning':'fa-file-code text-info' ?> me-2"></i><a href="/?page=files&root=<?= e($rootKey) ?>&path=<?= e($r) ?>"><?= e($it) ?></a></td><td><?= is_file($p)?e(human_bytes((float)filesize($p))):'папка' ?></td><td><?= e(date('d.m.Y H:i', filemtime($p) ?: time())) ?></td><td class="text-end"><form method="post" onsubmit="return confirm('Удалить?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_file"><input type="hidden" name="root" value="<?= e($rootKey) ?>"><input type="hidden" name="path" value="<?= e($r) ?>"><button class="btn btn-sm btn-outline-danger"><i class="fa-solid fa-trash"></i></button></form></td></tr><?php endforeach; if(!$items): ?><tr><td colspan="4" class="empty">Папка пустая</td></tr><?php endif; ?></tbody></table></div><?php else: $content=is_file($path)?file_get_contents($path):''; ?><form method="post" class="mt-3"><?= csrf_field() ?><input type="hidden" name="action" value="save_file"><input type="hidden" name="root" value="<?= e($rootKey) ?>"><input type="hidden" name="path" value="<?= e($rel) ?>"><textarea class="form-control code-editor" name="content" spellcheck="false"><?= e($content===false?'':$content) ?></textarea><button class="btn btn-primary mt-3">Сохранить файл</button><a class="btn btn-soft mt-3" href="/?page=files&root=<?= e($rootKey) ?>&path=<?= e(dirname($rel)==='.'?'':dirname($rel)) ?>">Назад</a></form><?php endif; ?>
  </section>
</div><?php }

function view_sites(): void
{ $sites=db()->query('SELECT * FROM sites ORDER BY id DESC')->fetchAll(); $folders=db()->query('SELECT * FROM folders ORDER BY id DESC')->fetchAll(); $php=run_ctl_json_cached(['php-list-json'],20,60); ?>
<div class="row g-4"><div class="col-lg-4"><div class="panel-card"><h2>Создать сайт</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="add_site"><input class="form-control" name="domain" placeholder="hyper-host.pw" required><input class="form-control" name="aliases" placeholder="www.hyper-host.pw"><select class="form-select" name="php_version"><option value="">PHP по умолчанию</option><?php foreach(($php['_error']??null)?[]:$php as $p): ?><option value="<?= e($p['version']) ?>">PHP <?= e($p['version']) ?></option><?php endforeach; ?></select><button class="btn btn-primary">Создать сайт</button></form></div><div class="panel-card mt-4"><h2>Создать папку-сайт</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_folder"><input class="form-control" name="name" placeholder="test-site" required><button class="btn btn-primary">Создать папку</button></form></div></div><div class="col-lg-8"><div class="panel-card"><h2>Сайты</h2><div class="table-responsive"><table class="table table-dark-soft align-middle"><thead><tr><th>Домен</th><th>Папка</th><th>PHP/SSL</th><th></th></tr></thead><tbody><?php foreach($sites as $s): ?><tr><td><b><?= e($s['domain']) ?></b><div class="small muted"><?= e($s['aliases']) ?></div></td><td><code><?= e($s['root_path']) ?></code></td><td><span class="badge text-bg-info">PHP <?= e($s['php_version']?:'default') ?></span> <span class="badge text-bg-<?= (int)$s['ssl_enabled']?'success':'secondary' ?>"><?= (int)$s['ssl_enabled']?'SSL':'HTTP' ?></span></td><td class="text-end"><a class="btn btn-sm btn-soft" href="/?page=files&root=sites&path=<?= e($s['domain'].'/public_html') ?>">Файлы</a><form method="post" class="d-inline" onsubmit="return confirm('Удалить сайт?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$sites): ?><tr><td colspan="4" class="empty">Сайтов пока нет</td></tr><?php endif; ?></tbody></table></div><h2 class="mt-4">Папки</h2><div class="table-responsive"><table class="table table-dark-soft"><tbody><?php foreach($folders as $f): ?><tr><td><b><?= e($f['name']) ?></b></td><td><code><?= e($f['path']) ?></code></td><td class="text-end"><a class="btn btn-sm btn-soft" href="/?page=files&root=sites&path=<?= e($f['name'].'/public_html') ?>">Файлы</a></td></tr><?php endforeach; if(!$folders): ?><tr><td class="empty">Папок пока нет</td></tr><?php endif; ?></tbody></table></div></div></div></div><?php }

function view_ftp(): void
{ $rows=db()->query('SELECT * FROM ftp_accounts ORDER BY id DESC')->fetchAll(); $gen=default_ftp_password(); ?>
<div class="row g-4"><div class="col-lg-4"><div class="panel-card"><h2>Создать FTP</h2><p class="muted">После входа будет одна общая папка <code>common/</code>. Внутри неё: <code>sites/</code> со всеми сайтами и <code>bots/</code> со всеми ботами.</p><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_ftp"><input class="form-control" name="username" placeholder="hyperhost" required><div class="input-group"><input class="form-control" name="password" id="ftpPass" value="<?= e($gen) ?>" minlength="8" required><button class="btn btn-outline-light" type="button" onclick="copyValue('ftpPass')"><i class="fa-regular fa-copy"></i></button></div><button class="btn btn-primary">Создать FTP</button></form></div></div><div class="col-lg-8"><div class="row g-3"><?php foreach($rows as $r): ?><div class="col-md-6"><div class="ftp-card"><h3><?= e($r['username']) ?></h3><div class="cred"><span>Хост</span><code><?= e($r['host']?:host_name()) ?></code></div><div class="cred"><span>Имя пользователя</span><code><?= e($r['username']) ?></code></div><div class="cred"><span>Пароль</span><code><?= e($r['password_plain']?:'задать новый') ?></code></div><div class="small mt-3">Путь после входа: <code>common/sites/</code> и <code>common/bots/</code><br>Порт: <b>21</b>, Passive: <b>40000-40100</b></div><div class="d-flex gap-2 mt-3"><button class="btn btn-sm btn-light" onclick="copyText('Host: <?= e($r['host']?:host_name()) ?>\nLogin: <?= e($r['username']) ?>\nPassword: <?= e($r['password_plain']) ?>\nPort: 21')">Копировать</button><button class="btn btn-sm btn-outline-light" data-bs-toggle="modal" data-bs-target="#ftp<?= (int)$r['id'] ?>">Пароль</button><form method="post" onsubmit="return confirm('Удалить FTP?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_ftp"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-danger">Удалить</button></form></div></div></div><div class="modal fade" id="ftp<?= (int)$r['id'] ?>"><div class="modal-dialog"><div class="modal-content"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="reset_ftp_password"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><div class="modal-header"><h5>Новый пароль FTP</h5><button class="btn-close" data-bs-dismiss="modal" type="button"></button></div><div class="modal-body"><input class="form-control" name="password" value="<?= e(default_ftp_password()) ?>" minlength="8" required></div><div class="modal-footer"><button class="btn btn-primary">Сохранить</button></div></form></div></div></div><?php endforeach; if(!$rows): ?><div class="empty">FTP аккаунтов пока нет</div><?php endif; ?></div></div></div><?php }

function pm2_status_map(): array { $d=run_ctl_json_cached(['bot-list-json'],10,25); $m=[]; if(!isset($d['_error'])) foreach($d as $p) $m[$p['name']]=$p; return $m; }
function view_bots(): void
{ $bots=db()->query('SELECT * FROM bots ORDER BY id DESC')->fetchAll(); $status=pm2_status_map(); ?>
<div class="row g-4">
  <div class="col-lg-4">
    <div class="panel-card">
      <h2>Загрузить и запустить бота</h2>
      <p class="muted">Загрузи <code>bot.py</code>, при необходимости <code>.env</code> и <code>requirements.txt</code>. Панель поставит зависимости, запустит PM2 и сохранит автозапуск: можно закрывать панель/SSH — бот продолжит работать.</p>
      <form method="post" enctype="multipart/form-data" class="vstack gap-3">
        <?= csrf_field() ?><input type="hidden" name="action" value="create_bot">
        <input class="form-control" name="name" placeholder="mystockbot" required>
        <select class="form-select" name="runtime"><option value="python">Python</option><option value="node">Node.js</option><option value="php">PHP</option><option value="custom">Custom bash</option></select>
        <input class="form-control" name="main_file" value="bot.py" placeholder="bot.py">
        <label class="form-label mb-0">Основной файл</label><input class="form-control" type="file" name="bot_file" accept=".py,.js,.php,.sh,.txt">
        <label class="form-label mb-0">.env — можно пропустить</label><input class="form-control" type="file" name="env_file" accept=".env,.txt">
        <label class="form-label mb-0">requirements.txt / package.json — можно пропустить</label><input class="form-control" type="file" name="requirements_file" accept=".txt,.json">
        <input class="form-control" type="number" name="memory_limit_mb" placeholder="RAM лимит, MB, например 512">
        <button class="btn btn-primary">Загрузить, поставить зависимости и запустить</button>
      </form>
    </div>
  </div>
  <div class="col-lg-8">
    <div class="panel-card">
      <div class="card-title-row"><h2>Список ботов PM2</h2><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="pm2_persist"><button class="btn btn-soft btn-sm"><i class="fa-solid fa-shield-heart me-1"></i>Включить 24/7</button></form></div>
      <div class="alert alert-dark-soft small mb-3"><i class="fa-solid fa-circle-check me-2 text-success"></i>После запуска бот не зависит от открытой панели или консоли. PM2 сохраняется в systemd и поднимает ботов после перезагрузки.</div>
      <div class="table-responsive"><table class="table table-dark-soft align-middle"><thead><tr><th>Бот</th><th>Статус</th><th>Файлы</th><th>Управление</th></tr></thead><tbody>
      <?php foreach($bots as $b): $pm=$status[$b['name']]??[]; $st=$pm['status']??'not_found'; $files=$pm['files']??[]; ?>
        <tr>
          <td><b><?= e($b['name']) ?></b><div class="small muted"><code><?= e($b['path']) ?></code></div><div class="small muted">PM2 name: <code><?= e($b['name']) ?></code></div></td>
          <td><span class="badge text-bg-<?= $st==='online'?'success':'danger' ?>"><?= e($st) ?></span><div class="small muted">RAM: <?= isset($pm['memory'])?e(human_bytes((float)$pm['memory'])):'?' ?></div></td>
          <td><?php if($files): foreach($files as $f): ?><span class="badge text-bg-secondary me-1"><?= e($f) ?></span><?php endforeach; else: ?><span class="muted">нет данных</span><?php endif; ?></td>
          <td class="text-end">
            <div class="btn-group btn-group-sm flex-wrap">
              <?php foreach(['start'=>'Start','stop'=>'Stop','restart'=>'Restart','install'=>'Deps'] as $cmd=>$label): ?>
                <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="bot_action"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>"><input type="hidden" name="bot_action" value="<?= e($cmd) ?>"><button class="btn btn-outline-primary"><?= e($label) ?></button></form>
              <?php endforeach; ?>
              <form method="post" onsubmit="return confirm('Остановить локальные дубли этого бота? Это помогает при TelegramConflictError getUpdates.')"><?= csrf_field() ?><input type="hidden" name="action" value="bot_action"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>"><input type="hidden" name="bot_action" value="kill-conflicts"><button class="btn btn-outline-warning">Fix conflict</button></form>
              <a class="btn btn-outline-light" href="/?page=bot_logs&id=<?= (int)$b['id'] ?>">Logs</a>
              <a class="btn btn-outline-light" href="/?page=files&root=bots&path=<?= e($b['name']) ?>">Files</a>
              <button class="btn btn-outline-danger" data-bs-toggle="modal" data-bs-target="#deleteBot<?= (int)$b['id'] ?>">Delete</button>
            </div>
          </td>
        </tr>
        <div class="modal fade" id="deleteBot<?= (int)$b['id'] ?>" tabindex="-1">
          <div class="modal-dialog modal-dialog-centered"><div class="modal-content">
            <div class="modal-header"><h5 class="modal-title">Удалить бота <?= e($b['name']) ?>?</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
            <div class="modal-body">
              <div class="alert alert-warning">Можно удалить только процесс из PM2 и оставить файлы, либо удалить процесс и всю папку бота с сервера.</div>
              <div class="small muted mb-2">Папка бота: <code><?= e($b['path']) ?></code></div>
              <form method="post" class="vstack gap-3">
                <?= csrf_field() ?><input type="hidden" name="action" value="delete_bot"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>">
                <button class="btn btn-outline-warning" onclick="return confirm('Удалить бота только из PM2? Файлы останутся на сервере.')">Удалить только из PM2, файлы оставить</button>
              </form>
              <hr>
              <form method="post" class="vstack gap-3">
                <?= csrf_field() ?><input type="hidden" name="action" value="delete_bot"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>"><input type="hidden" name="delete_files" value="1">
                <label class="form-label">Чтобы удалить файлы, введи точное имя бота:</label>
                <input class="form-control" name="confirm_name" placeholder="<?= e($b['name']) ?>" required>
                <button class="btn btn-danger" onclick="return confirm('ТОЧНО удалить PM2-процесс и все файлы этого бота с сервера?')">Удалить PM2 + файлы с сервера</button>
              </form>
            </div>
          </div></div>
        </div>
      <?php endforeach; if(!$bots): ?><tr><td colspan="4" class="empty">Ботов пока нет</td></tr><?php endif; ?>
      </tbody></table></div>
    </div>
  </div>
</div><?php }
function view_bot_logs(): void { $id=(int)($_GET['id']??0); $st=db()->prepare('SELECT * FROM bots WHERE id=?'); $st->execute([$id]); $b=$st->fetch(); if(!$b){echo '<div class="panel-card empty">Бот не найден</div>';return;} $res=run_ctl(['bot','logs',$b['name']],30); ?><div class="panel-card"><div class="card-title-row"><h2>Логи PM2: <?= e($b['name']) ?></h2><a class="btn btn-soft" href="/?page=bots">Назад</a></div><pre class="logs"><?= e($res['output']?:'Логов пока нет') ?></pre></div><?php }

function view_backups(): void { $jobs=db()->query('SELECT * FROM backup_jobs ORDER BY id DESC')->fetchAll(); $files=run_ctl_json(['backup-list-json'],30); ?>
<div class="row g-4"><div class="col-lg-4"><div class="panel-card"><h2>Создать backup сейчас</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="backup_run"><select class="form-select" name="target"><option value="all">Всё</option><option value="sites">Сайты</option><option value="bots">Боты</option><option value="db">Базы MySQL</option><option value="panel">Панель</option></select><button class="btn btn-primary">Создать backup</button></form></div><div class="panel-card mt-4"><h2>Расписание</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="backup_job"><input class="form-control" name="name" placeholder="daily_all" required><input class="form-control" name="schedule" value="0 3 * * *" required><select class="form-select" name="target"><option value="all">Всё</option><option value="sites">Сайты</option><option value="bots">Боты</option><option value="db">Базы</option></select><button class="btn btn-primary">Сохранить расписание</button></form></div></div><div class="col-lg-8"><div class="panel-card"><h2>Backup задачи</h2><table class="table table-dark-soft"><?php foreach($jobs as $j): ?><tr><td><b><?= e($j['name']) ?></b></td><td><code><?= e($j['schedule']) ?></code></td><td><?= e($j['target']) ?></td><td><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="delete_backup_job"><input type="hidden" name="id" value="<?= (int)$j['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$jobs): ?><tr><td class="empty">Задач пока нет</td></tr><?php endif; ?></table><h2 class="mt-4">Архивы</h2><table class="table table-dark-soft"><?php foreach(($files['_error']??null)?[]:$files as $f): ?><tr><td><code><?= e($f['name']) ?></code></td><td><?= e(human_bytes((float)$f['size'])) ?></td><td><?= e(date('d.m.Y H:i',(int)$f['mtime'])) ?></td></tr><?php endforeach; ?></table></div></div></div><?php }

function view_dns(): void { $zones=db()->query('SELECT * FROM dns_zones ORDER BY id DESC')->fetchAll(); $pub=setting_get('public_ip_override',(string)app_config('public_ip','90.189.208.25')); ?>
<div class="row g-4">
  <div class="col-xl-4">
    <div class="panel-card hero-mini">
      <div class="kicker"><i class="fa-solid fa-diagram-project me-2"></i>DNS перенос доменов</div>
      <h2>Свои NS для HYPER-HOST</h2>
      <p class="muted">Создай DNS-зону, потом у регистратора домена поставь <code>ns1.domain</code> и <code>ns2.domain</code>. Для домашнего сервера обязательно пробрось TCP/UDP 53 на сервер.</p>
      <form method="post" class="vstack gap-3 mt-3"><?= csrf_field() ?><input type="hidden" name="action" value="dns_wizard">
        <input class="form-control" name="domain" placeholder="hyper-host.pw" required>
        <input class="form-control" name="public_ip" value="<?= e($pub) ?>" placeholder="90.189.208.25">
        <input class="form-control" name="panel_subdomain" value="panel" placeholder="panel">
        <button class="btn btn-primary btn-lg"><i class="fa-solid fa-wand-magic-sparkles me-2"></i>Создать DNS автоматически</button>
      </form>
    </div>
    <div class="panel-card mt-4">
      <h2>Что ставить у регистратора</h2>
      <div class="dns-steps">
        <div><b>NS 1</b><code>ns1.твой-домен</code></div>
        <div><b>NS 2</b><code>ns2.твой-домен</code></div>
        <div><b>Glue A</b><code>ns1/ns2 → <?= e($pub) ?></code></div>
        <div><b>Порты</b><code>53 TCP/UDP → <?= e((string)app_config('server_ip')) ?></code></div>
      </div>
      <pre class="logs mt-3">sudo hyper dns wizard hyper-host.pw <?= e($pub) ?> panel
sudo hyper dns status hyper-host.pw</pre>
    </div>
  </div>
  <div class="col-xl-8">
    <?php foreach($zones as $z): $rs=db()->prepare('SELECT * FROM dns_records WHERE zone_id=? ORDER BY id'); $rs->execute([(int)$z['id']]); $recs=$rs->fetchAll(); $status=run_ctl_json_cached(['dns-status-json',$z['domain']],12,20); ?>
      <div class="panel-card mb-4">
        <div class="card-title-row align-items-start"><div><h2><?= e($z['domain']) ?></h2><div class="small muted">NS: <code>ns1.<?= e($z['domain']) ?></code> / <code>ns2.<?= e($z['domain']) ?></code></div></div><form method="post" onsubmit="return confirm('Удалить DNS зону?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_dns_zone"><input type="hidden" name="id" value="<?= (int)$z['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></div>
        <div class="status-grid mb-3">
          <div><span>Bind9</span><b class="<?= !empty($status['bind9_ok'])?'text-success':'text-danger' ?>"><?= !empty($status['bind9_ok'])?'работает':'ошибка' ?></b></div>
          <div><span>Zone</span><b class="<?= !empty($status['zone_ok'])?'text-success':'text-danger' ?>"><?= !empty($status['zone_ok'])?'ok':'bad' ?></b></div>
          <div><span>53 UDP</span><b class="<?= !empty($status['listen_53_udp'])?'text-success':'text-warning' ?>"><?= !empty($status['listen_53_udp'])?'слушает':'нет' ?></b></div>
          <div><span>Public A</span><b><?= e(implode(', ', $status['public_a'] ?? [])) ?: 'ещё не делегирован' ?></b></div>
        </div>
        <form method="post" class="row g-2 mb-3"><?= csrf_field() ?><input type="hidden" name="action" value="add_dns_record"><input type="hidden" name="zone_id" value="<?= (int)$z['id'] ?>"><div class="col-md-2"><select class="form-select" name="type"><option>A</option><option>AAAA</option><option>CNAME</option><option>MX</option><option>TXT</option><option>NS</option></select></div><div class="col-md-2"><input class="form-control" name="name" value="@"></div><div class="col-md-5"><input class="form-control" name="value" placeholder="IP / value"></div><div class="col-md-2"><input class="form-control" name="ttl" value="300"></div><div class="col-md-1"><button class="btn btn-primary w-100">+</button></div></form>
        <div class="table-responsive"><table class="table table-dark-soft align-middle"><thead><tr><th>Тип</th><th>Имя</th><th>Значение</th><th>TTL</th><th></th></tr></thead><tbody><?php foreach($recs as $r): ?><tr><td><span class="badge text-bg-secondary"><?= e($r['type']) ?></span></td><td><?= e($r['name']) ?></td><td><code><?= e($r['value']) ?></code></td><td><?= (int)$r['ttl'] ?></td><td class="text-end"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="delete_dns_record"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-outline-danger">x</button></form></td></tr><?php endforeach; ?></tbody></table></div>
      </div>
    <?php endforeach; if(!$zones): ?><div class="panel-card empty">DNS зон пока нет. Нажми “Создать DNS автоматически”.</div><?php endif; ?>
  </div>
</div><?php }

function view_network(): void { $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll(); $domain=(string)($_GET['domain']??($sites[0]['domain']??'hyper-host.pw')); $pub=setting_get('public_ip_override',(string)app_config('public_ip','90.189.208.25')); $doctor=run_ctl_json_cached(['network-doctor-json',$domain],12,12); ?>
<div class="row g-4">
  <div class="col-xl-5"><div class="panel-card hero-mini"><div class="kicker"><i class="fa-solid fa-tower-broadcast me-2"></i>Внешний / внутренний доступ</div><h2>Сеть должна работать всегда</h2><p class="muted">Сервер внутри сети: <code><?= e((string)app_config('server_ip')) ?></code>. Домен снаружи должен смотреть на публичный IP: <code><?= e($pub) ?></code>. Nginx должен слушать все IP, а роутер должен пробрасывать 80/443.</p>
    <form method="post" class="vstack gap-3 mt-3"><?= csrf_field() ?><input type="hidden" name="action" value="network_fix"><input class="form-control" name="domain" value="<?= e($domain) ?>" placeholder="hyper-host.pw"><input class="form-control" name="public_ip" value="<?= e($pub) ?>" placeholder="90.189.208.25"><button class="btn btn-primary btn-lg"><i class="fa-solid fa-screwdriver-wrench me-2"></i>Починить сеть и SSL-доступ</button></form>
    <form method="post" class="vstack gap-2 mt-4"><?= csrf_field() ?><input type="hidden" name="action" value="save_panel_domain"><label class="form-label">Домен панели</label><input class="form-control" name="panel_domain" placeholder="panel.hyper-host.pw"><button class="btn btn-soft">Привязать домен панели</button></form>
  </div></div>
  <div class="col-xl-7"><div class="panel-card"><h2>Диагностика доступа</h2><div class="status-grid">
    <div><span>Публичный IP</span><b><?= e((string)($doctor['public_ip'] ?? $pub)) ?></b></div>
    <div><span>DNS A</span><b><?= e(implode(', ', $doctor['dns_a'] ?? [])) ?: 'нет' ?></b></div>
    <div><span>Nginx</span><b class="<?= !empty($doctor['nginx_ok'])?'text-success':'text-danger' ?>"><?= !empty($doctor['nginx_ok'])?'ok':'bad' ?></b></div>
    <div><span>80</span><b class="<?= !empty($doctor['listen_80'])?'text-success':'text-danger' ?>"><?= !empty($doctor['listen_80'])?'слушает':'закрыт' ?></b></div>
    <div><span>443</span><b class="<?= !empty($doctor['listen_443'])?'text-success':'text-danger' ?>"><?= !empty($doctor['listen_443'])?'слушает':'закрыт' ?></b></div>
    <div><span>ACME</span><b class="<?= !empty($doctor['local_acme_ok'])?'text-success':'text-warning' ?>"><?= !empty($doctor['local_acme_ok'])?'ok':'fix needed' ?></b></div>
  </div><?php if(!empty($doctor['problem'])): ?><div class="alert alert-warning mt-3 mb-0"><?= e((string)$doctor['problem']) ?></div><?php endif; ?><div class="alert alert-info mt-3 mb-0">На роутере: <b>TCP 80/443</b> → <code><?= e((string)app_config('server_ip')) ?></code>. Для своих DNS ещё <b>TCP/UDP 53</b> → <code><?= e((string)app_config('server_ip')) ?></code>. Проверяй с телефона через мобильный интернет, не через Wi‑Fi.</div><pre class="logs mt-3">sudo hyper network fix <?= e($domain) ?> <?= e($pub) ?>
sudo hyper network doctor <?= e($domain) ?>
sudo hyper ssl check <?= e($domain) ?></pre></div></div>
</div><?php }

function view_ssl(): void {
    $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll();
    $certs=run_ctl_json_cached(['ssl-status-json'],8,120); $map=[]; if(!isset($certs['_error'])) foreach($certs as $c) $map[$c['domain']]=$c;
    $savedPublicIp = setting_get('public_ip_override', (string)app_config('public_ip',''));
    $modals = [];
?>
<div class="ssl-hero mb-4">
  <div>
    <div class="eyebrow"><i class="fa-solid fa-shield-halved"></i> Let's Encrypt</div>
    <h2>SSL сертификаты</h2>
    <p>Быстрая проверка DNS, ACME и Nginx без зависаний. Если статус зелёный — можно выпускать сертификат.</p>
  </div>
  <div class="ssl-hero-actions">
    <form method="post" class="d-flex gap-2 flex-wrap">
      <?= csrf_field() ?><input type="hidden" name="action" value="save_public_ip">
      <input class="form-control public-ip-input" name="public_ip" value="<?= e($savedPublicIp) ?>" placeholder="90.189.208.25">
      <button class="btn btn-soft"><i class="fa-solid fa-floppy-disk me-2"></i>IP</button>
    </form>
    <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="ssl_renew_all"><button class="btn btn-primary"><i class="fa-solid fa-arrows-rotate me-2"></i>Автопродление</button></form>
  </div>
</div>
<div class="panel-card ssl-card">
  <div class="table-responsive"><table class="table table-dark-soft align-middle mb-0"><thead><tr><th>Сайт</th><th>Проверка</th><th>Сертификат</th><th class="text-end">Действия</th></tr></thead><tbody>
  <?php foreach($sites as $s):
      $c=$map[$s['domain']]??null;
      $dns=run_ctl_json_cached(['ssl-check-json',$s['domain']],10,90);
      $hasCert = $c && (($c['status'] ?? '') === 'ok');
      $ready=empty($dns['_error']) && !empty($dns['certbot_ready']);
      $points=empty($dns['_error']) && !empty($dns['points_here']);
      if($hasCert){ $badge='success'; $label='SSL работает'; }
      elseif($ready){ $badge='success'; $label='Можно выпускать'; }
      elseif($points){ $badge='info'; $label='DNS OK'; }
      else { $badge='warning'; $label='Нужна настройка'; }
      ob_start(); ?>
      <div class="modal fade hh-modal" id="ssl<?= (int)$s['id'] ?>" tabindex="-1" aria-hidden="true">
        <div class="modal-dialog modal-dialog-centered modal-lg"><div class="modal-content"><form method="post">
          <?= csrf_field() ?><input type="hidden" name="action" value="ssl_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>">
          <div class="modal-header"><div><div class="eyebrow mb-1"><i class="fa-solid fa-certificate"></i> SSL выпуск</div><h5 class="modal-title mb-0"><?= e($s['domain']) ?></h5></div><button class="btn-close" data-bs-dismiss="modal" type="button"></button></div>
          <div class="modal-body">
            <div class="ssl-ready-box <?= $ready ? 'ok' : 'warn' ?>">
              <i class="fa-solid <?= $ready ? 'fa-circle-check' : 'fa-triangle-exclamation' ?>"></i>
              <div><b><?= $ready ? 'Проверка пройдена' : 'Перед выпуском есть предупреждение' ?></b><span><?= $ready ? 'DNS и ACME challenge готовы. Можно выпускать сертификат.' : e((string)($dns['problem'] ?? 'Проверь DNS/ACME и попробуй ещё раз.')) ?></span></div>
            </div>
            <label class="form-label mt-3">Email для Let’s Encrypt</label>
            <input class="form-control form-control-lg" name="email" type="email" placeholder="email@example.com" required>
          </div>
          <div class="modal-footer"><button type="button" class="btn btn-soft" data-bs-dismiss="modal">Отмена</button><button class="btn btn-primary btn-lg"><i class="fa-solid fa-bolt me-2"></i>Выпустить SSL</button></div>
        </form></div></div>
      </div>
      <?php $modals[] = ob_get_clean(); ?>
    <tr>
      <td><b><?= e($s['domain']) ?></b><div class="small muted">A: <?= e(implode(', ', $dns['a'] ?? [])) ?: 'нет' ?></div><?php if(!empty($dns['configured_public_ip'])): ?><div class="small text-success">IP: <?= e((string)$dns['configured_public_ip']) ?></div><?php endif; ?></td>
      <td><span class="badge rounded-pill text-bg-<?= e($badge) ?>"><?= e($label) ?></span>
        <div class="small muted mt-1">Нужно: <code><?= e((string)($dns['required_a'] ?? '')) ?></code></div>
        <?php if(!empty($dns['outbound_public_ip']) && !empty($dns['configured_public_ip']) && $dns['outbound_public_ip']!==$dns['configured_public_ip']): ?><div class="small text-warning">NAT режим: исходящий IP отличается, это не мешает SSL при пробросе портов.</div><?php endif; ?>
        <?php if(!$hasCert && !empty($dns['problem'])): ?><div class="small text-danger mt-1"><?= e((string)$dns['problem']) ?></div><?php endif; ?>
      </td>
      <td><?= $hasCert?'<span class="badge rounded-pill text-bg-success">'.e((string)($c['days_left']??'?')).' дней</span>':'<span class="badge rounded-pill text-bg-secondary">нет SSL</span>' ?><div class="small muted"><?= e((string)($c['expires']??'')) ?></div></td>
      <td class="text-end"><div class="d-inline-flex gap-2 flex-wrap justify-content-end"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="ssl_fix_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><button class="btn btn-sm btn-outline-info"><i class="fa-solid fa-wand-magic-sparkles me-1"></i>Fix ACME</button></form><button class="btn btn-sm btn-primary" data-bs-toggle="modal" data-bs-target="#ssl<?= (int)$s['id'] ?>"><i class="fa-solid fa-certificate me-1"></i><?= $hasCert?'Перевыпустить':'Выпустить' ?></button></div></td>
    </tr>
  <?php endforeach; if(!$sites): ?><tr><td colspan="4" class="empty">Сайтов пока нет</td></tr><?php endif; ?>
  </tbody></table></div>
</div>
<?= implode("\n", $modals) ?>
<div class="panel-card mt-4">
  <h2><i class="fa-solid fa-network-wired me-2"></i>SSL на IP</h2>
  <p class="muted mb-2">Для домена используй Let’s Encrypt. Для локального IP доступен self-signed сертификат.</p>
  <pre class="logs mb-0">sudo hyper-host-ctl ssl-ip-selfsigned 192.168.0.179</pre>
</div>
<?php }

function view_php(): void { $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll(); $versions=run_ctl_json_cached(['php-list-json'],20,60); ?>
<div class="panel-card"><h2>PHP-версии по сайтам</h2><table class="table table-dark-soft align-middle"><tbody><?php foreach($sites as $s): ?><tr><td><b><?= e($s['domain']) ?></b><div class="small muted">текущая: PHP <?= e($s['php_version']?:'default') ?></div></td><td><form method="post" class="d-flex gap-2"><?= csrf_field() ?><input type="hidden" name="action" value="set_site_php"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><select class="form-select" name="php_version"><?php foreach(($versions['_error']??null)?[]:$versions as $v): ?><option value="<?= e($v['version']) ?>" <?= ($s['php_version']??'')===$v['version']?'selected':'' ?>>PHP <?= e($v['version']) ?></option><?php endforeach; ?></select><button class="btn btn-primary">Сохранить</button></form></td></tr><?php endforeach; ?></tbody></table><p class="muted">Панель переключает только уже установленные PHP-FPM версии. Новые версии PHP ставятся пакетами Ubuntu/PPA.</p></div><?php }

function view_cron(): void { $rows=db()->query('SELECT * FROM cron_tasks ORDER BY id DESC')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-4"><div class="panel-card"><h2>Новая cron-задача</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_cron"><input class="form-control" name="name" placeholder="clear_cache" required><input class="form-control" name="schedule" value="*/10 * * * *" required><input class="form-control" name="command" placeholder="php /var/www/site/artisan schedule:run" required><button class="btn btn-primary">Сохранить</button></form></div></div><div class="col-lg-8"><div class="panel-card"><h2>Cron задачи</h2><table class="table table-dark-soft"><?php foreach($rows as $r): ?><tr><td><b><?= e($r['name']) ?></b></td><td><code><?= e($r['schedule']) ?></code></td><td><code><?= e($r['command']) ?></code></td><td><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="delete_cron"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$rows): ?><tr><td class="empty">Cron-задач пока нет</td></tr><?php endif; ?></table></div></div></div><?php }

function view_logs(): void { $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll(); $domain=(string)($_GET['domain']??($sites[0]['domain']??'')); $kind=(string)($_GET['kind']??'error'); $filter=(string)($_GET['filter']??''); $out=''; if($domain) $out=run_ctl(['site-logs',$domain,$kind,'250',$filter],30)['output']; ?>
<div class="panel-card"><h2>Логи сайтов</h2><form method="get" class="row g-2 mb-3"><input type="hidden" name="page" value="logs"><div class="col-md-3"><select class="form-select" name="domain"><?php foreach($sites as $s): ?><option value="<?= e($s['domain']) ?>" <?= $domain===$s['domain']?'selected':'' ?>><?= e($s['domain']) ?></option><?php endforeach; ?></select></div><div class="col-md-2"><select class="form-select" name="kind"><option value="error" <?= $kind==='error'?'selected':'' ?>>error</option><option value="access" <?= $kind==='access'?'selected':'' ?>>access</option></select></div><div class="col-md-5"><input class="form-control" name="filter" value="<?= e($filter) ?>" placeholder="фильтр ошибок"></div><div class="col-md-2"><button class="btn btn-primary w-100">Показать</button></div></form><pre class="logs"><?= e($out?:'Логов пока нет') ?></pre></div><?php }

function view_security(): void { $secret=setting_get('security_2fa_secret',''); if($secret===''){ $secret=base32_random(); setting_set('security_2fa_secret',$secret); } $enabled=setting_get('security_2fa_enabled','0'); $issuer='HYPER-HOST'; $account='admin@'.host_name(); $uri='otpauth://totp/'.rawurlencode($issuer.':'.$account).'?secret='.$secret.'&issuer='.rawurlencode($issuer); $logs=db()->query('SELECT * FROM auth_logs ORDER BY id DESC LIMIT 30')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-5"><div class="panel-card"><h2>2FA и IP allowlist</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="save_security"><label class="form-check"><input class="form-check-input" type="checkbox" name="enable_2fa" value="1" <?= $enabled==='1'?'checked':'' ?>> <span class="form-check-label">Включить 2FA</span></label><div><label class="form-label">2FA secret</label><input class="form-control" value="<?= e($secret) ?>" readonly><div class="small muted mt-1">Добавь в Authenticator вручную или через URI:</div><textarea class="form-control mt-2" rows="3" readonly><?= e($uri) ?></textarea></div><div><label class="form-label">IP allowlist</label><textarea class="form-control" name="ip_allowlist" rows="5" placeholder="Один IP на строку. Пусто = все IP разрешены."><?= e(setting_get('security_ip_allowlist','')) ?></textarea></div><button class="btn btn-primary">Сохранить</button></form><form method="post" class="mt-2"><?= csrf_field() ?><input type="hidden" name="action" value="reset_2fa_secret"><button class="btn btn-soft">Сбросить 2FA secret</button></form></div></div><div class="col-lg-7"><div class="panel-card"><h2>Журнал входов</h2><table class="table table-dark-soft"><thead><tr><th>Время</th><th>Логин</th><th>IP</th><th>Статус</th></tr></thead><tbody><?php foreach($logs as $l): ?><tr><td><?= e($l['created_at']) ?></td><td><?= e($l['username']) ?></td><td><?= e($l['ip']) ?></td><td><?= e($l['status']) ?></td></tr><?php endforeach; ?></tbody></table></div></div></div><?php }

function view_settings(): void { $dbStatus=db_writable_status(); ?>
<div class="row g-4"><div class="col-lg-6"><div class="panel-card"><h2>Ремонт панели</h2><p class="muted">Чинит SQLite, sudoers, FTP, ACL-права для сохранения файлов после FileZilla, Nginx и сервисы.</p><form method="post" class="d-inline"><?= csrf_field() ?><input type="hidden" name="action" value="repair_panel"><button class="btn btn-primary">Починить права и сервисы</button></form><form method="post" class="d-inline ms-2"><?= csrf_field() ?><input type="hidden" name="action" value="sync_resources"><button class="btn btn-soft">Синхронизировать</button></form><hr><form method="post" class="row g-2"><?= csrf_field() ?><input type="hidden" name="action" value="save_public_ip"><div class="col-8"><input class="form-control" name="public_ip" value="<?= e(setting_get('public_ip_override', (string)app_config('public_ip',''))) ?>" placeholder="Публичный IP для SSL, например 90.189.208.25"></div><div class="col-4"><button class="btn btn-soft w-100">IP для SSL</button></div></form></div></div><div class="col-lg-6"><div class="panel-card"><h2>Сменить пароль</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="change_password"><input class="form-control" type="password" name="current_password" placeholder="Текущий пароль" required><input class="form-control" type="password" name="new_password" placeholder="Новый пароль" minlength="10" required><button class="btn btn-primary">Сменить пароль</button></form></div></div><div class="col-12"><div class="panel-card"><h2>Системные пути</h2><div class="hardware-grid"><div><span>SQLite</span><b><?= e($dbStatus['file_writable']?'writable':'not writable') ?></b></div><div><span>Панель</span><b><?= e((string)app_config('panel_dir')) ?></b></div><div><span>Сайты</span><b><?= e((string)app_config('sites_dir')) ?></b></div><div><span>FTP</span><b><?= e((string)app_config('ftp_dir','/var/www/hyper-host-ftp')) ?></b></div><div><span>Боты</span><b><?= e((string)app_config('bots_dir')) ?></b></div></div></div></div></div><?php }
