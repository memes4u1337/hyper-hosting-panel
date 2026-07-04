# Быстрый старт HYPER-HOST v4

## Установка с GitHub

```bash
ssh root@IP_СЕРВЕРА
apt update && apt upgrade -y
apt install -y git curl unzip ca-certificates sudo ufw
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

## Создать сайт

```bash
sudo hyper-host-ctl add-site hyper-host.pw www.hyper-host.pw
```

Файлы:

```text
/var/www/hyper-host-sites/hyper-host.pw/public_html
```

## Создать папку без домена

```bash
sudo hyper-host-ctl create-folder test-site
```

Файлы:

```text
/var/www/hyper-host-sites/test-site/public_html
```

## Создать FTP

```bash
sudo hyper-host-ctl create-ftp hyperhost 'StrongFTPPassword123!' /var/www/hyper-host-sites/hyper-host.pw/public_html
```

Подключение:

```text
Хост: IP_СЕРВЕРА
Порт: 21
Имя пользователя: hhftp_hyperhost
Пароль: StrongFTPPassword123!
```

Внутри FTP:

```text
common/
site/
```

## Создать бота 24/7

```bash
sudo hyper-host-ctl bot-create mybot python 'python3 main.py'
sudo hyper-host-ctl bot start mybot
```

Логи:

```bash
sudo hyper-host-ctl bot logs mybot
```
