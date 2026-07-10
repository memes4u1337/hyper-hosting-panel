# v61

- pyftpdlib обновлён с ветки 1.5.x до 2.2.0.
- FTPS зафиксирован на TLS 1.2 для стабильного data-channel с FileZilla/GnuTLS.
- Отключён sendfile для TLS.
- Установщик проверяет пять циклов MLSD/LIST, upload/download и сохранность пароля admin.
- Nginx, SQL, сайты и данные панели не меняются.
