# HYPER-HOST CS 1.6 Hosting Patch v1.0

Назначение: отдельная панель Counter-Strike 1.6 на `www.avito.hyper-host.pw` поверх существующего HYPER-HOST.

## Установка

```bash
sudo bash install-cs16-panel.sh
```

С SSL сразу после того, как A-запись домена уже смотрит на сервер:

```bash
sudo CS16_SSL_EMAIL=you@example.com bash install-cs16-panel.sh
```

Если внешний IPv4 нужно задать вручную:

```bash
sudo CS16_PUBLIC_IP=1.2.3.4 CS16_SSL_EMAIL=you@example.com bash install-cs16-panel.sh
```

## Что входит

- SteamCMD + HLDS Counter-Strike 1.6;
- Classic HLDS или ReHLDS + ReGameDLL_CS;
- Metamod-R + AMX Mod X;
- несколько независимых серверов;
- systemd start/stop/restart/autostart;
- MariaDB статистика и история игроков;
- A2S + GoldSrc RCON;
- онлайн игроки: SteamID, IP, score, ping, время, kick/ban;
- RCON-консоль;
- карты: список, загрузка BSP, changelevel;
- editor server.cfg / AMXX configs / users.ini / plugins.ini;
- загрузка AMXX и enable/disable;
- отдельный FTP на файлы каждого сервера;
- CPU/RAM/DISK/Ping/Uptime/online;
- journalctl логи;
- Steam update и reinstall с восстановлением AMXX;
- аудит действий.

## Security fix final

- config-write получает содержимое только через stdin;
- PHP не может передать root-контроллеру произвольный путь к файлу;
- BSP/AMXX проходят через `/var/lib/hyper-cs16/uploads`;
- staging token имеет фиксированный формат;
- root проверяет owner `www-data`, inode/device, regular-file, размер и расширение;
- `O_NOFOLLOW` блокирует подмену через symlink;
- tar/zip загрузки модов отклоняют symlink/hardlink/device entries и path traversal;
- game config paths allow-listed;
- игровые порты ограничены диапазоном UFW `27015-27100/udp`.

Подробнее: `README-CS16-HOSTING-RU.md`.
