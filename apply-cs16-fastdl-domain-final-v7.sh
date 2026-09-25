#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
DOMAIN="old-zombie.ru"
SRC="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
SERVER_ROOT="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER_ROOT/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-domain-v7-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -f "$SRC" ]] || { echo "[ERROR] missing $SRC"; exit 2; }
[[ -d "$CSTRIKE/maps" ]] || { echo "[ERROR] missing $CSTRIKE/maps"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/hyper-cs16-ctl.repo"
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live"
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg"

echo "================================================================"
echo " HYPER-HOST FASTDL DOMAIN FINAL v7"
echo " Server: #$SID"
echo " URL:    http://$DOMAIN/fastdl/$SID/"
echo " Backup: $BACKUP"
echo "================================================================"

echo "[1/9] Explain the current failure signature..."
echo '3c21646f = ASCII "<!do" = HTML document, not a GoldSrc BSP.'
echo '1868833084 is exactly the little-endian integer value of those HTML bytes.'
echo 'So the SOURCE maps are fine; the HTTP route is returning a web page.'

echo "[2/9] Validate SOURCE BSP files..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import sys
bad=[]; good=0
for p in sorted(Path(sys.argv[1]).glob('*.bsp')):
    h=p.read_bytes()[:4]
    v=int.from_bytes(h,'little') if len(h)==4 else None
    if v==30: good+=1
    else: bad.append((p.name,v,h.hex(),p.stat().st_size))
print("valid BSP:",good)
print("bad BSP:",len(bad))
if bad:
    for x in bad[:30]: print(x)
    raise SystemExit(20)
PY

echo "[3/9] Rewrite ONLY old-zombie.ru HTTP/80 vhost: /fastdl/ raw, everything else -> HTTPS..."
NGP="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cywgc3VicHJvY2Vzcywgc2h1dGlsCgpkb21haW49c3lzLmFyZ3ZbMV0KYmFja3VwX2Rpcj1QYXRoKHN5cy5hcmd2WzJdKQoKY3A9c3VicHJvY2Vzcy5ydW4oWyduZ2lueCcsJy1UJ10sc3Rkb3V0PXN1YnByb2Nlc3MuUElQRSxzdGRlcnI9c3VicHJvY2Vzcy5TVERPVVQsdGV4dD1UcnVlKQpkdW1wPWNwLnN0ZG91dCBvciAnJwppZiBjcC5yZXR1cm5jb2RlIT0wOgogICAgcmFpc2UgU3lzdGVtRXhpdCgnW05HSU5YIEVSUk9SXSBuZ2lueCAtVCBmYWlsZWRcbicrZHVtcFstMzAwMDpdKQoKIyBDb2xsZWN0IGNvbmZpZyBwYXRocyBmcm9tIG5naW54IC1ULCB0aGVuIGZpbmQgYSByZWFsIHBvcnQtODAgc2VydmVyIGJsb2NrIGZvciBvbGQtem9tYmllLnJ1LgpwYXRocz1bXQpmb3IgbSBpbiByZS5maW5kaXRlcihyJ14jIGNvbmZpZ3VyYXRpb24gZmlsZSAoLis/KTpccyokJyxkdW1wLHJlLk0pOgogICAgZnA9UGF0aChtLmdyb3VwKDEpKQogICAgaWYgZnAuaXNfZmlsZSgpIGFuZCBmcCBub3QgaW4gcGF0aHM6CiAgICAgICAgcGF0aHMuYXBwZW5kKGZwKQoKZGVmIHNlcnZlcl9ibG9ja3ModGV4dCk6CiAgICBvdXQ9W10KICAgICMgU2ltcGxlIG5naW54LWJyYWNlIHNjYW5uZXI7IGlnbm9yZXMgY29tbWVudHMgYWZ0ZXIgIy4KICAgIGZvciBtIGluIHJlLmZpbmRpdGVyKHInKD9tKV5ccypzZXJ2ZXJccypceycsdGV4dCk6CiAgICAgICAgc3RhcnQ9bS5zdGFydCgpCiAgICAgICAgYnJhY2U9dGV4dC5maW5kKCd7JyxtLnN0YXJ0KCkpCiAgICAgICAgZGVwdGg9MAogICAgICAgIGluX3NxPWluX2RxPUZhbHNlCiAgICAgICAgZXNjPUZhbHNlCiAgICAgICAgaT1icmFjZQogICAgICAgIHdoaWxlIGkgPCBsZW4odGV4dCk6CiAgICAgICAgICAgIGNoPXRleHRbaV0KICAgICAgICAgICAgaWYgZXNjOgogICAgICAgICAgICAgICAgZXNjPUZhbHNlOyBpKz0xOyBjb250aW51ZQogICAgICAgICAgICBpZiBjaD09J1xcJzoKICAgICAgICAgICAgICAgIGVzYz1UcnVlOyBpKz0xOyBjb250aW51ZQogICAgICAgICAgICBpZiBjaD09IiciIGFuZCBub3QgaW5fZHE6CiAgICAgICAgICAgICAgICBpbl9zcT1ub3QgaW5fc3EKICAgICAgICAgICAgZWxpZiBjaD09JyInIGFuZCBub3QgaW5fc3E6CiAgICAgICAgICAgICAgICBpbl9kcT1ub3QgaW5fZHEKICAgICAgICAgICAgZWxpZiBub3QgaW5fc3EgYW5kIG5vdCBpbl9kcToKICAgICAgICAgICAgICAgIGlmIGNoPT0neyc6IGRlcHRoKz0xCiAgICAgICAgICAgICAgICBlbGlmIGNoPT0nfSc6CiAgICAgICAgICAgICAgICAgICAgZGVwdGgtPTEKICAgICAgICAgICAgICAgICAgICBpZiBkZXB0aD09MDoKICAgICAgICAgICAgICAgICAgICAgICAgb3V0LmFwcGVuZCgoc3RhcnQsaSsxLHRleHRbc3RhcnQ6aSsxXSkpCiAgICAgICAgICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgICAgIGkrPTEKICAgIHJldHVybiBvdXQKCmNhbmRpZGF0ZT1Ob25lCmZvciBmcCBpbiBwYXRoczoKICAgIHRyeToKICAgICAgICB0ZXh0PWZwLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnLGVycm9ycz0naWdub3JlJykKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgY29udGludWUKICAgIGZvciBzdGFydCxlbmQsYmxvY2sgaW4gc2VydmVyX2Jsb2Nrcyh0ZXh0KToKICAgICAgICBpZiBub3QgcmUuc2VhcmNoKHInKD9pbSleXHMqc2VydmVyX25hbWVccytbXjtdKlxib2xkLXpvbWJpZVwucnVcYicsYmxvY2spOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGlmIG5vdCByZS5zZWFyY2gocicoP2ltKV5ccypsaXN0ZW5ccysoPzpcWzo6XF06KT84MCg/OlxzfDspJyxibG9jayk6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgIyBQcmVmZXIgbm9uLVNTTCBIVFRQIGJsb2NrLgogICAgICAgIGlmIHJlLnNlYXJjaChyJyg/aW0pXlxzKmxpc3RlblxzK1teO10qNDQzJyxibG9jayk6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgY2FuZGlkYXRlPShmcCx0ZXh0LHN0YXJ0LGVuZCxibG9jaykKICAgICAgICBicmVhawogICAgaWYgY2FuZGlkYXRlOgogICAgICAgIGJyZWFrCgppZiBub3QgY2FuZGlkYXRlOgogICAgcmFpc2UgU3lzdGVtRXhpdCgKICAgICAgICAnW1BBVENIIEVSUk9SXSBDb3VsZCBub3QgZmluZCB0aGUgZXhpc3RpbmcgSFRUUC84MCBuZ2lueCBzZXJ2ZXIgYmxvY2sgZm9yIG9sZC16b21iaWUucnUuXG4nCiAgICAgICAgJ1J1bjogbmdpbnggLVQgMj4mMSB8IGdyZXAgLW4gLUI1IC1BMjUgInNlcnZlcl9uYW1lLipvbGQtem9tYmllLnJ1IicKICAgICkKCmZwLHRleHQsc3RhcnQsZW5kLG9sZD1jYW5kaWRhdGUKYmFja3VwX2Rpci5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKc2h1dGlsLmNvcHkyKGZwLGJhY2t1cF9kaXIvKGZwLm5hbWUrJy5iZWZvcmUtZmFzdGRsLXY3JykpCgojIEtlZXAgb25seSBsaXN0ZW5lci9zZXJ2ZXJfbmFtZS9sb2cvcm9vdC9pbmNsdWRlcyB0aGF0IGFyZSBoYXJtbGVzcyBpbiB0aGUgSFRUUCByZWRpcmVjdCB2aG9zdC4KbGlzdGVuX2xpbmVzPXJlLmZpbmRhbGwocicoP2ltKV5ccypsaXN0ZW5ccytbXjtdKzsnLG9sZCkKc2VydmVyX25hbWVfbGluZXM9cmUuZmluZGFsbChyJyg/aW0pXlxzKnNlcnZlcl9uYW1lXHMrW147XSs7JyxvbGQpCmFjY2Vzc19saW5lcz1yZS5maW5kYWxsKHInKD9pbSleXHMqKD86YWNjZXNzX2xvZ3xlcnJvcl9sb2cpXHMrW147XSs7JyxvbGQpCgppZiBub3Qgc2VydmVyX25hbWVfbGluZXM6CiAgICBzZXJ2ZXJfbmFtZV9saW5lcz1bZicgICAgc2VydmVyX25hbWUge2RvbWFpbn0gd3d3Lntkb21haW59OyddCgpsaW5lcz1bJ3NlcnZlciB7J10KZm9yIHggaW4gbGlzdGVuX2xpbmVzOgogICAgIyBOb3JtYWxpemUgaW5kZW50YXRpb24gYW5kIGtlZXAgb25seSBwb3J0IDgwIGxpc3RlbmVycy4KICAgIGlmIHJlLnNlYXJjaChyJyg/Ol58XHMpKD86XFs6OlxdOik/ODAoPzpcc3w7KScseCk6CiAgICAgICAgbGluZXMuYXBwZW5kKCcgICAgJyt4LnN0cmlwKCkpCmlmIGxlbihsaW5lcyk9PTE6CiAgICBsaW5lcy5leHRlbmQoWycgICAgbGlzdGVuIDgwOycsJyAgICBsaXN0ZW4gWzo6XTo4MDsnXSkKZm9yIHggaW4gc2VydmVyX25hbWVfbGluZXM6CiAgICBsaW5lcy5hcHBlbmQoJyAgICAnK3guc3RyaXAoKSkKZm9yIHggaW4gYWNjZXNzX2xpbmVzOgogICAgbGluZXMuYXBwZW5kKCcgICAgJyt4LnN0cmlwKCkpCgpsaW5lcyArPSBbCiAgICAnJywKICAgICcgICAgIyBIWVBFUi1IT1NUIEZhc3RETDogTVVTVCBzdGF5IHBsYWluIEhUVFAgZm9yIG9sZCBHb2xkU3JjIGNsaWVudHMuJywKICAgICcgICAgbG9jYXRpb24gXn4gL2Zhc3RkbC8geycsCiAgICAnICAgICAgICBhbGlhcyAvc3J2L2h5cGVyLWNzMTYvZmFzdGRsLzsnLAogICAgJyAgICAgICAgYXV0b2luZGV4IG9mZjsnLAogICAgJyAgICAgICAgZGVmYXVsdF90eXBlIGFwcGxpY2F0aW9uL29jdGV0LXN0cmVhbTsnLAogICAgJyAgICAgICAgdHJ5X2ZpbGVzICR1cmkgPTQwNDsnLAogICAgJyAgICAgICAgYWRkX2hlYWRlciBDYWNoZS1Db250cm9sICJwdWJsaWMsIG1heC1hZ2U9ODY0MDAiIGFsd2F5czsnLAogICAgJyAgICAgICAgYWRkX2hlYWRlciBYLUh5cGVyLUZhc3RETCAicmF3IiBhbHdheXM7JywKICAgICcgICAgfScsCiAgICAnJywKICAgICcgICAgIyBLZWVwIG5vcm1hbCB3ZWJzaXRlIGJlaGF2aW9yOiBldmVyeXRoaW5nIGV4Y2VwdCBGYXN0REwgZ29lcyB0byBIVFRQUy4nLAogICAgJyAgICBsb2NhdGlvbiAvIHsnLAogICAgJyAgICAgICAgcmV0dXJuIDMwMSBodHRwczovLyRob3N0JHJlcXVlc3RfdXJpOycsCiAgICAnICAgIH0nLAogICAgJ30nCl0KbmV3PSdcbicuam9pbihsaW5lcykKCnVwZGF0ZWQ9dGV4dFs6c3RhcnRdK25ldyt0ZXh0W2VuZDpdCmZwLndyaXRlX3RleHQodXBkYXRlZCxlbmNvZGluZz0ndXRmLTgnKQoKdGVzdD1zdWJwcm9jZXNzLnJ1bihbJ25naW54JywnLXQnXSxzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLHN0ZGVycj1zdWJwcm9jZXNzLlNURE9VVCx0ZXh0PVRydWUpCmlmIHRlc3QucmV0dXJuY29kZSE9MDoKICAgIHNodXRpbC5jb3B5MihiYWNrdXBfZGlyLyhmcC5uYW1lKycuYmVmb3JlLWZhc3RkbC12NycpLGZwKQogICAgc3VicHJvY2Vzcy5ydW4oWyduZ2lueCcsJy10J10sc3Rkb3V0PXN1YnByb2Nlc3MuUElQRSxzdGRlcnI9c3VicHJvY2Vzcy5TVERPVVQsdGV4dD1UcnVlKQogICAgcmFpc2UgU3lzdGVtRXhpdCgnW05HSU5YIEVSUk9SXSBwYXRjaGVkIGNvbmZpZyBmYWlsZWQsIHJlc3RvcmVkIGJhY2t1cDpcbicrKHRlc3Quc3Rkb3V0IG9yICcnKVstMzAwMDpdKQoKc3VicHJvY2Vzcy5ydW4oWydzeXN0ZW1jdGwnLCdyZWxvYWQnLCduZ2lueCddLGNoZWNrPVRydWUpCnByaW50KHN0cihmcCkpCg==' | base64 -d > "$NGP"
python3 "$NGP" "$DOMAIN" "$BACKUP"
rm -f "$NGP"

echo "[4/9] Local nginx raw-BSP test BEFORE touching panel..."
PROBE_SRC="$(find "$CSTRIKE/maps" -maxdepth 1 -type f -name 'zm_303.bsp' -print -quit)"
[[ -n "$PROBE_SRC" ]] || PROBE_SRC="$(find "$CSTRIKE/maps" -maxdepth 1 -type f -name '*.bsp' -print -quit)"
mkdir -p "$FASTDL/maps"
cp -f "$PROBE_SRC" "$FASTDL/maps/"
chmod 0755 "$FASTDL" "$FASTDL/maps" || true
chmod 0644 "$FASTDL/maps/$(basename "$PROBE_SRC")"
PROBE_NAME="$(basename "$PROBE_SRC")"
curl -sS --resolve "$DOMAIN:80:127.0.0.1"   -D /tmp/hh-v7-hdr   -o /tmp/hh-v7-body   "http://$DOMAIN/fastdl/$SID/maps/$PROBE_NAME"
echo "HTTP headers:"
head -n 20 /tmp/hh-v7-hdr
python3 - <<'PY'
from pathlib import Path
d=Path('/tmp/hh-v7-body').read_bytes()
print("HTTP body bytes:",len(d))
print("HTTP head:",d[:8].hex())
print("BSP version:",int.from_bytes(d[:4],'little') if len(d)>=4 else None)
if len(d)<4 or int.from_bytes(d[:4],'little')!=30:
    raise SystemExit("LOCAL NGINX STILL IS NOT SERVING RAW BSP")
PY
rm -f /tmp/hh-v7-hdr /tmp/hh-v7-body

echo "[5/9] Install final controller override..."
CP="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cwoKcD1QYXRoKHN5cy5hcmd2WzFdKQpzPXAucmVhZF90ZXh0KGVuY29kaW5nPSd1dGYtOCcpCgpCRUdJTj0iIyBIWVBFUi1IT1NUIEZBU1RETCBET01BSU4gVjcgQkVHSU4iCkVORD0iIyBIWVBFUi1IT1NUIEZBU1RETCBET01BSU4gVjcgRU5EIgoKIyBSZS1ydW5uaW5nIHRoZSBwYXRjaCByZXBsYWNlcyBpdHMgb3duIHByZXZpb3VzIG92ZXJyaWRlIGNsZWFubHkuCnM9cmUuc3ViKAogICAgcicoP21zKV4jIEhZUEVSLUhPU1QgRkFTVERMIERPTUFJTiBWNyBCRUdJTiQuKj9eIyBIWVBFUi1IT1NUIEZBU1RETCBET01BSU4gVjcgRU5EJFxuPycsCiAgICAnJywKICAgIHMKKQoKYmxvY2s9cg==' | base64 -d > "$CP"
python3 "$CP" "$SRC"
rm -f "$CP"
python3 -m py_compile "$SRC"
install -m 0755 "$SRC" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[6/9] Full clean FastDL sync..."
"$LIVE" fastdl-sync "$SID"

echo "[7/9] Status..."
"$LIVE" fastdl-status "$SID"

echo "[8/9] Restart CS server and verify runtime URL..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
"$LIVE" rcon "$SID" "sv_downloadurl" || true
"$LIVE" rcon "$SID" "sv_allowdownload" || true

echo "[9/9] Final direct map test..."
curl -sS --resolve "$DOMAIN:80:127.0.0.1"   -o /tmp/hh-v7-final.bsp   "http://$DOMAIN/fastdl/$SID/maps/$PROBE_NAME"
python3 - <<'PY'
from pathlib import Path
d=Path('/tmp/hh-v7-final.bsp').read_bytes()
print("downloaded bytes:",len(d))
print("first 8 bytes:",d[:8].hex())
print("BSP version:",int.from_bytes(d[:4],'little') if len(d)>=4 else None)
assert len(d)>1024, "download is suspiciously small"
assert int.from_bytes(d[:4],'little')==30, "download is not GoldSrc BSP v30"
print("[OK] nginx returns the real BSP file")
PY
rm -f /tmp/hh-v7-final.bsp

echo
echo "================================================================"
echo " [SUCCESS] FASTDL DOMAIN FINAL v7"
echo "================================================================"
echo "FastDL URL: http://$DOMAIN/fastdl/$SID/"
echo "Website HTTPS is unchanged."
echo "HTTP /fastdl/ stays raw; all other HTTP requests redirect to HTTPS."
echo "Backup: $BACKUP"
