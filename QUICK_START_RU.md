# HYPER-HOST quick start

## Обновить сервер из GitHub

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x install.sh uninstall.sh scripts/hhctl || true

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl bot-doctor

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## Настроить SSL при NAT

```bash
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl ssl-check-json hyper-host.pw
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

Проверь, что на роутере проброшены порты 80 и 443 на внутренний IP сервера.

## Убрать конфликт Telegram getUpdates

```bash
sudo hyper-host-ctl bot kill-conflicts ИМЯ_БОТА
sudo hyper-host-ctl bot restart ИМЯ_БОТА
```

## Обновление v11

```bash
cd /root/hyper-hosting-panel
git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd
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
