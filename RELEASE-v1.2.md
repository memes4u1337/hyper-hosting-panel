# HYPER-HOST v1.2

Исправлен критический конфликт CLI: `hyper` больше не заменяется файлом `hyper-host-ctl`.

## FTP

- `sudo hyper ftp fix` снова работает.
- ProFTPD восстанавливается напрямую через `hyper-host-ctl ftp-fix`.
- Поддерживаются FTP и explicit FTPS на TCP 21.
- Пассивные порты: TCP 40000-40100.
- Сохраняются существующие FTP-аккаунты панели.
- После установки проверяются порт 21, FTP banner и TLS.

## Установка патча

```bash
sudo ./apply-v1.2-ftp-final-fix.sh /root/hyper-hosting-panel
```
