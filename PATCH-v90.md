# HYPER-HOST v90 — Certbot на read-only `/etc`

Исправлена ошибка:

```text
[Errno 30] Read-only file system: '/etc/letsencrypt/.certbot.lock'
```

## Что изменено

- Certbot запускается с отдельными каталогами:
  - config: `/opt/hyper-host/letsencrypt`
  - work: `/opt/hyper-host/certbot-work`
  - logs: `/opt/hyper-host/certbot-logs`
- Новые сертификаты и renewal-конфиги больше не записываются в `/etc/letsencrypt`.
- Старое состояние Certbot автоматически копируется из `/etc/letsencrypt`, если оно существует.
- Автопродление выполняется через root-crontab в 03:17 ежедневно.
- Поиск сертификатов и статус сайтов поддерживают как новый `/opt`, так и старый `/etc`.

## Установка и выпуск одной командой

```bash
sudo ./apply-v90-certbot-readonly-final-fix.sh beta.mystockbot.xyz YOUR_EMAIL
```
