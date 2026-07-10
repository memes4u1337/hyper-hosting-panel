HYPER-HOST v60 — ACME + Certbot read-only /etc + explicit FTPS

Изменяются только:
- /usr/local/sbin/hyper-host-ctl
- /opt/hyper-host/bin/hyper_ftp_runtime.py
- Nginx-конфиги HYPER-HOST сайтов: добавляется/исправляется ACME location
- FTP runtime перезапускается с explicit TLS

Не изменяются:
- SQLite база панели
- пароль и хеш пользователя admin
- FTP-аккаунты и их пароли
- MySQL/MariaDB
- файлы сайтов и ботов
- интерфейс панели

Установка:
sudo bash apply-v60-ssl-ftps-fix.sh beta.mystockbot.xyz

Установка + немедленный выпуск SSL:
sudo bash apply-v60-ssl-ftps-fix.sh beta.mystockbot.xyz EMAIL@example.com

FileZilla:
Протокол: FTP
Шифрование: Требовать явный FTP через TLS
Хост: beta.mystockbot.xyz (после выпуска сертификата) или IP
Порт: 21
Режим: пассивный
