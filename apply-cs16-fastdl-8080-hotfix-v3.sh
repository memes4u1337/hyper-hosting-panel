#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
PUBLIC_IP="90.189.208.25"
LAN_IP="192.168.0.179"
PORT="8080"

SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
NGINX_CONF="/etc/nginx/conf.d/00-hyper-cs16-fastdl-8080.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-8080-hotfix-v3-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -f "$SRC_CTL" ]] || { echo "[ERROR] missing $SRC_CTL"; exit 2; }
[[ -d "$CSTRIKE" ]] || { echo "[ERROR] missing $CSTRIKE"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.repo"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live"
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg"
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/nginx-8080.conf"

echo "=============================================================="
echo " HYPER-HOST FASTDL 8080 HOTFIX v3"
echo " Server: #$SID"
echo " URL:    http://$PUBLIC_IP:$PORT/fastdl/$SID/"
echo " Backup: $BACKUP"
echo "=============================================================="

echo "[1/9] Validate source BSP..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
good=[]; bad=[]
for p in sorted(root.glob('*.bsp')):
    with p.open('rb') as fh:
        b=fh.read(4)
    v=int.from_bytes(b,'little') if len(b)==4 else None
    (good if v==30 else bad).append((p.name,v,b.hex()))
print("valid BSP:",len(good))
print("bad BSP:",len(bad))
if bad:
    print(*bad[:20],sep='\n')
    raise SystemExit(10)
PY

echo "[2/9] Install dedicated nginx FastDL on TCP $PORT..."
cat >"$NGINX_CONF" <<EOF
server {
    listen $PORT default_server;
    listen [::]:$PORT default_server;
    server_name _;

    access_log /var/log/nginx/hyper-cs16-fastdl-8080-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-8080-error.log warn;

    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        default_type application/octet-stream;
        add_header Cache-Control "public, max-age=86400" always;
        add_header X-Hyper-FastDL "8080" always;
    }

    location / {
        return 404;
    }
}
EOF
nginx -t
systemctl reload nginx

echo "[3/9] Firewall..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
fi

echo "[4/9] Patch panel URL/sync/status..."
PATCHER="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cwoKY3RsID0gUGF0aChzeXMuYXJndlsxXSkKcyA9IGN0bC5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JykKCk1BUktfQkVHSU4gPSAiIyBIWVBFUi1IT1NUIEZBU1RETCA4MDgwIE9WRVJSSURFIEJFR0lOIgpNQVJLX0VORCAgID0gIiMgSFlQRVItSE9TVCBGQVNUREwgODA4MCBPVkVSUklERSBFTkQiCgpvdmVycmlkZSA9ICIiIgojIEhZUEVSLUhPU1QgRkFTVERMIDgwODAgT1ZFUlJJREUgQkVHSU4KZGVmIF9mYXN0ZGxfdXJsKGM6ZGljdCktPnN0cjoKICAgIHNpZD1pbnQoYy5nZXQoJ2lkJykgb3IgMCkKICAgIHJldHVybiBmJ2h0dHA6Ly85MC4xODkuMjA4LjI1OjgwODAvZmFzdGRsL3tzaWR9JwoKCmRlZiBfaGhfZmFzdGRsX2NmZ184MDgwKGM6ZGljdCwgcm9vdDpQYXRoKS0+ZGljdDoKICAgIGNmZz1yb290Lydjc3RyaWtlL3NlcnZlci5jZmcnCiAgICBjZmcucGFyZW50Lm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlKQogICAgcmF3PWNmZy5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JyxlcnJvcnM9J2lnbm9yZScpIGlmIGNmZy5leGlzdHMoKSBlbHNlICcnCgogICAgaWYgcmF3LmNvdW50KCdcXFxcbicpPj01IGFuZCByYXcuY291bnQoJ1xcbicpPD0yOgogICAgICAgIHJhdz1yYXcucmVwbGFjZSgnXFxcXHJcXFxcbicsJ1xcbicpLnJlcGxhY2UoJ1xcXFxuJywnXFxuJykucmVwbGFjZSgnXFxcXHInLCdcXG4nKQoKICAgIHRleHQ9cmF3LnJlcGxhY2UoJ1xcclxcbicsJ1xcbicpLnJlcGxhY2UoJ1xccicsJ1xcbicpCiAgICB0ZXh0PXJlLnN1YigKICAgICAgICByJyg/aW1zKV5cXHMqLy8gSFlQRVItSE9TVCBGQVNUREwgQkVHSU5cXHMqJC4qP15cXHMqLy8gSFlQRVItSE9TVCBGQVNUREwgRU5EXFxzKiRcXG4/JywKICAgICAgICAnJywKICAgICAgICB0ZXh0CiAgICApCgogICAgbWFuYWdlZD17J3N2X2Rvd25sb2FkdXJsJywnc3ZfYWxsb3dkb3dubG9hZCcsJ3N2X2FsbG93dXBsb2FkJywnc3Zfc2VuZF9yZXNvdXJjZXMnLCdzdl9hbGxvd19kbGZpbGUnfQogICAga2VwdD1bXQogICAgZm9yIGxpbmUgaW4gdGV4dC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbT1yZS5tYXRjaChyJ15cXHMqKFtBLVphLXpfXVtBLVphLXowLTlfXSopXFxzKycsbGluZSkKICAgICAgICBpZiBtIGFuZCBtLmdyb3VwKDEpLmxvd2VyKCkgaW4gbWFuYWdlZDoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBrZXB0LmFwcGVuZChsaW5lKQoKICAgIHVybD1fZmFzdGRsX3VybChjKS5yc3RyaXAoJy8nKSsnLycKICAgIGJsb2NrPVsKICAgICAgICAnLy8gSFlQRVItSE9TVCBGQVNUREwgQkVHSU4nLAogICAgICAgICcvLyBEZWRpY2F0ZWQgRmFzdERMIG9uIFRDUCA4MDgwLicsCiAgICAgICAgJ3N2X2FsbG93ZG93bmxvYWQgMScsCiAgICAgICAgJ3N2X2FsbG93dXBsb2FkIDAnLAogICAgICAgICdzdl9zZW5kX3Jlc291cmNlcyAxJywKICAgICAgICAnc3ZfYWxsb3dfZGxmaWxlIDEnLAogICAgICAgIGYnc3ZfZG93bmxvYWR1cmwgInt1cmx9IicsCiAgICAgICAgJy8vIEhZUEVSLUhPU1QgRkFTVERMIEVORCcsCiAgICBdCiAgICBjb250ZW50PSdcXG4nLmpvaW4oa2VwdCkucnN0cmlwKCkrJ1xcblxcbicrJ1xcbicuam9pbihibG9jaykrJ1xcbicKICAgIGNmZy53cml0ZV90ZXh0KGNvbnRlbnQsZW5jb2Rpbmc9J3V0Zi04JykKICAgIHJldHVybiB7J29rJzpUcnVlLCd1cmwnOnVybC5yc3RyaXAoJy8nKSwnY29uZmlnJzpzdHIoY2ZnKX0KCgpkZWYgX2hoX2Zhc3RkbF92YWxpZGF0ZV9ic3BfZmlsZShwYXRoOlBhdGgpLT5kaWN0OgogICAgdHJ5OgogICAgICAgIHdpdGggcGF0aC5vcGVuKCdyYicpIGFzIGZoOgogICAgICAgICAgICBoZWFkPWZoLnJlYWQoNCkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOgogICAgICAgIHJldHVybiB7J29rJzpGYWxzZSwnZXJyb3InOnN0cihleGMpLCd2ZXJzaW9uJzpOb25lLCdoZWFkJzonJ30KICAgIGlmIGxlbihoZWFkKSE9NDoKICAgICAgICByZXR1cm4geydvayc6RmFsc2UsJ2Vycm9yJzonc2hvcnQgZmlsZScsJ3ZlcnNpb24nOk5vbmUsJ2hlYWQnOmhlYWQuaGV4KCl9CiAgICB2ZXJzaW9uPWludC5mcm9tX2J5dGVzKGhlYWQsJ2xpdHRsZScsc2lnbmVkPUZhbHNlKQogICAgcmV0dXJuIHsnb2snOnZlcnNpb249PTMwLCd2ZXJzaW9uJzp2ZXJzaW9uLCdoZWFkJzpoZWFkLmhleCgpfQoKCmRlZiBfaGhfZmFzdGRsX2h0dHBfcHJvYmVfODA4MChzaWQ6aW50LCByZWw6c3RyKS0+ZGljdDoKICAgIHJlbD1zdHIocmVsKS5yZXBsYWNlKCdcXFxcJywnLycpLmxzdHJpcCgnLycpCiAgICB1cmw9J2h0dHA6Ly8xMjcuMC4wLjE6ODA4MC9mYXN0ZGwvJytzdHIoaW50KHNpZCkpKycvJyt1cmxsaWIucGFyc2UucXVvdGUocmVsLHNhZmU9Jy8uXy0rKClbXScpCiAgICByZXE9dXJsbGliLnJlcXVlc3QuUmVxdWVzdCh1cmwsaGVhZGVycz17J0hvc3QnOic5MC4xODkuMjA4LjI1J30pCiAgICB0cnk6CiAgICAgICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJlcSx0aW1lb3V0PTYpIGFzIHI6CiAgICAgICAgICAgIGRhdGE9ci5yZWFkKDQpCiAgICAgICAgICAgIGNvZGU9aW50KGdldGF0dHIociwnc3RhdHVzJywyMDApIG9yIDIwMCkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOgogICAgICAgIHJldHVybiB7J29rJzpGYWxzZSwnaHR0cCc6MCwndXJsJzp1cmwsJ2Vycm9yJzpzdHIoZXhjKSwnaGVhZCc6JycsJ3ZlcnNpb24nOk5vbmV9CiAgICB2ZXJzaW9uPWludC5mcm9tX2J5dGVzKGRhdGEsJ2xpdHRsZScsc2lnbmVkPUZhbHNlKSBpZiBsZW4oZGF0YSk9PTQgZWxzZSBOb25lCiAgICByZXR1cm4gewogICAgICAgICdvayc6Y29kZT09MjAwIGFuZCB2ZXJzaW9uPT0zMCwKICAgICAgICAnaHR0cCc6Y29kZSwndXJsJzp1cmwsJ2hlYWQnOmRhdGEuaGV4KCksJ3ZlcnNpb24nOnZlcnNpb24KICAgIH0KIyBIWVBFUi1IT1NUIEZBU1RETCA4MDgwIE9WRVJSSURFIEVORAoiIiIKCmlmIE1BUktfQkVHSU4gaW4gcyBhbmQgTUFSS19FTkQgaW4gczoKICAgIHM9cmUuc3ViKAogICAgICAgIHInKD9tcyleIyBIWVBFUi1IT1NUIEZBU1RETCA4MDgwIE9WRVJSSURFIEJFR0lOXHMqJC4qP14jIEhZUEVSLUhPU1QgRkFTVERMIDgwODAgT1ZFUlJJREUgRU5EXHMqJFxuPycsCiAgICAgICAgJycsCiAgICAgICAgcwogICAgKQoKbT1yZS5zZWFyY2gocicoP20pXmRlZiBtYWluXChcKTpccyokJyxzKQppZiBub3QgbToKICAgIHJhaXNlIFN5c3RlbUV4aXQoJ1tQQVRDSCBFUlJPUl0gZGVmIG1haW4oKSBub3QgZm91bmQnKQpzPXNbOm0uc3RhcnQoKV0rb3ZlcnJpZGUucnN0cmlwKCkrJ1xuXG4nK3NbbS5zdGFydCgpOl0KCnN5bmNfYm9keSA9ICIiIgpkZWYgZmFzdGRsX3N5bmMoc2lkOmludCwgY29uZmlndXJlOmJvb2w9VHJ1ZSk6CiAgICByZXF1aXJlX3Jvb3QoKQogICAgYz1sb2FkX3NlcnZlcihzaWQpCiAgICByb290PVBhdGgoY1sncGF0aCddKQogICAgY3N0cmlrZT1yb290Lydjc3RyaWtlJwogICAgaWYgbm90IGNzdHJpa2UuaXNfZGlyKCk6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKGYnY3N0cmlrZSBkaXJlY3RvcnkgaXMgbWlzc2luZzoge2NzdHJpa2V9JykKCiAgICBkZXN0PUZBU1RETF9ST09UL3N0cihpbnQoc2lkKSkKICAgIEZBU1RETF9ST09ULm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlKQogICAgZGVzdC5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKCiAgICBiYWRfc291cmNlPVtdCiAgICBzb3VyY2VfbWFwcz1zb3J0ZWQoKGNzdHJpa2UvJ21hcHMnKS5nbG9iKCcqLmJzcCcpKSBpZiAoY3N0cmlrZS8nbWFwcycpLmlzX2RpcigpIGVsc2UgW10KICAgIGZvciBmcCBpbiBzb3VyY2VfbWFwczoKICAgICAgICB2PV9oaF9mYXN0ZGxfdmFsaWRhdGVfYnNwX2ZpbGUoZnApCiAgICAgICAgaWYgbm90IHZbJ29rJ106CiAgICAgICAgICAgIGJhZF9zb3VyY2UuYXBwZW5kKHsnbWFwJzpmcC5uYW1lLCoqdn0pCiAgICBpZiBiYWRfc291cmNlOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignU291cmNlIEJTUCB2YWxpZGF0aW9uIGZhaWxlZDogJytqc29uLmR1bXBzKGJhZF9zb3VyY2VbOjI1XSxlbnN1cmVfYXNjaWk9RmFsc2UpKQoKICAgIGNvcGllZF9kaXJzPVtdCiAgICBmb3IgbmFtZSBpbiBGQVNURExfRElSUzoKICAgICAgICBzcmM9Y3N0cmlrZS9uYW1lCiAgICAgICAgZHN0PWRlc3QvbmFtZQogICAgICAgIGlmIG5vdCBzcmMuaXNfZGlyKCk6CiAgICAgICAgICAgIGlmIGRzdC5leGlzdHMoKToKICAgICAgICAgICAgICAgIHNodXRpbC5ybXRyZWUoZHN0LGlnbm9yZV9lcnJvcnM9VHJ1ZSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBkc3QubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCiAgICAgICAgY3A9cnVuKAogICAgICAgICAgICBbJ3JzeW5jJywnLWEnLCctLWRlbGV0ZScsJy0tc2FmZS1saW5rcycsc3RyKHNyYykrJy8nLHN0cihkc3QpKycvJ10sCiAgICAgICAgICAgIGNoZWNrPUZhbHNlLHRpbWVvdXQ9MTIwMAogICAgICAgICkKICAgICAgICBpZiBjcC5yZXR1cm5jb2RlIT0wOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ0Zhc3RETCByc3luYyBmYWlsZWQgZm9yICcrc3RyKHNyYykrJzogJysoY3Auc3Rkb3V0IG9yICcnKVstMjUwMDpdKQogICAgICAgIGNvcGllZF9kaXJzLmFwcGVuZChuYW1lKQoKICAgIHNvdXJjZV93YWRzPXtwLm5hbWU6cCBmb3IgcCBpbiBjc3RyaWtlLml0ZXJkaXIoKSBpZiBwLmlzX2ZpbGUoKSBhbmQgcC5zdWZmaXgubG93ZXIoKT09Jy53YWQnfQogICAgZm9yIG9sZCBpbiBkZXN0Lmdsb2IoJyoud2FkJyk6CiAgICAgICAgaWYgb2xkLm5hbWUgbm90IGluIHNvdXJjZV93YWRzOgogICAgICAgICAgICB0cnk6IG9sZC51bmxpbmsoKQogICAgICAgICAgICBleGNlcHQgT1NFcnJvcjogcGFzcwogICAgZm9yIG5hbWUsc3JjIGluIHNvdXJjZV93YWRzLml0ZW1zKCk6CiAgICAgICAgc2h1dGlsLmNvcHkyKHNyYyxkZXN0L25hbWUpCgogICAgZm9yIGZwIGluIGxpc3QoZGVzdC5yZ2xvYignKi56dG1wJykpOgogICAgICAgIHRyeTogZnAudW5saW5rKCkKICAgICAgICBleGNlcHQgT1NFcnJvcjogcGFzcwoKICAgIGNmZ19yZXN1bHQ9X2hoX2Zhc3RkbF9jZmdfODA4MChjLHJvb3QpIGlmIGNvbmZpZ3VyZSBlbHNlIHsndXJsJzpfZmFzdGRsX3VybChjKX0KCiAgICBydW4oWydjaG93bicsJy1SJywncm9vdDp3d3ctZGF0YScsc3RyKGRlc3QpXSxjaGVjaz1GYWxzZSkKICAgIHJ1bihbJ2ZpbmQnLHN0cihkZXN0KSwnLXR5cGUnLCdkJywnLWV4ZWMnLCdjaG1vZCcsJzA3NTUnLCd7fScsJysnXSxjaGVjaz1GYWxzZSkKICAgIHJ1bihbJ2ZpbmQnLHN0cihkZXN0KSwnLXR5cGUnLCdmJywnLWV4ZWMnLCdjaG1vZCcsJzA2NDQnLCd7fScsJysnXSxjaGVjaz1GYWxzZSkKCiAgICBiYWRfY29weT1bXQogICAgYmFkX2h0dHA9W10KICAgIGZvciBzcmMgaW4gc291cmNlX21hcHM6CiAgICAgICAgZnA9ZGVzdC8nbWFwcycvc3JjLm5hbWUKICAgICAgICBpZiBub3QgZnAuaXNfZmlsZSgpOgogICAgICAgICAgICBiYWRfY29weS5hcHBlbmQoeydtYXAnOnNyYy5uYW1lLCdlcnJvcic6J21pc3NpbmcgZnJvbSBGYXN0REwnfSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICB2PV9oaF9mYXN0ZGxfdmFsaWRhdGVfYnNwX2ZpbGUoZnApCiAgICAgICAgaWYgbm90IHZbJ29rJ106CiAgICAgICAgICAgIGJhZF9jb3B5LmFwcGVuZCh7J21hcCc6c3JjLm5hbWUsKip2fSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBoPV9oaF9mYXN0ZGxfaHR0cF9wcm9iZV84MDgwKHNpZCwnbWFwcy8nK3NyYy5uYW1lKQogICAgICAgIGlmIG5vdCBoWydvayddOgogICAgICAgICAgICBiYWRfaHR0cC5hcHBlbmQoeydtYXAnOnNyYy5uYW1lLCoqaH0pCgogICAgaWYgYmFkX2NvcHk6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdGYXN0REwgQlNQIGNvcHkgdmFsaWRhdGlvbiBmYWlsZWQ6ICcranNvbi5kdW1wcyhiYWRfY29weVs6MjVdLGVuc3VyZV9hc2NpaT1GYWxzZSkpCiAgICBpZiBiYWRfaHR0cDoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ0Zhc3RETCBuZ2lueCA4MDgwIGlzIG5vdCBzZXJ2aW5nIHJhdyBCU1AgYnl0ZXM6ICcranNvbi5kdW1wcyhiYWRfaHR0cFs6MjVdLGVuc3VyZV9hc2NpaT1GYWxzZSkpCgogICAgZmlsZXM9MAogICAgdG90YWw9MAogICAgZm9yIGZwIGluIGRlc3Qucmdsb2IoJyonKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGlmIGZwLmlzX2ZpbGUoKToKICAgICAgICAgICAgICAgIGZpbGVzKz0xCiAgICAgICAgICAgICAgICB0b3RhbCs9ZnAuc3RhdCgpLnN0X3NpemUKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcGFzcwoKICAgIGNbJ2Zhc3RkbF91cmwnXT1fZmFzdGRsX3VybChjKQogICAgY1snZmFzdGRsX2xhc3Rfc3luYyddPWludCh0aW1lLnRpbWUoKSkKICAgIGNbJ2Zhc3RkbF9maWxlcyddPWZpbGVzCiAgICBjWydmYXN0ZGxfYnl0ZXMnXT10b3RhbAogICAgc2F2ZV9zZXJ2ZXIoYykKCiAgICBydW50aW1lX2Vycm9ycz1bXQogICAgaWYgc2VydmljZV9zdGF0dXMoc2lkKT09J2FjdGl2ZScgYW5kIHVkcF9saXN0ZW5pbmcoaW50KGMuZ2V0KCdwb3J0Jykgb3IgMCkpOgogICAgICAgIGZvciBjbWQgaW4gWwogICAgICAgICAgICAnc3ZfYWxsb3dkb3dubG9hZCAxJywKICAgICAgICAgICAgJ3N2X2FsbG93dXBsb2FkIDAnLAogICAgICAgICAgICAnc3Zfc2VuZF9yZXNvdXJjZXMgMScsCiAgICAgICAgICAgICdzdl9hbGxvd19kbGZpbGUgMScsCiAgICAgICAgICAgIGYnc3ZfZG93bmxvYWR1cmwgIntjWyJmYXN0ZGxfdXJsIl19LyInCiAgICAgICAgXToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgcXVlcnlfcmNvbignMTI3LjAuMC4xJyxpbnQoY1sncG9ydCddKSxzdHIoYy5nZXQoJ3Jjb25fcGFzc3dvcmQnLCcnKSksY21kLDIuMCkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgICAgICAgICBydW50aW1lX2Vycm9ycy5hcHBlbmQoc3RyKGV4YykpCgogICAgcmV0dXJuIHsKICAgICAgICAnb2snOlRydWUsJ2lkJzpzaWQsJ3VybCc6Y1snZmFzdGRsX3VybCddLCdyb290JzpzdHIoZGVzdCksCiAgICAgICAgJ2ZpbGVzJzpmaWxlcywnYnl0ZXMnOnRvdGFsLCdtYXBzJzpsZW4oc291cmNlX21hcHMpLAogICAgICAgICdkaXJzJzpjb3BpZWRfZGlycywnY29uZmlnJzpjZmdfcmVzdWx0LAogICAgICAgICdic3BfY29weV9vayc6VHJ1ZSwnaHR0cF84MDgwX29rJzpUcnVlLAogICAgICAgICdydW50aW1lX2FwcGxpZWQnOm5vdCBydW50aW1lX2Vycm9ycywKICAgICAgICAncnVudGltZV9lcnJvcnMnOnJ1bnRpbWVfZXJyb3JzWzo1XQogICAgfQoiIiIKCnBhdD1yZS5jb21waWxlKHInKD9tcyleZGVmIGZhc3RkbF9zeW5jXGIuKj8oPz1eZGVmIGZhc3RkbF9zdGF0dXNcYiknKQptPXBhdC5zZWFyY2gocykKaWYgbm90IG06CiAgICByYWlzZSBTeXN0ZW1FeGl0KCdbUEFUQ0ggRVJST1JdIGZhc3RkbF9zeW5jIC0+IGZhc3RkbF9zdGF0dXMgcmFuZ2Ugbm90IGZvdW5kJykKcz1zWzptLnN0YXJ0KCldK3N5bmNfYm9keS5zdHJpcCgpKydcblxuJytzW20uZW5kKCk6XQoKc3RhdHVzX2JvZHkgPSAiIiIKZGVmIGZhc3RkbF9zdGF0dXMoc2lkOmludCk6CiAgICBjPWxvYWRfc2VydmVyKHNpZCkKICAgIHJvb3Q9UGF0aChjWydwYXRoJ10pCiAgICBkZXN0PUZBU1RETF9ST09UL3N0cihpbnQoc2lkKSkKICAgIGNmZz1yb290Lydjc3RyaWtlL3NlcnZlci5jZmcnCiAgICB1cmw9X2Zhc3RkbF91cmwoYykKCiAgICBmaWxlcz0wCiAgICB0b3RhbD0wCiAgICBtYXBzPVtdCiAgICBpZiBkZXN0LmlzX2RpcigpOgogICAgICAgIGZvciBmcCBpbiBkZXN0LnJnbG9iKCcqJyk6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIGlmIGZwLmlzX2ZpbGUoKToKICAgICAgICAgICAgICAgICAgICBmaWxlcys9MQogICAgICAgICAgICAgICAgICAgIHRvdGFsKz1mcC5zdGF0KCkuc3Rfc2l6ZQogICAgICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgICAgIHBhc3MKICAgICAgICBtYXBzPXNvcnRlZCgoZGVzdC8nbWFwcycpLmdsb2IoJyouYnNwJykpIGlmIChkZXN0LydtYXBzJykuaXNfZGlyKCkgZWxzZSBbXQoKICAgIGN1cnJlbnQ9JycKICAgIGJsb2Nrcz0wCiAgICBpZiBjZmcuaXNfZmlsZSgpOgogICAgICAgIHRleHQ9Y2ZnLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnLGVycm9ycz0naWdub3JlJykKICAgICAgICB2YWxzPXJlLmZpbmRhbGwocicoP2ltKV5cXHMqc3ZfZG93bmxvYWR1cmxcXHMrIj8oW14iXFxyXFxuXSspJyx0ZXh0KQogICAgICAgIGlmIHZhbHM6IGN1cnJlbnQ9dmFsc1stMV0uc3RyaXAoKS5yc3RyaXAoJy8nKQogICAgICAgIGJsb2Nrcz1sZW4ocmUuZmluZGFsbChyJyg/aW0pXlxccyovLyBIWVBFUi1IT1NUIEZBU1RETCBCRUdJTlxccyokJyx0ZXh0KSkKCiAgICBwcm9iZT17J29rJzpGYWxzZSwnaHR0cCc6MCwndmVyc2lvbic6Tm9uZSwnaGVhZCc6Jyd9CiAgICBpZiBtYXBzOgogICAgICAgIHByb2JlPV9oaF9mYXN0ZGxfaHR0cF9wcm9iZV84MDgwKHNpZCwnbWFwcy8nK21hcHNbMF0ubmFtZSkKCiAgICBjb25maWd1cmVkPWJvb2woCiAgICAgICAgZGVzdC5pc19kaXIoKQogICAgICAgIGFuZCBjdXJyZW50LnJzdHJpcCgnLycpPT11cmwucnN0cmlwKCcvJykKICAgICAgICBhbmQgYmxvY2tzPT0xCiAgICAgICAgYW5kIHByb2JlLmdldCgnb2snKQogICAgKQogICAgcmV0dXJuIHsKICAgICAgICAnb2snOlRydWUsJ2lkJzpzaWQsJ3VybCc6dXJsLCdjb25maWd1cmVkX3VybCc6Y3VycmVudCwKICAgICAgICAnY29uZmlndXJlZCc6Y29uZmlndXJlZCwncm9vdCc6c3RyKGRlc3QpLCdleGlzdHMnOmRlc3QuaXNfZGlyKCksCiAgICAgICAgJ2ZpbGVzJzpmaWxlcywnYnl0ZXMnOnRvdGFsLCdtYXBzJzpsZW4obWFwcyksCiAgICAgICAgJ2h0dHBfb2snOmJvb2wocHJvYmUuZ2V0KCdvaycpKSwnaHR0cF9jb2RlJzppbnQocHJvYmUuZ2V0KCdodHRwJykgb3IgMCksCiAgICAgICAgJ2JzcF92ZXJzaW9uJzpwcm9iZS5nZXQoJ3ZlcnNpb24nKSwnYnNwX2hlYWQnOnByb2JlLmdldCgnaGVhZCcsJycpLAogICAgICAgICdsYXN0X3N5bmMnOmludChjLmdldCgnZmFzdGRsX2xhc3Rfc3luYycpIG9yIDApCiAgICB9CiIiIgoKcGF0PXJlLmNvbXBpbGUocicoP21zKV5kZWYgZmFzdGRsX3N0YXR1c1xiLio/KD89XmRlZiBfZXh0cmFjdF9leHRlcm5hbF9mYXN0ZGxfdXJsXGIpJykKbT1wYXQuc2VhcmNoKHMpCmlmIG5vdCBtOgogICAgcmFpc2UgU3lzdGVtRXhpdCgnW1BBVENIIEVSUk9SXSBmYXN0ZGxfc3RhdHVzIC0+IF9leHRyYWN0X2V4dGVybmFsX2Zhc3RkbF91cmwgcmFuZ2Ugbm90IGZvdW5kJykKcz1zWzptLnN0YXJ0KCldK3N0YXR1c19ib2R5LnN0cmlwKCkrJ1xuXG4nK3NbbS5lbmQoKTpdCgpjdGwud3JpdGVfdGV4dChzLGVuY29kaW5nPSd1dGYtOCcpCg==' | base64 -d > "$PATCHER"
python3 "$PATCHER" "$SRC_CTL"
python3 -m py_compile "$SRC_CTL"
install -m 0755 "$SRC_CTL" "$LIVE_CTL"
python3 -m py_compile "$LIVE_CTL"
rm -f "$PATCHER"

echo "[5/9] Clean FastDL map mirror..."
rm -rf "$FASTDL/maps"
mkdir -p "$FASTDL/maps"
rsync -a --delete --safe-links "$CSTRIKE/maps/" "$FASTDL/maps/"
find "$FASTDL/maps" -type f -name '*.ztmp' -delete 2>/dev/null || true

echo "[6/9] Full FastDL sync + raw BSP verification..."
"$LIVE_CTL" fastdl-sync "$SID"

echo "[7/9] Restart game server..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

echo "[8/9] Local 8080 binary test..."
TEST_MAP="$FASTDL/maps/zm_303.bsp"
if [[ ! -f "$TEST_MAP" ]]; then
  TEST_MAP="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname 'zm_*.bsp' -print -quit)"
fi
[[ -n "$TEST_MAP" ]] || { echo "[ERROR] no BSP in FastDL"; exit 20; }
NAME="$(basename "$TEST_MAP")"

curl -fsS --connect-timeout 3 --max-time 10   "http://127.0.0.1:$PORT/fastdl/$SID/maps/$NAME"   -o /tmp/hh-fastdl-map-test.bsp

python3 - /tmp/hh-fastdl-map-test.bsp "$NAME" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); name=sys.argv[2]
with p.open('rb') as fh:
    b=fh.read(4)
v=int.from_bytes(b,'little') if len(b)==4 else None
print("map:",name)
print("http bytes:",p.stat().st_size)
print("head:",b.hex())
print("BSP version:",v)
if v!=30:
    raise SystemExit(30)
PY
rm -f /tmp/hh-fastdl-map-test.bsp

echo "[9/9] Final status..."
"$LIVE_CTL" fastdl-status "$SID" || true
echo
"$LIVE_CTL" rcon "$SID" "sv_downloadurl" || true
"$LIVE_CTL" rcon "$SID" "sv_allowdownload" || true
echo
ss -ltnp | grep ":$PORT " || true

echo
echo "=============================================================="
echo " [SUCCESS] FASTDL 8080 HOTFIX v3 INSTALLED"
echo "=============================================================="
echo "FastDL URL: http://$PUBLIC_IP:$PORT/fastdl/$SID/"
echo
echo "IMPORTANT:"
echo "UPnP already failed on your router."
echo "Create/keep this Keenetic rule manually:"
echo "  TCP $PORT -> $LAN_IP:$PORT"
echo
echo "Then test from OUTSIDE your LAN:"
echo "  http://$PUBLIC_IP:$PORT/fastdl/$SID/maps/$NAME"
echo "Backup: $BACKUP"
