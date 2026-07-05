# HYPER-HOST v15 — DNS, внешний/внутренний IP, SSL и сетевой доктор

## Что добавлено

### 1. DNS-менеджер для переноса доменов
Теперь можно создавать свою DNS-зону прямо в панели/CLI.

Команды:

```bash
sudo hyper dns wizard hyper-host.pw 90.189.208.25 panel
sudo hyper dns status hyper-host.pw
sudo hyper dns guide
```

После `dns wizard` у регистратора домена нужно поставить NS:

```text
ns1.hyper-host.pw
ns2.hyper-host.pw
```

Если регистратор просит Glue/IP:

```text
ns1.hyper-host.pw -> 90.189.208.25
ns2.hyper-host.pw -> 90.189.208.25
```

На роутере нужен проброс DNS:

```text
TCP 53 -> 192.168.0.179:53
UDP 53 -> 192.168.0.179:53
```

### 2. Сетевой доктор
Добавлена диагностика внешнего и внутреннего доступа:

```bash
sudo hyper network doctor hyper-host.pw
```

Показывает:

- внутренний IP сервера;
- публичный IP;
- A-запись домена;
- слушает ли Nginx 80/443;
- работает ли bind9;
- работает ли ACME challenge для SSL;
- что именно надо поправить.

### 3. Автофикс сети

```bash
sudo hyper network fix hyper-host.pw 90.189.208.25
```

Делает:

- сохраняет публичный IP;
- чинит Nginx, чтобы он слушал все IP, а не внешний IP роутера;
- открывает UFW 80/443/53;
- чинит ACME location;
- включает bind9 authoritative mode;
- перезагружает Nginx/bind9.

### 4. В панели появилась вкладка `Сеть`
Там можно:

- проверить внешний/внутренний доступ;
- сохранить публичный IP;
- починить Nginx/firewall;
- привязать домен панели;
- увидеть подсказки по пробросу портов.

### 5. DNS вкладка стала удобнее
Теперь есть кнопка автоматического создания зоны.
Панель сама создаёт:

```text
@      A      PUBLIC_IP
www    A      PUBLIC_IP
panel  A      PUBLIC_IP
ns1    A      PUBLIC_IP
ns2    A      PUBLIC_IP
mail   A      PUBLIC_IP
@      MX     10 mail
@      TXT    SPF
```

## Важная схема для домашнего сервера

```text
Ubuntu server:       192.168.0.179
Router public IP:    90.189.208.25
Domain A record:     hyper-host.pw -> 90.189.208.25
Nginx listen:        0.0.0.0:80 / 0.0.0.0:443
Router forwarding:   80/443 -> 192.168.0.179
```

Внутри Wi-Fi внешний IP может не открываться из-за отсутствия NAT Loopback. Проверяй домен с телефона через мобильный интернет.

## Быстрая настройка после установки

```bash
sudo hyper network fix hyper-host.pw 90.189.208.25
sudo hyper dns wizard hyper-host.pw 90.189.208.25 panel
sudo hyper network doctor hyper-host.pw
sudo hyper ssl check hyper-host.pw
```

Если `ssl check` готов:

```bash
sudo hyper ssl issue hyper-host.pw admin@example.com
```
