# HYPER-HOST v1.2 — SSL + SQL Truth

Исправляет две подтверждённые проблемы:

1. SSL-аудит сравнивал пустые fingerprint и сообщал `live_matches=true`, даже когда Nginx отдавал сертификат другого домена.
2. Старый фоновый SQL-импорт не показывал PID/heartbeat/рост базы и выглядел зависшим во время долгой обработки MySQL.

Установка:

```bash
sudo ./apply-v1.2-ssl-sql-truth-final.sh /root/hyper-hosting-panel EMAIL
```

Проверка:

```bash
sudo hyper ssl repair-all EMAIL
sudo hyper db imports
```
