#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[HYPER-HOST] Запусти через sudo/root'; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${1:-beta.mystockbot.xyz}"
BASE=/opt/hyper-host
CONF=/etc/hyper-host/hyper-host.conf
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/v89-ssl-acme-nginx-$STAMP"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
fail(){ printf '[HYPER-HOST] ERROR: %s\n' "$*" >&2; exit 1; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_domain "$DOMAIN" || fail "Некорректный домен: $DOMAIN"
[[ -f "$CONF" ]] || fail "Не найден конфиг $CONF"

ensure_nginx_writable(){
  local probe="/etc/nginx/.hyper-host-v89-write-test-$$" runtime="$BASE/runtime/nginx"
  if touch "$probe" 2>/dev/null; then rm -f "$probe"; return 0; fi
  log 'Раздел /etc/nginx недоступен для записи, подключаю writable runtime.'
  mkdir -p "$runtime" /etc/nginx "$BASE/bin"
  [[ -f "$runtime/nginx.conf" ]] || cp -a /etc/nginx/. "$runtime/" 2>/dev/null || true
  mountpoint -q /etc/nginx && umount -lf /etc/nginx 2>/dev/null || true
  mount --bind "$runtime" /etc/nginx
  touch "$probe" || fail 'Не удалось сделать /etc/nginx доступным для записи'
  rm -f "$probe"
  cat > "$BASE/bin/mount-nginx-runtime.sh" <<'EOS'
#!/usr/bin/env bash
set -e
mkdir -p /opt/hyper-host/runtime/nginx /etc/nginx
mountpoint -q /etc/nginx || mount --bind /opt/hyper-host/runtime/nginx /etc/nginx
EOS
  chmod 0755 "$BASE/bin/mount-nginx-runtime.sh"
  { crontab -l 2>/dev/null | grep -v 'HYPER-HOST-NGINX-RUNTIME' || true; echo '@reboot /opt/hyper-host/bin/mount-nginx-runtime.sh # HYPER-HOST-NGINX-RUNTIME'; } | crontab -
}

ensure_nginx_writable
mkdir -p "$BACKUP" "$BASE/acme-webroot/.well-known/acme-challenge" /var/log/nginx /var/log/letsencrypt
chmod -R a+rX "$BASE/acme-webroot"
chown -R www-data:www-data "$BASE/acme-webroot" 2>/dev/null || true

tar -C /etc/nginx -cpf "$BACKUP/nginx.tar" .
for file in /usr/local/sbin/hyper-host-ctl /usr/local/sbin/hyper-host-nginx-reconcile /opt/hyper-host/nginx_recover_v88.py /opt/hyper-host/nginx_recover_v89.py; do
  [[ -f "$file" ]] && cp -a "$file" "$BACKUP/$(basename "$file")"
done

COMMITTED=0
rollback(){
  local code=$?
  trap - ERR
  if [[ "$COMMITTED" == 1 ]]; then
    printf '[HYPER-HOST] Nginx уже восстановлен; ошибка относится к локальной проверке домена %s.\n' "$DOMAIN" >&2
    exit "$code"
  fi
  printf '[HYPER-HOST] Ошибка установки v89. Возвращаю предыдущие файлы Nginx.\n' >&2
  find /etc/nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  tar -C /etc/nginx -xpf "$BACKUP/nginx.tar" 2>/dev/null || true
  [[ -f "$BACKUP/hyper-host-ctl" ]] && install -m 0755 "$BACKUP/hyper-host-ctl" /usr/local/sbin/hyper-host-ctl
  [[ -f "$BACKUP/hyper-host-nginx-reconcile" ]] && install -m 0755 "$BACKUP/hyper-host-nginx-reconcile" /usr/local/sbin/hyper-host-nginx-reconcile
  nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true
  exit "$code"
}
trap rollback ERR

log 'Устанавливаю безопасный Nginx reconcile и единый ACME webroot.'
install -m 0755 "$ROOT/scripts/nginx_recover_v89.py" /opt/hyper-host/nginx_recover_v89.py
install -m 0755 "$ROOT/scripts/nginx-reconcile-v89.sh" /usr/local/sbin/hyper-host-nginx-reconcile
install -m 0755 "$ROOT/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install -m 0755 "$ROOT/scripts/hyper" /usr/local/bin/hyper
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper-host-ctl
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl
ln -sfn /usr/local/bin/hyper /usr/bin/hyper

python3 -m py_compile /opt/hyper-host/nginx_recover_v89.py
bash -n /usr/local/sbin/hyper-host-nginx-reconcile
bash -n /usr/local/sbin/hyper-host-ctl
bash -n /usr/local/bin/hyper

if ! command -v certbot >/dev/null 2>&1; then
  log 'Устанавливаю certbot.'
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot >/dev/null
fi
command -v certbot >/dev/null 2>&1 || fail 'certbot не установлен'
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

log 'Пересобираю только управляемые vhost и проверяю nginx -t.'
/usr/local/sbin/hyper-host-nginx-reconcile
NGINX_TEST="$(nginx -t 2>&1)" || { printf '%s\n' "$NGINX_TEST" >&2; fail 'Nginx не прошёл проверку после v89'; }
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
COMMITTED=1

log "Проверяю реальный локальный ACME challenge для $DOMAIN."
/usr/local/sbin/hyper-host-ctl ssl-fix-site "$DOMAIN"
CHECK_JSON="$(/usr/local/sbin/hyper-host-ctl ssl-check-json "$DOMAIN")"
printf '%s' "$CHECK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("nginx_ok"), d.get("problem"); assert d.get("http_challenge_ok"), d.get("problem"); assert d.get("site_exists"), d.get("problem")'

trap - ERR
log 'v89 установлен: nginx -t проходит, ACME локально отдаётся из единого webroot.'
printf '\nГотово. В панели снова нажми «Выпустить SSL» для %s.\n' "$DOMAIN"
printf 'CLI-команда: sudo hyper ssl issue %s YOUR_EMAIL\n' "$DOMAIN"
printf 'Резервная копия: %s\n' "$BACKUP"
