<?php
declare(strict_types=1);

/**
 * HYPER-HOST CP — клиентский портал (cp.hyper-host.pw).
 * powered by memes4u1337
 *
 * Полностью изолированное приложение: свой системный пользователь (hypercp),
 * свой PHP-FPM pool, своя база. Доступа к базе и конфигу админ-панели нет.
 * Любое привилегированное действие идёт только через /usr/local/sbin/hyper-cp-bridge.
 */

ini_set('session.use_strict_mode', '1');
ini_set('session.use_only_cookies', '1');
session_name('HYPERCPSESSID');

$cpSecureCookie = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
    || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https')
    || ((int)($_SERVER['SERVER_PORT'] ?? 0) === 443);

session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/',
    'domain' => '',
    'secure' => $cpSecureCookie,
    'httponly' => true,
    'samesite' => 'Lax',
]);
session_start();

if (!isset($_SESSION['cp_started_at'])) $_SESSION['cp_started_at'] = time();
if (!isset($_SESSION['cp_last_seen'])) $_SESSION['cp_last_seen'] = time();
if ((time() - (int)$_SESSION['cp_last_seen']) > 28800 || (time() - (int)$_SESSION['cp_started_at']) > 86400) {
    $_SESSION = [];
    session_regenerate_id(true);
    $_SESSION['cp_started_at'] = time();
}
$_SESSION['cp_last_seen'] = time();
date_default_timezone_set('Europe/Moscow');

$cpConfig = [
    'db_path'      => '/var/lib/hyper-host-cp/cp.sqlite',
    'clients_root' => '/var/www/hyper-host-clients',
    'base_domain'  => 'hyper-host.pw',
    'cp_url'       => 'https://cp.hyper-host.pw',
    'bridge'       => '/usr/local/sbin/hyper-cp-bridge',
];
if (is_file('/etc/hyper-host/cp.php')) {
    $extra = require '/etc/hyper-host/cp.php';
    if (is_array($extra)) $cpConfig = array_replace($cpConfig, $extra);
}

set_exception_handler(static function (Throwable $e): void {
    error_log('HYPER-CP fatal: ' . $e->getMessage() . ' @ ' . $e->getFile() . ':' . $e->getLine());
    if (!headers_sent()) { http_response_code(500); header('Content-Type: text/html; charset=utf-8'); }
    echo '<!doctype html><meta charset="utf-8"><title>Ошибка</title>'
       . '<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#060912;color:#eaf0ff;'
       . 'font:15px/1.6 system-ui,sans-serif;padding:24px}.b{max-width:520px;background:#0d1322;'
       . 'border:1px solid rgba(150,170,220,.18);border-radius:18px;padding:32px}h1{font-size:19px;margin:0 0 10px}'
       . 'p{color:#8b98bd;margin:0}code{background:rgba(0,0,0,.4);padding:2px 7px;border-radius:6px;color:#2ee6ff}</style>'
       . '<div class="b"><h1>Панель временно недоступна</h1>'
       . '<p>Внутренняя ошибка. Администратору: <code>sudo bash doctor.sh --fix</code></p></div>';
    exit;
});

function cp_config(?string $key = null, mixed $default = null): mixed
{
    global $cpConfig;
    if ($key === null) return $cpConfig;
    return $cpConfig[$key] ?? $default;
}

function e(?string $v): string { return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function redirect(string $p): never { header('Location: ' . $p); exit; }

function human_bytes(float $bytes): string
{
    $u = ['B','KB','MB','GB','TB']; $i = 0;
    while ($bytes >= 1024 && $i < 4) { $bytes /= 1024; $i++; }
    return rtrim(rtrim(number_format($bytes, $i === 0 ? 0 : 1, '.', ''), '0'), '.') . ' ' . $u[$i];
}

function percent(float $used, float $total): int
{
    if ($total <= 0) return 0;
    return max(0, min(100, (int)round($used / $total * 100)));
}

// ---------------------------------------------------------------- база

function cp_db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) return $pdo;
    $path = (string)cp_config('db_path');
    if (!is_dir(dirname($path))) @mkdir(dirname($path), 02770, true);
    $pdo = new PDO('sqlite:' . $path);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
    $pdo->exec('PRAGMA foreign_keys=ON');
    $pdo->exec('PRAGMA journal_mode=WAL');
    $pdo->exec('PRAGMA busy_timeout=10000');
    cp_init_schema($pdo);
    return $pdo;
}

function cp_init_schema(PDO $db): void
{
    static $done = false; if ($done) return; $done = true;

    $db->exec("CREATE TABLE IF NOT EXISTS cp_users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL COLLATE NOCASE UNIQUE,
        email TEXT NOT NULL DEFAULT '',
        password_hash TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        ftp_password TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        last_login_at TEXT NULL
    )");

    $db->exec("CREATE TABLE IF NOT EXISTS cp_quotas (
        user_id INTEGER PRIMARY KEY,
        max_sites INTEGER NOT NULL DEFAULT 0,
        max_bots INTEGER NOT NULL DEFAULT 0,
        cpu_percent INTEGER NOT NULL DEFAULT 0,
        memory_mb INTEGER NOT NULL DEFAULT 0,
        disk_mb INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )");

    $db->exec("CREATE TABLE IF NOT EXISTS cp_sites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        domain TEXT NOT NULL UNIQUE,
        root_path TEXT NOT NULL,
        ssl_enabled INTEGER NOT NULL DEFAULT 0,
        ssl_expires TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )");

    $db->exec("CREATE TABLE IF NOT EXISTS cp_bots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        runtime TEXT NOT NULL DEFAULT 'python',
        unit_name TEXT NOT NULL,
        path TEXT NOT NULL,
        start_command TEXT NOT NULL,
        cpu_percent INTEGER NOT NULL DEFAULT 0,
        memory_mb INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, name)
    )");

    $db->exec("CREATE TABLE IF NOT EXISTS cp_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NULL, type TEXT NOT NULL, message TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )");
    $db->exec("CREATE INDEX IF NOT EXISTS idx_cp_events_user ON cp_events(user_id, id DESC)");

    $db->exec("CREATE TABLE IF NOT EXISTS cp_auth_attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT, login_key TEXT NOT NULL,
        success INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
    )");
    $db->exec("CREATE INDEX IF NOT EXISTS idx_cp_attempts ON cp_auth_attempts(login_key, created_at)");
}

// ---------------------------------------------------------------- csrf / flash

function csrf_token(): string
{
    if (empty($_SESSION['cp_csrf'])) $_SESSION['cp_csrf'] = bin2hex(random_bytes(32));
    return (string)$_SESSION['cp_csrf'];
}

function csrf_field(): string
{
    return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">';
}

function check_csrf(): void
{
    $t = (string)($_POST['_csrf'] ?? '');
    if ($t === '' || !hash_equals((string)($_SESSION['cp_csrf'] ?? ''), $t)) {
        http_response_code(419);
        exit('Сессия устарела. Обновите страницу.');
    }
}

function flash(?string $message = null, string $type = 'ok'): ?array
{
    if ($message !== null) { $_SESSION['cp_flash'] = ['message' => $message, 'type' => $type]; return null; }
    $f = $_SESSION['cp_flash'] ?? null; unset($_SESSION['cp_flash']);
    return is_array($f) ? $f : null;
}

function cp_event(string $type, string $message, ?int $userId = null): void
{
    try {
        $userId ??= (int)(current_user()['id'] ?? 0);
        cp_db()->prepare("INSERT INTO cp_events(user_id,type,message,created_at) VALUES(?,?,?,datetime('now','localtime'))")
               ->execute([$userId ?: null, $type, mb_substr($message, 0, 500)]);
    } catch (Throwable) {}
}

// ---------------------------------------------------------------- мост в root

/**
 * Единственная точка привилегированных операций. Payload уходит в stdin как JSON,
 * ответ читается из stdout. Никаких shell-строк здесь не собирается — это
 * исключает инъекции через доменное имя или имя бота.
 */
function cp_bridge(array $payload, int $timeout = 300): array
{
    $bridge = (string)cp_config('bridge');
    if (!is_executable($bridge)) {
        return ['ok' => false, 'error' => 'Служебный мост не установлен. Сообщите администратору.'];
    }
    $spec = [0 => ['pipe','r'], 1 => ['pipe','w'], 2 => ['pipe','w']];
    $proc = @proc_open(['/usr/bin/sudo','-n',$bridge], $spec, $pipes, null, ['PATH' => '/usr/sbin:/usr/bin:/sbin:/bin']);
    if (!is_resource($proc)) return ['ok' => false, 'error' => 'Не удалось запустить служебный мост'];

    fwrite($pipes[0], json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $out = ''; $err = ''; $start = time();
    while (true) {
        $out .= (string)stream_get_contents($pipes[1]);
        $err .= (string)stream_get_contents($pipes[2]);
        $st = proc_get_status($proc);
        if (!$st['running']) break;
        if (time() - $start > $timeout) { proc_terminate($proc, 9); break; }
        usleep(80000);
    }
    $out .= (string)stream_get_contents($pipes[1]);
    $err .= (string)stream_get_contents($pipes[2]);
    fclose($pipes[1]); fclose($pipes[2]); proc_close($proc);

    $data = json_decode(trim($out), true);
    if (!is_array($data)) {
        error_log('HYPER-CP bridge bad answer: ' . trim($err ?: $out));
        return ['ok' => false, 'error' => 'Служебный мост вернул некорректный ответ'];
    }
    return $data;
}

// ---------------------------------------------------------------- пользователи

function cp_user_by_id(int $id): ?array
{
    $st = cp_db()->prepare('SELECT * FROM cp_users WHERE id=? LIMIT 1');
    $st->execute([$id]);
    $r = $st->fetch();
    return is_array($r) ? $r : null;
}

function cp_user_by_name(string $name): ?array
{
    $st = cp_db()->prepare('SELECT * FROM cp_users WHERE lower(username)=lower(?) LIMIT 1');
    $st->execute([$name]);
    $r = $st->fetch();
    return is_array($r) ? $r : null;
}

function current_user(): ?array
{
    $id = (int)($_SESSION['cp_user_id'] ?? 0);
    if ($id < 1) return null;
    $u = cp_user_by_id($id);
    if (!$u) { unset($_SESSION['cp_user_id']); return null; }
    if ((string)$u['status'] === 'suspended') { unset($_SESSION['cp_user_id']); return null; }
    return $u;
}

function require_auth(): array
{
    $u = current_user();
    if (!$u) redirect('/?page=login');
    return $u;
}

function cp_quota(int $userId): array
{
    $st = cp_db()->prepare('SELECT * FROM cp_quotas WHERE user_id=?');
    $st->execute([$userId]);
    $q = $st->fetch();
    if (!is_array($q)) {
        $q = ['user_id'=>$userId,'max_sites'=>0,'max_bots'=>0,'cpu_percent'=>0,'memory_mb'=>0,'disk_mb'=>0];
    }
    return $q;
}

/** Пока администратор ничего не выдал — портал показывает заглушку, а не пустые вкладки. */
function cp_has_resources(array $quota): bool
{
    return ((int)$quota['max_sites'] + (int)$quota['max_bots']) > 0;
}

function cp_auth_key(string $username): string
{
    return hash('sha256', strtolower(trim($username)) . '|' . ($_SERVER['REMOTE_ADDR'] ?? 'unknown'));
}

function cp_auth_guard(string $username): void
{
    $db = cp_db(); $key = cp_auth_key($username); $now = time();
    $db->prepare('DELETE FROM cp_auth_attempts WHERE created_at < ?')->execute([$now - 86400]);
    $st = $db->prepare('SELECT COUNT(*) FROM cp_auth_attempts WHERE login_key=? AND success=0 AND created_at>=?');
    $st->execute([$key, $now - 900]);
    if ((int)$st->fetchColumn() >= 8) throw new RuntimeException('Слишком много попыток входа. Попробуйте через несколько минут.');
}

function cp_auth_record(string $username, bool $ok): void
{
    $db = cp_db(); $key = cp_auth_key($username);
    if ($ok) { $db->prepare('DELETE FROM cp_auth_attempts WHERE login_key=?')->execute([$key]); return; }
    $db->prepare('INSERT INTO cp_auth_attempts(login_key,success,created_at) VALUES(?,0,?)')->execute([$key, time()]);
}

function cp_login(string $username, string $password): array
{
    $username = trim($username);
    if ($username === '' || $password === '') throw new RuntimeException('Введите логин и пароль');
    cp_auth_guard($username);
    $u = cp_user_by_name($username);
    if (!$u || !password_verify($password, (string)$u['password_hash'])) {
        cp_auth_record($username, false);
        throw new RuntimeException('Неверный логин или пароль');
    }
    if ((string)$u['status'] === 'suspended') throw new RuntimeException('Аккаунт заблокирован администратором');
    cp_db()->prepare("UPDATE cp_users SET last_login_at=datetime('now','localtime') WHERE id=?")->execute([(int)$u['id']]);
    $_SESSION['cp_user_id'] = (int)$u['id'];
    session_regenerate_id(true);
    $_SESSION['cp_started_at'] = time();
    $_SESSION['cp_last_seen'] = time();
    cp_auth_record($username, true);
    cp_event('auth', 'Вход в панель', (int)$u['id']);
    return cp_user_by_id((int)$u['id']) ?? $u;
}

function cp_register(string $username, string $email, string $password, string $password2): array
{
    $username = strtolower(trim($username));
    $email = trim($email);

    // Логин клиента становится именем его папки и FTP-аккаунта — правила жёсткие.
    if (!preg_match('/^[a-z][a-z0-9_-]{2,23}$/', $username)) {
        throw new RuntimeException('Логин: 3–24 символа, начинается с буквы, только латиница, цифры, _ и -');
    }
    if (in_array($username, ['root','admin','www','www-data','ftp','mysql','nginx','hypercp','hypercloud','panel','cloud','cp'], true)) {
        throw new RuntimeException('Этот логин зарезервирован');
    }
    if ($email !== '' && !filter_var($email, FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Некорректный e-mail');
    if (strlen($password) < 10) throw new RuntimeException('Пароль должен быть не короче 10 символов');
    if (!hash_equals($password, $password2)) throw new RuntimeException('Пароли не совпадают');
    if (cp_user_by_name($username)) throw new RuntimeException('Этот логин уже занят');

    // Мост проверяет, что такого системного/FTP аккаунта ещё нет.
    $check = cp_bridge(['action' => 'user-available', 'user' => $username], 30);
    if (empty($check['ok'])) throw new RuntimeException((string)($check['error'] ?? 'Логин недоступен'));

    $db = cp_db();
    $ftpPassword = bin2hex(random_bytes(9));
    $db->prepare("INSERT INTO cp_users(username,email,password_hash,status,ftp_password) VALUES(?,?,?,'pending',?)")
       ->execute([$username, $email, password_hash($password, PASSWORD_DEFAULT), $ftpPassword]);
    $id = (int)$db->lastInsertId();
    $db->prepare('INSERT INTO cp_quotas(user_id) VALUES(?)')->execute([$id]);

    // Папку и FTP создаём сразу — клиент сможет положить файлы ещё до выдачи ресурсов.
    $init = cp_bridge(['action' => 'user-init', 'user' => $username, 'ftp_password' => $ftpPassword], 180);
    if (empty($init['ok'])) cp_event('warn', 'Каталог не создан: ' . (string)($init['error'] ?? ''), $id);

    $_SESSION['cp_user_id'] = $id;
    session_regenerate_id(true);
    $_SESSION['cp_started_at'] = time();
    $_SESSION['cp_last_seen'] = time();
    cp_event('auth', 'Регистрация аккаунта', $id);
    return cp_user_by_id($id) ?? throw new RuntimeException('Не удалось создать аккаунт');
}

function cp_logout(): never
{
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
    }
    session_destroy();
    redirect('/?page=login');
}

// ---------------------------------------------------------------- валидация

function cp_valid_domain(string $d): bool
{
    return (bool)preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/', $d);
}

function cp_valid_bot_name(string $n): bool
{
    return (bool)preg_match('/^[a-z0-9][a-z0-9_-]{1,31}$/', $n);
}

function cp_user_root(array $user): string
{
    return rtrim((string)cp_config('clients_root'), '/') . '/' . (string)$user['username'];
}

function cp_sites(int $userId): array
{
    $st = cp_db()->prepare('SELECT * FROM cp_sites WHERE user_id=? ORDER BY id DESC');
    $st->execute([$userId]);
    return $st->fetchAll();
}

function cp_bots(int $userId): array
{
    $st = cp_db()->prepare('SELECT * FROM cp_bots WHERE user_id=? ORDER BY id DESC');
    $st->execute([$userId]);
    return $st->fetchAll();
}

function cp_events(int $userId, int $limit = 60): array
{
    $st = cp_db()->prepare('SELECT * FROM cp_events WHERE user_id=? ORDER BY id DESC LIMIT ?');
    $st->execute([$userId, $limit]);
    return $st->fetchAll();
}

/** Живое потребление: диск клиента и состояние каждого systemd-юнита. */
function cp_usage(array $user): array
{
    $r = cp_bridge(['action' => 'usage', 'user' => (string)$user['username']], 30);
    return !empty($r['ok']) ? $r : ['ok' => false, 'disk_bytes' => 0, 'units' => []];
}
