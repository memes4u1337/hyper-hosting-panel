#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
SRC="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
CSTRIKE="/srv/hyper-cs16/servers/${SID}/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/${SID}"
NGINX="/etc/nginx/conf.d/00-hyper-cs16-fastdl-ip.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-map-fastdl-hotfix-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -f "$SRC" ]] || { echo "[ERROR] controller missing: $SRC"; exit 2; }
[[ -d "$CSTRIKE/maps" ]] || { echo "[ERROR] maps directory missing"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/hyper-cs16-ctl.repo"
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live"
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg"
[[ -f "$NGINX" ]] && cp -a "$NGINX" "$BACKUP/nginx-fastdl.conf"

echo "=============================================================="
echo " CS 1.6 MAP / FASTDL HOTFIX v1"
echo " Server #$SID"
echo "=============================================================="

echo "[1/7] Check source BSP files..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
bad=[]
ok=0
for p in sorted(root.glob('*.bsp')):
    b=p.read_bytes()[:4]
    v=int.from_bytes(b,'little') if len(b)==4 else -1
    if v==30: ok+=1
    else: bad.append((p.name,v,b.hex()))
print("valid BSP:",ok)
print("bad BSP:",len(bad))
for x in bad[:30]: print("BAD",x)
if bad: raise SystemExit(3)
PY

echo "[2/7] Install exact IP FastDL nginx route..."
cat >"$NGINX" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name 90.189.208.25;

    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        default_type application/octet-stream;
        try_files $uri =404;
        add_header X-Hyper-FastDL "1" always;
        add_header Cache-Control "public, max-age=86400" always;
    }

    location / {
        return 404;
    }
}
EOF
nginx -t
systemctl reload nginx

echo "[3/7] Patch FastDL sync so maps can never be published as HTML/broken BSP..."
PATCHER="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cwoKY3RsID0gUGF0aChzeXMuYXJndlsxXSkKCmRlZiByZXBsYWNlX2Z1bmModGV4dCwgbmFtZSwgbmV4dF9uYW1lLCBib2R5KToKICAgIHBhdCA9IHJlLmNvbXBpbGUocmYnKD9tcyleZGVmIHtyZS5lc2NhcGUobmFtZSl9XGIuKj8oPz1eZGVmIHtyZS5lc2NhcGUobmV4dF9uYW1lKX1cYiknKQogICAgbSA9IHBhdC5zZWFyY2godGV4dCkKICAgIGlmIG5vdCBtOgogICAgICAgIHJhaXNlIFN5c3RlbUV4aXQoZidbUEFUQ0ggRVJST1JdIGZ1bmN0aW9uIHJhbmdlIG5vdCBmb3VuZDoge25hbWV9IC0+IHtuZXh0X25hbWV9JykKICAgIHJldHVybiB0ZXh0WzptLnN0YXJ0KCldICsgYm9keS5yc3RyaXAoKSArICdcblxuJyArIHRleHRbbS5lbmQoKTpdCgpzID0gY3RsLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnKQoKIyBGb3JjZSBzdGFibGUgcHVibGljIEhUVFAgRmFzdERMIFVSTCBmb3IgdGhpcyBob3N0aW5nIG5vZGUuCmZhc3RkbF91cmwgPSByJycnZGVmIF9mYXN0ZGxfdXJsKGM6ZGljdCktPnN0cjoKICAgIHNpZD1pbnQoYy5nZXQoJ2lkJykgb3IgMCkKICAgIHJldHVybiBmJ2h0dHA6Ly85MC4xODkuMjA4LjI1L2Zhc3RkbC97c2lkfScKJycnCnMgPSByZXBsYWNlX2Z1bmMocywgJ19mYXN0ZGxfdXJsJywgJ19mYXN0ZGxfYXBwbHlfY2ZnJywgZmFzdGRsX3VybCkKCiMgUmVwYWlyIHNlcnZlci5jZmcgZXZlbiBpZiBpbXBvcnRlZCBhcyBvbmUgcGh5c2ljYWwgbGluZSB3aXRoIGxpdGVyYWwgIlxuIi4KYXBwbHlfY2ZnID0gcicnJ2RlZiBfZmFzdGRsX2FwcGx5X2NmZyhjOmRpY3QsIHJvb3Q6UGF0aHxOb25lPU5vbmUpLT5kaWN0OgogICAgcm9vdD1QYXRoKHJvb3Qgb3IgY1sncGF0aCddKQogICAgY2ZnPXJvb3QvJ2NzdHJpa2Uvc2VydmVyLmNmZycKICAgIGNmZy5wYXJlbnQubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCgogICAgcmF3PWNmZy5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JyxlcnJvcnM9J2lnbm9yZScpIGlmIGNmZy5leGlzdHMoKSBlbHNlICcnCiAgICByZXBhaXJlZF9lc2NhcGVkPUZhbHNlCiAgICBpZiByYXcuY291bnQoJ1xcbicpPj01IGFuZCByYXcuY291bnQoJ1xuJyk8PTI6CiAgICAgICAgcmF3PXJhdy5yZXBsYWNlKCdcXHJcXG4nLCdcbicpLnJlcGxhY2UoJ1xcbicsJ1xuJykucmVwbGFjZSgnXFxyJywnXG4nKQogICAgICAgIHJlcGFpcmVkX2VzY2FwZWQ9VHJ1ZQoKICAgIHRleHQ9cmF3LnJlcGxhY2UoJ1xyXG4nLCdcbicpLnJlcGxhY2UoJ1xyJywnXG4nKQoKICAgICMgRGVsZXRlIGV2ZXJ5IG9sZCBtYW5hZ2VkIGJsb2NrLgogICAgdGV4dD1yZS5zdWIoCiAgICAgICAgcicoP2ltcyleXHMqLy8gSFlQRVItSE9TVCBGQVNUREwgQkVHSU5ccyokLio/XlxzKi8vIEhZUEVSLUhPU1QgRkFTVERMIEVORFxzKiRcbj8nLAogICAgICAgICcnLAogICAgICAgIHRleHQKICAgICkKCiAgICAjIERlbGV0ZSBhbGwgc3RhbmRhbG9uZSB0cmFuc3BvcnQgY3ZhcnMgc28gdGhlcmUgaXMgb25seSBvbmUgZWZmZWN0aXZlIHZhbHVlLgogICAgbWFuYWdlZD17J3N2X2Rvd25sb2FkdXJsJywnc3ZfYWxsb3dkb3dubG9hZCcsJ3N2X2FsbG93dXBsb2FkJywnc3Zfc2VuZF9yZXNvdXJjZXMnLCdzdl9hbGxvd19kbGZpbGUnfQogICAga2VwdD1bXQogICAgZm9yIGxpbmUgaW4gdGV4dC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbT1yZS5tYXRjaChyJ15ccyooW0EtWmEtel9dW0EtWmEtejAtOV9dKilccysnLGxpbmUpCiAgICAgICAgaWYgbSBhbmQgbS5ncm91cCgxKS5sb3dlcigpIGluIG1hbmFnZWQ6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAga2VwdC5hcHBlbmQobGluZSkKCiAgICB1cmw9X2Zhc3RkbF91cmwoYykucnN0cmlwKCcvJykKICAgIGJsb2NrPVsKICAgICAgICAnLy8gSFlQRVItSE9TVCBGQVNUREwgQkVHSU4nLAogICAgICAgICdzdl9hbGxvd2Rvd25sb2FkIDEnLAogICAgICAgICdzdl9hbGxvd3VwbG9hZCAwJywKICAgICAgICAnc3Zfc2VuZF9yZXNvdXJjZXMgMScsCiAgICAgICAgJ3N2X2FsbG93X2RsZmlsZSAxJywKICAgICAgICBmJ3N2X2Rvd25sb2FkdXJsICJ7dXJsfSInLAogICAgICAgICcvLyBIWVBFUi1IT1NUIEZBU1RETCBFTkQnLAogICAgXQogICAgY29udGVudD0nXG4nLmpvaW4oa2VwdCkucnN0cmlwKCkrJ1xuXG4nKydcbicuam9pbihibG9jaykrJ1xuJwogICAgY2ZnLndyaXRlX3RleHQoY29udGVudCxlbmNvZGluZz0ndXRmLTgnKQoKICAgIHJldHVybiB7CiAgICAgICAgJ29rJzpUcnVlLAogICAgICAgICd1cmwnOnVybCwKICAgICAgICAnY29uZmlnJzpzdHIoY2ZnKSwKICAgICAgICAnZXNjYXBlZF9uZXdsaW5lc19yZXBhaXJlZCc6cmVwYWlyZWRfZXNjYXBlZCwKICAgICAgICAnZmFzdGRsX2Jsb2Nrcyc6MQogICAgfQonJycKcyA9IHJlcGxhY2VfZnVuYyhzLCAnX2Zhc3RkbF9hcHBseV9jZmcnLCAnX2Zhc3RkbF9jb3B5X3RyZWUnLCBhcHBseV9jZmcpCgojIENvbXBsZXRlbHkgaW5kZXBlbmRlbnQgc3luYy4gRG8gbm90IGNhbGwgb2xkIF9mYXN0ZGxfY29weV90cmVlIGF0IGFsbCwKIyBiZWNhdXNlIGxvY2FsIHBhdGNoZWQgdmVyc2lvbnMgbWF5IGhhdmUgYSBkaWZmZXJlbnQgc2lnbmF0dXJlLgpmYXN0ZGxfc3luYyA9IHInJydkZWYgZmFzdGRsX3N5bmMoc2lkOmludCwgY29uZmlndXJlOmJvb2w9VHJ1ZSk6CiAgICByZXF1aXJlX3Jvb3QoKQogICAgYz1sb2FkX3NlcnZlcihzaWQpCiAgICByb290PVBhdGgoY1sncGF0aCddKQogICAgY3N0cmlrZT1yb290Lydjc3RyaWtlJwogICAgaWYgbm90IGNzdHJpa2UuaXNfZGlyKCk6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKGYnY3N0cmlrZSBkaXJlY3RvcnkgaXMgbWlzc2luZzoge2NzdHJpa2V9JykKCiAgICBkZXN0PUZBU1RETF9ST09UL3N0cihzaWQpCiAgICBGQVNURExfUk9PVC5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKICAgIGRlc3QubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCgogICAgIyBWYWxpZGF0ZSBzb3VyY2UgQlNQIGJlZm9yZSBwdWJsaXNoaW5nLgogICAgc291cmNlX21hcHM9W10KICAgIGJhZF9zb3VyY2U9W10KICAgIG1hcHNfZGlyPWNzdHJpa2UvJ21hcHMnCiAgICBpZiBtYXBzX2Rpci5pc19kaXIoKToKICAgICAgICBmb3IgYnNwIGluIHNvcnRlZChtYXBzX2Rpci5nbG9iKCcqLmJzcCcpKToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgcmF3PWJzcC5yZWFkX2J5dGVzKClbOjRdCiAgICAgICAgICAgICAgICB2ZXJzaW9uPWludC5mcm9tX2J5dGVzKHJhdywnbGl0dGxlJyxzaWduZWQ9RmFsc2UpIGlmIGxlbihyYXcpPT00IGVsc2UgLTEKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHZlcnNpb249LTEKICAgICAgICAgICAgaWYgdmVyc2lvbiE9MzA6CiAgICAgICAgICAgICAgICBiYWRfc291cmNlLmFwcGVuZCh7J21hcCc6YnNwLm5hbWUsJ3ZlcnNpb24nOnZlcnNpb24sJ2hlYWQnOnJhdy5oZXgoKSBpZiAncmF3JyBpbiBsb2NhbHMoKSBlbHNlICcnfSkKICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgIHNvdXJjZV9tYXBzLmFwcGVuZChic3AubmFtZSkKCiAgICBpZiBiYWRfc291cmNlOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignUmVmdXNpbmcgRmFzdERMIHN5bmM6IGludmFsaWQgc291cmNlIEJTUChzKTogJytqc29uLmR1bXBzKGJhZF9zb3VyY2VbOjIwXSxlbnN1cmVfYXNjaWk9RmFsc2UpKQoKICAgICMgTWlycm9yIGFsbCBjbGllbnQtZG93bmxvYWRhYmxlIGFzc2V0cyBkaXJlY3RseSB3aXRoIHJzeW5jLgogICAgY29waWVkPVtdCiAgICBmb3IgbmFtZSBpbiBGQVNURExfRElSUzoKICAgICAgICBzcmM9Y3N0cmlrZS9uYW1lCiAgICAgICAgZHN0PWRlc3QvbmFtZQogICAgICAgIGlmIG5vdCBzcmMuaXNfZGlyKCk6CiAgICAgICAgICAgIGlmIGRzdC5leGlzdHMoKToKICAgICAgICAgICAgICAgIHNodXRpbC5ybXRyZWUoZHN0LGlnbm9yZV9lcnJvcnM9VHJ1ZSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBkc3QubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCiAgICAgICAgY3A9cnVuKAogICAgICAgICAgICBbJ3JzeW5jJywnLWEnLCctLWRlbGV0ZScsJy0tc2FmZS1saW5rcycsc3RyKHNyYykrJy8nLHN0cihkc3QpKycvJ10sCiAgICAgICAgICAgIGNoZWNrPUZhbHNlLHRpbWVvdXQ9MTIwMAogICAgICAgICkKICAgICAgICBpZiBjcC5yZXR1cm5jb2RlIT0wOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ0Zhc3RETCByc3luYyBmYWlsZWQgZm9yICcrbmFtZSsnOiAnKyhjcC5zdGRvdXQgb3IgJycpWy0yNTAwOl0pCiAgICAgICAgY29waWVkLmFwcGVuZChuYW1lKQoKICAgICMgUm9vdCBXQUQgZmlsZXMuCiAgICBzb3VyY2Vfd2Fkcz17cC5uYW1lOnAgZm9yIHAgaW4gY3N0cmlrZS5pdGVyZGlyKCkgaWYgcC5pc19maWxlKCkgYW5kIHAuc3VmZml4Lmxvd2VyKCk9PScud2FkJ30KICAgIGZvciBvbGQgaW4gZGVzdC5nbG9iKCcqLndhZCcpOgogICAgICAgIGlmIG9sZC5uYW1lIG5vdCBpbiBzb3VyY2Vfd2FkczoKICAgICAgICAgICAgdHJ5OiBvbGQudW5saW5rKCkKICAgICAgICAgICAgZXhjZXB0IE9TRXJyb3I6IHBhc3MKICAgIGZvciBuYW1lLHNyYyBpbiBzb3VyY2Vfd2Fkcy5pdGVtcygpOgogICAgICAgIHNodXRpbC5jb3B5MihzcmMsZGVzdC9uYW1lKQoKICAgICMgTmV2ZXIgcHVibGlzaCBzdGFsZSB0ZW1wb3JhcnkgY2xpZW50IGRvd25sb2Fkcy4KICAgIGZvciBmcCBpbiBsaXN0KGRlc3Qucmdsb2IoJyouenRtcCcpKToKICAgICAgICB0cnk6IGZwLnVubGluaygpCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6IHBhc3MKCiAgICAjIFZhbGlkYXRlIGRlc3RpbmF0aW9uIEJTUCBieXRlLWZvci1ieXRlIGJ5IHNpemUgKyBCU1AgdmVyc2lvbi4KICAgIGJhZF9kZXN0PVtdCiAgICBtaXNzaW5nPVtdCiAgICBmb3IgbmFtZSBpbiBzb3VyY2VfbWFwczoKICAgICAgICBzcmM9bWFwc19kaXIvbmFtZQogICAgICAgIGRzdD1kZXN0LydtYXBzJy9uYW1lCiAgICAgICAgaWYgbm90IGRzdC5pc19maWxlKCk6CiAgICAgICAgICAgIG1pc3NpbmcuYXBwZW5kKG5hbWUpCiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaGVhZD1kc3QucmVhZF9ieXRlcygpWzo0XQogICAgICAgIHZlcnNpb249aW50LmZyb21fYnl0ZXMoaGVhZCwnbGl0dGxlJyxzaWduZWQ9RmFsc2UpIGlmIGxlbihoZWFkKT09NCBlbHNlIC0xCiAgICAgICAgaWYgdmVyc2lvbiE9MzAgb3Igc3JjLnN0YXQoKS5zdF9zaXplIT1kc3Quc3RhdCgpLnN0X3NpemU6CiAgICAgICAgICAgIGJhZF9kZXN0LmFwcGVuZCh7CiAgICAgICAgICAgICAgICAnbWFwJzpuYW1lLCd2ZXJzaW9uJzp2ZXJzaW9uLAogICAgICAgICAgICAgICAgJ3NyY19zaXplJzpzcmMuc3RhdCgpLnN0X3NpemUsJ2RzdF9zaXplJzpkc3Quc3RhdCgpLnN0X3NpemUKICAgICAgICAgICAgfSkKCiAgICBpZiBtaXNzaW5nIG9yIGJhZF9kZXN0OgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigKICAgICAgICAgICAgJ0Zhc3RETCBtYXAgdmVyaWZpY2F0aW9uIGZhaWxlZDogbWlzc2luZz0nK2pzb24uZHVtcHMobWlzc2luZ1s6MjBdLGVuc3VyZV9hc2NpaT1GYWxzZSkKICAgICAgICAgICAgKycgYmFkPScranNvbi5kdW1wcyhiYWRfZGVzdFs6MjBdLGVuc3VyZV9hc2NpaT1GYWxzZSkKICAgICAgICApCgogICAgY2ZnX3Jlc3VsdD1fZmFzdGRsX2FwcGx5X2NmZyhjLHJvb3QpIGlmIGNvbmZpZ3VyZSBlbHNlIHsndXJsJzpfZmFzdGRsX3VybChjKX0KICAgIHVybD1zdHIoY2ZnX3Jlc3VsdC5nZXQoJ3VybCcpIG9yIF9mYXN0ZGxfdXJsKGMpKS5yc3RyaXAoJy8nKQoKICAgIHJ1bihbJ2Nob3duJywnLVInLCdyb290Ond3dy1kYXRhJyxzdHIoZGVzdCldLGNoZWNrPUZhbHNlKQogICAgcnVuKFsnZmluZCcsc3RyKGRlc3QpLCctdHlwZScsJ2QnLCctZXhlYycsJ2NobW9kJywnMDc1NScsJ3t9JywnKyddLGNoZWNrPUZhbHNlKQogICAgcnVuKFsnZmluZCcsc3RyKGRlc3QpLCctdHlwZScsJ2YnLCctZXhlYycsJ2NobW9kJywnMDY0NCcsJ3t9JywnKyddLGNoZWNrPUZhbHNlKQoKICAgICMgSFRUUC10ZXN0IGV2ZXJ5IEJTUCBsb2NhbGx5IHRocm91Z2ggdGhlIGV4YWN0IHB1YmxpYy1JUCB2aG9zdC4KICAgIGh0dHBfYmFkPVtdCiAgICBmb3IgbmFtZSBpbiBzb3VyY2VfbWFwczoKICAgICAgICB0ZXN0X3VybD1mJ2h0dHA6Ly8xMjcuMC4wLjEvZmFzdGRsL3tzaWR9L21hcHMve3VybGxpYi5wYXJzZS5xdW90ZShuYW1lKX0nCiAgICAgICAgdG1wPVBhdGgodGVtcGZpbGUuZ2V0dGVtcGRpcigpKS9mJ2hoLWZhc3RkbC17c2lkfS17b3MuZ2V0cGlkKCl9LnByb2JlJwogICAgICAgIHRyeToKICAgICAgICAgICAgY3A9cnVuKAogICAgICAgICAgICAgICAgWydjdXJsJywnLXNTJywnLS1jb25uZWN0LXRpbWVvdXQnLCcyJywnLS1tYXgtdGltZScsJzE1JywKICAgICAgICAgICAgICAgICAnLUgnLCdIb3N0OiA5MC4xODkuMjA4LjI1JywnLW8nLHN0cih0bXApLCctdycsJyV7aHR0cF9jb2RlfScsdGVzdF91cmxdLAogICAgICAgICAgICAgICAgY2hlY2s9RmFsc2UsdGltZW91dD0yMAogICAgICAgICAgICApCiAgICAgICAgICAgIGNvZGU9KGNwLnN0ZG91dCBvciAnJykuc3RyaXAoKVstMzpdCiAgICAgICAgICAgIGhlYWQ9dG1wLnJlYWRfYnl0ZXMoKVs6NF0gaWYgdG1wLmlzX2ZpbGUoKSBlbHNlIGInJwogICAgICAgICAgICB2ZXJzaW9uPWludC5mcm9tX2J5dGVzKGhlYWQsJ2xpdHRsZScsc2lnbmVkPUZhbHNlKSBpZiBsZW4oaGVhZCk9PTQgZWxzZSAtMQogICAgICAgICAgICBpZiBjb2RlIT0nMjAwJyBvciB2ZXJzaW9uIT0zMDoKICAgICAgICAgICAgICAgIGh0dHBfYmFkLmFwcGVuZCh7CiAgICAgICAgICAgICAgICAgICAgJ21hcCc6bmFtZSwnaHR0cCc6Y29kZSwndmVyc2lvbic6dmVyc2lvbiwnaGVhZCc6aGVhZC5oZXgoKSwKICAgICAgICAgICAgICAgIH0pCiAgICAgICAgZmluYWxseToKICAgICAgICAgICAgdHJ5OiB0bXAudW5saW5rKCkKICAgICAgICAgICAgZXhjZXB0IE9TRXJyb3I6IHBhc3MKCiAgICBpZiBodHRwX2JhZDoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoCiAgICAgICAgICAgICdGYXN0REwgSFRUUCBpcyBzZXJ2aW5nIG5vbi1CU1AgZGF0YTogJytqc29uLmR1bXBzKGh0dHBfYmFkWzoyMF0sZW5zdXJlX2FzY2lpPUZhbHNlKQogICAgICAgICkKCiAgICBmaWxlcz0wCiAgICB0b3RhbD0wCiAgICBmb3IgZnAgaW4gZGVzdC5yZ2xvYignKicpOgogICAgICAgIHRyeToKICAgICAgICAgICAgaWYgZnAuaXNfZmlsZSgpOgogICAgICAgICAgICAgICAgZmlsZXMrPTEKICAgICAgICAgICAgICAgIHRvdGFsKz1mcC5zdGF0KCkuc3Rfc2l6ZQogICAgICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgICAgICBwYXNzCgogICAgY1snZmFzdGRsX3VybCddPXVybAogICAgY1snZmFzdGRsX2xhc3Rfc3luYyddPWludCh0aW1lLnRpbWUoKSkKICAgIGNbJ2Zhc3RkbF9maWxlcyddPWZpbGVzCiAgICBjWydmYXN0ZGxfYnl0ZXMnXT10b3RhbAogICAgc2F2ZV9zZXJ2ZXIoYykKCiAgICBydW50aW1lX2Vycm9ycz1bXQogICAgaWYgc2VydmljZV9zdGF0dXMoc2lkKT09J2FjdGl2ZScgYW5kIHVkcF9saXN0ZW5pbmcoaW50KGMuZ2V0KCdwb3J0Jykgb3IgMCkpOgogICAgICAgIGZvciBjbWQgaW4gWwogICAgICAgICAgICAnc3ZfYWxsb3dkb3dubG9hZCAxJywKICAgICAgICAgICAgJ3N2X2FsbG93dXBsb2FkIDAnLAogICAgICAgICAgICAnc3Zfc2VuZF9yZXNvdXJjZXMgMScsCiAgICAgICAgICAgICdzdl9hbGxvd19kbGZpbGUgMScsCiAgICAgICAgICAgIGYnc3ZfZG93bmxvYWR1cmwgInt1cmx9IicKICAgICAgICBdOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBxdWVyeV9yY29uKCcxMjcuMC4wLjEnLGludChjWydwb3J0J10pLHN0cihjLmdldCgncmNvbl9wYXNzd29yZCcsJycpKSxjbWQsMi4wKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzoKICAgICAgICAgICAgICAgIHJ1bnRpbWVfZXJyb3JzLmFwcGVuZChzdHIoZXhjKSkKCiAgICByZXR1cm4gewogICAgICAgICdvayc6VHJ1ZSwKICAgICAgICAnaWQnOnNpZCwKICAgICAgICAndXJsJzp1cmwsCiAgICAgICAgJ3Jvb3QnOnN0cihkZXN0KSwKICAgICAgICAnZmlsZXMnOmZpbGVzLAogICAgICAgICdieXRlcyc6dG90YWwsCiAgICAgICAgJ21hcHMnOmxlbihzb3VyY2VfbWFwcyksCiAgICAgICAgJ2RpcnMnOmNvcGllZCwKICAgICAgICAnY29uZmlnJzpjZmdfcmVzdWx0LAogICAgICAgICdodHRwX21hcHNfdmVyaWZpZWQnOmxlbihzb3VyY2VfbWFwcyksCiAgICAgICAgJ3J1bnRpbWVfZXJyb3JzJzpydW50aW1lX2Vycm9yc1s6NV0KICAgIH0KJycnCnMgPSByZXBsYWNlX2Z1bmMocywgJ2Zhc3RkbF9zeW5jJywgJ2Zhc3RkbF9zdGF0dXMnLCBmYXN0ZGxfc3luYykKCmN0bC53cml0ZV90ZXh0KHMsZW5jb2Rpbmc9J3V0Zi04JykK' | base64 -d >"$PATCHER"
python3 "$PATCHER" "$SRC"
python3 -m py_compile "$SRC"
install -m 0755 "$SRC" "$LIVE"
python3 -m py_compile "$LIVE"
rm -f "$PATCHER"

echo "[4/7] Clean FastDL map copy..."
rm -rf "$FASTDL/maps"
mkdir -p "$FASTDL/maps"
rsync -a --delete "$CSTRIKE/maps/" "$FASTDL/maps/"
chown -R root:www-data "$FASTDL"
find "$FASTDL" -type d -exec chmod 0755 {} +
find "$FASTDL" -type f -exec chmod 0644 {} +

echo "[5/7] Full panel FastDL sync + verification..."
"$LIVE" fastdl-sync "$SID"

echo "[6/7] Restart server..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

echo "[7/7] Verify zm_303 specifically..."
SRCMAP="$CSTRIKE/maps/zm_303.bsp"
FDMAP="$FASTDL/maps/zm_303.bsp"

for f in "$SRCMAP" "$FDMAP"; do
  if [[ -f "$f" ]]; then
    echo "$f"
    od -An -tu4 -N4 "$f" | tr -d ' '
    ls -lh "$f"
  fi
done

if [[ -f "$FDMAP" ]]; then
  rm -f /tmp/zm_303.fastdl.test
  CODE="$(curl -sS --connect-timeout 3 --max-time 15 -H 'Host: 90.189.208.25'     -o /tmp/zm_303.fastdl.test -w '%{http_code}'     'http://127.0.0.1/fastdl/25/maps/zm_303.bsp' || true)"
  echo "HTTP code: $CODE"
  echo -n "Downloaded BSP version: "
  od -An -tu4 -N4 /tmp/zm_303.fastdl.test | tr -d ' '
  echo
  echo -n "Downloaded first 4 bytes: "
  od -An -tx1 -N4 /tmp/zm_303.fastdl.test | tr -s ' '
  rm -f /tmp/zm_303.fastdl.test
fi

"$LIVE" rcon "$SID" "sv_downloadurl" || true

echo
echo "=============================================================="
echo " [SUCCESS] MAP / FASTDL HOTFIX v1"
echo "=============================================================="
echo "Expected BSP version: 30"
echo "Expected first bytes: 1e 00 00 00"
echo "Expected HTTP: 200"
echo "FastDL URL: http://90.189.208.25/fastdl/$SID"
echo "Backup: $BACKUP"
