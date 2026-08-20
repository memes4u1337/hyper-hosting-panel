# HYPER CLOUD v100 — DELETE + CLOUD EDITOR

## Что добавлено

- Видимое удаление файлов и папок:
  - кнопка корзины на карточке;
  - кнопка удаления в списке;
  - кнопка удаления в окне просмотра;
  - отдельное подтверждение удаления без `window.confirm()`.
- Все Cloud-dialog по-прежнему закрываются только по крестику: backdrop и ESC заблокированы.
- Встроенный редактор обычных текстовых/кодовых файлов до 2 МБ.
- Поддерживаются PHP, HTML, CSS, JS, JSON, XML, SQL, Python, shell, TXT, MD, ENV, YAML и другие текстовые форматы.
- Ctrl+S / Cmd+S сохраняет файл, Tab вставляет два пробела, показывается число строк.
- Редактор файлов внутри архивов:
  - ZIP: просмотр и сохранение;
  - 7Z: просмотр и сохранение при наличии 7-Zip;
  - RAR: просмотр; сохранение только если на сервере установлен `rar`;
  - другие архивы остаются просмотром списка.
- Перед изменением архива создаётся скрытая резервная копия в `/var/lib/hyper-host-cloud/archive-backups`.
- Хранится не более 40 последних резервных копий архивов.
- Публичные ссылки, приватность файлов, drag & drop и структура `/var/www/hyper-host-cloud` сохраняются.

## Ограничения редактора

Редактор предназначен для текстовых файлов до 2 МБ. Бинарные файлы редактировать через браузер нельзя.

## Установка

Из папки патча:

```bash
chmod +x apply-v1.8-cloud-editor.sh
sudo ./apply-v1.8-cloud-editor.sh
```

Либо после добавления GitHub Overlay в корень репозитория:

```bash
cd /root
rm -rf /root/hyper-hosting-panel
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel
cd /root/hyper-hosting-panel
chmod +x apply-v1.8-cloud-editor.sh
sudo ./apply-v1.8-cloud-editor.sh /root/hyper-hosting-panel
```
