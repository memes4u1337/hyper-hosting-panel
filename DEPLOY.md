# Установка v76

Загрузи содержимое архива в корень репозитория и выполни:

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v76-deploy-manager-upload-only.sh
```

После установки открой `Панель → Боты → Deploy Manager`.

Главный бот: самостоятельно загрузи `bot.py`, `.env`, `requirements.txt`.
Шаблон магазинов: самостоятельно загрузи `bot.py`, `requirements.txt`.
Установщик никаких файлов-примеров не создаёт.
