HYPER CLOUD v107
================

1. Добавьте содержимое этого overlay в корень main-ветки репозитория HYPER-HOST.

2. На сервере выполните:

cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main \
https://github.com/memes4u1337/hyper-hosting-panel.git \
/root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v2.5-cloud-security-editor.sh && \
sudo ./apply-v2.5-cloud-security-editor.sh /root/hyper-hosting-panel

Установка НЕ удаляет существующие Cloud-аккаунты, приватные файлы, shared-папку и public shares.
Перед изменениями создаётся backup в /opt/hyper-host/backups/cloud-v107-<date>.

Успешный финал обязан содержать:
PANEL_DB_ISOLATED_OK
CLOUD_CODE_READONLY_OK
EDITOR_SITE_PROBE_OK
DOMAIN_OK: HYPER_CLOUD_V107

После установки откройте https://cloud.hyper-host.pw/ и сделайте Ctrl+F5.
