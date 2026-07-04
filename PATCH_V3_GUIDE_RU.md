# HYPER-HOST v3 — патч сохранения, FTP и статистики

## Что исправлено

1. Исправлена главная причина, почему панель «ничего не сохраняла».
   PHP-команда `proc_close()` могла возвращать `-1` после `proc_get_status()`, хотя root-команда реально выполнялась успешно. Из-за этого сайт/FTP/база создавались на сервере, но панель считала операцию ошибкой и не записывала данные в SQLite.

2. Исправлена статистика железа.
   Если `hyper-host-ctl stats-json` отдаёт JSON, панель теперь корректно его принимает и не показывает ошибку `Статистика пока недоступна: {...}`.

3. Переделана страница FTP.
   Теперь FTP показывается понятными карточками:
   - Хост
   - Имя пользователя
   - Пароль
   - Папка
   - Кнопки копирования

4. Добавлено сохранение FTP-пароля в SQLite панели.
   Важно: Linux не позволяет достать старый пароль FTP-пользователя обратно. Поэтому пароль виден только у FTP, созданных/обновлённых через панель v3. Для старых FTP можно нажать «Задать новый пароль».

5. Добавлена команда:

```bash
sudo hyper-host-ctl ftp-password USER PASS
```

6. Улучшено меню и интерфейс панели.

7. Добавлена миграция SQLite: колонка `password_plain` в таблицу `ftp_accounts`.

---

## Как залить патч в GitHub

На своём ПК распакуй архив `HYPER-HOST-v3-patch.zip`.

Скопируй содержимое папки `hyper-host-v3` поверх локального репозитория:

```bash
cd hyper-hosting-panel
cp -r /path/to/hyper-host-v3/* ./
```

Потом отправь в GitHub:

```bash
git status
git add .
git commit -m "HYPER-HOST v3: fix saving, FTP credentials and stats"
git push origin main
```

---

## Как обновить сервер из GitHub

На сервере ничего вручную не загружай. Выполни:

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

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl stats-json
sudo nginx -t
sudo systemctl reload nginx
```

---

## Если панель должна открываться на домене

Например, если панель должна быть на `panel.hyper-host.pw`:

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

PANEL_DOMAIN=panel.hyper-host.pw sudo -E bash install.sh

sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl stats-json
sudo nginx -t
sudo systemctl reload nginx
```

---

## Что сделать после обновления

В панели нажми:

```text
Настройки → Починить права и сервисы
```

Потом:

```text
Дашборд → Синхронизировать ресурсы
```

---

## Как создать FTP правильно

В панели открой:

```text
FTP → Создать FTP
```

Укажи:

```text
Имя пользователя: hyperhost
Пароль: StrongFTPPassword123!
Папка: /var/www/hyper-host-sites/hyper-host.pw/public_html
```

В панели будет показано:

```text
Хост: IP_СЕРВЕРА или домен панели
Имя пользователя: hhftp_hyperhost
Пароль: StrongFTPPassword123!
```

---

## Если старый FTP уже создан, но пароль не виден

Это нормально: старый Linux-пароль нельзя прочитать обратно. Нужно задать новый пароль в панели:

```text
FTP → нужный аккаунт → Задать новый пароль
```

Или через SSH:

```bash
sudo hyper-host-ctl ftp-password hhftp_hyperhost 'NewStrongFTPPassword123!'
```

После SSH-команды пароль будет изменён в Linux, но в панели он появится только если задавать пароль через панель.

---

## Проверка

```bash
sudo hyper-host-ctl stats-json
sudo hyper-host-ctl sync-json
sudo systemctl status nginx --no-pager
sudo systemctl status mariadb --no-pager
sudo systemctl status vsftpd --no-pager
sudo nginx -t
```

Если `stats-json` выводит JSON без ошибки, статистика в панели должна работать.
