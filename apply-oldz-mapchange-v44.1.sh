#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-mapchange-v44.1-${STAMP}"
PATCH="/tmp/oldz-mapchange-v44.1.py"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE MAP CHANGE FIX v44.1"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Plugins/FastDL/SQL/Admins/Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/4] Patch ONLY activate_map()..."
printf '%s' 'CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgc3lzCgpwID0gUGF0aChzeXMuYXJndlsxXSkKcyA9IHAucmVhZF90ZXh0KGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0ic3RyaWN0IikKCnN0YXJ0ID0gcy5maW5kKCJkZWYgYWN0aXZhdGVfbWFwKHNpZDppbnQsbWFwX25hbWU6c3RyKToiKQppZiBzdGFydCA8IDA6CiAgICByYWlzZSBTeXN0ZW1FeGl0KCJhY3RpdmF0ZV9tYXAoKSBub3QgZm91bmQiKQoKZW5kID0gcy5maW5kKCJcbmRlZiAiLCBzdGFydCArIDEwKQppZiBlbmQgPCAwOgogICAgZW5kID0gbGVuKHMpCgpuZXdfZnVuYyA9ICIiImRlZiBhY3RpdmF0ZV9tYXAoc2lkOmludCxtYXBfbmFtZTpzdHIpOgogICAgcmVxdWlyZV9yb290KCkKICAgIGM9bG9hZF9zZXJ2ZXIoc2lkKQoKICAgIGlmIG5vdCBTQUZFX01BUC5mdWxsbWF0Y2gobWFwX25hbWUpOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignSW52YWxpZCBtYXAnKQoKICAgIGJzcD1QYXRoKGNbJ3BhdGgnXSkvJ2NzdHJpa2UvbWFwcycvKG1hcF9uYW1lKycuYnNwJykKICAgIGlmIG5vdCBic3AuaXNfZmlsZSgpOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcihmJ01hcCBpcyBub3QgaW5zdGFsbGVkIG9uIHRoaXMgc2VydmVyOiB7bWFwX25hbWV9JykKCiAgICAjIFBlcnNpc3Qgc2VsZWN0ZWQgbWFwIGltbWVkaWF0ZWx5LgogICAgX3BlcnNpc3Rfc3RhcnRfbWFwKGMsbWFwX25hbWUpCiAgICBkYl91cGRhdGVfY3VycmVudF9tYXAoc2lkLG1hcF9uYW1lKQoKICAgICMgSWYgc2VydmVyIGlzIGRvd24sIHJlcXVlc3QgYSBub3JtYWwgcmVzdGFydCBhbmQgcmV0dXJuIGltbWVkaWF0ZWx5LgogICAgaWYgc2VydmljZV9zdGF0dXMoc2lkKSE9J2FjdGl2ZScgb3Igbm90IHVkcF9saXN0ZW5pbmcoaW50KGNbJ3BvcnQnXSkpOgogICAgICAgIHJ1bihbJ3N5c3RlbWN0bCcsJ3Jlc2V0LWZhaWxlZCcsZidoeXBlci1jczE2QHtzaWR9LnNlcnZpY2UnXSxjaGVjaz1GYWxzZSkKICAgICAgICBydW4oWydzeXN0ZW1jdGwnLCdyZXN0YXJ0JyxmJ2h5cGVyLWNzMTZAe3NpZH0uc2VydmljZSddLGNoZWNrPUZhbHNlKQogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICdvayc6VHJ1ZSwKICAgICAgICAgICAgJ21hcCc6bWFwX25hbWUsCiAgICAgICAgICAgICdjdXJyZW50X21hcCc6bWFwX25hbWUsCiAgICAgICAgICAgICdtb2RlJzoncmVzdGFydF9yZXF1ZXN0ZWQnLAogICAgICAgICAgICAnbG9hZGluZyc6VHJ1ZSwKICAgICAgICAgICAgJ21lc3NhZ2UnOidTZXJ2ZXIgcmVzdGFydCByZXF1ZXN0ZWQgZm9yIHNlbGVjdGVkIG1hcCcKICAgICAgICB9CgogICAgIyBBdm9pZCBuZWVkbGVzcyBjaGFuZ2VsZXZlbCBpZiBhbHJlYWR5IGFjdGl2ZS4KICAgIHRyeToKICAgICAgICBjdXJyZW50LF89cmNvbl9jdXJyZW50X21hcChjKQogICAgICAgIGlmIGN1cnJlbnQ9PW1hcF9uYW1lOgogICAgICAgICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgJ29rJzpUcnVlLAogICAgICAgICAgICAgICAgJ21hcCc6bWFwX25hbWUsCiAgICAgICAgICAgICAgICAnY3VycmVudF9tYXAnOm1hcF9uYW1lLAogICAgICAgICAgICAgICAgJ21vZGUnOidhbHJlYWR5X2FjdGl2ZScsCiAgICAgICAgICAgICAgICAnbG9hZGluZyc6RmFsc2UKICAgICAgICAgICAgfQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCgogICAgIyBGaXJlIGNoYW5nZWxldmVsIHdpdGggYSBzaG9ydCBSQ09OIHRpbWVvdXQuCiAgICAjIExvc2luZyB0aGUgUkNPTiByZXNwb25zZSBkdXJpbmcgbGV2ZWwgdHJhbnNpdGlvbiBpcyBub3JtYWwuCiAgICB3YXJuaW5nPScnCiAgICB0cnk6CiAgICAgICAgcXVlcnlfcmNvbigKICAgICAgICAgICAgcXVlcnlfaG9zdChjKSwKICAgICAgICAgICAgaW50KGNbJ3BvcnQnXSksCiAgICAgICAgICAgIHN0cihjLmdldCgncmNvbl9wYXNzd29yZCcsJycpKSwKICAgICAgICAgICAgJ2NoYW5nZWxldmVsICcrbWFwX25hbWUsCiAgICAgICAgICAgIDEuMgogICAgICAgICkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOgogICAgICAgIHdhcm5pbmc9c3RyKGV4YykKCiAgICAjIFNob3J0IHZlcmlmaWNhdGlvbiBvbmx5LiBORVZFUiBydW4gZ2VuZXJpYyByZWNvdmVyeSwgcGx1Z2luIHF1YXJhbnRpbmUsCiAgICAjIHJvbGxiYWNrIG9yIGxvbmcgd2FpdHMgZnJvbSBhIHdlYiBtYXAtY2hhbmdlIHJlcXVlc3QuCiAgICBkZWFkbGluZT10aW1lLnRpbWUoKSs0LjAKICAgIGxhc3Rfc2Vlbj0nJwogICAgd2hpbGUgdGltZS50aW1lKCk8ZGVhZGxpbmU6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBpZiBzZXJ2aWNlX3N0YXR1cyhzaWQpPT0nYWN0aXZlJyBhbmQgdWRwX2xpc3RlbmluZyhpbnQoY1sncG9ydCddKSk6CiAgICAgICAgICAgICAgICBxaSxxZXJyPXF1ZXJ5X2luZm9fcmV0cnkoaW50KGNbJ3BvcnQnXSksMSkKICAgICAgICAgICAgICAgIGlmIHFpOgogICAgICAgICAgICAgICAgICAgIGxhc3Rfc2Vlbj1zdHIocWkuZ2V0KCdtYXAnKSBvciAnJykKICAgICAgICAgICAgICAgICAgICBpZiBsYXN0X3NlZW49PW1hcF9uYW1lOgogICAgICAgICAgICAgICAgICAgICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgICAgICAgICAgICAgJ29rJzpUcnVlLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgJ21hcCc6bWFwX25hbWUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAnY3VycmVudF9tYXAnOm1hcF9uYW1lLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgJ21vZGUnOidjaGFuZ2VsZXZlbCcsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAnbG9hZGluZyc6RmFsc2UsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAndmVyaWZpZWRfYnknOidhMnMnLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgJ3dhcm5pbmcnOndhcm5pbmcKICAgICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHBhc3MKICAgICAgICB0aW1lLnNsZWVwKC4yNSkKCiAgICByZXR1cm4gewogICAgICAgICdvayc6VHJ1ZSwKICAgICAgICAnbWFwJzptYXBfbmFtZSwKICAgICAgICAnY3VycmVudF9tYXAnOm1hcF9uYW1lLAogICAgICAgICdtb2RlJzonY2hhbmdlbGV2ZWwnLAogICAgICAgICdsb2FkaW5nJzpUcnVlLAogICAgICAgICdsYXN0X3NlZW5fbWFwJzpsYXN0X3NlZW4sCiAgICAgICAgJ3dhcm5pbmcnOndhcm5pbmcsCiAgICAgICAgJ21lc3NhZ2UnOidNYXAgY2hhbmdlIGFjY2VwdGVkOyBzZXJ2ZXIgaXMgZmluaXNoaW5nIG1hcCBsb2FkJwogICAgfQoKIiIiCgpzID0gc1s6c3RhcnRdICsgbmV3X2Z1bmMgKyBzW2VuZDpdCnAud3JpdGVfdGV4dChzLCBlbmNvZGluZz0idXRmLTgiKQpwcmludCgiYWN0aXZhdGVfbWFwKCkgcmVwbGFjZWQgc3VjY2Vzc2Z1bGx5IikK' | base64 -d > "$PATCH"
python3 -m py_compile "$PATCH"
python3 "$PATCH" "$CTL"

echo "[2/4] Validate controller..."
python3 -m py_compile "$CTL"

echo "[3/4] Install validated controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[4/4] Verify server status WITHOUT changing map..."
"$LIVE" status "$SID"

rm -f "$PATCH"

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE MAP CHANGE v44.1"
echo "================================================================"
echo " changelevel request: short"
echo " panel long timeout: removed"
echo " slow map loading: returns loading=true"
echo " recovery/quarantine/rollback on map switch: disabled"
echo " Other systems: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
