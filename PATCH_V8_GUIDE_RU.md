# HYPER-HOST v8 patch

## Что исправлено

1. В ботах добавлена кнопка удаления.
2. Панель спрашивает подтверждение перед удалением.
3. Есть два режима:
   - удалить только PM2-процесс, файлы оставить;
   - удалить PM2-процесс и папку бота с сервера.
4. Для удаления файлов нужно ввести точное имя бота.
5. Исправлено падение `install.sh` на `chown: Circular directory structure`.
6. Установщик теперь до настройки прав снимает сломанные FTP bind-mount'ы и чистит `/etc/fstab`.
7. `hyper-host-ctl repair` стал безопаснее: сначала чистит mount'ы, потом чинит права.

## Как залить в GitHub

Распакуй архив и скопируй содержимое `hyper-host-v8` поверх своего репозитория.

```bash
cd hyper-hosting-panel
cp -r /path/to/hyper-host-v8/* ./
git add .
git commit -m "HYPER-HOST v8: safe bot delete and mount cleanup"
git push origin main
```

## Как обновить сервер из GitHub

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x install.sh uninstall.sh scripts/hhctl || true
sudo bash install.sh

sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl bot-doctor

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## Если старые mount'ы всё ещё видны

```bash
sudo hyper-host-ctl repair
findmnt | grep hyper-host || true
```

Если после repair всё ещё есть `public_html/common/sites`, перезагрузи сервер:

```bash
sudo reboot
```

После перезагрузки снова:

```bash
sudo hyper-host-ctl repair
findmnt | grep hyper-host || true
```
