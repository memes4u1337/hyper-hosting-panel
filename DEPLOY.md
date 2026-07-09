# HYPER-HOST — установка, FTP и DNS (v46)

powered by memes4u1337

## 1. Установка / обновление панели

```bash
cd /root
if [ ! -d /root/hyper-hosting-panel/.git ]; then
  git clone https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel
fi
cd /root/hyper-hosting-panel
git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd
chmod +x install.sh uninstall.sh scripts/hhctl scripts/hyper || true

sudo bash install.sh
sudo hyper repair
sudo hyper network fix hyper-host.pw 90.189.208.25
sudo hyper ftp fix
sudo hyper bot persist
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl restart bind9

sudo hyper stats
sudo hyper bots
sudo hyper network doctor hyper-host.pw
sudo hyper ssl check hyper-host.pw
sudo hyper ftp doctor
```

**Важно:** никогда не выполняй `systemctl restart vsftpd` вручную. С v46 vsftpd
замаскирован (`systemctl mask vsftpd`) — эта команда будет просто падать с ошибкой,
и это нормально, так и должно быть. FTP теперь обслуживает только
`hyper-host-ftp.service` (собственный сервер панели).

Прочитать эту инструкцию после обновления: `cat /root/hyper-hosting-panel/DEPLOY.md`


## 2. FTP не подключается — порядок диагностики

1. `sudo hyper ftp doctor` — главный источник правды. Смотри поле `issue`/`hint`:
   - **`ip_mismatch_cgnat_suspected: true`** — настроенный публичный IP не совпадает с
     тем, что реально видно из интернета. Это значит сервер сидит за CGNAT (двойной
     NAT у провайдера) — 90.189.208.25 (или какой у тебя сейчас настроен) физически
     не долетает до твоего роутера снаружи. Никакой проброс портов на роутере это не
     починит, потому что порт открывается на устройстве провайдера, а не на твоём.
     Варианты: попросить провайдера "выделенный публичный IP" (часто платная опция
     для физлиц), либо поднять VPN/туннель (например Cloudflare Tunnel / WireGuard на
     VPS) и проксировать порт через него, либо перенести панель на обычный VPS.
   - **`port21_owner` не `python3` и `vsftpd_active: active`** — старый vsftpd снова
     перехватил порт 21. Выполни: `sudo systemctl stop vsftpd && sudo systemctl mask vsftpd && sudo hyper ftp fix`.
   - **`listen_21: false`** — сервис не поднялся локально. `sudo hyper ftp fix`, потом
     `sudo tail -n 120 /var/log/hyper-host-ftp.log`.
2. Если `sudo hyper ftp doctor` говорит, что локально всё ок (`ftp_backend` слушает,
   баннер отвечает), а FileZilla всё равно пишет "Нет соединения" на порт 21 — это
   значит проблема не на сервере, а по пути до него:
   - На роутере должен быть проброс TCP 21 и TCP 40000-40100 на **LAN-IP сервера**
     (смотри поле `server_ip` в `sudo hyper access doctor`).
   - Провайдер не должен блокировать входящий 21 порт (некоторые домашние/мобильные
     тарифы режут входящие соединения на "серверные" порты).
   - Проверь совпадение `configured_public_ip` и `outbound_ip` в `hyper ftp doctor` —
     см. пункт про CGNAT выше.
3. Локальная проверка логина (без интернета, прямо на сервере):
   `sudo hyper ftp test ЛОГИН ПАРОЛЬ 127.0.0.1`


## 3. DNS и перенос доменов на свою панель (v46)

Раньше каждый добавленный домен получал СВОИ ns1.домен/ns2.домен — и под каждый
домен нужно было отдельно настраивать glue-записи у его регистратора. Теперь есть
общие NS-серверы панели, их видно в самом верху страницы **DNS** в панели
("Твои DNS-серверы").

### Шаг 1 — один раз настроить домен панели
Настройки → Сеть → "Домен панели" (например `hyper-host.pw`), затем:
```bash
sudo hyper network fix hyper-host.pw 90.189.208.25
sudo hyper dns wizard hyper-host.pw 90.189.208.25 panel
```
У регистратора **этого** домена один раз пропиши:
- NS: `ns1.hyper-host.pw`, `ns2.hyper-host.pw`
- Glue (если просит): `ns1.hyper-host.pw -> 90.189.208.25`, `ns2.hyper-host.pw -> 90.189.208.25`

### Шаг 2 — для каждого следующего домена
В панели: DNS → "Создать зону" → указываешь домен → жмёшь создать.
Либо командой:
```bash
sudo hyper dns wizard mydomain.ru 90.189.208.25
```
У регистратора ЭТОГО домена просто прописываешь те же самые NS:
```
ns1.hyper-host.pw
ns2.hyper-host.pw
```
Glue настраивать не нужно — эти NS-имена уже привязаны к IP через зону hyper-host.pw.

### Проверка
```bash
sudo hyper dns status ДОМЕН
sudo hyper dns inspect ДОМЕН
```
В панели на карточке зоны кнопка "Проверить" покажет актуальную делегацию у
регистратора (`public_ns`, `delegation_status`).

DNS-записи (A/MX/TXT/CNAME и т.д.) для каждого домена редактируются на той же
странице DNS, в карточке нужного домена.
