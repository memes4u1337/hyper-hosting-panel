# HYPER CLOUD v96 — Standalone

Это отдельное файловое облако для HYPER-HOST. Оно НЕ рендерится через `render_page()` и НЕ использует sidebar/topbar основной панели.

## URL

- Панель: `/`
- Облако: `/cloud/`
- Старый `/?page=cloud` автоматически перенаправляется на `/cloud/`.

## Авторизация

`/cloud/index.php` подключает штатный `app/bootstrap.php` и использует ту же PHP-сессию HYPER-HOST.

Если пользователь не вошёл в панель:

1. Cloud сохраняет `/cloud/` как адрес возврата.
2. Отправляет на `/?page=login`.
3. После успешного входа патч возвращает пользователя в `/cloud/`.

Скачать или открыть raw-файл без этой же авторизованной сессии нельзя.

## Интерфейс

Cloud имеет полностью отдельную оболочку:

- HYPER CLOUD branding;
- меню: Мой диск / Последние / Архивы / Изображения;
- поиск по текущему списку;
- сетка / список;
- Drag & Drop на всю рабочую область;
- выбор места загрузки: корень или любая папка;
- создание папок;
- открытие папок;
- просмотр фото, PDF, видео, аудио и текстовых файлов;
- просмотр списка файлов ZIP/RAR/7z/TAR без распаковки;
- скачивание;
- переименование;
- удаление.

## Хранилище

Файлы лежат отдельно:

```text
/var/www/hyper-host-cloud
```

Патч не переносит и не удаляет содержимое этой папки при обновлении.

## Установка из GitHub

Сначала добавьте файлы overlay в `main`, затем на сервере:

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main \
https://github.com/memes4u1337/hyper-hosting-panel.git \
/root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.4-cloud-standalone.sh && \
sudo ./apply-v1.4-cloud-standalone.sh /root/hyper-hosting-panel
```

## Проверка

```bash
php -l /var/www/hyper-host/public/cloud/index.php
node --check /var/www/hyper-host/public/cloud/cloud.js
sudo -u www-data test -w /var/www/hyper-host-cloud && echo CLOUD_WRITE_OK
sudo nginx -t
```

Открыть:

```text
https://panel.hyper-host.pw/cloud/
```

## Backup

Перед изменениями установщик создаёт backup:

```text
/opt/hyper-host/backups/cloud-standalone-YYYYMMDD-HHMMSS/
```

Старые встроенные runtime-файлы `app/cloud.php` и `/public/assets/cloud.*` удаляются только после backup. Содержимое `/var/www/hyper-host-cloud` не трогается.
