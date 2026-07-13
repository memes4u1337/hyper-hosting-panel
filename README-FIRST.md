# HYPER-HOST v88 — Nginx Clean Slate Recovery

Эта версия не пытается исправлять старые vhost по одному.

Она заменяет `/etc/nginx/nginx.conf` на минимальный управляемый конфиг, который подключает только:

```text
/etc/nginx/hyper-host-managed/*.conf
```

Старые `sites-enabled` и `conf.d` сохраняются в резервной копии и на диске, но больше не подключаются.

## Результат

- `panel.hyper-host.pw`, `192.168.0.179` и `90.189.208.25` открывают `/var/www/hyper-host/public`.
- Каждый сайт открывает собственный `/var/www/hyper-host-sites/<domain>/public_html`.
- `beta.mystockbot.xyz` открывает только свой `public_html`.
- Существующие сертификаты подключаются автоматически.
- Если сертификата панели нет, выполняется выпуск Let's Encrypt через webroot.
- После сборки выполняется полный `systemctl restart nginx`.

## Установка

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v88-nginx-clean-slate-recovery.sh beta.mystockbot.xyz
```

## Отчёт

```bash
sudo cat /root/hyper-host-v88-nginx-clean-slate-report.txt
sudo cat /opt/hyper-host/data/v88-routing.tsv
sudo nginx -T
```
