# Быстрый гайд HYPER-HOST

## 1. Залить на GitHub

На своём ПК:

```bash
git init
git add .
git commit -m "HYPER-HOST panel"
git branch -M main
git remote add origin https://github.com/YOUR_LOGIN/HYPER-HOST.git
git push -u origin main
```

## 2. Установить на сервер

На чистом сервере Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y git

git clone https://github.com/YOUR_LOGIN/HYPER-HOST.git
cd HYPER-HOST
sudo bash install.sh
```

Сразу со своим логином и паролем:

```bash
ADMIN_USER=admin ADMIN_PASS='StrongPassword123!' sudo -E bash install.sh
```

## 3. Открыть панель

После установки открой:

```text
http://IP_СЕРВЕРА/
```

IP установщик определяет автоматически и покажет в конце.

## 4. Создать сайт

1. Открой раздел **Сайты**.
2. Введи домен: `example.com`.
3. Если надо, добавь alias: `www.example.com`.
4. Нажми **Создать сайт**.

Файлы сайта будут тут:

```text
/var/www/hyper-host-sites/example.com/public_html
```

## 5. Привязать домен

В DNS домена создай A-запись:

```text
example.com -> IP_СЕРВЕРА
www.example.com -> IP_СЕРВЕРА
```

## 6. Создать FTP

1. Открой **FTP**.
2. Создай логин и пароль.
3. Выбери папку сайта или бота.

Подключение:

```text
Host: IP_СЕРВЕРА
Port: 21
Login: hhftp_логин
Password: твой пароль
```

## 7. Создать базу и открыть phpMyAdmin

1. Открой **Базы данных**.
2. Создай базу, пользователя и пароль.
3. Открой phpMyAdmin из панели.

Прямой адрес:

```text
http://IP_СЕРВЕРА/phpmyadmin
```

## 8. Внешние подключения MySQL

1. Открой **Настройки**.
2. Нажми **Включить внешний доступ**.
3. При создании базы включи **Разрешить внешний доступ**.

Данные подключения:

```text
Host: IP_СЕРВЕРА
Port: 3306
Database: имя базы
User: имя пользователя
Password: пароль
```

## 9. Создать Telegram-бота

1. Открой **Telegram-боты**.
2. Введи имя: `mybot`.
3. Runtime: `Python`.
4. Команда: `python3 main.py`.
5. Создай FTP для папки бота.
6. Загрузи файлы бота.
7. Нажми **Старт**.

Папка бота:

```text
/var/www/hyper-host-bots/mybot
```

## 10. SSL

В разделе **Сайты** нажми действия → SSL, укажи email.

Важно: DNS домена уже должен смотреть на сервер.
