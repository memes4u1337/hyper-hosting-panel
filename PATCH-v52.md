# HYPER-HOST v52 — fixed IP profile

Сборка жёстко закреплена за адресами:

- LAN: `192.168.0.179`
- WAN: `90.189.208.25`

Сторонние сервисы определения внешнего IP больше не используются. Cron `ip-autofix` только восстанавливает эти значения и не может заменить их адресом прокси/VPN.

Установка обновления:

```bash
sudo bash apply-v52-fixed-ip.sh
```

Проверка:

```bash
sudo hyper ip
sudo hyper ftp doctor
sudo hyper db doctor
```
