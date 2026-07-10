HYPER-HOST v62 — ProFTPD explicit FTPS

Этот патч меняет только FTP/FTPS backend:
- убирает запущенный pyftpdlib;
- ставит ProFTPD + mod_tls;
- сохраняет существующие FTP-аккаунты, папки и пароли;
- не меняет Nginx, SQL, сайты, ботов и пароль admin.

Установка:
sudo bash apply-v62-proftpd-ftps-fix.sh

После установки:
sudo cat /root/hyper-host-v62-proftpd-report.txt
sudo hyper-host-ctl ftp-doctor-json
