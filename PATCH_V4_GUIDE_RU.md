# HYPER-HOST v4 patch

## Что исправлено

1. **FTP аккаунты**
   - Исправлена типичная проблема Ubuntu/vsftpd: пользователи с `/usr/sbin/nologin` теперь автоматически разрешены через `/etc/shells`.
   - FTP-пользователь получает чистый корень `/var/www/hyper-host-ftp/hhftp_USER`.
   - Внутри всегда есть общая папка `common`.
   - Если FTP привязан к сайту/папке/боту, внутри появляется папка `site`, привязанная к выбранной директории через bind mount.
   - В панели показывается ровно:
     - Хост
     - Имя пользователя
     - Пароль

2. **Папки сайтов**
   - Добавлен отдельный раздел `Папки`.
   - При создании папки создаётся:
     ```text
     /var/www/hyper-host-sites/ИМЯ/public_html/index.php
     ```
   - Стартовая страница пустого сайта создаётся автоматически с названием папки.

3. **Создание сайтов**
   - При создании сайта сразу создаётся папка:
     ```text
     /var/www/hyper-host-sites/DOMAIN/public_html
     ```
   - Если файлов нет, создаётся стартовый `index.php`.
   - Автоматически создаётся Nginx-конфиг.

4. **Боты 24/7**
   - Боты создаются как `systemd`-сервисы.
   - В сервисе стоит `Restart=always`.
   - Бот запускается после перезагрузки сервера.
   - Добавлена кнопка установки зависимостей:
     - Python: `requirements.txt` → `venv` + pip install.
     - Node.js: `package.json` → npm install.
   - Добавлены кнопки Start / Stop / Restart / Logs / Deps.

5. **Дизайн**
   - Полностью обновлён интерфейс.
   - Добавлены Bootstrap 5 и FontAwesome.
   - Сделано меню в стиле современной хостинг-панели.
   - Добавлены красивые карточки, статистика, FTP-карточки, статусы сервисов.

6. **Сохранение**
   - Сохранение ресурсов идёт через SQLite.
   - После root-команд записи сохраняются в базу панели.
   - Добавлена синхронизация ресурсов с сервера.

---

## Как залить v4 в GitHub

Распакуй архив `HYPER-HOST-v4-patch.zip`.

Скопируй содержимое папки `hyper-host-v4` поверх своего локального репозитория:

```bash
cd hyper-hosting-panel
cp -r /path/to/hyper-host-v4/* ./
```

Потом:

```bash
git status
git add .
git commit -m "HYPER-HOST v4: FTP common folders, 24/7 bots and Bootstrap UI"
git push origin main
```

---

## Как обновить сервер из GitHub

На сервер ничего руками не загружай. После push в GitHub выполни на сервере:

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

## Если панель должна быть на домене

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

## Проверка FTP

Создать FTP через SSH:

```bash
sudo hyper-host-ctl create-ftp hyperhost 'StrongFTPPassword123!' /var/www/hyper-host-sites/hyper-host.pw/public_html
```

Проверить пользователя:

```bash
id hhftp_hyperhost
getent passwd hhftp_hyperhost
```

Проверить FTP:

```bash
sudo systemctl status vsftpd --no-pager
sudo ss -lntp | grep ':21'
sudo ufw allow 21/tcp
sudo ufw allow 40000:40100/tcp
sudo ufw status
```

Данные подключения:

```text
Хост: IP_СЕРВЕРА или panel.hyper-host.pw
Порт: 21
Имя пользователя: hhftp_hyperhost
Пароль: StrongFTPPassword123!
Пассивный режим: включить
```

После входа в FTP будут папки:

```text
common/
site/    если FTP привязан к сайту/папке/боту
```

---

## Проверка бота 24/7

```bash
sudo hyper-host-ctl bot-create mybot python 'python3 main.py'
sudo hyper-host-ctl bot start mybot
sudo systemctl status hyperbot-mybot.service --no-pager
sudo journalctl -u hyperbot-mybot.service -n 100 --no-pager
```

Если есть `requirements.txt`:

```bash
sudo hyper-host-ctl bot-install-requirements mybot
sudo hyper-host-ctl bot restart mybot
```

---

## Что ещё не хватает для полной панели

- Файловый менеджер прямо в браузере.
- Backup сайтов/баз/ботов по расписанию.
- DNS-менеджер.
- Менеджер PHP-версий для каждого сайта.
- Cron-задачи.
- Логи сайтов в UI.
- 2FA и IP allowlist для входа в панель.
- Telegram-уведомления при падении бота/ошибке Nginx/нехватке места.
- Ограничения ресурсов для ботов и сайтов.
- Автоматическая проверка SSL-сертификатов.
