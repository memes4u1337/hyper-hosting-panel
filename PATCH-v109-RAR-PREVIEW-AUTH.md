# HYPER CLOUD v109 — RAR / HTML preview / auth repair

Основные изменения:

- Исправлено чтение файлов внутри RAR/RAR5: первичный reader — `unrar`, затем fallback `rar`, `7z/7zz`, `bsdtar`.
- Installer включает Ubuntu `multiverse` и ставит `unrar` + `rar`, поэтому RAR можно не только читать, но и редактировать/сохранять.
- Поиск файла внутри архива имеет безопасный case-insensitive fallback для архивов, созданных в Windows.
- HTML-preview проверяет файл до открытия и запускается в полноэкранном sandbox iframe без лишней панели.
- `site-resource.php` умеет подтягивать CSS/JS/images/fonts/media из той же папки/архива, поддерживает case-insensitive filesystem lookup и `folder/ -> folder/index.html`.
- Ошибки resource/archive пишутся в `/var/log/hyper-cloud/php-error.log`, пользователю внутренние пути не раскрываются.
- Поле «Код подтверждения» удалено из авторизации Cloud. Панельный аккаунт в Cloud проверяется по логину+паролю через изолированный privileged helper. 2FA самой HYPER-HOST панели при входе в панель не меняется.
- Сохраняются Cloud DB, аккаунты, личные файлы, общая папка и публичные ссылки.
- Installer выполняет реальные authenticated probes: обычный HTML editor/site/CSS и отдельный RAR editor/save/site/CSS.

Установка:

```bash
sudo ./apply-v2.7-cloud-rar-preview-auth.sh /root/hyper-hosting-panel
```

Успешный конец содержит:

```text
CLOUD_RUNTIME_PERMISSIONS_OK
PANEL_DB_ISOLATED_OK
CLOUD_CODE_READONLY_OK
EDITOR_SITE_PROBE_OK
RAR_EDITOR_SITE_PROBE_OK
DOMAIN_OK: HYPER_CLOUD_V109
```
