# Установка v81

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v81-exact-host-routing.sh
```

Проверка:

```bash
sudo nginx -t
sudo cat /opt/hyper-host/data/site-routing-exact.tsv
curl --noproxy '*' -H 'Host: beta.mystockbot.xyz' http://192.168.0.179/
curl --noproxy '*' -H 'Host: www.beta.mystockbot.xyz' http://192.168.0.179/
```
