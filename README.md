# HYPER-HOST

Личная хостинг-панель для сайтов, FTP, баз данных, phpMyAdmin, SSL и Telegram-ботов 24/7.

Разработчик: **powered by memes4u1337**

## v10

- исправлена логика SSL для серверов за NAT;
- добавлена ручная настройка публичного IP для SSL;
- исправлена ошибка `home: unbound variable` в `hyper-host-ctl repair`;
- добавлена очистка локальных дублей Telegram-ботов при `TelegramConflictError`;
- добавлена кнопка Fix conflict в ботах;
- добавлен self-signed сертификат на IP.

## Установка

```bash
sudo bash install.sh
```

## Обновление из GitHub

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo nginx -t
sudo systemctl reload nginx
```

## Публичный IP для SSL

Если сервер внутри сети, например `192.168.0.179`, а домен смотрит на публичный IP `90.189.208.25`, сохрани публичный IP:

```bash
sudo hyper-host-ctl public-ip set 90.189.208.25
```

Проверка:

```bash
sudo hyper-host-ctl ssl-check-json hyper-host.pw
```

Выпуск SSL:

```bash
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

## HYPER-HOST v11

- Fast cache for dashboard, bots, SSL and PHP version checks.
- Better dark UI and smoother buttons/cards.
- SSL ACME challenge fix for `/.well-known/acme-challenge/`.
- `hyper-host-ctl ssl-fix-site DOMAIN` command.
- PM2 bot lock-file and local duplicate Telegram token cleanup.
