HYPER-HOST v71 — ПОЛНОЕ ВОССТАНОВЛЕНИЕ NGINX-МАРШРУТИЗАЦИИ

Патч меняет только Nginx/создание сайтов.
FTP, SQL, боты, база панели и пароль admin не изменяются.

Что делает:
1. Возвращает панель по 192.168.0.179, 90.189.208.25 и panel.hyper-host.pw.
2. Находит все реальные папки /var/www/hyper-host-sites/<домен>/public_html.
3. Пересоздаёт отдельный vhost для каждого такого домена.
4. Для новых сайтов автоматически создаёт стартовую заглушку, только если index.html/index.php отсутствуют.
5. Для beta.mystockbot.xyz устанавливает отдельную заглушку; прежний index сохраняется в backup.
6. Неизвестный Host показывает «Домен не настроен», но добавленные сайты туда больше не попадают.

Установка после загрузки файлов в корень GitHub:

cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v71-nginx-full-recovery.sh beta.mystockbot.xyz

Отчёт:
sudo cat /root/hyper-host-v71-nginx-full-recovery-report.txt
