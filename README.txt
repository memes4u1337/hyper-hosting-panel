HYPER-HOST v1.2 — статическая сеть и SSL

LAN: 192.168.0.179
WAN: 90.189.208.25

Запуск:
  chmod +x apply-v1.2-static-network-ssl-final.sh
  sudo ./apply-v1.2-static-network-ssl-final.sh /root/hyper-hosting-panel

После установки:
  sudo hyper ssl check DOMAIN
  sudo hyper ssl issue DOMAIN EMAIL
