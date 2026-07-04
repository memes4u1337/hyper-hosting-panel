# HYPER-HOST

Личная хостинг-панель для своего Ubuntu-сервера.

**powered by memes4u1337**

## Возможности

- Сайты и домены через Nginx + PHP-FPM.
- Автоматическое создание папки `public_html` при создании сайта.
- Отдельный раздел `Папки`: создать папку-сайт без домена.
- FTP через VSFTPD.
- FTP-аккаунт показывает: хост, имя пользователя, пароль.
- У каждого FTP есть общая папка `common`.
- Привязка FTP к сайту/папке/боту через папку `site`.
- MariaDB/MySQL и phpMyAdmin.
- Внешние подключения MySQL.
- Telegram/Node/PHP/custom боты как systemd-сервисы 24/7.
- Установка зависимостей ботов из панели.
- Статистика железа и статусы сервисов.
- Bootstrap + FontAwesome интерфейс.

## Установка

```bash
cd /root
git clone https://github.com/memes4u1337/hyper-hosting-panel.git
cd hyper-hosting-panel
sudo bash install.sh
```

Со своим логином и паролем:

```bash
ADMIN_USER=admin ADMIN_PASS='StrongPassword123!' sudo -E bash install.sh
```

С доменом панели:

```bash
PANEL_DOMAIN=panel.hyper-host.pw ADMIN_USER=admin ADMIN_PASS='StrongPassword123!' sudo -E bash install.sh
```

## Обновление

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

## Пути

```text
/var/www/hyper-host                 панель
/opt/hyper-host/data/hyperhost.sqlite база панели
/var/www/hyper-host-sites           сайты и папки
/var/www/hyper-host-bots            боты
/var/www/hyper-host-ftp             FTP home-директории
/usr/local/sbin/hyper-host-ctl      root-команда
```
