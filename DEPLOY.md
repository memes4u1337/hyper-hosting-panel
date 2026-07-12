# Deploy v80

1. Загрузи всё содержимое архива в корень ветки `main`.
2. Выполни:

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v80-all-sites-routing-final.sh
```

3. Проверь:

```bash
sudo nginx -t
sudo cat /root/hyper-host-v80-all-sites-routing-report.txt
sudo cat /opt/hyper-host/data/site-routing-plan.txt
```
