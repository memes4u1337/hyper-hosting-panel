# HYPER-HOST v2 patch — установка после GitHub

Этот патч чинит:

- сохранение данных панели через ремонт прав SQLite/sudoers;
- отображение сайтов/FTP/баз/ботов, даже если они созданы через SSH-команду `hyper-host-ctl`;
- страницу FTP: Host, Port, passive ports, готовая строка подключения, кнопки копирования;
- статистику железа: CPU, ядра, RAM, disk, load average, uptime;
- статусы сервисов: Nginx, MariaDB, VSFTPD, PHP-FPM;
- кнопки **Синхронизировать ресурсы** и **Починить права и сервисы**;
- root-команды `stats-json`, `sync-json`, `repair`.

---

## 1. Как залить патч в GitHub

На своём ПК распакуй архив патча и скопируй файлы поверх репозитория:

```bash
cd hyper-hosting-panel
cp -r /path/to/hyper-host-v2/* ./
```

Потом отправь изменения в GitHub:

```bash
git status
git add .
git commit -m "HYPER-HOST v2: fix saving, FTP and server stats"
git push origin main
```

---

## 2. Как обновить сервер после push в GitHub

На сервере:

```bash
cd /root/hyper-hosting-panel
git pull origin main
sudo bash install.sh
```

После установки сразу выполни ремонт и синхронизацию:

```bash
sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl stats-json
```

Если `sync-json` и `stats-json` выводят JSON — всё хорошо.

---

## 3. Обязательно проверить Nginx и сервисы

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl status nginx --no-pager
sudo systemctl status mariadb --no-pager
sudo systemctl status vsftpd --no-pager
```

---

## 4. Проверить права SQLite, если ничего не сохранялось

```bash
ls -la /opt/hyper-host/data
sudo chown -R www-data:www-data /opt/hyper-host/data
sudo chmod 0770 /opt/hyper-host/data
sudo chmod 0660 /opt/hyper-host/data/hyperhost.sqlite*
sudo hyper-host-ctl repair
```

Потом открой панель:

```text
http://IP_СЕРВЕРА/
```

В панели зайди:

```text
Настройки → Починить права и сервисы
Настройки → Синхронизировать сайты / FTP / базы / боты
```

---

## 5. Если сайт создан через SSH, но не виден в панели

Например ты создал:

```bash
sudo hyper-host-ctl add-site hyper-host.pw www.hyper-host.pw
```

Чтобы он появился в панели:

```bash
sudo hyper-host-ctl sync-json
```

Потом в самой панели нажми:

```text
Дашборд → Синхронизировать ресурсы
```

Или:

```text
Настройки → Синхронизировать сайты / FTP / базы / боты
```

---

## 6. Как создать FTP для сайта

Через панель:

```text
FTP → Создать FTP
```

Выбери папку:

```text
/var/www/hyper-host-sites/hyper-host.pw/public_html
```

Логин можно указать, например:

```text
hyperhost
```

Фактический логин будет:

```text
hhftp_hyperhost
```

Данные подключения:

```text
Host: IP_СЕРВЕРА
Port: 21
Login: hhftp_hyperhost
Password: твой пароль
Passive mode: ON
Passive ports: 40000-40100
```

Через SSH:

```bash
sudo hyper-host-ctl create-ftp hyperhost 'StrongFTPPassword123!' /var/www/hyper-host-sites/hyper-host.pw/public_html
```

Проверить пользователя:

```bash
id hhftp_hyperhost
```

Проверить FTP сервис:

```bash
sudo systemctl status vsftpd --no-pager
sudo ss -lntp | grep ':21'
sudo ufw status
```

---

## 7. Порты для FTP

Открой порты:

```bash
sudo ufw allow 21/tcp
sudo ufw allow 40000:40100/tcp
sudo ufw status
```

---

## 8. Проверка статистики железа

```bash
sudo hyper-host-ctl stats-json
```

В панели это будет видно на дашборде:

- CPU;
- количество ядер;
- RAM;
- диск;
- load average;
- uptime;
- статусы Nginx/MariaDB/FTP/PHP-FPM.

---

## 9. Если после обновления панель не открывается

```bash
sudo nginx -t
sudo tail -n 100 /var/log/nginx/hyper-host-panel.error.log
sudo systemctl restart nginx
sudo systemctl restart mariadb
sudo systemctl restart vsftpd
sudo hyper-host-ctl repair
```

---

## 10. Самый короткий порядок обновления

```bash
cd /root/hyper-hosting-panel
git pull origin main
sudo bash install.sh
sudo hyper-host-ctl repair
sudo nginx -t
sudo systemctl reload nginx
```

Потом в панели:

```text
Дашборд → Синхронизировать ресурсы
FTP → создать FTP для нужного сайта
```
