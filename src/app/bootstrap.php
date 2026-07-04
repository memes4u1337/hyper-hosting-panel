<?php
declare(strict_types=1);

session_name('HYPERHOSTSESSID');
session_start();

$configFile = __DIR__ . '/config.php';
if (!is_file($configFile)) {
    http_response_code(500);
    echo 'HYPER-HOST config.php not found. Run install.sh first.';
    exit;
}

$config = require $configFile;

date_default_timezone_set('Europe/Moscow');

function app_config(?string $key = null, mixed $default = null): mixed
{
    global $config;
    if ($key === null) {
        return $config;
    }
    return $config[$key] ?? $default;
}

function db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }
    $path = app_config('db_path');
    $pdo = new PDO('sqlite:' . $path);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
    $pdo->exec('PRAGMA foreign_keys = ON');
    return $pdo;
}

function e(?string $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function redirect(string $path): never
{
    header('Location: ' . $path);
    exit;
}

function csrf_token(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function check_csrf(): void
{
    $token = $_POST['_csrf'] ?? '';
    if (!is_string($token) || !hash_equals($_SESSION['csrf'] ?? '', $token)) {
        http_response_code(419);
        echo 'CSRF token error';
        exit;
    }
}

function current_user(): ?array
{
    if (empty($_SESSION['user_id'])) {
        return null;
    }
    $stmt = db()->prepare('SELECT id, username, created_at FROM users WHERE id = ?');
    $stmt->execute([(int)$_SESSION['user_id']]);
    $user = $stmt->fetch();
    return $user ?: null;
}

function require_auth(): array
{
    $user = current_user();
    if (!$user) {
        redirect('/?page=login');
    }
    return $user;
}

function flash(?string $message = null, string $type = 'ok'): ?array
{
    if ($message !== null) {
        $_SESSION['flash'] = ['message' => $message, 'type' => $type];
        return null;
    }
    $f = $_SESSION['flash'] ?? null;
    unset($_SESSION['flash']);
    return $f;
}

function setting_get(string $key, string $default = ''): string
{
    $stmt = db()->prepare('SELECT value FROM settings WHERE key = ?');
    $stmt->execute([$key]);
    $row = $stmt->fetch();
    return $row ? (string)$row['value'] : $default;
}

function setting_set(string $key, string $value): void
{
    $stmt = db()->prepare('INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value');
    $stmt->execute([$key, $value]);
}

function add_event(string $type, string $message): void
{
    $stmt = db()->prepare('INSERT INTO events(type, message, created_at) VALUES(?, ?, datetime("now", "localtime"))');
    $stmt->execute([$type, $message]);
}

function run_ctl(array $args, int $timeout = 120): array
{
    $cmd = 'sudo /usr/local/sbin/hyper-host-ctl';
    foreach ($args as $arg) {
        $cmd .= ' ' . escapeshellarg((string)$arg);
    }

    $descriptor = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $process = proc_open($cmd, $descriptor, $pipes);
    if (!is_resource($process)) {
        return ['code' => 1, 'output' => 'Не удалось запустить root-команду'];
    }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $output = '';
    $exitCode = null;
    $start = time();
    while (true) {
        $output .= stream_get_contents($pipes[1]);
        $output .= stream_get_contents($pipes[2]);
        $status = proc_get_status($process);
        if (!$status['running']) {
            $exitCode = is_int($status['exitcode'] ?? null) ? (int)$status['exitcode'] : null;
            break;
        }
        if (time() - $start > $timeout) {
            proc_terminate($process, 9);
            foreach ([1, 2] as $i) {
                if (isset($pipes[$i]) && is_resource($pipes[$i])) {
                    $output .= stream_get_contents($pipes[$i]);
                    fclose($pipes[$i]);
                }
            }
            proc_close($process);
            return ['code' => 124, 'output' => trim($output . "\nTimeout")];
        }
        usleep(100000);
    }
    $output .= stream_get_contents($pipes[1]);
    $output .= stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $closeCode = proc_close($process);

    // В PHP proc_close часто возвращает -1, если до этого вызывался proc_get_status().
    // Из-за этого панель считала успешные root-команды ошибками и не сохраняла записи.
    $code = ($exitCode !== null && $exitCode >= 0) ? $exitCode : (($closeCode >= 0) ? $closeCode : 0);
    return ['code' => $code, 'output' => trim($output)];
}

function is_valid_domain(string $domain): bool
{
    return (bool)preg_match('/^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$/', $domain);
}

function is_valid_name(string $name): bool
{
    return (bool)preg_match('/^[A-Za-z0-9_][A-Za-z0-9_-]{1,63}$/', $name);
}

function is_valid_db_name(string $name): bool
{
    return (bool)preg_match('/^[A-Za-z0-9_]{2,48}$/', $name);
}

function is_valid_folder_name(string $name): bool
{
    return (bool)preg_match('/^[A-Za-z0-9._-]{1,80}$/', $name) && !in_array($name, ['.', '..'], true);
}

function human_bytes(float $bytes): string
{
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    while ($bytes >= 1024 && $i < count($units) - 1) {
        $bytes /= 1024;
        $i++;
    }
    return round($bytes, 2) . ' ' . $units[$i];
}

function table_count(string $table): int
{
    $allowed = ['sites', 'folders', 'ftp_accounts', 'databases', 'bots', 'events'];
    if (!in_array($table, $allowed, true)) {
        return 0;
    }
    return (int)db()->query("SELECT COUNT(*) FROM {$table}")->fetchColumn();
}

function system_service_status(string $service): string
{
    $service = preg_replace('/[^A-Za-z0-9@_.-]/', '', $service);
    if ($service === '') {
        return 'unknown';
    }
    $out = [];
    $code = 0;
    exec('systemctl is-active ' . escapeshellarg($service) . ' 2>/dev/null', $out, $code);
    return trim($out[0] ?? 'inactive') ?: 'inactive';
}


function extract_json_payload(string $text): string
{
    $text = trim($text);
    if ($text === '') {
        return '';
    }
    $firstObj = strpos($text, '{');
    $firstArr = strpos($text, '[');
    $starts = array_filter([$firstObj, $firstArr], static fn($v) => $v !== false);
    if (!$starts) {
        return $text;
    }
    $start = min($starts);
    $lastObj = strrpos($text, '}');
    $lastArr = strrpos($text, ']');
    $ends = array_filter([$lastObj, $lastArr], static fn($v) => $v !== false);
    if (!$ends) {
        return substr($text, $start);
    }
    $end = max($ends);
    return substr($text, $start, $end - $start + 1);
}

function run_ctl_json(array $args, int $timeout = 60): array
{
    $result = run_ctl($args, $timeout);
    $json = extract_json_payload((string)$result['output']);
    $data = json_decode($json, true);
    if (is_array($data)) {
        return $data;
    }
    if ($result['code'] !== 0) {
        return ['_error' => $result['output'], '_code' => $result['code']];
    }
    return ['_error' => 'Некорректный JSON от hyper-host-ctl: ' . mb_substr($json ?: (string)$result['output'], 0, 500), '_code' => 1];
}

function percent(float $used, float $total): int
{
    if ($total <= 0) {
        return 0;
    }
    return max(0, min(100, (int)round(($used / $total) * 100)));
}

function db_writable_status(): array
{
    $path = (string)app_config('db_path');
    return [
        'path' => $path,
        'exists' => is_file($path),
        'file_writable' => is_file($path) ? is_writable($path) : false,
        'dir_writable' => is_writable(dirname($path)),
    ];
}

function upsert_site_row(string $domain, string $aliases, string $root, int $ssl = 0): void
{
    $stmt = db()->prepare('SELECT id FROM sites WHERE domain = ?');
    $stmt->execute([$domain]);
    if ($stmt->fetch()) {
        db()->prepare('UPDATE sites SET aliases = ?, root_path = ?, ssl_enabled = ? WHERE domain = ?')->execute([$aliases, $root, $ssl, $domain]);
    } else {
        db()->prepare('INSERT INTO sites(domain, aliases, root_path, ssl_enabled) VALUES(?, ?, ?, ?)')->execute([$domain, $aliases, $root, $ssl]);
    }
}

function upsert_folder_row(string $name, string $path): void
{
    $stmt = db()->prepare('SELECT id FROM folders WHERE name = ?');
    $stmt->execute([$name]);
    if ($stmt->fetch()) {
        db()->prepare('UPDATE folders SET path = ? WHERE name = ?')->execute([$path, $name]);
    } else {
        db()->prepare('INSERT INTO folders(name, path) VALUES(?, ?)')->execute([$name, $path]);
    }
}

function upsert_ftp_row(string $username, string $target, string $passwordPlain = '', ?string $host = null): void
{
    $host = $host ?: panel_host_for_connections();
    $stmt = db()->prepare('SELECT id, password_plain FROM ftp_accounts WHERE username = ?');
    $stmt->execute([$username]);
    $row = $stmt->fetch();
    if ($row) {
        if ($passwordPlain !== '') {
            db()->prepare('UPDATE ftp_accounts SET host = ?, target_path = ?, password_plain = ? WHERE username = ?')->execute([$host, $target, $passwordPlain, $username]);
        } else {
            db()->prepare('UPDATE ftp_accounts SET host = ?, target_path = ? WHERE username = ?')->execute([$host, $target, $username]);
        }
    } else {
        db()->prepare('INSERT INTO ftp_accounts(host, username, target_path, password_plain) VALUES(?, ?, ?, ?)')->execute([$host, $username, $target, $passwordPlain]);
    }
}

function panel_host_for_connections(): string
{
    $domain = trim((string)app_config('panel_domain', ''));
    if ($domain !== '' && $domain !== '_') {
        return $domain;
    }
    return (string)app_config('server_ip');
}

function upsert_db_row(string $dbName, string $dbUser, int $remote): void
{
    $stmt = db()->prepare('SELECT id FROM databases WHERE db_name = ?');
    $stmt->execute([$dbName]);
    if ($stmt->fetch()) {
        db()->prepare('UPDATE databases SET db_user = ?, remote_allowed = ? WHERE db_name = ?')->execute([$dbUser, $remote, $dbName]);
    } else {
        db()->prepare('INSERT INTO databases(db_name, db_user, remote_allowed) VALUES(?, ?, ?)')->execute([$dbName, $dbUser, $remote]);
    }
}

function upsert_bot_row(string $name, string $runtime, string $path, string $command): void
{
    $stmt = db()->prepare('SELECT id FROM bots WHERE name = ?');
    $stmt->execute([$name]);
    if ($stmt->fetch()) {
        db()->prepare('UPDATE bots SET runtime = ?, path = ?, start_command = ? WHERE name = ?')->execute([$runtime, $path, $command, $name]);
    } else {
        db()->prepare('INSERT INTO bots(name, runtime, path, start_command) VALUES(?, ?, ?, ?)')->execute([$name, $runtime, $path, $command]);
    }
}
