<?php
declare(strict_types=1);
require __DIR__ . '/../app/bootstrap.php';

$page = $_GET['page'] ?? 'dashboard';
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
        if ($user && password_verify($password, $user['password_hash'])) {
            $_SESSION['user_id'] = (int)$user['id'];
            add_event('auth', 'Вход в панель: ' . $username);
            redirect('/');
        }
        flash('Неверный логин или пароль', 'err');
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

render_page((string)$page, $user);

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
                if ($aliases !== '') {
                    foreach (array_filter(array_map('trim', explode(',', $aliases))) as $alias) {
                        if (!is_valid_domain($alias)) {
                            throw new RuntimeException('Неверный alias: ' . $alias);
                        }
                    }
                }
                $result = run_ctl(['add-site', $domain, $aliases]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                $root = rtrim(app_config('sites_dir'), '/') . '/' . $domain . '/public_html';
                $stmt = db()->prepare('INSERT INTO sites(domain, aliases, root_path) VALUES(?, ?, ?) ON CONFLICT(domain) DO UPDATE SET aliases = excluded.aliases, root_path = excluded.root_path');
                $stmt->execute([$domain, $aliases, $root]);
                add_event('site', 'Создан сайт: ' . $domain);
                flash('Сайт создан: ' . $domain);
                redirect('/?page=sites');

            case 'delete_site':
                $id = (int)($_POST['id'] ?? 0);
                $mode = !empty($_POST['delete_files']) ? '--delete-files' : '--keep-files';
                $stmt = db()->prepare('SELECT * FROM sites WHERE id = ?');
                $stmt->execute([$id]);
                $site = $stmt->fetch();
                if (!$site) {
                    throw new RuntimeException('Сайт не найден');
                }
                $result = run_ctl(['delete-site', $site['domain'], $mode]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                db()->prepare('DELETE FROM sites WHERE id = ?')->execute([$id]);
                add_event('site', 'Удалён сайт: ' . $site['domain']);
                flash('Сайт удалён: ' . $site['domain']);
                redirect('/?page=sites');

            case 'ssl_site':
                $id = (int)($_POST['id'] ?? 0);
                $email = trim((string)($_POST['email'] ?? ''));
                if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
                    throw new RuntimeException('Укажи нормальный email для Let\'s Encrypt');
                }
                $stmt = db()->prepare('SELECT * FROM sites WHERE id = ?');
                $stmt->execute([$id]);
                $site = $stmt->fetch();
                if (!$site) {
                    throw new RuntimeException('Сайт не найден');
                }
                $result = run_ctl(['ssl-site', $site['domain'], $email], 240);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                db()->prepare('UPDATE sites SET ssl_enabled = 1 WHERE id = ?')->execute([$id]);
                add_event('ssl', 'Выпущен SSL: ' . $site['domain']);
                flash('SSL выпущен для ' . $site['domain']);
                redirect('/?page=sites');

            case 'create_ftp':
                $username = trim((string)($_POST['username'] ?? ''));
                $password = (string)($_POST['password'] ?? '');
                $target = trim((string)($_POST['target_path'] ?? ''));
                if ($username === '' || !is_valid_name($username)) {
                    throw new RuntimeException('Неверный FTP логин');
                }
                if (strlen($password) < 8) {
                    throw new RuntimeException('Пароль FTP минимум 8 символов');
                }
                if (!str_starts_with($target, app_config('sites_dir')) && !str_starts_with($target, app_config('bots_dir'))) {
                    throw new RuntimeException('Путь должен быть внутри сайтов или ботов');
                }
                $result = run_ctl(['create-ftp', $username, $password, $target]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                $finalUser = str_starts_with($username, 'hhftp_') ? $username : 'hhftp_' . $username;
                $stmt = db()->prepare('INSERT INTO ftp_accounts(username, target_path) VALUES(?, ?) ON CONFLICT(username) DO UPDATE SET target_path = excluded.target_path');
                $stmt->execute([$finalUser, $target]);
                add_event('ftp', 'Создан FTP: ' . $finalUser);
                flash('FTP создан: ' . $finalUser);
                redirect('/?page=ftp');

            case 'delete_ftp':
                $id = (int)($_POST['id'] ?? 0);
                $stmt = db()->prepare('SELECT * FROM ftp_accounts WHERE id = ?');
                $stmt->execute([$id]);
                $ftp = $stmt->fetch();
                if (!$ftp) {
                    throw new RuntimeException('FTP не найден');
                }
                $result = run_ctl(['delete-ftp', $ftp['username']]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                db()->prepare('DELETE FROM ftp_accounts WHERE id = ?')->execute([$id]);
                add_event('ftp', 'Удалён FTP: ' . $ftp['username']);
                flash('FTP удалён: ' . $ftp['username']);
                redirect('/?page=ftp');

            case 'create_db':
                $dbName = trim((string)($_POST['db_name'] ?? ''));
                $dbUser = trim((string)($_POST['db_user'] ?? ''));
                $password = (string)($_POST['password'] ?? '');
                $remote = !empty($_POST['remote_allowed']) ? '1' : '0';
                if (!is_valid_db_name($dbName) || !is_valid_db_name($dbUser)) {
                    throw new RuntimeException('Имя базы и пользователя: только латиница, цифры, _');
                }
                if (strlen($password) < 10) {
                    throw new RuntimeException('Пароль базы минимум 10 символов');
                }
                $result = run_ctl(['create-db', $dbName, $dbUser, $password, $remote]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                $stmt = db()->prepare('INSERT INTO databases(db_name, db_user, remote_allowed) VALUES(?, ?, ?) ON CONFLICT(db_name) DO UPDATE SET db_user = excluded.db_user, remote_allowed = excluded.remote_allowed');
                $stmt->execute([$dbName, $dbUser, (int)$remote]);
                add_event('db', 'Создана база: ' . $dbName);
                flash('База создана: ' . $dbName);
                redirect('/?page=databases');

            case 'delete_db':
                $id = (int)($_POST['id'] ?? 0);
                $stmt = db()->prepare('SELECT * FROM databases WHERE id = ?');
                $stmt->execute([$id]);
                $row = $stmt->fetch();
                if (!$row) {
                    throw new RuntimeException('База не найдена');
                }
                $result = run_ctl(['delete-db', $row['db_name'], $row['db_user']]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                db()->prepare('DELETE FROM databases WHERE id = ?')->execute([$id]);
                add_event('db', 'Удалена база: ' . $row['db_name']);
                flash('База удалена: ' . $row['db_name']);
                redirect('/?page=databases');

            case 'mysql_external':
                $state = (string)($_POST['state'] ?? 'disable');
                $state = $state === 'enable' ? 'enable' : 'disable';
                $result = run_ctl(['mysql-external', $state], 180);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                setting_set('mysql_external', $state === 'enable' ? '1' : '0');
                add_event('settings', 'Внешние подключения MySQL: ' . $state);
                flash($state === 'enable' ? 'Внешние подключения MySQL включены' : 'Внешние подключения MySQL выключены');
                redirect('/?page=settings');

            case 'create_bot':
                $name = trim((string)($_POST['name'] ?? ''));
                $runtime = trim((string)($_POST['runtime'] ?? 'python'));
                $command = trim((string)($_POST['start_command'] ?? ''));
                if (!is_valid_name($name)) {
                    throw new RuntimeException('Неверное имя бота');
                }
                if (!in_array($runtime, ['python', 'node', 'php', 'custom'], true)) {
                    throw new RuntimeException('Неверный runtime');
                }
                if ($command === '') {
                    throw new RuntimeException('Укажи команду запуска');
                }
                $result = run_ctl(['bot-create', $name, $runtime, $command]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                $path = rtrim(app_config('bots_dir'), '/') . '/' . $name;
                $stmt = db()->prepare('INSERT INTO bots(name, runtime, path, start_command) VALUES(?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET runtime = excluded.runtime, path = excluded.path, start_command = excluded.start_command');
                $stmt->execute([$name, $runtime, $path, $command]);
                add_event('bot', 'Создан бот: ' . $name);
                flash('Бот создан: ' . $name);
                redirect('/?page=bots');

            case 'bot_action':
                $id = (int)($_POST['id'] ?? 0);
                $botAction = (string)($_POST['bot_action'] ?? 'status');
                if (!in_array($botAction, ['start', 'stop', 'restart'], true)) {
                    throw new RuntimeException('Неверное действие');
                }
                $stmt = db()->prepare('SELECT * FROM bots WHERE id = ?');
                $stmt->execute([$id]);
                $bot = $stmt->fetch();
                if (!$bot) {
                    throw new RuntimeException('Бот не найден');
                }
                $result = run_ctl(['bot', $botAction, $bot['name']]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                add_event('bot', 'Бот ' . $botAction . ': ' . $bot['name']);
                flash('Команда выполнена: ' . $botAction . ' ' . $bot['name']);
                redirect('/?page=bots');

            case 'delete_bot':
                $id = (int)($_POST['id'] ?? 0);
                $mode = !empty($_POST['delete_files']) ? '--delete-files' : '--keep-files';
                $stmt = db()->prepare('SELECT * FROM bots WHERE id = ?');
                $stmt->execute([$id]);
                $bot = $stmt->fetch();
                if (!$bot) {
                    throw new RuntimeException('Бот не найден');
                }
                $result = run_ctl(['bot-delete', $bot['name'], $mode]);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                db()->prepare('DELETE FROM bots WHERE id = ?')->execute([$id]);
                add_event('bot', 'Удалён бот: ' . $bot['name']);
                flash('Бот удалён: ' . $bot['name']);
                redirect('/?page=bots');


            case 'sync_resources':
                $synced = sync_resources_from_server();
                add_event('sync', 'Синхронизация ресурсов: ' . $synced);
                flash('Синхронизация готова: ' . $synced);
                redirect($_SERVER['HTTP_REFERER'] ?? '/');

            case 'repair_panel':
                $result = run_ctl(['repair'], 180);
                if ($result['code'] !== 0) {
                    throw new RuntimeException($result['output']);
                }
                add_event('repair', 'Исправлены права, sudoers, FTP-порты и сервисы');
                flash("Ремонт выполнен.\n" . $result['output']);
                redirect('/?page=settings');

            case 'change_password':
                $current = (string)($_POST['current_password'] ?? '');
                $new = (string)($_POST['new_password'] ?? '');
                if (strlen($new) < 10) {
                    throw new RuntimeException('Новый пароль минимум 10 символов');
                }
                $user = current_user();
                $stmt = db()->prepare('SELECT * FROM users WHERE id = ?');
                $stmt->execute([(int)$user['id']]);
                $row = $stmt->fetch();
                if (!$row || !password_verify($current, $row['password_hash'])) {
                    throw new RuntimeException('Текущий пароль неверный');
                }
                $hash = password_hash($new, PASSWORD_DEFAULT);
                db()->prepare('UPDATE users SET password_hash = ? WHERE id = ?')->execute([$hash, (int)$user['id']]);
                add_event('settings', 'Пароль администратора изменён');
                flash('Пароль изменён');
                redirect('/?page=settings');
        }
    } catch (Throwable $e) {
        flash($e->getMessage(), 'err');
        $referer = $_SERVER['HTTP_REFERER'] ?? '/';
        redirect($referer);
    }
}


function sync_resources_from_server(): string
{
    $data = run_ctl_json(['sync-json'], 60);
    if (isset($data['_error'])) {
        throw new RuntimeException((string)$data['_error']);
    }
    $counts = ['sites' => 0, 'ftp' => 0, 'databases' => 0, 'bots' => 0];
    foreach (($data['sites'] ?? []) as $site) {
        if (!empty($site['domain']) && !empty($site['root_path'])) {
            upsert_site_row((string)$site['domain'], (string)($site['aliases'] ?? ''), (string)$site['root_path'], (int)($site['ssl_enabled'] ?? 0));
            $counts['sites']++;
        }
    }
    foreach (($data['ftp'] ?? []) as $ftp) {
        if (!empty($ftp['username']) && !empty($ftp['target_path'])) {
            upsert_ftp_row((string)$ftp['username'], (string)$ftp['target_path']);
            $counts['ftp']++;
        }
    }
    foreach (($data['databases'] ?? []) as $row) {
        if (!empty($row['db_name']) && !empty($row['db_user'])) {
            upsert_db_row((string)$row['db_name'], (string)$row['db_user'], (int)($row['remote_allowed'] ?? 0));
            $counts['databases']++;
        }
    }
    foreach (($data['bots'] ?? []) as $bot) {
        if (!empty($bot['name']) && !empty($bot['path'])) {
            upsert_bot_row((string)$bot['name'], (string)($bot['runtime'] ?? 'custom'), (string)$bot['path'], (string)($bot['start_command'] ?? ''));
            $counts['bots']++;
        }
    }
    return "сайты {$counts['sites']}, FTP {$counts['ftp']}, базы {$counts['databases']}, боты {$counts['bots']}";
}

function render_login(): void
{
    $flash = flash();
    ?>
<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>HYPER-HOST — вход</title>
    <link rel="stylesheet" href="/assets/style.css">
</head>
<body class="login-body">
    <main class="login-card">
        <div class="brand-mark">HH</div>
        <h1>HYPER-HOST</h1>
        <p>Личная панель хостинга сайтов и Telegram-ботов</p>
        <?php if ($flash): ?><div class="alert <?= e($flash['type']) ?>"><?= e($flash['message']) ?></div><?php endif; ?>
        <form method="post" class="form-grid">
            <input type="hidden" name="_csrf" value="<?= e(csrf_token()) ?>">
            <label>Логин<input name="username" autocomplete="username" required></label>
            <label>Пароль<input type="password" name="password" autocomplete="current-password" required></label>
            <button class="btn primary" type="submit">Войти</button>
        </form>
        <div class="powered">powered by memes4u1337</div>
    </main>
</body>
</html>
<?php
}

function render_page(string $page, array $user): void
{
    $allowed = ['dashboard', 'sites', 'ftp', 'databases', 'bots', 'bot_logs', 'settings'];
    if (!in_array($page, $allowed, true)) {
        $page = 'dashboard';
    }
    $flash = flash();
    ?>
<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>HYPER-HOST</title>
    <link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<div class="app">
    <aside class="sidebar">
        <div class="logo">
            <div class="brand-mark small">HH</div>
            <div><strong>HYPER-HOST</strong><span>powered by memes4u1337</span></div>
        </div>
        <nav>
            <?= nav_item('dashboard', '📊 Дашборд', $page) ?>
            <?= nav_item('sites', '🌐 Сайты', $page) ?>
            <?= nav_item('ftp', '📁 FTP', $page) ?>
            <?= nav_item('databases', '🗄️ Базы данных', $page) ?>
            <?= nav_item('bots', '🤖 Telegram-боты', $page) ?>
            <?= nav_item('settings', '⚙️ Настройки', $page) ?>
        </nav>
        <a class="logout" href="/?page=logout">Выйти</a>
    </aside>
    <main class="content">
        <header class="topbar">
            <div>
                <h1><?= e(page_title($page)) ?></h1>
                <p>Сервер: <?= e(app_config('server_ip')) ?> · Пользователь: <?= e($user['username']) ?></p>
            </div>
            <a class="btn ghost" href="/phpmyadmin" target="_blank">phpMyAdmin</a>
        </header>
        <?php if ($flash): ?><div class="alert <?= e($flash['type']) ?>"><?= nl2br(e($flash['message'])) ?></div><?php endif; ?>
        <?php
        match ($page) {
            'dashboard' => view_dashboard(),
            'sites' => view_sites(),
            'ftp' => view_ftp(),
            'databases' => view_databases(),
            'bots' => view_bots(),
            'bot_logs' => view_bot_logs(),
            'settings' => view_settings(),
            default => view_dashboard(),
        };
        ?>
    </main>
</div>
<script src="/assets/app.js"></script>
</body>
</html>
<?php
}

function nav_item(string $key, string $label, string $page): string
{
    $class = $key === $page ? 'active' : '';
    return '<a class="' . $class . '" href="/?page=' . e($key) . '">' . e($label) . '</a>';
}

function page_title(string $page): string
{
    return match ($page) {
        'sites' => 'Сайты и домены',
        'ftp' => 'FTP подключения',
        'databases' => 'Базы данных',
        'bots' => 'Telegram-боты',
        'bot_logs' => 'Логи бота',
        'settings' => 'Настройки сервера',
        default => 'Дашборд',
    };
}

function csrf_field(): string
{
    return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">';
}

function view_dashboard(): void
{
    $stats = run_ctl_json(['stats-json'], 25);
    $statErr = $stats['_error'] ?? null;
    $services = $stats['services'] ?? [];
    $paths = $stats['paths'] ?? [];
    $diskTotal = (float)($stats['disk_total'] ?? (@disk_total_space('/') ?: 0));
    $diskUsed = (float)($stats['disk_used'] ?? 0);
    if ($diskUsed <= 0 && $diskTotal > 0) {
        $diskUsed = $diskTotal - (float)(@disk_free_space('/') ?: 0);
    }
    $memTotal = (float)($stats['mem_total'] ?? 0);
    $memUsed = (float)($stats['mem_used'] ?? 0);
    $diskPct = percent($diskUsed, $diskTotal);
    $memPct = percent($memUsed, $memTotal);
    $dbStatus = db_writable_status();
    $events = db()->query('SELECT * FROM events ORDER BY id DESC LIMIT 12')->fetchAll();
    ?>
<section class="hero">
    <div>
        <span class="hero-kicker">HYPER-HOST CONTROL CENTER</span>
        <h2>Сервер под сайты и Telegram-ботов</h2>
        <p>IP: <code><?= e(app_config('server_ip')) ?></code> · uptime: <code><?= e((string)($stats['uptime'] ?? 'unknown')) ?></code></p>
    </div>
    <form method="post" class="hero-actions">
        <?= csrf_field() ?>
        <input type="hidden" name="action" value="sync_resources">
        <button class="btn primary" type="submit">Синхронизировать ресурсы</button>
        <a class="btn ghost" href="/?page=ftp">FTP подключения</a>
    </form>
</section>

<?php if ($statErr): ?>
    <div class="alert err">Статистика пока недоступна: <?= e((string)$statErr) ?></div>
<?php endif; ?>

<section class="grid cards4">
    <div class="card stat gradient"><span>Сайты</span><strong><?= table_count('sites') ?></strong><em><?= e(app_config('sites_dir')) ?></em></div>
    <div class="card stat gradient"><span>FTP</span><strong><?= table_count('ftp_accounts') ?></strong><em>порт 21 / passive 40000-40100</em></div>
    <div class="card stat gradient"><span>Базы</span><strong><?= table_count('databases') ?></strong><em>MariaDB + phpMyAdmin</em></div>
    <div class="card stat gradient"><span>Боты</span><strong><?= table_count('bots') ?></strong><em>systemd services</em></div>
</section>

<section class="grid two">
    <div class="card">
        <div class="split-head"><h2>Железо сервера</h2><span class="tag">live</span></div>
        <div class="status-row"><span>CPU</span><code><?= e((string)($stats['cpu_model'] ?? 'unknown')) ?></code></div>
        <div class="status-row"><span>Ядра</span><b><?= e((string)($stats['cpu_cores'] ?? '0')) ?></b></div>
        <div class="status-row"><span>Load average</span><code><?= e(number_format((float)($stats['load1'] ?? 0), 2)) ?> / <?= e(number_format((float)($stats['load5'] ?? 0), 2)) ?> / <?= e(number_format((float)($stats['load15'] ?? 0), 2)) ?></code></div>
        <div class="status-row"><span>RAM</span><b><?= e(human_bytes($memUsed)) ?> / <?= e(human_bytes($memTotal)) ?></b></div>
        <div class="meter big"><i style="width: <?= $memPct ?>%"></i></div>
    </div>
    <div class="card">
        <div class="split-head"><h2>Сервисы</h2><a class="btn tiny ghost" href="/?page=settings">ремонт</a></div>
        <?php foreach (['nginx' => 'Nginx', 'mariadb' => 'MariaDB', 'vsftpd' => 'FTP / VSFTPD', 'php_fpm' => 'PHP-FPM'] as $key => $label): $status = (string)($services[$key] ?? 'unknown'); ?>
            <div class="status-row"><span><?= e($label) ?></span><b class="pill <?= e($status) ?>"><?= e($status) ?></b></div>
        <?php endforeach; ?>
        <div class="status-row"><span>SQLite панели</span><b class="pill <?= $dbStatus['file_writable'] && $dbStatus['dir_writable'] ? 'active' : 'failed' ?>"><?= $dbStatus['file_writable'] && $dbStatus['dir_writable'] ? 'writable' : 'problem' ?></b></div>
        <div class="hint"><code><?= e($dbStatus['path']) ?></code></div>
    </div>
</section>

<section class="grid two">
    <div class="card">
        <h2>Диск</h2>
        <div class="meter big"><i style="width: <?= $diskPct ?>%"></i></div>
        <p class="muted">Использовано <?= e(human_bytes($diskUsed)) ?> из <?= e(human_bytes($diskTotal)) ?> · свободно <?= e(human_bytes((float)($stats['disk_free'] ?? 0))) ?></p>
        <div class="hint">Сайты: <code><?= e((string)($paths['sites'] ?? app_config('sites_dir'))) ?></code></div>
        <div class="hint">Боты: <code><?= e((string)($paths['bots'] ?? app_config('bots_dir'))) ?></code></div>
    </div>
    <div class="card quick-card">
        <h2>Быстрые действия</h2>
        <div class="quick-actions">
            <a class="btn primary" href="/?page=sites">Добавить сайт</a>
            <a class="btn primary" href="/?page=ftp">Создать FTP</a>
            <a class="btn primary" href="/?page=databases">Создать базу</a>
            <a class="btn primary" href="/?page=bots">Создать бота</a>
            <a class="btn ghost" href="/phpmyadmin" target="_blank">phpMyAdmin</a>
        </div>
    </div>
</section>

<section class="card">
    <h2>Последние события</h2>
    <div class="table-wrap">
        <table>
            <thead><tr><th>Дата</th><th>Тип</th><th>Событие</th></tr></thead>
            <tbody>
            <?php foreach ($events as $event): ?>
                <tr><td><?= e($event['created_at']) ?></td><td><span class="tag"><?= e($event['type']) ?></span></td><td><?= e($event['message']) ?></td></tr>
            <?php endforeach; ?>
            <?php if (!$events): ?><tr><td colspan="3" class="empty">Событий пока нет</td></tr><?php endif; ?>
            </tbody>
        </table>
    </div>
</section>
<?php
}

function view_sites(): void
{
    $sites = db()->query('SELECT * FROM sites ORDER BY id DESC')->fetchAll();
    ?>
<section class="grid two">
    <div class="card">
        <h2>Добавить сайт</h2>
        <form method="post" class="form-grid">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="add_site">
            <label>Домен<input name="domain" placeholder="example.com" required></label>
            <label>Alias через запятую<input name="aliases" placeholder="www.example.com, api.example.com"></label>
            <button class="btn primary" type="submit">Создать сайт</button>
        </form>
        <p class="muted">Папка сайта будет создана автоматически в <code><?= e(app_config('sites_dir')) ?>/domain/public_html</code>.</p>
    </div>
    <div class="card accent-card">
        <h2>Как привязать домен</h2>
        <p>В DNS создай A-запись на IP сервера:</p>
        <div class="copy-line"><code><?= e(app_config('server_ip')) ?></code><button class="btn tiny" data-copy="<?= e(app_config('server_ip')) ?>">копировать</button></div>
        <p class="muted">После обновления DNS добавь домен тут. Nginx-конфиг создастся сам.</p>
    </div>
</section>

<section class="card">
    <h2>Сайты</h2>
    <div class="table-wrap">
        <table>
            <thead><tr><th>Домен</th><th>Alias</th><th>Папка</th><th>SSL</th><th>Дата</th><th></th></tr></thead>
            <tbody>
            <?php foreach ($sites as $site): ?>
                <tr>
                    <td><a href="http://<?= e($site['domain']) ?>" target="_blank"><?= e($site['domain']) ?></a></td>
                    <td><?= e($site['aliases'] ?: '—') ?></td>
                    <td><code><?= e($site['root_path']) ?></code></td>
                    <td><?= (int)$site['ssl_enabled'] ? '<span class="pill active">on</span>' : '<span class="pill inactive">off</span>' ?></td>
                    <td><?= e($site['created_at']) ?></td>
                    <td class="actions">
                        <details class="dropdown">
                            <summary class="btn tiny">действия</summary>
                            <form method="post">
                                <?= csrf_field() ?>
                                <input type="hidden" name="action" value="ssl_site">
                                <input type="hidden" name="id" value="<?= (int)$site['id'] ?>">
                                <input name="email" placeholder="email для SSL" required>
                                <button class="btn tiny primary" type="submit">SSL</button>
                            </form>
                            <form method="post" onsubmit="return confirm('Удалить сайт?');">
                                <?= csrf_field() ?>
                                <input type="hidden" name="action" value="delete_site">
                                <input type="hidden" name="id" value="<?= (int)$site['id'] ?>">
                                <label class="check"><input type="checkbox" name="delete_files" value="1"> удалить файлы</label>
                                <button class="btn tiny danger" type="submit">удалить</button>
                            </form>
                        </details>
                    </td>
                </tr>
            <?php endforeach; ?>
            <?php if (!$sites): ?><tr><td colspan="6" class="empty">Сайтов пока нет</td></tr><?php endif; ?>
            </tbody>
        </table>
    </div>
</section>
<?php
}

function available_targets(): array
{
    $targets = [];
    $sites = db()->query('SELECT domain, root_path FROM sites ORDER BY domain')->fetchAll();
    foreach ($sites as $site) {
        $targets[] = ['label' => 'Сайт: ' . $site['domain'], 'path' => $site['root_path']];
    }
    $bots = db()->query('SELECT name, path FROM bots ORDER BY name')->fetchAll();
    foreach ($bots as $bot) {
        $targets[] = ['label' => 'Бот: ' . $bot['name'], 'path' => $bot['path']];
    }
    return $targets;
}

function view_ftp(): void
{
    $accounts = db()->query('SELECT * FROM ftp_accounts ORDER BY id DESC')->fetchAll();
    $targets = available_targets();
    $ftpStatus = system_service_status('vsftpd');
    $host = app_config('server_ip');
    ?>
<section class="hero small-hero">
    <div>
        <span class="hero-kicker">FTP ACCESS</span>
        <h2>FTP подключения к сайтам и ботам</h2>
        <p>Host: <code><?= e($host) ?></code> · Port: <code>21</code> · Passive: <code>40000-40100</code></p>
    </div>
    <form method="post" class="hero-actions">
        <?= csrf_field() ?>
        <input type="hidden" name="action" value="sync_resources">
        <button class="btn ghost" type="submit">Обновить список FTP</button>
    </form>
</section>

<section class="grid three">
    <div class="card mini"><span>Статус FTP</span><b class="pill <?= e($ftpStatus) ?>"><?= e($ftpStatus) ?></b></div>
    <div class="card mini"><span>Хост</span><code><?= e($host) ?></code></div>
    <div class="card mini"><span>Порты</span><code>21, 40000-40100</code></div>
</section>

<section class="grid two">
    <div class="card">
        <h2>Создать FTP</h2>
        <form method="post" class="form-grid">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="create_ftp">
            <label>Логин <span class="muted">без префикса, панель сама добавит hhftp_</span><input name="username" placeholder="site_user" required></label>
            <label>Пароль<input name="password" type="password" minlength="8" required></label>
            <label>Папка
                <select name="target_path" required>
                    <?php foreach ($targets as $target): ?>
                        <option value="<?= e($target['path']) ?>"><?= e($target['label'] . ' — ' . $target['path']) ?></option>
                    <?php endforeach; ?>
                </select>
            </label>
            <?php if (!$targets): ?><p class="muted">Сначала создай сайт или бота, потом тут появится папка для FTP.</p><?php endif; ?>
            <button class="btn primary" type="submit" <?= !$targets ? 'disabled' : '' ?>>Создать FTP</button>
        </form>
    </div>
    <div class="card accent-card">
        <h2>Как подключаться</h2>
        <div class="connect-box">
            <div><span>Protocol</span><code>FTP</code></div>
            <div><span>Host</span><code><?= e($host) ?></code><button class="btn tiny" data-copy="<?= e($host) ?>">копировать</button></div>
            <div><span>Port</span><code>21</code></div>
            <div><span>Passive mode</span><code>ON</code></div>
            <div><span>Passive ports</span><code>40000-40100</code></div>
        </div>
        <p class="muted">В FileZilla / WinSCP выбирай обычный FTP. Логин будет вида <code>hhftp_site_user</code>.</p>
    </div>
</section>

<section class="card">
    <div class="split-head">
        <h2>FTP аккаунты</h2>
        <span class="tag"><?= count($accounts) ?> шт.</span>
    </div>
    <div class="table-wrap">
        <table>
            <thead><tr><th>Логин</th><th>Подключение</th><th>Папка</th><th>Дата</th><th></th></tr></thead>
            <tbody>
            <?php foreach ($accounts as $acc): $line = 'ftp://' . $acc['username'] . '@' . $host . ':21'; ?>
                <tr>
                    <td><code><?= e($acc['username']) ?></code></td>
                    <td><div class="copy-line"><code><?= e($line) ?></code><button class="btn tiny" data-copy="<?= e($line) ?>">копировать</button></div></td>
                    <td><code><?= e($acc['target_path']) ?></code></td>
                    <td><?= e($acc['created_at']) ?></td>
                    <td>
                        <form method="post" onsubmit="return confirm('Удалить FTP? Файлы не удаляются.');">
                            <?= csrf_field() ?>
                            <input type="hidden" name="action" value="delete_ftp">
                            <input type="hidden" name="id" value="<?= (int)$acc['id'] ?>">
                            <button class="btn tiny danger" type="submit">удалить</button>
                        </form>
                    </td>
                </tr>
            <?php endforeach; ?>
            <?php if (!$accounts): ?><tr><td colspan="5" class="empty">FTP аккаунтов пока нет. Создай сайт, потом создай FTP к его public_html.</td></tr><?php endif; ?>
            </tbody>
        </table>
    </div>
</section>
<?php
}

function view_databases(): void
{
    $rows = db()->query('SELECT * FROM databases ORDER BY id DESC')->fetchAll();
    ?>
<section class="grid two">
    <div class="card">
        <h2>Создать базу</h2>
        <form method="post" class="form-grid">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="create_db">
            <label>Имя базы<input name="db_name" placeholder="hh_site_db" required></label>
            <label>Пользователь<input name="db_user" placeholder="hh_site_user" required></label>
            <label>Пароль<input name="password" type="password" minlength="10" required></label>
            <label class="check"><input type="checkbox" name="remote_allowed" value="1"> Разрешить внешний доступ для этого пользователя</label>
            <button class="btn primary" type="submit">Создать базу</button>
        </form>
    </div>
    <div class="card accent-card">
        <h2>phpMyAdmin</h2>
        <p>Открыть phpMyAdmin можно тут:</p>
        <p><a class="btn primary" href="/phpmyadmin" target="_blank">Открыть phpMyAdmin</a></p>
        <p class="muted">Для внешнего доступа нужно включить его в настройках и открыть доступ у пользователя базы.</p>
    </div>
</section>

<section class="card">
    <h2>Базы данных</h2>
    <div class="table-wrap">
        <table>
            <thead><tr><th>База</th><th>Пользователь</th><th>Внешний доступ</th><th>Дата</th><th></th></tr></thead>
            <tbody>
            <?php foreach ($rows as $row): ?>
                <tr>
                    <td><code><?= e($row['db_name']) ?></code></td>
                    <td><code><?= e($row['db_user']) ?></code></td>
                    <td><?= (int)$row['remote_allowed'] ? '<span class="pill active">allowed</span>' : '<span class="pill inactive">local</span>' ?></td>
                    <td><?= e($row['created_at']) ?></td>
                    <td>
                        <form method="post" onsubmit="return confirm('Удалить базу и пользователя?');">
                            <?= csrf_field() ?>
                            <input type="hidden" name="action" value="delete_db">
                            <input type="hidden" name="id" value="<?= (int)$row['id'] ?>">
                            <button class="btn tiny danger" type="submit">удалить</button>
                        </form>
                    </td>
                </tr>
            <?php endforeach; ?>
            <?php if (!$rows): ?><tr><td colspan="5" class="empty">Баз пока нет</td></tr><?php endif; ?>
            </tbody>
        </table>
    </div>
</section>
<?php
}

function view_bots(): void
{
    $bots = db()->query('SELECT * FROM bots ORDER BY id DESC')->fetchAll();
    ?>
<section class="grid two">
    <div class="card">
        <h2>Добавить Telegram-бота</h2>
        <form method="post" class="form-grid">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="create_bot">
            <label>Имя бота<input name="name" placeholder="mybot" required></label>
            <label>Runtime
                <select name="runtime">
                    <option value="python">Python</option>
                    <option value="node">Node.js</option>
                    <option value="php">PHP</option>
                    <option value="custom">Custom</option>
                </select>
            </label>
            <label>Команда запуска<input name="start_command" placeholder="python3 main.py" required></label>
            <button class="btn primary" type="submit">Создать бота</button>
        </form>
    </div>
    <div class="card accent-card">
        <h2>Как это работает</h2>
        <p>Панель создаёт папку и systemd-сервис:</p>
        <p><code><?= e(app_config('bots_dir')) ?>/имя_бота</code></p>
        <p class="muted">Код бота загружаешь через FTP, потом запускаешь кнопкой «Старт».</p>
    </div>
</section>

<section class="card">
    <h2>Боты</h2>
    <div class="table-wrap">
        <table>
            <thead><tr><th>Имя</th><th>Runtime</th><th>Статус</th><th>Папка</th><th>Команда</th><th></th></tr></thead>
            <tbody>
            <?php foreach ($bots as $bot): $status = system_service_status('hyperbot-' . $bot['name']); ?>
                <tr>
                    <td><code><?= e($bot['name']) ?></code></td>
                    <td><span class="tag"><?= e($bot['runtime']) ?></span></td>
                    <td><span class="pill <?= e($status) ?>"><?= e($status) ?></span></td>
                    <td><code><?= e($bot['path']) ?></code></td>
                    <td><code><?= e($bot['start_command']) ?></code></td>
                    <td class="actions bot-actions">
                        <?php foreach (['start' => 'Старт', 'stop' => 'Стоп', 'restart' => 'Рестарт'] as $cmd => $label): ?>
                            <form method="post">
                                <?= csrf_field() ?>
                                <input type="hidden" name="action" value="bot_action">
                                <input type="hidden" name="id" value="<?= (int)$bot['id'] ?>">
                                <input type="hidden" name="bot_action" value="<?= e($cmd) ?>">
                                <button class="btn tiny" type="submit"><?= e($label) ?></button>
                            </form>
                        <?php endforeach; ?>
                        <a class="btn tiny ghost" href="/?page=bot_logs&id=<?= (int)$bot['id'] ?>">логи</a>
                        <form method="post" onsubmit="return confirm('Удалить бота?');">
                            <?= csrf_field() ?>
                            <input type="hidden" name="action" value="delete_bot">
                            <input type="hidden" name="id" value="<?= (int)$bot['id'] ?>">
                            <label class="check tiny-check"><input type="checkbox" name="delete_files" value="1"> файлы</label>
                            <button class="btn tiny danger" type="submit">удалить</button>
                        </form>
                    </td>
                </tr>
            <?php endforeach; ?>
            <?php if (!$bots): ?><tr><td colspan="6" class="empty">Ботов пока нет</td></tr><?php endif; ?>
            </tbody>
        </table>
    </div>
</section>
<?php
}

function view_bot_logs(): void
{
    $id = (int)($_GET['id'] ?? 0);
    $stmt = db()->prepare('SELECT * FROM bots WHERE id = ?');
    $stmt->execute([$id]);
    $bot = $stmt->fetch();
    if (!$bot) {
        echo '<section class="card"><p class="empty">Бот не найден</p></section>';
        return;
    }
    $result = run_ctl(['bot', 'logs', $bot['name']], 20);
    ?>
<section class="card">
    <div class="split-head">
        <h2>Логи: <?= e($bot['name']) ?></h2>
        <a class="btn ghost" href="/?page=bots">Назад</a>
    </div>
    <pre class="logs"><?= e($result['output'] ?: 'Логов пока нет') ?></pre>
</section>
<?php
}

function view_settings(): void
{
    $mysqlExternal = setting_get('mysql_external', '0');
    $dbStatus = db_writable_status();
    ?>
<section class="grid two">
    <div class="card">
        <h2>Внешние подключения MySQL</h2>
        <p>Текущий статус: <?= $mysqlExternal === '1' ? '<span class="pill active">включено</span>' : '<span class="pill inactive">выключено</span>' ?></p>
        <form method="post" class="inline-form">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="mysql_external">
            <input type="hidden" name="state" value="<?= $mysqlExternal === '1' ? 'disable' : 'enable' ?>">
            <button class="btn <?= $mysqlExternal === '1' ? 'danger' : 'primary' ?>" type="submit">
                <?= $mysqlExternal === '1' ? 'Выключить внешний доступ' : 'Включить внешний доступ' ?>
            </button>
        </form>
        <p class="muted">Команда меняет bind-address MariaDB и открывает/закрывает порт 3306 в UFW.</p>
    </div>
    <div class="card">
        <h2>Ремонт панели</h2>
        <p class="muted">Если кнопки не сохраняют, FTP не показывается или права слетели — нажми ремонт. Он чинит права SQLite, sudoers, FTP-порты и перезапускает сервисы.</p>
        <form method="post" class="inline-form" onsubmit="return confirm('Запустить ремонт панели?');">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="repair_panel">
            <button class="btn primary" type="submit">Починить права и сервисы</button>
        </form>
        <form method="post" class="inline-form" style="margin-top:10px">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="sync_resources">
            <button class="btn ghost" type="submit">Синхронизировать сайты / FTP / базы / боты</button>
        </form>
    </div>
</section>

<section class="grid two">
    <div class="card">
        <h2>Сменить пароль панели</h2>
        <form method="post" class="form-grid">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="change_password">
            <label>Текущий пароль<input type="password" name="current_password" required></label>
            <label>Новый пароль<input type="password" name="new_password" minlength="10" required></label>
            <button class="btn primary" type="submit">Сменить пароль</button>
        </form>
    </div>
    <div class="card">
        <h2>SQLite панели</h2>
        <div class="status-row"><span>Файл</span><b class="pill <?= $dbStatus['file_writable'] ? 'active' : 'failed' ?>"><?= $dbStatus['file_writable'] ? 'writable' : 'not writable' ?></b></div>
        <div class="status-row"><span>Папка</span><b class="pill <?= $dbStatus['dir_writable'] ? 'active' : 'failed' ?>"><?= $dbStatus['dir_writable'] ? 'writable' : 'not writable' ?></b></div>
        <div class="hint"><code><?= e($dbStatus['path']) ?></code></div>
    </div>
</section>

<section class="card">
    <h2>Системная информация</h2>
    <div class="settings-grid">
        <div><span>Панель</span><code>HYPER-HOST</code></div>
        <div><span>Разработчик</span><code>powered by memes4u1337</code></div>
        <div><span>IP</span><code><?= e(app_config('server_ip')) ?></code></div>
        <div><span>Папка панели</span><code><?= e(app_config('panel_dir')) ?></code></div>
        <div><span>Папка сайтов</span><code><?= e(app_config('sites_dir')) ?></code></div>
        <div><span>Папка ботов</span><code><?= e(app_config('bots_dir')) ?></code></div>
    </div>
</section>
<?php
}
