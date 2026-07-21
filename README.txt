HYPER-HOST v1.2 — NETWORK / SSL REPAIR

Фиксированные адреса:
  LAN: 192.168.0.179
  WAN: 90.189.208.25

Установка из каталога патча:
  sudo chmod +x apply-v1.2-network-ssl-repair.sh
  sudo ./apply-v1.2-network-ssl-repair.sh /root/hyper-hosting-panel

После установки:
  sudo hyper public-ip get
  sudo hyper nginx doctor
  sudo hyper ssl restore
  sudo hyper ssl check DOMAIN
  sudo hyper ssl issue DOMAIN EMAIL

Для HTTP-01 на роутере должны быть проброшены TCP 80 и 443 на 192.168.0.179.
Публичная DNS-запись домена: только A = 90.189.208.25, без AAAA и лишних A.
