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
    ssl_enabled INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS ftp_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    target_path TEXT NOT NULL,
    password_plain TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS databases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    db_name TEXT NOT NULL UNIQUE,
    db_user TEXT NOT NULL,
    remote_allowed INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS bots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    runtime TEXT NOT NULL DEFAULT 'python',
    path TEXT NOT NULL,
    start_command TEXT NOT NULL,
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


// Миграции для уже установленных панелей.
$columns = $pdo->query("PRAGMA table_info(ftp_accounts)")->fetchAll(PDO::FETCH_ASSOC);
$hasPasswordPlain = false;
foreach ($columns as $column) {
    if (($column['name'] ?? '') === 'password_plain') {
        $hasPasswordPlain = true;
        break;
    }
}
if (!$hasPasswordPlain) {
    $pdo->exec("ALTER TABLE ftp_accounts ADD COLUMN password_plain TEXT NOT NULL DEFAULT ''");
}

$stmt = $pdo->prepare('SELECT id FROM users WHERE username = ?');
$stmt->execute([$adminUser]);
if (!$stmt->fetch()) {
    $hash = password_hash($adminPass, PASSWORD_DEFAULT);
    $stmt = $pdo->prepare('INSERT INTO users(username, password_hash) VALUES(?, ?)');
    $stmt->execute([$adminUser, $hash]);
}

$settings = [
    'mysql_external' => '0',
    'panel_brand' => $config['panel_name'] ?? 'HYPER-HOST',
    'powered_by' => $config['powered_by'] ?? 'powered by memes4u1337',
];
foreach ($settings as $key => $value) {
    $stmt = $pdo->prepare('INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)');
    $stmt->execute([$key, $value]);
}

$stmt = $pdo->prepare('INSERT INTO events(type, message) VALUES(?, ?)');
$stmt->execute(['install', 'Панель HYPER-HOST установлена/обновлена']);
