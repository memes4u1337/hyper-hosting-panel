<?php
declare(strict_types=1);

/**
 * HYPER-HOST CP — клиентский портал.
 * powered by memes4u1337
 */

require __DIR__ . '/../app/bootstrap.php';

header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header('X-Robots-Tag: noindex, nofollow');

$page = (string)($_GET['page'] ?? 'dashboard');

// ============================================================ гость: вход
if ($page === 'logout') cp_logout();

if (!current_user()) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        check_csrf();
        $act = (string)($_POST['action'] ?? '');
        try {
            if ($act === 'login') {
                cp_login((string)($_POST['username'] ?? ''), (string)($_POST['password'] ?? ''));
                redirect('/?page=dashboard');
            }
            if ($act === 'register') {
                cp_register(
                    (string)($_POST['username'] ?? ''),
                    (string)($_POST['email'] ?? ''),
                    (string)($_POST['password'] ?? ''),
                    (string)($_POST['password2'] ?? '')
                );
                redirect('/?page=dashboard');
            }
        } catch (Throwable $e) {
            flash($e->getMessage(), 'danger');
            redirect('/?page=' . ($act === 'register' ? 'register' : 'login'));
        }
    }
    render_auth($page === 'register' ? 'register' : 'login');
    exit;
}

// ============================================================ клиент
$user = require_auth();
$quota = cp_quota((int)$user['id']);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    try {
        handle_action($user, $quota);
    } catch (Throwable $e) {
        flash($e->getMessage(), 'danger');
        redirect('/?page=' . (string)($_POST['back'] ?? 'dashboard'));
    }
}

render_shell($user, $quota, $page);


// ============================================================ действия

function handle_action(array $user, array $quota): void
{
    $act = (string)($_POST['action'] ?? '');
    $username = (string)$user['username'];
    $uid = (int)$user['id'];
    $db = cp_db();

    if (!cp_has_resources($quota) && $act !== 'change_password') {
        throw new RuntimeException('Администратор ещё не выдал ресурсы для вашего аккаунта');
    }

    switch ($act) {

        case 'create_site': {
            $domain = strtolower(trim((string)($_POST['domain'] ?? '')));
            if (($_POST['mode'] ?? '') === 'sub') {
                $sub = strtolower(trim((string)($_POST['subdomain'] ?? '')));
                if (!preg_match('/^[a-z0-9][a-z0-9-]{1,30}$/', $sub)) {
                    throw new RuntimeException('Поддомен: латиница, цифры и дефис, от 2 символов');
                }
                $domain = $sub . '.' . (string)cp_config('base_domain');
            }
            if (!cp_valid_domain($domain)) throw new RuntimeException('Некорректное доменное имя');

            $count = count(cp_sites($uid));
            if ($count >= (int)$quota['max_sites']) {
                throw new RuntimeException('Достигнут лимит сайтов: ' . (int)$quota['max_sites'] . '. Попросите администратора увеличить.');
            }
            $st = $db->prepare('SELECT id FROM cp_sites WHERE domain=?');
            $st->execute([$domain]);
            if ($st->fetch()) throw new RuntimeException('Такой домен уже добавлен');

            $r = cp_bridge(['action' => 'site-create', 'user' => $username, 'domain' => $domain], 180);
            if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Не удалось создать сайт'));

            $db->prepare('INSERT INTO cp_sites(user_id,domain,root_path) VALUES(?,?,?)')
               ->execute([$uid, $domain, (string)($r['root'] ?? '')]);
            cp_event('site', 'Создан сайт ' . $domain);
            flash('Сайт ' . $domain . ' создан. Файлы кладите по FTP в sites/' . $domain . '/public_html', 'success');
            redirect('/?page=sites');
        }

        case 'delete_site': {
            $site = owned_site($uid, (int)($_POST['id'] ?? 0));
            $r = cp_bridge(['action' => 'site-delete', 'user' => $username,
                            'domain' => (string)$site['domain'],
                            'wipe' => (string)($_POST['wipe'] ?? '0')], 120);
            if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Ошибка удаления'));
            $db->prepare('DELETE FROM cp_sites WHERE id=?')->execute([(int)$site['id']]);
            cp_event('site', 'Удалён сайт ' . $site['domain']);
            flash('Сайт удалён', 'success');
            redirect('/?page=sites');
        }

        case 'issue_ssl': {
            $site = owned_site($uid, (int)($_POST['id'] ?? 0));
            $email = trim((string)($_POST['email'] ?? ''));
            $r = cp_bridge(['action' => 'site-ssl', 'user' => $username,
                            'domain' => (string)$site['domain'], 'email' => $email], 320);
            if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Не удалось выпустить сертификат'));
            $db->prepare('UPDATE cp_sites SET ssl_enabled=1, ssl_expires=? WHERE id=?')
               ->execute([(string)($r['expires'] ?? ''), (int)$site['id']]);
            cp_event('ssl', 'Выпущен SSL для ' . $site['domain']);
            flash('SSL выпущен. Действует до ' . (string)($r['expires'] ?? '—'), 'success');
            redirect('/?page=ssl');
        }

        case 'create_bot': {
            $name = strtolower(trim((string)($_POST['name'] ?? '')));
            $runtime = (string)($_POST['runtime'] ?? 'python');
            if (!cp_valid_bot_name($name)) throw new RuntimeException('Имя бота: латиница, цифры, _ и -');

            $bots = cp_bots($uid);
            if (count($bots) >= (int)$quota['max_bots']) {
                throw new RuntimeException('Достигнут лимит ботов: ' . (int)$quota['max_bots']);
            }
            // Квота делится поровну между ботами, чтобы клиент не мог выйти за выданное.
            $slots = max(1, (int)$quota['max_bots']);
            $cpu = (int)floor((int)$quota['cpu_percent'] / $slots);
            $mem = (int)floor((int)$quota['memory_mb'] / $slots);

            $r = cp_bridge(['action' => 'bot-create', 'user' => $username, 'bot' => $name,
                            'runtime' => $runtime, 'cpu_percent' => $cpu, 'memory_mb' => $mem], 180);
            if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Не удалось создать бота'));

            $db->prepare('INSERT INTO cp_bots(user_id,name,runtime,unit_name,path,start_command,cpu_percent,memory_mb) VALUES(?,?,?,?,?,?,?,?)')
               ->execute([$uid, $name, $runtime, (string)($r['unit'] ?? ''), (string)($r['path'] ?? ''),
                          $runtime === 'node' ? 'node index.js' : 'python bot.py', $cpu, $mem]);
            cp_event('bot', 'Создан бот ' . $name);
            flash('Бот создан. Загрузите код по FTP в bots/' . $name . ', затем нажмите «Установить зависимости» и «Запустить».', 'success');
            redirect('/?page=bots');
        }

        case 'bot_action': {
            $bot = owned_bot($uid, (int)($_POST['id'] ?? 0));
            $a = (string)($_POST['act'] ?? '');
            $r = cp_bridge(['action' => 'bot-action', 'user' => $username,
                            'bot' => (string)$bot['name'], 'act' => $a], 120);
            if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Ошибка'));
            cp_event('bot', 'Бот ' . $bot['name'] . ': ' . $a);
            flash('Бот ' . $bot['name'] . ' — ' . (string)($r['status'] ?? $a), 'success');
            redirect('/?page=bots');
        }

        case 'bot_install': {
            $bot = owned_bot($uid, (int)($_POST['id'] ?? 0));
            $r = cp_bridge(['action' => 'bot-install', 'user' => $username, 'bot' => (string)$bot['name']], 900);
            if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Не удалось установить зависимости'));
            $_SESSION['cp_install_log'] = (string)($r['log'] ?? '');
            flash('Зависимости установлены', 'success');
            redirect('/?page=bots');
        }

        case 'delete_bot': {
            $bot = owned_bot($uid, (int)($_POST['id'] ?? 0));
            $r = cp_bridge(['action' => 'bot-delete', 'user' => $username,
                            'bot' => (string)$bot['name'], 'wipe' => (string)($_POST['wipe'] ?? '0')], 120);
            if (empty($r['ok'])) throw new RuntimeException((string)($r['error'] ?? 'Ошибка удаления'));
            $db->prepare('DELETE FROM cp_bots WHERE id=?')->execute([(int)$bot['id']]);
            cp_event('bot', 'Удалён бот ' . $bot['name']);
            flash('Бот удалён', 'success');
            redirect('/?page=bots');
        }

        case 'change_password': {
            $cur = (string)($_POST['current_password'] ?? '');
            $new = (string)($_POST['new_password'] ?? '');
            if (!password_verify($cur, (string)$user['password_hash'])) throw new RuntimeException('Текущий пароль неверный');
            if (strlen($new) < 10) throw new RuntimeException('Новый пароль минимум 10 символов');
            $db->prepare('UPDATE cp_users SET password_hash=? WHERE id=?')
               ->execute([password_hash($new, PASSWORD_DEFAULT), $uid]);
            flash('Пароль изменён', 'success');
            redirect('/?page=ftp');
        }
    }

    throw new RuntimeException('Неизвестное действие');
}

function owned_site(int $uid, int $id): array
{
    $st = cp_db()->prepare('SELECT * FROM cp_sites WHERE id=? AND user_id=?');
    $st->execute([$id, $uid]);
    $r = $st->fetch();
    if (!is_array($r)) throw new RuntimeException('Сайт не найден');
    return $r;
}

function owned_bot(int $uid, int $id): array
{
    $st = cp_db()->prepare('SELECT * FROM cp_bots WHERE id=? AND user_id=?');
    $st->execute([$id, $uid]);
    $r = $st->fetch();
    if (!is_array($r)) throw new RuntimeException('Бот не найден');
    return $r;
}


// ============================================================ вход/регистрация

function render_auth(string $mode): void
{
    $f = flash();
    ?><!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HYPER-HOST — <?= $mode === 'register' ? 'Регистрация' : 'Вход' ?></title>
<link href="/assets/cp.css?v=1" rel="stylesheet">
</head><body class="cp-auth-body">
<div class="cp-orb cp-orb-a"></div><div class="cp-orb cp-orb-b"></div>
<main class="cp-auth">
  <div class="cp-auth-card">
    <div class="cp-brand"><span class="cp-brand-mark">⚡</span><b>HYPER-HOST</b></div>
    <h1><?= $mode === 'register' ? 'Создать аккаунт' : 'Вход в панель' ?></h1>
    <p class="cp-muted"><?= $mode === 'register'
        ? 'Логин станет именем вашей папки на сервере и FTP-логином — выбирайте осознанно.'
        : 'Панель управления вашими сайтами и ботами.' ?></p>

    <?php if ($f): ?><div class="cp-alert cp-alert-<?= e($f['type']) ?>"><?= e($f['message']) ?></div><?php endif; ?>

    <form method="post" class="cp-form">
      <?= csrf_field() ?>
      <input type="hidden" name="action" value="<?= $mode === 'register' ? 'register' : 'login' ?>">
      <label><span>Логин</span>
        <input name="username" autocomplete="username" required autofocus
               <?= $mode === 'register' ? 'pattern="[a-z][a-z0-9_-]{2,23}" title="3–24 символа, латиница со строчной буквы"' : '' ?>>
      </label>
      <?php if ($mode === 'register'): ?>
        <label><span>E-mail <small>(необязательно)</small></span><input name="email" type="email" autocomplete="email"></label>
      <?php endif; ?>
      <label><span>Пароль</span><input name="password" type="password" required
             autocomplete="<?= $mode === 'register' ? 'new-password' : 'current-password' ?>" minlength="<?= $mode === 'register' ? 10 : 1 ?>"></label>
      <?php if ($mode === 'register'): ?>
        <label><span>Повторите пароль</span><input name="password2" type="password" required minlength="10" autocomplete="new-password"></label>
      <?php endif; ?>
      <button class="cp-btn cp-btn-primary cp-btn-lg"><?= $mode === 'register' ? 'Зарегистрироваться' : 'Войти' ?></button>
    </form>

    <div class="cp-auth-switch">
      <?php if ($mode === 'register'): ?>
        Уже есть аккаунт? <a href="/?page=login">Войти</a>
      <?php else: ?>
        Нет аккаунта? <a href="/?page=register">Зарегистрироваться</a>
      <?php endif; ?>
    </div>
  </div>
</main>
</body></html><?php
}


// ============================================================ оболочка

function render_shell(array $user, array $quota, string $page): void
{
    $granted = cp_has_resources($quota);
    $allowed = ['dashboard','sites','bots','ssl','logs','ftp'];
    if (!in_array($page, $allowed, true)) $page = 'dashboard';

    $nav = [
        'dashboard' => ['◈', 'Обзор'],
        'sites'     => ['◍', 'Сайты'],
        'bots'      => ['⬢', 'Боты'],
        'ssl'       => ['⛨', 'SSL'],
        'logs'      => ['≡', 'Логи'],
        'ftp'       => ['⇅', 'FTP и доступ'],
    ];
    $f = flash();
    ?><!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HYPER-HOST — панель клиента</title>
<link href="/assets/cp.css?v=1" rel="stylesheet">
</head><body>
<div class="cp-shell">

  <aside class="cp-sidebar" id="cpSidebar">
    <div class="cp-brand"><span class="cp-brand-mark">⚡</span><b>HYPER-HOST</b></div>
    <div class="cp-user-chip">
      <span class="cp-avatar"><?= e(mb_strtoupper(mb_substr((string)$user['username'], 0, 1))) ?></span>
      <div><b><?= e((string)$user['username']) ?></b>
        <small><?= $granted ? 'аккаунт активен' : 'ожидает выдачи ресурсов' ?></small>
      </div>
    </div>
    <nav class="cp-nav">
      <?php foreach ($nav as $id => [$icon, $label]): ?>
        <a class="cp-nav-link<?= $id === $page ? ' is-active' : '' ?><?= (!$granted && $id !== 'dashboard' && $id !== 'ftp') ? ' is-locked' : '' ?>"
           href="/?page=<?= e($id) ?>">
          <span class="cp-nav-icon"><?= $icon ?></span><span><?= e($label) ?></span>
        </a>
      <?php endforeach; ?>
    </nav>
    <a class="cp-nav-link cp-logout" href="/?page=logout"><span class="cp-nav-icon">⏻</span><span>Выйти</span></a>
  </aside>

  <main class="cp-main">
    <header class="cp-topbar">
      <button class="cp-burger" id="cpBurger" aria-label="Меню">☰</button>
      <h1><?= e($nav[$page][1]) ?></h1>
    </header>

    <div class="cp-content">
      <?php if ($f): ?><div class="cp-alert cp-alert-<?= e($f['type']) ?>"><?= e($f['message']) ?></div><?php endif; ?>

      <?php
      if (!$granted && !in_array($page, ['dashboard','ftp'], true)) {
          view_pending($user);
      } else {
          match ($page) {
              'sites' => view_sites($user, $quota),
              'bots'  => view_bots($user, $quota),
              'ssl'   => view_ssl($user),
              'logs'  => view_logs($user),
              'ftp'   => view_ftp($user),
              default => view_dashboard($user, $quota, $granted),
          };
      }
      ?>
    </div>
  </main>
</div>
<div class="cp-backdrop" id="cpBackdrop"></div>
<script src="/assets/cp.js?v=1" defer></script>
</body></html><?php
}


// ============================================================ заглушка

function view_pending(array $user): void
{
    ?>
<section class="cp-pending">
  <div class="cp-pending-glow"></div>
  <div class="cp-pending-icon">⏳</div>
  <h2>Администратор ещё не выдал ресурсы сервера</h2>
  <p>Ваш аккаунт <b><?= e((string)$user['username']) ?></b> создан и уже ждёт настройки.
     Как только администратор выделит место под сайты и ботов, все разделы откроются
     автоматически — эту страницу достаточно будет обновить.</p>
  <div class="cp-pending-steps">
    <div><span>1</span>Аккаунт зарегистрирован</div>
    <div class="is-current"><span>2</span>Ожидание выдачи ресурсов</div>
    <div><span>3</span>Полный доступ к панели</div>
  </div>
  <p class="cp-muted cp-pending-note">FTP-доступ к вашей папке уже работает — можно заранее загрузить файлы.
     Реквизиты в разделе «FTP и доступ».</p>
</section>
<?php }


// ============================================================ обзор

function view_dashboard(array $user, array $quota, bool $granted): void
{
    $sites = cp_sites((int)$user['id']);
    $bots = cp_bots((int)$user['id']);
    $usage = $granted ? cp_usage($user) : ['disk_bytes' => 0, 'units' => []];

    $running = 0;
    foreach (($usage['units'] ?? []) as $u) if (($u['status'] ?? '') === 'active') $running++;
    $memUsed = 0;
    foreach (($usage['units'] ?? []) as $u) $memUsed += (int)($u['memory_bytes'] ?? 0);

    if (!$granted) { view_pending($user); return; }
    ?>
<div class="cp-grid-4">
  <div class="cp-stat">
    <span>Сайты</span>
    <b><?= count($sites) ?><i>/ <?= (int)$quota['max_sites'] ?></i></b>
    <div class="cp-meter"><i style="width:<?= percent((float)count($sites), (float)$quota['max_sites']) ?>%"></i></div>
  </div>
  <div class="cp-stat">
    <span>Боты</span>
    <b><?= count($bots) ?><i>/ <?= (int)$quota['max_bots'] ?></i></b>
    <div class="cp-meter"><i style="width:<?= percent((float)count($bots), (float)$quota['max_bots']) ?>%"></i></div>
  </div>
  <div class="cp-stat">
    <span>Память ботов</span>
    <b><?= e(human_bytes((float)$memUsed)) ?><i>/ <?= (int)$quota['memory_mb'] ?> MB</i></b>
    <div class="cp-meter"><i style="width:<?= percent($memUsed / 1048576, (float)$quota['memory_mb']) ?>%"></i></div>
  </div>
  <div class="cp-stat">
    <span>Диск</span>
    <b><?= e(human_bytes((float)($usage['disk_bytes'] ?? 0))) ?><i>/ <?= (int)$quota['disk_mb'] ?> MB</i></b>
    <div class="cp-meter"><i style="width:<?= percent(((float)($usage['disk_bytes'] ?? 0)) / 1048576, (float)$quota['disk_mb']) ?>%"></i></div>
  </div>
</div>

<div class="cp-grid-2">
  <section class="cp-card">
    <h2>Выданные ресурсы</h2>
    <div class="cp-kv">
      <div><span>Сайтов</span><b><?= (int)$quota['max_sites'] ?></b></div>
      <div><span>Ботов</span><b><?= (int)$quota['max_bots'] ?></b></div>
      <div><span>Процессор</span><b><?= (int)$quota['cpu_percent'] ?>% ядра</b></div>
      <div><span>Память</span><b><?= (int)$quota['memory_mb'] ?> MB</b></div>
      <div><span>Диск</span><b><?= (int)$quota['disk_mb'] ?> MB</b></div>
      <div><span>Ботов запущено</span><b><?= $running ?></b></div>
    </div>
    <p class="cp-muted cp-note">Процессор и память делятся поровну между вашими ботами и
       ограничиваются на уровне системы — превысить выданное не получится.</p>
  </section>

  <section class="cp-card">
    <h2>Последние события</h2>
    <?php $events = cp_events((int)$user['id'], 12); ?>
    <?php if ($events): ?>
      <div class="cp-events">
        <?php foreach ($events as $ev): ?>
          <div class="cp-event">
            <span class="cp-event-type cp-t-<?= e((string)$ev['type']) ?>"><?= e((string)$ev['type']) ?></span>
            <div><b><?= e((string)$ev['message']) ?></b><small><?= e((string)$ev['created_at']) ?></small></div>
          </div>
        <?php endforeach; ?>
      </div>
    <?php else: ?>
      <div class="cp-empty">Событий пока нет</div>
    <?php endif; ?>
  </section>
</div>
<?php }


// ============================================================ сайты

function view_sites(array $user, array $quota): void
{
    $sites = cp_sites((int)$user['id']);
    $left = (int)$quota['max_sites'] - count($sites);
    $base = (string)cp_config('base_domain');
    ?>
<section class="cp-card">
  <div class="cp-card-head">
    <h2>Новый сайт</h2>
    <span class="cp-pill <?= $left > 0 ? 'is-ok' : 'is-warn' ?>">Свободно: <?= max(0, $left) ?></span>
  </div>

  <?php if ($left > 0): ?>
    <form method="post" class="cp-form-inline">
      <?= csrf_field() ?>
      <input type="hidden" name="action" value="create_site">
      <input type="hidden" name="back" value="sites">

      <div class="cp-tabs" data-tabs>
        <button type="button" class="is-active" data-tab="own">Свой домен</button>
        <button type="button" data-tab="sub">Поддомен <?= e($base) ?></button>
      </div>
      <input type="hidden" name="mode" value="own" data-mode>

      <div data-pane="own">
        <label><span>Домен</span>
          <input name="domain" placeholder="example.com" pattern="[a-z0-9.-]+" autocomplete="off">
        </label>
        <p class="cp-muted cp-note">A-запись домена должна указывать на IP сервера, иначе сайт и SSL не заработают.</p>
      </div>

      <div data-pane="sub" hidden>
        <label><span>Поддомен</span>
          <div class="cp-suffix"><input name="subdomain" placeholder="myshop" autocomplete="off"><span>.<?= e($base) ?></span></div>
        </label>
        <p class="cp-muted cp-note">Работает сразу — DNS настраивать не нужно.</p>
      </div>

      <button class="cp-btn cp-btn-primary">Создать сайт</button>
    </form>
  <?php else: ?>
    <div class="cp-empty">Лимит сайтов исчерпан. Попросите администратора увеличить квоту.</div>
  <?php endif; ?>
</section>

<section class="cp-card">
  <h2>Мои сайты</h2>
  <?php if ($sites): ?>
    <div class="cp-list">
      <?php foreach ($sites as $s): ?>
        <div class="cp-item">
          <div class="cp-item-main">
            <b><?= e((string)$s['domain']) ?></b>
            <code>sites/<?= e((string)$s['domain']) ?>/public_html</code>
          </div>
          <div class="cp-item-side">
            <span class="cp-pill <?= $s['ssl_enabled'] ? 'is-ok' : 'is-muted' ?>">
              <?= $s['ssl_enabled'] ? 'SSL до ' . e((string)$s['ssl_expires']) : 'без SSL' ?>
            </span>
            <a class="cp-btn cp-btn-soft" href="http<?= $s['ssl_enabled'] ? 's' : '' ?>://<?= e((string)$s['domain']) ?>" target="_blank" rel="noopener">Открыть</a>
            <form method="post" onsubmit="return confirm('Удалить сайт <?= e((string)$s['domain']) ?>? Файлы останутся на месте.')">
              <?= csrf_field() ?>
              <input type="hidden" name="action" value="delete_site">
              <input type="hidden" name="back" value="sites">
              <input type="hidden" name="id" value="<?= (int)$s['id'] ?>">
              <button class="cp-btn cp-btn-danger">Удалить</button>
            </form>
          </div>
        </div>
      <?php endforeach; ?>
    </div>
  <?php else: ?>
    <div class="cp-empty">Сайтов пока нет</div>
  <?php endif; ?>
</section>
<?php }


// ============================================================ боты

function view_bots(array $user, array $quota): void
{
    $bots = cp_bots((int)$user['id']);
    $usage = cp_usage($user);
    $byName = [];
    foreach (($usage['units'] ?? []) as $u) $byName[(string)$u['name']] = $u;
    $left = (int)$quota['max_bots'] - count($bots);
    $log = $_SESSION['cp_install_log'] ?? '';
    unset($_SESSION['cp_install_log']);
    ?>
<section class="cp-card">
  <div class="cp-card-head">
    <h2>Новый бот</h2>
    <span class="cp-pill <?= $left > 0 ? 'is-ok' : 'is-warn' ?>">Свободно: <?= max(0, $left) ?></span>
  </div>
  <?php if ($left > 0): ?>
    <form method="post" class="cp-form-inline">
      <?= csrf_field() ?>
      <input type="hidden" name="action" value="create_bot">
      <input type="hidden" name="back" value="bots">
      <div class="cp-row">
        <label><span>Имя бота</span><input name="name" placeholder="myshopbot" required pattern="[a-z0-9][a-z0-9_-]{1,31}"></label>
        <label><span>Среда</span>
          <select name="runtime">
            <option value="python">Python — bot.py</option>
            <option value="node">Node.js — index.js</option>
          </select>
        </label>
      </div>
      <button class="cp-btn cp-btn-primary">Создать бота</button>
    </form>
    <p class="cp-muted cp-note">После создания загрузите код по FTP в <code>bots/имя_бота</code>,
       затем «Установить зависимости» и «Запустить». Бот поднимается автоматически после
       перезагрузки сервера и перезапускается при падении.</p>
  <?php else: ?>
    <div class="cp-empty">Лимит ботов исчерпан</div>
  <?php endif; ?>
</section>

<?php if ($log): ?>
  <section class="cp-card"><h2>Установка зависимостей</h2><pre class="cp-log"><?= e((string)$log) ?></pre></section>
<?php endif; ?>

<section class="cp-card">
  <h2>Мои боты</h2>
  <?php if ($bots): ?>
    <div class="cp-list">
      <?php foreach ($bots as $b):
        $live = $byName[(string)$b['name']] ?? [];
        $status = (string)($live['status'] ?? 'inactive');
        $isRun = $status === 'active';
      ?>
        <div class="cp-item cp-item-bot">
          <div class="cp-item-main">
            <b><span class="cp-dot <?= $isRun ? 'is-on' : 'is-off' ?>"></span><?= e((string)$b['name']) ?></b>
            <code>bots/<?= e((string)$b['name']) ?> · <?= e((string)$b['runtime']) ?></code>
            <div class="cp-bot-meta">
              <span>CPU лимит <b><?= (int)$b['cpu_percent'] ?>%</b></span>
              <span>RAM лимит <b><?= (int)$b['memory_mb'] ?> MB</b></span>
              <span>Сейчас <b><?= e(human_bytes((float)($live['memory_bytes'] ?? 0))) ?></b></span>
            </div>
          </div>
          <div class="cp-item-side">
            <span class="cp-pill <?= $isRun ? 'is-ok' : 'is-muted' ?>"><?= $isRun ? 'работает' : e($status) ?></span>
            <?php foreach ([['start','Запустить'],['restart','Перезапуск'],['stop','Остановить']] as [$a,$title]): ?>
              <form method="post">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="bot_action">
                <input type="hidden" name="back" value="bots">
                <input type="hidden" name="id" value="<?= (int)$b['id'] ?>">
                <input type="hidden" name="act" value="<?= e($a) ?>">
                <button class="cp-btn cp-btn-soft"><?= e($title) ?></button>
              </form>
            <?php endforeach; ?>
            <form method="post">
              <?= csrf_field() ?>
              <input type="hidden" name="action" value="bot_install">
              <input type="hidden" name="back" value="bots">
              <input type="hidden" name="id" value="<?= (int)$b['id'] ?>">
              <button class="cp-btn cp-btn-soft">Зависимости</button>
            </form>
            <a class="cp-btn cp-btn-soft" href="/?page=logs&amp;bot=<?= (int)$b['id'] ?>">Логи</a>
            <form method="post" onsubmit="return confirm('Удалить бота <?= e((string)$b['name']) ?>?')">
              <?= csrf_field() ?>
              <input type="hidden" name="action" value="delete_bot">
              <input type="hidden" name="back" value="bots">
              <input type="hidden" name="id" value="<?= (int)$b['id'] ?>">
              <button class="cp-btn cp-btn-danger">Удалить</button>
            </form>
          </div>
        </div>
      <?php endforeach; ?>
    </div>
  <?php else: ?>
    <div class="cp-empty">Ботов пока нет</div>
  <?php endif; ?>
</section>
<?php }


// ============================================================ SSL

function view_ssl(array $user): void
{
    $sites = cp_sites((int)$user['id']);
    ?>
<section class="cp-card">
  <h2>SSL-сертификаты</h2>
  <p class="cp-muted cp-note">Бесплатные сертификаты Let's Encrypt на 90 дней с автоматическим продлением.
     Перед выпуском домен должен указывать на сервер — иначе Let's Encrypt откажет.</p>

  <?php if (!$sites): ?>
    <div class="cp-empty">Сначала создайте сайт в разделе «Сайты»</div>
  <?php else: ?>
    <div class="cp-list">
      <?php foreach ($sites as $s):
        $st = cp_bridge(['action' => 'site-ssl-status', 'user' => (string)$user['username'],
                         'domain' => (string)$s['domain']], 20);
        $has = !empty($st['ssl']);
        $days = (int)($st['days_left'] ?? 0);
      ?>
        <div class="cp-item">
          <div class="cp-item-main">
            <b><?= e((string)$s['domain']) ?></b>
            <?php if ($has): ?>
              <code>действует до <?= e((string)($st['expires'] ?? '')) ?> · осталось <?= $days ?> дней</code>
            <?php else: ?>
              <code>сертификата нет</code>
            <?php endif; ?>
            <?php if ($has): ?>
              <div class="cp-meter cp-meter-ssl"><i style="width:<?= percent((float)$days, 90.0) ?>%"></i></div>
            <?php endif; ?>
          </div>
          <div class="cp-item-side">
            <span class="cp-pill <?= $has ? ($days > 14 ? 'is-ok' : 'is-warn') : 'is-muted' ?>">
              <?= $has ? ($days > 14 ? 'активен' : 'скоро истекает') : 'нет SSL' ?>
            </span>
            <form method="post" class="cp-ssl-form">
              <?= csrf_field() ?>
              <input type="hidden" name="action" value="issue_ssl">
              <input type="hidden" name="back" value="ssl">
              <input type="hidden" name="id" value="<?= (int)$s['id'] ?>">
              <input name="email" type="email" placeholder="ваш@email" required value="<?= e((string)$user['email']) ?>">
              <button class="cp-btn cp-btn-primary"><?= $has ? 'Перевыпустить' : 'Выпустить SSL' ?></button>
            </form>
          </div>
        </div>
      <?php endforeach; ?>
    </div>
  <?php endif; ?>
</section>
<?php }


// ============================================================ логи

function view_logs(array $user): void
{
    $bots = cp_bots((int)$user['id']);
    $sites = cp_sites((int)$user['id']);
    $botId = (int)($_GET['bot'] ?? 0);
    $siteId = (int)($_GET['site'] ?? 0);
    $lines = [];
    $title = '';

    if ($botId > 0) {
        foreach ($bots as $b) if ((int)$b['id'] === $botId) {
            $r = cp_bridge(['action' => 'bot-logs', 'user' => (string)$user['username'], 'bot' => (string)$b['name']], 40);
            $lines = $r['lines'] ?? [];
            $title = 'Бот ' . (string)$b['name'];
        }
    } elseif ($siteId > 0) {
        foreach ($sites as $s) if ((int)$s['id'] === $siteId) {
            $r = cp_bridge(['action' => 'site-logs', 'user' => (string)$user['username'],
                            'domain' => (string)$s['domain'], 'kind' => (string)($_GET['kind'] ?? 'error')], 40);
            $lines = $r['lines'] ?? [];
            $title = 'Сайт ' . (string)$s['domain'];
        }
    }
    ?>
<section class="cp-card">
  <h2>Что смотрим</h2>
  <div class="cp-chips">
    <?php foreach ($bots as $b): ?>
      <a class="cp-chip<?= $botId === (int)$b['id'] ? ' is-active' : '' ?>" href="/?page=logs&amp;bot=<?= (int)$b['id'] ?>">⬢ <?= e((string)$b['name']) ?></a>
    <?php endforeach; ?>
    <?php foreach ($sites as $s): ?>
      <a class="cp-chip<?= $siteId === (int)$s['id'] ? ' is-active' : '' ?>" href="/?page=logs&amp;site=<?= (int)$s['id'] ?>">◍ <?= e((string)$s['domain']) ?></a>
    <?php endforeach; ?>
    <?php if (!$bots && !$sites): ?><span class="cp-muted">Нечего показывать — создайте сайт или бота</span><?php endif; ?>
  </div>
</section>

<?php if ($title): ?>
<section class="cp-card">
  <div class="cp-card-head">
    <h2><?= e($title) ?></h2>
    <?php if ($siteId): ?>
      <div class="cp-chips">
        <a class="cp-chip<?= ($_GET['kind'] ?? 'error') === 'error' ? ' is-active' : '' ?>" href="/?page=logs&amp;site=<?= $siteId ?>&amp;kind=error">Ошибки</a>
        <a class="cp-chip<?= ($_GET['kind'] ?? '') === 'access' ? ' is-active' : '' ?>" href="/?page=logs&amp;site=<?= $siteId ?>&amp;kind=access">Запросы</a>
      </div>
    <?php endif; ?>
  </div>
  <?php if ($lines): ?>
    <pre class="cp-log"><?= e(implode("\n", array_map('strval', $lines))) ?></pre>
  <?php else: ?>
    <div class="cp-empty">Лог пуст</div>
  <?php endif; ?>
</section>
<?php endif; ?>
<?php }


// ============================================================ FTP

function view_ftp(array $user): void
{
    $host = parse_url((string)cp_config('cp_url'), PHP_URL_HOST) ?: (string)cp_config('base_domain');
    $home = cp_user_root($user);
    ?>
<section class="cp-card">
  <h2>FTP-доступ</h2>
  <p class="cp-muted cp-note">Вы видите только свою папку — выйти за её пределы нельзя.
     Внутри: <code>sites/</code> — файлы сайтов, <code>bots/</code> — код ботов, <code>logs/</code> — логи.</p>

  <div class="cp-creds">
    <div><span>Сервер</span><b data-copy="<?= e($host) ?>"><?= e($host) ?></b></div>
    <div><span>Порт</span><b data-copy="21">21</b></div>
    <div><span>Логин</span><b data-copy="<?= e((string)$user['username']) ?>"><?= e((string)$user['username']) ?></b></div>
    <div><span>Пароль</span><b data-copy="<?= e((string)$user['ftp_password']) ?>"><?= e((string)$user['ftp_password']) ?></b></div>
    <div class="cp-creds-wide"><span>Ваша папка</span><b><?= e($home) ?></b></div>
  </div>
  <p class="cp-muted cp-note">Нажмите на значение, чтобы скопировать. Подходит любой FTP-клиент — например FileZilla.</p>
</section>

<section class="cp-card">
  <h2>Пароль от панели</h2>
  <form method="post" class="cp-form-inline">
    <?= csrf_field() ?>
    <input type="hidden" name="action" value="change_password">
    <input type="hidden" name="back" value="ftp">
    <div class="cp-row">
      <label><span>Текущий пароль</span><input type="password" name="current_password" required autocomplete="current-password"></label>
      <label><span>Новый пароль</span><input type="password" name="new_password" required minlength="10" autocomplete="new-password"></label>
    </div>
    <button class="cp-btn cp-btn-primary">Сменить пароль</button>
  </form>
</section>
<?php }
