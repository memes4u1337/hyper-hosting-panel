# HYPER-HOST v62 — ProFTPD FTPS data-channel fix

## Причина

У pyftpdlib управляющее TLS-соединение и авторизация работали, но FileZilla/GnuTLS
получала `GnuTLS -110` после `MLSD` на защищённом пассивном data-channel.

## Что изменено

- Единственный активный FTP backend: ProFTPD.
- Explicit FTPS на TCP 21.
- TLS 1.2 и `TLSOptions NoSessionReuseRequired`.
- Защищённые LIST/MLSD/STOR/RETR.
- PASV TCP 40000-40100, public address 90.189.208.25.
- `UseSendfile off`.
- Виртуальные пользователи через `mod_auth_file`.
- Auth/config/runtime хранятся в `/opt/hyper-host`, а unit — в `/run`.
- Создание, смена пароля и удаление FTP-аккаунта сразу пересобирают AuthUserFile.
- Старый pyftpdlib процесс останавливается.

## Что не изменено

- Nginx/ACME/SSL сайтов.
- MySQL и базы.
- Сайты, боты и интерфейс панели.
- FTP-логины, пароли и папки.
- Пользователь `admin` и его пароль.

## Самопроверка установщика

Установщик использует Ubuntu `lftp`, собранный с GnuTLS, и проверяет:

1. explicit TLS 1.2;
2. пять MLSD/LIST операций;
3. upload/download с проверкой содержимого;
4. отсутствие `GnuTLS -110`;
5. создание и удаление временного пользователя;
6. запрет входа удалённого пользователя;
7. неизменность хеша пароля `admin`.

При ошибке прежний `hyper-host-ctl` и FTP runtime восстанавливаются из backup.
