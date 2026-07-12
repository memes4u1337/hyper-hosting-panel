# HYPER-HOST v81 — exact host routing

Исправляет ошибку v80, при которой alias вроде `www.beta.mystockbot.xyz` присутствовал в плане, но мог не попасть в рабочий Nginx-vhost и открывал default-страницу «Домен не настроен».

## Новая схема

Все домены и aliases собираются в один управляемый конфиг:

`/etc/nginx/sites-available/20-hyper-host-sites-managed.conf`

Каждому имени создаётся отдельный `server`-блок:

- `beta.mystockbot.xyz` → `/var/www/hyper-host-sites/beta.mystockbot.xyz/public_html`
- `www.beta.mystockbot.xyz` → та же папка
- остальные домены и aliases → public_html своего сайта

Точная карта сохраняется в:

`/opt/hyper-host/data/site-routing-exact.tsv`

## Безопасность обновления

Патч не изменяет файлы сайтов, панель, FTP, SQL, ботов и пароль admin. Перед изменением сохраняется резервная копия CLI, Nginx и SQLite. Каждый Host проверяется отдельным probe-файлом из его реального `public_html`.
