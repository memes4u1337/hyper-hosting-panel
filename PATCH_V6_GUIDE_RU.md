# HYPER-HOST v6 — патч

## Что добавлено

### Боты PM2 24/7

Теперь бот создаётся удобным способом:

- основной файл: `bot.py` / `index.js` / `bot.php`;
- `.env` можно загрузить, можно пропустить;
- `requirements.txt` можно загрузить, можно пропустить;
- перед запуском Python-бота панель создаёт `venv` и ставит зависимости;
- после зависимостей бот запускается в PM2 24/7;
- PM2 `--name` берётся из названия бота;
- в панели видно список ботов, статус, RAM, файлы, логи;
- кнопки Start / Stop / Restart / Deps / Logs / Files.

CLI пример:

```bash
sudo hyper-host-ctl bot-create mystockbot python bot.py 512
sudo hyper-host-ctl bot-install-requirements mystockbot python
sudo hyper-host-ctl bot restart mystockbot
sudo hyper-host-ctl bot logs mystockbot
```

Аналог старого запуска:

```bash
pm2 start bot.py --interpreter python3 --name mystockbot
```

Но теперь панель делает это сама и дополнительно подключает `.env`.

### SSL

Добавлена проверка DNS перед Certbot.

Если у домена нет A/AAAA записи, панель больше не запускает Certbot вслепую, а показывает понятную ошибку:

```text
Добавь DNS A: domain.ru -> PUBLIC_IP
```

Проверка:

```bash
sudo hyper-host-ctl ssl-check-json hyper-host.pw
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

Важно: Let’s Encrypt не выпустит сертификат, если домен не указывает публичной A-записью на этот сервер и порт 80 недоступен из интернета.

### FTP

Структура FTP теперь такая:

```text
common/
  sites/
    hyper-host.pw/
      public_html/
  bots/
    mystockbot/
      bot.py
      .env
      requirements.txt
```

То есть при входе в FTP пользователь видит одну общую папку `common`, а уже внутри неё сайты и боты.

### Файловый менеджер

Переделан файловый менеджер:

- слева блок “Мой ПК” для загрузки файлов;
- справа дерево/список сервера;
- загрузка нескольких файлов сразу;
- создание папок;
- удаление;
- редактор файлов PHP/HTML/CSS/JS/TXT;
- после загрузки автоматически запускается ремонт прав.

### Дизайн

- правое окно не белое, а тёмное;
- улучшен layout файлового менеджера;
- улучшены карточки FTP/ботов/SSL;
- интерфейс стал ближе к нормальной хостинг-панели.

---

## Как залить v6 в GitHub

Распакуй архив и скопируй содержимое папки `hyper-host-v6` поверх своего репозитория:

```bash
cd hyper-hosting-panel
cp -r /path/to/hyper-host-v6/* ./

git status
git add .
git commit -m "HYPER-HOST v6: bot uploader, FTP common folder, SSL DNS check and file manager UI"
git push origin main
```

---

## Как обновить сервер после GitHub

На сервере:

```bash
cd /root

if [ ! -d /root/hyper-hosting-panel/.git ]; then
  git clone https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel
fi

cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

sudo bash install.sh
sudo hyper-host-ctl repair
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl stats-json

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

---

## Проверка после обновления

```bash
sudo hyper-host-ctl repair
sudo hyper-host-ctl stats-json
sudo hyper-host-ctl sync-json
sudo hyper-host-ctl bot-list-json
sudo hyper-host-ctl ssl-check-json hyper-host.pw
sudo nginx -t
sudo systemctl status nginx --no-pager
sudo systemctl status vsftpd --no-pager
```

---

## Почему SSL на hyper-host.pw не выпускался

Ошибка была такая:

```text
для hyper-host.pw не найдено действительных записей A
для hyper-host.pw не найдено действительных записей AAAA
```

Это значит, что у домена нет публичной DNS-записи.

Нужно зайти к регистратору домена и добавить:

```text
A    hyper-host.pw    PUBLIC_IP_СЕРВЕРА
A    www              PUBLIC_IP_СЕРВЕРА
```

Проверить:

```bash
dig +short hyper-host.pw
dig +short www.hyper-host.pw
curl -4 ifconfig.me
```

`dig` должен показать тот же публичный IP, что и `curl -4 ifconfig.me`.

После этого:

```bash
sudo hyper-host-ctl ssl-site hyper-host.pw admin@example.com
```

---

## Как расширить диск Ubuntu до всего объёма 1 ТБ

Сначала посмотри разметку:

```bash
lsblk
sudo fdisk -l
df -hT
```

### Если Ubuntu стоит на LVM

Частый вариант:

```text
/dev/sda        1T
/dev/sda3       100G
ubuntu--vg-ubuntu--lv  97G /
```

Тогда делай так:

```bash
sudo apt update
sudo apt install -y cloud-guest-utils lvm2

lsblk
```

Если корневой раздел `/dev/sda3`, то:

```bash
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -r -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
```

Проверка:

```bash
df -h
lsblk
```

### Если без LVM и ext4

Например корень `/dev/sda1`:

```bash
sudo apt install -y cloud-guest-utils
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
```

### Если XFS

```bash
sudo growpart /dev/sda 1
sudo xfs_growfs /
```

Перед расширением лучше сделать snapshot/backup VPS.
