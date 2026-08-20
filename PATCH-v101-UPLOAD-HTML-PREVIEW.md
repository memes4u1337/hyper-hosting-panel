# HYPER CLOUD v101 — upload progress + HTML website preview

Патч устанавливается поверх v100 и сохраняет текущие файлы Cloud, папки, приватные/public share-ссылки и редактор.

## Что добавлено

- Красивый progress bar при загрузке файлов без перезагрузки страницы во время передачи.
- Процент загрузки, загруженный/общий объём и текущая скорость.
- Состояния: загрузка, 100%, ошибка, повторная попытка.
- AJAX-upload использует существующий CSRF и те же серверные проверки, что обычная загрузка.
- `.html` / `.htm` теперь по умолчанию открываются как живая веб-страница внутри Cloud.
- В HTML preview подтягиваются локальные CSS, JS, изображения, видео, шрифты и другие относительные ресурсы из той же папки Cloud.
- Локальные ссылки между HTML-страницами продолжают работать внутри preview.
- В preview есть адресная строка, кнопка обновления и кнопка открытия preview в отдельном окне.
- HTML preview изолирован CSP sandbox и не получает прямого доступа к интерфейсу/сессии панели.
- Кнопка «Редактировать» для HTML сохранена: можно менять код, сохранять и сразу возвращаться к визуальному preview.
- Все функции v100 сохранены: удаление, редактор текста, ZIP/7z/RAR, sharing, Drag & Drop, приватность.

## Установка из GitHub

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.9-cloud-upload-preview.sh && \
sudo ./apply-v1.9-cloud-upload-preview.sh /root/hyper-hosting-panel
```

После установки откройте `/cloud/` и сделайте Ctrl+F5.

## Проверка

```bash
php -l /var/www/hyper-host/public/cloud/index.php
node --check /var/www/hyper-host/public/cloud/cloud.js
sudo nginx -t
```

Данные пользователей находятся в `/var/www/hyper-host-cloud` и патч их не удаляет.
