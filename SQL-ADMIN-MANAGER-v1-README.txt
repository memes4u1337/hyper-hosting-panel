SQL Admin Manager v1

Adds a separate "Админки" tab:
- SteamID / nickname / IP
- full or custom AMXX flags
- optional password / generated password
- days / calendar months / forever
- direct write to Admin Loader SQL tables
- same identity updates existing row without duplicate
- revoke/delete
- automatic amx_reloadadmins after each change

Install:
cd /root/hyper-hosting-panel
git fetch https://github.com/memes4u1337/hyper-hosting-panel.git main
git show FETCH_HEAD:apply-cs16-sql-admin-manager-v1.sh > /tmp/apply-cs16-sql-admin-manager-v1.sh
chmod +x /tmp/apply-cs16-sql-admin-manager-v1.sh
sudo bash /tmp/apply-cs16-sql-admin-manager-v1.sh /root/hyper-hosting-panel 25
