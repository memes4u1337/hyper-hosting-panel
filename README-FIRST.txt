HYPER-HOST v72 — полное восстановление SSL после v71

Проблема:
v71 пересобрал Nginx-vhost'ы и поставил всем сайтам общий self-signed
сертификат. Файлы Let's Encrypt при этом не были удалены, но Nginx перестал
на них ссылаться.

Что делает v72:
- находит все существующие сертификаты в:
  /opt/hyper-host/letsencrypt/live
  /etc/letsencrypt/live
- читает SAN/CN каждого сертификата;
- возвращает каждому сайту подходящий действующий сертификат;
- восстанавливает сертификат панели panel.hyper-host.pw;
- не выпускает новые сертификаты и не удаляет старые;
- домены без действующего сертификата оставляет на HTTP;
- сохраняет ACME challenge для будущего выпуска/продления;
- не меняет FTP, SQL, ботов, пароль admin и содержимое public_html.

Установка:
  sudo bash apply-v72-ssl-full-restore.sh

Отчёт:
  sudo cat /root/hyper-host-v72-ssl-full-restore-report.txt
  sudo cat /root/hyper-host-v72-ssl-map.json
