# HYPER-HOST v14 — удобная серверная команда `sudo hyper`

Добавлена короткая CLI-команда:

```bash
sudo hyper help
```

## Основные команды

```bash
sudo hyper dev
sudo hyper stats
sudo hyper status
sudo hyper bots
sudo hyper sites
sudo hyper ssl status
sudo hyper ftp
sudo hyper dbs
sudo hyper php
sudo hyper repair
sudo hyper update
```

## Боты

```bash
sudo hyper bot list
sudo hyper bot create 123 python bot.py 512
sudo hyper bot start 123
sudo hyper bot stop 123
sudo hyper bot restart 123
sudo hyper bot logs 123
sudo hyper bot fix 123
sudo hyper bot delete 123
sudo hyper bot delete 123 --delete-files
sudo hyper bot persist
sudo hyper bot doctor
```

`sudo hyper bot persist` включает 24/7 автозапуск через systemd/PM2.

## SSL

```bash
sudo hyper ssl check hyper-host.pw
sudo hyper ssl fix hyper-host.pw
sudo hyper ssl issue hyper-host.pw admin@example.com
sudo hyper ssl renew
```

## Обновление панели из GitHub

```bash
sudo hyper update
```

Команда сама делает `git fetch/reset`, запускает `install.sh`, `repair`, `pm2-persist`, проверяет nginx и перезапускает сервисы.

## Низкоуровневые команды

Любую старую команду `hyper-host-ctl` можно вызвать через:

```bash
sudo hyper raw stats-json
sudo hyper raw sync-json
sudo hyper raw add-site example.com
```
