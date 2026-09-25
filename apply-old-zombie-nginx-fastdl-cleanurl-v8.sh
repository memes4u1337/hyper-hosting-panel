#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
DOMAIN="old-zombie.ru"
PUBLIC_IP="90.189.208.25"
LAN_IP="192.168.0.179"

SERVER_ROOT="/srv/hyper-cs16/servers/${SID}"
CSTRIKE="$SERVER_ROOT/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/${SID}"
SITE_ROOT="/var/www/hyper-host-sites/${DOMAIN}/public_html"
CANON="/etc/nginx/conf.d/00-old-zombie-canonical.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/old-zombie-nginx-fastdl-v8-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -d "$CSTRIKE" ]] || { echo "[ERROR] missing $CSTRIKE"; exit 2; }

if [[ ! -d "$SITE_ROOT" ]]; then
  FOUND="$(find /var/www/hyper-host-sites -maxdepth 4 -type d -path "*/${DOMAIN}/public_html" -print -quit 2>/dev/null || true)"
  [[ -n "$FOUND" ]] && SITE_ROOT="$FOUND"
fi
[[ -d "$SITE_ROOT" ]] || { echo "[ERROR] old-zombie.ru public_html not found"; exit 2; }

mkdir -p "$BACKUP"
[[ -f "$CANON" ]] && cp -a "$CANON" "$BACKUP/" || true
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg" || true
nginx -T >"$BACKUP/nginx-T-before.txt" 2>&1 || true

echo "================================================================"
echo " OLD-ZOMBIE.RU NGINX + FASTDL + CLEAN URL FINAL v8"
echo " Server:   #$SID"
echo " Site:     $SITE_ROOT"
echo " FastDL:   http://${DOMAIN}/fastdl/${SID}/"
echo " LAN bind: ${LAN_IP}:80 / ${LAN_IP}:443"
echo " Backup:   $BACKUP"
echo "================================================================"

echo "[1/10] Find PHP-FPM socket..."
PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' -printf '%p\n' 2>/dev/null | sort -V | tail -1)"
[[ -n "$PHP_SOCK" ]] || { echo "[ERROR] PHP-FPM socket not found in /run/php"; exit 3; }
echo "PHP-FPM: $PHP_SOCK"

echo "[2/10] Validate source BSP maps..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1])
good=[]; bad=[]
for p in sorted(root.glob('*.bsp')):
    try:
        raw=p.read_bytes()[:4]
        v=struct.unpack('<I',raw)[0] if len(raw)==4 else None
        (good if v==30 else bad).append((p.name,v,raw.hex()))
    except Exception as e:
        bad.append((p.name,None,str(e)))
print("valid BSP:",len(good))
print("bad BSP:",len(bad))
for x in bad[:20]: print("BAD",x)
if bad: raise SystemExit(4)
PY

echo "[3/10] Clean-sync FastDL directly from cstrike..."
mkdir -p "$FASTDL"
for d in maps models sound sprites gfx resource overviews events media; do
  if [[ -d "$CSTRIKE/$d" ]]; then
    mkdir -p "$FASTDL/$d"
    rsync -a --delete --exclude='*.ztmp' "$CSTRIKE/$d/" "$FASTDL/$d/"
  else
    rm -rf "$FASTDL/$d"
  fi
done

find "$FASTDL" -maxdepth 1 -type f -iname '*.wad' -delete 2>/dev/null || true
find "$CSTRIKE" -maxdepth 1 -type f -iname '*.wad' -exec cp -a '{}' "$FASTDL/" ';'
find "$FASTDL" -type f -name '*.ztmp' -delete 2>/dev/null || true
chown -R root:www-data "$FASTDL"
find "$FASTDL" -type d -exec chmod 0755 '{}' +
find "$FASTDL" -type f -exec chmod 0644 '{}' +

echo "[4/10] Verify copied BSP bytes are identical..."
python3 - "$CSTRIKE/maps" "$FASTDL/maps" <<'PY'
from pathlib import Path
import hashlib,struct,sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2])
bad=[]
maps=sorted(src.glob('*.bsp'))
for p in maps:
    q=dst/p.name
    if not q.is_file():
        bad.append((p.name,'missing'))
        continue
    sh=lambda x: hashlib.sha256(x.read_bytes()).hexdigest()
    head=q.read_bytes()[:4]
    ver=struct.unpack('<I',head)[0] if len(head)==4 else None
    if sh(p)!=sh(q) or ver!=30:
        bad.append((p.name,f'version={ver}',head.hex()))
print("source BSP:",len(maps))
print("fastdl BSP:",len(list(dst.glob('*.bsp'))))
print("bad mirror:",len(bad))
for x in bad[:20]: print("BAD",x)
if bad: raise SystemExit(5)
PY

echo "[5/10] Repair server.cfg and force canonical sv_downloadurl..."
python3 - "$CSTRIKE/server.cfg" "$DOMAIN" "$SID" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); domain=sys.argv[2]; sid=sys.argv[3]
raw=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
if raw.count('\\n')>=5 and raw.count('\n')<=2:
    raw=raw.replace('\\r\\n','\n').replace('\\n','\n').replace('\\r','\n')
text=raw.replace('\r\n','\n').replace('\r','\n')

text=re.sub(r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?','',text)
managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
out=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+',line)
    if m and m.group(1).lower() in managed:
        continue
    out.append(line)

url=f'http://{domain}/fastdl/{sid}/'
out += [
    '',
    '// HYPER-HOST FASTDL BEGIN',
    '// Canonical OLD ZOMBIE FastDL',
    'sv_allowdownload 1',
    'sv_allowupload 0',
    'sv_send_resources 1',
    'sv_allow_dlfile 1',
    f'sv_downloadurl "{url}"',
    '// HYPER-HOST FASTDL END',
]
p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print("server.cfg lines:",len(out))
print("sv_downloadurl:",url)
PY

echo "[6/10] Ensure certificate exists..."
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

# First install HTTP-only exact-LAN listener. It wins over wildcard panel redirects.
cat >"$CANON" <<EOF
# OLD ZOMBIE canonical vhost v8.
# Exact LAN binds intentionally override wildcard panel/certbot listeners.

server {
    listen ${LAN_IP}:80 bind;
    server_name ${DOMAIN} www.${DOMAIN};

    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        default_type application/octet-stream;
        add_header Cache-Control "public, max-age=86400" always;
        add_header X-OldZombie-FastDL "raw" always;
    }

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}
EOF

nginx -t
systemctl reload nginx

if [[ ! -s "$CERT" || ! -s "$KEY" ]]; then
  echo "SSL certificate not found; requesting Let's Encrypt..."
  mkdir -p /var/www/html/.well-known/acme-challenge
  if ! command -v certbot >/dev/null 2>&1; then
    apt-get update
    apt-get install -y certbot
  fi
  certbot certonly --webroot -w /var/www/html \
    -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email
fi
[[ -s "$CERT" && -s "$KEY" ]] || { echo "[ERROR] SSL certificate still missing"; exit 6; }

echo "[7/10] Install canonical HTTPS site with clean URLs..."
cat >>"$CANON" <<EOF

server {
    listen ${LAN_IP}:443 ssl http2 bind;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${SITE_ROOT};
    index index.php index.html index.htm;

    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};

    # If the browser requests /page.php directly, make the visible URL /page.
    # Internal try_files requests keep their original \$request_uri, so they do not loop.
    if (\$request_uri ~ ^(.+)\\.php(?:\\?.*)?\$) {
        return 301 https://\$host\$1\$is_args\$args;
    }

    # FastDL also works over HTTPS for browser checks, although CS uses HTTP above.
    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        default_type application/octet-stream;
        add_header Cache-Control "public, max-age=86400" always;
        add_header X-OldZombie-FastDL "raw" always;
    }

    # /server -> /server.php internally; normal files/directories keep working.
    location / {
        try_files \$uri \$uri/ \$uri.php?\$query_string /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        try_files \$uri =404;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~ /\\. {
        deny all;
    }
}
EOF

nginx -t
systemctl reload nginx

echo "[8/10] Verify RAW FastDL through the exact active vhost..."
PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -name 'zm_303.bsp' -print -quit)"
if [[ -z "$PROBE" ]]; then
  PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname '*.bsp' -print -quit)"
fi
[[ -n "$PROBE" ]] || { echo "[ERROR] no BSP in FastDL"; exit 7; }
REL="${PROBE#"$FASTDL/"}"

curl -sS --connect-timeout 3 --max-time 15 \
  -H "Host: ${DOMAIN}" \
  -D /tmp/oz-hdr \
  -o /tmp/oz-bsp \
  "http://${LAN_IP}/fastdl/${SID}/${REL}"

cat /tmp/oz-hdr
python3 - /tmp/oz-bsp "$PROBE" <<'PY'
from pathlib import Path
import hashlib,struct,sys
got=Path(sys.argv[1]); src=Path(sys.argv[2])
raw=got.read_bytes()
head=raw[:4]
ver=struct.unpack('<I',head)[0] if len(head)==4 else None
print("HTTP body bytes:",len(raw))
print("HTTP head:",head.hex())
print("BSP version:",ver)
print("SHA256 match:",hashlib.sha256(raw).digest()==hashlib.sha256(src.read_bytes()).digest())
if ver!=30:
    raise SystemExit("FASTDL IS NOT RAW BSP")
if hashlib.sha256(raw).digest()!=hashlib.sha256(src.read_bytes()).digest():
    raise SystemExit("FASTDL BSP DIFFERS FROM SOURCE")
PY

echo "[9/10] Apply runtime FastDL cvars and restart server..."
CTL="/usr/local/sbin/hyper-cs16-ctl"
if [[ -x "$CTL" ]]; then
  "$CTL" rcon "$SID" 'sv_allowdownload 1' || true
  "$CTL" rcon "$SID" 'sv_allowupload 0' || true
  "$CTL" rcon "$SID" 'sv_send_resources 1' || true
  "$CTL" rcon "$SID" 'sv_allow_dlfile 1' || true
  "$CTL" rcon "$SID" "sv_downloadurl \\"http://${DOMAIN}/fastdl/${SID}/\\"" || true
fi
systemctl restart "hyper-cs16@${SID}.service" || true
sleep 3

echo "[10/10] Verify clean URLs + final FastDL..."
echo "--- HTTP FastDL ---"
curl -sSI --connect-timeout 3 --max-time 10 \
  -H "Host: ${DOMAIN}" \
  "http://${LAN_IP}/fastdl/${SID}/${REL}" | sed -n '1,12p'

echo "--- HTTPS /server ---"
curl -ksSI --connect-timeout 3 --max-time 10 \
  --resolve "${DOMAIN}:443:${LAN_IP}" \
  "https://${DOMAIN}/server" | sed -n '1,10p' || true

echo "--- HTTPS /server.php should redirect to /server ---"
curl -ksSI --connect-timeout 3 --max-time 10 \
  --resolve "${DOMAIN}:443:${LAN_IP}" \
  "https://${DOMAIN}/server.php" | sed -n '1,12p' || true

echo "--- runtime sv_downloadurl ---"
[[ -x "$CTL" ]] && "$CTL" rcon "$SID" 'sv_downloadurl' || true

rm -f /tmp/oz-hdr /tmp/oz-bsp

echo
echo "================================================================"
echo " [SUCCESS] OLD-ZOMBIE NGINX / FASTDL / CLEAN URL v8"
echo "================================================================"
echo "FastDL: http://${DOMAIN}/fastdl/${SID}/"
echo "Clean URL example: https://${DOMAIN}/server"
echo "Old .php URL redirects to extensionless URL."
echo "Canonical nginx: $CANON"
echo "Backup: $BACKUP"
