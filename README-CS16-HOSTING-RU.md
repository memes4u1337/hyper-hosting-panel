# HYPER-HOST — панель хостинга Counter-Strike 1.6

Патч добавляет отдельную панель игрового хостинга на домен `www.avito.hyper-host.pw`, не ломая основную панель HYPER-HOST.

## Что установится

- отдельный сайт `www.avito.hyper-host.pw` через штатный HYPER-HOST Nginx runtime;
- MariaDB база `hyper_cs16` для серверов, статистики, истории игроков и аудита;
- SteamCMD + официальный HLDS Counter-Strike 1.6 (App 90);
- Metamod-R + AMX Mod X 1.9;
- опциональный профиль ReHLDS + ReGameDLL_CS;
- отдельный `systemd`-сервис `hyper-cs16@ID.service` на каждый игровой сервер;
- мониторинг `hyper-cs16-monitor.service`;
- FTP каждого игрового сервера через уже установленный FTP HYPER-HOST;
- firewall UDP диапазон `27015-27100`;
- RCON, игроки, Kick/Ban, карты, AMXX, конфиги, логи, графики и переустановка.

## Установка

```bash
cd /root/hyper-hosting-panel-main
sudo bash install-cs16-panel.sh
```

Если DNS домена уже указывает на сервер и нужно сразу выпустить SSL:

```bash
sudo CS16_SSL_EMAIL=you@example.com bash install-cs16-panel.sh
```

Если публичный IP нужно указать вручную:

```bash
sudo CS16_PUBLIC_IP=90.189.208.25 CS16_SSL_EMAIL=you@example.com bash install-cs16-panel.sh
```

По умолчанию установщик скачивает базовую сборку и сразу создаёт первый сервер на `27015`, 16 слотов, `de_dust2`.

Чтобы поставить только веб-панель без загрузки HLDS:

```bash
sudo CS16_SKIP_GAME_DOWNLOAD=1 bash install-cs16-panel.sh
```

## DNS и доступ из Интернета

Создай `A`-запись:

```text
www.avito.hyper-host.pw -> публичный IPv4 сервера
```

Если Ubuntu находится за домашним/офисным роутером (NAT), на роутере нужен проброс UDP портов игрового сервера, например:

```text
UDP 27015 -> IP Ubuntu:27015
```

Для нескольких серверов удобно пробросить диапазон `27015-27100/UDP`.

Патч сам открывает этот диапазон в UFW, но физический NAT/роутер он изменить не может.

## FTP

При создании игрового сервера создаётся отдельный FTP-аккаунт. Его реквизиты показываются во вкладке **FTP**. FTP сразу открывается в корне конкретного HLDS-сервера.

Обычно:

```text
Host: публичный IP HYPER-HOST
Port: 21
Login: cs16_ID
Password: отображается в панели
```

## Управление из консоли Ubuntu

Диагностика:

```bash
sudo hyper-cs16-ctl doctor
```

Проверить сервер:

```bash
sudo hyper-cs16-ctl status 1
```

Запуск / остановка / рестарт:

```bash
sudo hyper-cs16-ctl start 1
sudo hyper-cs16-ctl stop 1
sudo hyper-cs16-ctl restart 1
```

RCON:

```bash
sudo hyper-cs16-ctl rcon 1 "status"
sudo hyper-cs16-ctl rcon 1 "amxx plugins"
sudo hyper-cs16-ctl rcon 1 "meta list"
```

Карты:

```bash
sudo hyper-cs16-ctl maps 1
sudo hyper-cs16-ctl change-map 1 de_dust2
```

Плагины:

```bash
sudo hyper-cs16-ctl plugins 1
sudo hyper-cs16-ctl plugin-toggle 1 admin.amxx on
```

Проверить/обновить Steam-файлы:

```bash
sudo hyper-cs16-ctl update 1
```

Переустановить сборку:

```bash
sudo hyper-cs16-ctl reinstall 1
```

Перед переустановкой панель сохраняет важные AMXX-конфиги и плагины в `/opt/hyper-cs16/backups/`, а после чистой установки автоматически возвращает `users.ini`, `plugins.ini` и `.amxx` файлы.

## Где лежат файлы

```text
/srv/hyper-cs16/base-hlds          базовый шаблон HLDS
/srv/hyper-cs16/servers/1          сервер №1
/etc/hyper-cs16/servers/1.json     закрытая runtime-конфигурация
/opt/hyper-cs16/backups            резервные копии перед reinstall
/var/lib/hyper-cs16/uploads        закрытый staging BSP/AMXX загрузок
/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html
```

## systemd

```bash
systemctl status hyper-cs16@1
journalctl -u hyper-cs16@1 -f
systemctl status hyper-cs16-monitor
```

## Основные функции веб-панели

- несколько независимых CS 1.6 серверов;
- игровые порты 27015-27100 и слоты 1-32;
- обычный HLDS или ReHLDS профиль;
- Start / Stop / Restart;
- обновление Steam-файлов;
- переустановка;
- карта, hostname, пароль сервера, RCON;
- живые CPU/RAM/Uptime/карта/онлайн;
- график игроков/CPU за 24 часа;
- история игроков в SQL;
- список игроков онлайн;
- Kick / Ban 30 min;
- полноценная RCON-консоль для любых серверных команд;
- список карт и `changelevel`;
- загрузка `.bsp` из панели;
- полный FTP для модов/моделей/звуков/карт;
- редактор `server.cfg`, `amxx.cfg`, `users.ini`, `plugins.ini`, `modules.ini`, `mapcycle.txt`, `maps.ini`;
- загрузка `.amxx` прямо из панели и включение/выключение плагинов;
- `journalctl` лог сервера;
- аудит действий администратора.

## Важно

`RCON` и FTP-пароли хранятся только на сервере. Runtime-файлы закрыты правами Linux. Веб-пользователь не получает произвольный root-shell: `sudo` разрешён только для валидирующего `/usr/local/sbin/hyper-cs16-ctl`. Редактор конфигов передаёт содержимое контроллеру через stdin, а BSP/AMXX загружаются только через закрытый staging с проверкой владельца, inode, размера и расширения — root-контроллер не принимает произвольные пути от PHP.
