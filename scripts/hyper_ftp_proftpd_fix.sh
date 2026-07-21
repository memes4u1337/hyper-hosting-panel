#!/usr/bin/env bash
set -Eeuo pipefail

CONF="${HYPER_HOST_CONF:-/etc/hyper-host/hyper-host.conf}"
[[ -f "$CONF" ]] && source "$CONF" || true

BASE_DIR="${BASE_DIR:-/opt/hyper-host}"
FTP_DIR="${FTP_DIR:-/var/www/hyper-host-ftp}"
FTP_AUTH_TXT="${FTP_AUTH_TXT:-$BASE_DIR/data/vsftpd_virtual_users.txt}"
FTP_USER_CONF_DIR="${FTP_USER_CONF_DIR:-$BASE_DIR/ftp/user_conf}"
PROFTPD_DIR="${PROFTPD_DIR:-$BASE_DIR/proftpd}"
AUTH_SYNC="${PROFTPD_AUTH_SYNC:-$BASE_DIR/bin/proftpd_auth_sync.py}"
PASSWD_FILE="$PROFTPD_DIR/ftpd.passwd"
GROUP_FILE="$PROFTPD_DIR/ftpd.group"
TLS_DIR="$PROFTPD_DIR/tls"
TLS_CERT="$TLS_DIR/hyper-host-ftp.crt"
TLS_KEY="$TLS_DIR/hyper-host-ftp.key"
LAN_CONF="$PROFTPD_DIR/proftpd-lan.conf"
WAN_CONF="$PROFTPD_DIR/proftpd-wan.conf"
LAN_SERVICE="hyper-host-proftpd-lan.service"
WAN_SERVICE="hyper-host-proftpd-wan.service"
LAN_PORT=21
WAN_PORT=2121
LAN_PASV_MIN=40000
LAN_PASV_MAX=40049
WAN_PASV_MIN=40050
WAN_PASV_MAX=40100

log(){ printf '[HYPER-HOST FTP] %s\n' "$*"; }
warn(){ printf '[HYPER-HOST FTP WARNING] %s\n' "$*" >&2; }
fail(){ printf '[HYPER-HOST FTP ERROR] %s\n' "$*" >&2; exit 1; }

extract_ipv4(){ grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"${1:-}" | head -n1 || true; }
is_private(){ local ip="${1:-}"; [[ "$ip" =~ ^10\. || "$ip" =~ ^192\.168\. || "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. || "$ip" =~ ^127\. || "$ip" =~ ^169\.254\. ]]; }

LAN_IP="$(extract_ipv4 "${SERVER_IP:-}")"
[[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[[ -n "$LAN_IP" ]] || fail 'Не удалось определить локальный IPv4 сервера'

PUBLIC_IP_VALUE="$(extract_ipv4 "${PUBLIC_IP:-${SERVER_PUBLIC_IP:-}}")"
if [[ -z "$PUBLIC_IP_VALUE" && -f /etc/hyper-host/public_ip ]]; then
  PUBLIC_IP_VALUE="$(extract_ipv4 "$(cat /etc/hyper-host/public_ip 2>/dev/null || true)")"
fi
if [[ -z "$PUBLIC_IP_VALUE" ]]; then
  PUBLIC_IP_VALUE="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  PUBLIC_IP_VALUE="$(extract_ipv4 "$PUBLIC_IP_VALUE")"
fi
if [[ -z "$PUBLIC_IP_VALUE" ]] || is_private "$PUBLIC_IP_VALUE"; then
  PUBLIC_IP_VALUE="$LAN_IP"
  warn "Публичный IP не найден — временно используется $LAN_IP"
fi

LAN_CIDR="${LAN_IP%.*}.0/24"
UID_VALUE="$(id -u www-data 2>/dev/null || echo 33)"
GID_VALUE="$(id -g www-data 2>/dev/null || echo 33)"

export DEBIAN_FRONTEND=noninteractive
if ! command -v proftpd >/dev/null 2>&1; then
  log 'Устанавливаю ProFTPD и поддержку TLS...'
  apt-get update --allow-releaseinfo-change >/dev/null
  apt-get install -y proftpd-basic lftp openssl >/dev/null
  apt-get install -y proftpd-mod-crypto >/dev/null 2>&1 || true
fi
command -v proftpd >/dev/null 2>&1 || fail 'ProFTPD не установлен'
command -v openssl >/dev/null 2>&1 || fail 'OpenSSL не установлен'
[[ -x "$AUTH_SYNC" ]] || fail "Не найден генератор FTP-пользователей: $AUTH_SYNC"

mkdir -p "$PROFTPD_DIR" "$TLS_DIR" "$FTP_DIR" "$FTP_USER_CONF_DIR" "$(dirname "$FTP_AUTH_TXT")" /var/log
[[ -f "$FTP_AUTH_TXT" ]] || touch "$FTP_AUTH_TXT"
chmod 0600 "$FTP_AUTH_TXT" 2>/dev/null || true
chmod 0755 "$FTP_DIR" "$FTP_USER_CONF_DIR" 2>/dev/null || true

if [[ ! -s "$TLS_CERT" || ! -s "$TLS_KEY" ]]; then
  log 'Создаю локальный TLS-сертификат для FTP...'
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=HYPER-HOST FTP" \
    -keyout "$TLS_KEY" -out "$TLS_CERT" >/dev/null 2>&1
  chmod 0600 "$TLS_KEY"
  chmod 0644 "$TLS_CERT"
fi

"$AUTH_SYNC" \
  --auth-text "$FTP_AUTH_TXT" \
  --user-conf-dir "$FTP_USER_CONF_DIR" \
  --ftp-dir "$FTP_DIR" \
  --passwd-file "$PASSWD_FILE" \
  --group-file "$GROUP_FILE" \
  --uid "$UID_VALUE" --gid "$GID_VALUE" --group-name www-data >/dev/null

write_config(){
  local path="$1" name="$2" port="$3" pasv_min="$4" pasv_max="$5" pasv_ip="$6" log_suffix="$7"
  local modules_line=""
  [[ -f /etc/proftpd/modules.conf ]] && modules_line="Include /etc/proftpd/modules.conf"
  cat > "$path" <<EOCONF
$modules_line
ServerType standalone
ServerName "$name"
DefaultServer on
UseIPv6 off
DefaultAddress 0.0.0.0
Port $port
User nobody
Group nogroup
Umask 002 002
MaxInstances 40
TimeoutNoTransfer 600
TimeoutStalled 600
TimeoutIdle 1200

AuthOrder mod_auth_file.c
AuthUserFile $PASSWD_FILE
AuthGroupFile $GROUP_FILE
RequireValidShell off
UseFtpUsers off
DefaultRoot ~

AllowOverwrite on
AllowRetrieveRestart on
AllowStoreRestart on
PassivePorts $pasv_min $pasv_max
MasqueradeAddress $pasv_ip

SystemLog /var/log/hyper-host-proftpd-${log_suffix}.log
TransferLog /var/log/hyper-host-proftpd-${log_suffix}-transfer.log

<IfModule mod_tls.c>
  TLSEngine on
  TLSLog /var/log/hyper-host-proftpd-${log_suffix}-tls.log
  TLSProtocol TLSv1.2
  TLSRSACertificateFile $TLS_CERT
  TLSRSACertificateKeyFile $TLS_KEY
  TLSRequired off
  TLSOptions NoSessionReuseRequired
</IfModule>

<Directory ~>
  AllowOverwrite on
  <Limit ALL>
    AllowAll
  </Limit>
</Directory>
EOCONF
}

write_config "$LAN_CONF" 'HYPER-HOST FTP LAN' "$LAN_PORT" "$LAN_PASV_MIN" "$LAN_PASV_MAX" "$LAN_IP" lan
write_config "$WAN_CONF" 'HYPER-HOST FTP WAN' "$WAN_PORT" "$WAN_PASV_MIN" "$WAN_PASV_MAX" "$PUBLIC_IP_VALUE" wan

validate_proftpd_config(){
  local conf="$1" label="$2" output directive attempt
  for attempt in $(seq 1 20); do
    if output="$(proftpd -t -c "$conf" 2>&1)"; then
      return 0
    fi
    directive="$(printf '%s\n' "$output" | sed -n "s/.*unknown configuration directive '\([^']*\)'.*/\1/p" | head -n1)"
    if [[ -n "$directive" ]]; then
      warn "$label: ProFTPD не поддерживает директиву $directive — удаляю её из сгенерированного конфига"
      sed -i -E "/^[[:space:]]*${directive}([[:space:]]|$)/d" "$conf"
      continue
    fi
    printf '%s\n' "$output" >&2
    fail "$label-конфигурация ProFTPD не прошла проверку"
  done
  fail "$label-конфигурация ProFTPD не прошла проверку после автоматической очистки"
}

validate_proftpd_config "$LAN_CONF" 'LAN'
validate_proftpd_config "$WAN_CONF" 'WAN'

# Удаляем конфликтующий встроенный FTP runtime из предыдущей установки.
systemctl stop hyper-host-ftp.service hyper-host-ftp-lan.service hyper-host-ftp-wan.service >/dev/null 2>&1 || true
systemctl disable hyper-host-ftp.service hyper-host-ftp-lan.service hyper-host-ftp-wan.service >/dev/null 2>&1 || true
pkill -f 'hyper_ftp_server.py|hyper-host-ftp-server' >/dev/null 2>&1 || true
systemctl stop vsftpd.service >/dev/null 2>&1 || true
systemctl disable vsftpd.service >/dev/null 2>&1 || true
systemctl unmask proftpd.service >/dev/null 2>&1 || true
systemctl stop proftpd.service >/dev/null 2>&1 || true
systemctl disable proftpd.service >/dev/null 2>&1 || true

SERVICE_DIR=/etc/systemd/system
if ! mkdir -p "$SERVICE_DIR" 2>/dev/null || ! ( : > "$SERVICE_DIR/.hyper-host-write-test" ) 2>/dev/null; then
  SERVICE_DIR=/run/systemd/system
  mkdir -p "$SERVICE_DIR"
else
  rm -f "$SERVICE_DIR/.hyper-host-write-test"
fi

PROFTPD_BIN="$(command -v proftpd)"
cat > "$SERVICE_DIR/$LAN_SERVICE" <<EOSVC
[Unit]
Description=HYPER-HOST ProFTPD LAN
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PROFTPD_BIN --nodaemon --config $LAN_CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOSVC

cat > "$SERVICE_DIR/$WAN_SERVICE" <<EOSVC
[Unit]
Description=HYPER-HOST ProFTPD WAN backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PROFTPD_BIN --nodaemon --config $WAN_CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOSVC

systemctl daemon-reload
systemctl enable "$LAN_SERVICE" "$WAN_SERVICE" >/dev/null 2>&1 || true
systemctl restart "$LAN_SERVICE"
systemctl restart "$WAN_SERVICE"

# Внешние клиенты с публичными адресами отправляются на WAN backend,
# локальные клиенты из домашней сети остаются на порту 21 LAN backend.
if command -v iptables >/dev/null 2>&1; then
  while iptables -t nat -C PREROUTING -p tcp --dport "$LAN_PORT" ! -s "$LAN_CIDR" -j REDIRECT --to-ports "$WAN_PORT" >/dev/null 2>&1; do
    iptables -t nat -D PREROUTING -p tcp --dport "$LAN_PORT" ! -s "$LAN_CIDR" -j REDIRECT --to-ports "$WAN_PORT" >/dev/null 2>&1 || break
  done
  if [[ "$PUBLIC_IP_VALUE" != "$LAN_IP" ]]; then
    iptables -t nat -I PREROUTING 1 -p tcp --dport "$LAN_PORT" ! -s "$LAN_CIDR" -j REDIRECT --to-ports "$WAN_PORT"
  fi
fi

ufw allow 21/tcp >/dev/null 2>&1 || true
ufw allow 2121/tcp >/dev/null 2>&1 || true
ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
iptables -C INPUT -p tcp --dport 21 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 21 -j ACCEPT >/dev/null 2>&1 || true
iptables -C INPUT -p tcp --dport 2121 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 2121 -j ACCEPT >/dev/null 2>&1 || true
iptables -C INPUT -p tcp --match multiport --dports 40000:40100 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --match multiport --dports 40000:40100 -j ACCEPT >/dev/null 2>&1 || true

# Если /etc read-only и units установлены в /run, восстановим их после перезагрузки.
if command -v crontab >/dev/null 2>&1; then
  CURRENT_CRON="$(crontab -l 2>/dev/null | grep -v 'HYPER-HOST-FTP-RESTORE' || true)"
  {
    printf '%s\n' "$CURRENT_CRON"
    printf '@reboot sleep 20 && /usr/local/sbin/hyper-host-ctl ftp-fix >>/var/log/hyper-host-ftp-restore.log 2>&1 # HYPER-HOST-FTP-RESTORE\n'
  } | awk 'NF' | crontab -
fi

sleep 1
systemctl is-active --quiet "$LAN_SERVICE" || fail 'LAN FTP-сервис не запустился'
systemctl is-active --quiet "$WAN_SERVICE" || fail 'WAN FTP-сервис не запустился'
ss -H -lntp 'sport = :21' 2>/dev/null | grep -q proftpd || fail 'Порт 21 не слушается ProFTPD'
ss -H -lntp 'sport = :2121' 2>/dev/null | grep -q proftpd || fail 'Порт 2121 не слушается ProFTPD'

log "FTP восстановлен: LAN $LAN_IP:21, WAN $PUBLIC_IP_VALUE:21"
log "Passive: LAN $LAN_PASV_MIN-$LAN_PASV_MAX, WAN $WAN_PASV_MIN-$WAN_PASV_MAX"
log 'FileZilla: Protocol FTP, Encryption explicit TLS или plain FTP, Passive mode'
