# HYPER-HOST

**HYPER-HOST** — личная хостинг-панель для своего Ubuntu/VDS сервера.

Powered by **memes4u1337**.

## Возможности v5

- Сайты и домены на Nginx + PHP-FPM.
- phpMyAdmin.
- MariaDB/MySQL и внешние подключения.
- FTP через VSFTPD.
- FTP с общим корнем: `common/`, `sites/`, `bots/`.
- Файловый менеджер в браузере: загрузка, удаление, редактор PHP/HTML/CSS/JS/TXT.
- PM2-боты 24/7:
  - Python;
  - Node.js;
  - PHP;
  - custom bash.
- Start / Stop / Restart / Logs / Deps для ботов.
- Backup сайтов, баз, ботов и панели.
- Backup по расписанию через cron.
- DNS-менеджер для bind9.
- SSL-статусы и автопродление через certbot.
- PHP-версии для каждого сайта.
- Cron-задачи из панели.
- Логи сайтов в UI.
- 2FA, IP allowlist, журнал входов.
- Статистика сервера: CPU, RAM, диск, сервисы, PM2.

## Установка

```bash
cd /root
git clone https://github.com/memes4u1337/hyper-hosting-panel.git
cd hyper-hosting-panel
ADMIN_USER=admin ADMIN_PASS='StrongPassword123!' sudo -E bash install.sh
```

Открыть:

```text
http://IP_СЕРВЕРА/
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


## HYPER-HOST v6

Добавлено: загрузчик ботов (`bot.py`, `.env`, `requirements.txt`), автоустановка зависимостей перед запуском PM2 24/7, FTP структура `common/sites/bots`, проверка DNS перед SSL, улучшенный файловый менеджер и тёмный UI.

Обновление сервера:

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
