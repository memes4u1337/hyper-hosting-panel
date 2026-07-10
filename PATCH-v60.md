# HYPER-HOST v60

## Исправлено

1. ACME challenge вынесен в `/opt/hyper-host/acme-webroot`, поэтому не зависит от root конкретного сайта.
2. Проверка использует настоящий virtual host через `curl --resolve` и игнорирует proxy-переменные.
3. Certbot хранит config/work/logs в `/opt/hyper-host`, а не в read-only `/etc/letsencrypt`.
4. FTP runtime поддерживает explicit FTPS (`AUTH TLS`) на текущем TCP 21.
5. Существующий обычный FTP остаётся доступен для совместимости.
6. После выпуска/обновления SSL FTP автоматически подхватывает доменный сертификат.
7. Если доменного сертификата ещё нет, создаётся постоянный self-signed сертификат в `/opt/hyper-host/data/ftp-tls`.
8. Установщик проверяет FTPS upload/download и удаление временного аккаунта.
9. Установщик сравнивает хеш пароля `admin` и файл credentials до/после. Пароль не меняется.
