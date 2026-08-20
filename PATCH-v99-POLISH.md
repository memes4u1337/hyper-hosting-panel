# HYPER CLOUD v99 — UI polish

Обновление standalone Cloud поверх v97/v98.

## Что изменено
- Главный экран очищен от рекламных и поясняющих блоков. Остаются файлы, папки и действия.
- Просмотр ZIP/RAR/7z переработан в нормальный вертикальный файловый список.
- Публичная страница одного файла стала компактной: имя, размер/дата, предпросмотр и кнопка скачивания.
- Для изображения, PDF, видео и аудио публичная ссылка показывает аккуратный предпросмотр.
- Недействительная или отозванная ссылка теперь имеет отдельную оформленную страницу 404.
- Все существующие правила приватности и публичных токенов сохранены.
- Bootstrap 5.3.8 и Font Awesome сохранены.
- Модальные окна по-прежнему закрываются только явным крестиком; backdrop и ESC заблокированы.

## Установка
Распакуйте GitHub Overlay в корень репозитория, закоммитьте в main и запустите на сервере:

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.7-cloud-polish.sh && \
sudo ./apply-v1.7-cloud-polish.sh /root/hyper-hosting-panel
```

Cloud: `https://panel.hyper-host.pw/cloud/`
