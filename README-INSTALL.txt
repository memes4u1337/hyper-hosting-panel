HYPER CLOUD v108
================

Исправление для прерванной установки v107:
Permission denied на /var/www/hyper-host-cloud-app/app/bootstrap.php.

v108 очищает старые ACL только внутри Cloud-приложения, задаёт точные права
для runtime-пользователя hypercloud и отдельно проверяет доступ к bootstrap.php
и /etc/hyper-host/cloud.php ДО инициализации Cloud DB.

1. Добавьте содержимое GitHub Overlay в корень main-ветки HYPER-HOST.

2. На сервере выполните:

cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main \
https://github.com/memes4u1337/hyper-hosting-panel.git \
/root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v2.6-cloud-runtime-repair.sh && \
sudo ./apply-v2.6-cloud-runtime-repair.sh /root/hyper-hosting-panel

Установка НЕ удаляет существующие Cloud-аккаунты, приватные файлы, shared-папку
и public shares. Перед изменениями создаётся backup в
/opt/hyper-host/backups/cloud-v108-<date>.

Успешный финал обязан содержать:
CLOUD_RUNTIME_PERMISSIONS_OK
PANEL_DB_ISOLATED_OK
CLOUD_CODE_READONLY_OK
EDITOR_SITE_PROBE_OK
DOMAIN_OK: HYPER_CLOUD_V108

Если runtime-доступ снова невозможен, installer теперь печатает namei/getfacl для
точного каталога, а не маскирует проблему сообщением Cloud DB.
