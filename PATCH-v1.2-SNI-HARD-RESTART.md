# HYPER-HOST v1.2 — SNI Hard Restart

Исправляет ситуацию, когда Nginx отдаёт сертификат одного сайта для всех доменов.

## Исправлено

- точный Certbot lineage `/opt/hyper-host/letsencrypt/live/<domain>` для основного домена;
- отдельный HTTPS-vhost для каждого SNI;
- aliases подключаются только если сертификат действительно их покрывает;
- soft reload заменён на полный restart одного systemd-managed Nginx;
- старые HYPER-HOST symlink-vhost удаляются из `sites-enabled`;
- после установки проверяется реальный сертификат через `127.0.0.1:443` и SNI;
- сертификат панели выпускается отдельно, если отсутствует;
- существующие FTP, сайты, базы и фоновые SQL-импорты не изменяются.

## Установка

```bash
sudo ./apply-v1.2-sni-hard-restart-final.sh /root/hyper-hosting-panel EMAIL
```
