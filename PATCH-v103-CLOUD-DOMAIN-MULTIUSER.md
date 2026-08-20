# HYPER CLOUD v103

## Архитектура

Cloud больше не является частью UI панели. Он устанавливается как отдельное PHP-приложение с Nginx virtual host `cloud.hyper-host.pw`.

### Авторизация

Есть два независимых источника входа:

1. **HYPER-HOST panel account** — пароль проверяется напрямую по существующей SQLite-базе панели. Пароль в Cloud не копируется.
2. **Cloud account** — создаётся только в `/var/lib/hyper-host-cloud/cloud.sqlite`.

Cloud registration **никогда не пишет пользователя в таблицу `users` панели**, поэтому зарегистрированный в Cloud логин нельзя использовать для входа в HYPER-HOST panel.

### Файлы

- private: `/var/www/hyper-host-cloud/users/<storage_key>/`
- common: `/var/www/hyper-host-cloud/shared/`

В общей папке все авторизованные Cloud-пользователи могут смотреть, загружать и скачивать файлы. Изменять/удалять конкретный объект может его владелец или аккаунт панели.

## Исправление upload HTTP 200

Загрузка вынесена в `/api/upload.php`. Каждый файл режется JS на части по 4 MiB. API **всегда отвечает JSON** с корректным HTTP-кодом. Каждая часть автоматически повторяется до трёх раз при сетевой ошибке.

Это убирает ситуацию, когда frontend пытался разобрать HTML-страницу как JSON и показывал «ошибка 200».

## Архивы

- список больше не ограничен размером самого архива;
- поиск entry использует фактическое имя внутри архива;
- редактор не блокируется по размеру самого ZIP/7Z/RAR;
- перед записью создаётся backup; для очень больших архивов используется reflink, а нехватка места под копию больше не блокирует сохранение;
- ZIP: ZipArchive или `zip`;
- 7Z: `7z/7zz`;
- RAR: `rar` (installer пытается установить пакет из multiverse).

## HTML preview

У `.html/.htm` есть отдельная кнопка **Сайт**. Она открывает файл в новой вкладке. Cloud проксирует относительные ресурсы из той же структуры папок: CSS, JS, images, fonts, media, `srcset`, CSS `url()`, `@import`, JS modules и простые `fetch('...')`.

То же работает для HTML, лежащего внутри архива.

## Установка

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main \
https://github.com/memes4u1337/hyper-hosting-panel.git \
/root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v2.1-cloud-domain-multiuser.sh && \
sudo ./apply-v2.1-cloud-domain-multiuser.sh /root/hyper-hosting-panel
```
