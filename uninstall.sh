#!/usr/bin/env bash
set -Eeuo pipefail

# По умолчанию сайты и боты НЕ удаляются.
DELETE_USER_DATA="${DELETE_USER_DATA:-0}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запусти от root: sudo bash uninstall.sh"
  exit 1
fi

echo "[HYPER-HOST] Остановка и удаление панели..."

rm -f /etc/nginx/sites-enabled/hyper-host-panel.conf /etc/nginx/sites-available/hyper-host-panel.conf
rm -f /etc/sudoers.d/hyper-host
rm -f /usr/local/sbin/hyper-host-ctl

systemctl daemon-reload || true
systemctl reload nginx || true

rm -rf /var/www/hyper-host
rm -rf /etc/hyper-host

if [[ "$DELETE_USER_DATA" == "1" ]]; then
  echo "[HYPER-HOST] Удаляю пользовательские данные сайтов/ботов/базу панели..."
  rm -rf /opt/hyper-host /var/www/hyper-host-sites /var/www/hyper-host-bots
else
  echo "[HYPER-HOST] Сайты, боты и база панели сохранены:"
  echo "  /opt/hyper-host"
  echo "  /var/www/hyper-host-sites"
  echo "  /var/www/hyper-host-bots"
fi

echo "[HYPER-HOST] Готово. Системные пакеты nginx/php/mariadb/vsftpd не удалялись специально."
