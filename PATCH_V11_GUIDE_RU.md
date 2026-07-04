# HYPER-HOST v11 patch

## Что исправлено

### 1. Ускорение панели

В v11 добавлен быстрый кэш для тяжёлых команд панели:

- `stats-json`
- `bot-list-json`
- `ssl-status-json`
- `ssl-check-json`
- `php-list-json`

Теперь дашборд, SSL-страница и список ботов не должны каждый раз долго ждать `systemctl`, `pm2`, `dig`, `curl` и другие серверные проверки.

Кэш чистится автоматически при:

- ремонте панели;
- синхронизации ресурсов;
- SSL fix;
- изменении ресурсов через панель.

Папка кэша:

```text
/opt/hyper-host/cache
```

### 2. Дизайн

Добавлен более красивый UI:

- улучшенная тёмная тема;
- красивые hover-эффекты;
- улучшенные карточки;
- плавные кнопки;
- бейдж fast mode;
- улучшенная визуальная сетка;
- более аккуратные таблицы и панели.

### 3. SSL / Let's Encrypt

Главный фикс: Nginx теперь явно разрешает:

```text
/.well-known/acme-challenge/
```

Раньше эта папка могла блокироваться правилом:

```nginx
location ~ /\. { deny all; }
```

Из-за этого панель писала:

```text
Nginx локально не отдаёт /.well-known/acme-challenge
```

В v11 добавлено:

```bash
sudo hyper-host-ctl ssl-fix-site DOMAIN
```

Например:

```bash
sudo hyper-host-ctl ssl-fix-site hyper-host.pw
sudo hyper-host-ctl ssl-check-json hyper-host.pw
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

Также в панели на странице SSL добавлена кнопка:

```text
Fix ACME
```

### 4. Боты PM2 / TelegramConflictError

В v11 запуск ботов стал строже:

- перед start/restart панель гасит локальные дубли;
- добавлен lock-файл `.hyper-bot.lock`, чтобы один и тот же бот не запускался два раза локально;
- панель ищет одинаковые Telegram-токены в папках ботов и выключает локальные дубли;
- перед запуском делает `deleteWebhook?drop_pending_updates=true`, если найден Telegram token.

Если после этого `TelegramConflictError` остаётся, значит этот же токен запущен не на этом сервере: старый VPS, домашний ПК, Docker, другой PM2 или другой хостинг.

## Как обновить сервер из GitHub

После заливки v11 в GitHub:

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x install.sh uninstall.sh scripts/hhctl || true

sudo bash install.sh

sudo hyper-host-ctl repair
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl ssl-fix-site hyper-host.pw
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl stats-json
sudo hyper-host-ctl bot-doctor

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## Проверка SSL

```bash
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl ssl-fix-site hyper-host.pw
sudo hyper-host-ctl ssl-check-json hyper-host.pw
```

Если `certbot_ready: true`, выпускай:

```bash
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

## Проверка бота

```bash
sudo hyper-host-ctl bot kill-conflicts 123
sudo hyper-host-ctl bot restart 123
sudo hyper-host-ctl bot logs 123
```

Если ошибка `TelegramConflictError` осталась, ищи второй запуск токена вне этой панели.
