# HYPER-HOST v82

This release rolls back only the global Nginx/site-routing changes introduced in v79-v81, using the server-side backup created before v79.

It then creates one isolated vhost for `beta.mystockbot.xyz` without rebuilding any other site.

Install:

```bash
sudo bash apply-v82-restore-old-sites-beta-only.sh beta.mystockbot.xyz
```

Report:

```bash
sudo cat /root/hyper-host-v82-restore-old-sites-beta-report.txt
```
