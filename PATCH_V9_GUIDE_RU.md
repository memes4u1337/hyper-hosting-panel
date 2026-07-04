# HYPER-HOST v9 — SSL без тупых ошибок

## Что исправлено

### SSL

Теперь панель перед выпуском SSL делает preflight-проверку:

- есть ли A/AAAA записи у домена;
- смотрят ли DNS-записи на публичный IP сервера;
- проходит ли `nginx -t`;
- существует ли сайт в HYPER-HOST;
- отдаёт ли Nginx `/.well-known/acme-challenge/` для этого домена;
- открыт ли 80/443 порт в UFW;
- пишет отдельный лог Certbot в `/var/log/letsencrypt/hyper-host-DOMAIN-DATE.log`.

Если DNS не готов, Certbot не запускается. Панель сразу показывает, какую запись нужно добавить:

```text
A    domain.ru    PUBLIC_IP_СЕРВЕРА
```

### Node.js / PM2

Исправлена установка Node.js 20.x. Если на сервере стоит старый Ubuntu Node.js 12 и конфликтует `libnode-dev`, установщик чистит старые `nodejs/npm/libnode-dev/node-gyp` и ставит Node.js 20.x заново.

## Как обновить сервер

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x install.sh uninstall.sh scripts/hhctl || true

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl bot-doctor
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## Проверка SSL перед выпуском

```bash
sudo hyper-host-ctl ssl-check-json hyper-host.pw
```

Если всё готово, будет:

```json
"certbot_ready": true
```

Если DNS не готов, будет понятная причина в поле:

```json
"problem": "..."
```

## Выпуск SSL

```bash
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

Если у сайта есть alias `www.hyper-host.pw` и он тоже правильно указывает на сервер, v9 добавит его в сертификат автоматически. Если alias не настроен по DNS, он будет пропущен, чтобы Certbot не падал.

## Что обязательно для Let's Encrypt

1. Домен должен иметь публичную A-запись на публичный IP сервера.
2. Порт 80 должен быть открыт из интернета.
3. Порт 443 должен быть открыт из интернета.
4. Сайт должен быть создан в HYPER-HOST.
5. Nginx должен проходить проверку `sudo nginx -t`.

Проверка DNS:

```bash
dig +short hyper-host.pw
curl -4 ifconfig.me
```

Если `dig +short hyper-host.pw` пустой — SSL не выпустится, пока не добавишь A-запись у регистратора.
