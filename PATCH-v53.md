# HYPER-HOST v53 — реальный ремонт FTP и внешнего MySQL

Фиксированные адреса:

- LAN: `192.168.0.179`
- WAN: `90.189.208.25`

## Что изменено

1. Старый самописный FTP полностью отключается.
2. FTP работает через два независимых экземпляра `vsftpd`:
   - LAN: `192.168.0.179:21`, PASV `40000-40020`;
   - Internet: `90.189.208.25:2121`, PASV `40100-40120`.
3. Разделение нужно, чтобы локальный FTP не получал WAN-IP в PASV-ответе и наоборот.
4. Существующие FTP-логины и пароли мигрируют в PAM/Berkeley DB.
5. FTP-папки подключаются через bind-mount, права восстанавливаются через ACL.
6. Разрешены Explicit FTP over TLS и обычный FTP.
7. MariaDB принудительно слушает `0.0.0.0:3306`; установщик проверяет именно внешний bind, а не просто наличие порта.
8. Все базы панели получают пользователей на `localhost`, `127.0.0.1`, `192.168.0.%` и `%`.
9. Исправлена команда `sudo hyper db test`: раньше она теряла аргумент HOST.
10. Для локального бота есть hairpin DNAT, но правильный адрес на этом же сервере — `127.0.0.1:3306`.
11. Патч пытается автоматически добавить пробросы через UPnP.
12. `sudo hyper connectivity test` реально загружает/скачивает FTP-файл и авторизуется в MariaDB сохранёнными логинами.
13. В интерфейсе разделены URL phpMyAdmin и MySQL host для кода бота.

## Установка

```bash
sudo bash apply-v53-connectivity-fix.sh
```

## Проверка

```bash
sudo hyper connectivity doctor
sudo hyper connectivity test
sudo hyper ftp doctor
sudo hyper ftp test LOGIN PASSWORD 127.0.0.1 21
sudo hyper ftp test LOGIN PASSWORD 127.0.0.1 2121
sudo hyper db doctor
sudo hyper db test 127.0.0.1 USER PASSWORD DATABASE
sudo hyper db test 90.189.208.25 USER PASSWORD DATABASE
```

## Роутер

Если UPnP выключен, вручную пробросить:

- TCP `2121` → `192.168.0.179:2121`;
- TCP `40100-40120` → `192.168.0.179:40100-40120`;
- TCP `3306` → `192.168.0.179:3306`.

Для стандартного внешнего FTP-порта можно дополнительно настроить:

- внешний TCP `21` → `192.168.0.179:2121`.

`phpMyAdmin` — веб-интерфейс. Для бота используются MySQL host, port, user, password и database, а не URL phpMyAdmin.
