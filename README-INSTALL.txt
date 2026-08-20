HYPER CLOUD v103
================

Главный URL:
  https://cloud.hyper-host.pw/

Что изменено:
- отдельный домен и отдельное приложение Cloud;
- отдельная регистрация пользователей облака;
- логин/пароль пользователя HYPER-HOST панели также подходят для Cloud;
- новые Cloud-аккаунты НЕ добавляются в базу панели и НЕ могут входить в panel.hyper-host.pw;
- личные файлы каждого аккаунта физически отделены;
- общая папка видна всем Cloud-аккаунтам;
- загрузка больших файлов идёт чанками по 4 MiB через отдельный JSON API, поэтому больше нет ложной ошибки HTTP 200;
- progress bar, retry каждой части до 3 раз;
- HTML/HTM имеют кнопку «Сайт» и открываются отдельной вкладкой с CSS/JS/images из своей папки;
- HTML внутри ZIP/7Z/RAR тоже можно открыть как сайт;
- редактор кода работает для обычных файлов и файлов внутри архивов;
- размер самого архива не блокирует редактор; список архива читается полностью, без прежнего лимита 250000 элементов;
- ZIP и 7Z редактируются; installer также пытается установить rar для записи RAR;
- Bootstrap + Font Awesome + отдельный Cloud CSS/JS;
- публичные ссылки, скачивание, удаление, папки и Drag & Drop сохранены.

Хранилище:
  /var/www/hyper-host-cloud/users/<account>/   личные файлы
  /var/www/hyper-host-cloud/shared/            общая папка
  /var/lib/hyper-host-cloud/cloud.sqlite       аккаунты/метаданные Cloud

Установка после загрузки файлов в GitHub main:
  cd /root && rm -rf /root/hyper-hosting-panel && \
  git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
  cd /root/hyper-hosting-panel && \
  chmod +x apply-v2.1-cloud-domain-multiuser.sh && \
  sudo ./apply-v2.1-cloud-domain-multiuser.sh /root/hyper-hosting-panel

DNS:
  cloud.hyper-host.pw должен иметь A-запись на IP сервера.
  Installer сам попробует получить Let's Encrypt SSL. Если DNS ещё не готов, он не удалит Cloud и напечатает команду certbot для повторного запуска.

Важно:
- старые файлы Cloud не удаляются;
- при первой миграции они переносятся в личное хранилище первого администратора панели;
- старые публичные ссылки из shares.json импортируются с теми же токенами;
- /?page=cloud и старый /cloud/ панели перенаправляются на cloud.hyper-host.pw.
