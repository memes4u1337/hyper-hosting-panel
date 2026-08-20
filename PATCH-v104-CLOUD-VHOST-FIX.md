# HYPER CLOUD v104 — domain/vhost hard fix

Исправляет ситуацию, когда после установки Cloud домен `cloud.hyper-host.pw` показывает стандартную страницу обычного сайта HYPER-HOST (`public_html`) вместо HYPER CLOUD.

## Причина
Текущий HYPER-HOST периодически полностью пересобирает Nginx в `/etc/nginx/hyper-host-managed/*.conf`. Домен `cloud.hyper-host.pw`, если он ранее был создан как обычный сайт, автоматически получает root `/var/www/hyper-host-sites/cloud.hyper-host.pw/public_html`. Старый v103 создавал отдельный config в `sites-enabled`, но актуальный `nginx.conf` после reconcile использует managed-конфиги, поэтому обычный site-vhost снова выигрывал.

## Что делает v104
- сохраняет пользовательские Cloud-файлы и Cloud SQLite;
- повторно устанавливает полноценное приложение `/var/www/hyper-host-cloud-app`;
- помечает старую папку обычного сайта `cloud.hyper-host.pw` отключённой, НЕ удаляя её данные;
- удаляет только запись этого домена из таблицы `sites` панели, предварительно делая backup SQLite;
- устанавливает persistent helper `/opt/hyper-host/bin/hyper-cloud-nginx-fragment.sh`;
- патчит штатный `hyper-host-nginx-reconcile`, чтобы после КАЖДОЙ пересборки Nginx возвращался standalone Cloud vhost;
- дополнительно патчит `nginx_recover_v89.py`: Cloud-домен исключается из обычных сайтов, а `15-cloud-app.conf` не стирается даже при прямом recover;
- использует уже выпущенный Let's Encrypt сертификат из `/etc/letsencrypt` или `/opt/hyper-host/letsencrypt`;
- если сертификата нет — получает его через `certbot certonly --webroot`, без `certbot --nginx`;
- HTTP всегда уходит на HTTPS, когда сертификат доступен;
- в конце выполняет реальную SNI-проверку через `curl --resolve` и завершает установку с ошибкой, если домен всё ещё отдаёт не HYPER CLOUD.

## Установка
```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v2.2-cloud-vhost-fix.sh && \
sudo ./apply-v2.2-cloud-vhost-fix.sh /root/hyper-hosting-panel
```

Успех подтверждается строкой:
```
[HYPER CLOUD] DOMAIN_OK: https://cloud.hyper-host.pw/ -> HYPER CLOUD v104
```
