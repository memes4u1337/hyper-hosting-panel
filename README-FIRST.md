# HYPER-HOST v75 — отдельный MyStock Deploy Manager

## Установка обновления

Загрузи содержимое архива в корень репозитория и выполни:

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v75-deploy-manager-pro.sh
```

После установки открой отдельную страницу:

```text
Панель → Боты → Deploy Manager
```

или:

```text
http://IP-ПАНЕЛИ/?page=deploy_center
```

## Главный deploy-бот

Панель ничего не генерирует для главного бота. Загружаются твои файлы:

- `bot.py`
- `.env`
- `requirements.txt`

Готовая переписанная версия переданного deploy-бота находится в архиве:

```text
ready-master-bot/
```

и после установки на сервере:

```text
/opt/hyper-host/deploy-center/examples/
```

Скопируй `.env.example` в `.env`, заполни токен главного бота и пароль MySQL, затем загрузи все три файла через Deploy Manager.

## Файлы дочерних магазинов

В отдельный блок загружаются только твои:

- `bot.py`
- `requirements.txt`

Установщик не создаёт и не подставляет файлы-заглушки.

Хранилище шаблона:

```text
/var/www/hyper-host-deploy/template/
```

## Папки созданных магазинов

```text
/var/www/hyper-host-managed-bots/<project_id>-<название-магазина>/
```

В каждой папке автоматически создаются:

- копия твоих файлов шаблона;
- `.env` из MySQL;
- отдельный `venv`;
- папка `logs`;
- отдельный PM2-процесс.

## `.env` дочернего магазина

```env
BOT_TOKEN=<projects.bot_token>
DB_HOST=90.189.208.25
DB_USER=mystock
DB_PASS=<пароль, сохранённый в Deploy Manager>
DB_NAME=mystock
DB_PORT=3306
PROJECT_ID=<projects.id>
PROJECT_NAME=<projects.project_name>
OWNER_USER_ID=<projects.user_id>
OWNER_TG_ID=<users.tg_id>
OWNER_USERNAME=<users.username>
```

## Уведомления главного бота

Переписанный главный бот уведомляет всех пользователей MySQL с `users.role='admin'`:

- начало запуска магазина;
- название и Project ID;
- кто создал магазин;
- полный токен;
- Telegram username и ссылка;
- папка проекта;
- PM2-имя;
- успешный запуск или полная ошибка.

## SSL

v75 не переписывает Nginx и не меняет сертификаты. Он только показывает фактический аудит через:

```bash
sudo hyper-host-ctl ssl-audit-json
```

Отчёт установки:

```bash
sudo cat /root/hyper-host-v75-deploy-manager-report.txt
```
