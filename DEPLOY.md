# Deploy Manager v75 — серверные пути

```text
Главный бот:        /var/www/hyper-host-deploy/master
Файлы магазинов:    /var/www/hyper-host-deploy/template
Созданные магазины: /var/www/hyper-host-managed-bots
PM2 HOME:           /var/www/hyper-host-bots/.pm2
Готовый master bot: /opt/hyper-host/deploy-center/examples
Конфиг SQL:         /opt/hyper-host/deploy-center/config.json
```

## Диагностика

```bash
sudo hyper-host-ctl deploy-center-doctor
sudo hyper-host-ctl deploy-center-sync
sudo -u hyperbot -H env HOME=/var/www/hyper-host-bots PM2_HOME=/var/www/hyper-host-bots/.pm2 pm2 ls
```

## Что должно быть установлено

- Python 3
- `python3-venv`
- `pip`
- Node.js/npm
- PM2
- PyMySQL в `/opt/hyper-host/deploy-center/venv`
- доступ к MySQL `90.189.208.25:3306`
- доступ к `api.telegram.org`
