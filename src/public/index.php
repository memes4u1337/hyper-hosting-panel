<?php
declare(strict_types=1);
require __DIR__ . '/../app/bootstrap.php';

$page = (string)($_GET['page'] ?? 'dashboard');
$action = $_POST['action'] ?? $_GET['action'] ?? null;

if ($page === 'logout') {
    session_destroy();
    redirect('/?page=login');
}

if ($page === 'login') {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        check_csrf();
        $username = trim((string)($_POST['username'] ?? ''));
        $password = (string)($_POST['password'] ?? '');
        $stmt = db()->prepare('SELECT * FROM users WHERE username = ?');
        $stmt->execute([$username]);
        $user = $stmt->fetch();
        if ($user && password_verify($password, (string)$user['password_hash'])) {
            $_SESSION['user_id'] = (int)$user['id'];
            add_event('auth', 'Вход в панель: ' . $username);
            redirect('/');
        }
        flash('Неверный логин или пароль', 'danger');
        redirect('/?page=login');
    }
    render_login();
    exit;
}

$user = require_auth();
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    handle_post((string)$action);
}
render_page($page, $user);

function csrf_field(): string
{
    return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">';
}

function host_name(): string
{
    return panel_host_for_connections();
}

function default_ftp_password(): string
{
    return 'Hh-' . bin2hex(random_bytes(5)) . '!';
}

function handle_post(string $action): void
{
    try {
        switch ($action) {
            case 'add_site':
                $domain = strtolower(trim((string)($_POST['domain'] ?? '')));
                $aliases = strtolower(trim((string)($_POST['aliases'] ?? '')));
                if (!is_valid_domain($domain)) {
                    throw new RuntimeException('Неверный домен');
                }
                foreach (array_filter(array_map('trim', explode(',', $aliases))) as $alias) {
                    if (!is_valid_domain($alias)) {
                        throw new RuntimeException('Неверный alias: ' . $alias);
                    }
                }
                $result = run_ctl(['add-site', $domain, $aliases], 180);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                $root = rtrim((string)app_config('sites_dir'), '/') . '/' . $domain . '/public_html';
                upsert_site_row($domain, $aliases, $root, 0);
                add_event('site', 'Создан сайт: ' . $domain);
                flash('Сайт создан и папка public_html готова: ' . $domain, 'success');
                redirect('/?page=sites');

            case 'delete_site':
                $id = (int)($_POST['id'] ?? 0);
                $mode = !empty($_POST['delete_files']) ? '--delete-files' : '--keep-files';
                $stmt = db()->prepare('SELECT * FROM sites WHERE id = ?');
                $stmt->execute([$id]);
                $site = $stmt->fetch();
                if (!$site) throw new RuntimeException('Сайт не найден');
                $result = run_ctl(['delete-site', $site['domain'], $mode], 120);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                db()->prepare('DELETE FROM sites WHERE id = ?')->execute([$id]);
                add_event('site', 'Удалён сайт: ' . $site['domain']);
                flash('Сайт удалён: ' . $site['domain'], 'success');
                redirect('/?page=sites');

            case 'ssl_site':
                $id = (int)($_POST['id'] ?? 0);
                $email = trim((string)($_POST['email'] ?? ''));
                if (!filter_var($email, FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Укажи нормальный email');
                $stmt = db()->prepare('SELECT * FROM sites WHERE id = ?');
                $stmt->execute([$id]);
                $site = $stmt->fetch();
                if (!$site) throw new RuntimeException('Сайт не найден');
                $result = run_ctl(['ssl-site', $site['domain'], $email], 300);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                db()->prepare('UPDATE sites SET ssl_enabled = 1 WHERE id = ?')->execute([$id]);
                add_event('ssl', 'Выпущен SSL: ' . $site['domain']);
                flash('SSL выпущен для ' . $site['domain'], 'success');
                redirect('/?page=sites');

            case 'create_folder':
                $name = trim((string)($_POST['name'] ?? ''));
                if (!is_valid_folder_name($name)) throw new RuntimeException('Неверное имя папки. Можно латиницу, цифры, точку, _ и -');
                $result = run_ctl(['create-folder', $name], 120);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                $path = rtrim((string)app_config('sites_dir'), '/') . '/' . $name . '/public_html';
                upsert_folder_row($name, $path);
                add_event('folder', 'Создана папка: ' . $name);
                flash('Папка создана: ' . $name . '. Внутри уже есть стартовый index.php', 'success');
                redirect('/?page=folders');

            case 'delete_folder':
                $id = (int)($_POST['id'] ?? 0);
                $stmt = db()->prepare('SELECT * FROM folders WHERE id = ?');
                $stmt->execute([$id]);
                $folder = $stmt->fetch();
                if (!$folder) throw new RuntimeException('Папка не найдена');
                $result = run_ctl(['delete-folder', $folder['name']], 120);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                db()->prepare('DELETE FROM folders WHERE id = ?')->execute([$id]);
                add_event('folder', 'Удалена папка: ' . $folder['name']);
                flash('Папка удалена: ' . $folder['name'], 'success');
                redirect('/?page=folders');

            case 'create_ftp':
                $username = trim((string)($_POST['username'] ?? ''));
                $password = (string)($_POST['password'] ?? '');
                $target = trim((string)($_POST['target_path'] ?? 'common'));
                if ($username === '' || !is_valid_name($username)) throw new RuntimeException('Неверный FTP логин');
                if (strlen($password) < 8) throw new RuntimeException('Пароль FTP минимум 8 символов');
                if ($target === '') $target = 'common';
                if ($target !== 'common' && !str_starts_with($target, (string)app_config('sites_dir')) && !str_starts_with($target, (string)app_config('bots_dir')) && !str_starts_with($target, (string)app_config('ftp_dir', '/var/www/hyper-host-ftp'))) {
                    throw new RuntimeException('Путь должен быть common, сайтами или ботами');
                }
                $result = run_ctl(['create-ftp', $username, $password, $target], 180);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                $finalUser = str_starts_with($username, 'hhftp_') ? $username : 'hhftp_' . $username;
                $home = rtrim((string)app_config('ftp_dir', '/var/www/hyper-host-ftp'), '/') . '/' . $finalUser;
                upsert_ftp_row($finalUser, $home, $password, host_name());
                add_event('ftp', 'Создан FTP: ' . $finalUser);
                flash("FTP создан. Хост: " . host_name() . " | Имя пользователя: {$finalUser} | Пароль: {$password}", 'success');
                redirect('/?page=ftp');

            case 'delete_ftp':
                $id = (int)($_POST['id'] ?? 0);
                $stmt = db()->prepare('SELECT * FROM ftp_accounts WHERE id = ?');
                $stmt->execute([$id]);
                $ftp = $stmt->fetch();
                if (!$ftp) throw new RuntimeException('FTP не найден');
                $result = run_ctl(['delete-ftp', $ftp['username']], 120);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                db()->prepare('DELETE FROM ftp_accounts WHERE id = ?')->execute([$id]);
                add_event('ftp', 'Удалён FTP: ' . $ftp['username']);
                flash('FTP удалён: ' . $ftp['username'], 'success');
                redirect('/?page=ftp');

            case 'reset_ftp_password':
                $id = (int)($_POST['id'] ?? 0);
                $password = (string)($_POST['password'] ?? '');
                if (strlen($password) < 8) throw new RuntimeException('Пароль FTP минимум 8 символов');
                $stmt = db()->prepare('SELECT * FROM ftp_accounts WHERE id = ?');
                $stmt->execute([$id]);
                $ftp = $stmt->fetch();
                if (!$ftp) throw new RuntimeException('FTP не найден');
                $result = run_ctl(['ftp-password', $ftp['username'], $password], 120);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                upsert_ftp_row((string)$ftp['username'], (string)$ftp['target_path'], $password, host_name());
                add_event('ftp', 'Обновлён пароль FTP: ' . $ftp['username']);
                flash("Пароль FTP обновлён. Хост: " . host_name() . " | Имя пользователя: {$ftp['username']} | Пароль: {$password}", 'success');
                redirect('/?page=ftp');

            case 'create_db':
                $dbName = trim((string)($_POST['db_name'] ?? ''));
                $dbUser = trim((string)($_POST['db_user'] ?? ''));
                $password = (string)($_POST['password'] ?? '');
                $remote = !empty($_POST['remote_allowed']) ? '1' : '0';
                if (!is_valid_db_name($dbName) || !is_valid_db_name($dbUser)) throw new RuntimeException('Имя базы и пользователя: латиница, цифры, _');
                if (strlen($password) < 10) throw new RuntimeException('Пароль базы минимум 10 символов');
                $result = run_ctl(['create-db', $dbName, $dbUser, $password, $remote], 180);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                upsert_db_row($dbName, $dbUser, (int)$remote);
                add_event('db', 'Создана база: ' . $dbName);
                flash('База создана: ' . $dbName, 'success');
                redirect('/?page=databases');

            case 'delete_db':
                $id = (int)($_POST['id'] ?? 0);
                $stmt = db()->prepare('SELECT * FROM databases WHERE id = ?');
                $stmt->execute([$id]);
                $row = $stmt->fetch();
                if (!$row) throw new RuntimeException('База не найдена');
                $result = run_ctl(['delete-db', $row['db_name'], $row['db_user']], 180);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                db()->prepare('DELETE FROM databases WHERE id = ?')->execute([$id]);
                add_event('db', 'Удалена база: ' . $row['db_name']);
                flash('База удалена: ' . $row['db_name'], 'success');
                redirect('/?page=databases');

            case 'mysql_external':
                $state = (string)($_POST['state'] ?? 'disable');
                if (!in_array($state, ['enable', 'disable'], true)) throw new RuntimeException('Неверное действие');
                $result = run_ctl(['mysql-external', $state], 180);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                setting_set('mysql_external', $state === 'enable' ? '1' : '0');
                flash('Внешний MySQL: ' . ($state === 'enable' ? 'включён' : 'выключен'), 'success');
                redirect('/?page=settings');

            case 'create_bot':
                $name = trim((string)($_POST['name'] ?? ''));
                $runtime = (string)($_POST['runtime'] ?? 'python');
                $cmd = trim((string)($_POST['start_command'] ?? ''));
                if (!is_valid_name($name)) throw new RuntimeException('Неверное имя бота');
                if (!in_array($runtime, ['python', 'node', 'php', 'custom'], true)) throw new RuntimeException('Неверный runtime');
                if ($cmd === '') throw new RuntimeException('Команда запуска обязательна');
                $result = run_ctl(['bot-create', $name, $runtime, $cmd], 180);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                $path = rtrim((string)app_config('bots_dir'), '/') . '/' . $name;
                upsert_bot_row($name, $runtime, $path, $cmd);
                add_event('bot', 'Создан 24/7 бот: ' . $name);
                flash('Бот создан как systemd-сервис 24/7: ' . $name, 'success');
                redirect('/?page=bots');

            case 'bot_action':
                $id = (int)($_POST['id'] ?? 0);
                $botAction = (string)($_POST['bot_action'] ?? '');
                $stmt = db()->prepare('SELECT * FROM bots WHERE id = ?');
                $stmt->execute([$id]);
                $bot = $stmt->fetch();
                if (!$bot) throw new RuntimeException('Бот не найден');
                if ($botAction === 'install') {
                    $result = run_ctl(['bot-install-requirements', $bot['name']], 300);
                } else {
                    $result = run_ctl(['bot', $botAction, $bot['name']], 120);
                }
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                flash('Команда выполнена: ' . $botAction . ' / ' . $bot['name'], 'success');
                redirect('/?page=bots');

            case 'delete_bot':
                $id = (int)($_POST['id'] ?? 0);
                $mode = !empty($_POST['delete_files']) ? '--delete-files' : '--keep-files';
                $stmt = db()->prepare('SELECT * FROM bots WHERE id = ?');
                $stmt->execute([$id]);
                $bot = $stmt->fetch();
                if (!$bot) throw new RuntimeException('Бот не найден');
                $result = run_ctl(['bot-delete', $bot['name'], $mode], 120);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                db()->prepare('DELETE FROM bots WHERE id = ?')->execute([$id]);
                flash('Бот удалён: ' . $bot['name'], 'success');
                redirect('/?page=bots');

            case 'repair_panel':
                $result = run_ctl(['repair'], 180);
                if ($result['code'] !== 0) throw new RuntimeException($result['output']);
                flash('Ремонт выполнен: права, sudoers, FTP shell/порты и сервисы проверены', 'success');
                redirect('/?page=settings');

            case 'sync_resources':
                sync_resources();
                flash('Ресурсы синхронизированы с сервером', 'success');
                redirect('/?page=dashboard');

            case 'change_password':
                $current = (string)($_POST['current_password'] ?? '');
                $new = (string)($_POST['new_password'] ?? '');
                if (strlen($new) < 10) throw new RuntimeException('Новый пароль минимум 10 символов');
                $uid = (int)($_SESSION['user_id'] ?? 0);
                $stmt = db()->prepare('SELECT * FROM users WHERE id = ?');
                $stmt->execute([$uid]);
                $u = $stmt->fetch();
                if (!$u || !password_verify($current, (string)$u['password_hash'])) throw new RuntimeException('Текущий пароль неверный');
                db()->prepare('UPDATE users SET password_hash = ? WHERE id = ?')->execute([password_hash($new, PASSWORD_DEFAULT), $uid]);
                flash('Пароль панели изменён', 'success');
                redirect('/?page=settings');
        }
    } catch (Throwable $e) {
        flash($e->getMessage(), 'danger');
        redirect('/?page=' . ($_GET['page'] ?? 'dashboard'));
    }
}

function sync_resources(): void
{
    $data = run_ctl_json(['sync-json'], 90);
    if (isset($data['_error'])) throw new RuntimeException((string)$data['_error']);
    foreach (($data['sites'] ?? []) as $s) upsert_site_row((string)$s['domain'], (string)($s['aliases'] ?? ''), (string)$s['root_path'], (int)($s['ssl_enabled'] ?? 0));
    foreach (($data['folders'] ?? []) as $f) upsert_folder_row((string)$f['name'], (string)$f['path']);
    foreach (($data['ftp'] ?? []) as $f) upsert_ftp_row((string)$f['username'], (string)$f['target_path'], '', (string)($f['host'] ?? host_name()));
    foreach (($data['databases'] ?? []) as $d) upsert_db_row((string)$d['db_name'], (string)$d['db_user'], (int)($d['remote_allowed'] ?? 0));
    foreach (($data['bots'] ?? []) as $b) upsert_bot_row((string)$b['name'], (string)$b['runtime'], (string)$b['path'], (string)$b['start_command']);
}

function render_login(): void
{
    $flash = flash();
    ?>
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HYPER-HOST</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet"><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet"><link href="/assets/style.css" rel="stylesheet"></head><body class="login-body">
<div class="login-shell">
  <div class="login-card card-glass">
    <div class="brand-mark"><i class="fa-solid fa-rocket"></i></div>
    <h1>HYPER-HOST</h1><p>powered by memes4u1337</p>
    <?php if ($flash): ?><div class="alert alert-<?= e($flash['type']) ?> py-2"><?= e($flash['message']) ?></div><?php endif; ?>
    <form method="post" class="vstack gap-3">
      <?= csrf_field() ?>
      <input class="form-control form-control-lg" name="username" placeholder="Логин" autofocus required>
      <input class="form-control form-control-lg" type="password" name="password" placeholder="Пароль" required>
      <button class="btn btn-primary btn-lg w-100"><i class="fa-solid fa-right-to-bracket me-2"></i>Войти</button>
    </form>
  </div>
</div>
</body></html><?php
}

function render_page(string $page, array $user): void
{
    $titles = ['dashboard'=>'Дашборд','sites'=>'Сайты','folders'=>'Папки','ftp'=>'FTP','databases'=>'Базы данных','bots'=>'Боты 24/7','bot_logs'=>'Логи бота','settings'=>'Настройки','roadmap'=>'Что ещё добавить'];
    $title = $titles[$page] ?? 'Дашборд';
    $flash = flash();
    ?><!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?= e($title) ?> — HYPER-HOST</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet"><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet"><link href="/assets/style.css" rel="stylesheet"></head><body>
<div class="app-shell">
  <aside class="sidebar">
    <div class="brand"><div class="brand-icon"><i class="fa-solid fa-bolt"></i></div><div><b>HYPER-HOST</b><span>powered by memes4u1337</span></div></div>
    <nav class="nav flex-column gap-1 mt-4">
      <?= nav_item('dashboard','fa-gauge-high','Дашборд',$page) ?>
      <?= nav_item('sites','fa-globe','Сайты',$page) ?>
      <?= nav_item('folders','fa-folder-tree','Папки',$page) ?>
      <?= nav_item('ftp','fa-network-wired','FTP',$page) ?>
      <?= nav_item('databases','fa-database','Базы',$page) ?>
      <?= nav_item('bots','fa-robot','Боты 24/7',$page) ?>
      <?= nav_item('settings','fa-sliders','Настройки',$page) ?>
      <?= nav_item('roadmap','fa-list-check','Что добавить',$page) ?>
    </nav>
    <div class="sidebar-footer"><a href="/?page=logout" class="btn btn-outline-light w-100"><i class="fa-solid fa-arrow-right-from-bracket me-2"></i>Выйти</a></div>
  </aside>
  <main class="content">
    <header class="topbar">
      <div><h1><?= e($title) ?></h1><div class="text-muted small">Сервер: <code><?= e(host_name()) ?></code></div></div>
      <div class="top-actions"><form method="post" class="d-inline"><?= csrf_field() ?><input type="hidden" name="action" value="sync_resources"><button class="btn btn-light"><i class="fa-solid fa-rotate me-2"></i>Синхронизация</button></form></div>
    </header>
    <?php if ($flash): ?><div class="alert alert-<?= e($flash['type']) ?> shadow-sm"><i class="fa-solid fa-circle-info me-2"></i><?= nl2br(e($flash['message'])) ?></div><?php endif; ?>
    <?php route_view($page); ?>
  </main>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script><script src="/assets/app.js"></script>
</body></html><?php
}

function nav_item(string $id, string $icon, string $label, string $page): string
{
    $active = $id === $page ? ' active' : '';
    return '<a class="nav-link' . $active . '" href="/?page=' . e($id) . '"><i class="fa-solid ' . e($icon) . '"></i><span>' . e($label) . '</span></a>';
}

function route_view(string $page): void
{
    match ($page) {
        'sites' => view_sites(), 'folders' => view_folders(), 'ftp' => view_ftp(), 'databases' => view_databases(), 'bots' => view_bots(), 'bot_logs' => view_bot_logs(), 'settings' => view_settings(), 'roadmap' => view_roadmap(), default => view_dashboard(),
    };
}

function stat_card(string $icon, string $label, string $value, string $sub=''): void { ?><div class="stat-card"><div class="stat-icon"><i class="fa-solid <?= e($icon) ?>"></i></div><div><span><?= e($label) ?></span><b><?= e($value) ?></b><?php if($sub): ?><em><?= e($sub) ?></em><?php endif; ?></div></div><?php }

function view_dashboard(): void
{
    $stats = run_ctl_json(['stats-json'], 40);
    $events = db()->query('SELECT * FROM events ORDER BY id DESC LIMIT 8')->fetchAll();
    ?>
<div class="row g-3 mb-4">
  <div class="col-md-3"><?php stat_card('fa-globe', 'Сайты', (string)table_count('sites'), 'домены') ?></div>
  <div class="col-md-3"><?php stat_card('fa-folder', 'Папки', (string)table_count('folders'), 'public_html') ?></div>
  <div class="col-md-3"><?php stat_card('fa-network-wired', 'FTP', (string)table_count('ftp_accounts'), 'аккаунты') ?></div>
  <div class="col-md-3"><?php stat_card('fa-robot', 'Боты', (string)table_count('bots'), 'systemd 24/7') ?></div>
</div>
<div class="row g-4">
  <div class="col-xl-8"><div class="panel-card"><div class="card-title-row"><h2><i class="fa-solid fa-microchip me-2"></i>Железо сервера</h2><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="repair_panel"><button class="btn btn-sm btn-primary">Починить</button></form></div>
  <?php if (isset($stats['_error'])): ?><div class="alert alert-warning">Статистика пока недоступна: <?= e($stats['_error']) ?></div><?php else: ?>
  <div class="hardware-grid">
    <div><span>CPU</span><b><?= e((string)$stats['cpu_model']) ?></b></div><div><span>Ядра</span><b><?= e((string)$stats['cpu_cores']) ?></b></div><div><span>Uptime</span><b><?= e((string)$stats['uptime']) ?></b></div><div><span>Load</span><b><?= e(round((float)$stats['load1'],2).' / '.round((float)$stats['load5'],2).' / '.round((float)$stats['load15'],2)) ?></b></div>
  </div>
  <?= progress_block('RAM', (float)$stats['mem_used'], (float)$stats['mem_total']) ?>
  <?= progress_block('Диск /', (float)$stats['disk_used'], (float)$stats['disk_total']) ?>
  <div class="service-row mt-3"><?php foreach (($stats['services'] ?? []) as $name=>$st): ?><span class="badge rounded-pill text-bg-<?= $st==='active'?'success':'danger' ?>"><?= e($name) ?>: <?= e((string)$st) ?></span><?php endforeach; ?></div>
  <?php endif; ?></div></div>
  <div class="col-xl-4"><div class="panel-card"><h2><i class="fa-solid fa-clock-rotate-left me-2"></i>События</h2><?php foreach($events as $ev): ?><div class="event"><b><?= e($ev['type']) ?></b><span><?= e($ev['message']) ?></span><small><?= e($ev['created_at']) ?></small></div><?php endforeach; if(!$events): ?><div class="empty">Событий пока нет</div><?php endif; ?></div></div>
</div><?php
}

function progress_block(string $label, float $used, float $total): string
{
    $p = percent($used,$total);
    return '<div class="usage"><div class="d-flex justify-content-between"><span>'.e($label).'</span><b>'.e(human_bytes($used).' / '.human_bytes($total)).'</b></div><div class="progress"><div class="progress-bar" style="width:'.$p.'%"></div></div></div>';
}

function view_sites(): void
{
    $sites = db()->query('SELECT * FROM sites ORDER BY id DESC')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-5"><div class="panel-card"><h2><i class="fa-solid fa-plus me-2"></i>Создать сайт</h2><p class="text-muted">Сразу создаётся папка <code>public_html</code>, Nginx-конфиг и стартовая страница.</p><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="add_site"><input class="form-control" name="domain" placeholder="hyper-host.pw" required><input class="form-control" name="aliases" placeholder="www.hyper-host.pw, api.hyper-host.pw"><button class="btn btn-primary"><i class="fa-solid fa-globe me-2"></i>Создать сайт</button></form></div></div><div class="col-lg-7"><div class="panel-card"><h2>Сайты</h2><div class="table-responsive"><table class="table align-middle"><thead><tr><th>Домен</th><th>Папка</th><th>SSL</th><th></th></tr></thead><tbody><?php foreach($sites as $s): ?><tr><td><b><?= e($s['domain']) ?></b><div class="small text-muted"><?= e($s['aliases']) ?></div></td><td><code><?= e($s['root_path']) ?></code></td><td><span class="badge text-bg-<?= (int)$s['ssl_enabled']?'success':'secondary' ?>"><?= (int)$s['ssl_enabled']?'SSL':'HTTP' ?></span></td><td class="text-end"><button class="btn btn-sm btn-outline-primary" data-bs-toggle="modal" data-bs-target="#ssl<?= (int)$s['id'] ?>">SSL</button><form method="post" class="d-inline" onsubmit="return confirm('Удалить сайт?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><div class="modal fade" id="ssl<?= (int)$s['id'] ?>"><div class="modal-dialog"><div class="modal-content"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="ssl_site"><input type="hidden" name="id" value="<?= (int)$s['id'] ?>"><div class="modal-header"><h5>SSL для <?= e($s['domain']) ?></h5><button class="btn-close" data-bs-dismiss="modal" type="button"></button></div><div class="modal-body"><input class="form-control" name="email" type="email" placeholder="email@example.com" required></div><div class="modal-footer"><button class="btn btn-primary">Выпустить SSL</button></div></form></div></div></div><?php endforeach; if(!$sites): ?><tr><td colspan="4" class="empty">Сайтов пока нет</td></tr><?php endif; ?></tbody></table></div></div></div></div><?php
}

function view_folders(): void
{
    $rows = db()->query('SELECT * FROM folders ORDER BY id DESC')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-5"><div class="panel-card"><h2><i class="fa-solid fa-folder-plus me-2"></i>Создать папку</h2><p class="text-muted">Создаёт пустой мини-сайт без домена: папка с <code>public_html/index.php</code> и названием папки.</p><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_folder"><input class="form-control" name="name" placeholder="client-site-1" required><button class="btn btn-primary">Создать папку</button></form></div></div><div class="col-lg-7"><div class="panel-card"><h2>Папки сайтов</h2><div class="table-responsive"><table class="table align-middle"><thead><tr><th>Название</th><th>Путь</th><th></th></tr></thead><tbody><?php foreach($rows as $r): ?><tr><td><b><?= e($r['name']) ?></b></td><td><code><?= e($r['path']) ?></code></td><td class="text-end"><form method="post" onsubmit="return confirm('Удалить папку с файлами?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_folder"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$rows): ?><tr><td colspan="3" class="empty">Папок пока нет</td></tr><?php endif; ?></tbody></table></div></div></div></div><?php
}

function view_ftp(): void
{
    $rows = db()->query('SELECT * FROM ftp_accounts ORDER BY id DESC')->fetchAll();
    $sites = db()->query('SELECT domain, root_path FROM sites ORDER BY domain')->fetchAll();
    $folders = db()->query('SELECT name, path FROM folders ORDER BY name')->fetchAll();
    $bots = db()->query('SELECT name, path FROM bots ORDER BY name')->fetchAll();
    $gen = default_ftp_password(); ?>
<div class="row g-4"><div class="col-lg-5"><div class="panel-card"><h2><i class="fa-solid fa-user-plus me-2"></i>Создать FTP</h2><p class="text-muted">После входа FTP увидит папку <b>common</b>. Если выбрать сайт/бота — дополнительно будет папка <b>site</b> с файлами.</p><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_ftp"><input class="form-control" name="username" placeholder="hyperhost" required><div class="input-group"><input class="form-control" name="password" id="ftpPass" value="<?= e($gen) ?>" minlength="8" required><button class="btn btn-outline-secondary" type="button" onclick="copyValue('ftpPass')"><i class="fa-regular fa-copy"></i></button></div><select class="form-select" name="target_path"><option value="common">Только общая папка common</option><?php foreach($sites as $s): ?><option value="<?= e($s['root_path']) ?>">Сайт: <?= e($s['domain']) ?></option><?php endforeach; foreach($folders as $f): ?><option value="<?= e($f['path']) ?>">Папка: <?= e($f['name']) ?></option><?php endforeach; foreach($bots as $b): ?><option value="<?= e($b['path']) ?>">Бот: <?= e($b['name']) ?></option><?php endforeach; ?></select><button class="btn btn-primary"><i class="fa-solid fa-network-wired me-2"></i>Создать FTP</button></form></div></div><div class="col-lg-7"><div class="row g-3"><?php foreach($rows as $r): ?><div class="col-md-6"><div class="ftp-card"><h3><i class="fa-solid fa-plug me-2"></i><?= e($r['username']) ?></h3><div class="cred"><span>Хост</span><code><?= e($r['host'] ?: host_name()) ?></code></div><div class="cred"><span>Имя пользователя</span><code><?= e($r['username']) ?></code></div><div class="cred"><span>Пароль</span><code><?= e($r['password_plain'] ?: 'задать новый') ?></code></div><div class="small text-muted mt-2">Корень: <code><?= e($r['target_path']) ?></code><br>Порт: <b>21</b>, Passive: <b>40000-40100</b></div><div class="d-flex gap-2 mt-3"><button class="btn btn-sm btn-light" onclick="copyText('Host: <?= e($r['host'] ?: host_name()) ?>\nLogin: <?= e($r['username']) ?>\nPassword: <?= e($r['password_plain']) ?>')">Копировать</button><button class="btn btn-sm btn-outline-light" data-bs-toggle="modal" data-bs-target="#ftp<?= (int)$r['id'] ?>">Пароль</button><form method="post" onsubmit="return confirm('Удалить FTP?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_ftp"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-danger">Удалить</button></form></div></div></div><div class="modal fade" id="ftp<?= (int)$r['id'] ?>"><div class="modal-dialog"><div class="modal-content"><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="reset_ftp_password"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><div class="modal-header"><h5>Новый пароль FTP</h5><button class="btn-close" data-bs-dismiss="modal" type="button"></button></div><div class="modal-body"><input class="form-control" name="password" value="<?= e(default_ftp_password()) ?>" minlength="8" required></div><div class="modal-footer"><button class="btn btn-primary">Сохранить пароль</button></div></form></div></div></div><?php endforeach; if(!$rows): ?><div class="empty">FTP аккаунтов пока нет</div><?php endif; ?></div></div></div><?php
}

function view_databases(): void
{
    $rows = db()->query('SELECT * FROM databases ORDER BY id DESC')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-5"><div class="panel-card"><h2><i class="fa-solid fa-database me-2"></i>Создать базу</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_db"><input class="form-control" name="db_name" placeholder="site_db" required><input class="form-control" name="db_user" placeholder="site_user" required><input class="form-control" name="password" type="password" placeholder="Пароль" minlength="10" required><label class="form-check"><input class="form-check-input" type="checkbox" name="remote_allowed" value="1"> <span class="form-check-label">Разрешить внешний доступ</span></label><button class="btn btn-primary">Создать базу</button><a class="btn btn-outline-primary" href="/phpmyadmin" target="_blank">Открыть phpMyAdmin</a></form></div></div><div class="col-lg-7"><div class="panel-card"><h2>Базы данных</h2><div class="table-responsive"><table class="table align-middle"><thead><tr><th>База</th><th>Пользователь</th><th>Доступ</th><th></th></tr></thead><tbody><?php foreach($rows as $r): ?><tr><td><code><?= e($r['db_name']) ?></code></td><td><code><?= e($r['db_user']) ?></code></td><td><span class="badge text-bg-<?= (int)$r['remote_allowed']?'success':'secondary' ?>"><?= (int)$r['remote_allowed']?'remote':'local' ?></span></td><td class="text-end"><form method="post" onsubmit="return confirm('Удалить базу?')"><?= csrf_field() ?><input type="hidden" name="action" value="delete_db"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="btn btn-sm btn-outline-danger">Удалить</button></form></td></tr><?php endforeach; if(!$rows): ?><tr><td colspan="4" class="empty">Баз пока нет</td></tr><?php endif; ?></tbody></table></div></div></div></div><?php
}

function view_bots(): void
{
    $bots = db()->query('SELECT * FROM bots ORDER BY id DESC')->fetchAll(); ?>
<div class="row g-4"><div class="col-lg-5"><div class="panel-card"><h2><i class="fa-solid fa-robot me-2"></i>Создать 24/7 бота</h2><p class="text-muted">Создаётся systemd-сервис с <code>Restart=always</code>. Бот будет работать после перезагрузки сервера.</p><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="create_bot"><input class="form-control" name="name" placeholder="mybot" required><select class="form-select" name="runtime"><option value="python">Python</option><option value="node">Node.js</option><option value="php">PHP</option><option value="custom">Custom</option></select><input class="form-control" name="start_command" placeholder="python3 main.py" value="python3 main.py" required><button class="btn btn-primary">Создать бота</button></form></div></div><div class="col-lg-7"><div class="panel-card"><h2>Боты</h2><div class="table-responsive"><table class="table align-middle"><thead><tr><th>Бот</th><th>Статус</th><th>Команда</th><th></th></tr></thead><tbody><?php foreach($bots as $b): $st=system_service_status('hyperbot-'.$b['name']); ?><tr><td><b><?= e($b['name']) ?></b><div class="small text-muted"><code><?= e($b['path']) ?></code></div></td><td><span class="badge text-bg-<?= $st==='active'?'success':'danger' ?>"><?= e($st) ?></span></td><td><code><?= e($b['start_command']) ?></code></td><td class="text-end"><div class="btn-group btn-group-sm"><?php foreach(['start'=>'Start','stop'=>'Stop','restart'=>'Restart','install'=>'Deps'] as $cmd=>$label): ?><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="bot_action"><input type="hidden" name="id" value="<?= (int)$b['id'] ?>"><input type="hidden" name="bot_action" value="<?= e($cmd) ?>"><button class="btn btn-outline-primary"><?= e($label) ?></button></form><?php endforeach; ?><a class="btn btn-outline-dark" href="/?page=bot_logs&id=<?= (int)$b['id'] ?>">Logs</a></div></td></tr><?php endforeach; if(!$bots): ?><tr><td colspan="4" class="empty">Ботов пока нет</td></tr><?php endif; ?></tbody></table></div></div></div></div><?php
}

function view_bot_logs(): void
{
    $id=(int)($_GET['id']??0); $stmt=db()->prepare('SELECT * FROM bots WHERE id=?'); $stmt->execute([$id]); $bot=$stmt->fetch(); if(!$bot){echo '<div class="panel-card empty">Бот не найден</div>';return;} $res=run_ctl(['bot','logs',$bot['name']],30); ?><div class="panel-card"><div class="card-title-row"><h2>Логи: <?= e($bot['name']) ?></h2><a class="btn btn-light" href="/?page=bots">Назад</a></div><pre class="logs"><?= e($res['output'] ?: 'Логов пока нет') ?></pre></div><?php
}

function view_settings(): void
{
    $mysqlExternal = setting_get('mysql_external', '0'); $dbStatus=db_writable_status(); ?>
<div class="row g-4"><div class="col-lg-6"><div class="panel-card"><h2>Внешние подключения MySQL</h2><p>Статус: <span class="badge text-bg-<?= $mysqlExternal==='1'?'success':'secondary' ?>"><?= $mysqlExternal==='1'?'включено':'выключено' ?></span></p><form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="mysql_external"><input type="hidden" name="state" value="<?= $mysqlExternal==='1'?'disable':'enable' ?>"><button class="btn btn-<?= $mysqlExternal==='1'?'danger':'primary' ?>"><?= $mysqlExternal==='1'?'Выключить':'Включить' ?></button></form></div></div><div class="col-lg-6"><div class="panel-card"><h2>Ремонт</h2><p class="text-muted">Чинит SQLite, sudoers, FTP shell, порты и сервисы.</p><form method="post" class="d-inline"><?= csrf_field() ?><input type="hidden" name="action" value="repair_panel"><button class="btn btn-primary">Починить права и сервисы</button></form><form method="post" class="d-inline ms-2"><?= csrf_field() ?><input type="hidden" name="action" value="sync_resources"><button class="btn btn-light">Синхронизировать</button></form></div></div><div class="col-lg-6"><div class="panel-card"><h2>Сменить пароль</h2><form method="post" class="vstack gap-3"><?= csrf_field() ?><input type="hidden" name="action" value="change_password"><input class="form-control" type="password" name="current_password" placeholder="Текущий пароль" required><input class="form-control" type="password" name="new_password" placeholder="Новый пароль" minlength="10" required><button class="btn btn-primary">Сменить пароль</button></form></div></div><div class="col-lg-6"><div class="panel-card"><h2>Системные пути</h2><div class="hardware-grid"><div><span>SQLite</span><b><?= e($dbStatus['file_writable']?'writable':'not writable') ?></b></div><div><span>Панель</span><b><?= e((string)app_config('panel_dir')) ?></b></div><div><span>Сайты</span><b><?= e((string)app_config('sites_dir')) ?></b></div><div><span>FTP</span><b><?= e((string)app_config('ftp_dir','/var/www/hyper-host-ftp')) ?></b></div></div></div></div></div><?php
}

function view_roadmap(): void
{ ?>
<div class="panel-card"><h2><i class="fa-solid fa-list-check me-2"></i>Чего ещё не хватает для полной хостинг-панели</h2><div class="row g-3 mt-2"><div class="col-md-6"><ul class="nice-list"><li>Файловый менеджер в браузере: загрузка, удаление, редактор PHP/HTML.</li><li>Резервные копии сайтов, баз и ботов по расписанию.</li><li>DNS-менеджер, если домены будут обслуживаться на твоих NS.</li><li>SSL-автопродление с красивым статусом сертификатов.</li><li>Ограничения ресурсов: лимит диска, лимит процессов, лимит RAM для ботов.</li></ul></div><div class="col-md-6"><ul class="nice-list"><li>Менеджер PHP-версий для каждого сайта.</li><li>Cron-задачи из панели.</li><li>Логи сайтов в UI: access/error, фильтр ошибок.</li><li>Безопасность: 2FA, IP allowlist, журнал входов.</li><li>Уведомления Telegram: падение бота, ошибка Nginx, мало места на диске.</li></ul></div></div></div><?php }
