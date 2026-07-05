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
    $allowed = ['sites', 'folders', 'ftp_accounts', 'databases', 'bots', 'events', 'backup_jobs', 'dns_zones', 'dns_records', 'cron_tasks', 'auth_logs'];
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


function hh_cache_dir(): string
{
    $dir = (string)app_config('cache_dir', '/opt/hyper-host/cache');
    if (!is_dir($dir)) {
        @mkdir($dir, 0775, true);
    }
    return $dir;
}

function hh_cache_key(array $args): string
{
    return hash('sha256', json_encode($args, JSON_UNESCAPED_UNICODE));
}

function run_ctl_json_cached(array $args, int $timeout = 20, int $ttl = 8): array
{
    // HYPER-HOST v18 fast mode:
    // тяжёлые shell-проверки больше не запускаются на каждое открытие вкладки.
    // Если кэш свежий — отдаём его сразу. Если команда временно зависла/упала —
    // отдаём старый кэш до 30 минут, чтобы панель не тормозила и не висела.
    $ttl = max($ttl, 60);
    $staleTtl = max($ttl, 1800);
    $dir = hh_cache_dir();
    $file = $dir . '/' . hh_cache_key($args) . '.json';
    $readCached = static function(string $file): ?array {
        $raw = @file_get_contents($file);
        $data = json_decode((string)$raw, true);
        return is_array($data) ? $data : null;
    };
    if (is_file($file)) {
        $age = time() - filemtime($file);
        if ($ttl > 0 && $age <= $ttl) {
            $data = $readCached($file);
            if (is_array($data)) {
                $data['_cached'] = true;
                $data['_cache_age'] = $age;
                return $data;
            }
        }
    }
    $data = run_ctl_json($args, min($timeout, 12));
    if (!isset($data['_error'])) {
        @file_put_contents($file, json_encode($data, JSON_UNESCAPED_UNICODE));
        return $data;
    }
    if (is_file($file) && (time() - filemtime($file) <= $staleTtl)) {
        $cached = $readCached($file);
        if (is_array($cached)) {
            $cached['_cached'] = true;
            $cached['_stale'] = true;
            $cached['_cache_age'] = time() - filemtime($file);
            return $cached;
        }
    }
    return $data;
}

function hh_clear_cache(): void
{
    $dir = hh_cache_dir();
    foreach (glob($dir . '/*.json') ?: [] as $f) {
        @unlink($f);
    }
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


function auth_log(string $username, string $status): void
{
    try {
        $stmt = db()->prepare('INSERT INTO auth_logs(username, ip, user_agent, status, created_at) VALUES(?, ?, ?, ?, datetime("now", "localtime"))');
        $stmt->execute([$username, $_SERVER['REMOTE_ADDR'] ?? '', substr($_SERVER['HTTP_USER_AGENT'] ?? '', 0, 240), $status]);
    } catch (Throwable) {}
}

function ip_allowed(): bool
{
    $raw = trim(setting_get('security_ip_allowlist', ''));
    if ($raw === '') return true;
    $ip = $_SERVER['REMOTE_ADDR'] ?? '';
    foreach (preg_split('/[\r\n,]+/', $raw) as $line) {
        $line = trim($line);
        if ($line === '') continue;
        if ($line === $ip) return true;
        if (str_ends_with($line, '.*') && str_starts_with($ip, substr($line, 0, -1))) return true;
    }
    return false;
}

function base32_random(int $length = 16): string
{
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $out = '';
    for ($i=0; $i<$length; $i++) $out .= $alphabet[random_int(0, strlen($alphabet)-1)];
    return $out;
}

function base32_decode_hh(string $base32): string
{
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $base32 = strtoupper(preg_replace('/[^A-Z2-7]/', '', $base32));
    $bits = '';
    for ($i=0; $i<strlen($base32); $i++) {
        $v = strpos($alphabet, $base32[$i]);
        if ($v === false) continue;
        $bits .= str_pad(decbin($v), 5, '0', STR_PAD_LEFT);
    }
    $out = '';
    for ($i=0; $i+8<=strlen($bits); $i+=8) $out .= chr(bindec(substr($bits, $i, 8)));
    return $out;
}

function totp_code(string $secret, ?int $timeSlice = null): string
{
    $timeSlice ??= (int)floor(time() / 30);
    $secretKey = base32_decode_hh($secret);
    if ($secretKey === '') return '';
    $time = pack('N*', 0) . pack('N*', $timeSlice);
    $hash = hash_hmac('sha1', $time, $secretKey, true);
    $offset = ord(substr($hash, -1)) & 0x0F;
    $truncated = unpack('N', substr($hash, $offset, 4))[1] & 0x7FFFFFFF;
    return str_pad((string)($truncated % 1000000), 6, '0', STR_PAD_LEFT);
}

function verify_totp(string $secret, string $code): bool
{
    $code = preg_replace('/\D/', '', $code);
    if (strlen($code) !== 6) return false;
    $slice = (int)floor(time() / 30);
    for ($i=-1; $i<=1; $i++) if (hash_equals(totp_code($secret, $slice+$i), $code)) return true;
    return false;
}

function safe_rel_path(string $path): string
{
    $path = str_replace("\0", '', $path);
    $path = str_replace('\\', '/', $path);
    $parts = [];
    foreach (explode('/', $path) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') { array_pop($parts); continue; }
        $parts[] = $part;
    }
    return implode('/', $parts);
}

function file_manager_roots(): array
{
    return [
        'sites' => ['label' => 'Сайты', 'path' => (string)app_config('sites_dir')],
        'bots' => ['label' => 'Боты', 'path' => (string)app_config('bots_dir')],
        'ftp' => ['label' => 'FTP', 'path' => (string)app_config('ftp_dir', '/var/www/hyper-host-ftp')],
        'backups' => ['label' => 'Backup', 'path' => setting_get('backup_dir', '/opt/hyper-host/backups')],
    ];
}

function fm_resolve(string $rootKey, string $rel = ''): array
{
    $roots = file_manager_roots();
    if (!isset($roots[$rootKey])) $rootKey = 'sites';
    $root = rtrim($roots[$rootKey]['path'], '/');
    $rel = safe_rel_path($rel);
    $path = $root . ($rel !== '' ? '/' . $rel : '');
    $rootReal = realpath($root) ?: $root;
    $pathReal = realpath($path) ?: $path;
    if (!str_starts_with($pathReal, $rootReal)) throw new RuntimeException('Неверный путь');
    return [$rootKey, $root, $rel, $path];
}

function upsert_bot_row_v5(string $name, string $runtime, string $path, string $command, int $memory = 0, int $processLimit = 0): void
{
    $stmt = db()->prepare('SELECT id FROM bots WHERE name = ?');
    $stmt->execute([$name]);
    if ($stmt->fetch()) {
        db()->prepare('UPDATE bots SET runtime=?, path=?, start_command=?, memory_limit_mb=?, process_limit=? WHERE name=?')->execute([$runtime, $path, $command, $memory, $processLimit, $name]);
    } else {
        db()->prepare('INSERT INTO bots(name, runtime, path, start_command, memory_limit_mb, process_limit) VALUES(?, ?, ?, ?, ?, ?)')->execute([$name, $runtime, $path, $command, $memory, $processLimit]);
    }
}

function upsert_site_row_v5(string $domain, string $aliases, string $root, int $ssl = 0, string $phpVersion = '', int $diskLimit = 0): void
{
    $stmt = db()->prepare('SELECT id, php_version, disk_limit_mb FROM sites WHERE domain = ?');
    $stmt->execute([$domain]);
    $row = $stmt->fetch();
    if ($row) {
        if ($phpVersion === '') $phpVersion = (string)($row['php_version'] ?? '');
        if ($diskLimit === 0) $diskLimit = (int)($row['disk_limit_mb'] ?? 0);
        db()->prepare('UPDATE sites SET aliases=?, root_path=?, ssl_enabled=?, php_version=?, disk_limit_mb=? WHERE domain=?')->execute([$aliases, $root, $ssl, $phpVersion, $diskLimit, $domain]);
    } else {
        db()->prepare('INSERT INTO sites(domain, aliases, root_path, ssl_enabled, php_version, disk_limit_mb) VALUES(?, ?, ?, ?, ?, ?)')->execute([$domain, $aliases, $root, $ssl, $phpVersion, $diskLimit]);
    }
}
