# HYPER-HOST v89 — SSL / ACME / Nginx final fix

Исправлено:

- `sudo nginx -t` автоматически восстанавливается через управляемый reconcile;
- `hyper ssl fix DOMAIN`, проверка панели и Certbot используют один каталог `/opt/hyper-host/acme-webroot`;
- ACME-блок больше не вставляется внутрь другого `location` и не ломает Nginx-конфиг;
- Nginx reconcile больше не изменяет SQLite и не падает с `database is locked`;
- после выпуска сертификат автоматически подключается к HTTPS-vhost;
- включается `certbot.timer` для автопродления.

## Установка

```bash
cd /root/hyper-hosting-panel-main
chmod +x apply-v89-ssl-acme-nginx-final-fix.sh
sudo ./apply-v89-ssl-acme-nginx-final-fix.sh beta.mystockbot.xyz
```

После успешного патча выпусти сертификат в панели либо командой:

```bash
sudo hyper ssl issue beta.mystockbot.xyz YOUR_EMAIL
```

Проверка:

```bash
sudo nginx -t
sudo hyper ssl check beta.mystockbot.xyz
```
