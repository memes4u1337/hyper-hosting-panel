# HYPER CLOUD v98 — Bootstrap + Font Awesome Premium UI

## Что изменено
- Bootstrap 5.3.8 подключён через jsDelivr.
- Font Awesome Free 6.7.2 подключён через cdnjs.
- Полностью отполирован standalone-интерфейс /cloud/.
- Новая панель состояния: приватность, публичные ссылки, свободное место.
- Улучшены sidebar, header, карточки, списки, кнопки, контекстные меню и responsive.
- Все модальные окна теперь LOCKED: клик по backdrop не закрывает, ESC не закрывает.
- Закрытие пользовательской модалки — только явным крестиком. Переход на другую модалку по действию «Создать» остаётся намеренным действием.
- Приватный доступ и публичные ссылки v97 сохранены без изменений.

## Установка
```bash
cd /root && rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && chmod +x apply-v1.6-cloud-ui.sh && \
sudo ./apply-v1.6-cloud-ui.sh /root/hyper-hosting-panel
```

Cloud: https://panel.hyper-host.pw/cloud/
