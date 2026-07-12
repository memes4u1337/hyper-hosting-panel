# Deploy v79

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v79-site-vhost-content-fix.sh beta.mystockbot.xyz
```

Manual repair commands:

```bash
sudo hyper-host-ctl site-repair beta.mystockbot.xyz
sudo hyper-host-ctl sites-rebuild
sudo nginx -t
```
