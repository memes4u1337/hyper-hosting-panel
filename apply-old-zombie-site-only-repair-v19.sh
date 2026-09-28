#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="${1:-old-zombie.ru}"
SITE_ROOT="${2:-/var/www/hyper-host-sites/old-zombie.ru/public_html}"
TARGET="/etc/nginx/hyper-host-managed/20-site-${DOMAIN}.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-site-only-v19-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$SITE_ROOT" ]] || fail "site root missing: $SITE_ROOT"

mkdir -p "$BACKUP"
[[ -f "$TARGET" ]] && cp -a "$TARGET" "$BACKUP/20-site-${DOMAIN}.conf.before" || true
nginx -T >"$BACKUP/nginx-T-before.txt" 2>&1 || true

echo "================================================================"
echo " OLD-ZOMBIE.RU SITE ONLY REPAIR v19"
echo " Domain:    $DOMAIN"
echo " Site root: $SITE_ROOT"
echo " Target:    $TARGET"
echo " Backup:    $BACKUP"
echo " FastDL:    NOT TOUCHED"
echo "================================================================"

echo "[1/8] Detect PHP-FPM socket..."
PHP_SOCK=""
for sock in /run/php/php*-fpm.sock; do
    [[ -S "$sock" ]] || continue
    PHP_SOCK="$sock"
    break
done

if [[ -z "$PHP_SOCK" ]]; then
    fail "no PHP-FPM socket found under /run/php/"
fi
echo "PHP-FPM: $PHP_SOCK"

echo "[2/8] Check TLS certificate..."
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
[[ -f "$CERT" ]] || fail "certificate missing: $CERT"
[[ -f "$KEY" ]] || fail "certificate key missing: $KEY"
echo "TLS certificate: OK"

echo "[3/8] Inspect website entry points..."
find "$SITE_ROOT" -maxdepth 2 -type f \( \
  -name 'index.php' -o -name 'index.html' -o -name '*.js' -o -name '*.css' \
\) -printf '%p\n' 2>/dev/null | head -n 40 || true

[[ -f "$SITE_ROOT/index.php" || -f "$SITE_ROOT/index.html" ]] \
  || fail "site has neither index.php nor index.html"

echo "[4/8] Write CLEAN domain-only nginx vhost..."
cat >"$TARGET" <<EOF
# OLD-ZOMBIE.RU site vhost
# Managed by site-only repair v19.
# IMPORTANT: this file contains NO FastDL configuration.

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    root $SITE_ROOT;
    index index.php index.html index.htm;

    location ^~ /.well-known/acme-challenge/ {
        root $SITE_ROOT;
        try_files \$uri =404;
    }

    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    root $SITE_ROOT;
    index index.php index.html index.htm;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;

    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    charset utf-8;
    client_max_body_size 64m;

    # Normal site routing. Existing files/folders are served directly;
    # application routes fall back to index.php.
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP application / API handlers.
    location ~ \.php$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$document_root;
        fastcgi_param HTTP_PROXY "";
        fastcgi_index index.php;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_connect_timeout 60s;
        fastcgi_send_timeout 120s;
        fastcgi_read_timeout 120s;
    }

    # Static assets used by tabs/buttons/frontend.
    location ~* \.(?:css|js|mjs|json|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|eot|map)$ {
        try_files \$uri =404;
        expires 1h;
        add_header Cache-Control "public, max-age=3600";
        access_log off;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

echo "[5/8] Validate nginx WITHOUT touching FastDL..."
nginx -t
systemctl reload nginx
sleep 1

echo "[6/8] Verify domain vhost is actually loaded..."
nginx -T >"$BACKUP/nginx-T-after.txt" 2>&1
python3 - "$BACKUP/nginx-T-after.txt" "$DOMAIN" "$TARGET" <<'PY'
from pathlib import Path
import sys,re
txt=Path(sys.argv[1]).read_text(encoding="utf-8",errors="ignore")
domain=sys.argv[2]
target=sys.argv[3]

if f"# configuration file {target}:" not in txt:
    raise SystemExit(f"target config is not loaded by nginx: {target}")

blocks=re.findall(r'(?ms)server\s*\{.*?\n\}', txt)
hits=[b for b in blocks if re.search(rf'(?m)^\s*server_name\s+[^;]*\b{re.escape(domain)}\b',b)]
print("domain server blocks:",len(hits))
if len(hits)<2:
    raise SystemExit("expected HTTP + HTTPS domain server blocks")
print("domain vhost loaded: OK")
PY

echo "[7/8] Test site HTML + common assets locally..."
HTTP_CODE="$(curl -sS --resolve "$DOMAIN:80:127.0.0.1" \
  -o "$BACKUP/http.body" -D "$BACKUP/http.headers" \
  -w '%{http_code}' "http://$DOMAIN/" || true)"
HTTPS_CODE="$(curl -k -sS --resolve "$DOMAIN:443:127.0.0.1" \
  -o "$BACKUP/https.body" -D "$BACKUP/https.headers" \
  -w '%{http_code}' "https://$DOMAIN/" || true)"

echo "HTTP status:  $HTTP_CODE"
echo "HTTPS status: $HTTPS_CODE"
head -n 15 "$BACKUP/https.headers" || true

case "$HTTPS_CODE" in
  200|301|302) ;;
  *) fail "site HTTPS returned unexpected status $HTTPS_CODE" ;;
esac

# Extract a few local CSS/JS references from the returned page and verify them.
python3 - "$BACKUP/https.body" "$DOMAIN" "$BACKUP" <<'PY'
from pathlib import Path
import re,sys,subprocess,urllib.parse

html=Path(sys.argv[1]).read_text(encoding="utf-8",errors="ignore")
domain=sys.argv[2]
backup=Path(sys.argv[3])

refs=[]
for pat in [
    r'<script[^>]+src=["\']([^"\']+)["\']',
    r'<link[^>]+href=["\']([^"\']+\.(?:css|js)(?:\?[^"\']*)?)["\']'
]:
    refs.extend(re.findall(pat,html,re.I))

clean=[]
for ref in refs:
    if ref.startswith("//"):
        ref="https:"+ref
    if ref.startswith("http://") or ref.startswith("https://"):
        u=urllib.parse.urlparse(ref)
        if u.hostname not in {domain,"www."+domain}:
            continue
        path=u.path + (("?"+u.query) if u.query else "")
    elif ref.startswith("/"):
        path=ref
    else:
        path="/"+ref
    if path not in clean:
        clean.append(path)

print("local CSS/JS refs found:",len(clean))
for i,path in enumerate(clean[:12],1):
    out=backup/f"asset-{i}.body"
    cp=subprocess.run([
        "curl","-k","-sS","--resolve",f"{domain}:443:127.0.0.1",
        "-o",str(out),"-w","%{http_code}",f"https://{domain}{path}"
    ],capture_output=True,text=True)
    code=cp.stdout.strip()
    print(code,path)
    if code not in {"200","304"}:
        raise SystemExit(f"broken local asset: {path} -> HTTP {code}")
PY

echo "[8/8] Check PHP-FPM and nginx errors..."
systemctl is-active nginx
PHP_UNIT="$(basename "$PHP_SOCK" .sock | sed 's/php/php/' | sed 's/-fpm/-fpm/')"
echo "PHP socket exists: $PHP_SOCK"
echo
echo "Recent nginx errors for domain:"
tail -n 100 /var/log/nginx/error.log 2>/dev/null | grep -F "$DOMAIN" | tail -n 20 || true

echo
echo "================================================================"
echo " [SUCCESS] OLD-ZOMBIE SITE ONLY REPAIR v19"
echo "================================================================"
echo " Site:      https://$DOMAIN/"
echo " Site root: $SITE_ROOT"
echo " Config:    $TARGET"
echo " PHP-FPM:   $PHP_SOCK"
echo " Backup:    $BACKUP"
echo
echo "FASTDL WAS NOT READ, MODIFIED, RELOADED SEPARATELY, OR REBUILT."
echo "Only the old-zombie.ru site vhost was replaced."
echo "================================================================"
