HYPER-HOST FASTDL FINAL v8

Your current error is not a broken BSP. HTTP 206 is normal for a Range request.
The real error is that the first bytes are 3c21646f = ASCII "<!do", so nginx is serving HTML instead of the BSP.

v8 stops stacking fragile edits on the old FastDL code:
- installs one isolated helper for sync/status/rebuild;
- direct panel commands fastdl-sync/fastdl-status/fastdl-rebuild use the helper;
- internal controller calls during restart/map/build use the helper too;
- removes old-zombie.ru HTTP/80 redirect blocks from other nginx configs;
- installs one canonical old-zombie.ru HTTP vhost where /fastdl/ is raw static files and everything else redirects to HTTPS;
- HTTPS vhost is left intact;
- validates source BSP version 30;
- mirrors maps/resources/WADs and checks SHA256;
- verifies nginx body bytes are 1e000000 and X-Hyper-FastDL: raw-v8;
- clean/rebuild deletes only /srv/hyper-cs16/fastdl/<id>, never the game server.

Install:
sudo bash apply-cs16-fastdl-final-v8.sh /root/hyper-hosting-panel 25
