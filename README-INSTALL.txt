HYPER CLOUD v97 — PRIVATE SHARING

1) Загрузите содержимое GitHub Overlay в корень main вашего репозитория.

2) На сервере выполните:

cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.5-cloud-sharing.sh && \
sudo ./apply-v1.5-cloud-sharing.sh /root/hyper-hosting-panel

Cloud: https://panel.hyper-host.pw/cloud/
Файлы: /var/www/hyper-host-cloud
Реестр ссылок: /var/lib/hyper-host-cloud/shares.json

ВАЖНО:
- все файлы приватны по умолчанию;
- публичным становится только выбранный файл после "Открыть доступ по ссылке";
- отключение доступа сразу инвалидирует старую ссылку;
- SQL не требуется.
