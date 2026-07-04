# HYPER-HOST v5 — быстрый старт

## Установка с GitHub

```bash
ssh root@IP_СЕРВЕРА

apt update
apt install -y git curl unzip ca-certificates sudo tar

cd /root
git clone https://github.com/memes4u1337/hyper-hosting-panel.git
cd hyper-hosting-panel

ADMIN_USER=admin ADMIN_PASS='StrongPassword123!' sudo -E bash install.sh
```

## Обновление с GitHub

```bash
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

## FTP

Создай FTP в панели или так:

```bash
sudo hyper-host-ctl create-ftp hyperhost 'StrongFTPPassword123!'
```

Подключение:

```text
Host: IP_СЕРВЕРА
Port: 21
Login: hhftp_hyperhost
Password: StrongFTPPassword123!
```

Внутри FTP:

```text
common/
sites/
bots/
```

## Боты PM2

Python:

```bash
sudo hyper-host-ctl bot-create mystockbot python bot.py 512
sudo hyper-host-ctl bot-install-requirements mystockbot
sudo hyper-host-ctl bot restart mystockbot
sudo hyper-host-ctl bot logs mystockbot
```

PM2 напрямую:

```bash
pm2 list
pm2 logs mystockbot
pm2 restart mystockbot
pm2 save
```
