# HYPER-HOST v7 — фикс PM2-ботов и FTP-mount

## Что исправлено

### Боты

- PM2 теперь запускается не от случайного root-контекста, а через отдельного пользователя `hyperbot`.
- Используется отдельный `PM2_HOME=/var/www/hyper-host-bots/.pm2`.
- При создании/загрузке бота:
  1. создаётся папка `/var/www/hyper-host-bots/ИМЯ_БОТА`;
  2. загружается `bot.py` / `.env` / `requirements.txt`;
  3. если есть `requirements.txt`, создаётся `venv`;
  4. ставятся зависимости;
  5. бот запускается через PM2 с `--name` равным имени бота;
  6. выполняется `pm2 save`, чтобы бот жил после перезагрузки.
- Добавлена диагностика:

```bash
sudo hyper-host-ctl bot-doctor
```

### Node.js / PM2

Ubuntu 22.04 часто ставит Node.js 12 из стандартного репозитория. Для современного PM2 это плохо. В v7 установщик проверяет версию Node.js и при необходимости ставит Node.js 20.x, потом PM2:

```bash
npm install -g pm2@latest
```

### FTP mount

- `repair` больше не использует старый home FTP-пользователя, если он был случайно выставлен в `public_html`.
- FTP-пользователям принудительно выставляется home:

```text
/var/www/hyper-host-ftp/hhftp_USERNAME
```

- старые рекурсивные bind-mount'ы чистятся из `/etc/fstab` и снимаются.

## Как обновить сервер после загрузки v7 в GitHub

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl bot-doctor
sudo hyper-host-ctl sync-json

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## Как проверить ботов

```bash
sudo hyper-host-ctl bot-doctor
sudo hyper-host-ctl bot-list-json
sudo -u hyperbot -H env HOME=/var/www/hyper-host-bots PM2_HOME=/var/www/hyper-host-bots/.pm2 pm2 list
```

## Как вручную запустить существующего Python-бота

Допустим бот лежит тут:

```text
/var/www/hyper-host-bots/mystockbot
```

Команды:

```bash
sudo chown -R hyperbot:www-data /var/www/hyper-host-bots/mystockbot
sudo chmod -R ug+rwX,o+rX /var/www/hyper-host-bots/mystockbot

cd /var/www/hyper-host-bots/mystockbot
sudo -u hyperbot -H python3 -m venv venv
sudo -u hyperbot -H ./venv/bin/pip install --upgrade pip wheel setuptools
sudo -u hyperbot -H ./venv/bin/pip install -r requirements.txt

sudo -u hyperbot -H env HOME=/var/www/hyper-host-bots PM2_HOME=/var/www/hyper-host-bots/.pm2 pm2 delete mystockbot || true
sudo -u hyperbot -H env HOME=/var/www/hyper-host-bots PM2_HOME=/var/www/hyper-host-bots/.pm2 pm2 start ./venv/bin/python --name mystockbot -- bot.py
sudo -u hyperbot -H env HOME=/var/www/hyper-host-bots PM2_HOME=/var/www/hyper-host-bots/.pm2 pm2 save
```

Но после v7 лучше делать через панель или так:

```bash
sudo hyper-host-ctl bot-create mystockbot python bot.py 512
sudo hyper-host-ctl bot logs mystockbot
```


## HYPER-HOST v8

- В разделе **Боты** добавлено удаление через модальное окно с подтверждением.
- Можно удалить только PM2-процесс и оставить файлы.
- Можно удалить PM2-процесс и всю папку бота с сервера; для этого нужно ввести точное имя бота.
- Установщик перед `chown` автоматически снимает старые рекурсивные FTP bind-mount'ы, из-за которых была ошибка `Circular directory structure`.
- `repair` больше не должен оставлять mount'ы внутри `public_html/common/...`.
