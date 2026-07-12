# HYPER-HOST v83 — восстановление панели и сайтов

v83 удаляет только сломанный общий routing v80/v81 и возвращает независимые Nginx-vhost:

- панель: `192.168.0.179`, `90.189.208.25`, `panel.hyper-host.pw`;
- каждый существующий сайт: собственная папка `/var/www/hyper-host-sites/<domain>/public_html`;
- `beta.mystockbot.xyz`: строго `/var/www/hyper-host-sites/beta.mystockbot.xyz/public_html`;
- неизвестные Host: нейтральная страница «Домен не настроен».

Файлы сайтов не создаются, не удаляются и не перезаписываются. Aliases берутся из SQLite, а если они там пусты — из прежнего индивидуального vhost. Автоматический `www` не добавляется.

Установка:

```bash
sudo bash apply-v83-panel-sites-beta-final-recovery.sh beta.mystockbot.xyz
```
