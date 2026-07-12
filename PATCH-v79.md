# HYPER-HOST v79 — Site vhost/content fix

Точечное исправление маршрутизации сайтов в Nginx.

## Исправлено

- `beta.mystockbot.xyz` жёстко привязывается к `/var/www/hyper-host-sites/beta.mystockbot.xyz/public_html`.
- Все существующие папки вида `/var/www/hyper-host-sites/<domain>/public_html` получают отдельный активный vhost.
- Загруженные файлы, `index.html`, `index.htm`, `index.php`, `.env` и каталоги сайта не удаляются и не перезаписываются.
- `index.html` имеет приоритет над `index.php`, чтобы загруженный статический сайт не перекрывался старой PHP-заглушкой.
- Удаляются только дублирующие активные vhost, которые заявляют тот же точный домен.
- Сохраняются существующие aliases и PHP-FPM socket.
- Если найден действующий сертификат, подходящий домену по SAN/CN, восстанавливается HTTPS-vhost с этим сертификатом.
- Команда `add-site` использует ту же исправленную логику для будущих сайтов.
- Добавлены команды:
  - `hyper-host-ctl site-repair DOMAIN`
  - `hyper-host-ctl sites-rebuild`

## Не изменяется

- FTP и FTP-аккаунты;
- SQL и базы данных;
- Deploy Manager и боты;
- пароль `admin`;
- содержимое сайтов.
