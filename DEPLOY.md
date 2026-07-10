# HYPER-HOST — установка, FTP, MySQL и DNS (v53 connectivity fix)

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
sudo hyper connectivity fix
sudo hyper connectivity doctor
sudo hyper connectivity test
sudo hyper bot persist
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl restart bind9

sudo hyper stats
sudo hyper bots
sudo hyper network doctor hyper-host.pw
sudo hyper ssl check hyper-host.pw
sudo hyper ftp doctor
```

FTP в v53 обслуживают два отдельных экземпляра `vsftpd`. Старый самописный сервис
`hyper-host-ftp.service` отключается и удаляется. LAN и Internet разделены, чтобы
каждый PASV-ответ содержал правильный IP. Проверка:
`systemctl status hyper-host-vsftpd-lan hyper-host-vsftpd-wan`.

Прочитать эту инструкцию после обновления: `cat /root/hyper-hosting-panel/DEPLOY.md`


## 2. Фиксированные IP и FTP

Эта сборка использует только два адреса:

- LAN: `192.168.0.179`
- WAN: `90.189.208.25`

Команда проверки:

```bash
sudo hyper ip
```

FTP:

- из локальной сети: `192.168.0.179:21`;
- из интернета: `90.189.208.25:2121`;
- LAN passive: `40000-40020`; Internet passive: `40100-40120`.

На роутере пробрось TCP `2121` и TCP `40100-40120` на такие же порты `192.168.0.179`. Необязательно: внешний TCP `21` → внутренний `2121`.
Диагностика и реальный тест загрузки/скачивания:

```bash
sudo hyper ftp doctor
sudo hyper ftp test ЛОГИН ПАРОЛЬ 127.0.0.1 21
sudo hyper ftp test ЛОГИН ПАРОЛЬ 127.0.0.1 2121
sudo hyper connectivity test   # проверяет сохранённые FTP и MySQL логины
```

Cron автоопределения IP полностью удалён. Панель использует только LAN `192.168.0.179` и WAN `90.189.208.25`.


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


## 4. MySQL и phpMyAdmin

- SQL внутри сервера: `127.0.0.1:3306`;
- SQL из LAN: `192.168.0.179:3306`;
- SQL из интернета: `90.189.208.25:3306`;
- phpMyAdmin LAN: `http://192.168.0.179/phpmyadmin/`;
- phpMyAdmin Internet: `http://90.189.208.25/phpmyadmin/`.

Для внешнего SQL на роутере пробрось TCP `3306` на `192.168.0.179:3306` и используй
отдельного MySQL-пользователя со сложным паролем.

```bash
sudo hyper connectivity fix
sudo hyper db doctor
sudo hyper db test 127.0.0.1 USER PASS DATABASE
sudo hyper connectivity test
```


## 5. Боты не создаются / "Read-only file system" на hyperbot-pm2.service

Найдена и исправлена реальная причина: при создании любого бота панель сначала
пыталась поставить PM2 в автозапуск через systemd-юнит
`/etc/systemd/system/hyperbot-pm2.service`. Если эта директория у тебя read-only
(похоже на контейнер/урезанное окружение — `/etc/nginx`, `/etc/bind`,
`/etc/phpmyadmin` при этом остаются писабельными, так что это не вся ФС, а именно
управление systemd-юнитами), запись падала с "Read-only file system", а так как весь
скрипт выполняется с `set -e`, это ПАДЕНИЕ УБИВАЛО ВЕСЬ ПРОЦЕСС ЦЕЛИКОМ — ещё до того,
как бот успевал создаться и запуститься.

Исправлено: теперь если systemd-юнит записать нельзя, панель просто пропускает этот
шаг (с понятным предупреждением в лог, не падая), пробует более лёгкий fallback через
`cron @reboot`, и создание/запуск бота продолжается как обычно — сам PM2-процесс для
работы бота systemd не требует, юнит нужен только для автоподъёма после полной
перезагрузки сервера.

Заодно проверены и защищены от той же ошибки ещё 7 подобных мест (конфиги nginx для
панели и сайтов, phpMyAdmin, bind9, sudoers, cron) — если что-то из этого тоже
окажется read-only на твоей машине, панель теперь предупредит и продолжит работу
вместо того, чтобы вылетать с сырой ошибкой bash.

Проверить, что именно read-only на сервере: `mount | grep ' / '` и
`findmnt /etc/systemd/system`.


## 5. "Не удалось получить блокировку файла /var/lib/dpkg/lock-frontend"

Это не баг панели — это значит, что в момент запуска `install.sh` apt/dpkg уже
использовался другим процессом (чаще всего фоновые автообновления Ubuntu,
`unattended-upgrades`). С v49 `install.sh` сам ждёт освобождения блокировки до 3 минут
вместо мгновенного отказа. Если это всё равно повторяется — посмотри, что держит
блокировку: `sudo fuser /var/lib/dpkg/lock-frontend` и подожди завершения процесса
(или `sudo systemctl stop unattended-upgrades` на время установки).


## 6. Долгая установка бота + статистика ботов не обновлялась без перезагрузки

Обе проблемы были в одном и том же месте — панель на каждое действие с ботами
безусловно перепроверяла весь рантайм (python/node/npm/pm2/systemd), даже когда всё
уже давно стоит:

- **Создание бота**: при каждом клике "Загрузить и запустить" панель дёргала
  `apt-get update` по всем репозиториям (Ubuntu x4, nodesource, ondrej/php PPA), даже
  если Node.js уже нужной версии. На домашнем интернете это легко давало от 10 секунд
  до пары минут ожидания впустую на КАЖДОГО бота. Теперь если Node.js уже нужной
  версии — apt вообще не трогается (замерено: 2 мс вместо полного apt-get update).
- **Live-статистика ботов**: страница "Боты" и так была устроена опрашивать
  `/?api=bots` каждые 4 секунды в фоне (без перезагрузки) — но сама эта команда на
  сервере попутно перезапускала полную проверку python/node/pm2 и **записывала
  dump.pm2 на диск** при каждом опросе. Из-за этого реальный интервал обновления
  растягивался на секунды, а иногда команда не укладывалась в таймаут (8с) и
  обновление вообще пропускалось. Теперь для простого чтения статуса используется
  прямой опрос PM2 без лишней работы (замерено: 43 мс вместо нескольких секунд) —
  статистика (RAM/CPU/uptime/restarts) обновляется на странице сама, раз в 4 секунды,
  без перезагрузки.

Кнопки долгих операций (создание бота, установка зависимостей, "Обновить" в шапке)
теперь сразу блокируются и показывают спиннер с пояснением при клике — если что-то
идёт, это будет видно сразу, а не "непонятно, сработало или зависло".
