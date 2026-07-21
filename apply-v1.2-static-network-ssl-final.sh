#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
LAN_IP="192.168.0.179"
PUBLIC_IP_FIXED="90.189.208.25"
CONF="/etc/hyper-host/hyper-host.conf"
BASE_DIR="/opt/hyper-host"
NETWORK_ENV="$BASE_DIR/network.env"
LE_CONFIG_DIR="$BASE_DIR/letsencrypt"
LE_WORK_DIR="$BASE_DIR/certbot-work"
LE_LOGS_DIR="$BASE_DIR/certbot-logs"
ACME_WEBROOT="$BASE_DIR/acme-webroot"
CONTROL_BIN="/usr/local/sbin/hyper-host-ctl"
HYPER_BIN="/usr/local/bin/hyper"
INSTALLER_BIN="/usr/local/sbin/hyper-host-installer"
RUNTIME_BIN="$BASE_DIR/bin/hyper-host-nginx-runtime"
RECONCILE_BIN="/usr/local/sbin/hyper-host-nginx-reconcile"
SSL_TRUTH_BIN="$BASE_DIR/ssl-truth.py"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BASE_DIR/backups/v1.2-static-network-ssl-$TIMESTAMP"
REPORT="$BASE_DIR/logs/static-network-ssl-$TIMESTAMP.txt"

log(){ printf '[HYPER-HOST] %s\n' "$*"; }
warn(){ printf '[HYPER-HOST WARNING] %s\n' "$*" >&2; }
fail(){ printf '[HYPER-HOST ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Запусти патч через sudo/root.'

REQUIRED=(
  setup.sh install.sh
  scripts/hhctl scripts/hyper scripts/hyper_nginx_runtime.sh
  scripts/nginx-reconcile-v89.sh scripts/nginx_recover_v89.py
  scripts/hyper_ftp_proftpd_fix.sh scripts/proftpd_auth_sync.py
  scripts/ssl_truth.py
)
for file in "${REQUIRED[@]}"; do
  [[ -f "$ROOT_DIR/$file" ]] || fail "Нет обязательного файла: $file"
done

bash -n "$ROOT_DIR/setup.sh"
bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/scripts/hhctl"
bash -n "$ROOT_DIR/scripts/hyper"
bash -n "$ROOT_DIR/scripts/hyper_nginx_runtime.sh"
bash -n "$ROOT_DIR/scripts/nginx-reconcile-v89.sh"
bash -n "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh"
python3 -m py_compile "$ROOT_DIR/scripts/nginx_recover_v89.py" "$ROOT_DIR/scripts/ssl_truth.py" "$ROOT_DIR/scripts/proftpd_auth_sync.py"

same_path(){
  local a b
  a="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
  b="$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")"
  [[ "$a" == "$b" ]]
}

install_if_different(){
  local mode="$1" src="$2" dst="$3"
  mkdir -p "$(dirname "$dst")"
  if same_path "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
  else
    install -m"$mode" "$src" "$dst"
  fi
}

cert_expiry_epoch(){
  local cert="$1" end
  end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
  [[ -n "$end" ]] || { echo 0; return; }
  date -d "$end" +%s 2>/dev/null || echo 0
}

lineage_valid(){
  local root="$1" lineage="$2"
  [[ -s "$root/live/$lineage/fullchain.pem" && -s "$root/live/$lineage/privkey.pem" ]] || return 1
  openssl x509 -in "$root/live/$lineage/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || return 1
  openssl pkey -in "$root/live/$lineage/privkey.pem" -noout >/dev/null 2>&1 || return 1
}

merge_certbot_state(){
  local src="$1" lineage src_epoch dst_epoch lineage_dir
  [[ -d "$src/live" && -d "$src/archive" ]] || return 0
  same_path "$src" "$LE_CONFIG_DIR" && return 0
  while IFS= read -r -d '' lineage_dir; do
    lineage="$(basename "$lineage_dir")"
    lineage_valid "$src" "$lineage" || continue
    src_epoch="$(cert_expiry_epoch "$src/live/$lineage/fullchain.pem")"
    dst_epoch=0
    if lineage_valid "$LE_CONFIG_DIR" "$lineage"; then
      dst_epoch="$(cert_expiry_epoch "$LE_CONFIG_DIR/live/$lineage/fullchain.pem")"
    fi
    (( src_epoch > dst_epoch )) || continue
    log "Возвращаю действующий SSL: $lineage"
    rm -rf "$LE_CONFIG_DIR/live/$lineage" "$LE_CONFIG_DIR/archive/$lineage"
    mkdir -p "$LE_CONFIG_DIR/live" "$LE_CONFIG_DIR/archive" "$LE_CONFIG_DIR/renewal"
    cp -a "$src/archive/$lineage" "$LE_CONFIG_DIR/archive/$lineage"
    cp -a "$src/live/$lineage" "$LE_CONFIG_DIR/live/$lineage"
    if [[ -f "$src/renewal/$lineage.conf" ]]; then
      cp -a "$src/renewal/$lineage.conf" "$LE_CONFIG_DIR/renewal/$lineage.conf"
      sed -i -E \
        "s#^archive_dir[[:space:]]*=.*#archive_dir = $LE_CONFIG_DIR/archive/$lineage#; \
         s#^cert[[:space:]]*=.*#cert = $LE_CONFIG_DIR/live/$lineage/cert.pem#; \
         s#^privkey[[:space:]]*=.*#privkey = $LE_CONFIG_DIR/live/$lineage/privkey.pem#; \
         s#^chain[[:space:]]*=.*#chain = $LE_CONFIG_DIR/live/$lineage/chain.pem#; \
         s#^fullchain[[:space:]]*=.*#fullchain = $LE_CONFIG_DIR/live/$lineage/fullchain.pem#" \
        "$LE_CONFIG_DIR/renewal/$lineage.conf" 2>/dev/null || true
    fi
  done < <(find -L "$src/live" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

log "Создаю резервную копию: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" "$BASE_DIR/logs" "$BASE_DIR/bin" "$PROJECT_DIR/scripts"
for path in "$CONF" "$NETWORK_ENV" "$CONTROL_BIN" "$HYPER_BIN" "$INSTALLER_BIN" "$RECONCILE_BIN" "$SSL_TRUTH_BIN"; do
  if [[ -e "$path" || -L "$path" ]]; then
    name="$(printf '%s' "$path" | sed 's#^/##;s#/#__#g')"
    cp -aL "$path" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
  fi
done
[[ -d "$LE_CONFIG_DIR" ]] && cp -a "$LE_CONFIG_DIR" "$BACKUP_DIR/letsencrypt" 2>/dev/null || true
[[ -d "$BASE_DIR/runtime/nginx" ]] && cp -a "$BASE_DIR/runtime/nginx" "$BACKUP_DIR/nginx-runtime" 2>/dev/null || true

log 'Устанавливаю исправленные файлы без изменения FTP-аккаунтов и данных сайтов.'
if ! same_path "$ROOT_DIR" "$PROJECT_DIR"; then
  install_if_different 0755 "$ROOT_DIR/setup.sh" "$PROJECT_DIR/setup.sh"
  install_if_different 0755 "$ROOT_DIR/install.sh" "$PROJECT_DIR/install.sh"
  for file in hhctl hyper hyper_nginx_runtime.sh nginx-reconcile-v89.sh nginx_recover_v89.py hyper_ftp_proftpd_fix.sh proftpd_auth_sync.py ssl_truth.py; do
    install_if_different 0755 "$ROOT_DIR/scripts/$file" "$PROJECT_DIR/scripts/$file"
  done
fi
install_if_different 0755 "$ROOT_DIR/scripts/hhctl" "$CONTROL_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper" "$HYPER_BIN"
install_if_different 0755 "$ROOT_DIR/setup.sh" "$INSTALLER_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper_nginx_runtime.sh" "$RUNTIME_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$RECONCILE_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$BASE_DIR/nginx_recover_v89.py"
install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$SSL_TRUTH_BIN"
install_if_different 0755 "$ROOT_DIR/scripts/hyper_ftp_proftpd_fix.sh" "$BASE_DIR/bin/hyper_ftp_proftpd_fix.sh"
install_if_different 0755 "$ROOT_DIR/scripts/proftpd_auth_sync.py" "$BASE_DIR/bin/proftpd_auth_sync.py"
ln -sfn "$HYPER_BIN" /usr/bin/hyper
ln -sfn "$CONTROL_BIN" /usr/bin/hyper-host-ctl
ln -sfn "$INSTALLER_BIN" /usr/local/bin/hyper-host-installer

log "Фиксирую сеть: LAN=$LAN_IP, WAN=$PUBLIC_IP_FIXED"
cat > "$NETWORK_ENV.tmp" <<EOFNETWORK
NETWORK_MODE="static"
STATIC_LAN_IP="$LAN_IP"
STATIC_PUBLIC_IP="$PUBLIC_IP_FIXED"
SERVER_IP="$LAN_IP"
PUBLIC_IP="$PUBLIC_IP_FIXED"
SERVER_PUBLIC_IP="$PUBLIC_IP_FIXED"
DISABLE_IP_AUTOFIX="1"
EOFNETWORK
chmod 0600 "$NETWORK_ENV.tmp"
mv -f "$NETWORK_ENV.tmp" "$NETWORK_ENV"
mkdir -p /etc/hyper-host 2>/dev/null || true
printf '%s\n' "$PUBLIC_IP_FIXED" > /etc/hyper-host/public_ip 2>/dev/null || true

OLD_PUBLIC_IP=""
if [[ -f "$CONF" ]]; then
  OLD_PUBLIC_IP="$(sed -nE 's/^PUBLIC_IP=["'"']?([^"'"'[:space:]]+).*/\1/p' "$CONF" | tail -n1 || true)"
  python3 - "$CONF" "$LAN_IP" "$PUBLIC_IP_FIXED" <<'PYCONF'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); lan=sys.argv[2]; pub=sys.argv[3]
text=p.read_text('utf-8',errors='ignore')
values={
 'SERVER_IP':lan,'PUBLIC_IP':pub,'SERVER_PUBLIC_IP':pub,
 'NETWORK_MODE':'static','STATIC_LAN_IP':lan,'STATIC_PUBLIC_IP':pub,
 'DISABLE_IP_AUTOFIX':'1'
}
for key,value in values.items():
    line=f'{key}="{value}"'
    if re.search(rf'(?m)^{re.escape(key)}=',text):
        text=re.sub(rf'(?m)^{re.escape(key)}=.*$',line,text)
    else:
        text=text.rstrip()+"\n"+line+"\n"
p.write_text(text,'utf-8')
PYCONF
else
  warn "$CONF отсутствует; статическая сеть всё равно сохранена в $NETWORK_ENV"
fi

for php_conf in /var/www/hyper-host/app/config.php /opt/hyper-host/app/config.php; do
  [[ -f "$php_conf" ]] || continue
  python3 - "$php_conf" "$LAN_IP" "$PUBLIC_IP_FIXED" <<'PYPHP'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); lan=sys.argv[2]; pub=sys.argv[3]
text=p.read_text('utf-8',errors='ignore')
text=re.sub(r"(['\"]server_ip['\"]\s*=>\s*)['\"][^'\"]*['\"]",rf"\1'{lan}'",text)
text=re.sub(r"(['\"]public_ip['\"]\s*=>\s*)['\"][^'\"]*['\"]",rf"\1'{pub}'",text)
p.write_text(text,'utf-8')
PYPHP
done

log 'Отключаю старую автоматическую подмену публичного IP.'
rm -f /etc/cron.d/hyper-host-ip-watch 2>/dev/null || true
if command -v crontab >/dev/null 2>&1; then
  current="$(crontab -l 2>/dev/null | grep -v 'ip-autofix' || true)"
  printf '%s\n' "$current" | awk 'NF' | crontab - 2>/dev/null || true
fi
systemctl reload cron 2>/dev/null || true

log 'Исправляю только старый ошибочный IP в локальных DNS-зонах HYPER-HOST.'
if [[ -n "$OLD_PUBLIC_IP" && "$OLD_PUBLIC_IP" != "$PUBLIC_IP_FIXED" && -d /etc/bind/hyper-host-zones ]]; then
  OLD_PUBLIC_IP="$OLD_PUBLIC_IP" NEW_PUBLIC_IP="$PUBLIC_IP_FIXED" python3 - <<'PYDNS'
import os,re,pathlib
old=os.environ['OLD_PUBLIC_IP']; new=os.environ['NEW_PUBLIC_IP']
for p in pathlib.Path('/etc/bind/hyper-host-zones').glob('db.*'):
    try: text=p.read_text('utf-8',errors='ignore')
    except Exception: continue
    text=text.replace('IN A '+old, 'IN A '+new).replace('ip4:'+old, 'ip4:'+new)
    # У сервера нет публичного IPv6: локально управляемые AAAA удаляем.
    text='\n'.join(line for line in text.splitlines() if not re.search(r'\sIN\s+AAAA\s',line,re.I))+'\n'
    p.write_text(text,'utf-8')
PYDNS
  systemctl restart bind9 2>/dev/null || true
fi

log 'Возвращаю действующие сертификаты из старых каталогов и резервных копий.'
mkdir -p "$LE_CONFIG_DIR" "$LE_WORK_DIR" "$LE_LOGS_DIR" "$ACME_WEBROOT/.well-known/acme-challenge"
chmod 0700 "$LE_CONFIG_DIR" "$LE_WORK_DIR" 2>/dev/null || true
chmod 0750 "$LE_LOGS_DIR" 2>/dev/null || true
rm -f "$LE_CONFIG_DIR/.certbot.lock" "$LE_WORK_DIR/.certbot.lock" "$LE_LOGS_DIR/.certbot.lock" 2>/dev/null || true
merge_certbot_state /etc/letsencrypt || true
while IFS= read -r -d '' live_dir; do
  merge_certbot_state "$(dirname "$live_dir")" || true
done < <(find "$BASE_DIR/backups" -type d -name live -print0 2>/dev/null)

log 'Убираю старые IP-vhost, созданные для ошибочно определённых адресов.'
"$RUNTIME_BIN"
for conf in /etc/nginx/sites-available/hyper-host-ip-*.conf; do
  [[ -e "$conf" ]] || continue
  [[ "$(basename "$conf")" == "hyper-host-ip-$LAN_IP.conf" ]] && continue
  rm -f "/etc/nginx/sites-enabled/$(basename "$conf")" "$conf" 2>/dev/null || true
done

ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

log 'Пересобираю Nginx: публичный IP больше не добавляется в server_name панели.'
"$RECONCILE_BIN"
nginx -t
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || fail 'Nginx не перезапустился.'

log 'Переподключаю ранее выпущенные сертификаты к сайтам.'
if ! "$CONTROL_BIN" ssl-restore-existing >"$LE_LOGS_DIR/restore-$TIMESTAMP.json" 2>"$LE_LOGS_DIR/restore-$TIMESTAMP.err"; then
  cat "$LE_LOGS_DIR/restore-$TIMESTAMP.err" >&2 2>/dev/null || true
  fail 'Не удалось переподключить существующие SSL-сертификаты.'
fi
cat "$LE_LOGS_DIR/restore-$TIMESTAMP.json"
nginx -t
systemctl reload nginx >/dev/null 2>&1 || true

log 'Проверяю локальный ACME для всех сайтов, не перевыпуская сертификаты.'
: > "$REPORT"
{
  echo 'HYPER-HOST v1.2 — STATIC NETWORK / SSL REPORT'
  echo "LAN_IP=$LAN_IP"
  echo "PUBLIC_IP=$PUBLIC_IP_FIXED"
  echo "NETWORK_MODE=static"
  echo
  echo '--- CERTIFICATES ---'
  "$HYPER_BIN" ssl status || true
  echo
  echo '--- DOMAINS ---'
} >> "$REPORT"

if [[ -d /var/www/hyper-host-sites ]]; then
  while IFS= read -r -d '' site_dir; do
    domain="$(basename "$site_dir")"
    [[ "$domain" == *.* ]] || continue
    if "$CONTROL_BIN" ssl-fix-site "$domain" >>"$REPORT" 2>&1; then
      printf '%s\tACME_LOCAL_OK\n' "$domain" >> "$REPORT"
    else
      printf '%s\tACME_LOCAL_ERROR\n' "$domain" >> "$REPORT"
    fi
    a="$(dig +short @1.1.1.1 A "$domain" 2>/dev/null | sed '/^$/d' | sort -u | paste -sd, - || true)"
    aaaa="$(dig +short @1.1.1.1 AAAA "$domain" 2>/dev/null | sed '/^$/d' | sort -u | paste -sd, - || true)"
    printf '%s\tA=%s\tAAAA=%s\n' "$domain" "${a:-NONE}" "${aaaa:-NONE}" >> "$REPORT"
  done < <(find /var/www/hyper-host-sites -mindepth 1 -maxdepth 1 -type d -print0)
fi

# Продление — только best effort: новый сертификат выпускается из панели через email.
if "$HYPER_BIN" ssl renew >>"$REPORT" 2>&1; then
  log 'Проверка продления существующих SSL выполнена.'
else
  warn "Продление существующих сертификатов сейчас не прошло. Подробности: $REPORT"
fi

# Не перенастраиваем FTP; только убеждаемся, что патч его не остановил.
if ss -ltn 2>/dev/null | grep -qE '[:.]21[[:space:]]'; then
  log 'FTP порт 21 остался активен.'
else
  warn 'FTP порт 21 сейчас не слушается. SSL-патч FTP-конфиг не изменял.'
fi

log 'Готово.'
echo
printf '  Внутренний IP:  %s\n' "$LAN_IP"
printf '  Внешний IP:     %s\n' "$PUBLIC_IP_FIXED"
printf '  Certbot config: %s\n' "$LE_CONFIG_DIR"
printf '  ACME webroot:   %s\n' "$ACME_WEBROOT"
printf '  Отчёт:          %s\n' "$REPORT"
printf '  Backup:         %s\n' "$BACKUP_DIR"
echo
printf 'Выпуск SSL: sudo hyper ssl issue DOMAIN EMAIL\n'
printf 'Проверка:   sudo hyper ssl check DOMAIN\n'
