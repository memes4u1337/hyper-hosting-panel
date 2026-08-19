HYPER CLOUD v96
===============

Главное изменение: Cloud больше НЕ открывается внутри HYPER-HOST.
Новый standalone URL: https://panel.hyper-host.pw/cloud/

Файлы:
- apply-v1.4-cloud-standalone.sh
- src/public/cloud/index.php
- src/public/cloud/cloud.css
- src/public/cloud/cloud.js

Хранилище:
/var/www/hyper-host-cloud

Установка после загрузки overlay в GitHub main:

cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.4-cloud-standalone.sh && \
sudo ./apply-v1.4-cloud-standalone.sh /root/hyper-hosting-panel
