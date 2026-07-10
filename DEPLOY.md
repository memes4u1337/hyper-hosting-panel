# HYPER-HOST v56

Загрузи содержимое этой папки в корень GitHub-репозитория и выполни на сервере:

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v56-single-ftp-fix.sh
```

Проверка:

```bash
sudo hyper ftp doctor
sudo hyper connectivity doctor
cat /root/hyper-host-v56-ftp-report.txt
```

FileZilla:

- LAN: `192.168.0.179`, порт `21`;
- Internet: `90.189.208.25`, порт `21`;
- режим передачи: Passive;
- шифрование: Plain FTP;
- passive range: `40000-40100`.

Проброс роутера:

```text
TCP 21          -> 192.168.0.179:21
TCP 40000-40100 -> 192.168.0.179:40000-40100
```
