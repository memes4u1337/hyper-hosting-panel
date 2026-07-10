# HYPER-HOST v54 — FTP authentication repair

Исправляет аварийное завершение v53:

```text
db_load: BDB5090 unexpected end of input data or key/data pair
```

Причина: файл `/opt/hyper-host/data/vsftpd_virtual_users.txt` записывался с буквальными символами `\\n` вместо реальных переводов строк. Berkeley DB получала нечётную/повреждённую последовательность key/value и установка завершалась до запуска `vsftpd`.

## Исправления

- реальные переводы строк в FTP auth TXT;
- автоматическая миграция повреждённого v53-файла;
- проверка чётности user/password пар;
- безопасная фиктивная запись для пустой базы;
- атомарная сборка `vsftpd_virtual_users.db`;
- ошибки `db_load` больше не скрываются;
- восстановление сохранённых аккаунтов из `hyperhost.sqlite`;
- обязательная проверка systemd и портов 21/2121.

## Установка

```bash
sudo bash apply-v54-ftp-auth-fix.sh
```
