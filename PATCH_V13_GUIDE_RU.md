# HYPER-HOST v13 — PM2 24/7 автозапуск ботов

## Что исправлено

В этом патче исправлена главная проблема с ботами: после запуска из панели они больше не зависят от открытой панели, SSH-консоли или браузера.

Теперь HYPER-HOST делает так:

1. запускает бота через PM2 от отдельного пользователя `hyperbot`;
2. сохраняет список процессов через `pm2 save`;
3. создаёт systemd-сервис `hyperbot-pm2.service`;
4. включает автозапуск сервиса;
5. после перезагрузки сервера PM2 делает `resurrect` и поднимает сохранённых ботов;
6. после Start/Stop/Restart/Delete список PM2 снова сохраняется.

## Важная команда после обновления

```bash
sudo hyper-host-ctl pm2-persist
```

Она принудительно включает 24/7-режим для PM2.

## Проверка

```bash
sudo hyper-host-ctl bot-doctor
systemctl status hyperbot-pm2.service --no-pager
sudo -u hyperbot -H env HOME=/var/www/hyper-host-bots PM2_HOME=/var/www/hyper-host-bots/.pm2 pm2 list
```

В `bot-doctor` должно быть видно:

```text
pm2_systemd: enabled / active
pm2_dump: /var/www/hyper-host-bots/.pm2/dump.pm2
```

## Как обновить сервер

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x install.sh uninstall.sh scripts/hhctl || true

sudo bash install.sh

sudo hyper-host-ctl repair
sudo hyper-host-ctl pm2-persist
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl ssl-fix-site hyper-host.pw
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl stats-json
sudo hyper-host-ctl bot-doctor

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## Проверка бота 123

```bash
sudo hyper-host-ctl bot kill-conflicts 123
sudo hyper-host-ctl bot restart 123
sudo hyper-host-ctl pm2-persist
sudo hyper-host-ctl bot logs 123
```

Если после этого снова `TelegramConflictError`, значит такой же Telegram-токен запущен вне этого сервера: старый ПК, другой VPS, Docker, другой PM2 или другой хостинг.
