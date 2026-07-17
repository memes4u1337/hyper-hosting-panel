# HYPER-HOST v15 Quick Start

## Обновление сервера из GitHub

```bash
cd /root/hyper-hosting-panel

git fetch origin main
git checkout main
git reset --hard origin/main
git clean -fd

chmod +x setup.sh install.sh uninstall.sh scripts/hhctl scripts/hyper || true

sudo bash setup.sh

sudo hyper repair
sudo hyper network fix hyper-host.pw 90.189.208.25
sudo hyper bot persist
sudo hyper stats
sudo hyper bots
sudo hyper network doctor hyper-host.pw
sudo hyper ssl check hyper-host.pw

sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart vsftpd
```

## Перенос домена на свои DNS

```bash
sudo hyper dns wizard hyper-host.pw 90.189.208.25 panel
sudo hyper dns status hyper-host.pw
```

У регистратора домена поставить NS:

```text
ns1.hyper-host.pw
ns2.hyper-host.pw
```

Glue/IP:

```text
ns1.hyper-host.pw -> 90.189.208.25
ns2.hyper-host.pw -> 90.189.208.25
```

## Проброс портов на роутере

```text
TCP 80   -> 192.168.0.179:80
TCP 443  -> 192.168.0.179:443
TCP 53   -> 192.168.0.179:53
UDP 53   -> 192.168.0.179:53
```

## SSL

```bash
sudo hyper ssl fix hyper-host.pw
sudo hyper ssl check hyper-host.pw
sudo hyper ssl issue hyper-host.pw admin@example.com
```
