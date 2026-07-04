# HYPER-HOST

**HYPER-HOST** — личная hosting panel для своего сервера: сайты, домены, PHP, phpMyAdmin, FTP, базы данных и Telegram-боты.

Разработчик: **powered by memes4u1337**

> Панель сделана для личного использования на своём сервере, не как коммерческий shared-hosting. Устанавливай на чистый VPS/сервер с Ubuntu/Debian.

---

## Что умеет

- Автоматический установщик `install.sh`.
- Автоопределение IP сервера.
- Установка Nginx, PHP-FPM, MariaDB, phpMyAdmin, VSFTPD, Certbot.
- Создание сайтов и привязка доменов.
- Генерация Nginx-конфига для каждого сайта.
- PHP-сайты через PHP-FPM.
- Доступ к phpMyAdmin из панели.
- Создание FTP-подключений для сайтов и папок ботов.
- Создание MySQL/MariaDB баз и пользователей.
- Опция внешних подключений к MySQL/MariaDB.
- Создание и управление Telegram-ботами через systemd: start / stop / restart / logs.
- Тёмный красивый интерфейс.
- SQLite-база самой панели, без лишней сложности.

---

## Быстрая установка

```bash
git clone https://github.com/YOUR_LOGIN/HYPER-HOST.git
cd HYPER-HOST
sudo bash install.sh
```

После установки в конце будет показано:

- URL панели
- логин
- пароль
- IP сервера

Обычно панель будет доступна по:

```text
http://SERVER_IP/
```

---

## Установка с готовым логином/паролем

```bash
ADMIN_USER=admin ADMIN_PASS='StrongPassword123!' sudo -E bash install.sh
```

Можно сразу указать домен панели:

```bash
PANEL_DOMAIN=panel.example.com ADMIN_USER=admin ADMIN_PASS='StrongPassword123!' sudo -E bash install.sh
```

---

## Как залить на GitHub

```bash
git init
git add .
git commit -m "Initial HYPER-HOST panel"
git branch -M main
git remote add origin https://github.com/YOUR_LOGIN/HYPER-HOST.git
git push -u origin main
```

Потом на сервере:

```bash
git clone https://github.com/YOUR_LOGIN/HYPER-HOST.git
cd HYPER-HOST
sudo bash install.sh
```

---

## Где лежат файлы после установки

```text
/var/www/hyper-host/                 сама панель
/opt/hyper-host/                     данные, шаблоны, служебные файлы
/opt/hyper-host/data/hyperhost.sqlite база панели
/var/www/hyper-host-sites/           сайты
/var/www/hyper-host-bots/            Telegram-боты
/usr/local/sbin/hyper-host-ctl       root-команды панели
/etc/nginx/sites-available/          nginx-конфиги сайтов
/etc/systemd/system/hyperbot-*.service systemd-сервисы ботов
```

---

## Домены

1. В DNS домена создай `A` запись на IP сервера.
2. В панели открой **Сайты**.
3. Добавь домен, например:

```text
example.com
```

4. Файлы сайта будут тут:

```text
/var/www/hyper-host-sites/example.com/public_html
```

---

## FTP

В панели открой **FTP** и создай пользователя для сайта или папки бота.

Подключение:

```text
Host: IP сервера
Port: 21
Login: созданный FTP логин
Password: пароль, который указал при создании
```

Пассивные порты по умолчанию:

```text
40000-40100
```

---

## phpMyAdmin

После установки phpMyAdmin доступен из панели и напрямую:

```text
http://SERVER_IP/phpmyadmin
```

Логин и пароль — от созданного MySQL-пользователя, который создаёшь в разделе **Базы данных**.

---

## Внешние подключения MySQL/MariaDB

В панели открой **Настройки** и включи внешние подключения.

Также при создании базы включи галочку **Разрешить внешний доступ**.

Подключение:

```text
Host: IP сервера
Port: 3306
Database: имя базы
User: имя пользователя
Password: пароль
```

Важно: открытый 3306 порт лучше использовать только с сильными паролями и по возможности ограничивать доступ через firewall.

---

## Telegram-боты

В панели открой **Боты**.

Пример Python-бота:

```text
Имя: mybot
Тип: python
Команда запуска: python3 main.py
```

Папка будет создана тут:

```text
/var/www/hyper-host-bots/mybot
```

Загрузи туда код бота через FTP и нажми **Старт**.

---

## SSL для сайта

В разделе **Сайты** можно выпустить SSL через Let's Encrypt, если DNS домена уже направлен на сервер.

---

## Удаление панели

```bash
sudo bash uninstall.sh
```

По умолчанию удаление не трогает папки сайтов и ботов. Внутри `uninstall.sh` есть отдельная переменная, если нужно удалить всё полностью.

---

## Поддерживаемые ОС

- Ubuntu 22.04 / 24.04
- Debian 11 / 12

Лучше ставить на чистый сервер без Hestia/Vesta/CyberPanel, потому что они тоже управляют Nginx/Apache/PHP/FTP и могут конфликтовать.

## HYPER-HOST v3

В v3 исправлены сохранение данных панели, отображение статистики сервера и страница FTP.

Главные изменения:

- панель больше не считает успешные `hyper-host-ctl` команды ошибками;
- `stats-json` корректно отображается в дашборде;
- FTP показывает хост, имя пользователя и пароль;
- добавлена смена FTP-пароля из панели;
- добавлена команда `hyper-host-ctl ftp-password USER PASS`;
- добавлена миграция SQLite для `ftp_accounts.password_plain`;
- обновлён интерфейс и меню.
