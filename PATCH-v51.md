# HYPER-HOST v51 — IP / FTP / MySQL / phpMyAdmin

## Установка патча

```bash
unzip hyper-host-v51-network-ftp-mysql-patch.zip
cd hyper-host-v51-network-ftp-mysql-patch
sudo bash apply-v51-network-ftp-mysql-patch.sh
```

## Новые команды

```bash
sudo hyper ip                 # LAN/WAN IP, шлюз, интерфейс, FTP/SQL/phpMyAdmin
sudo hyper ip fix             # заново определить IP и применить ко всем сервисам
sudo hyper ftp doctor         # состояние FTP и passive-портов
sudo hyper ftp test LOGIN PASSWORD 127.0.0.1
sudo hyper db status          # реальные SQL endpoints
sudo hyper db doctor          # диагностика bind/3306/пользователей
sudo hyper db external enable # повторно включить внешний SQL
sudo hyper db user USER PASS DB %
```

## Что исправлено

- Внутренний IP определяется по default route, внешний — через несколько независимых сервисов с кэшем и fallback.
- IP автоматически записываются в конфигурацию панели и обновляются cron-задачей раз в 5 минут.
- FTP использует реальный встроенный сервер HYPER-HOST, поддерживает passive и active mode, загрузку, скачивание, удаление и REST resume.
- Для клиента из LAN passive mode сообщает внутренний IP; для клиента из интернета — внешний IP.
- MySQL слушает `0.0.0.0:3306`, firewall открывается, а удалённые аккаунты создаются с нужным Host (`%`, IP или маска).
- phpMyAdmin всегда подключается к MariaDB через `127.0.0.1:3306`, но показывает реальные WAN/LAN адреса для внешних программ.
- В панели исправлена кнопка копирования данных: удалённая база теперь выдаёт WAN-IP, локальная — `127.0.0.1`.

## Обязательный проброс на роутере

На внутренний IP, который показывает `sudo hyper ip`, необходимо пробросить:

```text
TCP 21             -> LAN_IP:21
TCP 40000-40100    -> LAN_IP:40000-40100
TCP 3306           -> LAN_IP:3306
```

Для сайтов дополнительно: TCP 80 и TCP 443. Для собственного DNS: TCP/UDP 53.

Если WAN-IP роутера не совпадает с внешним IP из `sudo hyper ip`, вероятен CGNAT/двойной NAT. В таком случае вход из интернета не заработает без белого IP от провайдера, VPN-туннеля или reverse tunnel.

## Безопасность SQL

Не используй слабые пароли и не создавай удалённый доступ для `root`. Лучше ограничивать Host конкретным внешним IP:

```bash
sudo hyper db user bot_user 'СЛОЖНЫЙ_ПАРОЛЬ' bot_db 203.0.113.25
```
