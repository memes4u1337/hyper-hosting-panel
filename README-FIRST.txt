HYPER-HOST v59 — точечный Nginx log directory patch

Исправляет только создание/удаление сайтов при read-only /etc и /usr.

Не меняет:
- FTP;
- MySQL/phpMyAdmin;
- ботов/PM2;
- SQLite базы панели;
- существующие сайты и их файлы;
- интерфейс панели.

Установка после загрузки содержимого архива в корень GitHub:

cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v59-nginx-runtime-fix.sh

Проверка:
sudo touch /etc/nginx/.v59-test && sudo rm /etc/nginx/.v59-test
sudo nginx -t
sudo crontab -l | grep HYPER-HOST-NGINX-RUNTIME
sudo hyper-host-ctl add-site beta.mystockbot.xyz '' ''

Исправляет отсутствующие logs/access.log и logs/error.log до nginx -t.
