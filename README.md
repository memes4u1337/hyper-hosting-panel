# HYPER-HOST v1.2

Панель управления сайтами, PHP/MySQL, FTP/FTPS, SSL и ботами.

## Обновление установленного сервера

```bash
sudo ./apply-v1.2-stable-recovery.sh /root/hyper-hosting-panel
```

Патч восстанавливает writable Nginx runtime, создание сайтов, ранее выпущенные SSL-сертификаты и FTP/FTPS через ProFTPD.

## Меню

```bash
sudo hyper-host-installer
```

## Основные проверки

```bash
sudo hyper nginx doctor
sudo hyper ftp doctor
sudo hyper ssl status
sudo nginx -t
```

Автор: memes4u1337  
GitHub: https://github.com/memes4u1337/hyper-hosting-panel
