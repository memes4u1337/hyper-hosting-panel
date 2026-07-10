# HYPER-HOST v57 — writable Nginx sites patch

Изменён только механизм записи Nginx-конфигов и вывод установщика.

## Исправлено

- создание/удаление сайта больше не падает при read-only `/etc/nginx`;
- действующие Nginx-конфиги сохраняются в `/opt/hyper-host/runtime/nginx`;
- каталог подключается поверх `/etc/nginx` через bind mount;
- systemd автоматически подключает runtime до запуска Nginx после перезагрузки;
- патч сам проверяет `создать сайт -> открыть -> удалить`;
- в консоли цветом выделяется только `HYPER-HOST`;
- в конце выводятся LAN/WAN IP, ссылки панели/phpMyAdmin и данные администратора;
- если сохранённого рабочего пароля администратора нет, патч задаёт новый и показывает его.

FTP, SQL, боты, интерфейс и данные сайтов не изменяются.

## Установка

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v57-nginx-readonly-fix.sh
```

После установки повтори создание `beta.mystockbot.xyz` в панели.

Отчёт с адресами и доступом администратора:

```bash
sudo cat /root/hyper-host-v57-access.txt
```
