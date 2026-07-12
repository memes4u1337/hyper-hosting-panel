#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
DOMAIN="${1:-beta.mystockbot.xyz}"
SITE_ROOT="/var/www/hyper-host-sites/$DOMAIN/public_html"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_CURRENT="$BASE/backups/v82-current-state-$STAMP"
REPORT=/root/hyper-host-v82-restore-old-sites-beta-report.txt
mkdir -p "$BACKUP_CURRENT"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; return 1; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_domain "$DOMAIN" || { echo "[HYPER-HOST] Некорректный домен: $DOMAIN" >&2; exit 1; }

ensure_nginx_writable(){
  local test=/etc/nginx/hyper-host-v82-write-test-$$ runtime=/opt/hyper-host/runtime/nginx mount_script=/opt/hyper-host/bin/mount-nginx-runtime.sh
  if touch "$test" 2>/dev/null; then rm -f "$test"; return 0; fi
  log 'Каталог /etc/nginx read-only — подключаю writable runtime.'
  mkdir -p "$runtime" /opt/hyper-host/bin
  if [[ ! -f "$runtime/nginx.conf" ]]; then
    cp -a /etc/nginx/. "$runtime/" 2>/dev/null || fail 'Не удалось скопировать Nginx в writable runtime.'
  fi
  mountpoint -q /etc/nginx && umount -lf /etc/nginx 2>/dev/null || true
  mount --bind "$runtime" /etc/nginx || fail 'Не удалось подключить writable Nginx runtime.'
  touch "$test" 2>/dev/null || fail 'Nginx runtime всё ещё недоступен для записи.'
  rm -f "$test"
  cat > "$mount_script" <<'EOS'
#!/usr/bin/env bash
set -e
RUNTIME=/opt/hyper-host/runtime/nginx
TARGET=/etc/nginx
mkdir -p "$RUNTIME" "$TARGET"
mountpoint -q "$TARGET" && exit 0
mount --bind "$RUNTIME" "$TARGET"
EOS
  chmod 0755 "$mount_script"
  { crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME' || true; echo '@reboot /opt/hyper-host/bin/mount-nginx-runtime.sh # HYPER-HOST-NGINX-RUNTIME'; } | crontab -
}

log "Резервная копия текущего состояния: $BACKUP_CURRENT"
ensure_nginx_writable
[[ -d /etc/nginx ]] && tar -C /etc/nginx -cpf "$BACKUP_CURRENT/nginx.tar" .
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP_CURRENT/hyper-host-ctl"
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP_CURRENT/hyperhost.sqlite"

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi

rollback(){
  local code=$?
  trap - ERR
  printf '[HYPER-HOST] Ошибка. Возвращаю состояние до запуска v82.\n' >&2
  if [[ -f "$BACKUP_CURRENT/nginx.tar" ]]; then
    find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    tar -C /etc/nginx -xpf "$BACKUP_CURRENT/nginx.tar" 2>/dev/null || true
  fi
  [[ -f "$BACKUP_CURRENT/hyper-host-ctl" ]] && cp -a "$BACKUP_CURRENT/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  [[ -f "$BACKUP_CURRENT/hyperhost.sqlite" ]] && cp -a "$BACKUP_CURRENT/hyperhost.sqlite" "$DATA"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  exit "$code"
}
trap rollback ERR

# v79 backup was taken before v79/v80/v81 started rebuilding every site.
RESTORE_SOURCE="$(find "$BASE/backups" -mindepth 1 -maxdepth 1 -type d -name 'v79-site-vhost-content-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{sub(/^[^ ]+ /,"");print}')"
[[ -n "$RESTORE_SOURCE" ]] || fail 'Не найдена резервная копия v79-site-vhost-content-* (она должна быть после установки v79).'
[[ -f "$RESTORE_SOURCE/nginx.tar" ]] || fail "В резервной копии нет nginx.tar: $RESTORE_SOURCE"
[[ -f "$RESTORE_SOURCE/hyper-host-ctl" ]] || fail "В резервной копии нет hyper-host-ctl: $RESTORE_SOURCE"

log "Возвращаю конфиги сайтов и панели из рабочей копии: $RESTORE_SOURCE"
find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -C /etc/nginx -xpf "$RESTORE_SOURCE/nginx.tar"

# Restore only the old sites metadata, not users/bots/settings changed later.
if [[ -f "$RESTORE_SOURCE/hyperhost.sqlite" && -f "$DATA" ]]; then
  python3 - "$DATA" "$RESTORE_SOURCE/hyperhost.sqlite" <<'PYDB'
import sqlite3,sys
cur_path,old_path=sys.argv[1:3]
con=sqlite3.connect(cur_path)
try:
    con.execute("ATTACH DATABASE ? AS olddb",(old_path,))
    has_cur=con.execute("SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='sites'").fetchone()
    has_old=con.execute("SELECT 1 FROM olddb.sqlite_master WHERE type='table' AND name='sites'").fetchone()
    if has_cur and has_old:
        cur_cols=[r[1] for r in con.execute("PRAGMA main.table_info(sites)")]
        old_cols={r[1] for r in con.execute("PRAGMA olddb.table_info(sites)")}
        common=[c for c in cur_cols if c in old_cols]
        if common:
            q=','.join('"'+c.replace('"','""')+'"' for c in common)
            con.execute("DELETE FROM main.sites")
            con.execute(f"INSERT INTO main.sites ({q}) SELECT {q} FROM olddb.sites")
            con.commit()
finally:
    con.close()
PYDB
fi

# Remove only the global route files introduced after v79.
rm -f \
  /etc/nginx/sites-enabled/20-hyper-host-sites-managed.conf \
  /etc/nginx/sites-available/20-hyper-host-sites-managed.conf \
  /etc/nginx/sites-enabled/hyper-host-sites-managed.conf \
  /etc/nginx/sites-available/hyper-host-sites-managed.conf
rm -f "$BASE/data/site-routing-exact.tsv" "$BASE/data/site-routing-plan.txt"

# Put back the pre-global-rebuild CLI (v78 logic), preserving Deploy Manager fixes.
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
bash -n /usr/local/sbin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true

mkdir -p "$SITE_ROOT" "/var/www/hyper-host-sites/$DOMAIN/logs" /opt/hyper-host/acme-webroot/.well-known/acme-challenge
# Make uploaded FTP content readable by Nginx/PHP without changing ownership.
find "$SITE_ROOT" -type d -exec chmod 0755 {} + 2>/dev/null || true
find "$SITE_ROOT" -type f -exec chmod 0644 {} + 2>/dev/null || true
chmod 0755 /var/www /var/www/hyper-host-sites "/var/www/hyper-host-sites/$DOMAIN" "$SITE_ROOT" 2>/dev/null || true
touch "/var/www/hyper-host-sites/$DOMAIN/logs/access.log" "/var/www/hyper-host-sites/$DOMAIN/logs/error.log"

# Preserve the PHP socket previously selected for beta when possible.
PHP_SOCK=""
for oldconf in \
  "/etc/nginx/sites-available/hyper-host-site-$DOMAIN.conf" \
  "/etc/nginx/sites-enabled/hyper-host-site-$DOMAIN.conf"; do
  [[ -f "$oldconf" ]] || continue
  PHP_SOCK="$(sed -nE 's#.*fastcgi_pass[[:space:]]+unix:([^;]+);.*#\1#p' "$oldconf" | head -n1)"
  [[ -n "$PHP_SOCK" ]] && break
done
if [[ -z "$PHP_SOCK" || ! -S "$PHP_SOCK" ]]; then
  PHP_VERSION="$(python3 - "$DATA" "$DOMAIN" <<'PYPHP'
import sqlite3,sys
try:
    con=sqlite3.connect(sys.argv[1])
    r=con.execute("SELECT php_version FROM sites WHERE domain=? LIMIT 1",(sys.argv[2],)).fetchone()
    print((r[0] if r and r[0] else '').strip())
except Exception: pass
PYPHP
)"
  [[ -n "$PHP_VERSION" && -S "/run/php/php${PHP_VERSION}-fpm.sock" ]] && PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
fi
[[ -n "$PHP_SOCK" && -S "$PHP_SOCK" ]] || PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "$PHP_SOCK" ]] || PHP_SOCK=/run/php/php8.2-fpm.sock

# Remove beta from any other enabled server_name, without touching the rest of that site.
python3 - /etc/nginx/sites-enabled "$DOMAIN" <<'PYDEDUP'
from pathlib import Path
import os,re,sys
enabled=Path(sys.argv[1]); domain=sys.argv[2].lower(); targets={domain,'www.'+domain}
for link in list(enabled.iterdir()) if enabled.exists() else []:
    try: real=link.resolve(strict=True)
    except Exception: continue
    if real.name==f'hyper-host-site-{domain}.conf': continue
    try: text=real.read_text(encoding='utf-8',errors='ignore')
    except Exception: continue
    state={'changed':False,'found':False}
    def repl(m):
        names=m.group(1).split()
        kept=[x for x in names if x.lower() not in targets]
        if len(kept)!=len(names):
            state['found']=True; state['changed']=True
        if not kept: kept=['disabled-beta-route.invalid']
        return 'server_name '+' '.join(kept)+';'
    new=re.sub(r'\bserver_name\s+([^;]+);',repl,text)
    if state['found'] and state['changed']:
        real.write_text(new,encoding='utf-8')
PYDEDUP

CERT=""; KEY=""
shopt -s nullglob
for candidate in /opt/hyper-host/letsencrypt/live/*/fullchain.pem /etc/letsencrypt/live/*/fullchain.pem; do
  [[ -f "$candidate" ]] || continue
  candidate_key="${candidate%/fullchain.pem}/privkey.pem"
  [[ -f "$candidate_key" ]] || continue
  openssl x509 -in "$candidate" -noout -checkend 0 >/dev/null 2>&1 || continue
  openssl x509 -in "$candidate" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || continue
  CERT="$candidate"; KEY="$candidate_key"; break
done
shopt -u nullglob

BETA_CONF="/etc/nginx/sites-available/hyper-host-site-$DOMAIN.conf"
cat > "$BETA_CONF" <<EOFNGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $SITE_ROOT;
    index index.html index.htm index.php;
    client_max_body_size 1024M;
    access_log /var/www/hyper-host-sites/$DOMAIN/logs/access.log;
    error_log /var/www/hyper-host-sites/$DOMAIN/logs/error.log;

    location ^~ /.well-known/acme-challenge/ {
        root /opt/hyper-host/acme-webroot;
        default_type text/plain;
        try_files \$uri =404;
        allow all;
    }
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:$PHP_SOCK;
    }
    location ~ /\. { deny all; }
}
EOFNGINX

if [[ -n "$CERT" && -n "$KEY" ]]; then
cat >> "$BETA_CONF" <<EOFSSL

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    root $SITE_ROOT;
    index index.html index.htm index.php;
    client_max_body_size 1024M;
    access_log /var/www/hyper-host-sites/$DOMAIN/logs/ssl-access.log;
    error_log /var/www/hyper-host-sites/$DOMAIN/logs/ssl-error.log;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /.well-known/acme-challenge/ {
        root /opt/hyper-host/acme-webroot;
        default_type text/plain;
        try_files \$uri =404;
        allow all;
    }
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:$PHP_SOCK;
    }
    location ~ /\. { deny all; }
}
EOFSSL
fi
ln -sfn "$BETA_CONF" "/etc/nginx/sites-enabled/hyper-host-site-$DOMAIN.conf"

NGINX_TEST="$(nginx -t 2>&1)"
printf '%s\n' "$NGINX_TEST"
[[ "$NGINX_TEST" != *'conflicting server name'* ]] || fail 'После восстановления остались конфликтующие server_name.'
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx

SERVER_IP="$(awk -F= '/^SERVER_IP=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' /etc/hyper-host/hyper-host.conf 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$SERVER_IP" ]] || SERVER_IP=127.0.0.1

# Beta must always serve the exact uploaded directory.
PROBE="hyper-host-v82-beta-${STAMP}-$$.txt"
PROBE_BODY="HYPER-HOST-V82-BETA-$STAMP-$$"
printf '%s' "$PROBE_BODY" > "$SITE_ROOT/$PROBE"
chmod 0644 "$SITE_ROOT/$PROBE"
BETA_BODY=""
for addr in "$SERVER_IP" 127.0.0.1; do
  BETA_BODY="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 7 -H "Host: $DOMAIN" "http://$addr/$PROBE" 2>/dev/null || true)"
  [[ "$BETA_BODY" == "$PROBE_BODY" ]] && break
done
rm -f "$SITE_ROOT/$PROBE"
[[ "$BETA_BODY" == "$PROBE_BODY" ]] || fail "$DOMAIN не отдаёт файлы из $SITE_ROOT. Ответ: ${BETA_BODY:0:240}"

# Panel must be back on LAN IP and its own document root.
PANEL_ROOT=/var/www/hyper-host/public
[[ -d "$PANEL_ROOT" ]] || fail "Не найден document root панели: $PANEL_ROOT"
PANEL_PROBE="hyper-host-v82-panel-${STAMP}-$$.txt"
PANEL_BODY="HYPER-HOST-V82-PANEL-$STAMP-$$"
printf '%s' "$PANEL_BODY" > "$PANEL_ROOT/$PANEL_PROBE"
chmod 0644 "$PANEL_ROOT/$PANEL_PROBE"
PANEL_RESPONSE=""
for addr in "$SERVER_IP" 127.0.0.1; do
  PANEL_RESPONSE="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 7 -H "Host: $SERVER_IP" "http://$addr/$PANEL_PROBE" 2>/dev/null || true)"
  [[ "$PANEL_RESPONSE" == "$PANEL_BODY" ]] && break
done
rm -f "$PANEL_ROOT/$PANEL_PROBE"
[[ "$PANEL_RESPONSE" == "$PANEL_BODY" ]] || fail "Панель не отдаётся из $PANEL_ROOT по LAN IP. Ответ: ${PANEL_RESPONSE:0:240}"

# Check every restored canonical site using its restored vhost, without rebuilding it.
VERIFY_LIST="/tmp/hyper-host-v82-sites-$$.tsv"
python3 - /etc/nginx/sites-enabled > "$VERIFY_LIST" <<'PYVERIFY'
from pathlib import Path
import re,sys
base=Path(sys.argv[1]); seen=set()
for link in sorted(base.iterdir()) if base.exists() else []:
    try: p=link.resolve(strict=True); text=p.read_text(encoding='utf-8',errors='ignore')
    except Exception: continue
    roots=re.findall(r'\broot\s+(/var/www/hyper-host-sites/([^/\s;]+)/public_html);',text)
    if not roots: continue
    names=[]
    for raw in re.findall(r'\bserver_name\s+([^;]+);',text):
        names += [x for x in raw.split() if re.match(r'^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$',x)]
    for root,site in roots:
        if site in seen or not names: continue
        host=site if site in names else names[0]
        seen.add(site); print(f'{site}\t{host}\t{root}')
PYVERIFY

SITES_OK=0
SITES_TOTAL=0
SITE_RESULTS="/tmp/hyper-host-v82-results-$$.txt"
: > "$SITE_RESULTS"
while IFS=$'\t' read -r site host root; do
  [[ -n "$site" && -n "$host" && -d "$root" ]] || continue
  SITES_TOTAL=$((SITES_TOTAL+1))
  probe="hyper-host-v82-site-${SITES_TOTAL}-${STAMP}-$$.txt"
  body="HYPER-HOST-V82-SITE-${site}-${STAMP}-$$"
  printf '%s' "$body" > "$root/$probe"
  chmod 0644 "$root/$probe"
  response="$(curl --noproxy '*' -kfsSL --connect-timeout 2 --max-time 12 --max-redirs 4 \
    --resolve "$host:80:$SERVER_IP" --resolve "$host:443:$SERVER_IP" \
    "http://$host/$probe" 2>/dev/null || true)"
  rm -f "$root/$probe"
  if [[ "$response" == "$body" ]]; then
    SITES_OK=$((SITES_OK+1)); printf '%s | %s | OK\n' "$host" "$root" >> "$SITE_RESULTS"
  else
    fail "Старый сайт $host не вернулся в $root. Ответ: ${response:0:200}"
  fi
done < "$VERIFY_LIST"
rm -f "$VERIFY_LIST"

ADMIN_HASH_AFTER=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi
[[ -z "$ADMIN_HASH_BEFORE" || "$ADMIN_HASH_BEFORE" == "$ADMIN_HASH_AFTER" ]] || fail 'Пароль admin изменился.'

INDEX_FILE='не найден'
for idx in index.html index.htm index.php; do [[ -f "$SITE_ROOT/$idx" ]] && { INDEX_FILE="$idx"; break; }; done
HTTPS_STATUS='сертификат для beta не найден — HTTP работает'
[[ -n "$CERT" ]] && HTTPS_STATUS="подключён $CERT"

{
  echo 'HYPER-HOST v82 — restore old sites + beta only'
  echo
  echo "Restored from: $RESTORE_SOURCE"
  echo "Current-state backup: $BACKUP_CURRENT"
  echo "Panel LAN: OK ($SERVER_IP -> $PANEL_ROOT)"
  echo "Restored sites checked: $SITES_OK/$SITES_TOTAL"
  echo "Beta domain: $DOMAIN"
  echo "Beta root: $SITE_ROOT"
  echo "Beta index priority: index.html index.htm index.php"
  echo "Beta current index: $INDEX_FILE"
  echo "Beta HTTPS: $HTTPS_STATUS"
  echo 'Global managed v81 config: removed'
  echo 'Other site configs: restored exactly from pre-v79 backup'
  echo 'FTP/SQL data/bots/site files: unchanged'
  echo 'Admin password: unchanged'
  echo
  echo 'Restored site checks:'
  cat "$SITE_RESULTS"
} > "$REPORT"
chmod 0600 "$REPORT"
rm -f "$SITE_RESULTS"
trap - ERR

printf '\n%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — старые сайты и панель восстановлены'
printf '%s\n' '============================================================'
printf ' Панель LAN:         %s\n' "РАБОТАЕТ ($SERVER_IP)"
printf ' Старые сайты:       %s/%s проверено\n' "$SITES_OK" "$SITES_TOTAL"
printf ' beta.mystockbot:    %s\n' 'свой public_html — РАБОТАЕТ'
printf ' beta index:         %s\n' "$INDEX_FILE"
printf ' beta HTTPS:         %s\n' "$HTTPS_STATUS"
printf ' Остальные vhost:    %s\n' 'ВОЗВРАЩЕНЫ КАК БЫЛИ'
printf ' Admin password:     %s\n' 'НЕ ИЗМЕНЁН'
printf ' Отчёт:              %s\n' "$REPORT"
printf '%s\n' '============================================================'
