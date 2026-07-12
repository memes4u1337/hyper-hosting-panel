# HYPER-HOST v80 — все сайты в своих public_html

Исправление окончательно разделяет маршрутизацию всех доменов и aliases.

## Что исправлено

- каждая папка `/var/www/hyper-host-sites/<domain>/public_html` владеет своим доменом;
- alias не может перехватить домен, для которого существует отдельная папка;
- aliases берутся из SQLite-панели, а при пустом поле безопасно восстанавливаются из старого vhost;
- одинаковый alias назначается только одному сайту;
- panel-domain исключается из списка сайтов и не отключается;
- каждому hostname с существующим сертификатом создаётся корректный HTTPS-vhost;
- сертификаты разных aliases могут отличаться;
- старые конфликтующие HYPER-HOST vhost-ссылки отключаются;
- все index.html/index.htm/index.php сохраняются без изменений;
- после установки каждый домен и alias проверяется уникальным файлом из его public_html.

## Установка

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v80-all-sites-routing-final.sh
```

Отчёт:

```bash
sudo cat /root/hyper-host-v80-all-sites-routing-report.txt
```

План маршрутизации:

```bash
sudo cat /opt/hyper-host/data/site-routing-plan.txt
```
