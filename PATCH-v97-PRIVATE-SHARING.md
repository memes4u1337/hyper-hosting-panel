# HYPER CLOUD v97 — Private by default + доступ по ссылке

Обновление для standalone HYPER CLOUD v96.

## Главное

- Все новые и существующие файлы приватны по умолчанию.
- Обычный `/cloud/`, просмотр, raw и обычное скачивание требуют авторизации HYPER-HOST.
- Для одного конкретного файла администратор может включить `Доступ по ссылке`.
- Создаётся случайный 48-символьный токен. В URL нет пути к файлу.
- По публичной ссылке доступен только один файл и его скачивание.
- Директории никогда не публикуются.
- После `Закрыть доступ` старая ссылка сразу получает 404.
- При переименовании файла/папки активные ссылки продолжают работать и автоматически получают новый внутренний путь.
- При удалении файла или папки все связанные публичные ссылки автоматически отзываются.
- Публичные страницы помечены `noindex/noarchive`.

## Интерфейс

Добавлено:

- более выразительный отдельный дизайн Cloud;
- бейдж `Приватный` на закрытых файлах;
- бейдж `По ссылке` на опубликованных файлах;
- новый раздел `Доступ по ссылке` в собственном меню Cloud;
- окно `Доступ к файлу`;
- кнопка `Открыть доступ по ссылке`;
- поле с готовой публичной ссылкой;
- кнопка `Копировать`;
- кнопка `Закрыть доступ`;
- доступ можно настроить из карточки файла и из полноэкранного просмотра;
- отдельная красивая публичная страница получателя с названием, размером и кнопкой скачивания;
- для изображений публичная страница показывает превью только этого изображения.

## Хранилище

Файлы Cloud остаются здесь:

```text
/var/www/hyper-host-cloud
```

Реестр публичных ссылок хранится ОТДЕЛЬНО от файлов:

```text
/var/lib/hyper-host-cloud/shares.json
```

Права устанавливаются на `www-data:www-data`, файл реестра `0660`, каталог `2770`.

Никакого SQL для v97 не требуется.

## Публичная ссылка

Пример формата:

```text
https://panel.hyper-host.pw/cloud/?s=<случайный_токен>
```

Получатель не получает доступ к `/cloud/`, списку файлов, папкам или панели. Он видит только отдельную страницу одного расшаренного файла.

## Установка из GitHub

Добавьте содержимое `HYPER-HOST-CLOUD-v97-GITHUB-OVERLAY` в корень ветки `main`, затем на сервере:

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main \
https://github.com/memes4u1337/hyper-hosting-panel.git \
/root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.5-cloud-sharing.sh && \
sudo ./apply-v1.5-cloud-sharing.sh /root/hyper-hosting-panel
```

## Проверка

```bash
php -l /var/www/hyper-host/public/cloud/index.php
node --check /var/www/hyper-host/public/cloud/cloud.js
bash -n /root/hyper-hosting-panel/apply-v1.5-cloud-sharing.sh
sudo -u www-data test -w /var/www/hyper-host-cloud && echo CLOUD_WRITE_OK
sudo -u www-data test -w /var/lib/hyper-host-cloud/shares.json && echo CLOUD_SHARES_OK
sudo nginx -t
```

Открыть:

```text
https://panel.hyper-host.pw/cloud/
```

## Backup

Перед установкой создаётся backup:

```text
/opt/hyper-host/backups/cloud-v97-YYYYMMDD-HHMMSS/
```

Если уже существовал `shares.json`, он также попадает в backup. Само содержимое `/var/www/hyper-host-cloud` патч не удаляет и не переносит.
