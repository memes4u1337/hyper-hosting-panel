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
if (isset($_GET['api'])) { render_api((string)$_GET['api']); exit; }
if ($_SERVER['REQUEST_METHOD'] === 'POST') { check_csrf(); handle_post((string)$action); }
render_page($page, $user);

function render_api(string $api): void
{
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    try {
        if ($api === 'stats') {
            $data = run_ctl_json_live(['stats-json'], 8);
            echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            return;
        }
        if ($api === 'bots') {
            $data = bots_usage_data();
            echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            return;
        }
        if ($api === 'ssl-host') {
            $host = strtolower(trim((string)($_GET['host'] ?? '')));
            if ($host === '' || !is_valid_domain($host)) {
                http_response_code(422);
                echo json_encode(['ok' => false, 'problem' => 'Укажи полный домен, например www.pixel-pc.store'], JSON_UNESCAPED_UNICODE);
                return;
            }
            $check = run_ctl_json(['ssl-host-check-json', $host], 45);
            echo json_encode($check, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            return;
        }
        if ($api === 'ssl-job') {
            $jobId = trim((string)($_GET['job'] ?? ''));
            if (!preg_match('/^ssl-[A-Za-z0-9_.-]{8,120}$/', $jobId)) {
                http_response_code(422);
                echo json_encode(['ok' => false, 'state' => 'failed', 'message' => 'Некорректный ID SSL-задания'], JSON_UNESCAPED_UNICODE);
                return;
            }
            $job = run_ctl_json_live(['ssl-job-json', $jobId], 8);
            if (!empty($job['ok']) && ($job['state'] ?? '') === 'success' && !empty($job['domain'])) {
                db()->prepare('UPDATE sites SET ssl_enabled=1 WHERE domain=?')->execute([(string)$job['domain']]);
                hh_clear_cache();
            }
            echo json_encode($job, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            return;
        }
        http_response_code(404);
        echo json_encode(['_error' => 'API not found'], JSON_UNESCAPED_UNICODE);
    } catch (Throwable $e) {
        http_response_code(500);
        echo json_encode(['_error' => $e->getMessage()], JSON_UNESCAPED_UNICODE);
    }
}

function csrf_field(): string { return '<input type="hidden" name="_csrf" value="'.e(csrf_token()).'">'; }
function host_name(): string { return panel_host_for_connections(); }
function default_ftp_password(): string { return 'Hh-' . bin2hex(random_bytes(5)) . '!'; }
function default_db_password(): string { return 'Db-' . bin2hex(random_bytes(6)) . '!'; }
function current_public_ipv4(): string
{
    $ip = trim(setting_get('public_ip_override', (string)app_config('public_ip', '')));
    if ($ip !== '' && filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return $ip;
    $host = host_name();
    return filter_var($host, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) ? $host : '';
}
function dns_panel_label(string $value): string
{
    $value = strtolower(trim($value));
    return preg_match('/^[a-z0-9][a-z0-9-]{0,61}$/', $value) ? $value : 'panel';
}
function dns_default_records_for_panel(string $domain, string $ip, string $panelSub = 'panel'): array
{
    $panelSub = dns_panel_label($panelSub);
    return [
        ['name' => '@', 'type' => 'A', 'value' => $ip, 'ttl' => 300],
        ['name' => 'www', 'type' => 'A', 'value' => $ip, 'ttl' => 300],
        ['name' => $panelSub, 'type' => 'A', 'value' => $ip, 'ttl' => 300],
        ['name' => 'ns1', 'type' => 'A', 'value' => $ip, 'ttl' => 300],
        ['name' => 'ns2', 'type' => 'A', 'value' => $ip, 'ttl' => 300],
        ['name' => 'mail', 'type' => 'A', 'value' => $ip, 'ttl' => 3600],
        ['name' => '@', 'type' => 'MX', 'value' => '10 mail.'.$domain.'.', 'ttl' => 3600],
        ['name' => '@', 'type' => 'TXT', 'value' => 'v=spf1 a mx ip4:'.$ip.' ~all', 'ttl' => 3600],
    ];
}
function replace_dns_records(int $zoneId, array $records): void
{
    db()->prepare('DELETE FROM dns_records WHERE zone_id=?')->execute([$zoneId]);
    $ins = db()->prepare('INSERT INTO dns_records(zone_id,type,name,value,ttl) VALUES(?,?,?,?,?)');
    foreach ($records as $r) {
        $ins->execute([$zoneId, strtoupper((string)$r['type']), (string)$r['name'], (string)$r['value'], (int)$r['ttl']]);
    }
}
function back_to_current(): never { redirect($_SERVER['HTTP_REFERER'] ?? '/'); }

function request_wants_json(): bool
{
    $accept = strtolower((string)($_SERVER['HTTP_ACCEPT'] ?? ''));
    $requestedWith = strtolower((string)($_SERVER['HTTP_X_REQUESTED_WITH'] ?? ''));
    return str_contains($accept, 'application/json') || in_array($requestedWith, ['fetch', 'xmlhttprequest'], true);
}

function json_response(array $payload, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

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
                $id=(int)($_POST['id']??0);
                $email=trim((string)($_POST['email']??''));
                // Убираем невидимые символы, которые браузер/буфер обмена иногда
                // добавляет к адресу. Обычный корректный email после этого проходит
                // одинаково и через AJAX, и при обычной отправке формы.
                $email=preg_replace('/[\x{200B}-\x{200D}\x{FEFF}]/u','',$email) ?? $email;
                if($email==='' || !filter_var($email,FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Укажи корректный email, например name@example.com');
                setting_set('ssl_email', $email);
                $st=db()->prepare('SELECT * FROM sites WHERE id=?'); $st->execute([$id]); $s=$st->fetch();
                if(!$s) throw new RuntimeException('Сайт не найден');

                // SSL выпускается отдельным системным заданием. Веб-запрос больше не
                // держится во время reload/restart Nginx, поэтому панель не падает с
                // ERR_EMPTY_RESPONSE даже при аварийном восстановлении Nginx.
                $res=run_ctl_json(['ssl-site-start-json',(string)$s['domain'],$email],20);
                if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??$res['_error']??'Не удалось запустить выпуск SSL'));
                add_event('ssl','Запущен выпуск SSL: '.$s['domain'].' / job '.(string)($res['job_id']??''));

                if(request_wants_json()) {
                    json_response([
                        'ok'=>true,
                        'job_id'=>(string)($res['job_id']??''),
                        'domain'=>(string)$s['domain'],
                        'state'=>(string)($res['state']??'queued'),
                        'message'=>(string)($res['message']??'SSL-задание запущено'),
                    ]);
                }
                flash('Выпуск SSL запущен в фоне. Страница не будет падать; обнови статус через несколько секунд.','success');
                redirect('/?page=ssl');
            }
            case 'ssl_any': {
                $host = strtolower(trim((string)($_POST['host'] ?? '')));
                $host = preg_replace('/[\x{200B}-\x{200D}\x{FEFF}\s]/u', '', $host) ?? $host;
                $host = rtrim($host, '.');
                $email = trim((string)($_POST['email'] ?? ''));
                $email = preg_replace('/[\x{200B}-\x{200D}\x{FEFF}]/u', '', $email) ?? $email;
                if (!is_valid_domain($host)) throw new RuntimeException('Укажи полный домен, например www.pixel-pc.store');
                if ($email === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Укажи корректный email, например name@example.com');
                setting_set('ssl_email', $email);

                // Ищем сайт-владельца: точное совпадение, иначе самый длинный суффикс.
                $sites = db()->query('SELECT * FROM sites')->fetchAll();
                $parent = null;
                foreach ($sites as $s) { if (strtolower((string)$s['domain']) === $host) { $parent = $s; break; } }
                if (!$parent) {
                    $bestLen = 0;
                    foreach ($sites as $s) {
                        $d = strtolower((string)$s['domain']);
                        if ($d !== '' && str_ends_with($host, '.' . $d) && strlen($d) > $bestLen) { $parent = $s; $bestLen = strlen($d); }
                    }
                }
                if (!$parent) {
                    $base = preg_replace('/^[^.]+\./', '', $host);
                    throw new RuntimeException('Для ' . $host . ' нет сайта в панели. Сначала создай сайт с базовым доменом ' . $base . ' на вкладке «Сайты», потом выпускай SSL.');
                }

                // Привязываем www/поддомен к сайту, иначе certbot про него не узнает.
                $siteDomain = (string)$parent['domain'];
                if (strtolower($siteDomain) !== $host) {
                    $set = [];
                    foreach (preg_split('/[\s,;]+/', (string)($parent['aliases'] ?? '')) as $a) {
                        $a = strtolower(trim($a));
                        if ($a !== '' && is_valid_domain($a) && $a !== strtolower($siteDomain)) $set[$a] = true;
                    }
                    if (!isset($set[$host])) {
                        $set[$host] = true;
                        $clean = implode(',', array_keys($set));
                        db()->prepare('UPDATE sites SET aliases=? WHERE id=?')->execute([$clean, (int)$parent['id']]);
                        $r = run_ctl(['site-aliases-set', $siteDomain, $clean], 240);
                        if ($r['code'] !== 0) throw new RuntimeException('Не удалось привязать ' . $host . ' к сайту ' . $siteDomain . ":\n" . $r['output']);
                        add_event('site', 'Домен ' . $host . ' привязан к сайту ' . $siteDomain);
                        hh_clear_cache();
                    }
                }

                $res = run_ctl_json(['ssl-bundle-start-json', $siteDomain, $email, $host], 30);
                if (empty($res['ok'])) throw new RuntimeException((string)($res['error'] ?? $res['_error'] ?? 'Не удалось запустить выпуск SSL'));
                add_event('ssl', 'Запущен выпуск SSL: ' . $host . ' (сайт ' . $siteDomain . ') / job ' . (string)($res['job_id'] ?? ''));

                if (request_wants_json()) {
                    json_response([
                        'ok' => true,
                        'job_id' => (string)($res['job_id'] ?? ''),
                        'domain' => $host,
                        'site' => $siteDomain,
                        'state' => (string)($res['state'] ?? 'queued'),
                        'message' => (string)($res['message'] ?? 'SSL-задание запущено'),
                    ]);
                }
                flash('Выпуск SSL для ' . $host . ' запущен в фоне. Обнови статус через минуту.', 'success');
                redirect('/?page=ssl');
            }
            case 'save_site_aliases': {
                $id = (int)($_POST['id'] ?? 0);
                $st = db()->prepare('SELECT * FROM sites WHERE id=?'); $st->execute([$id]); $s = $st->fetch();
                if (!$s) throw new RuntimeException('Сайт не найден');
                $set = [];
                foreach (preg_split('/[\s,;]+/', strtolower(trim((string)($_POST['aliases'] ?? '')))) as $a) {
                    $a = trim($a);
                    if ($a === '') continue;
                    if (!is_valid_domain($a)) throw new RuntimeException('Неверный домен: ' . $a);
                    if ($a === strtolower((string)$s['domain'])) continue;
                    $set[$a] = true;
                }
                $clean = implode(',', array_keys($set));
                db()->prepare('UPDATE sites SET aliases=? WHERE id=?')->execute([$clean, $id]);
                $res = run_ctl(['site-aliases-set', (string)$s['domain'], $clean], 240);
                if ($res['code'] !== 0) throw new RuntimeException($res['output']);
                hh_clear_cache();
                add_event('site', 'Домены сайта ' . $s['domain'] . ': ' . ($clean ?: 'только основной'));
                flash('Домены сайта обновлены: ' . $s['domain'] . ($clean ? ' + ' . $clean : ''), 'success');
                redirect('/?page=sites');
            }
            case 'create_folder': {
                $name=trim((string)($_POST['name']??'')); if(!is_valid_folder_name($name)) throw new RuntimeException('Неверное имя папки');
                $res=run_ctl(['create-folder',$name],120); if($res['code']!==0) throw new RuntimeException($res['output']); $path=rtrim((string)app_config('sites_dir'),'/').'/'.$name.'/public_html'; upsert_folder_row($name,$path); flash('Папка создана: '.$name,'success'); redirect('/?page=sites');
            }
            case 'delete_folder': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM folders WHERE id=?'); $st->execute([$id]); $f=$st->fetch(); if(!$f) throw new RuntimeException('Папка не найдена'); $res=run_ctl(['delete-folder',$f['name']],120); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('DELETE FROM folders WHERE id=?')->execute([$id]); redirect('/?page=sites');
            }
            case 'ftp_fix': {
                hh_clear_cache();
                $res=run_ctl(['ftp-fix'],120); if($res['code']!==0) throw new RuntimeException($res['output']);
                flash('FTP исправлен для FileZilla: порт 21, passive 40000-40100, plain FTP','success'); redirect('/?page=ftp');
            }
            case 'create_ftp': {
                $username=trim((string)($_POST['username']??'')); $password=(string)($_POST['password']??''); if($username===''||!is_valid_name($username)) throw new RuntimeException('Неверный FTP логин'); if(strlen($password)<8) throw new RuntimeException('Пароль FTP минимум 8 символов');
                $scope=ftp_scope_clean((string)($_POST['scope']??'all')); $target=ftp_scope_target_clean($scope,(string)($_POST['scope_target']??''));
                $args=['create-ftp',$username,$password,$scope]; if($target!=='') $args[]=$target;
                $res=run_ctl($args,240); if($res['code']!==0) throw new RuntimeException($res['output']); $final=$username; $home=rtrim((string)app_config('ftp_dir','/var/www/hyper-host-ftp'),'/').'/'.$final; $ftpHostForRow=current_public_ipv4() ?: host_name(); upsert_ftp_row($final,$home,$password,$ftpHostForRow,$scope,$target); add_event('ftp','Создан FTP: '.$final.' / '.ftp_scope_label_ui($scope,$target)); flash("FTP создан. Хост: ".$ftpHostForRow." | FTP-логин: {$final} | Пароль: {$password} | Открывает: ".ftp_scope_label_ui($scope,$target),'success'); redirect('/?page=ftp');
            }
            case 'delete_ftp': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM ftp_accounts WHERE id=?'); $st->execute([$id]); $f=$st->fetch(); if(!$f) throw new RuntimeException('FTP не найден'); $res=run_ctl(['delete-ftp',$f['username']],120); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('DELETE FROM ftp_accounts WHERE id=?')->execute([$id]); redirect('/?page=ftp');
            }
            case 'reset_ftp_password': {
                $id=(int)($_POST['id']??0); $pass=(string)($_POST['password']??''); if(strlen($pass)<8) throw new RuntimeException('Пароль минимум 8 символов'); $st=db()->prepare('SELECT * FROM ftp_accounts WHERE id=?'); $st->execute([$id]); $f=$st->fetch(); if(!$f) throw new RuntimeException('FTP не найден'); $scope=ftp_scope_clean((string)($f['access_scope']??'all')); $target=ftp_scope_target_clean($scope,(string)($f['access_target']??'')); $args=['ftp-password',$f['username'],$pass,$scope]; if($target!=='') $args[]=$target; $res=run_ctl($args,120); if($res['code']!==0) throw new RuntimeException($res['output']); upsert_ftp_row((string)$f['username'],(string)$f['target_path'],$pass,current_public_ipv4() ?: host_name(),$scope,$target); flash('FTP-логин восстановлен и пароль обновлён','success'); redirect('/?page=ftp');
            }
            case 'repair_ftp_account': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM ftp_accounts WHERE id=?'); $st->execute([$id]); $f=$st->fetch(); if(!$f) throw new RuntimeException('FTP не найден'); $pass=(string)($f['password_plain']??''); if(strlen($pass)<8) $pass=default_ftp_password(); $scope=ftp_scope_clean((string)($f['access_scope']??'all')); $target=ftp_scope_target_clean($scope,(string)($f['access_target']??'')); $args=['ftp-password',$f['username'],$pass,$scope]; if($target!=='') $args[]=$target; $res=run_ctl($args,180); if($res['code']!==0) throw new RuntimeException($res['output']); upsert_ftp_row((string)$f['username'],(string)$f['target_path'],$pass,current_public_ipv4() ?: host_name(),$scope,$target); flash('FTP-аккаунт восстановлен. Открывает: '.ftp_scope_label_ui($scope,$target),'success'); redirect('/?page=ftp');
            }
            case 'create_db': {
                $db=trim((string)($_POST['db_name']??'')); $du=trim((string)($_POST['db_user']??'')); $pass=(string)($_POST['password']??''); $remote=!empty($_POST['remote_allowed'])?'1':'0'; $hostPattern=$remote==='1'?(trim((string)($_POST['host_pattern']??'%'))):'localhost'; if($hostPattern==='custom') $hostPattern=trim((string)($_POST['custom_host']??'%')); if(!is_valid_db_name($db)||!is_valid_db_name($du)) throw new RuntimeException('Имя базы/пользователя: латиница, цифры, _'); if(strlen($pass)<10) throw new RuntimeException('Пароль базы минимум 10 символов'); $res=run_ctl(['create-db',$db,$du,$pass,$remote,$hostPattern],180); if($res['code']!==0) throw new RuntimeException($res['output']); upsert_db_row($db,$du,(int)$remote,$pass,$remote==='1'?mysql_external_host():mysql_local_host(),'3306'); upsert_mysql_account_row($du,$pass,$hostPattern,$db,'ALL',(int)$remote); flash('База и phpMyAdmin-пользователь созданы','success'); redirect('/?page=databases');
            }
            case 'import_db': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM databases WHERE id=?'); $st->execute([$id]); $row=$st->fetch(); if(!$row) throw new RuntimeException('База не найдена');
                $file=$_FILES['sql_file']??null;
                if(!is_array($file) || (int)($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK) {
                    $code=(int)($file['error']??UPLOAD_ERR_NO_FILE);
                    $errors=[UPLOAD_ERR_INI_SIZE=>'Файл превышает upload_max_filesize',UPLOAD_ERR_FORM_SIZE=>'Файл превышает допустимый размер формы',UPLOAD_ERR_PARTIAL=>'Файл загружен не полностью',UPLOAD_ERR_NO_FILE=>'Файл не выбран',UPLOAD_ERR_NO_TMP_DIR=>'Нет временной папки PHP',UPLOAD_ERR_CANT_WRITE=>'PHP не может записать файл на диск',UPLOAD_ERR_EXTENSION=>'Загрузка остановлена расширением PHP'];
                    throw new RuntimeException($errors[$code]??('Ошибка загрузки файла: '.$code));
                }
                $original=(string)($file['name']??'dump.sql');
                $lower=strtolower($original);
                if(!str_ends_with($lower,'.sql') && !str_ends_with($lower,'.sql.gz') && !str_ends_with($lower,'.gz') && !str_ends_with($lower,'.zip')) throw new RuntimeException('Разрешены только .sql, .sql.gz, .gz и .zip');
                $uploadDir='/opt/hyper-host/imports/uploads';
                if(!is_dir($uploadDir) && !@mkdir($uploadDir,0770,true)) throw new RuntimeException('Не удалось создать папку импорта');
                $safe=preg_replace('/[^A-Za-z0-9._-]+/u','_',basename($original))?:'dump.sql';
                $dest=$uploadDir.'/'.date('Ymd-His').'-'.bin2hex(random_bytes(4)).'-'.$safe;
                if(!move_uploaded_file((string)$file['tmp_name'],$dest)) throw new RuntimeException('Не удалось переместить загруженный SQL в очередь импорта');
                @chmod($dest,0640);
                $res=run_ctl_json(['mysql-import-start',(string)$row['db_name'],$dest],60);
                if(empty($res['ok'])) { @unlink($dest); throw new RuntimeException((string)($res['error']??$res['_error']??'Не удалось запустить импорт')); }
                add_event('database','Запущен фоновый SQL-импорт: '.$row['db_name'].' / '.$original);
                flash('SQL загружен. Импорт запущен в фоне, страницу можно закрыть. Задание: '.(string)($res['job_id']??''),'success'); redirect('/?page=databases#imports');
            }
            case 'cancel_import': {
                $jobId=trim((string)($_POST['job_id']??''));
                if(!preg_match('/^[A-Za-z0-9_.-]{5,160}$/',$jobId)) throw new RuntimeException('Некорректный ID задания');
                $res=run_ctl_json(['mysql-import-cancel',$jobId],30);
                if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??'Не удалось отменить импорт'));
                flash('Отмена импорта запрошена: '.$jobId,'warning'); redirect('/?page=databases#import-jobs');
            }
            case 'delete_db': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM databases WHERE id=?'); $st->execute([$id]); $r=$st->fetch(); if(!$r) throw new RuntimeException('База не найдена'); $res=run_ctl(['delete-db',$r['db_name'],$r['db_user']],180); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('DELETE FROM databases WHERE id=?')->execute([$id]); redirect('/?page=databases');
            }
            case 'mysql_external': {
                $state=(string)($_POST['state']??'disable'); $res=run_ctl(['mysql-external',$state],180); if($res['code']!==0) throw new RuntimeException($res['output']); setting_set('mysql_external',$state==='enable'?'1':'0'); redirect('/?page=databases');
            }
            case 'phpmyadmin_fix': {
                hh_clear_cache();
                $res=run_ctl(['phpmyadmin-fix'],300); if($res['code']!==0) throw new RuntimeException($res['output']);
                flash('phpMyAdmin настроен: pmadb включён, лимиты загрузки/экспорта подняты', 'success'); redirect('/?page=databases');
            }
            case 'php_versions_install': {
                hh_clear_cache();
                $res=run_ctl(['php-install-all'],900); if($res['code']!==0) throw new RuntimeException($res['output']);
                flash('PHP-FPM версии установлены/проверены', 'success'); redirect('/?page=php');
            }
            case 'create_mysql_account': {
                $user=trim((string)($_POST['mysql_user']??'')); $pass=(string)($_POST['password']??''); $dbn=trim((string)($_POST['grant_db']??'')); $remote=!empty($_POST['remote_allowed'])?'1':'0'; $host=$remote==='1'?(trim((string)($_POST['host_pattern']??'%'))):'localhost'; if($host==='custom') $host=trim((string)($_POST['custom_host']??'%')); $priv=(string)($_POST['privileges']??'ALL');
                if(!is_valid_db_name($user)) throw new RuntimeException('Имя пользователя: латиница, цифры, _');
                if($dbn!=='' && $dbn!=='*' && !is_valid_db_name($dbn)) throw new RuntimeException('Неверное имя базы для доступа');
                if(strlen($pass)<10) throw new RuntimeException('Пароль MySQL минимум 10 символов');
                $res=run_ctl(['create-mysql-account',$user,$pass,$host,$dbn,$priv],180); if($res['code']!==0) throw new RuntimeException($res['output']);
                upsert_mysql_account_row($user,$pass,$host,$dbn,$priv,(int)$remote);
                flash('MySQL/phpMyAdmin аккаунт создан','success'); redirect('/?page=databases');
            }
            case 'delete_mysql_account': {
                $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM mysql_accounts WHERE id=?'); $st->execute([$id]); $a=$st->fetch(); if(!$a) throw new RuntimeException('Аккаунт не найден');
                $res=run_ctl(['delete-mysql-account',$a['username'],$a['host_pattern']?:'localhost'],180); if($res['code']!==0) throw new RuntimeException($res['output']);
                db()->prepare('DELETE FROM mysql_accounts WHERE id=?')->execute([$id]); flash('MySQL аккаунт удалён','success'); redirect('/?page=databases');
            }
            case 'deploy_config_save': {
                $host=trim((string)($_POST['db_host']??'90.189.208.25')); $port=(int)($_POST['db_port']??3306); $user=trim((string)($_POST['db_user']??'mystock')); $pass=(string)($_POST['db_pass']??''); $name=trim((string)($_POST['db_name']??'mystock'));
                if($host===''||$user===''||$name===''||$port<1||$port>65535) throw new RuntimeException('Проверь параметры MySQL');
                $res=run_ctl_json(['deploy-center-config','save',$host,(string)$port,$user,$pass,$name],60); if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??$res['_error']??'Не удалось сохранить MySQL'));
                setting_set('deploy_db_host',$host); setting_set('deploy_db_port',(string)$port); setting_set('deploy_db_user',$user); setting_set('deploy_db_name',$name);
                flash('Подключение MyStock сохранено. Пароль хранится только на сервере.','success'); redirect('/?page=deploy_center');
            }
            case 'deploy_sync': {
                $data=run_ctl_json(['deploy-center-sync'],120); sync_managed_projects_local($data);
                flash('Проекты синхронизированы из MySQL: '.(int)($data['count']??0),'success'); redirect('/?page=deploy_center');
            }
            case 'deploy_template_upload': {
                $botTmp=bot_uploaded_tmp('template_bot_file'); $reqTmp=bot_uploaded_tmp('template_requirements_file');
                if($botTmp==='' && $reqTmp==='') throw new RuntimeException('Выбери bot.py или requirements.txt шаблона');
                $res=run_ctl_json(['deploy-center-template-install',$botTmp,$reqTmp],120); if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??$res['_error']??'Не удалось сохранить шаблон'));
                flash('Файлы для новых магазинов сохранены','success'); redirect('/?page=deploy_center');
            }
            case 'deploy_master_upload': {
                $botTmp=bot_uploaded_tmp('master_bot_file'); $envTmp=bot_uploaded_tmp('master_env_file'); $reqTmp=bot_uploaded_tmp('master_requirements_file');
                if($botTmp==='' && $envTmp==='' && $reqTmp==='') throw new RuntimeException('Выбери bot.py, .env или requirements.txt главного бота');
                $res=run_ctl_json(['deploy-center-master-install',$botTmp,$envTmp,$reqTmp],1200); if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??$res['_error']??'Не удалось запустить главный deploy-бот'));
                flash('Главный deploy-бот обновлён и запущен через PM2','success'); redirect('/?page=deploy_center');
            }
            case 'deploy_master_action': {
                $act=(string)($_POST['master_action']??'restart'); $res=run_ctl_json(['deploy-center-master-action',$act],180); if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??$res['_error']??'Ошибка главного бота'));
                flash('Главный deploy-бот: '.$act,'success'); redirect('/?page=deploy_center');
            }
            case 'deploy_project_action': {
                $pid=(int)($_POST['project_id']??0); $act=(string)($_POST['project_action']??'deploy'); $del=!empty($_POST['delete_files'])?'1':'0'; if($pid<1) throw new RuntimeException('Проект не выбран');
                $res=run_ctl_json(['deploy-center-project-action',(string)$pid,$act,$del],1200); if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??$res['_error']??'Ошибка проекта'));
                $data=run_ctl_json(['deploy-center-sync'],120); if(!empty($data['ok'])) sync_managed_projects_local($data);
                flash($act==='delete' ? 'Бот проекта #'.$pid.' полностью удалён с сервера. Проект в MySQL сохранён.' : 'Проект #'.$pid.': '.$act,'success'); redirect('/?page=deploy_center');
            }
            case 'ssl_restore_existing': {
                hh_clear_cache(); $res=run_ctl_json(['ssl-repair-all'],1200); if(empty($res['ok'])) throw new RuntimeException((string)($res['error']??$res['_error']??'Не удалось восстановить SSL'));
                $issued=count($res['issued']??[]); $failed=count($res['failed']??[]);
                flash('SSL восстановлен и переподключён ко всем найденным доменам. Новых выпущено: '.$issued.($failed?'; ошибок выпуска: '.$failed:''),$failed?'warning':'success'); redirect('/?page=ssl');
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
            case 'access_fix': { hh_clear_cache(); $res=run_ctl(['access-fix'],180); if($res['code']!==0) throw new RuntimeException($res['output']); flash('Доступ с других ПК включён на Ubuntu. Роутер всё равно нужно пробросить вручную.','success'); redirect('/?page=access'); }
            case 'disk_expand': { hh_clear_cache(); $res=run_ctl(['disk-expand'],600); if($res['code']!==0) throw new RuntimeException($res['output']); flash('Диск расширен. Проверь новый размер root-раздела.','success'); redirect('/?page=disk'); }
                        case 'save_panel_domain': { $domain=strtolower(trim((string)($_POST['panel_domain']??''))); if(!is_valid_domain($domain)) throw new RuntimeException('Неверный домен панели'); $res=run_ctl(['panel-domain','set',$domain],120); if($res['code']!==0) throw new RuntimeException($res['output']); setting_set('panel_domain_override',$domain); hh_clear_cache(); flash('Домен панели сохранён: '.$domain,'success'); redirect('/?page=network'); }
            case 'dns_wizard': {
                $domain=strtolower(trim((string)($_POST['domain']??'')));
                $ip=trim((string)($_POST['public_ip']??''));
                $panel=dns_panel_label((string)($_POST['panel_subdomain']??'panel'));
                if(!is_valid_domain($domain)) throw new RuntimeException('Неверный домен');
                if($ip==='' ) $ip=current_public_ipv4();
                if($ip==='' || !filter_var($ip,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)) throw new RuntimeException('Укажи публичный IPv4 для DNS');
                // v46: используем общие NS-серверы панели (ns1/ns2.<домен панели>) для любого
                // нового домена, если домен панели настроен и отличается от переносимого домена.
                // Тогда glue-записи у регистратора нужны только один раз — для домена самой панели.
                $nsHost=dns_shared_ns_host($domain);
                $primary='ns1.'.$nsHost.'.'; $admin='admin.'.$domain.'.';
                db()->beginTransaction();
                db()->prepare('INSERT INTO dns_zones(domain,primary_ns,admin_email) VALUES(?,?,?) ON CONFLICT(domain) DO UPDATE SET primary_ns=excluded.primary_ns,admin_email=excluded.admin_email')->execute([$domain,$primary,$admin]);
                $st=db()->prepare('SELECT id FROM dns_zones WHERE domain=?'); $st->execute([$domain]); $zoneId=(int)($st->fetch()['id']??0);
                replace_dns_records($zoneId, dns_default_records_for_panel($domain,$ip,$panel));
                db()->commit();
                setting_set('public_ip_override',$ip);
                $res=run_ctl(['dns-wizard',$domain,$ip,$panel],180); if($res['code']!==0) throw new RuntimeException($res['output']);
                dns_apply_zone($domain);
                hh_clear_cache();
                flash("DNS-зона готова: $domain. NS: ns1.$nsHost / ns2.$nsHost",'success'); redirect('/?page=dns');
            }
            case 'create_dns_zone': { $domain=strtolower(trim((string)($_POST['domain']??''))); if(!is_valid_domain($domain)) throw new RuntimeException('Неверный домен'); db()->prepare('INSERT INTO dns_zones(domain,primary_ns,admin_email) VALUES(?,?,?) ON CONFLICT(domain) DO UPDATE SET primary_ns=excluded.primary_ns,admin_email=excluded.admin_email')->execute([$domain, trim((string)($_POST['primary_ns']??'ns1.local.')), trim((string)($_POST['admin_email']??'admin.local.'))]); dns_apply_zone($domain); redirect('/?page=dns'); }
            case 'add_dns_record': { $zone=(int)($_POST['zone_id']??0); $type=strtoupper(trim((string)($_POST['type']??'A'))); $name=trim((string)($_POST['name']??'@')); $value=trim((string)($_POST['value']??'')); $ttl=(int)($_POST['ttl']??3600); if($value==='') throw new RuntimeException('Значение DNS записи пустое'); db()->prepare('INSERT INTO dns_records(zone_id,type,name,value,ttl) VALUES(?,?,?,?,?)')->execute([$zone,$type,$name,$value,$ttl]); $z=db()->prepare('SELECT domain FROM dns_zones WHERE id=?'); $z->execute([$zone]); $zr=$z->fetch(); if($zr) dns_apply_zone((string)$zr['domain']); redirect('/?page=dns'); }
            case 'delete_dns_record': { $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT z.domain FROM dns_records r JOIN dns_zones z ON z.id=r.zone_id WHERE r.id=?'); $st->execute([$id]); $z=$st->fetch(); db()->prepare('DELETE FROM dns_records WHERE id=?')->execute([$id]); if($z) dns_apply_zone((string)$z['domain']); redirect('/?page=dns'); }
            case 'delete_dns_zone': { $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM dns_zones WHERE id=?'); $st->execute([$id]); $z=$st->fetch(); if($z){ run_ctl(['dns-delete',$z['domain']],60); db()->prepare('DELETE FROM dns_zones WHERE id=?')->execute([$id]); } redirect('/?page=dns'); }
            case 'ssl_renew_all': { hh_clear_cache(); $res=run_ctl(['ssl-renew-all'],300); if($res['code']!==0) throw new RuntimeException($res['output']); hh_clear_cache(); flash('SSL автопродление проверено','success'); redirect('/?page=ssl'); }
            case 'save_public_ip': { $ip=trim((string)($_POST['public_ip']??'')); if($ip!=='' && !filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) throw new RuntimeException('Неверный публичный IPv4'); $res=$ip===''?run_ctl(['public-ip','clear'],60):run_ctl(['public-ip','set',$ip],60); if($res['code']!==0) throw new RuntimeException($res['output']); setting_set('public_ip_override',$ip); hh_clear_cache(); flash($ip===''?'Публичный IP сброшен':'Публичный IP сохранён: '.$ip,'success'); redirect('/?page=ssl'); }
            case 'set_site_php': { $id=(int)($_POST['id']??0); $ver=(string)($_POST['php_version']??''); $st=db()->prepare('SELECT * FROM sites WHERE id=?'); $st->execute([$id]); $s=$st->fetch(); if(!$s) throw new RuntimeException('Сайт не найден'); $res=run_ctl(['site-php',$s['domain'],$ver],180); if($res['code']!==0) throw new RuntimeException($res['output']); db()->prepare('UPDATE sites SET php_version=? WHERE id=?')->execute([$ver,$id]); hh_clear_cache(); flash('PHP для '.$s['domain'].' сохранён: '.$ver, 'success'); redirect('/?page=php'); }
            case 'create_cron': { $name=trim((string)($_POST['name']??'')); $schedule=trim((string)($_POST['schedule']??'')); $cmd=trim((string)($_POST['command']??'')); if(!is_valid_name($name)||$schedule===''||$cmd==='') throw new RuntimeException('Неверные данные cron'); db()->prepare('INSERT INTO cron_tasks(name,schedule,command,enabled) VALUES(?,?,?,1) ON CONFLICT(name) DO UPDATE SET schedule=excluded.schedule,command=excluded.command,enabled=1')->execute([$name,$schedule,$cmd]); $res=run_ctl(['cron-set',$name,$schedule,$cmd],60); if($res['code']!==0) throw new RuntimeException($res['output']); redirect('/?page=cron'); }
            case 'delete_cron': { $id=(int)($_POST['id']??0); $st=db()->prepare('SELECT * FROM cron_tasks WHERE id=?'); $st->execute([$id]); $c=$st->fetch(); if($c){ run_ctl(['cron-delete',$c['name']],60); db()->prepare('DELETE FROM cron_tasks WHERE id=?')->execute([$id]); } redirect('/?page=cron'); }
            case 'save_security': { setting_set('security_ip_allowlist', trim((string)($_POST['ip_allowlist']??''))); $enabled=!empty($_POST['enable_2fa'])?'1':'0'; if($enabled==='1' && setting_get('security_2fa_secret','')==='') setting_set('security_2fa_secret',base32_random()); setting_set('security_2fa_enabled',$enabled); flash('Безопасность сохранена','success'); redirect('/?page=security'); }
            case 'reset_2fa_secret': { setting_set('security_2fa_secret',base32_random()); flash('2FA secret обновлён','success'); redirect('/?page=security'); }
            case 'cp_grant': {
                $uid=(int)($_POST['user_id']??0);
                $sites=max(0,min(200,(int)($_POST['max_sites']??0)));
                $bots=max(0,min(200,(int)($_POST['max_bots']??0)));
                $cpu=max(0,min(400,(int)($_POST['cpu_percent']??0)));
                $mem=max(0,min(65536,(int)($_POST['memory_mb']??0)));
                $disk=max(0,min(4194304,(int)($_POST['disk_mb']??0)));
                cp_admin_grant($uid,$sites,$bots,$cpu,$mem,$disk);
                flash('Ресурсы выданы. У клиента разделы откроются сразу.','success');
                redirect('/?page=clients');
            }
            case 'cp_status': {
                $uid=(int)($_POST['user_id']??0);
                $status=(string)($_POST['status']??'');
                cp_admin_status($uid,$status);
                flash($status==='suspended'?'Клиент заблокирован, его боты остановлены':'Клиент разблокирован','success');
                redirect('/?page=clients');
            }
            case 'cp_delete': {
                $uid=(int)($_POST['user_id']??0);
                cp_admin_delete($uid);
                flash('Клиент удалён вместе с сайтами, ботами и файлами','success');
                redirect('/?page=clients');
            }
            case 'repair_panel':
                hh_clear_cache(); { $res=run_ctl(['repair'],240); if($res['code']!==0) throw new RuntimeException($res['output']); flash('Ремонт выполнен: права, ACL, FTP, сервисы проверены','success'); redirect('/?page=settings'); }
            case 'sync_resources':
                hh_clear_cache(); { sync_resources(); flash('Ресурсы синхронизированы','success'); redirect('/?page=dashboard'); }
            case 'change_password': { $current=(string)($_POST['current_password']??''); $new=(string)($_POST['new_password']??''); if(strlen($new)<10) throw new RuntimeException('Новый пароль минимум 10 символов'); $uid=(int)($_SESSION['user_id']??0); $st=db()->prepare('SELECT * FROM users WHERE id=?'); $st->execute([$uid]); $u=$st->fetch(); if(!$u||!password_verify($current,(string)$u['password_hash'])) throw new RuntimeException('Текущий пароль неверный'); db()->prepare('UPDATE users SET password_hash=? WHERE id=?')->execute([password_hash($new,PASSWORD_DEFAULT),$uid]); flash('Пароль панели изменён','success'); redirect('/?page=settings'); }
        }
    } catch (Throwable $e) {
        if (request_wants_json()) {
            json_response(['ok'=>false,'state'=>'failed','message'=>$e->getMessage()], 422);
        }
        flash($e->getMessage(), 'danger');
        redirect('/?page=' . ($_GET['page'] ?? 'dashboard'));
    }
}

function sync_resources(): void
{
    $data=run_ctl_json(['sync-json'],90); if(isset($data['_error'])) throw new RuntimeException((string)$data['_error']);
    foreach(($data['sites']??[]) as $s) upsert_site_row_v5((string)$s['domain'],(string)($s['aliases']??''),(string)$s['root_path'],(int)($s['ssl_enabled']??0),(string)($s['php_version']??''));
    foreach(($data['folders']??[]) as $f) upsert_folder_row((string)$f['name'],(string)$f['path']);
    foreach(($data['ftp']??[]) as $f) upsert_ftp_row((string)$f['username'],(string)$f['target_path'],'',(string)($f['host']??host_name()),(string)($f['access_scope']??'all'),(string)($f['access_target']??''));
    foreach(($data['databases']??[]) as $d) upsert_db_row((string)$d['db_name'],(string)$d['db_user'],(int)($d['remote_allowed']??0));
    foreach(($data['bots']??[]) as $b) upsert_bot_row_v5((string)$b['name'],(string)$b['runtime'],(string)$b['path'],(string)$b['start_command'],(int)($b['memory_limit_mb']??0));
}

function dns_shared_ns_host(string $domain): string
{
    // v46: домен-хост для общих NS панели — домен панели, если он настроен и отличается
    // от переносимого домена; иначе (например для самого домена панели) — сам домен.
    $panelDomain=strtolower(trim((string)app_config('panel_domain','')));
    if ($panelDomain !== '' && $panelDomain !== '_' && is_valid_domain($panelDomain) && $panelDomain !== $domain) {
        return $panelDomain;
    }
    return $domain;
}

function dns_apply_zone(string $domain): void
{
    $st=db()->prepare('SELECT * FROM dns_zones WHERE domain=?'); $st->execute([$domain]); $z=$st->fetch(); if(!$z) return;
    $rs=db()->prepare('SELECT type,name,value,ttl FROM dns_records WHERE zone_id=? ORDER BY id'); $rs->execute([(int)$z['id']]); $records=$rs->fetchAll();
    // ns_host восстанавливаем из уже сохранённого primary_ns (ns1.<ns_host>.), чтобы
    // повторное применение зоны (добавление/удаление записи) не откатывало общие NS
    // панели обратно на устаревшую схему "ns1.<сам домен>".
    $primaryNs=trim((string)($z['primary_ns'] ?? ''), '.');
    $nsHost=(strpos($primaryNs, 'ns1.') === 0) ? substr($primaryNs, 4) : dns_shared_ns_host($domain);
    if ($nsHost === '' || !is_valid_domain($nsHost)) $nsHost = $domain;
    $res=run_ctl(['dns-apply',$domain,json_encode($records, JSON_UNESCAPED_UNICODE),(string)$z['primary_ns'],(string)$z['admin_email'],$nsHost],120); if($res['code']!==0) throw new RuntimeException($res['output']);
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

function sync_managed_projects_local(array $payload): void
{
    if (empty($payload['ok']) || !isset($payload['projects']) || !is_array($payload['projects'])) {
        throw new RuntimeException((string)($payload['error'] ?? 'Не удалось получить проекты из MySQL'));
    }
    $sql = 'INSERT INTO managed_projects(project_id,owner_user_id,project_name,owner_tg_id,owner_username,owner_name,subscription_status,bot_active,bot_username,bot_link,pm2_name,deploy_path,pm2_status,sql_status,last_error,token_fingerprint,synced_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,datetime("now","localtime")) ON CONFLICT(project_id) DO UPDATE SET owner_user_id=excluded.owner_user_id,project_name=excluded.project_name,owner_tg_id=excluded.owner_tg_id,owner_username=excluded.owner_username,owner_name=excluded.owner_name,subscription_status=excluded.subscription_status,bot_active=excluded.bot_active,bot_username=excluded.bot_username,bot_link=excluded.bot_link,pm2_name=excluded.pm2_name,deploy_path=excluded.deploy_path,pm2_status=excluded.pm2_status,sql_status=excluded.sql_status,last_error=excluded.last_error,token_fingerprint=excluded.token_fingerprint,synced_at=excluded.synced_at';
    $st=db()->prepare($sql);
    foreach($payload['projects'] as $r){
        $st->execute([
            (int)$r['project_id'],(int)$r['owner_user_id'],(string)$r['project_name'],(string)($r['owner_tg_id']??''),(string)($r['owner_username']??''),(string)($r['owner_name']??''),(string)($r['subscription_status']??''),(string)($r['bot_active']??''),(string)($r['bot_username']??''),(string)($r['bot_link']??''),(string)($r['pm2_name']??''),(string)($r['deploy_path']??''),(string)($r['pm2']['status']??'not_found'),(string)($r['sql_status']??''),(string)($r['last_error']??''),(string)($r['token_fingerprint']??'')
        ]);
    }
    setting_set('deploy_last_sync', date('Y-m-d H:i:s'));
}

function deploy_center_config(): array
{
    $d=run_ctl_json_live(['deploy-center-config'],15);
    return (!empty($d['ok']) && isset($d['config'])) ? $d['config'] : ['_error'=>(string)($d['error']??$d['_error']??'Deploy Center недоступен')];
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


function hh_app_version(): string { return '1.10-v94'; }

function hh_nav_config(): array
{
    return [
        'main'    => ['label'=>'Сервер','icon'=>'fa-gauge-high','accent'=>'#4f7dff','items'=>['dashboard'=>['fa-chart-line','Дашборд'],'files'=>['fa-folder-open','Файлы'],'disk'=>['fa-hard-drive','Диск'],'settings'=>['fa-sliders','Настройки']]],
        'hosting' => ['label'=>'Хостинг','icon'=>'fa-server','accent'=>'#22d3ee','items'=>['sites'=>['fa-globe','Сайты'],'ftp'=>['fa-network-wired','FTP'],'databases'=>['fa-database','Базы'],'php'=>['fa-code','PHP'],'clients'=>['fa-users','Клиенты']]],
        'auto'    => ['label'=>'Боты','icon'=>'fa-robot','accent'=>'#a855f7','items'=>['bots'=>['fa-robot','PM2 боты'],'deploy_center'=>['fa-diagram-project','Deploy Manager'],'backups'=>['fa-box-archive','Backup'],'cron'=>['fa-clock','Cron'],'logs'=>['fa-file-lines','Логи']]],
        'secure'  => ['label'=>'Доступ','icon'=>'fa-shield-halved','accent'=>'#f472b6','items'=>['access'=>['fa-plug-circle-bolt','Внешний доступ'],'dns'=>['fa-diagram-project','DNS'],'network'=>['fa-tower-broadcast','Сеть'],'ssl'=>['fa-shield-halved','SSL'],'security'=>['fa-lock','Безопасность']]],
    ];
}

function hh_active_category(string $page): string
{
    foreach (hh_nav_config() as $key => $cat) { if (isset($cat['items'][$page])) return $key; }
    return 'main';
}

function nav_item(string $id,string $icon,string $label,string $page): string
{
    $active=$id===$page?' active':'';
    return '<a class="nav-link'.$active.'" href="/?page='.e($id).'"'.($active?' aria-current="page"':'').'><span class="nav-link-icon"><i class="fa-solid '.e($icon).'"></i></span><span class="nav-link-label">'.e($label).'</span><i class="fa-solid fa-chevron-right nav-link-arrow"></i></a>';
}

function render_login(): void
{
    $flash=flash(); $need2fa=setting_get('security_2fa_enabled','0')==='1'; ?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HYPER-HOST</title><link rel="preconnect" href="https://cdn.jsdelivr.net"><link rel="preconnect" href="https://cdnjs.cloudflare.com" crossorigin><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet"><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet"><link href="/assets/style.css?v=94" rel="stylesheet"></head><body class="login-body">
<div class="login-orb login-orb-a"></div><div class="login-orb login-orb-b"></div><div class="login-orb login-orb-c"></div>
<main class="login-clean">
  <section class="login-card card-glass login-clean-card">
    <div class="brand-mark login-card-mark"><i class="fa-solid fa-bolt"></i></div>
    <h1>HYPER-HOST</h1>
    <h2>Вход</h2>
    <?php if($flash): ?><div class="alert alert-<?= e($flash['type']) ?> py-2 mt-3"><?= e($flash['message']) ?></div><?php endif; ?>
    <form method="post" class="vstack gap-3 mt-3"><?= csrf_field() ?>
      <label class="hh-field"><span>Логин</span><input class="form-control form-control-lg" name="username" autocomplete="username" autofocus required></label>
      <label class="hh-field"><span>Пароль</span><input class="form-control form-control-lg" type="password" name="password" autocomplete="current-password" required></label>
      <?php if($need2fa): ?><label class="hh-field"><span>2FA</span><input class="form-control form-control-lg" name="totp" inputmode="numeric"></label><?php endif; ?>
      <button class="btn btn-primary btn-lg w-100"><i class="fa-solid fa-right-to-bracket me-2"></i>Войти</button>
    </form>
  </section>
</main>
</body></html><?php
}

function render_page(string $page, array $user): void
{
    $titles=['dashboard'=>'Панель управления','files'=>'Файловый менеджер','sites'=>'Сайты и папки','ftp'=>'FTP','databases'=>'Базы данных','bots'=>'Боты PM2 24/7','deploy_center'=>'MyStock Deploy Manager','bot_logs'=>'Логи бота','deploy_logs'=>'Логи проекта','backups'=>'Backup','dns'=>'DNS','network'=>'Сеть и доступ','ssl'=>'SSL','php'=>'PHP-версии','cron'=>'Cron','logs'=>'Логи сайтов','security'=>'Безопасность','settings'=>'Настройки','access'=>'Внешний доступ','disk'=>'Диск и LVM','clients'=>'Клиенты портала']; $title=$titles[$page]??'Дашборд'; $flash=flash();
    $nav=hh_nav_config(); $activeCat=hh_active_category($page);
    ?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?= e($title) ?> — HYPER-HOST</title>
<link rel="preconnect" href="https://cdn.jsdelivr.net"><link rel="preconnect" href="https://cdnjs.cloudflare.com" crossorigin>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet">
<link href="/assets/style.css?v=94" rel="stylesheet"></head><body class="hh-v17"><div class="app-shell" id="appShell">
<div class="mobile-nav-backdrop" id="mobileNavBackdrop"></div>
<aside class="sidebar sidebar-v3" id="mainSidebar">
  <div class="sidebar-brand-v3">
    <a href="/?page=dashboard" class="brand-link-v3">
      <span class="brand-mark-v3"><i class="fa-solid fa-bolt"></i></span>
      <span class="brand-copy-v3"><b>HYPER-HOST</b><small>server control center</small></span>
    </a>
    <button type="button" class="sidebar-close-v3" id="mobileNavClose" aria-label="Закрыть меню"><i class="fa-solid fa-xmark"></i></button>
  </div>

  <div class="server-card-v3">
    <div class="server-card-main-v3"><span class="status-dot"></span><div><b><?= e(host_name()) ?></b><span>сервер работает</span></div></div>
    <div class="server-card-live-v3" data-live-rail>
      <div class="live-mini-v3"><div><span>CPU</span><b data-stat="railCpuPercent">—</b></div><div class="live-mini-bar-v3"><i data-stat-bar="railCpu" style="width:0%"></i></div></div>
      <div class="live-mini-v3"><div><span>RAM</span><b data-stat="railMemPercent">—</b></div><div class="live-mini-bar-v3"><i data-stat-bar="railMem" style="width:0%"></i></div></div>
    </div>
  </div>

  <div class="sidebar-category-switch-v79" role="tablist" aria-label="Разделы панели">
    <?php foreach($nav as $key=>$cat): ?>
      <button type="button" class="sidebar-category-v79<?= $key===$activeCat?' active':'' ?>" data-sidebar-category="<?= e($key) ?>" style="--group-accent:<?= e($cat['accent']) ?>" role="tab" aria-selected="<?= $key===$activeCat?'true':'false' ?>">
        <span><i class="fa-solid <?= e($cat['icon']) ?>"></i></span><b><?= e($cat['label']) ?></b>
      </button>
    <?php endforeach; ?>
  </div>

  <div class="sidebar-nav-stage-v79">
    <?php foreach($nav as $key=>$cat): ?>
      <section class="nav-panel-v79<?= $key===$activeCat?' active':'' ?>" data-sidebar-panel="<?= e($key) ?>" style="--group-accent:<?= e($cat['accent']) ?>" role="tabpanel"<?= $key===$activeCat?'':' hidden' ?>>
        <div class="nav-panel-head-v79"><span><i class="fa-solid <?= e($cat['icon']) ?>"></i></span><div><small>Раздел</small><b><?= e($cat['label']) ?></b></div></div>
        <nav class="nav nav-v3 flex-column">
          <?php foreach($cat['items'] as $id=>$it): ?><?= nav_item($id,$it[0],$it[1],$page) ?><?php endforeach; ?>
        </nav>
      </section>
    <?php endforeach; ?>
  </div>

  <div class="sidebar-footer-v3">
    <div class="version-pill-v3"><span>HYPER-HOST</span><b><?= e(hh_app_version()) ?></b></div>
    <a href="/?page=logout" class="logout-v3"><i class="fa-solid fa-arrow-right-from-bracket"></i><span>Выйти</span></a>
  </div>
</aside>

<main class="content" style="--cat-accent:<?= e($nav[$activeCat]['accent']??'#4f7dff') ?>">
  <header class="topbar topbar-v3">
    <button type="button" class="mobile-nav-toggle" id="mobileNavToggle" aria-label="Открыть меню" aria-expanded="false"><i class="fa-solid fa-bars"></i></button>
    <div class="topbar-title-v3">
      <div class="topbar-kicker"><i class="fa-solid <?= e($nav[$activeCat]['icon']??'fa-rocket') ?>"></i><?= e($nav[$activeCat]['label']??'') ?></div>
      <h1><?= e($title) ?></h1>
      <div class="topbar-host-v3"><span class="status-dot"></span><span>Сервер</span><code><?= e(host_name()) ?></code></div>
    </div>
    <form method="post" data-async-submit class="topbar-refresh-v3"><?= csrf_field() ?><input type="hidden" name="action" value="sync_resources"><button class="btn btn-soft" data-loading-text="Синхронизирую..."><i class="fa-solid fa-rotate"></i><span>Обновить</span></button></form>
  </header>
  <?php if($flash): ?><div class="alert alert-<?= e($flash['type']) ?> shadow-sm"><i class="fa-solid fa-circle-info"></i><span><?= nl2br(e($flash['message'])) ?></span></div><?php endif; ?>
  <section class="page-stage-v3"><?php route_view($page); ?></section>
</main></div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js" defer></script>
<script src="/assets/app.js?v=94" defer></script></body></html><?php
}
function route_view(string $page): void { match($page){ 'files'=>view_files(), 'sites'=>view_sites(), 'ftp'=>view_ftp(), 'databases'=>view_databases(), 'pma_login'=>view_pma_login(), 'bots'=>view_bots(), 'deploy_center'=>view_deploy_center(), 'bot_logs'=>view_bot_logs(), 'deploy_logs'=>view_deploy_logs(), 'backups'=>view_backups(), 'dns'=>view_dns(), 'network'=>view_network(), 'ssl'=>view_ssl(), 'php'=>view_php(), 'cron'=>view_cron(), 'logs'=>view_logs(), 'security'=>view_security(), 'settings'=>view_settings(), 'access'=>view_access(), 'disk'=>view_disk(), 'clients'=>view_clients(), default=>view_dashboard(), }; }
function stat_card(string $icon,string $label,string $value,string $sub=''): void { ?><div class="stat-card"><div class="stat-icon"><i class="fa-solid <?= e($icon) ?>"></i></div><div><span><?= e($label) ?></span><b><?= e($value) ?></b><?php if($sub): ?><em><?= e($sub) ?></em><?php endif; ?></div></div><?php }
function progress_block(string $label,float $used,float $total): string { $p=percent($used,$total); return '<div class="usage"><div class="d-flex justify-content-between"><span>'.e($label).'</span><b>'.e(human_bytes($used).' / '.human_bytes($total)).'</b></div><div class="progress"><div class="progress-bar" style="width:'.$p.'%"></div></div></div>'; }

function view_dashboard(): void
{
    $stats = run_ctl_json_live(['stats-json'], 8);
    $events = db()->query('SELECT * FROM events ORDER BY id DESC LIMIT 8')->fetchAll();
    $sites = table_count('sites');
    $ftp = table_count('ftp_accounts');
    $bots = table_count('bots');
    $dbs = table_count('databases');
    $memUsed = (float)($stats['mem_used'] ?? 0);
    $memTotal = (float)($stats['mem_total'] ?? 0);
    $diskUsed = (float)($stats['disk_used'] ?? 0);
    $diskTotal = (float)($stats['disk_total'] ?? 0);
    $cpuPercent = (float)($stats['cpu_percent'] ?? 0);
    $memPercent = percent($memUsed, $memTotal);
    $diskPercent = percent($diskUsed, $diskTotal);
    ?>
<div class="dashboard-v33" data-live-stats>
  <section class="dash-hero-v33 mb-4">
    <div class="dash-hero-main-v33">
      <div class="kicker"><i class="fa-solid fa-chart-line me-2"></i>Обзор сервера</div>
      <h2>HYPER-HOST</h2>
      <div class="dash-host-line"><span data-stat="hostnameShort"><?= e((string)($stats['hostname'] ?? host_name())) ?></span><code><?= e(host_name()) ?></code></div>
    </div>
    <div class="dash-actions-v33">
      <a class="dash-action-v33 primary" href="/?page=sites"><i class="fa-solid fa-plus"></i><span>Сайт</span></a>
      <a class="dash-action-v33" href="/?page=bots"><i class="fa-solid fa-robot"></i><span>Бот</span></a>
      <a class="dash-action-v33" href="/?page=databases"><i class="fa-solid fa-database"></i><span>База</span></a>
      <a class="dash-action-v33" href="/?page=files"><i class="fa-solid fa-folder-open"></i><span>Файлы</span></a>
    </div>
  </section>

  <?php if(isset($stats['_error'])): ?>
    <div class="alert alert-warning"><?= e((string)$stats['_error']) ?></div>
  <?php else: ?>
  <div class="dash-layout-v33">
    <div class="dash-main-v33">
      <div class="dash-resource-grid-v33 mb-4">
        <div class="dash-resource-card-v33 cpu-card-v29">
          <div class="dash-resource-top"><span><i class="fa-solid fa-microchip"></i>CPU</span><b data-stat="cpuPercent"><?= e((string)$cpuPercent) ?>%</b></div>
          <div class="live-meter"><div data-stat-bar="cpu" style="width:<?= e((string)$cpuPercent) ?>%"></div></div>
          <div class="dash-resource-meta"><b data-stat="cpuModel"><?= e((string)($stats['cpu_model'] ?? 'unknown')) ?></b><small><span data-stat="cpuCores"><?= e((string)($stats['cpu_cores'] ?? 0)) ?></span> cores · load <span data-stat="loadText"><?= e((string)($stats['load1'] ?? 0)) ?> / <?= e((string)($stats['load5'] ?? 0)) ?> / <?= e((string)($stats['load15'] ?? 0)) ?></span></small></div>
        </div>
        <div class="dash-resource-card-v33 ram-card-v29">
          <div class="dash-resource-top"><span><i class="fa-solid fa-memory"></i>RAM</span><b data-stat="memPercent"><?= $memPercent ?>%</b></div>
          <div class="live-meter"><div data-stat-bar="mem" style="width:<?= $memPercent ?>%"></div></div>
          <div class="dash-resource-meta"><b data-stat="memText"><?= e(human_bytes($memUsed).' / '.human_bytes($memTotal)) ?></b><small>свободно <span data-stat="memAvailable"><?= e(human_bytes((float)($stats['mem_available'] ?? 0))) ?></span> · кэш <span data-stat="memCached"><?= e(human_bytes((float)($stats['mem_cached'] ?? 0))) ?></span></small></div>
        </div>
        <div class="dash-resource-card-v33 disk-card-v29">
          <div class="dash-resource-top"><span><i class="fa-solid fa-hard-drive"></i>Диск /</span><b data-stat="diskPercent"><?= $diskPercent ?>%</b></div>
          <div class="live-meter"><div data-stat-bar="disk" style="width:<?= $diskPercent ?>%"></div></div>
          <div class="dash-resource-meta"><b data-stat="diskText"><?= e(human_bytes($diskUsed).' / '.human_bytes($diskTotal)) ?></b><small>свободно <span data-stat="diskFree"><?= e(human_bytes((float)($stats['disk_free'] ?? 0))) ?></span></small></div>
        </div>
        <div class="dash-resource-card-v33 system-card-v29">
          <div class="dash-resource-top"><span><i class="fa-solid fa-server"></i>Система</span><b data-stat="uptime"><?= e((string)($stats['uptime'] ?? '—')) ?></b></div>
          <div class="dash-system-list-v33">
            <div><span>Host</span><b data-stat="hostname"><?= e((string)($stats['hostname'] ?? host_name())) ?></b></div>
            <div><span>PM2</span><b data-stat="pm2Version"><?= e((string)($stats['pm2_version'] ?: 'not installed')) ?></b></div>
            <div><span>Kernel</span><b data-stat="kernel"><?= e((string)($stats['kernel'] ?? '')) ?></b></div>
          </div>
        </div>
      </div>

      <div class="panel-card dash-disk-panel-v33 mb-4">
        <div class="card-title-row"><h2><i class="fa-solid fa-chart-simple me-2"></i>Диски и папки</h2><a class="btn btn-sm btn-soft" href="/?page=disk">Открыть диск</a></div>
        <div class="disk-path-grid-v29">
          <?php foreach(['root'=>'Корень /','sites'=>'Сайты','bots'=>'Боты','ftp'=>'FTP','backups'=>'Backup'] as $key=>$label): $d=$stats['disks'][$key]??[]; $pct=(float)($d['percent']??0); ?>
            <div class="disk-path-v29" data-disk-path="<?= e($key) ?>">
              <div><span><?= e($label) ?></span><b data-disk-field="text"><?= e(human_bytes((float)($d['used']??0)).' / '.human_bytes((float)($d['total']??0))) ?></b></div>
              <div class="mini-meter"><i data-disk-field="bar" style="width:<?= e((string)$pct) ?>%"></i></div>
              <small data-disk-field="free">свободно <?= e(human_bytes((float)($d['free']??0))) ?></small>
            </div>
          <?php endforeach; ?>
        </div>
      </div>

      <div class="quick-grid">
        <a class="quick-card" href="/?page=files"><i class="fa-solid fa-folder-open"></i><b>Файлы</b><span>папки сайтов и ботов</span></a>
        <a class="quick-card" href="/?page=access"><i class="fa-solid fa-plug-circle-bolt"></i><b>Доступ</b><span>порты и внешний IP</span></a>
        <a class="quick-card" href="/?page=ssl"><i class="fa-solid fa-shield-halved"></i><b>SSL</b><span>сертификаты</span></a>
        <a class="quick-card" href="/?page=settings"><i class="fa-solid fa-sliders"></i><b>Настройки</b><span>пароль и ремонт</span></a>
      </div>
    </div>

    <aside class="dash-side-v33">
      <div class="panel-card dash-counts-v33">
        <h2><i class="fa-solid fa-layer-group me-2"></i>Ресурсы</h2>
        <a href="/?page=sites"><span>Сайты</span><b><?= (int)$sites ?></b></a>
        <a href="/?page=databases"><span>Базы</span><b><?= (int)$dbs ?></b></a>
        <a href="/?page=bots"><span>Боты</span><b><?= (int)$bots ?></b></a>
        <a href="/?page=ftp"><span>FTP</span><b><?= (int)$ftp ?></b></a>
      </div>

      <div class="panel-card service-live-panel-v29">
        <h2><i class="fa-solid fa-heart-pulse me-2"></i>Сервисы</h2>
        <div class="service-row-v29" data-services>
          <?php foreach(($stats['services']??[]) as $name=>$st): ?>
            <span data-service="<?= e((string)$name) ?>" class="service-chip-v29 <?= $st==='active'?'ok':'bad' ?>"><i class="fa-solid fa-circle"></i><?= e($name) ?>: <?= e((string)$st) ?></span>
          <?php endforeach; ?>
        </div>
      </div>

      <div class="panel-card dash-events-v33">
        <h2><i class="fa-solid fa-clock-rotate-left me-2"></i>События</h2>
        <?php foreach($events as $ev): ?><div class="event"><b><?= e($ev['type']) ?></b><span><?= e($ev['message']) ?></span><small><?= e($ev['created_at']) ?></small></div><?php endforeach; if(!$events): ?><div class="empty">Событий пока нет</div><?php endif; ?>
      </div>
    </aside>
  </div>
  <?php endif; ?>
</div>
<?php }

function view_files(): void
{ $rootKey=(string)($_GET['root']??'sites'); $rel=safe_rel_path((string)($_GET['path']??'')); [$rootKey,$root,$rel,$path]=fm_resolve($rootKey,$rel); $items=is_dir($path)?array_values(array_diff(scandir($path)?:[],['.','..'])):[]; sort($items); $currentDir=is_dir($path)?$rel:dirname($rel); if($currentDir==='.')$currentDir=''; ?>
<div class="file-manager-layout">
  <section class="panel-card pc-panel">
    <h2><i class="fa-solid fa-desktop me-2"></i>Мой ПК</h2>
    
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
{ $sites=db()->query('SELECT * FROM sites ORDER BY id DESC')->fetchAll(); $folders=db()->query('SELECT * FROM folders ORDER BY id DESC')->fetchAll(); $php=run_ctl_json_cached(['php-list-json'],10,300); ?>
<div class="row g-4"><div class="col-lg-4"><div class="panel-card"><h2>Создать сайт</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="add_site"><input class="form-control" name="domain" placeholder="hyper-host.pw" required><input class="form-control" name="aliases" placeholder="www.hyper-host.pw"><select class="form-select" name="php_version"><option value="">PHP по умолчанию</option><?php foreach(($php['_error']??null)?[]:$php as $p): ?><option value="<?= e($p['version']) ?>">PHP <?= e($p['version']) ?></option><?php endforeach; ?></select><button class="btn btn-primary">Создать сайт</button></form></div><div class="panel-card mt-4"><h2>Создать папку-сайт</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_folder"><input class="form-control" name="name" placeholder="test-site" required><button class="btn btn-primary">Создать папку</button></form></div></div><div class="col-lg-8"><div class="panel-card"><h2>Сайты</h2><div class="table-responsive"><table class="table table-dark-soft align-middle"><thead><tr><th>Домен</th><th>Папка</th><th>PHP/SSL</th><th></th></tr></thead><tbody><?php foreach($sites as $s): ?><tr><td><b><?= e($s['domain']) ?></b><div class="site-domains-v92"><?php foreach(array_filter(preg_split('/[\s,;]+/',(string)$s['aliases'])) as $al): ?><span><?= e($al) ?></span><?php endforeach; ?></div><form method="post" class="site-alias-form-v92"><?= csrf_field() ?><input type="hidden" name="action" value="save_site_aliases"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><input class="form-control form-control-sm" name="aliases" value="<?= e($s['aliases']) ?>" placeholder="www.<?= e($s['domain']) ?>"><button class="btn btn-sm btn-soft">Сохранить домены</button></form></td><td><code><?= e($s['root_path']) ?></code></td><td><span class="badge text-bg-info">PHP <?= e($s['php_version']?:'default') ?></span> <span class="badge text-bg-<?= (int)$s['ssl_enabled']?'success':'secondary' ?>"><?= (int)$s['ssl_enabled']?'SSL':'HTTP' ?></span></td><td class="text-end"><a class="btn btn-sm btn-soft" href="/?page=files&root=sites&path=<?= e($s['domain'].'/public_html') ?>">Файлы</a><form method="post" class="d-inline" onsubmit="return confirm('Удалить сайт?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$sites): ?><tr><td colspan="4" class="empty">Сайтов пока нет</td></tr><?php endif; ?></tbody></table></div><h2 class="mt-4">Папки</h2><div class="table-responsive"><table class="table table-dark-soft"><tbody><?php foreach($folders as $f): ?><tr><td><b><?= e($f['name']) ?></b></td><td><code><?= e($f['path']) ?></code></td><td class="text-end"><a class="btn btn-sm btn-soft" href="/?page=files&root=sites&path=<?= e($f['name'].'/public_html') ?>">Файлы</a></td></tr><?php endforeach; if(!$folders): ?><tr><td class="empty">Папок пока нет</td></tr><?php endif; ?></tbody></table></div></div></div></div><?php }

function view_pma_login(): void
{
    $type=(string)($_GET['type']??'db'); $id=(int)($_GET['id']??0);
    if($type==='account') { $st=db()->prepare('SELECT username AS db_user, password_plain AS db_password_plain FROM mysql_accounts WHERE id=?'); }
    else { $st=db()->prepare('SELECT db_user, db_password_plain FROM databases WHERE id=?'); }
    $st->execute([$id]); $r=$st->fetch();
    if(!$r || empty($r['db_user']) || empty($r['db_password_plain'])) { echo '<div class="panel-card empty">Нет сохранённых данных для входа. Создай/обнови пароль аккаунта.</div>'; return; }
    $url=phpmyadmin_url();
    ?>
    <div class="panel-card pma-auto-card">
      <h2><i class="fa-solid fa-database me-2"></i>Вход в phpMyAdmin</h2>
      
      <form id="pmaAutoForm" method="post" action="<?= e($url) ?>" class="vstack gap-3">
        <input type="hidden" name="pma_username" value="<?= e($r['db_user']) ?>">
        <input type="hidden" name="pma_password" value="<?= e($r['db_password_plain']) ?>">
        <input type="hidden" name="server" value="1">
        <button class="btn btn-primary btn-lg"><i class="fa-solid fa-right-to-bracket me-2"></i>Перейти в phpMyAdmin</button>
      </form>
      <div class="mt-3 small muted">Логин: <code><?= e($r['db_user']) ?></code></div>
    </div>
    <script>setTimeout(()=>document.getElementById('pmaAutoForm')?.submit(), 450);</script>
    <?php
}

function view_databases(): void
{
    $rows=db()->query('SELECT * FROM databases ORDER BY id DESC')->fetchAll();
    $accounts=db()->query('SELECT * FROM mysql_accounts ORDER BY id DESC')->fetchAll();
    $mysql=run_ctl_json_cached(['mysql-status-json'],5,120);
    $doctor=run_ctl_json_cached(['mysql-doctor-json'],5,120);
    $pmaStatus=run_ctl_json_cached(['phpmyadmin-status-json'],5,120);
    $imports=run_ctl_json_cached(['mysql-import-status-json'],8,5);
    if(!is_array($imports) || !array_is_list($imports)) $imports=[];
    $gen=default_db_password();
    $external=setting_get('mysql_external','0')==='1' || (($mysql['bind_address']??'')==='0.0.0.0');
    $pma=phpmyadmin_url();
    $mysqlExternalHost=mysql_external_host();
    $mysqlLocalHost=mysql_local_host();
    $mysqlLanHost=(string)app_config('server_ip','192.168.0.179');
    $listen=!empty($mysql['listen_3306']);
    $accountByUser=[]; foreach($accounts as $a){ $accountByUser[$a['username']]=$a; }
    $serviceOk=(($mysql['service']??'')==='active');
    ?>
<div class="db-page-v93">

  <section class="db-hero-v93">
    <div class="db-hero-top-v93">
      <div class="db-hero-title-v93">
        <div class="eyebrow"><i class="fa-solid fa-database"></i> MySQL / MariaDB</div>
        <h2>Базы данных</h2>
        <p>Создание баз, аккаунты phpMyAdmin и фоновый импорт больших дампов.</p>
      </div>
      <div class="db-hero-actions-v93">
        <a class="btn btn-primary" href="<?= e($pma) ?>" target="_blank" rel="noopener"><i class="fa-solid fa-arrow-up-right-from-square me-2"></i>Открыть phpMyAdmin</a>
        <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="phpmyadmin_fix"><button class="btn btn-soft"><i class="fa-solid fa-screwdriver-wrench me-2"></i>Настроить phpMyAdmin</button></form>
        <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="mysql_external"><input type="hidden" name="state" value="enable"><button class="btn btn-soft"><i class="fa-solid fa-plug-circle-bolt me-2"></i>Внешний SQL</button></form>
      </div>
    </div>

    <div class="db-status-v93">
      <div class="db-status-item-v93">
        <span>Сервер</span>
        <b class="<?= $serviceOk?'hh-ok':'hh-warn' ?>"><?= e((string)($mysql['service']??'unknown')) ?></b>
      </div>
      <div class="db-status-item-v93">
        <span>Порт 3306</span>
        <b class="<?= $listen?'hh-ok':'hh-bad' ?>"><?= $listen?'слушает':'закрыт' ?></b>
      </div>
      <div class="db-status-item-v93">
        <span>Доступ</span>
        <b class="<?= $external?'hh-ok':'hh-warn' ?>"><?= $external?'внешний':'локальный' ?></b>
      </div>
      <div class="db-status-item-v93">
        <span>SQL host</span>
        <code class="db-copy-v93" data-copy-text="<?= e($mysqlExternalHost) ?>" title="Нажми, чтобы скопировать"><?= e($mysqlExternalHost) ?></code>
      </div>
      <div class="db-status-item-v93">
        <span>Служебная база pma</span>
        <b class="<?= !empty($pmaStatus['ready'])?'hh-ok':'hh-warn' ?>"><?= !empty($pmaStatus['ready'])?'готова':'настроить' ?></b>
      </div>
      <div class="db-status-item-v93">
        <span>Лимит импорта</span>
        <code><?= e((string)($pmaStatus['upload_max_filesize']??'8192M')) ?></code>
      </div>
      <div class="db-status-item-v93">
        <span>Память экспорта</span>
        <code><?= e((string)($pmaStatus['memory_limit']??'2048M')) ?></code>
      </div>
      <div class="db-status-item-v93">
        <span>Всего баз</span>
        <code><?= count($rows) ?> · аккаунтов <?= count($accounts) ?></code>
      </div>
    </div>

    <?php if(!empty($doctor['problem'])): ?>
      <div class="db-problem-v93"><i class="fa-solid fa-triangle-exclamation"></i><span><?= e((string)$doctor['problem']) ?></span></div>
    <?php endif; ?>
  </section>

  <div class="db-columns-v93">
    <aside class="db-side-v93">

      <div class="panel-card db-form-card-v93">
        <div class="db-form-head-v93"><span><i class="fa-solid fa-plus"></i></span><div><b>Новая база</b><small>база и пользователь одной кнопкой</small></div></div>
        <form method="post" class="db-form-v93"><?= csrf_field() ?><input type="hidden" name="action" value="create_db">
          <label class="db-field-v93"><span>Имя базы</span><input class="form-control" name="db_name" placeholder="hyper_host_bot" value="hyper_host_bot" required></label>
          <label class="db-field-v93"><span>Пользователь</span><input class="form-control" name="db_user" placeholder="hyper_bot" value="hyper_bot" required></label>
          <label class="db-field-v93"><span>Пароль</span>
            <span class="input-group"><input class="form-control" id="dbPass" name="password" value="<?= e($gen) ?>" minlength="10" required><button class="btn btn-outline-light" type="button" onclick="copyValue('dbPass')"><i class="fa-regular fa-copy"></i></button></span>
          </label>
          <div class="db-access-pills">
            <label><input type="radio" name="remote_allowed" value="0" checked><span><i class="fa-solid fa-house"></i>Локально</span></label>
            <label><input type="radio" name="remote_allowed" value="1"><span><i class="fa-solid fa-globe"></i>Внешний вход</span></label>
          </div>
          <div class="remote-options db-hidden">
            <label class="db-field-v93"><span>Откуда пускать</span>
              <select class="form-select" name="host_pattern" onchange="this.closest('.remote-options').querySelector('.custom-host').style.display=this.value==='custom'?'block':'none'">
                <option value="%">Любой IP</option>
                <option value="<?= e($mysqlLanHost) ?>">Только LAN: <?= e($mysqlLanHost) ?></option>
                <option value="custom">Свой IP или маска</option>
              </select>
            </label>
            <input class="form-control custom-host mt-2" style="display:none" name="custom_host" placeholder="1.2.3.4 или 90.189.208.%">
          </div>
          <button class="btn btn-primary btn-lg w-100"><i class="fa-solid fa-wand-magic-sparkles me-2"></i>Создать базу</button>
        </form>
      </div>

      <div class="panel-card db-form-card-v93" id="imports">
        <div class="db-form-head-v93"><span><i class="fa-solid fa-file-import"></i></span><div><b>Импорт дампа</b><small>.sql, .sql.gz и .zip до 8 ГБ</small></div></div>
        <?php if($rows): ?>
        <form method="post" enctype="multipart/form-data" class="db-form-v93"><?= csrf_field() ?><input type="hidden" name="action" value="import_db">
          <label class="db-field-v93"><span>В какую базу</span>
            <select class="form-select" name="id" required><?php foreach($rows as $r): ?><option value="<?= (int)$r['id'] ?>"><?= e($r['db_name']) ?></option><?php endforeach; ?></select>
          </label>
          <label class="db-field-v93"><span>Файл дампа</span>
            <input class="form-control" type="file" name="sql_file" accept=".sql,.gz,.zip,application/sql,application/zip,application/gzip" required>
          </label>
          <button class="btn btn-primary w-100"><i class="fa-solid fa-cloud-arrow-up me-2"></i>Загрузить и импортировать</button>
        </form>
        <p class="db-note-v93">Файл загружается один раз, дальше импорт идёт в фоне — вкладку можно закрыть. Дамп на 2 ГБ занимает 30–120 минут. Живой прогресс, скорость и число созданных таблиц видно справа.</p>
        <?php else: ?>
          <div class="db-empty-v93">Сначала создай базу — тогда появится выбор, куда импортировать.</div>
        <?php endif; ?>
      </div>

      <div class="panel-card db-form-card-v93">
        <div class="db-form-head-v93"><span><i class="fa-solid fa-user-lock"></i></span><div><b>Аккаунт phpMyAdmin</b><small>отдельный вход под свои права</small></div></div>
        <form method="post" class="db-form-v93"><?= csrf_field() ?><input type="hidden" name="action" value="create_mysql_account">
          <label class="db-field-v93"><span>Логин</span><input class="form-control" name="mysql_user" placeholder="pma_user" required></label>
          <label class="db-field-v93"><span>Пароль</span>
            <span class="input-group"><input class="form-control" id="pmaPass" name="password" value="<?= e(default_db_password()) ?>" minlength="10" required><button class="btn btn-outline-light" type="button" onclick="copyValue('pmaPass')"><i class="fa-regular fa-copy"></i></button></span>
          </label>
          <label class="db-field-v93"><span>Доступ к базе</span>
            <select class="form-select" name="grant_db"><option value="">Без привязки к базе</option><?php foreach($rows as $r): ?><option value="<?= e($r['db_name']) ?>"><?= e($r['db_name']) ?></option><?php endforeach; ?><option value="*">Все базы</option></select>
          </label>
          <label class="db-field-v93"><span>Права</span>
            <select class="form-select" name="privileges"><option value="ALL">Полный доступ</option><option value="SELECT">Только чтение</option></select>
          </label>
          <div class="db-access-pills">
            <label><input type="radio" name="remote_allowed" value="0" checked><span><i class="fa-solid fa-house"></i>Локально</span></label>
            <label><input type="radio" name="remote_allowed" value="1"><span><i class="fa-solid fa-globe"></i>Внешний вход</span></label>
          </div>
          <div class="remote-options db-hidden">
            <label class="db-field-v93"><span>Откуда пускать</span>
              <select class="form-select" name="host_pattern" onchange="this.closest('.remote-options').querySelector('.custom-host').style.display=this.value==='custom'?'block':'none'">
                <option value="%">Любой IP</option>
                <option value="<?= e($mysqlLanHost) ?>">Только <?= e($mysqlLanHost) ?></option>
                <option value="custom">Свой IP или маска</option>
              </select>
            </label>
            <input class="form-control custom-host mt-2" style="display:none" name="custom_host" placeholder="1.2.3.4">
          </div>
          <button class="btn btn-soft w-100"><i class="fa-solid fa-user-plus me-2"></i>Создать аккаунт</button>
        </form>
      </div>

    </aside>

    <div class="db-main-v93">

      <div class="panel-card">
        <div class="card-title-row flex-wrap">
          <h2><i class="fa-solid fa-table me-2"></i>Базы <span class="db-count-v93"><?= count($rows) ?></span></h2>
          <div class="d-flex gap-2 flex-wrap">
            <button class="btn btn-sm btn-soft" onclick="copyText('<?= e($mysqlExternalHost) ?>')">Копировать SQL host</button>
            <button class="btn btn-sm btn-soft" onclick="copyText('<?= e($pma) ?>')">Ссылка phpMyAdmin</button>
          </div>
        </div>
        <div class="db-cards-v93">
        <?php foreach($rows as $r):
          $a=$accountByUser[$r['db_user']]??null;
          $hostPattern=(string)($a['host_pattern']??($r['remote_allowed']?'%':'localhost'));
          $connHost=(int)$r['remote_allowed']?$mysqlLanHost:$mysqlLocalHost;
          $remote=(int)$r['remote_allowed'];
          $pass=(string)($r['db_password_plain']?:'');
        ?>
          <article class="db-card-v93<?= $remote?' is-remote':'' ?>">
            <header class="db-card-head-v93">
              <span class="db-card-icon-v93"><i class="fa-solid fa-database"></i></span>
              <div class="db-card-name-v93"><b><?= e($r['db_name']) ?></b><small><?= e(mysql_host_label($hostPattern)) ?></small></div>
              <span class="<?= $remote?'hh-warn':'hh-ok' ?>"><i class="fa-solid <?= $remote?'fa-globe':'fa-house' ?>"></i><?= $remote?'внешний вход':'только локально' ?></span>
            </header>
            <div class="db-fields-v93">
              <div><span>Пользователь</span><code class="db-copy-v93" data-copy-text="<?= e($r['db_user']) ?>" title="Скопировать"><?= e($r['db_user']) ?></code></div>
              <div><span>Хост подключения</span><code class="db-copy-v93" data-copy-text="<?= e($connHost) ?>" title="Скопировать"><?= e($connHost) ?></code></div>
              <div><span>Порт</span><code>3306</code></div>
              <div><span>Пароль</span><?php if($pass!==''): ?><code class="db-copy-v93 db-secret-v93" data-copy-text="<?= e($pass) ?>" title="Скопировать"><?= e($pass) ?></code><?php else: ?><code class="db-muted-v93">не сохранён</code><?php endif; ?></div>
            </div>
            <div class="db-actions">
              <a class="btn btn-sm btn-primary" href="/?page=pma_login&type=db&id=<?= (int)$r['id'] ?>"><i class="fa-solid fa-right-to-bracket me-1"></i>Войти</a>
              <button class="btn btn-sm btn-soft" onclick="copyText('Host: <?= e($connHost) ?>\nPort: 3306\nDatabase: <?= e($r['db_name']) ?>\nUser: <?= e($r['db_user']) ?>\nPassword: <?= e($pass) ?>')"><i class="fa-regular fa-copy me-1"></i>Все данные</button>
              <form method="post" onsubmit="return confirm('Удалить базу <?= e($r['db_name']) ?> вместе со всеми таблицами?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_db"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form>
            </div>
          </article>
        <?php endforeach; if(!$rows): ?><div class="db-empty-v93">Баз пока нет. Создай первую в форме слева.</div><?php endif; ?>
        </div>
      </div>

      <div class="panel-card" id="import-jobs">
        <div class="card-title-row flex-wrap">
          <h2><i class="fa-solid fa-bars-progress me-2"></i>Импорт SQL</h2>
          <button class="btn btn-sm btn-soft" type="button" onclick="location.reload()"><i class="fa-solid fa-rotate me-1"></i>Обновить</button>
        </div>
        <div class="db-cards-v93">
        <?php $hasRunning=false; foreach($imports as $job):
          $status=(string)($job['status']??'unknown');
          $running=in_array($status,['queued','running','waiting_mysql'],true);
          if($running) $hasRunning=true;
          $progress=max(0,min(100,(float)($job['progress']??0)));
          $elapsed=(int)($job['elapsed_seconds']??0); $eta=$job['eta_seconds']??null;
          $speed=(float)($job['speed_mib_s']??0); $alive=!empty($job['worker_alive']);
          $statusText=match($status){'done'=>'готово','failed'=>'ошибка','cancelled'=>'отменён','waiting_mysql'=>'MySQL обрабатывает блок','queued'=>'в очереди',default=>'импортируется'};
          $statusClass=$status==='done'?'hh-ok':(in_array($status,['failed','cancelled'],true)?'hh-bad':'hh-warn');
          $barClass=$status==='done'?' done':(in_array($status,['failed','cancelled'],true)?' failed':'');
        ?>
          <article class="db-job-v93">
            <header class="db-card-head-v93">
              <span class="db-card-icon-v93 job"><i class="fa-solid fa-file-arrow-down"></i></span>
              <div class="db-card-name-v93"><b><?= e((string)($job['database']??'')) ?></b><small><?= e((string)($job['source_name']??'')) ?></small></div>
              <span class="<?= $statusClass ?>"><?= e($statusText) ?></span>
            </header>
            <div class="db-job-bar-v93<?= $barClass ?>"><i style="width:<?= round($progress,1) ?>%"></i></div>
            <div class="db-job-meta-v93">
              <div><span>Прогресс</span><b><?= round($progress,1) ?>%</b></div>
              <div><span>Прочитано</span><b><?= e(human_bytes((float)($job['bytes_processed']??0))) ?></b><em>из <?= e(human_bytes((float)($job['bytes_total']??0))) ?></em></div>
              <div><span>Скорость</span><b><?= round($speed,1) ?> МиБ/с</b><em>процесс <?= $alive?'жив':'не найден' ?></em></div>
              <div><span>Таблиц создано</span><b><?= (int)($job['tables_count']??0) ?></b><em><?= e(human_bytes((float)($job['database_size_bytes']??0))) ?> в базе</em></div>
              <div><span>Прошло</span><b><?= gmdate('H:i:s',max(0,$elapsed)) ?></b><?php if(is_numeric($eta)): ?><em>осталось ~<?= gmdate('H:i:s',max(0,(int)$eta)) ?></em><?php endif; ?></div>
              <div><span>Задание</span><b class="db-job-id-v93"><?= e((string)($job['job_id']??'')) ?></b></div>
            </div>
            <?php if(!empty($job['error'])): ?>
              <div class="db-job-error-v93"><i class="fa-solid fa-circle-exclamation"></i><span><?= e(mb_substr((string)$job['error'],0,400)) ?></span></div>
            <?php elseif(!empty($job['log_tail']) && $status==='waiting_mysql'): ?>
              <div class="db-job-hint-v93"><i class="fa-solid fa-circle-info"></i><span>MySQL занят обработкой последнего блока — это не зависание.</span></div>
            <?php endif; ?>
            <?php if($running): ?>
              <div class="db-actions"><form method="post" onsubmit="return confirm('Остановить импорт? Уже загруженные таблицы останутся в базе.')"><?= csrf_field() ?><input type="hidden" name="action" value="cancel_import"><input type="hidden" name="job_id" value="<?= e((string)($job['job_id']??'')) ?>"><button class="btn btn-sm btn-outline-danger">Остановить импорт</button></form></div>
            <?php endif; ?>
          </article>
        <?php endforeach; if(!$imports): ?><div class="db-empty-v93">Импорты ещё не запускались.</div><?php endif; ?>
        </div>
      </div>
      <?php if(!empty($hasRunning)): ?><script>setTimeout(function(){location.reload()},5000);</script><?php endif; ?>

      <div class="panel-card">
        <div class="card-title-row flex-wrap"><h2><i class="fa-solid fa-users-gear me-2"></i>Аккаунты MySQL <span class="db-count-v93"><?= count($accounts) ?></span></h2></div>
        <div class="db-cards-v93">
        <?php foreach($accounts as $a):
          $remote=(int)$a['remote_allowed'];
          $connHost=$remote?$mysqlExternalHost:$mysqlLanHost;
        ?>
          <article class="db-card-v93<?= $remote?' is-remote':'' ?>">
            <header class="db-card-head-v93">
              <span class="db-card-icon-v93 user"><i class="fa-solid fa-user-lock"></i></span>
              <div class="db-card-name-v93"><b><?= e($a['username']) ?></b><small><?= e(mysql_host_label((string)$a['host_pattern'])) ?></small></div>
              <span class="<?= $remote?'hh-warn':'hh-ok' ?>"><i class="fa-solid <?= $remote?'fa-globe':'fa-house' ?>"></i><?= $remote?'внешний вход':'только локально' ?></span>
            </header>
            <div class="db-fields-v93">
              <div><span>База</span><code><?= e($a['db_name']?:'без привязки') ?></code></div>
              <div><span>Права</span><code><?= e($a['privileges']) ?></code></div>
              <div><span>Хост подключения</span><code class="db-copy-v93" data-copy-text="<?= e($connHost) ?>" title="Скопировать"><?= e($connHost) ?></code></div>
              <div><span>Пароль</span><code class="db-copy-v93 db-secret-v93" data-copy-text="<?= e($a['password_plain']) ?>" title="Скопировать"><?= e($a['password_plain']) ?></code></div>
            </div>
            <div class="db-actions">
              <a class="btn btn-sm btn-primary" href="/?page=pma_login&type=account&id=<?= (int)$a['id'] ?>"><i class="fa-solid fa-right-to-bracket me-1"></i>Войти</a>
              <button class="btn btn-sm btn-soft" onclick="copyText('Host: <?= e($connHost) ?>\nPort: 3306\nDatabase: <?= e($a['db_name']) ?>\nUser: <?= e($a['username']) ?>\nPassword: <?= e($a['password_plain']) ?>')"><i class="fa-regular fa-copy me-1"></i>Все данные</button>
              <form method="post" onsubmit="return confirm('Удалить MySQL аккаунт <?= e($a['username']) ?>?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_mysql_account"><input type="hidden" name="id" value="<?= (int)$a['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form>
            </div>
          </article>
        <?php endforeach; if(!$accounts): ?><div class="db-empty-v93">Аккаунтов пока нет.</div><?php endif; ?>
        </div>
      </div>

    </div>
  </div>
</div>
<script>
document.querySelectorAll('.db-access-pills input[type="radio"]').forEach(function(r){
  function upd(){
    var form=r.closest('form'); if(!form) return;
    var remote=form.querySelector('.remote-options'); if(!remote) return;
    var yes=form.querySelector('input[name="remote_allowed"][value="1"]');
    remote.classList.toggle('db-hidden', !(yes && yes.checked));
  }
  r.addEventListener('change', upd); upd();
});
document.querySelectorAll('.db-copy-v93').forEach(function(el){
  el.addEventListener('click', function(){
    var value = el.getAttribute('data-copy-text') || el.textContent || '';
    if(!value) return;
    if(typeof copyText === 'function'){ copyText(value); }
    else if(navigator.clipboard){ navigator.clipboard.writeText(value); }
    el.classList.add('copied');
    setTimeout(function(){ el.classList.remove('copied'); }, 900);
  });
});
</script><?php
}

function ftp_scope_clean(string $scope): string
{
    $scope = strtolower(trim($scope));
    return in_array($scope, ['all','sites','site','bots','backups','files'], true) ? $scope : 'all';
}

function ftp_scope_target_clean(string $scope, string $target): string
{
    $target = trim($target);
    if ($scope !== 'site') return '';
    if ($target === '' || !preg_match('/^[a-z0-9][a-z0-9.-]{1,250}[a-z0-9]$/i', $target)) {
        throw new RuntimeException('Выбери сайт для FTP-доступа');
    }
    return strtolower($target);
}

function ftp_scope_label_ui(string $scope, string $target = ''): string
{
    $scope = ftp_scope_clean($scope);
    return match ($scope) {
        'sites' => 'все сайты',
        'site' => 'сайт ' . ($target ?: 'не выбран'),
        'bots' => 'боты PM2',
        'backups' => 'backup',
        'files' => 'личная FTP-папка uploads',
        default => 'всё: сайты, боты, backup, uploads',
    };
}

function view_ftp(): void
{ $rows=db()->query('SELECT * FROM ftp_accounts ORDER BY id DESC')->fetchAll(); $siteOptions=db()->query('SELECT domain FROM sites ORDER BY domain ASC')->fetchAll(); $gen=default_ftp_password(); $doctor=run_ctl_json_cached(['ftp-doctor-json'],8,30); $publicHost=(string)(($doctor['configured_public_ip']??'') ?: ($doctor['public_ip']??'') ?: current_public_ipv4() ?: host_name()); $lanHost=(string)(($doctor['server_ip']??'') ?: app_config('server_ip','')); $ftpHost=$publicHost; $ftpIssue=(string)($doctor['issue']??''); $ftpHint=(string)($doctor['hint']??''); ?>
<div class="ftp-layout-v92">
  <div>
    <div class="panel-card ftp-create-card">
      <div class="kicker"><i class="fa-solid fa-folder-tree me-2"></i>FTP</div>
      <h2>Аккаунты доступа</h2>
      <div class="status-grid compact-status mt-3">
        <div><span>FTP-сервер</span><b class="<?= (($doctor['ftp_service']??'')==='active' || !empty($doctor['listen_21']))?'text-success':'text-danger' ?>"><?= e((string)(($doctor['ftp_service']??'') ?: 'runtime')) ?></b></div>
        <div><span>порт 21</span><b class="<?= !empty($doctor['listen_21'])?'text-success':'text-danger' ?>"><?= !empty($doctor['listen_21'])?'слушает':'закрыт' ?></b></div>
        <div><span>passive</span><b>40000-40100</b></div>
        <div><span>движок</span><b>Hyper FTP</b></div>
      </div>
      <?php if($ftpIssue !== ''): ?><div class="ftp-health mt-3"><b><?= e($ftpIssue) ?></b><?php if($ftpHint !== ''): ?><span><?= e($ftpHint) ?></span><?php endif; ?></div><?php endif; ?>
      <form method="post" class="vstack gap-3 mt-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_ftp">
        <input class="form-control" name="username" placeholder="hhftp_Danz" required>
        <div class="input-group"><input class="form-control" name="password" id="ftpPass" value="<?= e($gen) ?>" minlength="8" required><button class="btn btn-outline-light" type="button" onclick="copyValue('ftpPass')"><i class="fa-regular fa-copy"></i></button></div>
        <select class="form-select" name="scope" id="ftpScopeSelect">
          <option value="all">Показывать всё</option>
          <option value="sites">Только все сайты</option>
          <option value="site">Только один сайт</option>
          <option value="bots">Только боты</option>
          <option value="backups">Только backup</option>
          <option value="files">Только личную папку uploads</option>
        </select>
        <select class="form-select" name="scope_target" id="ftpSiteSelect">
          <option value="">Выбрать сайт</option>
          <?php foreach($siteOptions as $s): ?><option value="<?= e($s['domain']) ?>"><?= e($s['domain']) ?></option><?php endforeach; ?>
        </select>
        <button class="btn btn-primary btn-lg"><i class="fa-solid fa-plus me-2"></i>Создать FTP</button>
      </form>
      <form method="post" class="mt-3"><?= csrf_field() ?><input type="hidden" name="action" value="ftp_fix"><button class="btn btn-soft w-100"><i class="fa-solid fa-screwdriver-wrench me-2"></i>Починить FTP</button></form>
    </div>
  </div>
  <div>
    <div class="panel-card mb-3 ftp-connection-card">
      <div class="connection-line"><span>FileZilla</span><code>FTP <?= e($ftpHost) ?> : 21</code><b>Plain + Passive</b></div>
      <div class="connection-line"><span>LAN</span><code>FTP <?= e($lanHost ?: '192.168.x.x') ?> : 21</code><b>для локальной сети</b></div>
      <div class="ftp-connect-grid mt-3">
        <div><span>Из интернета</span><code><?= e($publicHost) ?></code></div>
        <div><span>В локальной сети</span><code><?= e($lanHost ?: $publicHost) ?></code></div>
        <div><span>Шифрование</span><code>Обычный FTP</code></div>
        <div><span>Режим</span><code>Пассивный</code></div>
      </div>
    </div>
    <div class="row g-3">
      <?php foreach($rows as $r): $cardHost=$publicHost; $scope=ftp_scope_clean((string)($r['access_scope']??'all')); $target=(string)($r['access_target']??''); $scopeLabel=ftp_scope_label_ui($scope,$target); ?>
        <div class="col-md-6"><div class="ftp-card ftp-card-v25">
          <h3><i class="fa-solid fa-user-lock me-2"></i><?= e($r['username']) ?></h3>
          <div class="cred"><span>Хост</span><code><?= e($cardHost) ?></code></div>
          <div class="cred"><span>Локальный хост</span><code><?= e($lanHost ?: $cardHost) ?></code></div>
          <div class="cred"><span>Порт</span><code>21</code></div>
          <div class="cred"><span>FTP-логин</span><code><?= e($r['username']) ?></code></div>
          <div class="cred"><span>Пароль</span><code><?= e($r['password_plain']?:'задать новый') ?></code></div>
          <div class="cred"><span>Открывает</span><code><?= e($scopeLabel) ?></code></div>
          <div class="ftp-tags"><span>Plain FTP</span><span>Passive</span><span><?= e($scopeLabel) ?></span></div>
          <div class="d-flex gap-2 mt-3 flex-wrap">
            <button class="btn btn-sm btn-light" onclick="copyText('Protocol: FTP\nHost: <?= e($cardHost) ?>\nPort: 21\nEncryption: Only use plain FTP\nTransfer mode: Passive\nLogin: <?= e($r['username']) ?>\nPassword: <?= e($r['password_plain']) ?>')">Копировать</button>
            <button class="btn btn-sm btn-outline-light" data-bs-toggle="modal" data-bs-target="#ftp<?= (int)$r['id'] ?>">Пароль</button>
            <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="repair_ftp_account"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-soft">Восстановить</button></form>
            <form method="post" onsubmit="return confirm('Удалить FTP?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_ftp"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-danger">Удалить</button></form>
          </div>
        </div></div>
        <div class="modal fade hh-modal" id="ftp<?= (int)$r['id'] ?>"><div class="modal-dialog modal-dialog-centered"><div class="modal-content"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="reset_ftp_password"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><div class="modal-header"><h5>Новый пароль FTP</h5><button class="btn-close" data-bs-dismiss="modal" type="button"></button></div><div class="modal-body"><input class="form-control" name="password" value="<?= e(default_ftp_password()) ?>" minlength="8" required></div><div class="modal-footer"><button class="btn btn-primary">Сохранить</button></div></form></div></div></div>
      <?php endforeach; if(!$rows): ?><div class="empty">FTP аккаунтов пока нет</div><?php endif; ?>
    </div>
  </div>
</div><?php }


function pm2_status_map(): array { $d=bots_usage_data(); $m=[]; foreach(($d['bots']??[]) as $p) { $name=(string)($p['name']??''); if($name!=='') $m[$name]=$p; } return $m; }
function view_deploy_center(): void
{
  $cfg=deploy_center_config();
  $doctor=run_ctl_json_live(['deploy-center-doctor'],25);
  $projects=db()->query('SELECT * FROM managed_projects ORDER BY project_id DESC')->fetchAll();
  $lastSync=setting_get('deploy_last_sync','ещё не выполнялась');
  $masterStatus=(string)($cfg['master_pm2']['status']??'not_found');
  $masterFiles=$cfg['master_files']??[];
  $templateFiles=$cfg['template_files']??[];
  $masterTg=$cfg['master_telegram']??[];
  $serverMissing=$doctor['missing']??[];
  $uploadMissing=$doctor['upload_missing']??[];
  ?>
<div class="deploy-manager-v75">
  <section class="deploy-manager-hero-v75 panel-card">
    <div class="deploy-manager-copy-v75">
      <div class="eyebrow"><i class="fa-solid fa-diagram-project"></i> MyStock Deploy Manager</div>
      <h2>Главный deploy-бот и все магазины</h2>
      <p>Отдельный центр управления. Главный бот читает проекты из MySQL, берёт твои файлы шаблона и создаёт каждый магазин в своей папке с отдельным venv и PM2-процессом.</p>
      <div class="deploy-manager-badges-v75">
        <span><i class="fa-solid fa-crown"></i> Master: <b><?= e($masterStatus) ?></b></span>
        <span><i class="fa-solid fa-store"></i> Проектов: <b><?= count($projects) ?></b></span>
        <span><i class="fa-solid fa-clock"></i> Sync: <b><?= e($lastSync) ?></b></span>
      </div>
    </div>
    <div class="deploy-manager-hero-actions-v75">
      <form method="post" data-async-submit><?= csrf_field() ?><input type="hidden" name="action" value="deploy_sync"><button class="btn btn-primary btn-lg" data-loading-text="Читаю SQL и Telegram getMe..."><i class="fa-solid fa-rotate me-2"></i>Синхронизировать</button></form>
      <a class="btn btn-soft" href="/?page=deploy_logs&master=1"><i class="fa-solid fa-terminal me-2"></i>Логи master</a>
    </div>
  </section>

  <?php if($serverMissing): ?><div class="alert alert-danger mt-4"><b>На сервере не хватает:</b> <?= e(implode(', ', $serverMissing)) ?><?= !empty($doctor['db_error'])?' · '.e((string)$doctor['db_error']):'' ?></div><?php endif; ?>
  <?php if($uploadMissing): ?><div class="alert alert-warning mt-3"><b>Нужно загрузить через эту страницу:</b> <?= e(implode(', ', $uploadMissing)) ?></div><?php endif; ?>

  <div class="row g-4 mt-1">
    <div class="col-xxl-4 col-xl-6">
      <section class="panel-card deploy-config-card-v75 h-100">
        <div class="deploy-card-icon-v75 db"><i class="fa-solid fa-database"></i></div>
        <h3>Подключение к MyStock SQL</h3>
        <p class="muted">Из SQL берутся проекты, токены, владельцы, статусы и названия магазинов.</p>
        <form method="post" class="vstack gap-3 mt-3">
          <?= csrf_field() ?><input type="hidden" name="action" value="deploy_config_save">
          <div class="row g-2"><div class="col-8"><label class="hh-field"><span>DB_HOST</span><input class="form-control" name="db_host" value="<?= e((string)($cfg['db_host']??'90.189.208.25')) ?>"></label></div><div class="col-4"><label class="hh-field"><span>PORT</span><input class="form-control" type="number" name="db_port" value="<?= e((string)($cfg['db_port']??3306)) ?>"></label></div></div>
          <label class="hh-field"><span>DB_USER</span><input class="form-control" name="db_user" value="<?= e((string)($cfg['db_user']??'mystock')) ?>"></label>
          <label class="hh-field"><span>DB_PASS</span><input class="form-control" type="password" name="db_pass" placeholder="<?= !empty($cfg['db_pass_set'])?'Пароль сохранён — оставь пустым':'Пароль MySQL' ?>"></label>
          <label class="hh-field"><span>DB_NAME</span><input class="form-control" name="db_name" value="<?= e((string)($cfg['db_name']??'mystock')) ?>"></label>
          <button class="btn btn-soft"><i class="fa-solid fa-floppy-disk me-2"></i>Сохранить SQL</button>
        </form>
      </section>
    </div>

    <div class="col-xxl-4 col-xl-6">
      <section class="panel-card deploy-master-card-v75 h-100">
        <div class="deploy-card-head-v75"><div class="deploy-card-icon-v75 master"><i class="fa-solid fa-crown"></i></div><span class="bot-status-v29 <?= $masterStatus==='online'?'ok':'bad' ?>"><?= e($masterStatus) ?></span></div>
        <h3>Главный deploy-бот</h3>
        <p class="muted">Ты сам загружаешь все три файла. Панель ничего не генерирует и не заменяет внутри главного бота.</p>
        <form method="post" enctype="multipart/form-data" class="vstack gap-3 mt-3" data-async-submit>
          <?= csrf_field() ?><input type="hidden" name="action" value="deploy_master_upload">
          <label class="upload-mini deploy-upload-v75"><span><i class="fa-brands fa-python"></i> bot.py</span><input class="form-control" type="file" name="master_bot_file" accept=".py"></label>
          <label class="upload-mini deploy-upload-v75"><span><i class="fa-solid fa-key"></i> .env</span><input class="form-control" type="file" name="master_env_file" accept=".env,.txt"></label>
          <label class="upload-mini deploy-upload-v75"><span><i class="fa-solid fa-list"></i> requirements.txt</span><input class="form-control" type="file" name="master_requirements_file" accept=".txt"></label>
          <button class="btn btn-primary" data-loading-text="Создаю venv, ставлю зависимости и запускаю PM2..."><i class="fa-solid fa-cloud-arrow-up me-2"></i>Загрузить и запустить</button>
        </form>
        <div class="deploy-file-state-v75 mt-3">
          <span class="<?= !empty($masterFiles['bot_py']['exists'])?'ok':'bad' ?>"><i class="fa-solid fa-file-code"></i> bot.py</span>
          <span class="<?= !empty($masterFiles['env']['exists'])?'ok':'bad' ?>"><i class="fa-solid fa-key"></i> .env</span>
          <span class="<?= !empty($masterFiles['requirements']['exists'])?'ok':'warn' ?>"><i class="fa-solid fa-list"></i> requirements</span>
        </div>
        <?php if(!empty($masterTg['link'])): ?><a class="deploy-master-link-v75 mt-3" target="_blank" rel="noopener" href="<?= e((string)$masterTg['link']) ?>"><i class="fa-brands fa-telegram"></i><span><?= e((string)($masterTg['first_name']?:$masterTg['username'])) ?></span><b>@<?= e((string)$masterTg['username']) ?></b></a><?php endif; ?>
        <div class="d-flex gap-2 mt-3 flex-wrap"><?php foreach(['start'=>'Start','stop'=>'Stop','restart'=>'Restart'] as $a=>$label): ?><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="deploy_master_action"><input type="hidden" name="master_action" value="<?= e($a) ?>"><button class="btn btn-sm btn-soft"><?= e($label) ?></button></form><?php endforeach; ?><a class="btn btn-sm btn-soft" href="/?page=deploy_logs&master=1">Logs</a></div>
      </section>
    </div>

    <div class="col-xxl-4 col-xl-12">
      <section class="panel-card deploy-template-card-v75 h-100">
        <div class="deploy-card-icon-v75 template"><i class="fa-solid fa-box-open"></i></div>
        <h3>Файлы для новых магазинов</h3>
        <p class="muted">Загружаются только твои реальные файлы. Никаких bot.py-заглушек установщик не создаёт.</p>
        <form method="post" enctype="multipart/form-data" class="vstack gap-3 mt-3" data-async-submit>
          <?= csrf_field() ?><input type="hidden" name="action" value="deploy_template_upload">
          <label class="upload-mini deploy-upload-v75"><span><i class="fa-brands fa-python"></i> bot.py магазина</span><input class="form-control" type="file" name="template_bot_file" accept=".py"></label>
          <label class="upload-mini deploy-upload-v75"><span><i class="fa-solid fa-list"></i> requirements.txt магазина</span><input class="form-control" type="file" name="template_requirements_file" accept=".txt"></label>
          <button class="btn btn-soft"><i class="fa-solid fa-floppy-disk me-2"></i>Сохранить мои файлы</button>
        </form>
        <div class="deploy-file-state-v75 mt-3">
          <span class="<?= !empty($templateFiles['bot_py']['exists'])?'ok':'bad' ?>"><i class="fa-solid fa-file-code"></i> bot.py</span>
          <span class="<?= !empty($templateFiles['requirements']['exists'])?'ok':'warn' ?>"><i class="fa-solid fa-list"></i> requirements</span>
        </div>
        <div class="deploy-paths-v75 mt-3"><span>Master</span><code><?= e((string)($cfg['master_dir']??'')) ?></code><span>Шаблон</span><code><?= e((string)($cfg['template_dir']??'')) ?></code><span>Магазины</span><code><?= e((string)($cfg['managed_dir']??'')) ?></code></div>
      </section>
    </div>
  </div>

  <section class="panel-card mt-4 deploy-projects-v75">
    <div class="card-title-row flex-wrap">
      <div><div class="eyebrow"><i class="fa-solid fa-store"></i> SQL projects</div><h2>Проекты / магазины</h2><div class="small muted">Каждый проект получает папку <code>&lt;project_id&gt;-&lt;название&gt;</code>, свой <code>.env</code>, venv и PM2.</div></div>
      <div class="d-flex gap-2"><span class="badge text-bg-info"><?= count($projects) ?> проектов</span><a class="btn btn-sm btn-soft" href="/?page=files&root=bots"><i class="fa-solid fa-folder-open me-1"></i>Файлы</a></div>
    </div>
    <div class="table-responsive"><table class="table table-dark-soft align-middle deploy-project-table-v75"><thead><tr><th>Магазин</th><th>Кто создал</th><th>Telegram-бот</th><th>Состояние</th><th>Папка</th><th>Управление</th></tr></thead><tbody>
    <?php foreach($projects as $p): ?><tr>
      <td><b class="deploy-project-name-v75">#<?= (int)$p['project_id'] ?> <?= e($p['project_name']) ?></b><div class="small muted mt-1">Тариф: <?= e($p['subscription_status']) ?> · token fp: <code><?= e($p['token_fingerprint']) ?></code></div></td>
      <td><b><?= e($p['owner_name']?:($p['owner_username']?:'Без имени')) ?></b><div class="small muted"><?= $p['owner_username']?'@'.e($p['owner_username']).' · ':'' ?>TG <?= e($p['owner_tg_id']) ?></div></td>
      <td><?php if($p['bot_link']): ?><a class="deploy-telegram-link-v75" target="_blank" rel="noopener" href="<?= e($p['bot_link']) ?>"><i class="fa-brands fa-telegram"></i><span>@<?= e($p['bot_username']) ?></span></a><?php else: ?><span class="muted">getMe недоступен</span><?php endif; ?></td>
      <td><span class="bot-status-v29 <?= $p['pm2_status']==='online'?'ok':'bad' ?>"><?= e($p['pm2_status']) ?></span><div class="small muted mt-1">SQL: <?= e($p['sql_status']?:'—') ?> · user: <?= e($p['bot_active']) ?></div><?php if($p['last_error']): ?><div class="deploy-error-v75" title="<?= e($p['last_error']) ?>"><?= e($p['last_error']) ?></div><?php endif; ?></td>
      <td><code class="deploy-project-path-v75"><?= e($p['deploy_path']) ?></code></td>
      <td><div class="deploy-actions-v75"><form method="post" data-async-submit><?= csrf_field() ?><input type="hidden" name="action" value="deploy_project_action"><input type="hidden" name="project_id" value="<?= (int)$p['project_id'] ?>"><input type="hidden" name="project_action" value="deploy"><button class="btn btn-sm btn-primary" data-loading-text="Копирую файлы, создаю .env и venv...">Развернуть</button></form><?php foreach(['start'=>'Start','stop'=>'Stop','restart'=>'Restart'] as $a=>$label): ?><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="deploy_project_action"><input type="hidden" name="project_id" value="<?= (int)$p['project_id'] ?>"><input type="hidden" name="project_action" value="<?= e($a) ?>"><button class="btn btn-sm btn-soft"><?= e($label) ?></button></form><?php endforeach; ?><a class="btn btn-sm btn-soft" href="/?page=deploy_logs&project_id=<?= (int)$p['project_id'] ?>">Logs</a><form method="post" onsubmit="return confirm('Полностью удалить развернутого бота «<?= e(addslashes($p['project_name'])) ?>»? PM2-процесс, папка, .env, venv и логи будут удалены. Сам проект в MySQL останется.');"><?= csrf_field() ?><input type="hidden" name="action" value="deploy_project_action"><input type="hidden" name="project_id" value="<?= (int)$p['project_id'] ?>"><input type="hidden" name="project_action" value="delete"><input type="hidden" name="delete_files" value="1"><button class="btn btn-sm btn-danger"><i class="fa-solid fa-trash-can me-1"></i>Удалить</button></form></div></td>
    </tr><?php endforeach; if(!$projects): ?><tr><td colspan="6" class="empty">Сохрани подключение к MySQL и нажми «Синхронизировать»</td></tr><?php endif; ?>
    </tbody></table></div>
  </section>
</div>
<?php }

function view_deploy_logs(): void
{
  $master=!empty($_GET['master']); $pid=(int)($_GET['project_id']??0); $args=$master?['deploy-center-master-action','logs']:['deploy-center-project-action',(string)$pid,'logs','0']; $res=run_ctl_json($args,40); $text=(string)($res['output']??$res['error']??$res['_error']??'Логов нет'); ?>
  <div class="panel-card"><div class="card-title-row"><h2><?= $master?'Логи главного deploy-бота':'Логи проекта #'.$pid ?></h2><a class="btn btn-soft" href="/?page=deploy_center">Назад</a></div><pre class="logs"><?= e($text) ?></pre></div><?php
}

function bots_usage_data(): array
{
  // v92: одна команда отдаёт и телеметрию ботов, и контекст сервера,
  // чтобы в панели было видно не абстрактные мегабайты, а реальную долю.
  $data = run_ctl_json_live(['bots-usage-json'], 10);
  if (is_array($data) && empty($data['_error']) && isset($data['bots']) && is_array($data['bots'])) {
    return $data;
  }
  $legacy = run_ctl_json_live(['bot-list-json'], 8);
  $bots = (is_array($legacy) && empty($legacy['_error'])) ? array_values($legacy) : [];
  return [
    'ok' => false,
    'server' => [],
    'totals' => ['count' => count($bots), 'online' => 0, 'memory' => 0, 'cpu' => 0, 'disk_bytes' => 0],
    'bots' => $bots,
    '_error' => (string)($data['_error'] ?? ''),
  ];
}

function bots_bar_percent(float $part, float $whole): float
{
  if ($whole <= 0) return 0.0;
  return max(0.0, min(100.0, round($part / $whole * 100, 1)));
}

function view_bots(): void
{
  $bots = db()->query('SELECT * FROM bots ORDER BY id DESC')->fetchAll();
  $usage = bots_usage_data();
  $status = [];
  foreach (($usage['bots'] ?? []) as $p) { $status[(string)($p['name'] ?? '')] = $p; }
  $server = $usage['server'] ?? [];
  $totals = $usage['totals'] ?? [];
  $memTotal = (float)($server['mem_total'] ?? 0);
  $cores = (int)($server['cpu_cores'] ?? 0);
  $totalBotMem = (float)($totals['memory'] ?? 0);
  $modals = [];
  ?>
<div class="bots-page-v92" data-live-bots data-mem-total="<?= e((string)$memTotal) ?>" data-cpu-cores="<?= e((string)$cores) ?>">
  <div class="panel-card bot-upload-card bot-upload-card-v29">
    <div class="eyebrow"><i class="fa-solid fa-robot"></i> PM2 24/7</div>
    <h2>Загрузить бота</h2>
    <form method="post" enctype="multipart/form-data" class="vstack gap-3" data-async-submit>
      <?= csrf_field() ?><input type="hidden" name="action" value="create_bot">
      <input class="form-control" name="name" placeholder="HYPER-HOST-BOT" required>
      <div class="row g-2"><div class="col-5"><select class="form-select" name="runtime"><option value="python">Python</option><option value="node">Node.js</option><option value="php">PHP</option><option value="custom">Custom</option></select></div><div class="col-7"><input class="form-control" name="main_file" value="bot.py" placeholder="bot.py"></div></div>
      <label class="upload-mini"><span>Основной файл</span><input class="form-control" type="file" name="bot_file" accept=".py,.js,.php,.sh,.txt"></label>
      <label class="upload-mini"><span>.env</span><input class="form-control" type="file" name="env_file" accept=".env,.txt"></label>
      <label class="upload-mini"><span>requirements.txt / package.json</span><input class="form-control" type="file" name="requirements_file" accept=".txt,.json"></label>
      <input class="form-control" type="number" name="memory_limit_mb" placeholder="RAM лимит, MB, например 512">
      <button class="btn btn-primary btn-lg w-100" data-loading-text="Устанавливаю и запускаю... (обычно 10-40с, дольше — если ставятся тяжёлые зависимости)"><i class="fa-solid fa-play me-2"></i>Загрузить и запустить</button>
    </form>
    <div class="small muted mt-2" data-async-hint style="display:none">Не закрывай вкладку — идёт установка зависимостей и запуск через PM2. Как закончится, страница сама обновится.</div>
    <form method="post" class="mt-3"><?= csrf_field() ?><input type="hidden" name="action" value="pm2_persist"><button class="btn btn-soft w-100"><i class="fa-solid fa-shield-heart me-2"></i>Включить 24/7</button></form>
  </div>

  <div class="panel-card bots-panel-v29">
    <div class="card-title-row flex-wrap"><h2><i class="fa-solid fa-list-check me-2"></i>Нагрузка на сервер</h2><a class="btn btn-sm btn-soft" href="/?page=files&root=bots">Файлы ботов</a></div>

    <?php if (!empty($usage['_error'])): ?>
      <div class="alert alert-warning"><?= e((string)$usage['_error']) ?></div>
    <?php endif; ?>

    <div class="bots-summary-v92">
      <div class="bots-summary-item-v92">
        <span>Ботов онлайн</span>
        <b data-bots-online><?= (int)($totals['online'] ?? 0) ?> / <?= (int)($totals['count'] ?? count($bots)) ?></b>
        <em data-bots-load>load <?= e((string)($server['load1'] ?? '—')) ?></em>
      </div>
      <div class="bots-summary-item-v92">
        <span>RAM всех ботов</span>
        <b data-bots-mem><?= e(human_bytes($totalBotMem)) ?></b>
        <em data-bots-mem-pct><?= e((string)($totals['memory_percent'] ?? 0)) ?>% от <?= e(human_bytes($memTotal)) ?></em>
      </div>
      <div class="bots-summary-item-v92">
        <span>CPU всех ботов</span>
        <b data-bots-cpu><?= e((string)($totals['cpu'] ?? 0)) ?>%</b>
        <em data-bots-cpu-pct><?= e((string)($totals['cpu_of_server'] ?? 0)) ?>% от <?= (int)$cores ?> ядер</em>
      </div>
      <div class="bots-summary-item-v92">
        <span>Диск ботов</span>
        <b data-bots-disk><?= e(human_bytes((float)($totals['disk_bytes'] ?? 0))) ?></b>
        <em>код и зависимости</em>
      </div>
    </div>

    <div class="bot-grid-v92">
    <?php foreach ($bots as $b):
      $pm = $status[$b['name']] ?? [];
      $st = (string)($pm['status'] ?? 'not_found');
      $online = $st === 'online';
      $files = $pm['files'] ?? [];
      $mem = (float)($pm['memory'] ?? 0);
      $memPct = (float)($pm['memory_percent'] ?? 0);
      $cpu = (float)($pm['cpu_percent'] ?? ($pm['cpu'] ?? 0));
      $cpuServer = (float)($pm['cpu_of_server'] ?? 0);
      $restarts = (int)($pm['restarts'] ?? 0);
      $crash = !empty($pm['crash_loop']);
      $memShare = bots_bar_percent($mem, $totalBotMem);
      $cpuBar = max(0.0, min(100.0, $cpu));
      $cardClass = $online ? ($crash ? 'is-warn' : '') : 'is-down';
      ob_start(); ?>
      <div class="modal fade hh-modal bot-delete-modal" id="deleteBot<?= (int)$b['id'] ?>" tabindex="-1" aria-hidden="true">
        <div class="modal-dialog modal-dialog-centered"><div class="modal-content">
          <div class="modal-header"><div><div class="eyebrow"><i class="fa-solid fa-trash"></i> Удаление</div><h5 class="modal-title mb-0"><?= e($b['name']) ?></h5></div><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
          <div class="modal-body">
            <div class="small muted mb-3">Папка: <code><?= e($b['path']) ?></code></div>
            <form method="post" class="mb-3">
              <?= csrf_field() ?><input type="hidden" name="action" value="delete_bot"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>">
              <button class="btn btn-outline-warning w-100">Удалить только из PM2, файлы оставить</button>
            </form>
            <form method="post" class="vstack gap-3">
              <?= csrf_field() ?><input type="hidden" name="action" value="delete_bot"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>"><input type="hidden" name="delete_files" value="1">
              <label class="form-label">Подтверди имя бота:</label>
              <input class="form-control form-control-lg" name="confirm_name" placeholder="<?= e($b['name']) ?>" autocomplete="off" required>
              <button class="btn btn-danger btn-lg w-100">Удалить PM2 + файлы с сервера</button>
            </form>
          </div>
        </div></div>
      </div>
      <?php $modals[] = ob_get_clean(); ?>

      <div class="bot-card-v92 bot-card-live <?= e($cardClass) ?>" data-bot-name="<?= e($b['name']) ?>">
        <div class="bot-head-v92">
          <div class="bot-mark-v92"><i class="fa-solid fa-robot"></i></div>
          <div class="bot-id-v92"><b><?= e($b['name']) ?></b><span><?= e($b['runtime']) ?> · <?= e($b['start_command'] ?: 'bot.py') ?></span></div>
          <span class="bot-state-v92 <?= $online ? 'ok' : 'bad' ?>" data-bot-status><?= e($st) ?></span>
        </div>

        <div class="bot-alert-v92" data-bot-alert<?= $crash ? '' : ' hidden' ?>>
          <i class="fa-solid fa-triangle-exclamation"></i>
          <span data-bot-alert-text><?= $crash ? 'Бот в цикле перезапусков: '.(int)$restarts.' рестартов и нулевой uptime. Смотри Logs — процесс падает сразу после старта.' : '' ?></span>
        </div>

        <div class="bot-load-v92">
          <div class="bot-load-row-v92 ram">
            <div class="bot-load-top-v92"><span>RAM</span><b><span data-bot-mem><?= e(human_bytes($mem)) ?></span><em data-bot-mem-pct><?= e((string)$memPct) ?>% сервера</em></b></div>
            <div class="bot-load-bar-v92"><i data-bot-mem-bar style="width:<?= e((string)$memShare) ?>%"></i></div>
            <div class="bot-load-foot-v92"><span>из <?= e(human_bytes($memTotal)) ?> на сервере</span><span data-bot-mem-share>доля среди ботов <?= e((string)$memShare) ?>%</span></div>
          </div>
          <div class="bot-load-row-v92 cpu">
            <div class="bot-load-top-v92"><span>CPU</span><b><span data-bot-cpu><?= e((string)$cpu) ?>% ядра</span><em data-bot-cpu-pct><?= e((string)$cpuServer) ?>% сервера</em></b></div>
            <div class="bot-load-bar-v92"><i data-bot-cpu-bar style="width:<?= e((string)$cpuBar) ?>%"></i></div>
            <div class="bot-load-foot-v92"><span><?= (int)$cores ?> ядер всего</span><span data-bot-cputime>CPU time <?= e((string)($pm['cpu_seconds'] ?? 0)) ?>с</span></div>
          </div>
        </div>

        <div class="bot-facts-v92">
          <div><span>Uptime</span><b data-bot-uptime><?= e((string)($pm['uptime'] ?? '—')) ?></b></div>
          <div><span>Restarts</span><b data-bot-restarts class="<?= $restarts > 50 ? 'bad' : ($restarts > 5 ? 'warn' : '') ?>"><?= (int)$restarts ?></b></div>
          <div><span>Threads</span><b data-bot-threads><?= e((string)($pm['threads'] ?? '—')) ?></b></div>
          <div><span>PID</span><b data-bot-pid><?= e((string)($pm['pid'] ?? '—')) ?></b></div>
          <div><span>Папка</span><b data-bot-disk><?= e(human_bytes((float)($pm['disk_bytes'] ?? 0))) ?></b></div>
        </div>

        <div class="bot-path-v92"><?= e($b['path']) ?></div>
        <div class="bot-files-v92" data-bot-files><?php if ($files): foreach ($files as $f): ?><span><?= e($f) ?></span><?php endforeach; else: ?><em>файлы не прочитаны</em><?php endif; ?></div>

        <div class="bot-actions-v92">
          <?php foreach (['start' => 'Start', 'stop' => 'Stop', 'restart' => 'Restart', 'install' => 'Deps'] as $cmd => $label): ?>
            <form method="post" data-async-submit><?= csrf_field() ?><input type="hidden" name="action" value="bot_action"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>"><input type="hidden" name="bot_action" value="<?= e($cmd) ?>"><button class="btn btn-sm btn-soft" data-loading-text="<?= $cmd === 'install' ? 'Ставлю зависимости...' : '...' ?>"><?= e($label) ?></button></form>
          <?php endforeach; ?>
          <form method="post" onsubmit="return confirm('Остановить локальные дубли этого бота?')"><?= csrf_field() ?><input type="hidden" name="action" value="bot_action"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>"><input type="hidden" name="bot_action" value="kill-conflicts"><button class="btn btn-sm btn-outline-warning">Fix</button></form>
          <a class="btn btn-sm btn-soft" href="/?page=bot_logs&id=<?= (int)$b['id'] ?>">Logs</a>
          <a class="btn btn-sm btn-soft" href="/?page=files&root=bots&path=<?= e($b['name']) ?>">Files</a>
          <button type="button" class="btn btn-sm btn-outline-danger" data-bs-toggle="modal" data-bs-target="#deleteBot<?= (int)$b['id'] ?>">Delete</button>
        </div>
      </div>
    <?php endforeach; if (!$bots): ?><div class="empty">Ботов пока нет. Загрузи первого через форму слева.</div><?php endif; ?>
    </div>
  </div>
</div>
<?= implode("\n", $modals) ?>
<?php }

function view_bot_logs(): void { $id=(int)($_GET['id']??0); $st=db()->prepare('SELECT * FROM bots WHERE id=?'); $st->execute([$id]); $b=$st->fetch(); if(!$b){echo '<div class="panel-card empty">Бот не найден</div>';return;} $res=run_ctl(['bot','logs',$b['name']],30); ?><div class="panel-card"><div class="card-title-row"><h2>Логи PM2: <?= e($b['name']) ?></h2><a class="btn btn-soft" href="/?page=bots">Назад</a></div><pre class="logs"><?= e($res['output']?:'Логов пока нет') ?></pre></div><?php }

function view_backups(): void { $jobs=db()->query('SELECT * FROM backup_jobs ORDER BY id DESC')->fetchAll(); $files=run_ctl_json(['backup-list-json'],30); ?>
<div class="row g-4"><div class="col-lg-4"><div class="panel-card"><h2>Создать backup сейчас</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="backup_run"><select class="form-select" name="target"><option value="all">Всё</option><option value="sites">Сайты</option><option value="bots">Боты</option><option value="db">Базы MySQL</option><option value="panel">Панель</option></select><button class="btn btn-primary">Создать backup</button></form></div><div class="panel-card mt-4"><h2>Расписание</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="backup_job"><input class="form-control" name="name" placeholder="daily_all" required><input class="form-control" name="schedule" value="0 3 * * *" required><select class="form-select" name="target"><option value="all">Всё</option><option value="sites">Сайты</option><option value="bots">Боты</option><option value="db">Базы</option></select><button class="btn btn-primary">Сохранить расписание</button></form></div></div><div class="col-lg-8"><div class="panel-card"><h2>Backup задачи</h2><div class="table-responsive"><table class="table table-dark-soft"><?php foreach($jobs as $j): ?><tr><td><b><?= e($j['name']) ?></b></td><td><code><?= e($j['schedule']) ?></code></td><td><?= e($j['target']) ?></td><td><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="delete_backup_job"><input type="hidden" name="id" value="<?= (int)$j['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$jobs): ?><tr><td class="empty">Задач пока нет</td></tr><?php endif; ?></table></div><h2 class="mt-4">Архивы</h2><div class="table-responsive"><table class="table table-dark-soft"><?php foreach(($files['_error']??null)?[]:$files as $f): ?><tr><td><code><?= e($f['name']) ?></code></td><td><?= e(human_bytes((float)$f['size'])) ?></td><td><?= e(date('d.m.Y H:i',(int)$f['mtime'])) ?></td></tr><?php endforeach; ?></table></div></div></div></div><?php }

function view_dns(): void {
    $zones=db()->query('SELECT * FROM dns_zones ORDER BY id DESC')->fetchAll();
    $pub=setting_get('public_ip_override',(string)app_config('public_ip','90.189.208.25'));
    $inspectDomain=strtolower(trim((string)($_GET['inspect']??($zones[0]['domain']??''))));
    $inspect=null;
    if($inspectDomain!=='' && is_valid_domain($inspectDomain)) $inspect=run_ctl_json_cached(['dns-inspect-json',$inspectDomain],30,300);
    $panelDomainRaw=trim((string)app_config('panel_domain',''));
    $panelDomainSet=($panelDomainRaw!=='' && $panelDomainRaw!=='_' && is_valid_domain($panelDomainRaw));
    $zoneDomains=array_map(static fn($z)=>(string)$z['domain'],$zones);
    $sitesNoDns=array_values(array_filter(
        db()->query('SELECT domain FROM sites ORDER BY domain ASC')->fetchAll(),
        static fn($s)=>!in_array((string)$s['domain'],$zoneDomains,true)
    ));
?>
<div class="dns-page-v40">
  <div class="panel-card mb-4 dns-ns-summary-v46">
    <div class="card-title-row flex-wrap gap-2">
      <div><i class="fa-solid fa-server me-2"></i><b>Твои DNS-серверы</b></div>
      <?php if(!$panelDomainSet): ?><a class="btn btn-sm btn-soft" href="/?page=network">Настроить домен панели</a><?php endif; ?>
    </div>
    <?php if($panelDomainSet): ?>
      <p class="small muted mb-2">Эти два адреса пропиши у регистратора ЛЮБОГО домена, который переносишь на панель — не нужно каждый раз заводить отдельные NS/glue.</p>
      <div class="dns-compact-grid">
        <div><span>NS1</span><code data-copy="ns1.<?= e($panelDomainRaw) ?>">ns1.<?= e($panelDomainRaw) ?></code></div>
        <div><span>NS2</span><code data-copy="ns2.<?= e($panelDomainRaw) ?>">ns2.<?= e($panelDomainRaw) ?></code></div>
        <div><span>Glue / IP (только для <?= e($panelDomainRaw) ?>)</span><code data-copy="<?= e($pub) ?>"><?= e($pub) ?></code></div>
      </div>
    <?php else: ?>
      <p class="small muted mb-0">Сначала укажи домен панели в Настройках сети — тогда у тебя появятся свои постоянные NS вида <code>ns1.твой-домен-панели</code>, которые можно прописывать у любых доменов без повторной настройки glue.</p>
    <?php endif; ?>
  </div>

  <?php if($sitesNoDns): ?>
  <div class="panel-card mb-4">
    <div class="card-title-row"><h2><i class="fa-solid fa-list-check me-2"></i>Домены без DNS-зоны</h2></div>
    <p class="small muted mb-2">Это домены твоих сайтов в панели, для которых ещё не создана DNS-зона. Жми, чтобы сразу выпустить зону с общими NS панели.</p>
    <div class="d-flex flex-wrap gap-2">
      <?php foreach($sitesNoDns as $s): ?>
        <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="dns_wizard"><input type="hidden" name="domain" value="<?= e($s['domain']) ?>"><input type="hidden" name="public_ip" value="<?= e($pub) ?>"><input type="hidden" name="panel_subdomain" value="panel"><button class="btn btn-sm btn-soft"><i class="fa-solid fa-plus me-1"></i><?= e($s['domain']) ?></button></form>
      <?php endforeach; ?>
    </div>
  </div>
  <?php endif; ?>

  <div class="dns-hero panel-card mb-4">
    <div>
      <div class="kicker"><i class="fa-solid fa-diagram-project me-2"></i>DNS</div>
      <h2>Перенос домена на HYPER-HOST</h2>
    </div>
    <form method="post" class="dns-create-form"><?= csrf_field() ?><input type="hidden" name="action" value="dns_wizard">
      <input class="form-control" name="domain" placeholder="mystockbot.xyz" required>
      <input class="form-control" name="public_ip" value="<?= e($pub) ?>" placeholder="90.189.208.25">
      <input class="form-control" name="panel_subdomain" value="panel" placeholder="panel">
      <button class="btn btn-primary"><i class="fa-solid fa-wand-magic-sparkles me-2"></i>Создать зону</button>
    </form>
  </div>

  <div class="row g-4">
    <div class="col-xxl-7">
      <?php foreach($zones as $z):
        $rs=db()->prepare('SELECT * FROM dns_records WHERE zone_id=? ORDER BY id'); $rs->execute([(int)$z['id']]); $recs=$rs->fetchAll();
        $status=run_ctl_json_cached(['dns-status-json',$z['domain']],8,60);
        $info=run_ctl_json_cached(['dns-inspect-json',$z['domain']],30,300);
        $currentNs=$info['public_ns'] ?? [];
        $delegated=($info['delegation_status']??'')==='on_hyper_host';
      ?>
      <div class="panel-card mb-4 dns-zone-card-v40">
        <div class="card-title-row align-items-start flex-wrap gap-3">
          <div class="min-w-0"><h2><?= e($z['domain']) ?></h2><div class="small muted">Зона на сервере: <code><?= e((string)($status['zonefile'] ?? '')) ?></code></div></div>
          <div class="d-flex gap-2 flex-wrap">
            <a class="btn btn-sm btn-soft" href="/?page=dns&inspect=<?= e($z['domain']) ?>">Проверить</a>
            <form method="post" onsubmit="return confirm('Удалить DNS зону?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_dns_zone"><input type="hidden" name="id" value="<?= (int)$z['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form>
          </div>
        </div>
        <div class="dns-compact-grid my-3">
          <div><span>Bind9</span><b class="<?= !empty($status['bind9_ok'])?'hh-ok':'hh-bad' ?>"><?= !empty($status['bind9_ok'])?'работает':'ошибка' ?></b></div>
          <div><span>Zone</span><b class="<?= !empty($status['zone_ok'])?'hh-ok':'hh-bad' ?>"><?= !empty($status['zone_ok'])?'ok':'bad' ?></b></div>
          <div><span>53 TCP/UDP</span><b class="<?= (!empty($status['listen_53_udp'])&&!empty($status['listen_53_tcp']))?'hh-ok':'hh-warn' ?>"><?= (!empty($status['listen_53_udp'])&&!empty($status['listen_53_tcp']))?'открыт':'проверить' ?></b></div>
          <div><span>Делегация</span><b class="<?= $delegated?'hh-ok':'hh-warn' ?>"><?= $delegated?'на панели':'у регистратора' ?></b></div>
        </div>
        <div class="dns-transfer-box mb-3">
          <div><span>Поставить NS у регистратора</span><code>ns1.<?= e($z['domain']) ?></code><code>ns2.<?= e($z['domain']) ?></code></div>
          <div><span>Glue / Child NS IP</span><code><?= e((string)($status['public_ip'] ?? $pub)) ?></code></div>
          <div><span>Сейчас публичные NS</span><code><?= e($currentNs ? implode(', ', $currentNs) : 'не найдено') ?></code></div>
          <div><span>Регистратор</span><code><?= e((string)($info['registrar'] ?? 'не определён')) ?></code></div>
        </div>
        <?php if(!empty($status['problem'])): ?><div class="alert alert-warning py-2 mb-3"><?= e((string)$status['problem']) ?></div><?php endif; ?>
        <form method="post" class="dns-record-form mb-3"><?= csrf_field() ?><input type="hidden" name="action" value="add_dns_record"><input type="hidden" name="zone_id" value="<?= (int)$z['id'] ?>"><select class="form-select" name="type"><option>A</option><option>AAAA</option><option>CNAME</option><option>MX</option><option>TXT</option><option>NS</option><option>CAA</option></select><input class="form-control" name="name" value="@"><input class="form-control" name="value" placeholder="IP / значение"><input class="form-control" name="ttl" value="300"><button class="btn btn-primary">+</button></form>
        <div class="table-responsive"><table class="table table-dark-soft align-middle"><thead><tr><th>Тип</th><th>Имя</th><th>Значение</th><th>TTL</th><th></th></tr></thead><tbody><?php foreach($recs as $r): ?><tr><td><span class="badge text-bg-secondary"><?= e($r['type']) ?></span></td><td><?= e($r['name']) ?></td><td><code><?= e($r['value']) ?></code></td><td><?= (int)$r['ttl'] ?></td><td class="text-end"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="delete_dns_record"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-outline-danger">x</button></form></td></tr><?php endforeach; if(!$recs): ?><tr><td colspan="5" class="empty">Записей пока нет</td></tr><?php endif; ?></tbody></table></div>
      </div>
      <?php endforeach; if(!$zones): ?><div class="panel-card empty">DNS зон пока нет</div><?php endif; ?>
    </div>
    <div class="col-xxl-5">
      <div class="panel-card dns-inspector-card">
        <h2><i class="fa-solid fa-magnifying-glass-location me-2"></i>Проверка домена</h2>
        <form method="get" class="dns-inspect-form mb-3"><input type="hidden" name="page" value="dns"><input class="form-control" name="inspect" value="<?= e($inspectDomain) ?>" placeholder="mystockbot.xyz"><button class="btn btn-soft">Проверить</button></form>
        <?php if($inspect && empty($inspect['_error'])): ?>
        <div class="dns-compact-grid inspector-grid">
          <div><span>Домен</span><b><?= e((string)$inspect['domain']) ?></b></div>
          <div><span>Регистратор</span><b><?= e((string)($inspect['registrar'] ?: 'не определён')) ?></b></div>
          <div><span>NS</span><b><?= e(implode(', ', $inspect['public_ns'] ?? []) ?: 'нет') ?></b></div>
          <div><span>A</span><b><?= e(implode(', ', $inspect['public_a'] ?? []) ?: 'нет') ?></b></div>
          <div><span>Где хостится</span><b><?= e((string)($inspect['hosting_guess'] ?: 'не определено')) ?></b></div>
          <div><span>Статус</span><b class="<?= (($inspect['delegation_status']??'')==='on_hyper_host')?'hh-ok':'hh-warn' ?>"><?= e((string)($inspect['delegation_label'] ?? 'проверить')) ?></b></div>
        </div>
        <?php if(!empty($inspect['expiry_date']) || !empty($inspect['creation_date'])): ?><div class="dns-mini-note mt-3"><b>WHOIS</b><span>Создан: <?= e((string)($inspect['creation_date'] ?: '—')) ?> · Истекает: <?= e((string)($inspect['expiry_date'] ?: '—')) ?></span></div><?php endif; ?>
        <?php else: ?><div class="empty">Выбери домен для проверки</div><?php endif; ?>
      </div>
    </div>
  </div>
</div><?php }

function view_network(): void {
    $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll();
    $domain=(string)($_GET['domain']??($sites[0]['domain']??'hyper-host.pw'));
    $pub=setting_get('public_ip_override',(string)app_config('public_ip','90.189.208.25'));
    $doctor=run_ctl_json_cached(['network-doctor-json',$domain],8,180);
?>
<div class="row g-4 network-page-v40">
  <div class="col-xxl-4"><div class="panel-card hero-mini"><div class="kicker"><i class="fa-solid fa-tower-broadcast me-2"></i>Сеть</div><h2>Доступ и домен</h2>
    <form method="post" class="vstack gap-3 mt-3"><?= csrf_field() ?><input type="hidden" name="action" value="network_fix"><input class="form-control" name="domain" value="<?= e($domain) ?>" placeholder="mystockbot.xyz"><input class="form-control" name="public_ip" value="<?= e($pub) ?>" placeholder="90.189.208.25"><button class="btn btn-primary btn-lg"><i class="fa-solid fa-screwdriver-wrench me-2"></i>Исправить</button></form>
    <form method="post" class="vstack gap-2 mt-4"><?= csrf_field() ?><input type="hidden" name="action" value="save_panel_domain"><label class="form-label">Домен панели</label><input class="form-control" name="panel_domain" value="<?= e(setting_get('panel_domain_override', (string)app_config('panel_domain', ''))) ?>" placeholder="panel.hyper-host.pw"><button class="btn btn-soft"><i class="fa-solid fa-link me-2"></i>Сохранить</button></form>
  </div></div>
  <div class="col-xxl-8"><div class="panel-card"><h2>Диагностика</h2>
    <div class="network-check-grid network-check-grid-v40">
      <div class="network-check"><span>Публичный IP</span><b><?= e((string)($doctor['public_ip'] ?? $pub)) ?></b></div>
      <div class="network-check"><span>DNS A</span><b class="<?= (($doctor['dns_status']??'')==='ok')?'hh-ok':'hh-warn' ?>"><?= e(implode(', ', $doctor['dns_a'] ?? [])) ?: 'нет' ?></b></div>
      <div class="network-check"><span>Локальный DNS</span><b><?= e(implode(', ', $doctor['dns_a_local'] ?? [])) ?: 'нет' ?></b></div>
      <div class="network-check"><span>Nginx</span><b class="<?= !empty($doctor['nginx_ok'])?'hh-ok':'hh-bad' ?>"><?= !empty($doctor['nginx_ok'])?'ok':'bad' ?></b></div>
      <div class="network-check"><span>80</span><b class="<?= !empty($doctor['listen_80'])?'hh-ok':'hh-bad' ?>"><?= !empty($doctor['listen_80'])?'слушает':'нет' ?></b></div>
      <div class="network-check"><span>443</span><b class="<?= !empty($doctor['listen_443'])?'hh-ok':'hh-bad' ?>"><?= !empty($doctor['listen_443'])?'слушает':'нет' ?></b></div>
      <div class="network-check"><span>ACME</span><b class="<?= !empty($doctor['local_acme_ok'])?'hh-ok':'hh-warn' ?>"><?= !empty($doctor['local_acme_ok'])?'ok':'fix' ?></b></div>
      <div class="network-check"><span>DNS 53</span><b class="<?= !empty($doctor['listen_dns_53'])?'hh-ok':'hh-warn' ?>"><?= !empty($doctor['listen_dns_53'])?'слушает':'проверить' ?></b></div>
    </div>
    <?php if(!empty($doctor['problem'])): ?><div class="alert alert-warning mt-3 mb-0"><?= e((string)$doctor['problem']) ?></div><?php endif; ?>
  </div></div>
</div><?php }

function view_ssl(): void {
    $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll();
    $audit=run_ctl_json_cached(['ssl-audit-json'],20,60); $map=[]; if(!empty($audit['ok'])) foreach(($audit['sites']??[]) as $c) $map[$c['domain']]=$c;
    $savedPublicIp = setting_get('public_ip_override', (string)app_config('public_ip',''));
    $savedSslEmail = setting_get('ssl_email','');
    $modals = [];
?>
<div class="ssl-hero mb-4">
  <div>
    <div class="eyebrow"><i class="fa-solid fa-shield-halved"></i> Let's Encrypt</div>
    <h2>SSL сертификаты</h2>
  </div>
  <div class="ssl-hero-actions">
    <form method="post" class="d-flex gap-2 flex-wrap">
      <?= csrf_field() ?><input type="hidden" name="action" value="save_public_ip">
      <input class="form-control public-ip-input" name="public_ip" value="<?= e($savedPublicIp) ?>" placeholder="90.189.208.25">
      <button class="btn btn-soft"><i class="fa-solid fa-floppy-disk me-2"></i>IP</button>
    </form>
    <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="ssl_restore_existing"><button class="btn btn-soft"><i class="fa-solid fa-screwdriver-wrench me-2"></i>Восстановить SSL на всех доменах</button></form><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="ssl_renew_all"><button class="btn btn-primary"><i class="fa-solid fa-arrows-rotate me-2"></i>Автопродление</button></form>
  </div>
</div>
<div class="ssl-any-card-v92 mb-4">
  <div class="eyebrow"><i class="fa-solid fa-globe"></i> Любой домен</div>
  <h2 class="mb-2">SSL на www и поддомены</h2>
  <p class="muted mb-0">Впиши полный хост — например <code>www.pixel-pc.store</code>. Панель привяжет его к нужному сайту, пересоберёт Nginx и выпустит <b>один</b> сертификат сразу на домен и все его имена.</p>
  <div class="ssl-any-grid-v92">
    <form method="post" class="ssl-any-form-v92" data-ssl-submit data-ssl-any data-domain="">
      <?= csrf_field() ?><input type="hidden" name="action" value="ssl_any">
      <input class="form-control form-control-lg" name="host" placeholder="www.pixel-pc.store" autocomplete="off" spellcheck="false" required data-ssl-host>
      <input class="form-control form-control-lg" name="email" type="email" value="<?= e($savedSslEmail) ?>" placeholder="email@example.com" autocomplete="email" spellcheck="false" required data-ssl-email>
      <div class="ssl-any-actions-v92">
        <button type="button" class="btn btn-soft" data-ssl-check><i class="fa-solid fa-stethoscope me-2"></i>Проверить домен</button>
        <button class="btn btn-primary btn-lg" type="submit" data-ssl-button><i class="fa-solid fa-bolt me-2"></i><span>Выпустить SSL</span></button>
      </div>
      <div class="ssl-job-panel" data-ssl-job-panel hidden>
        <div class="ssl-job-head"><span class="ssl-job-icon"><i class="fa-solid fa-rotate fa-spin"></i></span><div><b data-ssl-job-title>Запускаю выпуск SSL</b><span data-ssl-job-message>Задание создаётся на сервере…</span></div></div>
        <div class="ssl-job-progress"><i data-ssl-job-progress></i></div>
        <pre class="ssl-job-error" data-ssl-job-error hidden></pre>
      </div>
    </form>
    <div class="ssl-any-report-v92" data-ssl-report>
      <div class="placeholder">Нажми «Проверить домен» — покажу A и AAAA записи, к какому сайту привязан хост, отдаётся ли ACME challenge и есть ли уже живой сертификат.</div>
    </div>
  </div>
</div>
<div class="panel-card ssl-card">
  <div class="table-responsive"><table class="table table-dark-soft align-middle mb-0"><thead><tr><th>Сайт</th><th>Проверка</th><th>Сертификат</th><th class="text-end">Действия</th></tr></thead><tbody>
  <?php foreach($sites as $s):
      $c=$map[$s['domain']]??null;
      $dns=run_ctl_json_cached(['ssl-check-json',$s['domain']],8,300);
      $hasCert = $c && (($c['status'] ?? '') === 'active');
      $partial = $c && (($c['status'] ?? '') === 'partial');
      $certOnly = $c && (($c['status'] ?? '') === 'cert_only');
      $ready=empty($dns['_error']) && !empty($dns['certbot_ready']);
      $points=empty($dns['_error']) && !empty($dns['points_here']);
      if($hasCert){ $badge='success'; $label='SSL реально работает'; }
      elseif($partial){ $badge='warning'; $label='SSL частично: проверь aliases'; }
      elseif($certOnly){ $badge='warning'; $label='Сертификат есть, Nginx не отдаёт'; }
      elseif($ready){ $badge='success'; $label='Можно выпускать'; }
      elseif($points){ $badge='info'; $label='DNS OK'; }
      else { $badge='warning'; $label='Нужна настройка'; }
      ob_start(); ?>
      <div class="modal fade ssl-modal" id="ssl<?= (int)$s['id'] ?>" tabindex="-1" aria-hidden="true" data-bs-backdrop="static" data-bs-keyboard="false">
        <div class="modal-dialog modal-dialog-centered modal-lg"><div class="modal-content"><form method="post" data-ssl-submit data-domain="<?= e($s['domain']) ?>">
          <?= csrf_field() ?><input type="hidden" name="action" value="ssl_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>">
          <div class="modal-header"><div><div class="eyebrow mb-1"><i class="fa-solid fa-certificate"></i> SSL выпуск</div><h5 class="modal-title mb-0"><?= e($s['domain']) ?></h5></div><button class="btn-close" data-bs-dismiss="modal" type="button" aria-label="Закрыть"></button></div>
          <div class="modal-body">
            <div class="ssl-ready-box <?= $ready ? 'ok' : 'warn' ?>">
              <i class="fa-solid <?= $ready ? 'fa-circle-check' : 'fa-triangle-exclamation' ?>"></i>
              <div><b><?= $ready ? 'Проверка пройдена' : 'Перед выпуском есть предупреждение' ?></b><span><?= $ready ? 'DNS и ACME challenge готовы. Можно выпускать сертификат.' : e((string)($dns['problem'] ?? 'Проверь DNS/ACME и попробуй ещё раз.')) ?></span></div>
            </div>
            <label class="form-label mt-3">Email для Let’s Encrypt</label>
            <input class="form-control form-control-lg" name="email" type="email" value="<?= e($savedSslEmail) ?>" placeholder="email@example.com" autocomplete="email" spellcheck="false" required data-ssl-email>
            <div class="ssl-cli-v79" data-ssl-cli-box>
              <div class="ssl-cli-head-v79"><div><i class="fa-solid fa-terminal"></i><b>Команды для выпуска через SSH</b></div><span>Нажми на команду — она скопируется</span></div>
              <div class="ssl-cli-grid-v79">
                <button type="button" class="cmd-copy ssl-cli-command-v79" data-ssl-command-template="sudo hyper ssl check {domain}"><i class="fa-solid fa-stethoscope"></i><code></code></button>
                <button type="button" class="cmd-copy ssl-cli-command-v79" data-ssl-command-template="sudo hyper ssl fix {domain}"><i class="fa-solid fa-wand-magic-sparkles"></i><code></code></button>
                <button type="button" class="cmd-copy ssl-cli-command-v79 primary" data-ssl-command-template="sudo hyper ssl issue {domain} {email}"><i class="fa-solid fa-certificate"></i><code></code></button>
                <button type="button" class="cmd-copy ssl-cli-command-v79" data-ssl-command-template="sudo certbot --config-dir /opt/hyper-host/letsencrypt --work-dir /opt/hyper-host/certbot-work --logs-dir /opt/hyper-host/certbot-logs certonly --webroot -w /opt/hyper-host/acme-webroot --non-interactive --agree-tos --email {email} --no-eff-email --preferred-challenges http-01 --cert-name {domain} -d {domain} && sudo /usr/local/sbin/hyper-host-nginx-reconcile && sudo nginx -t && sudo systemctl reload nginx"><i class="fa-solid fa-screwdriver-wrench"></i><code></code></button>
              </div>
            </div>
            <div class="ssl-job-panel" data-ssl-job-panel hidden>
              <div class="ssl-job-head"><span class="ssl-job-icon"><i class="fa-solid fa-rotate fa-spin"></i></span><div><b data-ssl-job-title>Запускаю выпуск SSL</b><span data-ssl-job-message>Задание создаётся на сервере…</span></div></div>
              <div class="ssl-job-progress"><i data-ssl-job-progress></i></div>
              <pre class="ssl-job-error" data-ssl-job-error hidden></pre>
            </div>
          </div>
          <div class="modal-footer"><button type="button" class="btn btn-soft" data-bs-dismiss="modal" data-ssl-cancel>Отмена</button><button class="btn btn-primary btn-lg" type="submit" data-ssl-button><i class="fa-solid fa-bolt"></i><span>Выпустить SSL</span></button></div>
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
      <td><?= $hasCert?'<span class="badge rounded-pill text-bg-success">'.e((string)($c['certificate']['days_left']??'?')).' дней</span>':($partial?'<span class="badge rounded-pill text-bg-warning">не все домены защищены</span>':($certOnly?'<span class="badge rounded-pill text-bg-warning">найден, не подключён</span>':'<span class="badge rounded-pill text-bg-secondary">нет SSL</span>')) ?><div class="small muted"><?= e((string)($c['certificate']['expires']??'')) ?></div></td>
      <td class="text-end"><div class="d-inline-flex gap-2 flex-wrap justify-content-end"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="ssl_fix_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><button class="btn btn-sm btn-outline-info"><i class="fa-solid fa-wand-magic-sparkles me-1"></i>Fix ACME</button></form><button class="btn btn-sm btn-primary" data-bs-toggle="modal" data-bs-target="#ssl<?= (int)$s['id'] ?>"><i class="fa-solid fa-certificate me-1"></i><?= $hasCert?'Перевыпустить':'Выпустить' ?></button></div></td>
    </tr>
  <?php endforeach; if(!$sites): ?><tr><td colspan="4" class="empty">Сайтов пока нет</td></tr><?php endif; ?>
  </tbody></table></div>
</div>
<?= implode("\n", $modals) ?>
<div class="row g-4 mt-1">
  <div class="col-lg-6">
    <div class="panel-card h-100">
      <h2><i class="fa-solid fa-gauge-high me-2"></i>SSL для панели</h2>
      <p class="muted">Домен <code>panel.hyper-host.pw</code> должен открывать именно панель, а не обычный сайт.</p>
      <div class="cmd-stack">
        <button type="button" class="cmd-copy" onclick="copyText('sudo hyper panel domain panel.hyper-host.pw')"><i class="fa-solid fa-copy"></i><code>sudo hyper panel domain panel.hyper-host.pw</code></button>
        <button type="button" class="cmd-copy" onclick="copyText('sudo hyper ssl panel panel.hyper-host.pw memes4u1337@mail.ru')"><i class="fa-solid fa-copy"></i><code>sudo hyper ssl panel panel.hyper-host.pw memes4u1337@mail.ru</code></button>
      </div>
    </div>
  </div>
  <div class="col-lg-6">
    <div class="panel-card h-100">
      <h2><i class="fa-solid fa-network-wired me-2"></i>SSL на внутренний IP</h2>
      <p class="muted">Для IP нельзя получить обычный зелёный Let’s Encrypt. Панель поставит локальный self-signed SSL на <code>192.168.0.179</code>.</p>
      <div class="cmd-stack">
        <button type="button" class="cmd-copy" onclick="copyText('sudo hyper ssl ip 192.168.0.179')"><i class="fa-solid fa-copy"></i><code>sudo hyper ssl ip 192.168.0.179</code></button>
      </div>
    </div>
  </div>
</div>
<?php }

function view_php(): void { $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll(); $versions=run_ctl_json_cached(['php-list-json'],10,120); ?>
<div class="panel-card"><div class="card-title-row flex-wrap"><div><h2>PHP-версии по сайтам</h2><p class="muted mb-0">Выбери версию отдельно для каждого домена.</p></div><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="php_versions_install"><button class="btn btn-soft"><i class="fa-solid fa-download me-2"></i>Установить PHP 8.1 / 8.2 / 8.3 / 8.4</button></form></div><div class="service-row mt-3 mb-3"><?php foreach(($versions['_error']??null)?[]:$versions as $v): ?><span class="badge rounded-pill text-bg-info">PHP <?= e($v['version']) ?></span><?php endforeach; ?></div><div class="table-responsive"><table class="table table-dark-soft align-middle"><tbody><?php foreach($sites as $s): ?><tr><td><b><?= e($s['domain']) ?></b><div class="small muted">сейчас: PHP <?= e($s['php_version']?:'default') ?></div></td><td><form method="post" class="d-flex gap-2"><?= csrf_field() ?><input type="hidden" name="action" value="set_site_php"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><select class="form-select" name="php_version"><?php foreach(($versions['_error']??null)?[]:$versions as $v): ?><option value="<?= e($v['version']) ?>" <?= ($s['php_version']??'')===$v['version']?'selected':'' ?>>PHP <?= e($v['version']) ?></option><?php endforeach; ?></select><button class="btn btn-primary">Сохранить</button></form></td></tr><?php endforeach; if(!$sites): ?><tr><td class="empty">Сайтов пока нет</td></tr><?php endif; ?></tbody></table></div></div><?php }

function view_cron(): void { $rows=db()->query('SELECT * FROM cron_tasks ORDER BY id DESC')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-4"><div class="panel-card"><h2>Новая cron-задача</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_cron"><input class="form-control" name="name" placeholder="clear_cache" required><input class="form-control" name="schedule" value="*/10 * * * *" required><input class="form-control" name="command" placeholder="php /var/www/site/artisan schedule:run" required><button class="btn btn-primary">Сохранить</button></form></div></div><div class="col-lg-8"><div class="panel-card"><h2>Cron задачи</h2><div class="table-responsive"><table class="table table-dark-soft"><?php foreach($rows as $r): ?><tr><td><b><?= e($r['name']) ?></b></td><td><code><?= e($r['schedule']) ?></code></td><td><code><?= e($r['command']) ?></code></td><td><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="delete_cron"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$rows): ?><tr><td class="empty">Cron-задач пока нет</td></tr><?php endif; ?></table></div></div></div></div><?php }

function view_logs(): void { $sites=db()->query('SELECT * FROM sites ORDER BY domain')->fetchAll(); $domain=(string)($_GET['domain']??($sites[0]['domain']??'')); $kind=(string)($_GET['kind']??'error'); $filter=(string)($_GET['filter']??''); $out=''; if($domain) $out=run_ctl(['site-logs',$domain,$kind,'250',$filter],30)['output']; ?>
<div class="panel-card"><h2>Логи сайтов</h2><form method="get" class="row g-2 mb-3"><input type="hidden" name="page" value="logs"><div class="col-md-3"><select class="form-select" name="domain"><?php foreach($sites as $s): ?><option value="<?= e($s['domain']) ?>" <?= $domain===$s['domain']?'selected':'' ?>><?= e($s['domain']) ?></option><?php endforeach; ?></select></div><div class="col-md-2"><select class="form-select" name="kind"><option value="error" <?= $kind==='error'?'selected':'' ?>>error</option><option value="access" <?= $kind==='access'?'selected':'' ?>>access</option></select></div><div class="col-md-5"><input class="form-control" name="filter" value="<?= e($filter) ?>" placeholder="фильтр ошибок"></div><div class="col-md-2"><button class="btn btn-primary w-100">Показать</button></div></form><pre class="logs"><?= e($out?:'Логов пока нет') ?></pre></div><?php }

function view_security(): void { $secret=setting_get('security_2fa_secret',''); if($secret===''){ $secret=base32_random(); setting_set('security_2fa_secret',$secret); } $enabled=setting_get('security_2fa_enabled','0'); $issuer='HYPER-HOST'; $account='admin@'.host_name(); $uri='otpauth://totp/'.rawurlencode($issuer.':'.$account).'?secret='.$secret.'&issuer='.rawurlencode($issuer); $logs=db()->query('SELECT * FROM auth_logs ORDER BY id DESC LIMIT 30')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-5"><div class="panel-card"><h2>2FA и IP allowlist</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="save_security"><label class="form-check"><input class="form-check-input" type="checkbox" name="enable_2fa" value="1" <?= $enabled==='1'?'checked':'' ?>> <span class="form-check-label">Включить 2FA</span></label><div><label class="form-label">2FA secret</label><input class="form-control" value="<?= e($secret) ?>" readonly><textarea class="form-control mt-2" rows="3" readonly><?= e($uri) ?></textarea></div><div><label class="form-label">IP allowlist</label><textarea class="form-control" name="ip_allowlist" rows="5" placeholder="Один IP на строку. Пусто = все IP разрешены."><?= e(setting_get('security_ip_allowlist','')) ?></textarea></div><button class="btn btn-primary">Сохранить</button></form><form method="post" class="mt-2"><?= csrf_field() ?><input type="hidden" name="action" value="reset_2fa_secret"><button class="btn btn-soft">Сбросить 2FA secret</button></form></div></div><div class="col-lg-7"><div class="panel-card"><h2>Журнал входов</h2><div class="table-responsive"><table class="table table-dark-soft"><thead><tr><th>Время</th><th>Логин</th><th>IP</th><th>Статус</th></tr></thead><tbody><?php foreach($logs as $l): ?><tr><td><?= e($l['created_at']) ?></td><td><?= e($l['username']) ?></td><td><?= e($l['ip']) ?></td><td><?= e($l['status']) ?></td></tr><?php endforeach; ?></tbody></table></div></div></div></div><?php }


function view_access(): void
{
    $j=run_ctl_json_cached(['access-doctor-json'],3,90);
    $pub=(string)($j['public_ip']??'');
    $server=(string)($j['server_ip']??host_name());
    $ports=$j['listen_ports']??[];
    $forwarding=$j['router_forwarding_needed']??[];
    $ufw=(string)($j['ufw_status']??'unknown');
    $openCount=0; $totalPorts=0;
    foreach($ports as $ok){ $totalPorts++; if($ok) $openCount++; }
    ?>
<div class="access-page-v94">

  <section class="access-hero-v94">
    <div>
      <div class="eyebrow"><i class="fa-solid fa-plug-circle-bolt"></i> Внешний доступ</div>
      <h2>Доступ снаружи</h2>
      <p>Панель открывает нужные порты на самом Ubuntu (UFW + nginx + FTP). Проброс на роутере
         остаётся ручным шагом — правила для него перечислены ниже.</p>
    </div>
    <div class="access-actions-v94">
      <form method="post" data-async-submit>
        <?= csrf_field() ?><input type="hidden" name="action" value="access_fix">
        <button class="btn btn-primary btn-lg" data-loading-text="Открываю порты...">
          <i class="fa-solid fa-wand-magic-sparkles me-2"></i>Открыть порты на сервере
        </button>
      </form>
    </div>
  </section>

  <div class="access-grid-v94">

    <section class="panel-card">
      <h2 class="mb-3"><i class="fa-solid fa-server me-2"></i>Состояние сервера</h2>
      <div class="access-stat-grid-v94">
        <div class="access-stat-v94"><span>Локальный IP</span><b><?= e($server ?: '—') ?></b></div>
        <div class="access-stat-v94"><span>Публичный IP</span><b><?= e($pub ?: 'не задан') ?></b></div>
        <div class="access-stat-v94"><span>UFW</span><b class="<?= $ufw==='active'?'hh-ok':'hh-warn' ?>"><?= e($ufw) ?></b></div>
        <div class="access-stat-v94"><span>Порты открыты</span><b><?= (int)$openCount ?> / <?= (int)$totalPorts ?></b></div>
      </div>

      <h2 class="mt-4 mb-3"><i class="fa-solid fa-shield-halved me-2"></i>Порты Ubuntu</h2>
      <?php if($ports): ?>
        <div class="access-ports-v94">
          <?php foreach($ports as $name=>$ok): ?>
            <span class="access-port-v94 <?= $ok?'is-open':'is-closed' ?>">
              <i class="fa-solid fa-circle"></i><?= e((string)$name) ?> · <?= $ok?'открыт':'закрыт' ?>
            </span>
          <?php endforeach; ?>
        </div>
      <?php else: ?>
        <div class="access-empty-v94">Данные о портах пока не получены</div>
      <?php endif; ?>

      <?php if($openCount < $totalPorts): ?>
        <div class="access-note-v94">
          <i class="fa-solid fa-triangle-exclamation me-2"></i>
          Часть портов закрыта. Нажми «Открыть порты на сервере» — панель починит UFW и правила nginx/FTP.
        </div>
      <?php endif; ?>
    </section>

    <section class="panel-card">
      <h2 class="mb-3"><i class="fa-solid fa-router me-2"></i>Проброс на роутере</h2>
      <p class="muted mb-3">Эти правила нужно один раз добавить в роутере вручную — сервер сделать это за тебя не может.</p>
      <?php if($forwarding): ?>
        <div class="access-fwd-v94">
          <?php foreach($forwarding as $r): ?>
            <div class="access-fwd-row-v94">
              <b><?= e((string)($r['service']??'')) ?></b>
              <code data-copy="<?= e((string)($r['rule']??'')) ?>" title="Нажми, чтобы скопировать"><?= e((string)($r['rule']??'')) ?></code>
            </div>
          <?php endforeach; ?>
        </div>
      <?php else: ?>
        <div class="access-empty-v94">Дополнительный проброс не требуется</div>
      <?php endif; ?>

      <div class="access-note-v94">
        <i class="fa-solid fa-circle-info me-2"></i>
        Если сайт открывается внутри сети, но не снаружи — почти всегда дело именно в этих правилах
        роутера или в том, что провайдер выдаёт серый IP.
      </div>
    </section>

  </div>
</div>
<?php }

function view_disk(): void
{ $j=run_ctl_json_cached(['disk-doctor-json'],3,90); ?>
<div class="row g-4"><div class="col-xl-5"><div class="panel-card"><h2><i class="fa-solid fa-hard-drive me-2"></i>Диск и LVM</h2><div class="network-check-grid mb-3"><div class="network-check"><span>Root</span><b><?= e((string)($j['root_total']??'')) ?></b></div><div class="network-check"><span>Свободно</span><b><?= e((string)($j['root_free']??'')) ?></b></div><div class="network-check"><span>VG</span><b><?= e((string)($j['root_vg']??'—')) ?></b></div></div><form method="post" onsubmit="return confirm('Расширить root LVM на всё свободное место диска?')"><?= csrf_field() ?><input type="hidden" name="action" value="disk_expand"><button class="btn btn-primary btn-lg w-100"><i class="fa-solid fa-up-right-and-down-left-from-center me-2"></i>Расширить диск автоматически</button></form><div class="mt-3 vstack gap-2"><button class="cmd-copy" type="button" data-copy="sudo hyper disk doctor"><i class="fa-regular fa-copy"></i><code>sudo hyper disk doctor</code></button><button class="cmd-copy" type="button" data-copy="sudo hyper disk expand"><i class="fa-regular fa-copy"></i><code>sudo hyper disk expand</code></button></div></div></div><div class="col-xl-7"><div class="panel-card"><h2>Диагностика</h2><pre class="logs"><?= e(json_encode($j, JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT)) ?></pre></div></div></div><?php }

function view_settings(): void { $dbStatus=db_writable_status(); ?>
<div class="row g-4"><div class="col-lg-6"><div class="panel-card"><h2>Ремонт панели</h2><form method="post" class="d-inline"><?= csrf_field() ?><input type="hidden" name="action" value="repair_panel"><button class="btn btn-primary">Починить права и сервисы</button></form><form method="post" class="d-inline ms-2"><?= csrf_field() ?><input type="hidden" name="action" value="sync_resources"><button class="btn btn-soft">Синхронизировать</button></form><hr><form method="post" class="row g-2"><?= csrf_field() ?><input type="hidden" name="action" value="save_public_ip"><div class="col-8"><input class="form-control" name="public_ip" value="<?= e(setting_get('public_ip_override', (string)app_config('public_ip',''))) ?>" placeholder="Публичный IP"></div><div class="col-4"><button class="btn btn-soft w-100">Сохранить IP</button></div></form></div></div><div class="col-lg-6"><div class="panel-card"><h2>Сменить пароль</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="change_password"><input class="form-control" type="password" name="current_password" placeholder="Текущий пароль" required><input class="form-control" type="password" name="new_password" placeholder="Новый пароль" minlength="10" required><button class="btn btn-primary">Сменить пароль</button></form></div></div><div class="col-12"><div class="panel-card"><h2>Системные пути</h2><div class="hardware-grid"><div><span>SQLite</span><b><?= e($dbStatus['file_writable']?'writable':'not writable') ?></b></div><div><span>Панель</span><b><?= e((string)app_config('panel_dir')) ?></b></div><div><span>Сайты</span><b><?= e((string)app_config('sites_dir')) ?></b></div><div><span>FTP</span><b><?= e((string)app_config('ftp_dir','/var/www/hyper-host-ftp')) ?></b></div><div><span>Боты</span><b><?= e((string)app_config('bots_dir')) ?></b></div></div></div></div></div><?php }


/* ============================================================================
   HYPER-HOST v94 — управление клиентами портала cp.hyper-host.pw
   powered by memes4u1337

   Панель работает с базой портала напрямую (общая группа hypercp), а всё
   привилегированное — создание/удаление аккаунтов, остановка ботов, перевыдача
   лимитов CPU/RAM — делает через тот же root-мост, что и сам портал.
   ========================================================================== */

function cp_admin_db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) return $pdo;
    $path = '/var/lib/hyper-host-cp/cp.sqlite';
    if (!is_file($path)) throw new RuntimeException('Клиентский портал не установлен. Запусти: sudo bash install-cp.sh');
    $pdo = new PDO('sqlite:' . $path);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
    $pdo->exec('PRAGMA busy_timeout=10000');
    return $pdo;
}

function cp_admin_bridge(array $payload, int $timeout = 180): array
{
    $bin = '/usr/local/sbin/hyper-cp-bridge';
    if (!is_executable($bin)) return ['ok' => false, 'error' => 'Мост портала не установлен'];
    $spec = [0 => ['pipe','r'], 1 => ['pipe','w'], 2 => ['pipe','w']];
    $proc = @proc_open(['/usr/bin/sudo','-n',$bin], $spec, $pipes, null, ['PATH' => '/usr/sbin:/usr/bin:/sbin:/bin']);
    if (!is_resource($proc)) return ['ok' => false, 'error' => 'Не удалось запустить мост портала'];
    fwrite($pipes[0], json_encode($payload, JSON_UNESCAPED_UNICODE));
    fclose($pipes[0]);
    $out = ''; $start = time();
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);
    while (true) {
        $out .= (string)stream_get_contents($pipes[1]);
        stream_get_contents($pipes[2]);
        $st = proc_get_status($proc);
        if (!$st['running']) break;
        if (time() - $start > $timeout) { proc_terminate($proc, 9); break; }
        usleep(80000);
    }
    $out .= (string)stream_get_contents($pipes[1]);
    fclose($pipes[1]); fclose($pipes[2]); proc_close($proc);
    $data = json_decode(trim($out), true);
    return is_array($data) ? $data : ['ok' => false, 'error' => 'Некорректный ответ моста'];
}

function cp_admin_user(int $id): array
{
    $st = cp_admin_db()->prepare('SELECT * FROM cp_users WHERE id=?');
    $st->execute([$id]);
    $u = $st->fetch();
    if (!is_array($u)) throw new RuntimeException('Клиент не найден');
    return $u;
}

function cp_admin_grant(int $uid, int $sites, int $bots, int $cpu, int $mem, int $disk): void
{
    $u = cp_admin_user($uid);
    $db = cp_admin_db();
    $db->prepare("INSERT INTO cp_quotas(user_id,max_sites,max_bots,cpu_percent,memory_mb,disk_mb,updated_at)
                  VALUES(?,?,?,?,?,?,datetime('now','localtime'))
                  ON CONFLICT(user_id) DO UPDATE SET max_sites=excluded.max_sites,max_bots=excluded.max_bots,
                  cpu_percent=excluded.cpu_percent,memory_mb=excluded.memory_mb,disk_mb=excluded.disk_mb,
                  updated_at=excluded.updated_at")
       ->execute([$uid, $sites, $bots, $cpu, $mem, $disk]);

    if ((string)$u['status'] === 'pending' && ($sites + $bots) > 0) {
        $db->prepare("UPDATE cp_users SET status='active' WHERE id=?")->execute([$uid]);
    }

    // Лимиты — не цифра в интерфейсе: юниты ботов переписываются и перезапускаются,
    // чтобы CPUQuota/MemoryMax реально соответствовали выданному.
    $slots = max(1, $bots);
    $st = $db->prepare('SELECT name, runtime FROM cp_bots WHERE user_id=?');
    $st->execute([$uid]);
    $list = [];
    foreach ($st->fetchAll() as $b) {
        $list[] = ['name' => (string)$b['name'], 'runtime' => (string)$b['runtime'],
                   'cpu_percent' => intdiv($cpu, $slots), 'memory_mb' => intdiv($mem, $slots)];
    }
    if ($list) {
        cp_admin_bridge(['action' => 'bot-limits', 'user' => (string)$u['username'], 'bots' => $list], 180);
        $db->prepare('UPDATE cp_bots SET cpu_percent=?, memory_mb=? WHERE user_id=?')
           ->execute([intdiv($cpu, $slots), intdiv($mem, $slots), $uid]);
    }

    $db->prepare("INSERT INTO cp_events(user_id,type,message,created_at) VALUES(?,'admin',?,datetime('now','localtime'))")
       ->execute([$uid, "Администратор выдал ресурсы: сайтов $sites, ботов $bots, CPU $cpu%, RAM $mem MB, диск $disk MB"]);
    add_event('clients', 'Выданы ресурсы клиенту ' . $u['username']);
}

function cp_admin_status(int $uid, string $status): void
{
    if (!in_array($status, ['active','suspended'], true)) throw new RuntimeException('Некорректный статус');
    $u = cp_admin_user($uid);
    $r = cp_admin_bridge(['action' => 'user-set-status', 'user' => (string)$u['username'], 'status' => $status], 120);
    if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Не удалось изменить статус'));
    cp_admin_db()->prepare('UPDATE cp_users SET status=? WHERE id=?')->execute([$status, $uid]);
    add_event('clients', 'Клиент ' . $u['username'] . ': ' . $status);
}

function cp_admin_delete(int $uid): void
{
    $u = cp_admin_user($uid);
    $r = cp_admin_bridge(['action' => 'user-delete', 'user' => (string)$u['username']], 300);
    if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Не удалось удалить клиента'));
    $db = cp_admin_db();
    foreach (['cp_sites','cp_bots','cp_events','cp_quotas'] as $t) {
        $db->prepare("DELETE FROM {$t} WHERE user_id=?")->execute([$uid]);
    }
    $db->prepare('DELETE FROM cp_users WHERE id=?')->execute([$uid]);
    add_event('clients', 'Удалён клиент ' . $u['username']);
}

function view_clients(): void
{
    try {
        $db = cp_admin_db();
    } catch (Throwable $e) {
        ?>
<div class="panel-card">
  <h2><i class="fa-solid fa-users me-2"></i>Клиенты портала</h2>
  <div class="alert alert-warning mb-0"><?= e($e->getMessage()) ?></div>
</div>
<?php   return;
    }

    $users = $db->query('SELECT * FROM cp_users ORDER BY (status="pending") DESC, id DESC')->fetchAll();
    $quotas = [];
    foreach ($db->query('SELECT * FROM cp_quotas')->fetchAll() as $q) $quotas[(int)$q['user_id']] = $q;
    $siteCount = [];
    foreach ($db->query('SELECT user_id, COUNT(*) c FROM cp_sites GROUP BY user_id')->fetchAll() as $r) $siteCount[(int)$r['user_id']] = (int)$r['c'];
    $botCount = [];
    foreach ($db->query('SELECT user_id, COUNT(*) c FROM cp_bots GROUP BY user_id')->fetchAll() as $r) $botCount[(int)$r['user_id']] = (int)$r['c'];

    $pending = 0;
    foreach ($users as $u) if ((string)$u['status'] === 'pending') $pending++;
    $modals = [];
    ?>
<section class="clients-hero-v94">
  <div>
    <div class="eyebrow"><i class="fa-solid fa-users"></i> cp.hyper-host.pw</div>
    <h2>Клиенты портала</h2>
    <p>Пока клиенту не выданы ресурсы, он видит только заглушку «администратор ещё не выдал права».
       Выданные проценты CPU и мегабайты памяти применяются к systemd-юнитам его ботов по-настоящему.</p>
  </div>
  <div class="clients-stat-v94">
    <div><span>Всего</span><b><?= count($users) ?></b></div>
    <div><span>Ждут выдачи</span><b class="<?= $pending ? 'hh-warn' : '' ?>"><?= $pending ?></b></div>
  </div>
</section>

<div class="panel-card">
  <div class="table-responsive">
    <table class="table table-dark-soft align-middle mb-0">
      <thead><tr><th>Клиент</th><th>Статус</th><th>Использует</th><th>Выдано</th><th class="text-end">Действия</th></tr></thead>
      <tbody>
      <?php foreach ($users as $u):
          $uid = (int)$u['id'];
          $q = $quotas[$uid] ?? ['max_sites'=>0,'max_bots'=>0,'cpu_percent'=>0,'memory_mb'=>0,'disk_mb'=>0];
          $granted = ((int)$q['max_sites'] + (int)$q['max_bots']) > 0;
          $status = (string)$u['status'];
          $badge = $status === 'active' ? 'success' : ($status === 'suspended' ? 'danger' : 'warning');
          $label = $status === 'active' ? 'активен' : ($status === 'suspended' ? 'заблокирован' : 'ждёт выдачи');
          ob_start(); ?>
        <div class="modal fade hh-modal" id="cpGrant<?= $uid ?>" tabindex="-1" aria-hidden="true">
          <div class="modal-dialog modal-dialog-centered">
            <div class="modal-content">
              <form method="post">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="cp_grant">
                <input type="hidden" name="user_id" value="<?= $uid ?>">
                <div class="modal-header">
                  <div>
                    <div class="eyebrow mb-1"><i class="fa-solid fa-sliders"></i> Ресурсы</div>
                    <h5 class="modal-title mb-0"><?= e((string)$u['username']) ?></h5>
                  </div>
                  <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                </div>
                <div class="modal-body">
                  <div class="cp-grant-grid-v94">
                    <label class="hh-field"><span>Сайтов</span>
                      <input class="form-control" type="number" name="max_sites" min="0" max="200" value="<?= (int)$q['max_sites'] ?>"></label>
                    <label class="hh-field"><span>Ботов</span>
                      <input class="form-control" type="number" name="max_bots" min="0" max="200" value="<?= (int)$q['max_bots'] ?>"></label>
                    <label class="hh-field"><span>CPU, % ядра</span>
                      <input class="form-control" type="number" name="cpu_percent" min="0" max="400" step="5" value="<?= (int)$q['cpu_percent'] ?>"></label>
                    <label class="hh-field"><span>RAM, MB</span>
                      <input class="form-control" type="number" name="memory_mb" min="0" max="65536" step="64" value="<?= (int)$q['memory_mb'] ?>"></label>
                    <label class="hh-field"><span>Диск, MB</span>
                      <input class="form-control" type="number" name="disk_mb" min="0" max="4194304" step="512" value="<?= (int)$q['disk_mb'] ?>"></label>
                  </div>
                  <div class="cp-grant-note-v94">
                    <i class="fa-solid fa-circle-info me-2"></i>
                    CPU и RAM делятся поровну между ботами клиента и прописываются в
                    <code>CPUQuota=</code> и <code>MemoryMax=</code> его systemd-юнитов.
                    Работающие боты перезапустятся, чтобы новые лимиты вступили в силу.
                  </div>
                </div>
                <div class="modal-footer">
                  <button type="button" class="btn btn-soft" data-bs-dismiss="modal">Отмена</button>
                  <button class="btn btn-primary">Выдать</button>
                </div>
              </form>
            </div>
          </div>
        </div>
      <?php $modals[] = ob_get_clean(); ?>
        <tr>
          <td>
            <b><?= e((string)$u['username']) ?></b>
            <div class="small muted"><?= e((string)($u['email'] ?: '—')) ?></div>
            <div class="small muted">с <?= e(substr((string)$u['created_at'], 0, 10)) ?></div>
          </td>
          <td><span class="badge rounded-pill text-bg-<?= $badge ?>"><?= e($label) ?></span></td>
          <td>
            <div class="small">сайтов: <b><?= (int)($siteCount[$uid] ?? 0) ?></b> из <?= (int)$q['max_sites'] ?></div>
            <div class="small">ботов: <b><?= (int)($botCount[$uid] ?? 0) ?></b> из <?= (int)$q['max_bots'] ?></div>
          </td>
          <td>
            <?php if ($granted): ?>
              <div class="small">CPU <b><?= (int)$q['cpu_percent'] ?>%</b> · RAM <b><?= (int)$q['memory_mb'] ?> MB</b></div>
              <div class="small muted">диск <?= (int)$q['disk_mb'] ?> MB</div>
            <?php else: ?>
              <span class="badge rounded-pill text-bg-secondary">ничего не выдано</span>
            <?php endif; ?>
          </td>
          <td class="text-end">
            <div class="d-inline-flex gap-2 flex-wrap justify-content-end">
              <button class="btn btn-sm btn-primary" data-bs-toggle="modal" data-bs-target="#cpGrant<?= $uid ?>">
                <i class="fa-solid fa-sliders me-1"></i>Ресурсы
              </button>
              <form method="post">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="cp_status">
                <input type="hidden" name="user_id" value="<?= $uid ?>">
                <input type="hidden" name="status" value="<?= $status === 'suspended' ? 'active' : 'suspended' ?>">
                <button class="btn btn-sm btn-outline-<?= $status === 'suspended' ? 'success' : 'warning' ?>">
                  <?= $status === 'suspended' ? 'Разблокировать' : 'Заблокировать' ?>
                </button>
              </form>
              <form method="post" onsubmit="return confirm('Удалить клиента <?= e((string)$u['username']) ?> вместе со всеми сайтами, ботами и файлами? Отменить нельзя.')">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="cp_delete">
                <input type="hidden" name="user_id" value="<?= $uid ?>">
                <button class="btn btn-sm btn-outline-danger"><i class="fa-solid fa-trash"></i></button>
              </form>
            </div>
          </td>
        </tr>
      <?php endforeach; if (!$users): ?>
        <tr><td colspan="5" class="empty">Клиентов пока нет. Регистрация — на cp.hyper-host.pw</td></tr>
      <?php endif; ?>
      </tbody>
    </table>
  </div>
</div>
<?= implode("\n", $modals) ?>
<?php }
