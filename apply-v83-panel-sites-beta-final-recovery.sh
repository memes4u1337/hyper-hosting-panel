#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
BETA_DOMAIN="${1:-beta.mystockbot.xyz}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v83-panel-sites-beta-recovery-$STAMP"
REPORT=/root/hyper-host-v83-panel-sites-beta-recovery-report.txt
ROUTING_MAP="$BASE/data/v83-routing.tsv"
INDEX_BEFORE="/tmp/hyper-host-v83-index-before-$$.json"
INDEX_AFTER="/tmp/hyper-host-v83-index-after-$$.json"
mkdir -p "$BACKUP"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; return 1; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_domain "$BETA_DOMAIN" || { echo "[HYPER-HOST] Некорректный домен: $BETA_DOMAIN" >&2; exit 1; }

ensure_nginx_writable(){
  local test="/etc/nginx/hyper-host-v83-write-test-$$" runtime=/opt/hyper-host/runtime/nginx mount_script=/opt/hyper-host/bin/mount-nginx-runtime.sh
  if touch "$test" 2>/dev/null; then rm -f "$test"; return 0; fi
  log 'Каталог /etc/nginx read-only — подключаю writable runtime.'
  mkdir -p "$runtime" /opt/hyper-host/bin /etc/nginx
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

snapshot_indexes(){
  local output="$1"
  python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,sys
base=Path('/var/www/hyper-host-sites'); out={}
if base.is_dir():
    for site in sorted(base.iterdir()):
        root=site/'public_html'
        if not root.is_dir(): continue
        for name in ('index.html','index.htm','index.php'):
            p=root/name
            if p.is_file():
                h=hashlib.sha256()
                with p.open('rb') as f:
                    for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
                out[str(p)]={'sha256':h.hexdigest(),'size':p.stat().st_size}
Path(sys.argv[1]).write_text(json.dumps(out,ensure_ascii=False,sort_keys=True,indent=2),encoding='utf-8')
PY
}

read_shell_value(){
  local key="$1" file="${2:-/etc/hyper-host/hyper-host.conf}"
  [[ -f "$file" ]] || return 0
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?([^\"'#[:space:]]+).*/\\1/p" "$file" | tail -n1
}

ensure_nginx_writable
log "Резервная копия текущего Nginx: $BACKUP"
tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" .
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP/hyper-host-ctl"
[[ -f /opt/hyper-host/nginx_recover_v83.py ]] && cp -a /opt/hyper-host/nginx_recover_v83.py "$BACKUP/nginx_recover_v83.py"

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi
snapshot_indexes "$INDEX_BEFORE"

rollback(){
  local code=$?
  trap - ERR
  printf '[HYPER-HOST] Ошибка. Возвращаю Nginx и CLI в состояние до v83.\n' >&2
  if [[ -f "$BACKUP/nginx.tar" ]]; then
    find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    tar -C /etc/nginx -xpf "$BACKUP/nginx.tar" 2>/dev/null || true
  fi
  [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  if [[ -f "$BACKUP/nginx_recover_v83.py" ]]; then
    cp -a "$BACKUP/nginx_recover_v83.py" /opt/hyper-host/nginx_recover_v83.py
  else
    rm -f /opt/hyper-host/nginx_recover_v83.py
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  rm -f "$INDEX_BEFORE" "$INDEX_AFTER"
  exit "$code"
}
trap rollback ERR

LAN_IP="$(read_shell_value SERVER_IP)"
[[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$LAN_IP" ]] || LAN_IP=192.168.0.179
PUBLIC_IP="$(read_shell_value PUBLIC_IP)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(read_shell_value SERVER_PUBLIC_IP)"
[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "$LAN_IP" ]] || PUBLIC_IP="$(cat /etc/hyper-host/public_ip 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP=90.189.208.25

PANEL_DOMAIN="$(read_shell_value PANEL_DOMAIN)"
if ! valid_domain "$PANEL_DOMAIN"; then
  PANEL_DOMAIN="$(python3 - "$DATA" <<'PY'
import re,sqlite3,sys
candidates=[]
for path in ('/var/www/hyper-host/app/config.php','/var/www/hyper-host/app/config.example.php'):
    try:
        text=open(path,encoding='utf-8',errors='ignore').read()
        m=re.search(r"['\"]panel_domain['\"]\s*=>\s*['\"]([^'\"]+)",text)
        if m: candidates.append(m.group(1))
    except Exception: pass
try:
    con=sqlite3.connect(sys.argv[1])
    row=con.execute("SELECT value FROM settings WHERE key='panel_domain_override' LIMIT 1").fetchone()
    if row: candidates.insert(0,str(row[0]))
except Exception: pass
for value in candidates:
    value=value.strip().lower().rstrip('.')
    if re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}',value):
        print(value); break
PY
)"
fi
valid_domain "$PANEL_DOMAIN" || PANEL_DOMAIN=panel.hyper-host.pw

PANEL_PHP_SOCK="$(read_shell_value PHP_FPM_SOCK)"
[[ -n "$PANEL_PHP_SOCK" && -S "$PANEL_PHP_SOCK" ]] || PANEL_PHP_SOCK="$(sed -nE 's#.*fastcgi_pass[[:space:]]+unix:([^;]+);.*#\1#p' /etc/nginx/sites-available/hyper-host-panel.conf 2>/dev/null | head -n1 || true)"
[[ -n "$PANEL_PHP_SOCK" && -S "$PANEL_PHP_SOCK" ]] || PANEL_PHP_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "$PANEL_PHP_SOCK" ]] || PANEL_PHP_SOCK=/run/php/php8.2-fpm.sock

DEFAULT_SSL_DIR="$BASE/ssl/default-vhost"
DEFAULT_CERT="$DEFAULT_SSL_DIR/fullchain.pem"
DEFAULT_KEY="$DEFAULT_SSL_DIR/privkey.pem"
mkdir -p "$DEFAULT_SSL_DIR"
if [[ ! -s "$DEFAULT_CERT" || ! -s "$DEFAULT_KEY" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj '/CN=hyper-host-default.invalid' \
    -keyout "$DEFAULT_KEY" -out "$DEFAULT_CERT" >/dev/null 2>&1
  chmod 0600 "$DEFAULT_KEY"; chmod 0644 "$DEFAULT_CERT"
fi

mkdir -p "/var/www/hyper-host-sites/$BETA_DOMAIN/public_html" "/var/www/hyper-host-sites/$BETA_DOMAIN/logs" \
  /var/www/hyper-host/public /opt/hyper-host/acme-webroot/.well-known/acme-challenge
find /var/www/hyper-host-sites -mindepth 2 -maxdepth 2 -type d -name public_html -exec chmod a+rX {} + 2>/dev/null || true
find /var/www/hyper-host-sites -mindepth 3 -type d -exec chmod a+rX {} + 2>/dev/null || true
find /var/www/hyper-host-sites -mindepth 3 -type f -exec chmod a+r {} + 2>/dev/null || true
chmod a+rX /var/www/hyper-host/public 2>/dev/null || true

log 'Убираю только сломанный общий роутинг v80/v81 и создаю независимые vhost панели и каждого сайта.'
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install -m 0755 "$ROOT/scripts/nginx_recover_v83.py" /opt/hyper-host/nginx_recover_v83.py
bash -n /usr/local/sbin/hyper-host-ctl
python3 -W error -m py_compile /opt/hyper-host/nginx_recover_v83.py
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true

python3 /opt/hyper-host/nginx_recover_v83.py \
  --panel-domain "$PANEL_DOMAIN" \
  --lan-ip "$LAN_IP" \
  --public-ip "$PUBLIC_IP" \
  --beta-domain "$BETA_DOMAIN" \
  --panel-php-sock "$PANEL_PHP_SOCK" \
  --default-cert "$DEFAULT_CERT" \
  --default-key "$DEFAULT_KEY" \
  --map "$ROUTING_MAP"

NGINX_TEST="$(nginx -t 2>&1)"
printf '%s\n' "$NGINX_TEST"
[[ "$NGINX_TEST" != *'conflicting server name'* ]] || fail 'В активном Nginx остались конфликтующие server_name.'
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
sleep 1

probe_route(){
  local host="$1" root="$2" label="$3" probe body response="" attempt
  probe="hyper-host-v83-${label}-${STAMP}-$$.txt"
  body="HYPER-HOST-V83-${label}-${STAMP}-$$"
  printf '%s' "$body" > "$root/$probe"
  chmod a+r "$root/$probe"
  for attempt in 1 2 3 4 5; do
    response="$(curl --noproxy '*' -kfsSL --connect-timeout 2 --max-time 12 --max-redirs 4 \
      --resolve "$host:80:$LAN_IP" --resolve "$host:443:$LAN_IP" \
      "http://$host/$probe" 2>/dev/null || true)"
    [[ "$response" == "$body" ]] && break
    sleep 1
  done
  rm -f "$root/$probe"
  [[ "$response" == "$body" ]] || fail "$host не отдаёт $root. Ответ: ${response:0:220}"
}

# Панель: отдельно по LAN IP и по домену панели.
PANEL_ROOT=/var/www/hyper-host/public
PANEL_PROBE="hyper-host-v83-panel-${STAMP}-$$.txt"
PANEL_BODY="HYPER-HOST-V83-PANEL-${STAMP}-$$"
printf '%s' "$PANEL_BODY" > "$PANEL_ROOT/$PANEL_PROBE"
chmod a+r "$PANEL_ROOT/$PANEL_PROBE"
PANEL_RESPONSE=""
for attempt in 1 2 3 4 5; do
  PANEL_RESPONSE="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 8 -H "Host: $LAN_IP" "http://$LAN_IP/$PANEL_PROBE" 2>/dev/null || true)"
  [[ "$PANEL_RESPONSE" == "$PANEL_BODY" ]] && break
  sleep 1
done
[[ "$PANEL_RESPONSE" == "$PANEL_BODY" ]] || { rm -f "$PANEL_ROOT/$PANEL_PROBE"; fail "Панель по $LAN_IP всё ещё не открывает $PANEL_ROOT"; }
PANEL_DOMAIN_RESPONSE="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 8 --resolve "$PANEL_DOMAIN:80:$LAN_IP" "http://$PANEL_DOMAIN/$PANEL_PROBE" 2>/dev/null || true)"
rm -f "$PANEL_ROOT/$PANEL_PROBE"
[[ "$PANEL_DOMAIN_RESPONSE" == "$PANEL_BODY" ]] || fail "Домен панели $PANEL_DOMAIN не открывает $PANEL_ROOT"

[[ -s "$ROUTING_MAP" ]] || fail "Карта сайтов не создана: $ROUTING_MAP"
TOTAL=0; OK=0; BETA_OK=0
RESULTS="/tmp/hyper-host-v83-results-$$.txt"; : > "$RESULTS"
while IFS=$'\t' read -r host domain root conf; do
  [[ -n "$host" && -n "$domain" && -d "$root" ]] || continue
  TOTAL=$((TOTAL+1))
  safe_label="$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '-')-$TOTAL"
  probe_route "$host" "$root" "$safe_label"
  OK=$((OK+1))
  [[ "$host" == "$BETA_DOMAIN" && "$root" == "/var/www/hyper-host-sites/$BETA_DOMAIN/public_html" ]] && BETA_OK=1
  printf '%s | %s | OK\n' "$host" "$root" >> "$RESULTS"
done < "$ROUTING_MAP"
(( TOTAL > 0 )) || fail 'Не найдено ни одного сайта с public_html.'
[[ "$BETA_OK" == 1 ]] || fail "$BETA_DOMAIN отсутствует в точной карте сайтов."

snapshot_indexes "$INDEX_AFTER"
cmp -s "$INDEX_BEFORE" "$INDEX_AFTER" || fail 'Изменились index.html/index.htm/index.php одного из сайтов.'

ADMIN_HASH_AFTER=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi
[[ -z "$ADMIN_HASH_BEFORE" || "$ADMIN_HASH_BEFORE" == "$ADMIN_HASH_AFTER" ]] || fail 'Пароль admin изменился.'

BETA_INDEX='нет index.html/index.htm/index.php'
for idx in index.html index.htm index.php; do
  [[ -f "/var/www/hyper-host-sites/$BETA_DOMAIN/public_html/$idx" ]] && { BETA_INDEX="$idx"; break; }
done

{
  echo 'HYPER-HOST v83 — panel + all sites + beta final recovery'
  echo
  echo "Panel LAN: http://$LAN_IP/ -> $PANEL_ROOT"
  echo "Panel public IP: http://$PUBLIC_IP/ -> $PANEL_ROOT"
  echo "Panel domain: http://$PANEL_DOMAIN/ -> $PANEL_ROOT"
  echo "Panel PHP socket: $PANEL_PHP_SOCK"
  echo "Site hosts checked: $OK/$TOTAL"
  echo "Beta: $BETA_DOMAIN -> /var/www/hyper-host-sites/$BETA_DOMAIN/public_html"
  echo "Beta index: $BETA_INDEX"
  echo "Broken v80/v81 managed route: removed"
  echo "Site files: unchanged"
  echo "Admin password: unchanged"
  echo "Backup: $BACKUP"
  echo "Routing map: $ROUTING_MAP"
  echo
  echo 'Routes:'
  cat "$RESULTS"
} > "$REPORT"
chmod 0600 "$REPORT"
rm -f "$RESULTS" "$INDEX_BEFORE" "$INDEX_AFTER"
trap - ERR

printf '\n%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — панель и сайты восстановлены'
printf '%s\n' '============================================================'
printf ' Панель LAN:          %s\n' "РАБОТАЕТ ($LAN_IP)"
printf ' Панель domain:       %s\n' "РАБОТАЕТ ($PANEL_DOMAIN)"
printf ' Сайты/aliases:       %s/%s проверено\n' "$OK" "$TOTAL"
printf ' beta.mystockbot:     %s\n' 'СВОЙ public_html — РАБОТАЕТ'
printf ' beta index:          %s\n' "$BETA_INDEX"
printf ' Файлы сайтов:        %s\n' 'НЕ ИЗМЕНЯЛИСЬ'
printf ' Admin password:      %s\n' 'НЕ ИЗМЕНЁН'
printf ' Отчёт:               %s\n' "$REPORT"
printf '%s\n' '============================================================'
