# HYPER-HOST v10 patch

## Что исправлено

1. SSL больше не требует, чтобы исходящий IP сервера совпадал с A-записью домена.
   Это важно, если сервер стоит за роутером/NAT: внутренний IP может быть `192.168.0.179`, домен может смотреть на `90.189.208.25`, а `curl ifconfig.me` может показывать другой IP.

2. Добавлена ручная настройка публичного IP для SSL:

```bash
sudo hyper-host-ctl public-ip set 90.189.208.25
```

3. Панель SSL теперь показывает:

- внутренний IP сервера;
- A-запись домена;
- нужную A-запись;
- предупреждение про NAT и проброс портов 80/443;
- понятную ошибку, если DNS или Nginx не готовы.

4. Исправлена ошибка:

```text
/usr/local/sbin/hyper-host-ctl: line 776: home: unbound variable
```

5. Для Telegram-ботов добавлена защита от локальных дублей. Перед запуском бот с таким же именем удаляется из PM2 root/hyperbot, останавливаются старые systemd-сервисы и процессы из папки этого бота.

6. В панели ботов добавлена кнопка **Fix conflict**. Она помогает при ошибке:

```text
TelegramConflictError: getUpdates was aborted by another getUpdates request
```

7. Добавлена команда для локального self-signed сертификата на IP:

```bash
sudo hyper-host-ctl ssl-ip-selfsigned 192.168.0.179
```

Важно: это не полноценный доверенный браузером сертификат. Для нормального SSL лучше использовать домен.

---

## Как залить v10 в GitHub

Распакуй архив и скопируй содержимое папки `hyper-host-v10` поверх своего локального репозитория:

```bash
cd hyper-hosting-panel
cp -r /path/to/hyper-host-v10/* ./

git status
git add .
git commit -m "HYPER-HOST v10: fix SSL public IP NAT and bot conflicts"
git push origin main
```

---

## Как обновить сервер из GitHub

На сервере выполни:

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x install.sh uninstall.sh scripts/hhctl || true

sudo bash install.sh

sudo hyper-host-ctl repair
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl bot-doctor

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

---

## Проверка SSL для hyper-host.pw

```bash
sudo hyper-host-ctl public-ip set 90.189.208.25
sudo hyper-host-ctl ssl-check-json hyper-host.pw
```

Должно быть примерно так:

```json
"certbot_ready": true
```

Если `certbot_ready` false, смотри `problem` и `warning` в JSON.

---

## Выпуск SSL

```bash
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

Почту замени на свою.

---

## Важное для роутера/NAT

Если сервер внутри сети:

```text
192.168.0.179
```

а домен смотрит на публичный IP:

```text
90.189.208.25
```

то на роутере обязательно должен быть проброс:

```text
80/tcp  -> 192.168.0.179:80
443/tcp -> 192.168.0.179:443
```

Без этого Let's Encrypt не сможет проверить домен.

---

## Если бот пишет TelegramConflictError

В панели нажми:

```text
Боты → Fix conflict
```

Или через SSH:

```bash
sudo hyper-host-ctl bot kill-conflicts 123
sudo hyper-host-ctl bot restart 123
```

Если ошибка остаётся, значит такой же Telegram-токен запущен не на этом сервере, а где-то ещё: на старом VPS, на твоём ПК, в systemd, Docker или другом PM2.
