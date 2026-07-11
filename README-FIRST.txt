HYPER-HOST v70 — Nginx site-vhost repair

Точечный патч после v69:
- FTP/FTPS не переустанавливается и не изменяется;
- восстанавливает Nginx-vhost beta.mystockbot.xyz (или домена из аргумента);
- сохраняет уже загруженные файлы public_html;
- новые сайты проверяются реальным probe-запросом через 192.168.0.179;
- пароль admin и SQL не изменяются.

Установка:
sudo bash apply-v70-nginx-site-vhost-repair.sh beta.mystockbot.xyz
