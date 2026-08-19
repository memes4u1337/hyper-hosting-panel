# HYPER-HOST v94 — Cloud Storage

Патч добавляет в HYPER-HOST отдельный раздел **«Облако»** и отдельное физическое хранилище:

```text
/var/www/hyper-host-cloud
```

## Что умеет

- отдельная вкладка «Облако» в разделе «Сервер»;
- создание вложенных папок;
- загрузка одного или нескольких файлов прямо в корень или текущую папку;
- автоматическое безопасное переименование при совпадении имени (`file (1).zip`);
- скачивание файлов с поддержкой HTTP Range для больших файлов/видео;
- переименование и удаление файлов/папок;
- просмотр изображений, PDF, видео, аудио, текста и исходного кода;
- просмотр списка содержимого `.zip`, `.rar`, `.7z`, `.tar`, `.tar.gz`, `.tgz`, `.bz2`, `.xz` без распаковки;
- показывает свободное место на диске;
- защита от `../`, выхода за корень облака и символьных ссылок;
- CSRF остаётся включён для всех изменяющих операций;
- архивы только читаются для предпросмотра и не распаковываются автоматически.

## Новые файлы

```text
apply-v1.2-cloud-storage.sh
src/app/cloud.php
PATCH-v94-CLOUD.md
README-INSTALL-CLOUD.txt
```

`apply-v1.2-cloud-storage.sh` сам аккуратно патчит существующие:

```text
src/public/index.php
src/app/config.example.php
install.sh
```

А на уже установленном сервере добавляет `cloud_dir` в действующий `app/config.php`, создаёт `/var/www/hyper-host-cloud` и устанавливает Cloud-модуль без удаления сайтов, ботов, FTP и баз.

## Установка из GitHub

После того как новые файлы из архива добавлены в `main` репозитория:

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.2-cloud-storage.sh && \
sudo ./apply-v1.2-cloud-storage.sh /root/hyper-hosting-panel
```

## Проверка

```bash
sudo -u www-data test -w /var/www/hyper-host-cloud && echo CLOUD_WRITE_OK
php -l /var/www/hyper-host/app/cloud.php
sudo nginx -t
```

Открыть:

```text
https://panel.hyper-host.pw/?page=cloud
```

## Архивы

Патч пытается автоматически установить:

```bash
p7zip-full libarchive-tools unzip
```

Если `apt/dpkg` в этот момент занят, панель всё равно установится, а архиваторы можно поставить позже:

```bash
sudo apt update && sudo apt install -y p7zip-full libarchive-tools unzip
```

## Backup

Перед изменением патч создаёт резервную копию в:

```text
/opt/hyper-host/backups/cloud-patch-YYYYMMDD-HHMMSS
```
