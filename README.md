# HYPER-HOST v1.2

Панель управления сайтами, PHP, MariaDB, FTP/FTPS, Telegram-ботами, Nginx и SSL.

## Текущий финальный патч

`apply-v1.2-sql-ssl-final.sh`

Исправляет:

- загрузку больших SQL-файлов без обрыва браузерного соединения;
- фоновый потоковый импорт `.sql`, `.sql.gz`, `.gz`, `.zip`;
- лимит загрузки до 8 ГБ и таймаут Nginx/PHP 6 часов;
- MySQL `max_allowed_packet=1G` и увеличенные сетевые таймауты;
- восстановление действующих сертификатов из всех старых backup-каталогов;
- повторное подключение SSL ко всем существующим сайтам;
- автоматический выпуск отсутствующих сертификатов, когда найден Certbot email и DNS корректен.

FTP-аккаунты, сайты и базы данных патч не удаляет.

## Установка

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main \
https://github.com/memes4u1337/hyper-hosting-panel.git \
/root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.2-sql-ssl-final.sh setup.sh install.sh && \
sudo ./apply-v1.2-sql-ssl-final.sh /root/hyper-hosting-panel && \
sudo hyper-host-installer
```

## Проверка

```bash
sudo hyper db imports
sudo hyper ssl status
sudo hyper ssl repair-all YOUR_EMAIL
sudo nginx -t
```
