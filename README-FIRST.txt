HYPER-HOST v63 — ProFTPD explicit FTPS

Этот патч меняет только FTP/FTPS backend:
- убирает запущенный pyftpdlib;
- ставит ProFTPD + mod_tls;
- сохраняет существующие FTP-аккаунты, папки и пароли;
- не меняет Nginx, SQL, сайты, ботов и пароль admin.

Установка:
sudo bash apply-v63-proftpd-ubuntu-fix.sh

После установки:
sudo cat /root/hyper-host-v63-proftpd-report.txt
sudo hyper-host-ctl ftp-doctor-json


v63: удалены необязательные директивы mod_ident/mod_wtmp, из-за которых Ubuntu 22.04 отклоняла конфиг.
