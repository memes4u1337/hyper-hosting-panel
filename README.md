# HYPER-HOST

Личная хостинг-панель: сайты, FTP, MySQL/phpMyAdmin, SSL, Python/Node/PHP боты через PM2, backup, DNS, cron, логи и файловый менеджер.

powered by memes4u1337

## Установка / обновление

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

## v12

- Ускорен dashboard / SSL / боты.
- Исправлено модальное окно SSL.
- Убран лишний NAT-текст из SSL UI.
- Улучшен дизайн dashboard и кнопок.
- Статус SSL после выпуска показывает `SSL работает`.

## HYPER-HOST v13

PM2 для ботов теперь сохраняется в systemd-сервис `hyperbot-pm2.service`. После запуска из панели бот продолжает работать после закрытия панели, SSH-консоли и после перезагрузки сервера.

Команда проверки:

```bash
sudo hyper-host-ctl bot-doctor
systemctl status hyperbot-pm2.service --no-pager
```


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
