HYPER CLOUD v109

Установка из корня репозитория:

  chmod +x apply-v2.7-cloud-rar-preview-auth.sh
  sudo ./apply-v2.7-cloud-rar-preview-auth.sh /root/hyper-hosting-panel

Патч НЕ удаляет:
- /var/lib/hyper-host-cloud/cloud.sqlite
- /var/www/hyper-host-cloud/users/
- /var/www/hyper-host-cloud/shared/
- публичные ссылки

v109 устанавливает unrar/rar из Ubuntu multiverse и перед завершением реально
создаёт тестовый RAR, открывает index.html в editor.php, сохраняет изменение,
запускает HTML-preview и проверяет style.css через site-resource.php.

Поле кода подтверждения из Cloud-login удалено. Для panel-linked аккаунта Cloud
использует логин+пароль панели; настройки 2FA входа в саму HYPER-HOST панель
этот патч не меняет.
