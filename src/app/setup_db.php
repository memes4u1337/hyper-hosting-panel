<?php
declare(strict_types=1);

$config = require __DIR__ . '/config.php';
$dbPath = $config['db_path'];
$dir = dirname($dbPath);
if (!is_dir($dir)) {
    mkdir($dir, 0750, true);
}

$adminUser = $argv[1] ?? 'admin';
$adminPass = $argv[2] ?? bin2hex(random_bytes(10));

$pdo = new PDO('sqlite:' . $dbPath);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$pdo->exec('PRAGMA foreign_keys = ON');

$pdo->exec(<<<SQL
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS sites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT NOT NULL UNIQUE,
    aliases TEXT DEFAULT '',
    root_path TEXT NOT NULL,
    php_version TEXT NOT NULL DEFAULT '',
    disk_limit_mb INTEGER NOT NULL DEFAULT 0,
    ssl_enabled INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    path TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS ftp_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    host TEXT NOT NULL DEFAULT '',
    username TEXT NOT NULL UNIQUE,
    target_path TEXT NOT NULL,
    password_plain TEXT NOT NULL DEFAULT '',
    access_scope TEXT NOT NULL DEFAULT 'all',
    access_target TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS databases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    db_name TEXT NOT NULL UNIQUE,
    db_user TEXT NOT NULL,
    remote_allowed INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS mysql_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    password_plain TEXT NOT NULL DEFAULT '',
    host_pattern TEXT NOT NULL DEFAULT 'localhost',
    db_name TEXT NOT NULL DEFAULT '',
    privileges TEXT NOT NULL DEFAULT 'ALL',
    remote_allowed INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS bots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    runtime TEXT NOT NULL DEFAULT 'python',
    path TEXT NOT NULL,
    start_command TEXT NOT NULL,
    memory_limit_mb INTEGER NOT NULL DEFAULT 0,
    process_limit INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);


CREATE TABLE IF NOT EXISTS managed_projects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL UNIQUE,
    owner_user_id INTEGER NOT NULL DEFAULT 0,
    project_name TEXT NOT NULL DEFAULT '',
    owner_tg_id TEXT NOT NULL DEFAULT '',
    owner_username TEXT NOT NULL DEFAULT '',
    owner_name TEXT NOT NULL DEFAULT '',
    subscription_status TEXT NOT NULL DEFAULT '',
    bot_active TEXT NOT NULL DEFAULT '',
    bot_username TEXT NOT NULL DEFAULT '',
    bot_link TEXT NOT NULL DEFAULT '',
    pm2_name TEXT NOT NULL DEFAULT '',
    deploy_path TEXT NOT NULL DEFAULT '',
    pm2_status TEXT NOT NULL DEFAULT 'not_found',
    sql_status TEXT NOT NULL DEFAULT '',
    last_error TEXT NOT NULL DEFAULT '',
    token_fingerprint TEXT NOT NULL DEFAULT '',
    synced_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS deploy_uploads (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL UNIQUE,
    bot_path TEXT NOT NULL DEFAULT '',
    requirements_path TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS backup_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    target TEXT NOT NULL DEFAULT 'all',
    schedule TEXT NOT NULL DEFAULT '0 3 * * *',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS dns_zones (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT NOT NULL UNIQUE,
    primary_ns TEXT NOT NULL DEFAULT 'ns1.local.',
    admin_email TEXT NOT NULL DEFAULT 'admin.local.',
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS dns_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    zone_id INTEGER NOT NULL,
    type TEXT NOT NULL,
    name TEXT NOT NULL,
    value TEXT NOT NULL,
    ttl INTEGER NOT NULL DEFAULT 3600,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime')),
    FOREIGN KEY(zone_id) REFERENCES dns_zones(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS cron_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    schedule TEXT NOT NULL,
    command TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS auth_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL DEFAULT '',
    ip TEXT NOT NULL DEFAULT '',
    user_agent TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);
SQL);

function ensure_column(PDO $pdo, string $table, string $column, string $definition): void
{
    $cols = $pdo->query('PRAGMA table_info(' . $table . ')')->fetchAll(PDO::FETCH_ASSOC);
    foreach ($cols as $col) {
        if (($col['name'] ?? '') === $column) return;
    }
    $pdo->exec('ALTER TABLE ' . $table . ' ADD COLUMN ' . $column . ' ' . $definition);
}

ensure_column($pdo, 'sites', 'php_version', "TEXT NOT NULL DEFAULT ''");
ensure_column($pdo, 'sites', 'disk_limit_mb', "INTEGER NOT NULL DEFAULT 0");
ensure_column($pdo, 'ftp_accounts', 'host', "TEXT NOT NULL DEFAULT ''");
ensure_column($pdo, 'ftp_accounts', 'password_plain', "TEXT NOT NULL DEFAULT ''");
ensure_column($pdo, 'ftp_accounts', 'access_scope', "TEXT NOT NULL DEFAULT 'all'");
ensure_column($pdo, 'ftp_accounts', 'access_target', "TEXT NOT NULL DEFAULT ''");
ensure_column($pdo, 'databases', 'db_password_plain', "TEXT NOT NULL DEFAULT ''");
ensure_column($pdo, 'databases', 'db_host', "TEXT NOT NULL DEFAULT '127.0.0.1'");
ensure_column($pdo, 'databases', 'db_port', "TEXT NOT NULL DEFAULT '3306'");
ensure_column($pdo, 'mysql_accounts', 'password_plain', "TEXT NOT NULL DEFAULT ''");
ensure_column($pdo, 'mysql_accounts', 'host_pattern', "TEXT NOT NULL DEFAULT 'localhost'");
ensure_column($pdo, 'mysql_accounts', 'db_name', "TEXT NOT NULL DEFAULT ''");
ensure_column($pdo, 'mysql_accounts', 'privileges', "TEXT NOT NULL DEFAULT 'ALL'");
ensure_column($pdo, 'mysql_accounts', 'remote_allowed', "INTEGER NOT NULL DEFAULT 0");
ensure_column($pdo, 'bots', 'memory_limit_mb', "INTEGER NOT NULL DEFAULT 0");
ensure_column($pdo, 'bots', 'process_limit', "INTEGER NOT NULL DEFAULT 0");

$stmt = $pdo->prepare('SELECT id FROM users WHERE username = ?');
$stmt->execute([$adminUser]);
if (!$stmt->fetch()) {
    $stmt = $pdo->prepare('INSERT INTO users(username, password_hash) VALUES(?, ?)');
    $stmt->execute([$adminUser, password_hash($adminPass, PASSWORD_DEFAULT)]);
}

$defaults = [
    'mysql_external' => '0',
    'security_2fa_enabled' => '0',
    'security_2fa_secret' => '',
    'security_ip_allowlist' => '',
    'backup_dir' => '/opt/hyper-host/backups',
    'public_ip_override' => '',
    'deploy_db_host' => '90.189.208.25',
    'deploy_db_port' => '3306',
    'deploy_db_user' => 'mystock',
    'deploy_db_name' => 'mystock',
    'deploy_master_project_id' => '0',
];
foreach ($defaults as $k => $v) {
    $stmt = $pdo->prepare('INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)');
    $stmt->execute([$k, $v]);
}

echo "HYPER-HOST database ready. Admin: {$adminUser}\n";
