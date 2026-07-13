# Deploy v88

1. Загрузить содержимое архива в корень ветки `main`.
2. Выполнить:

```bash
cd /tmp && sudo rm -rf hyper-host-update && git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git hyper-host-update && cd hyper-host-update && sudo bash apply-v88-nginx-clean-slate-recovery.sh beta.mystockbot.xyz
```

Резервная копия создаётся в `/opt/hyper-host/backups/v88-nginx-clean-slate-*`.
