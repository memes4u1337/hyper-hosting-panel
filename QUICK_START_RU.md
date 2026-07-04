# Быстрый старт HYPER-HOST

## Обновление с GitHub

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x install.sh uninstall.sh scripts/hhctl || true

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl ssl-fix-site hyper-host.pw
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl bot-doctor

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## SSL

```bash
sudo hyper-host-ctl ssl-check-json hyper-host.pw
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

## Боты

```bash
sudo hyper-host-ctl bot kill-conflicts 123
sudo hyper-host-ctl bot restart 123
sudo hyper-host-ctl bot logs 123
```

## Включить 24/7 для ботов

```bash
sudo hyper-host-ctl pm2-persist
sudo hyper-host-ctl bot-doctor
```

После этого можно закрывать панель и SSH — боты останутся работать через PM2/systemd.


## HYPER-HOST CLI v14

После установки доступна короткая команда:

```bash
sudo hyper help
sudo hyper dev
sudo hyper stats
sudo hyper bots
sudo hyper ssl status
sudo hyper update
```

Разработчик отображается командой:

```bash
sudo hyper dev
```

Выводит: `@memes4u1337`.
