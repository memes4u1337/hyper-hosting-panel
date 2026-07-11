HYPER-HOST v68 — локальный + публичный FTPS и правильная маршрутизация сайтов

Что исправляет:
1. LAN FTPS: 192.168.0.179:21, PASV 40000-40049.
2. Public FTPS: 90.189.208.25:21, PASV 40050-40100.
3. Внешний TCP 21 автоматически отправляется на отдельный WAN backend 2121.
4. Новые домены больше не открывают панель.
5. Каждый сайт отдаёт собственный public_html по HTTP и HTTPS.
6. Если загружен index.html, он имеет приоритет над старой заглушкой index.php.
7. Пароль admin, SQL, боты и пользовательские файлы не изменяются.

Установка после загрузки содержимого архива в корень GitHub:

cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v68-dual-ftp-site-routing-fix.sh beta.mystockbot.xyz

FileZilla в локальной сети:
  host: 192.168.0.179
  port: 21
  encryption: Require explicit FTP over TLS
  mode: Passive

FileZilla из интернета:
  host: 90.189.208.25
  port: 21
  encryption: Require explicit FTP over TLS
  mode: Passive

Роутер:
  TCP 21 -> 192.168.0.179:21
  TCP 40000-40100 -> 192.168.0.179:40000-40100

Отчёт:
  sudo cat /root/hyper-host-v68-dual-ftp-site-routing-report.txt
