#!/usr/bin/env bash
# HYPER-HOST v91 - MariaDB watchdog hotfix
# Fixes v90 false-positive DB failures caused by mariadb-admin authentication.
# Safe to run multiple times.

set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root: sudo bash $0"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/hyper-host/backups/v91-db-watchdog-${TS}"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"

echo "[v91] Stopping v90 watchdog while applying fix..."
systemctl stop hyper-host-stack-restore.timer >/dev/null 2>&1 || true
systemctl stop hyper-host-stack-restore.service >/dev/null 2>&1 || true

if [[ -f /usr/local/sbin/hyper-host-health-repair ]]; then
  cp -a /usr/local/sbin/hyper-host-health-repair "$BACKUP/hyper-host-health-repair"
fi

cat >/usr/local/sbin/hyper-host-health-repair <<'HEALTH_EOF'
#!/usr/bin/env bash
set -u

LOCK="/run/hyper-host-health-repair.lock"
LOG="/var/log/hyper-host-health.log"
RECONCILE_STAMP="/run/hyper-host-nginx-reconcile.last"
FAIL=0

exec 9>"$LOCK"
if ! flock -n 9; then
  exit 0
fi

touch "$LOG" 2>/dev/null || true
chmod 0640 "$LOG" 2>/dev/null || true

log() {
  local msg
  msg="$(date '+%F %T') $*"
  printf '%s\n' "$msg" >>"$LOG" 2>/dev/null || true
  logger -t hyper-host-health -- "$*" 2>/dev/null || true
}

unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

ensure_service() {
  local u="$1"
  unit_exists "$u" || return 1
  systemctl enable "$u" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "$u"; then
    log "starting $u"
    systemctl start "$u" >/dev/null 2>&1 || {
      log "ERROR: could not start $u"
      return 1
    }
  fi
  return 0
}

root_opts="$(findmnt -n -o OPTIONS / 2>/dev/null || true)"
if [[ ",${root_opts}," == *,ro,* ]]; then
  log "CRITICAL: root filesystem is READ-ONLY. No forced remount attempted. Check disk/filesystem with dmesg/journalctl."
  exit 70
fi

# If the sites directory is explicitly a mountpoint in /etc/fstab, make sure
# that mount really exists. We never guess devices or rewrite /etc/fstab.
if [[ -f /etc/fstab ]] && awk '
  $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == "/var/www/hyper-host-sites" { found=1 }
  END { exit(found ? 0 : 1) }
' /etc/fstab; then
  if ! mountpoint -q /var/www/hyper-host-sites; then
    log "WARN: sites filesystem from /etc/fstab is not mounted; mounting it"
    if ! mount /var/www/hyper-host-sites >/dev/null 2>&1; then
      log "CRITICAL: could not mount /var/www/hyper-host-sites"
      FAIL=1
    fi
  fi
fi

if [[ -d /var/www/hyper-host-sites && ! -r /var/www/hyper-host-sites ]]; then
  log "CRITICAL: /var/www/hyper-host-sites is not readable"
  FAIL=1
fi

# Ensure HYPER-HOST nginx runtime bind mount is present before touching nginx.
if ! /usr/local/sbin/hyper-host-prepare-nginx-runtime >/dev/null 2>&1; then
  log "ERROR: nginx runtime preparation failed"
  FAIL=1
fi

# Database first.
#
# IMPORTANT:
# Do NOT decide that MariaDB is dead only because `mariadb-admin ping`
# returned non-zero. On many installations root SQL authentication may require
# credentials or a different auth plugin. In that case the server can be fully
# operational while `mariadb-admin ping` returns "Access denied".
#
# systemd is the primary readiness signal here. A SQL query is diagnostic only.
DB=""
for u in mariadb.service mysql.service; do
  if unit_exists "$u"; then
    DB="$u"
    break
  fi
done

if [[ -n "$DB" ]]; then
  systemctl enable "$DB" >/dev/null 2>&1 || true

  if ! systemctl is-active --quiet "$DB"; then
    log "WARN: $DB is inactive; starting it"
    systemctl start "$DB" >/dev/null 2>&1 || true

    db_active=0
    for _ in {1..20}; do
      if systemctl is-active --quiet "$DB"; then
        db_active=1
        break
      fi
      sleep 1
    done

    if (( ! db_active )); then
      log "ERROR: $DB failed to become active"
      systemctl --no-pager --full status "$DB" >>"$LOG" 2>&1 || true
      FAIL=1
    fi
  fi

  if systemctl is-active --quiet "$DB"; then
    # Optional SQL-level probe. Failure here is NOT a reason to restart a
    # systemd-active database because it may simply be root auth configuration.
    if command -v mariadb >/dev/null 2>&1; then
      if mariadb --connect-timeout=3 --protocol=socket -Nse 'SELECT 1' >/dev/null 2>&1; then
        log "database SQL probe OK ($DB)"
      else
        log "WARN: SQL probe could not authenticate, but $DB is active; database was NOT restarted"
      fi
    elif command -v mysql >/dev/null 2>&1; then
      if mysql --connect-timeout=3 --protocol=socket -Nse 'SELECT 1' >/dev/null 2>&1; then
        log "database SQL probe OK ($DB)"
      else
        log "WARN: SQL probe could not authenticate, but $DB is active; database was NOT restarted"
      fi
    else
      log "$DB is active (SQL client not installed for an additional probe)"
    fi
  fi
else
  log "ERROR: neither mariadb.service nor mysql.service exists"
  FAIL=1
fi

# Start every installed PHP-FPM service before nginx reconciliation.
mapfile -t PHP_UNITS < <(
  systemctl list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '$1 ~ /^php[0-9]+\.[0-9]+-fpm\.service$/ {print $1}' \
    | sort -V -u
)
for u in "${PHP_UNITS[@]:-}"; do
  [[ -n "$u" ]] || continue
  ensure_service "$u" || FAIL=1
done

php_sock_ok=0
for _ in {1..15}; do
  if compgen -G '/run/php/php*-fpm.sock' >/dev/null 2>&1; then
    php_sock_ok=1
    break
  fi
  sleep 1
done
if (( ! php_sock_ok )); then
  log "ERROR: no PHP-FPM socket found in /run/php"
  FAIL=1
fi

# Supporting services. Only touch units that already exist.
ensure_service cron.service || true
if ! ensure_service bind9.service; then
  ensure_service named.service || true
fi
if ! ensure_service ssh.service; then
  ensure_service sshd.service || true
fi

# PM2 bot persistence generated by HYPER-HOST.
ensure_service hyperbot-pm2.service || true

# FTP: prefer the HYPER-HOST ProFTPD service; do not start competing daemons.
for ftp_u in hyper-host-proftpd-lan.service proftpd.service hyper-host-ftp.service; do
  if unit_exists "$ftp_u"; then
    ensure_service "$ftp_u" || true
    break
  fi
done

# Certificate renewal timer, if installed.
if unit_exists certbot.timer; then
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
fi

can_reconcile() {
  local now last
  now="$(date +%s)"
  last=0
  [[ -f "$RECONCILE_STAMP" ]] && last="$(cat "$RECONCILE_STAMP" 2>/dev/null || echo 0)"
  (( now - last >= 300 ))
}

run_reconcile() {
  if ! can_reconcile; then
    return 0
  fi
  date +%s >"$RECONCILE_STAMP" 2>/dev/null || true

  if [[ -x /usr/local/sbin/hyper-host-nginx-reconcile ]]; then
    log "running HYPER-HOST nginx reconcile"
    /usr/local/sbin/hyper-host-nginx-reconcile >/dev/null 2>&1 || true
  elif [[ -x /opt/hyper-host/bin/hyper-host-nginx-runtime ]]; then
    # Fallback: use the panel's own runtime helper, but only after PHP-FPM is up.
    /opt/hyper-host/bin/hyper-host-nginx-runtime --quiet >/dev/null 2>&1 || true
  fi
}

# Validate nginx config. Reconcile only on actual config failure.
if ! nginx -t >/dev/null 2>&1; then
  log "WARN: nginx -t failed"
  run_reconcile
fi

if nginx -t >/dev/null 2>&1; then
  ensure_service nginx.service || FAIL=1
else
  log "ERROR: nginx configuration is invalid after reconcile"
  FAIL=1
fi

# Detect panel host from the panel vhost when possible.
PANEL_HOST=""
for f in \
  /etc/nginx/sites-enabled/hyper-host-panel* \
  /etc/nginx/sites-available/hyper-host-panel* \
  /etc/nginx/conf.d/hyper-host-panel*; do
  [[ -f "$f" ]] || continue
  PANEL_HOST="$(
    awk '
      $1=="server_name" {
        for (i=2;i<=NF;i++) {
          gsub(/;/,"",$i)
          if ($i !~ /^_/ && $i !~ /\*/ && $i != "") { print $i; exit }
        }
      }' "$f" 2>/dev/null
  )"
  [[ -n "$PANEL_HOST" ]] && break
done
[[ -n "$PANEL_HOST" ]] || PANEL_HOST="panel.hyper-host.pw"

if command -v curl >/dev/null 2>&1 && systemctl is-active --quiet nginx.service; then
  code="$(
    curl -k -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 3 --max-time 8 \
      -H "Host: $PANEL_HOST" http://127.0.0.1/ 2>/dev/null || true
  )"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"

  case "$code" in
    000|502|503|504)
      log "WARN: local panel health returned HTTP $code; refreshing PHP-FPM/nginx"
      for u in "${PHP_UNITS[@]:-}"; do
        [[ -n "$u" ]] || continue
        systemctl restart "$u" >/dev/null 2>&1 || true
      done
      sleep 2
      run_reconcile
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx.service >/dev/null 2>&1 || systemctl restart nginx.service >/dev/null 2>&1 || true
      fi

      code2="$(
        curl -k -sS -o /dev/null -w '%{http_code}' \
          --connect-timeout 3 --max-time 8 \
          -H "Host: $PANEL_HOST" http://127.0.0.1/ 2>/dev/null || true
      )"
      [[ "$code2" =~ ^[0-9]{3}$ ]] || code2="000"
      if [[ "$code2" == "000" || "$code2" == "502" || "$code2" == "503" || "$code2" == "504" ]]; then
        log "ERROR: panel is still unhealthy: HTTP $code2"
        FAIL=1
      fi
      ;;
    5??)
      # A generic HTTP 500 may be an application bug. Do not create restart loops.
      log "WARN: panel returned HTTP $code; infrastructure was not force-restarted"
      ;;
  esac
fi

if (( FAIL )); then
  log "health check finished with errors"
  exit 1
fi

log "health check OK"
exit 0
HEALTH_EOF

chmod 0755 /usr/local/sbin/hyper-host-health-repair

# v90 allowed unlimited DB restart attempts. Limit them so a genuinely broken
# database/filesystem cannot be hammered forever.
DB_UNIT=""
for u in mariadb.service mysql.service; do
  if systemctl cat "$u" >/dev/null 2>&1; then
    DB_UNIT="$u"
    break
  fi
done

if [[ -n "$DB_UNIT" ]]; then
  DROPIN_DIR="/etc/systemd/system/${DB_UNIT}.d"
  mkdir -p "$DROPIN_DIR"
  if [[ -f "$DROPIN_DIR/hyper-host-recovery.conf" ]]; then
    cp -a "$DROPIN_DIR/hyper-host-recovery.conf" "$BACKUP/${DB_UNIT}-hyper-host-recovery.conf"
  fi

  cat >"$DROPIN_DIR/hyper-host-recovery.conf" <<'DB_EOF'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Restart=on-failure
RestartSec=10s
DB_EOF
fi

systemctl daemon-reload
systemctl reset-failed hyper-host-stack-restore.service >/dev/null 2>&1 || true
[[ -n "$DB_UNIT" ]] && systemctl reset-failed "$DB_UNIT" >/dev/null 2>&1 || true

echo "[v91] Checking database service..."
if [[ -n "$DB_UNIT" ]]; then
  systemctl enable "$DB_UNIT" >/dev/null 2>&1 || true
  systemctl start "$DB_UNIT" >/dev/null 2>&1 || true
  systemctl --no-pager --full status "$DB_UNIT" | sed -n '1,18p' || true
else
  echo "[v91] WARNING: mariadb.service/mysql.service not found"
fi

echo "[v91] Running corrected health check once..."
if /usr/local/sbin/hyper-host-health-repair; then
  echo "[v91] Health check: OK"
else
  echo "[v91] Health check still reports a real infrastructure error."
  echo "[v91] Check: journalctl -u mariadb -b --no-pager -n 200"
fi

systemctl reset-failed hyper-host-stack-restore.service >/dev/null 2>&1 || true
systemctl enable --now hyper-host-stack-restore.timer >/dev/null 2>&1 || true

echo
echo "[v91] Installed successfully."
echo "[v91] Backup: $BACKUP"
echo "[v91] Status:"
systemctl --no-pager --full status hyper-host-stack-restore.timer 2>/dev/null | sed -n '1,15p' || true
echo
echo "[v91] Last health log:"
tail -n 30 /var/log/hyper-host-health.log 2>/dev/null || true
