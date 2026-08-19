#!/usr/bin/env bash
# HYPER-HOST v90: reliable boot + watchdog recovery
# Target: Ubuntu 22.04+/systemd, existing HYPER-HOST installation
#
# What it changes:
#   - replaces fragile @reboot nginx-runtime cron with a systemd dependency
#   - makes nginx wait for the writable /etc/nginx runtime bind mount
#   - enables automatic restart for nginx, MariaDB and PHP-FPM on failures
#   - creates a boot recovery + 1-minute health watchdog
#   - starts PM2/FTP/DNS/cron/SSH/certbot units when they already exist
#   - NEVER force-remounts the root filesystem read-write and NEVER repairs DB tables
#
# Safe to run repeatedly. Existing unit/drop-in files and root crontab are backed up.

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root: sudo bash $0"
  exit 1
fi

if [[ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]]; then
  echo "ERROR: this patch requires systemd."
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/hyper-host/backups/v90-autostart-${TS}"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"

log() { printf '[v90] %s\n' "$*"; }

backup_path() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    local dst="$BACKUP${p}"
    mkdir -p "$(dirname "$dst")"
    cp -a "$p" "$dst"
  fi
}

unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

enable_start_if_exists() {
  local u="$1"
  if unit_exists "$u"; then
    systemctl enable "$u" >/dev/null 2>&1 || true
    systemctl start "$u" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

log "Backup directory: $BACKUP"
crontab -l 2>/dev/null >"$BACKUP/root.crontab" || true

# ---------------------------------------------------------------------------
# 1) Self-contained nginx runtime mount helper.
#    /etc/nginx was made writable by HYPER-HOST using a bind-mounted runtime.
#    We prepare the mount only; nginx validation/reconciliation is handled later.
# ---------------------------------------------------------------------------
PREPARE_NGINX="/usr/local/sbin/hyper-host-prepare-nginx-runtime"
backup_path "$PREPARE_NGINX"

cat >"$PREPARE_NGINX" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME="/opt/hyper-host/runtime/nginx"
TARGET="/etc/nginx"
LOCK="/run/hyper-host-nginx-runtime.lock"

exec 9>"$LOCK"
flock -w 20 9

log() {
  logger -t hyper-host-nginx-runtime -- "$*" 2>/dev/null || true
  printf '[nginx-runtime] %s\n' "$*"
}

root_opts="$(findmnt -n -o OPTIONS / 2>/dev/null || true)"
if [[ ",${root_opts}," == *,ro,* ]]; then
  log "CRITICAL: root filesystem is read-only; refusing an unsafe forced remount."
  exit 70
fi

mkdir -p "$TARGET" "$RUNTIME"

# If /etc/nginx is already a mountpoint, keep it. This covers the normal
# HYPER-HOST runtime bind mount and avoids stacking duplicate bind mounts.
if mountpoint -q "$TARGET"; then
  mount -o remount,bind,rw "$TARGET" >/dev/null 2>&1 || true
else
  # First run only: seed runtime from the current nginx tree.
  # Once runtime/nginx.conf exists, runtime is considered the source of truth.
  if [[ ! -s "$RUNTIME/nginx.conf" ]]; then
    if [[ ! -s "$TARGET/nginx.conf" ]]; then
      log "ERROR: neither runtime nor /etc/nginx contains nginx.conf"
      exit 71
    fi
    cp -a "$TARGET/." "$RUNTIME/"
  fi

  mount --bind "$RUNTIME" "$TARGET"
  mount -o remount,bind,rw "$TARGET" >/dev/null 2>&1 || true
fi

probe="$TARGET/.hyper-host-write-test.$$"
if ! ( : >"$probe" ) 2>/dev/null; then
  log "ERROR: /etc/nginx is still not writable after runtime mount"
  exit 72
fi
rm -f "$probe"

log "/etc/nginx runtime is ready"
EOF
chmod 0755 "$PREPARE_NGINX"

# ---------------------------------------------------------------------------
# 2) Nginx runtime systemd unit + nginx ordering/restart policy.
# ---------------------------------------------------------------------------
RUNTIME_UNIT="/etc/systemd/system/hyper-host-nginx-runtime.service"
NGINX_DROPIN_DIR="/etc/systemd/system/nginx.service.d"
NGINX_DROPIN="$NGINX_DROPIN_DIR/hyper-host-recovery.conf"
backup_path "$RUNTIME_UNIT"
backup_path "$NGINX_DROPIN"

cat >"$RUNTIME_UNIT" <<'EOF'
[Unit]
Description=HYPER-HOST prepare writable nginx runtime
After=local-fs.target
Before=nginx.service
RequiresMountsFor=/opt/hyper-host
ConditionPathExists=/etc/nginx

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hyper-host-prepare-nginx-runtime
TimeoutStartSec=30
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$NGINX_DROPIN_DIR"
cat >"$NGINX_DROPIN" <<'EOF'
[Unit]
Requires=hyper-host-nginx-runtime.service
After=hyper-host-nginx-runtime.service network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=3s
EOF

# ---------------------------------------------------------------------------
# 3) Restart policy for DB and all installed PHP-FPM versions.
# ---------------------------------------------------------------------------
install_restart_dropin() {
  local u="$1"
  local d="/etc/systemd/system/${u}.d"
  local f="$d/hyper-host-recovery.conf"
  backup_path "$f"
  mkdir -p "$d"
  cat >"$f" <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=5s
EOF
}

DB_UNIT=""
for u in mariadb.service mysql.service; do
  if unit_exists "$u"; then
    DB_UNIT="$u"
    install_restart_dropin "$u"
    break
  fi
done

mapfile -t PHP_UNITS < <(
  systemctl list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '$1 ~ /^php[0-9]+\.[0-9]+-fpm\.service$/ {print $1}' \
    | sort -V -u
)

for u in "${PHP_UNITS[@]:-}"; do
  [[ -n "$u" ]] || continue
  install_restart_dropin "$u"
done

# ---------------------------------------------------------------------------
# 4) Health/recovery script.
# ---------------------------------------------------------------------------
HEALTH="/usr/local/sbin/hyper-host-health-repair"
backup_path "$HEALTH"

cat >"$HEALTH" <<'EOF'
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
DB=""
for u in mariadb.service mysql.service; do
  if unit_exists "$u"; then
    DB="$u"
    ensure_service "$u" || FAIL=1
    break
  fi
done

if [[ -n "$DB" ]]; then
  DBADMIN=""
  command -v mariadb-admin >/dev/null 2>&1 && DBADMIN="mariadb-admin"
  [[ -z "$DBADMIN" ]] && command -v mysqladmin >/dev/null 2>&1 && DBADMIN="mysqladmin"

  if [[ -n "$DBADMIN" ]]; then
    db_ok=0
    for _ in {1..20}; do
      if "$DBADMIN" --protocol=socket ping --silent >/dev/null 2>&1; then
        db_ok=1
        break
      fi
      sleep 1
    done
    if (( ! db_ok )); then
      log "WARN: DB ping failed; one controlled restart of $DB"
      systemctl restart "$DB" >/dev/null 2>&1 || true
      sleep 3
      if ! "$DBADMIN" --protocol=socket ping --silent >/dev/null 2>&1; then
        log "ERROR: database is still unavailable"
        FAIL=1
      fi
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
EOF
chmod 0755 "$HEALTH"

# ---------------------------------------------------------------------------
# 5) Boot recovery service + periodic watchdog.
# ---------------------------------------------------------------------------
HEALTH_UNIT="/etc/systemd/system/hyper-host-stack-restore.service"
HEALTH_TIMER="/etc/systemd/system/hyper-host-stack-restore.timer"
backup_path "$HEALTH_UNIT"
backup_path "$HEALTH_TIMER"

cat >"$HEALTH_UNIT" <<'EOF'
[Unit]
Description=HYPER-HOST stack health and recovery
After=local-fs.target network-online.target hyper-host-nginx-runtime.service
Wants=network-online.target hyper-host-nginx-runtime.service
RequiresMountsFor=/opt/hyper-host

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hyper-host-health-repair
TimeoutStartSec=120
Nice=5
EOF

cat >"$HEALTH_TIMER" <<'EOF'
[Unit]
Description=Run HYPER-HOST health recovery every minute

[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=10s
Unit=hyper-host-stack-restore.service

[Install]
WantedBy=timers.target
EOF

# ---------------------------------------------------------------------------
# 6) Remove only the old HYPER-HOST nginx @reboot cron line.
#    The new systemd dependency now owns boot ordering.
# ---------------------------------------------------------------------------
OLD_CRON="$(crontab -l 2>/dev/null || true)"
NEW_CRON="$(
  printf '%s\n' "$OLD_CRON" \
    | grep -v 'HYPER-HOST-NGINX-RUNTIME' \
    | grep -v '/opt/hyper-host/bin/hyper-host-nginx-runtime --boot' \
    || true
)"
printf '%s\n' "$NEW_CRON" | crontab -

# ---------------------------------------------------------------------------
# 7) Activate.
# ---------------------------------------------------------------------------
systemctl daemon-reload

systemctl enable hyper-host-nginx-runtime.service >/dev/null
systemctl enable hyper-host-stack-restore.timer >/dev/null

# Core services.
enable_start_if_exists cron.service || true
enable_start_if_exists bind9.service || enable_start_if_exists named.service || true
enable_start_if_exists ssh.service || enable_start_if_exists sshd.service || true

if [[ -n "$DB_UNIT" ]]; then
  systemctl enable "$DB_UNIT" >/dev/null 2>&1 || true
  systemctl start "$DB_UNIT" >/dev/null 2>&1 || true
fi

for u in "${PHP_UNITS[@]:-}"; do
  [[ -n "$u" ]] || continue
  systemctl enable "$u" >/dev/null 2>&1 || true
  systemctl start "$u" >/dev/null 2>&1 || true
done

# Ensure PM2 persistence unit exists if the panel command can generate it.
if ! unit_exists hyperbot-pm2.service && [[ -x /usr/local/sbin/hyper-host-ctl ]]; then
  /usr/local/sbin/hyper-host-ctl pm2-persist >/dev/null 2>&1 || true
  systemctl daemon-reload
fi
enable_start_if_exists hyperbot-pm2.service || true

# Re-run the FTP fixer once if present; it is the panel's own idempotent repair path.
if [[ -x /usr/local/sbin/hyper-host-ctl ]]; then
  /usr/local/sbin/hyper-host-ctl ftp-fix >/dev/null 2>&1 || true
fi

# Prepare nginx runtime before nginx start.
systemctl start hyper-host-nginx-runtime.service || true
systemctl reset-failed nginx.service hyper-host-nginx-runtime.service >/dev/null 2>&1 || true

if unit_exists nginx.service; then
  systemctl enable nginx.service >/dev/null 2>&1 || true
fi

# First full repair now, then arm watchdog.
if ! "$HEALTH"; then
  log "WARNING: first health pass found a problem. See: /var/log/hyper-host-health.log"
fi
systemctl start hyper-host-stack-restore.timer

log "Installed."
log "Backup: $BACKUP"
log "Health log: /var/log/hyper-host-health.log"
log ""
log "Status:"
systemctl --no-pager --full status \
  hyper-host-nginx-runtime.service \
  hyper-host-stack-restore.timer \
  nginx.service \
  "${DB_UNIT:-mariadb.service}" 2>/dev/null || true

log ""
log "Useful checks:"
log "  systemctl --failed"
log "  journalctl -u hyper-host-stack-restore.service -b --no-pager -n 100"
log "  tail -n 100 /var/log/hyper-host-health.log"
log "  nginx -t"
log "  findmnt /etc/nginx"
