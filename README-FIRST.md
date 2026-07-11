# HYPER-HOST v74 — MyStock Deploy Center + truthful SSL

## Установка обновления

Загрузи содержимое архива в корень репозитория и выполни:

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v74-deploy-center-ssl-truth.sh
```

Отчёт:

```bash
sudo cat /root/hyper-host-v74-deploy-center-report.txt
```

## Новая структура ботов

```text
/var/www/hyper-host-deploy/master/          главный deploy-бот
/var/www/hyper-host-deploy/template/        bot.py + requirements.txt шаблона
/var/www/hyper-host-managed-bots/           дочерние магазины
  123-komplektoff-pc/
    bot.py
    requirements.txt
    .env
    venv/
```

`.env` дочернего проекта создаётся автоматически из `projects.bot_token` и настроек MySQL:

```dotenv
BOT_TOKEN=<projects.bot_token>
DB_HOST=90.189.208.25
DB_PORT=3306
DB_USER=mystock
DB_PASS=<пароль, сохранённый на сервере>
DB_NAME=mystock
PROJECT_ID=<projects.id>
PROJECT_NAME=<projects.project_name>
OWNER_USER_ID=<projects.user_id>
OWNER_TG_ID=<users.tg_id>
OWNER_USERNAME=<users.username>
```

Пароль MySQL не хранится в GitHub. Патч пытается забрать его из существующего MySQL-аккаунта `mystock` в SQLite панели. Если аккаунта в панели нет, введи пароль один раз в `Боты → MyStock Deploy Center`.

## Что появилось в панели

- загрузка `bot.py` и `requirements.txt` главного deploy-бота;
- выбор проекта, токен которого используется главным ботом;
- загрузка `bot.py` и `requirements.txt` шаблона магазина;
- синхронизация `projects + users + bot_deployments` из MySQL;
- название магазина, владелец, Telegram ID, username владельца;
- ссылка `https://t.me/<bot_username>` через Telegram `getMe`;
- Deploy / Start / Stop / Restart / Logs каждого проекта;
- отдельная папка и venv каждого магазина;
- реальный PM2-статус вместе со статусом из MySQL;
- диагностика зависимостей сервера.

## Что нужно серверу

Патч устанавливает/проверяет:

- Python 3;
- `python3-venv`;
- `python3-pip`;
- Node.js/NPM;
- PM2;
- PyMySQL в отдельном venv Deploy Center;
- доступ пользователя `hyperbot` к каталогам deploy/template/projects;
- рабочее подключение к MySQL;
- доступ к `api.telegram.org` для получения username бота.

## SSL

Панель больше не считает `sites.ssl_enabled=1` доказательством работающего SSL.

Новый аудит проверяет:

1. наличие сертификата в `/opt/hyper-host/letsencrypt/live` и `/etc/letsencrypt/live`;
2. SAN/CN и срок действия;
3. HTTPS-vhost Nginx;
4. сертификат, который Nginx реально отдаёт по SNI.

Статусы:

- `active` — SSL реально отдаётся;
- `cert_only` — сертификат на диске есть, но Nginx его не подключил;
- `missing` — сертификата нет;
- `expired` — сертификат просрочен.

Кнопка **«Подключить найденные сертификаты»** возвращает действующие сертификаты в Nginx. Если файлов сертификата уже нет, его нельзя «вернуть» без нового выпуска через Let’s Encrypt.
