# HYPER-HOST v56 — один FTP-движок

## Исправлено

- Полностью удалена зависимость FTP от PAM, Berkeley DB, `db_load`, `/etc/fstab` и `/etc/pam.d`.
- Удалён ошибочный heredoc `PYFTPAUTHNORMALIZE'`, из-за которого создание и удаление аккаунтов печатало `SyntaxError`.
- Работает один процесс `pyftpdlib` и один сервис `hyper-host-ftp.service`.
- Один управляющий порт: TCP `21`.
- Один пассивный диапазон: TCP `40000-40100`.
- PASV-адрес выбирается автоматически для каждого подключения:
  - LAN-клиент получает `192.168.0.179`;
  - интернет-клиент получает `90.189.208.25`.
- Создание, смена пароля и удаление пользователя применяются без перезапуска FTP.
- Удалённый пользователь сразу теряет возможность входа.
- Панель и CLI показывают одинаковые адреса и порт.

## Установка

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v56-single-ftp-fix.sh
```

## Подключение

В локальной сети:

```text
Host: 192.168.0.179
Port: 21
Mode: Passive
Encryption: Plain FTP
```

Из интернета:

```text
Host: 90.189.208.25
Port: 21
Mode: Passive
Encryption: Plain FTP
```

На роутере:

```text
TCP 21          -> 192.168.0.179:21
TCP 40000-40100 -> 192.168.0.179:40000-40100
```
