# HYPER-HOST CLOUD v95 — Drag & Drop

## Что добавлено

- Отдельная вкладка `Облако` в HYPER-HOST.
- Отдельное хранилище `/var/www/hyper-host-cloud`.
- Отдельный PHP-модуль `src/app/cloud.php`.
- Отдельный дизайн `src/public/assets/cloud.css`.
- Отдельная логика Drag & Drop `src/public/assets/cloud.js`.
- Доступ только после обычной авторизации HYPER-HOST.
- Дополнительная защита внутри Cloud-модуля через `current_user()`.
- Drag & Drop нескольких файлов.
- Выбор места загрузки: корень, текущая папка или любая созданная папка.
- Переход внутрь папок и загрузка прямо в открытую папку.
- Создание, переименование и удаление папок/файлов.
- Скачивание файлов.
- Просмотр изображений, PDF, видео, аудио и текстовых файлов.
- Просмотр списка содержимого ZIP/RAR/7z/TAR без автоматической распаковки.
- Защита от `../`, symlink и выхода за `/var/www/hyper-host-cloud`.
- Скачивание и просмотр выполняются только через авторизованный обработчик панели.

## Файлы

```text
apply-v1.3-cloud-storage.sh
src/app/cloud.php
src/public/assets/cloud.css
src/public/assets/cloud.js
```

## Установка после добавления файлов в GitHub main

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.3-cloud-storage.sh && \
sudo ./apply-v1.3-cloud-storage.sh /root/hyper-hosting-panel
```

## Проверка

```bash
sudo -u www-data test -w /var/www/hyper-host-cloud && echo CLOUD_WRITE_OK
php -l /var/www/hyper-host/app/cloud.php
ls -lah /var/www/hyper-host/public/assets/cloud.*
sudo nginx -t
```

Открыть:

```text
https://panel.hyper-host.pw/?page=cloud
```

Если выйти из панели или открыть Cloud без действующей сессии, HYPER-HOST перенаправляет на страницу входа.
