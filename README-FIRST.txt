HYPER-HOST v69 — локальный + публичный FTPS и окончательная маршрутизация сайтов

Что исправляет:
1. LAN FTPS: 192.168.0.179:21, PASV 40000-40049.
2. Public FTPS: 90.189.208.25:21, PASV 40050-40100.
3. Внешний TCP 21 автоматически отправляется на отдельный WAN backend 2121.
4. Старый Nginx-конфиг панели с server_name _ больше не перехватывает новые домены.
5. Остаётся один нейтральный default-vhost, который не показывает админ-панель.
6. Панель закрепляется только за PANEL_DOMAIN или за IP сервера, если домен не задан.
7. Каждый сайт отдаёт собственный public_html по HTTP и HTTPS.
8. Проверка выполняется напрямую через 127.0.0.1 с правильным Host без proxy/DNS.
9. Пароль admin, SQL, боты и файлы сайтов не изменяются.

Установка после загрузки содержимого архива в корень GitHub:

cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v69-dual-ftp-site-routing-final-fix.sh beta.mystockbot.xyz

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
  sudo cat /root/hyper-host-v69-dual-ftp-site-routing-report.txt
