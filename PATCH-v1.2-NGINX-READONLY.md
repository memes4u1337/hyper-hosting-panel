# HYPER-HOST v1.2 — Nginx read-only final fix

Исправляет невозможность создавать сайты при read-only `/etc/nginx`.

## Что изменено

- рабочая конфигурация Nginx хранится в `/opt/hyper-host/runtime/nginx`;
- runtime подключается bind-mount поверх `/etc/nginx` и доступен для записи;
- root-crontab автоматически восстанавливает runtime после перезагрузки;
- создание сайта использует временный конфиг и безопасную замену;
- добавлены `sudo hyper nginx fix` и `sudo hyper nginx doctor`;
- сохранены Certbot-каталоги в `/opt/hyper-host`;
- сохранлено восстановление ProFTPD/FTPS и passive-портов `40000-40100`;
- патч проверяет цикл создания, открытия и удаления тестового сайта.

## Применение

```bash
sudo ./apply-v1.2-nginx-readonly-final-fix.sh /root/hyper-hosting-panel
```

## Исправление запуска из каталога проекта

Патч корректно запускается непосредственно из `/root/hyper-hosting-panel`.
Если исходный и целевой файл совпадают, копирование пропускается, права приводятся к `0755`.
Ошибка `install: source and destination are the same file` устранена.
