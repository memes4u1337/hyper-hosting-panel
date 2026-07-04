# HYPER-HOST v12 — быстрый UI, SSL modal fix, dashboard wow

## Что исправлено

1. **SSL modal fix**
   - Модальное окно выпуска SSL больше не рендерится внутри `<table>`.
   - Bootstrap modal теперь открывается по центру и не улетает по экрану.
   - Добавлен JS-страховщик, который переносит modal в `body` перед открытием.

2. **SSL статус**
   - Если сертификат уже есть и он валиден, панель показывает `SSL работает`.
   - Если сертификата нет, но проверки пройдены — показывает `Можно выпускать`.
   - Убран длинный текст про `192.168.x.x` из интерфейса SSL.
   - Проверка ACME стала быстрее: локальный curl теперь не висит долго.

3. **Ускорение панели**
   - Dashboard использует кэш системной статистики 45 секунд.
   - PM2 список ботов кэшируется 25 секунд.
   - SSL статусы кэшируются дольше, чтобы вкладка SSL открывалась быстрее.
   - После действий с SSL/ботами кэш очищается автоматически.

4. **Дизайн**
   - Обновлён dashboard: hero-блок, быстрые карточки действий, более красивый layout.
   - Улучшены кнопки, таблицы, модалки, hover-эффекты и карточки.
   - SSL-раздел стал компактнее и удобнее.

## Команды после установки

```bash
sudo hyper-host-ctl repair
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl ssl-fix-site hyper-host.pw
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl bot-doctor
sudo nginx -t
sudo systemctl reload nginx
```

## SSL

```bash
sudo hyper-host-ctl ssl-check-json hyper-host.pw
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

## Бот 123

```bash
sudo hyper-host-ctl bot kill-conflicts 123
sudo hyper-host-ctl bot restart 123
sudo hyper-host-ctl bot logs 123
```

Если после этого всё равно `TelegramConflictError`, значит этот же токен запущен не в HYPER-HOST, а где-то ещё.
