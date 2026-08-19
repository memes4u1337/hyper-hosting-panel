HYPER-HOST CLOUD v95
====================

1. Положить эти файлы в main репозитория HYPER-HOST:
   apply-v1.3-cloud-storage.sh
   src/app/cloud.php
   src/public/assets/cloud.css
   src/public/assets/cloud.js

2. На сервере выполнить:

cd /root && rm -rf /root/hyper-hosting-panel && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && cd /root/hyper-hosting-panel && chmod +x apply-v1.3-cloud-storage.sh && sudo ./apply-v1.3-cloud-storage.sh /root/hyper-hosting-panel

3. Открыть:
   https://panel.hyper-host.pw/?page=cloud

Cloud работает только после авторизации в основной панели.
