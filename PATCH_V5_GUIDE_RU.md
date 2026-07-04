# HYPER-HOST v5 patch

## Что добавлено

- Файловый менеджер в браузере:
  - просмотр папок;
  - загрузка файлов;
  - удаление файлов/папок;
  - создание папок;
  - редактор PHP/HTML/CSS/JS/TXT прямо в панели.
- FTP переделан на общий корень:
  - `common/` — личная общая папка FTP;
  - `sites/` — все сайты сервера;
  - `bots/` — все боты сервера.
- Исправлены права после FileZilla/FTP:
  - добавлены ACL;
  - `www-data` получает доступ на чтение/запись;
  - папки получают `g+s`, чтобы новые файлы не ломали сайт.
- Боты переведены на PM2, как ты запускал вручную:
  - Python: `pm2 start bot.py --interpreter python3 --name mystockbot`;
  - Node.js и PHP тоже поддерживаются;
  - список ботов в панели;
  - Start / Stop / Restart / Deps / Logs;
  - автозапуск через `pm2 startup` + `pm2 save`.
- Backup:
  - ручной backup сайтов/ботов/баз/панели;
  - расписание через `/etc/cron.d`.
- DNS-менеджер:
  - зоны;
  - A/AAAA/CNAME/MX/TXT записи;
  - запись zone-файлов для bind9.
- SSL:
  - список сертификатов;
  - дни до окончания;
  - выпуск SSL;
  - запуск `certbot renew` из панели.
- PHP-версии:
  - выбор установленной PHP-FPM версии для сайта;
  - панель меняет `fastcgi_pass` в Nginx-конфиге сайта.
- Cron-задачи:
  - создание задач из панели;
  - удаление задач;
  - запись в `/etc/cron.d`.
- Логи сайтов:
  - access/error;
  - фильтр ошибок;
  - просмотр прямо в UI.
- Безопасность:
  - 2FA TOTP;
  - IP allowlist;
  - журнал входов.
- Дизайн:
  - тёмная правая рабочая зона;
  - Bootstrap 5;
  - FontAwesome;
  - стиль ближе к современной хостинг-панели;
  - кнопка `Что добавить` убрана.

## Как залить v5 в GitHub

Распакуй архив и скопируй содержимое папки `hyper-host-v5` поверх своего локального репозитория:

```bash
cd hyper-hosting-panel
cp -r /path/to/hyper-host-v5/* ./

git status
git add .
git commit -m "HYPER-HOST v5: file manager, PM2 bots, backups, DNS, SSL, cron and security"
git push origin main
```

## Как обновить сервер из GitHub

На сервер ничего вручную не кидай. После push в GitHub выполни на сервере:

```bash
cd /root

if [ ! -d /root/hyper-hosting-panel/.git ]; then
  git clone https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel
fi

cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl stats-json
sudo nginx -t
sudo systemctl reload nginx
```

## Проверка FTP

Создай FTP из панели или через SSH:

```bash
sudo hyper-host-ctl create-ftp hyperhost 'StrongFTPPassword123!'
```

Подключение:

```text
Хост: IP_СЕРВЕРА
Порт: 21
Имя пользователя: hhftp_hyperhost
Пароль: StrongFTPPassword123!
Passive mode: ON
```

После входа должны быть папки:

```text
common/
sites/
bots/
```

В `sites/` будут все сайты, например:

```text
sites/hyper-host.pw/public_html/
```

## Если после FTP файл не сохраняется или сайт не видит изменения

```bash
sudo hyper-host-ctl repair
sudo systemctl restart vsftpd
sudo systemctl reload nginx
```

## Проверка PM2-ботов

```bash
pm2 list
pm2 logs
pm2 save
```

Создать Python-бота через SSH:

```bash
sudo hyper-host-ctl bot-create mystockbot python bot.py 512
```

Это аналогично:

```bash
pm2 start bot.py --interpreter python3 --name mystockbot --max-memory-restart 512M
```

Установить зависимости:

```bash
sudo hyper-host-ctl bot-install-requirements mystockbot
```

Логи:

```bash
sudo hyper-host-ctl bot logs mystockbot
```

## Проверка новых команд

```bash
sudo hyper-host-ctl php-list-json
sudo hyper-host-ctl ssl-status-json
sudo hyper-host-ctl backup-list-json
sudo hyper-host-ctl bot-list-json
sudo hyper-host-ctl stats-json
sudo hyper-host-ctl sync-json
```
