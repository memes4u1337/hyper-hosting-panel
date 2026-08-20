# HYPER CLOUD v105 — vhost repair

Исправляет падение v104 `sed: unterminated s command` в `hyper-cloud-nginx-fragment.sh`.

Дополнительно:
- helper больше не парсит `hyper-host.conf` через хрупкий sed;
- installer экспортирует найденный PHP-FPM socket в reconcile;
- после каждого reconcile Cloud vhost создаётся повторно;
- конфликтующие legacy vhost из sites-enabled/sites-available архивируются и удаляются;
- существующий `cloud.sqlite`, private/shared файлы и публичные ссылки сохраняются;
- финальный health-check требует `HYPER_CLOUD_V105`.
