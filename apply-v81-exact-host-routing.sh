#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/opt/hyper-host
DATA="$BASE/data/hyperhost.sqlite"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v81-exact-host-routing-$STAMP"
REPORT=/root/hyper-host-v81-exact-host-routing-report.txt
PLAN="$BASE/data/site-routing-plan.txt"
EXACT_MAP="$BASE/data/site-routing-exact.tsv"
MANAGED_CONF=/etc/nginx/sites-available/20-hyper-host-sites-managed.conf
INDEX_MANIFEST_BEFORE="/tmp/hyper-host-v81-index-before-$$.json"
INDEX_MANIFEST_AFTER="/tmp/hyper-host-v81-index-after-$$.json"
mkdir -p "$BACKUP"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; return 1; }

log "Резервная копия: $BACKUP"
[[ -f /usr/local/sbin/hyper-host-ctl ]] && cp -a /usr/local/sbin/hyper-host-ctl "$BACKUP/hyper-host-ctl"
[[ -f /opt/hyper-host/ssl-truth.py ]] && cp -a /opt/hyper-host/ssl-truth.py "$BACKUP/ssl-truth.py"
[[ -d /etc/nginx ]] && tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" . 2>/dev/null || true
[[ -f "$DATA" ]] && cp -a "$DATA" "$BACKUP/hyperhost.sqlite"

ADMIN_HASH_BEFORE=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_BEFORE="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi

snapshot_indexes(){
  local output="$1"
  python3 - "$output" <<'PYINDEX'
from pathlib import Path
import hashlib,json,sys
base=Path('/var/www/hyper-host-sites')
out={}
if base.exists():
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
PYINDEX
}

ensure_nginx_writable(){
  local test=/etc/nginx/hyper-host-v81-write-test-$$ runtime=/opt/hyper-host/runtime/nginx mount_script=/opt/hyper-host/bin/mount-nginx-runtime.sh
  if touch "$test" 2>/dev/null; then rm -f "$test"; return 0; fi
  log 'Каталог /etc/nginx read-only — подключаю существующий writable runtime из /opt.'
  mkdir -p "$runtime" /opt/hyper-host/bin
  if [[ ! -f "$runtime/nginx.conf" ]]; then
    cp -a /etc/nginx/. "$runtime/" 2>/dev/null || fail 'Не удалось скопировать текущую конфигурацию Nginx в /opt.'
  fi
  mountpoint -q /etc/nginx && umount -lf /etc/nginx 2>/dev/null || true
  mount --bind "$runtime" /etc/nginx || fail 'Не удалось подключить writable Nginx runtime.'
  touch "$test" 2>/dev/null || fail 'После bind-mount /etc/nginx всё ещё недоступен для записи.'
  rm -f "$test"
  cat > "$mount_script" <<'EOSCRIPT'
#!/usr/bin/env bash
set -e
RUNTIME=/opt/hyper-host/runtime/nginx
TARGET=/etc/nginx
mkdir -p "$RUNTIME" "$TARGET"
mountpoint -q "$TARGET" && exit 0
mount --bind "$RUNTIME" "$TARGET"
EOSCRIPT
  chmod 0755 "$mount_script"
  { crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME'; echo '@reboot /opt/hyper-host/bin/mount-nginx-runtime.sh # HYPER-HOST-NGINX-RUNTIME'; } | crontab -
}

rollback(){
  local code=$?
  trap - ERR
  printf '[HYPER-HOST] Ошибка. Возвращаю предыдущие CLI, Nginx и метаданные сайтов.\n' >&2
  [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  [[ -f "$BACKUP/ssl-truth.py" ]] && cp -a "$BACKUP/ssl-truth.py" /opt/hyper-host/ssl-truth.py
  if [[ -f "$BACKUP/nginx.tar" ]]; then
    find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    find /etc/nginx/sites-available -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    tar -C /etc/nginx -xpf "$BACKUP/nginx.tar" 2>/dev/null || true
  fi
  [[ -f "$BACKUP/hyperhost.sqlite" ]] && cp -a "$BACKUP/hyperhost.sqlite" "$DATA"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  rm -f "$INDEX_MANIFEST_BEFORE" "$INDEX_MANIFEST_AFTER"
  exit "$code"
}
trap rollback ERR

snapshot_indexes "$INDEX_MANIFEST_BEFORE"
ensure_nginx_writable

log 'Создаю точную маршрутизацию каждого домена и alias. Файлы сайтов, панель, FTP, SQL, боты и admin не изменяются.'
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install -m 0755 "$ROOT/scripts/ssl_truth.py" /opt/hyper-host/ssl-truth.py
bash -n /usr/local/sbin/hyper-host-ctl
python3 -m py_compile /opt/hyper-host/ssl-truth.py
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl 2>/dev/null || true
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl 2>/dev/null || true

/usr/local/sbin/hyper-host-ctl sites-rebuild

NGINX_TEST="$(nginx -t 2>&1)"
printf '%s\n' "$NGINX_TEST"
[[ "$NGINX_TEST" != *'conflicting server name'* ]] || fail 'В Nginx остались конфликтующие server_name'
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx

[[ -s "$PLAN" ]] || fail "План сайтов не создан: $PLAN"
[[ -s "$EXACT_MAP" ]] || fail "Точная карта доменов не создана: $EXACT_MAP"
[[ -f "$MANAGED_CONF" ]] || fail "Единый Nginx-конфиг сайтов не создан: $MANAGED_CONF"

SERVER_IP="$(awk -F= '/^SERVER_IP=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' /etc/hyper-host/hyper-host.conf 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$SERVER_IP" ]] || SERVER_IP=127.0.0.1

host_has_https(){
  local conf="$1" host="$2"
  python3 - "$conf" "$host" <<'PYHTTPS'
import re,sys
from pathlib import Path
p=Path(sys.argv[1]); host=sys.argv[2]
if not p.is_file(): raise SystemExit(1)
text=p.read_text(encoding='utf-8',errors='ignore')
for block in re.findall(r'server\s*\{.*?\n\}',text,re.S):
    if not re.search(r'\blisten\s+(?:\[::\]:)?443\b[^;]*\bssl\b',block): continue
    m=re.search(r'\bserver_name\s+([^;]+);',block)
    if m and host in m.group(1).split(): raise SystemExit(0)
raise SystemExit(1)
PYHTTPS
}

RESULTS="/tmp/hyper-host-v81-results-$$.txt"
: > "$RESULTS"
TOTAL_SITES=0
TOTAL_HOSTS=0
HTTP_OK=0
HTTPS_OK=0

while IFS='|' read -r domain aliases phpv; do
  [[ -n "$domain" ]] || continue
  TOTAL_SITES=$((TOTAL_SITES+1))
  root="/var/www/hyper-host-sites/$domain/public_html"
  conf="$MANAGED_CONF"
  [[ -d "$root" ]] || fail "Нет public_html для $domain: $root"
  [[ -f "$conf" ]] || fail "Нет единого vhost-конфига: $conf"

  probe="hyper-host-v81-probe-${STAMP}-${TOTAL_SITES}-$$.txt"
  body="HYPER-HOST-V81-${domain}-${STAMP}-$$"
  printf '%s' "$body" > "$root/$probe"
  chmod 0644 "$root/$probe"

  hosts="$domain"
  if [[ -n "$aliases" ]]; then hosts+=" ${aliases//,/ }"; fi
  for host in $hosts; do
    TOTAL_HOSTS=$((TOTAL_HOSTS+1))
    mapped="$(awk -F'|' -v h="$host" '$1==h {print $3; exit}' "$EXACT_MAP")"
    [[ "$mapped" == "$root" ]] || { rm -f "$root/$probe"; fail "$host в точной карте смотрит в '$mapped', ожидалось '$root'"; }
    python3 - "$MANAGED_CONF" "$host" "$root" <<'PYV81BLOCK' || { rm -f "$root/$probe"; fail "В Nginx нет отдельного server-блока $host -> $root"; }
import re,sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore')
host=sys.argv[2]; root=sys.argv[3]
for block in re.findall(r'server\s*\{.*?\n\}', text, re.S):
    m=re.search(r'\bserver_name\s+([^;]+);', block)
    if not m or m.group(1).strip()!=host: continue
    r=re.search(r'\broot\s+([^;]+);', block)
    if r and r.group(1).strip()==root:
        raise SystemExit(0)
raise SystemExit(1)
PYV81BLOCK
    response=""
    for addr in "$SERVER_IP" 127.0.0.1; do
      response="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 7 -H "Host: $host" "http://$addr/$probe" 2>/dev/null || true)"
      [[ "$response" == "$body" ]] && break
    done
    [[ "$response" == "$body" ]] || { rm -f "$root/$probe"; fail "HTTP $host попал не в $root. Ответ: ${response:0:220}"; }
    HTTP_OK=$((HTTP_OK+1))

    if host_has_https "$conf" "$host"; then
      response="$(curl --noproxy '*' -kfsS --connect-timeout 2 --max-time 9 --resolve "$host:443:$SERVER_IP" "https://$host/$probe" 2>/dev/null || true)"
      [[ "$response" == "$body" ]] || { rm -f "$root/$probe"; fail "HTTPS $host попал не в $root"; }
      HTTPS_OK=$((HTTPS_OK+1))
      printf '%s | HTTP OK | HTTPS OK | %s\n' "$host" "$root" >> "$RESULTS"
    else
      printf '%s | HTTP OK | HTTPS: сертификат не найден | %s\n' "$host" "$root" >> "$RESULTS"
    fi
  done
  rm -f "$root/$probe"
done < "$PLAN"

(( TOTAL_SITES > 0 )) || fail 'Не найдено ни одной папки сайта с public_html'

# Неизвестный Host не должен случайно отдавать содержимое одного из сайтов.
UNKNOWN="v81-unknown-${STAMP}-$$.invalid"
UNKNOWN_BODY="$(curl --noproxy '*' -sS --connect-timeout 2 --max-time 5 -H "Host: $UNKNOWN" "http://$SERVER_IP/" 2>/dev/null || true)"
[[ "$UNKNOWN_BODY" != *'HYPER-HOST-V81-'* ]] || fail 'Неизвестный домен попал в один из сайтов'

snapshot_indexes "$INDEX_MANIFEST_AFTER"
cmp -s "$INDEX_MANIFEST_BEFORE" "$INDEX_MANIFEST_AFTER" || fail 'Изменились index.html/index.htm/index.php одного из сайтов'

ADMIN_HASH_AFTER=""
if [[ -f "$DATA" ]] && command -v php >/dev/null 2>&1; then
  ADMIN_HASH_AFTER="$(php -r '$p=new PDO("sqlite:/opt/hyper-host/data/hyperhost.sqlite");$s=$p->prepare("SELECT password_hash FROM users WHERE username=?");$s->execute(["admin"]);echo (string)$s->fetchColumn();' 2>/dev/null || true)"
fi
[[ -z "$ADMIN_HASH_BEFORE" || "$ADMIN_HASH_BEFORE" == "$ADMIN_HASH_AFTER" ]] || fail 'Пароль admin изменился'

{
  echo 'HYPER-HOST v81 — exact host routing'
  echo
  echo "Sites: $TOTAL_SITES"
  echo "Hostnames checked over HTTP: $HTTP_OK/$TOTAL_HOSTS"
  echo "Hostnames checked over HTTPS: $HTTPS_OK"
  echo "Server IP used for local checks: $SERVER_IP"
  echo "Routing plan: $PLAN"
  echo "Exact host map: $EXACT_MAP"
  echo "Managed Nginx config: $MANAGED_CONF"
  echo "Admin password: unchanged"
  echo "Site index files: unchanged"
  echo "FTP/SQL/bots/panel files: unchanged"
  echo "Backup: $BACKUP"
  echo
  echo 'Per-host results:'
  cat "$RESULTS"
  echo
  echo 'Routing plan:'
  cat "$PLAN"
} > "$REPORT"
chmod 0600 "$REPORT"
rm -f "$RESULTS" "$INDEX_MANIFEST_BEFORE" "$INDEX_MANIFEST_AFTER"
trap - ERR

printf '\n%s\n' '============================================================'
printf '%s\n' ' HYPER-HOST — каждый домен привязан к своему public_html'
printf '%s\n' '============================================================'
printf ' Сайтов:             %s\n' "$TOTAL_SITES"
printf ' Точных Host-маршрутов:    %s\n' "$TOTAL_HOSTS"
printf ' HTTP проверено:     %s/%s\n' "$HTTP_OK" "$TOTAL_HOSTS"
printf ' HTTPS проверено:    %s\n' "$HTTPS_OK"
printf ' Файлы сайтов:       %s\n' 'НЕ ИЗМЕНЯЛИСЬ'
printf ' Admin password:     %s\n' 'НЕ ИЗМЕНЁН'
printf ' Отчёт:              %s\n' "$REPORT"
printf '%s\n' '============================================================'
