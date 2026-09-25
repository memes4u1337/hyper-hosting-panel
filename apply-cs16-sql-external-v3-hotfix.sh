#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
SRC="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-sql-external-v3-hotfix-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -f "$SRC" ]] || { echo "[ERROR] missing $SRC"; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/hyper-cs16-ctl.repo"
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live"

PATCHER="$(mktemp)"
echo 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgcmUsIHN5cwoKY3RsID0gUGF0aChzeXMuYXJndlsxXSkKcyA9IGN0bC5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JykKCmlmICJkZWYgaGhfc3FsX2V4dGVybmFsX2VuYWJsZSgiIG5vdCBpbiBzOgogICAgcmFpc2UgU3lzdGVtRXhpdCgiW1BBVENIIEVSUk9SXSB2MyBiYWNrZW5kIGhlbHBlciBoaF9zcWxfZXh0ZXJuYWxfZW5hYmxlKCkgaXMgbWlzc2luZy4gUmUtcnVuIHYzIHBhdGNoIHN0YWdlIGZpcnN0LiIpCgpwYXQgPSByZS5jb21waWxlKAogICAgciIoP21zKV4oP1A8aT5ccyopcT1zcFwuYWRkX3BhcnNlclwoJ3NxbC1leHRlcm5hbC1lbmFibGUnXCkuKj8iCiAgICByIig/PV5ccypxPXNwXC5hZGRfcGFyc2VyXCh8XlxzKmFyZ3M9c3BcLnBhcnNlX2FyZ3NcKFwpKSIKKQptID0gcGF0LnNlYXJjaChzKQpjYW5vbmljYWwgPSAiICAgIHE9c3AuYWRkX3BhcnNlcignc3FsLWV4dGVybmFsLWVuYWJsZScpOyBxLmFkZF9hcmd1bWVudCgnaWQnLHR5cGU9aW50KVxuIgppZiBtOgogICAgcyA9IHNbOm0uc3RhcnQoKV0gKyBjYW5vbmljYWwgKyBzW20uZW5kKCk6XQplbHNlOgogICAgYW5jaG9yID0gInE9c3AuYWRkX3BhcnNlcignc3FsLXByb3Zpc2lvbicpOyBxLmFkZF9hcmd1bWVudCgnaWQnLHR5cGU9aW50KTsgcS5hZGRfYXJndW1lbnQoJy0tcm90YXRlJyxhY3Rpb249J3N0b3JlX3RydWUnKSIKICAgIGlmIGFuY2hvciBub3QgaW4gczoKICAgICAgICByYWlzZSBTeXN0ZW1FeGl0KCJbUEFUQ0ggRVJST1JdIGNhbm5vdCBmaW5kIHNxbC1wcm92aXNpb24gcGFyc2VyIGFuY2hvciIpCiAgICBzID0gcy5yZXBsYWNlKGFuY2hvciwgYW5jaG9yICsgIlxuIiArIGNhbm9uaWNhbC5yc3RyaXAoKSwgMSkKCmRpc3BhdGNoX3BhdCA9IHJlLmNvbXBpbGUociIoP20pXig/UDxpPlxzKillbGlmIGFyZ3NcLmNtZD09J3NxbC1leHRlcm5hbC1lbmFibGUnOi4qJCIpCm0gPSBkaXNwYXRjaF9wYXQuc2VhcmNoKHMpCmlmIG06CiAgICBpbmRlbnQgPSBtLmdyb3VwKCdpJykKICAgIHJlcGwgPSBpbmRlbnQgKyAiZWxpZiBhcmdzLmNtZD09J3NxbC1leHRlcm5hbC1lbmFibGUnOiByZXN1bHQ9aGhfc3FsX2V4dGVybmFsX2VuYWJsZShhcmdzLmlkKSIKICAgIHMgPSBzWzptLnN0YXJ0KCldICsgcmVwbCArIHNbbS5lbmQoKTpdCmVsc2U6CiAgICBhbmNob3IgPSAiZWxpZiBhcmdzLmNtZD09J3NxbC1wcm92aXNpb24nOiByZXN1bHQ9c3FsX3Byb3Zpc2lvbihhcmdzLmlkLGFyZ3Mucm90YXRlKSIKICAgIGlmIGFuY2hvciBub3QgaW4gczoKICAgICAgICByYWlzZSBTeXN0ZW1FeGl0KCJbUEFUQ0ggRVJST1JdIGNhbm5vdCBmaW5kIHNxbC1wcm92aXNpb24gZGlzcGF0Y2ggYW5jaG9yIikKICAgIHMgPSBzLnJlcGxhY2UoYW5jaG9yLCBhbmNob3IgKyAiXG4gICAgICAgIGVsaWYgYXJncy5jbWQ9PSdzcWwtZXh0ZXJuYWwtZW5hYmxlJzogcmVzdWx0PWhoX3NxbF9leHRlcm5hbF9lbmFibGUoYXJncy5pZCkiLCAxKQoKbGluZXMgPSBzLnNwbGl0bGluZXMoKQpvdXQgPSBbXQpzZWVuID0gRmFsc2UKZm9yIGxpbmUgaW4gbGluZXM6CiAgICBpZiAicT1zcC5hZGRfcGFyc2VyKCdzcWwtZXh0ZXJuYWwtZW5hYmxlJykiIGluIGxpbmU6CiAgICAgICAgc2VlbiA9IFRydWUKICAgICAgICBvdXQuYXBwZW5kKGxpbmUpCiAgICAgICAgY29udGludWUKICAgIGlmIHNlZW4gYW5kIHJlLnNlYXJjaChyInFcLmFkZF9hcmd1bWVudFwoXHMqWydcIl0tLXJlbW90ZVsnXCJdIiwgbGluZSk6CiAgICAgICAgY29udGludWUKICAgIGlmIHNlZW4gYW5kICJxPXNwLmFkZF9wYXJzZXIoIiBpbiBsaW5lOgogICAgICAgIHNlZW4gPSBGYWxzZQogICAgaWYgc2VlbiBhbmQgImFyZ3M9c3AucGFyc2VfYXJncygiIGluIGxpbmU6CiAgICAgICAgc2VlbiA9IEZhbHNlCiAgICBvdXQuYXBwZW5kKGxpbmUpCgpjdGwud3JpdGVfdGV4dCgiXG4iLmpvaW4ob3V0KSArICJcbiIsIGVuY29kaW5nPSd1dGYtOCcpCg==' | base64 -d > "$PATCHER"

echo "=============================================================="
echo " SQL EXTERNAL v3 HOTFIX"
echo " Fix: old --remote parser conflict"
echo "=============================================================="

echo "[1/4] Fix repo CLI parser/dispatch..."
python3 "$PATCHER" "$SRC"

echo "[2/4] Syntax check..."
python3 -m py_compile "$SRC"

echo "[3/4] Install live controller..."
install -m 0755 "$SRC" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[4/4] Enable external SQL and verify..."
"$LIVE" sql-external-enable "$SID"
echo
"$LIVE" sql-external-status "$SID" || true
echo
ss -ltnp | grep ':3306' || true

rm -f "$PATCHER"

echo
echo "[SUCCESS] SQL EXTERNAL v3 HOTFIX INSTALLED"
echo "The command no longer requires --remote."
echo "Open: http://www.avito.hyper-host.pw/?page=sql&server_id=$SID"
echo "Backup: $BACKUP"
