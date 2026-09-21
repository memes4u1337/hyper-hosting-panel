#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.22 — ROBUST SKIP MISSING
#
# Requires installed v3.20 adaptive runtime.
# Fixes v3.21 "runtime_report anchor missing" by structural Python patching.

SID="${1:-17}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
DOMAIN="www.avito.hyper-host.pw"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.22-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.22-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die() {
  echo
  echo "[ERROR] $*"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backup: $BACKUP"
  exit 1
}

echo "============================================================"
echo " HYPER-HOST CS16 v3.22 — ROBUST SKIP MISSING"
echo "============================================================"
echo "Server:     $SID"
echo "Live ctl:   $LIVE_CTL"
echo "Repo:       $REPO"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"
grep -q "def _v320_prepare_runtime" "$LIVE_CTL" || die "v3.22 requires installed v3.20 runtime"

PATCHER="$(mktemp /tmp/hh-v322.XXXXXX.py)"
ROOTS="$(mktemp /tmp/hh-v322-roots.XXXXXX)"
NGTMP="$(mktemp /tmp/hh-v322-nginx.XXXXXX)"

cleanup_tmp() {
  rm -f "$PATCHER" "$ROOTS" "$NGTMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT

printf '%s' 'ZnJvbSBfX2Z1dHVyZV9fIGltcG9ydCBhbm5vdGF0aW9ucwoKaW1wb3J0IGFzdAppbXBvcnQgb3MKaW1wb3J0IHB5X2NvbXBpbGUKaW1wb3J0IHJlCmltcG9ydCBzeXMKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCgpNQVJLRVIgPSAnIyA+Pj4gSFlQRVItSE9TVCB2My4yMiBPUFRJT05BTCBGSUxFIFNBTklUSVpFUiA+Pj4nCgpIRUxQRVIgPSByJycnCiMgPj4+IEhZUEVSLUhPU1QgdjMuMjIgT1BUSU9OQUwgRklMRSBTQU5JVElaRVIgPj4+CmRlZiBfdjMyMl9wbHVnaW5fY29uZmlnX2ZpbGVzKGNzdHJpa2U6UGF0aCktPmxpc3RbUGF0aF06CiAgICBjZmc9Y3N0cmlrZS8nYWRkb25zL2FteG1vZHgvY29uZmlncycKICAgIGlmIG5vdCBjZmcuaXNfZGlyKCk6CiAgICAgICAgcmV0dXJuIFtdCiAgICBvdXQ9W10KICAgIG1haW49Y2ZnLydwbHVnaW5zLmluaScKICAgIGlmIG1haW4uaXNfZmlsZSgpOgogICAgICAgIG91dC5hcHBlbmQobWFpbikKICAgIG91dCArPSBzb3J0ZWQoCiAgICAgICAgKAogICAgICAgICAgICBwIGZvciBwIGluIGNmZy5nbG9iKCdwbHVnaW5zLSouaW5pJykKICAgICAgICAgICAgaWYgcC5pc19maWxlKCkgYW5kIG5vdCBwLm5hbWUuc3RhcnRzd2l0aCgnZGlzYWJsZWQtJykKICAgICAgICApLAogICAgICAgIGtleT1sYW1iZGEgcDpwLm5hbWUubG93ZXIoKQogICAgKQogICAgcmV0dXJuIG91dAoKCmRlZiBfdjMyMl9pc19jcml0aWNhbF9wbHVnaW4obmFtZTpzdHIpLT5ib29sOgogICAgbj1QYXRoKHN0cihuYW1lKSkubmFtZS5sb3dlcigpLnN0cmlwKCkKICAgIGlmIG4gaW4gewogICAgICAgICd6b21iaWVfcGxhZ3VlLmFteHgnLCd6b21iaWVfcGxhZ3VlNDAuYW14eCcsCiAgICAgICAgJ3pwX2NvcmUuYW14eCcsJ3pwNTBfY29yZS5hbXh4JywKICAgIH06CiAgICAgICAgcmV0dXJuIFRydWUKICAgIHJldHVybiBib29sKHJlLmZ1bGxtYXRjaChyJ3pvbWJpZV9wbGFndWUoPzo0MHw0Wy5fLV0/Myk/Wy5dYW14eCcsbikpCgoKZGVmIF92MzIyX3NraXBfbWlzc2luZ19vcHRpb25hbF9yZWZzKHNlcnZlcl9yb290OlBhdGgpLT5kaWN0OgogICAgY3N0cmlrZT1zZXJ2ZXJfcm9vdC8nY3N0cmlrZScKICAgIHBsdWdkaXI9Y3N0cmlrZS8nYWRkb25zL2FteG1vZHgvcGx1Z2lucycKCiAgICBtaXNzaW5nX3BsdWdpbnM9W10KICAgIGNyaXRpY2FsX21pc3Npbmc9W10KICAgIGNhc2VfZml4ZWQ9W10KICAgIG1pc3NpbmdfbWV0YT1bXQogICAgY2hhbmdlZF9maWxlcz1bXQogICAgYWN0aW9ucz1bXQoKICAgIGFjdHVhbD17fQogICAgaWYgcGx1Z2Rpci5pc19kaXIoKToKICAgICAgICBmb3IgcCBpbiBwbHVnZGlyLml0ZXJkaXIoKToKICAgICAgICAgICAgaWYgcC5pc19maWxlKCkgYW5kIHAuc3VmZml4Lmxvd2VyKCk9PScuYW14eCc6CiAgICAgICAgICAgICAgICBhY3R1YWwuc2V0ZGVmYXVsdChwLm5hbWUubG93ZXIoKSxwLm5hbWUpCgogICAgZm9yIGNmZyBpbiBfdjMyMl9wbHVnaW5fY29uZmlnX2ZpbGVzKGNzdHJpa2UpOgogICAgICAgIHJhdz1jZmcucmVhZF9ieXRlcygpLnJlcGxhY2UoYidcclxuJyxiJ1xuJykucmVwbGFjZShiJ1xyJyxiJ1xuJykuZGVjb2RlKCdsYXRpbjEnLCdpZ25vcmUnKQogICAgICAgIG91dD1bXQogICAgICAgIGNoYW5nZWQ9RmFsc2UKCiAgICAgICAgZm9yIGxpbmUgaW4gcmF3LnNwbGl0bGluZXMoKToKICAgICAgICAgICAgc3Q9bGluZS5zdHJpcCgpCiAgICAgICAgICAgIGlmIG5vdCBzdCBvciBzdC5zdGFydHN3aXRoKCgnOycsJy8vJywnIycpKToKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQobGluZSkKICAgICAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgICAgICBib2R5PXJlLnNwbGl0KHInXHMqKD86O3wvLyknLHN0LG1heHNwbGl0PTEpWzBdLnN0cmlwKCkKICAgICAgICAgICAgcGFydHM9Ym9keS5zcGxpdCgpCiAgICAgICAgICAgIHRva2VuPShwYXJ0c1swXS5zdHJpcCgnIicpIGlmIHBhcnRzIGVsc2UgJycpCgogICAgICAgICAgICBpZiBub3QgdG9rZW4ubG93ZXIoKS5lbmRzd2l0aCgnLmFteHgnKToKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQobGluZSkKICAgICAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgICAgICBuYW1lPVBhdGgodG9rZW4ucmVwbGFjZSgnXFwnLCcvJykpLm5hbWUKICAgICAgICAgICAgZXhhY3Q9cGx1Z2Rpci9uYW1lCgogICAgICAgICAgICBpZiBleGFjdC5pc19maWxlKCk6CiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKGxpbmUpCiAgICAgICAgICAgICAgICBjb250aW51ZQoKICAgICAgICAgICAgYWx0PWFjdHVhbC5nZXQobmFtZS5sb3dlcigpKQogICAgICAgICAgICBpZiBhbHQ6CiAgICAgICAgICAgICAgICBpZHg9bGluZS5maW5kKHRva2VuKQogICAgICAgICAgICAgICAgaWYgaWR4Pj0wOgogICAgICAgICAgICAgICAgICAgIGxpbmU9bGluZVs6aWR4XSthbHQrbGluZVtpZHgrbGVuKHRva2VuKTpdCiAgICAgICAgICAgICAgICAgICAgY2hhbmdlZD1UcnVlCiAgICAgICAgICAgICAgICAgICAgY2FzZV9maXhlZC5hcHBlbmQoewogICAgICAgICAgICAgICAgICAgICAgICAnY29uZmlnJzpjZmcubmFtZSwKICAgICAgICAgICAgICAgICAgICAgICAgJ2Zyb20nOnRva2VuLAogICAgICAgICAgICAgICAgICAgICAgICAndG8nOmFsdCwKICAgICAgICAgICAgICAgICAgICB9KQogICAgICAgICAgICAgICAgb3V0LmFwcGVuZChsaW5lKQogICAgICAgICAgICAgICAgY29udGludWUKCiAgICAgICAgICAgICMgQ29yZSBnYW1lcGxheSBwbHVnaW46IG5ldmVyIHNpbGVudGx5IHNraXAuCiAgICAgICAgICAgIGlmIF92MzIyX2lzX2NyaXRpY2FsX3BsdWdpbihuYW1lKToKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQobGluZSkKICAgICAgICAgICAgICAgIGNyaXRpY2FsX21pc3NpbmcuYXBwZW5kKHsKICAgICAgICAgICAgICAgICAgICAnY29uZmlnJzpjZmcubmFtZSwKICAgICAgICAgICAgICAgICAgICAncGx1Z2luJzpuYW1lLAogICAgICAgICAgICAgICAgfSkKICAgICAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgICAgICBvdXQuYXBwZW5kKCc7IEhZUEVSLUhPU1QgdjMuMjIgc2tpcHBlZCBtaXNzaW5nIG9wdGlvbmFsIHBsdWdpbjogJytsaW5lKQogICAgICAgICAgICBjaGFuZ2VkPVRydWUKICAgICAgICAgICAgbWlzc2luZ19wbHVnaW5zLmFwcGVuZCh7CiAgICAgICAgICAgICAgICAnY29uZmlnJzpjZmcubmFtZSwKICAgICAgICAgICAgICAgICdwbHVnaW4nOm5hbWUsCiAgICAgICAgICAgIH0pCgogICAgICAgIGlmIGNoYW5nZWQ6CiAgICAgICAgICAgIGNmZy53cml0ZV9ieXRlcygoJ1xuJy5qb2luKG91dCkucnN0cmlwKCkrJ1xuJykuZW5jb2RlKCdsYXRpbjEnLCdyZXBsYWNlJykpCiAgICAgICAgICAgIGNoYW5nZWRfZmlsZXMuYXBwZW5kKHN0cihjZmcucmVsYXRpdmVfdG8oY3N0cmlrZSkpKQoKICAgICMgTWlzc2luZyBvcHRpb25hbCB0aGlyZC1wYXJ0eSBNZXRhbW9kIHJlZmVyZW5jZXMuCiAgICAjIEFNWFggbG9hZGVyIGFuZCBNZXRhbW9kL0dhbWVETEwgY29yZSBhcmUgZGVsaWJlcmF0ZWx5IE5PVCBza2lwcGVkLgogICAgbXA9Y3N0cmlrZS8nYWRkb25zL21ldGFtb2QvcGx1Z2lucy5pbmknCiAgICBpZiBtcC5pc19maWxlKCk6CiAgICAgICAgcmF3PW1wLnJlYWRfYnl0ZXMoKS5yZXBsYWNlKGInXHJcbicsYidcbicpLnJlcGxhY2UoYidccicsYidcbicpLmRlY29kZSgnbGF0aW4xJywnaWdub3JlJykKICAgICAgICBvdXQ9W10KICAgICAgICBjaGFuZ2VkPUZhbHNlCgogICAgICAgIGZvciBsaW5lIGluIHJhdy5zcGxpdGxpbmVzKCk6CiAgICAgICAgICAgIHN0PWxpbmUuc3RyaXAoKQogICAgICAgICAgICBpZiBub3Qgc3Qgb3Igc3Quc3RhcnRzd2l0aCgoJzsnLCcvLycsJyMnKSk6CiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKGxpbmUpCiAgICAgICAgICAgICAgICBjb250aW51ZQoKICAgICAgICAgICAgbT1yZS5zZWFyY2gocicoP2kpXmxpbnV4KD86MzIpP1xzKyhbXlxzXStbLl1zbylcYicsc3QpCiAgICAgICAgICAgIGlmIG5vdCBtOgogICAgICAgICAgICAgICAgb3V0LmFwcGVuZChsaW5lKQogICAgICAgICAgICAgICAgY29udGludWUKCiAgICAgICAgICAgIHJlbD1tLmdyb3VwKDEpLnJlcGxhY2UoJ1xcJywnLycpLmxzdHJpcCgnLycpCiAgICAgICAgICAgIGlmICcuLicgaW4gUGF0aChyZWwpLnBhcnRzOgogICAgICAgICAgICAgICAgb3V0LmFwcGVuZChsaW5lKQogICAgICAgICAgICAgICAgY29udGludWUKCiAgICAgICAgICAgIGxvdz1yZWwubG93ZXIoKQogICAgICAgICAgICBjcml0aWNhbD0oJ2FteG1vZHgnIGluIGxvdyBvciAnbWV0YW1vZCcgaW4gbG93KQoKICAgICAgICAgICAgaWYgKGNzdHJpa2UvcmVsKS5pc19maWxlKCkgb3IgY3JpdGljYWw6CiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKGxpbmUpCiAgICAgICAgICAgICAgICBjb250aW51ZQoKICAgICAgICAgICAgb3V0LmFwcGVuZCgnOyBIWVBFUi1IT1NUIHYzLjIyIHNraXBwZWQgbWlzc2luZyBvcHRpb25hbCBNZXRhbW9kIHBsdWdpbjogJytsaW5lKQogICAgICAgICAgICBjaGFuZ2VkPVRydWUKICAgICAgICAgICAgbWlzc2luZ19tZXRhLmFwcGVuZChyZWwpCgogICAgICAgIGlmIGNoYW5nZWQ6CiAgICAgICAgICAgIG1wLndyaXRlX2J5dGVzKCgnXG4nLmpvaW4ob3V0KS5yc3RyaXAoKSsnXG4nKS5lbmNvZGUoJ2xhdGluMScsJ3JlcGxhY2UnKSkKICAgICAgICAgICAgY2hhbmdlZF9maWxlcy5hcHBlbmQoc3RyKG1wLnJlbGF0aXZlX3RvKGNzdHJpa2UpKSkKCiAgICBpZiBtaXNzaW5nX3BsdWdpbnM6CiAgICAgICAgYWN0aW9ucy5hcHBlbmQoJ3NraXBwZWQgJytzdHIobGVuKG1pc3NpbmdfcGx1Z2lucykpKycgbWlzc2luZyBvcHRpb25hbCBBTVhYIHBsdWdpbiByZWZlcmVuY2UocyknKQogICAgaWYgY2FzZV9maXhlZDoKICAgICAgICBhY3Rpb25zLmFwcGVuZCgnZml4ZWQgJytzdHIobGVuKGNhc2VfZml4ZWQpKSsnIGNhc2Utc2Vuc2l0aXZlIEFNWFggcGx1Z2luIGZpbGVuYW1lKHMpJykKICAgIGlmIG1pc3NpbmdfbWV0YToKICAgICAgICBhY3Rpb25zLmFwcGVuZCgnc2tpcHBlZCAnK3N0cihsZW4obWlzc2luZ19tZXRhKSkrJyBtaXNzaW5nIG9wdGlvbmFsIE1ldGFtb2QgcGx1Z2luIHJlZmVyZW5jZShzKScpCgogICAgcmV0dXJuIHsKICAgICAgICAnb2snOm5vdCBib29sKGNyaXRpY2FsX21pc3NpbmcpLAogICAgICAgICdtaXNzaW5nX3BsdWdpbnMnOm1pc3NpbmdfcGx1Z2lucywKICAgICAgICAnY3JpdGljYWxfbWlzc2luZ19wbHVnaW5zJzpjcml0aWNhbF9taXNzaW5nLAogICAgICAgICdjYXNlX2ZpeGVkX3BsdWdpbnMnOmNhc2VfZml4ZWQsCiAgICAgICAgJ21pc3NpbmdfbWV0YW1vZF9wbHVnaW5zJzptaXNzaW5nX21ldGEsCiAgICAgICAgJ2NoYW5nZWRfZmlsZXMnOmxpc3QoZGljdC5mcm9ta2V5cyhjaGFuZ2VkX2ZpbGVzKSksCiAgICAgICAgJ2FjdGlvbnMnOmFjdGlvbnMsCiAgICB9CgoKZGVmIF92MzIyX2ludmFsaWRfcGx1Z2luX25hbWVzKHJlcG9ydDpkaWN0KS0+bGlzdFtzdHJdOgogICAgbmFtZXM9W10KICAgIGZvciBsaW5lIGluIGxpc3QocmVwb3J0LmdldCgncGx1Z2luX2Vycm9ycycpIG9yIFtdKToKICAgICAgICB0ZXh0PXN0cihsaW5lKQogICAgICAgIGZvciBwYXQgaW4gKAogICAgICAgICAgICByJ0ludmFsaWQgUGx1Z2luXHMqXChwbHVnaW5ccysiKFteIl0rWy5dYW14eCkiXCknLAogICAgICAgICAgICByJ1BsdWdpbiBmaWxlIG9wZW4gZXJyb3JccypcKHBsdWdpblxzKyIoW14iXStbLl1hbXh4KSJcKScsCiAgICAgICAgKToKICAgICAgICAgICAgbT1yZS5zZWFyY2gocGF0LHRleHQscmUuSSkKICAgICAgICAgICAgaWYgbm90IG06CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBuYW1lPVBhdGgobS5ncm91cCgxKSkubmFtZQogICAgICAgICAgICBpZiBub3QgX3YzMjJfaXNfY3JpdGljYWxfcGx1Z2luKG5hbWUpOgogICAgICAgICAgICAgICAgbmFtZXMuYXBwZW5kKG5hbWUpCiAgICByZXR1cm4gbGlzdChkaWN0LmZyb21rZXlzKG5hbWVzKSkKCgpkZWYgX3YzMjJfcXVhcmFudGluZV9wbHVnaW5zKHNlcnZlcl9yb290OlBhdGgsbmFtZXM6bGlzdFtzdHJdLHJlYXNvbjpzdHI9J2ludmFsaWQgb3B0aW9uYWwgcGx1Z2luJyktPmRpY3Q6CiAgICBjc3RyaWtlPXNlcnZlcl9yb290Lydjc3RyaWtlJwogICAgd2FudGVkPXtQYXRoKHgpLm5hbWUubG93ZXIoKSBmb3IgeCBpbiBuYW1lcyBpZiB4fQogICAgaWYgbm90IHdhbnRlZDoKICAgICAgICByZXR1cm4geydvayc6VHJ1ZSwncGx1Z2lucyc6W10sJ2NoYW5nZWRfZmlsZXMnOltdfQoKICAgIGNoYW5nZWRfZmlsZXM9W10KICAgIGRpc2FibGVkPVtdCgogICAgZm9yIGNmZyBpbiBfdjMyMl9wbHVnaW5fY29uZmlnX2ZpbGVzKGNzdHJpa2UpOgogICAgICAgIHJhdz1jZmcucmVhZF9ieXRlcygpLnJlcGxhY2UoYidcclxuJyxiJ1xuJykucmVwbGFjZShiJ1xyJyxiJ1xuJykuZGVjb2RlKCdsYXRpbjEnLCdpZ25vcmUnKQogICAgICAgIG91dD1bXQogICAgICAgIGNoYW5nZWQ9RmFsc2UKCiAgICAgICAgZm9yIGxpbmUgaW4gcmF3LnNwbGl0bGluZXMoKToKICAgICAgICAgICAgc3Q9bGluZS5zdHJpcCgpCiAgICAgICAgICAgIGlmIG5vdCBzdCBvciBzdC5zdGFydHN3aXRoKCgnOycsJy8vJywnIycpKToKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQobGluZSkKICAgICAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgICAgICBib2R5PXJlLnNwbGl0KHInXHMqKD86O3wvLyknLHN0LG1heHNwbGl0PTEpWzBdLnN0cmlwKCkKICAgICAgICAgICAgcGFydHM9Ym9keS5zcGxpdCgpCiAgICAgICAgICAgIHRva2VuPShwYXJ0c1swXS5zdHJpcCgnIicpIGlmIHBhcnRzIGVsc2UgJycpCiAgICAgICAgICAgIG5hbWU9UGF0aCh0b2tlbi5yZXBsYWNlKCdcXCcsJy8nKSkubmFtZS5sb3dlcigpCgogICAgICAgICAgICBpZiBuYW1lIGluIHdhbnRlZDoKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQoJzsgSFlQRVItSE9TVCB2My4yMiBxdWFyYW50aW5lZCAnK3JlYXNvbisnOiAnK2xpbmUpCiAgICAgICAgICAgICAgICBjaGFuZ2VkPVRydWUKICAgICAgICAgICAgICAgIGRpc2FibGVkLmFwcGVuZChQYXRoKHRva2VuKS5uYW1lKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgb3V0LmFwcGVuZChsaW5lKQoKICAgICAgICBpZiBjaGFuZ2VkOgogICAgICAgICAgICBjZmcud3JpdGVfYnl0ZXMoKCdcbicuam9pbihvdXQpLnJzdHJpcCgpKydcbicpLmVuY29kZSgnbGF0aW4xJywncmVwbGFjZScpKQogICAgICAgICAgICBjaGFuZ2VkX2ZpbGVzLmFwcGVuZChzdHIoY2ZnLnJlbGF0aXZlX3RvKGNzdHJpa2UpKSkKCiAgICByZXR1cm4gewogICAgICAgICdvayc6VHJ1ZSwKICAgICAgICAncGx1Z2lucyc6bGlzdChkaWN0LmZyb21rZXlzKGRpc2FibGVkKSksCiAgICAgICAgJ2NoYW5nZWRfZmlsZXMnOmNoYW5nZWRfZmlsZXMsCiAgICB9CgoKZGVmIF92MzIyX3F1YXJhbnRpbmVfcnVudGltZV9iYWRfcGx1Z2lucyhzaWQ6aW50LGM6ZGljdCxwYXRoOlBhdGgscmVwb3J0OmRpY3QpLT5kaWN0OgogICAgbmFtZXM9X3YzMjJfaW52YWxpZF9wbHVnaW5fbmFtZXMocmVwb3J0KQogICAgaWYgbm90IG5hbWVzOgogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICdvayc6VHJ1ZSwKICAgICAgICAgICAgJ2NoYW5nZWQnOkZhbHNlLAogICAgICAgICAgICAncGx1Z2lucyc6W10sCiAgICAgICAgICAgICdyZXBvcnQnOnJlcG9ydCwKICAgICAgICAgICAgJ3N0YXJ0X21hcmsnOk5vbmUsCiAgICAgICAgfQoKICAgIGNmZ3M9X3YzMjJfcGx1Z2luX2NvbmZpZ19maWxlcyhwYXRoLydjc3RyaWtlJykKICAgIHNuYXBzaG90cz17c3RyKHApOnAucmVhZF9ieXRlcygpIGZvciBwIGluIGNmZ3MgaWYgcC5pc19maWxlKCl9CgogICAgcT1fdjMyMl9xdWFyYW50aW5lX3BsdWdpbnMocGF0aCxuYW1lcykKICAgIGlmIG5vdCBxLmdldCgncGx1Z2lucycpOgogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICdvayc6VHJ1ZSwKICAgICAgICAgICAgJ2NoYW5nZWQnOkZhbHNlLAogICAgICAgICAgICAncGx1Z2lucyc6W10sCiAgICAgICAgICAgICdyZXBvcnQnOnJlcG9ydCwKICAgICAgICAgICAgJ3N0YXJ0X21hcmsnOk5vbmUsCiAgICAgICAgfQoKICAgIG1hcms9dGltZS50aW1lKCkKICAgIHJ1bihbJ3N5c3RlbWN0bCcsJ3Jlc2V0LWZhaWxlZCcsZidoeXBlci1jczE2QHtzaWR9LnNlcnZpY2UnXSxjaGVjaz1GYWxzZSkKICAgIHJ1bihbJ3N5c3RlbWN0bCcsJ3Jlc3RhcnQnLGYnaHlwZXItY3MxNkB7c2lkfS5zZXJ2aWNlJ10sY2hlY2s9RmFsc2UsdGltZW91dD02MCkKCiAgICBvayxkZXRhaWw9d2FpdF9zZXJ2ZXJfcmVhZHkobG9hZF9zZXJ2ZXIoc2lkKSw0NS4wKQogICAgaWYgbm90IG9rOgogICAgICAgIGZvciBuYW1lLGRhdGEgaW4gc25hcHNob3RzLml0ZW1zKCk6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIFBhdGgobmFtZSkud3JpdGVfYnl0ZXMoZGF0YSkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHBhc3MKCiAgICAgICAgcnVuKFsnc3lzdGVtY3RsJywncmVzZXQtZmFpbGVkJyxmJ2h5cGVyLWNzMTZAe3NpZH0uc2VydmljZSddLGNoZWNrPUZhbHNlKQogICAgICAgIHJ1bihbJ3N5c3RlbWN0bCcsJ3Jlc3RhcnQnLGYnaHlwZXItY3MxNkB7c2lkfS5zZXJ2aWNlJ10sY2hlY2s9RmFsc2UsdGltZW91dD02MCkKICAgICAgICB3YWl0X3NlcnZlcl9yZWFkeShsb2FkX3NlcnZlcihzaWQpLDM1LjApCgogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICdvayc6RmFsc2UsCiAgICAgICAgICAgICdjaGFuZ2VkJzpGYWxzZSwKICAgICAgICAgICAgJ3BsdWdpbnMnOltdLAogICAgICAgICAgICAnZXJyb3InOidxdWFyYW50aW5lIHJlc3RhcnQgZmFpbGVkOiAnK3N0cihkZXRhaWwpLAogICAgICAgICAgICAncmVwb3J0JzpyZXBvcnQsCiAgICAgICAgICAgICdzdGFydF9tYXJrJzpOb25lLAogICAgICAgIH0KCiAgICB0aW1lLnNsZWVwKDEuNSkKICAgIGRldD1fZGV0ZWN0X21vZF9wcm9maWxlX2F0KHBhdGgpCiAgICBuZXdfcmVwb3J0PV9ydW50aW1lX21vZF9yZXBvcnQoCiAgICAgICAgbG9hZF9zZXJ2ZXIoc2lkKSwKICAgICAgICBib29sKGRldC5nZXQoJ3pwX2FjdGl2ZScpKSwKICAgICAgICBpbnQoZGV0LmdldCgnYWN0aXZlX3BsdWdpbl9jb3VudCcpIG9yIDApCiAgICApCgogICAgcmV0dXJuIHsKICAgICAgICAnb2snOlRydWUsCiAgICAgICAgJ2NoYW5nZWQnOlRydWUsCiAgICAgICAgJ3BsdWdpbnMnOnEuZ2V0KCdwbHVnaW5zJykgb3IgW10sCiAgICAgICAgJ3JlcG9ydCc6bmV3X3JlcG9ydCwKICAgICAgICAnZGV0ZWN0ZWQnOmRldCwKICAgICAgICAnc3RhcnRfbWFyayc6bWFyaywKICAgIH0KCgpkZWYgX3YzMjJfZmlsdGVyX3J1bnRpbWVfZXJyb3JzKGxpbmVzOmxpc3Rbc3RyXSktPmxpc3Rbc3RyXToKICAgIHN0b2NrX3NvPSgKICAgICAgICAnZnVuX2FteHhfaTM4Ni5zbycsCiAgICAgICAgJ2VuZ2luZV9hbXh4X2kzODYuc28nLAogICAgICAgICdmYWtlbWV0YV9hbXh4X2kzODYuc28nLAogICAgICAgICdnZW9pcF9hbXh4X2kzODYuc28nLAogICAgICAgICdjc3RyaWtlX2FteHhfaTM4Ni5zbycsCiAgICAgICAgJ2NzeF9hbXh4X2kzODYuc28nLAogICAgICAgICdoYW1zYW5kd2ljaF9hbXh4X2kzODYuc28nLAogICAgICAgICdteXNxbF9hbXh4X2kzODYuc28nLAogICAgKQoKICAgIG91dD1bXQogICAgZm9yIGxpbmUgaW4gbGlzdChsaW5lcyBvciBbXSk6CiAgICAgICAgbG93PXN0cihsaW5lKS5sb3dlcigpCgogICAgICAgIGlmICgKICAgICAgICAgICAgJ1ttZXRhXSBlcnJvcjonIGluIGxvdyBhbmQKICAgICAgICAgICAgJ25vdCBsb2FkaW5nIHBsdWdpbicgaW4gbG93IGFuZAogICAgICAgICAgICAnYWxyZWFkeSBsb2FkZWQgKHN0YXR1cz1ydW5uaW5nKScgaW4gbG93CiAgICAgICAgKToKICAgICAgICAgICAgY29udGludWUKCiAgICAgICAgaWYgKAogICAgICAgICAgICAnW21ldGFdIGVycm9yOicgaW4gbG93IGFuZAogICAgICAgICAgICAnZmFpbGVkIHRvIGxvYWQgcGx1Z2luJyBpbiBsb3cgYW5kCiAgICAgICAgICAgIGFueSh4IGluIGxvdyBmb3IgeCBpbiBzdG9ja19zbykKICAgICAgICApOgogICAgICAgICAgICBjb250aW51ZQoKICAgICAgICBvdXQuYXBwZW5kKGxpbmUpCgogICAgcmV0dXJuIG91dAojIDw8PCBIWVBFUi1IT1NUIHYzLjIyIE9QVElPTkFMIEZJTEUgU0FOSVRJWkVSIDw8PAonJycKCgpkZWYgcGFyc2Uoc3JjOnN0cik6CiAgICByZXR1cm4gYXN0LnBhcnNlKHNyYykKCgpkZWYgZnVuY3Rpb25fbm9kZSh0cmVlOmFzdC5BU1QsbmFtZTpzdHIpOgogICAgZm9yIG5vZGUgaW4gZ2V0YXR0cih0cmVlLCdib2R5JyxbXSk6CiAgICAgICAgaWYgaXNpbnN0YW5jZShub2RlLChhc3QuRnVuY3Rpb25EZWYsYXN0LkFzeW5jRnVuY3Rpb25EZWYpKSBhbmQgbm9kZS5uYW1lPT1uYW1lOgogICAgICAgICAgICByZXR1cm4gbm9kZQogICAgcmV0dXJuIE5vbmUKCgpkZWYgdGFyZ2V0X25hbWUobm9kZSk6CiAgICBpZiBpc2luc3RhbmNlKG5vZGUsYXN0LkFzc2lnbik6CiAgICAgICAgZm9yIHQgaW4gbm9kZS50YXJnZXRzOgogICAgICAgICAgICBpZiBpc2luc3RhbmNlKHQsYXN0Lk5hbWUpOgogICAgICAgICAgICAgICAgcmV0dXJuIHQuaWQKICAgIGlmIGlzaW5zdGFuY2Uobm9kZSxhc3QuQW5uQXNzaWduKSBhbmQgaXNpbnN0YW5jZShub2RlLnRhcmdldCxhc3QuTmFtZSk6CiAgICAgICAgcmV0dXJuIG5vZGUudGFyZ2V0LmlkCiAgICByZXR1cm4gTm9uZQoKCmRlZiBpbnNlcnRfYWZ0ZXJfbGluZShzcmM6c3RyLGxpbmVfbm86aW50LGJsb2NrOnN0ciktPnN0cjoKICAgIGxpbmVzPXNyYy5zcGxpdGxpbmVzKGtlZXBlbmRzPVRydWUpCiAgICBpZHg9bWF4KDAsbWluKGxlbihsaW5lcyksbGluZV9ubykpCiAgICBpZiBibG9jayBhbmQgbm90IGJsb2NrLmVuZHN3aXRoKCdcbicpOgogICAgICAgIGJsb2NrKz0nXG4nCiAgICBsaW5lc1tpZHg6aWR4XT1bYmxvY2tdCiAgICByZXR1cm4gJycuam9pbihsaW5lcykKCgpkZWYgZnVuY19zb3VyY2Uoc3JjOnN0cixub2RlKS0+c3RyOgogICAgbGluZXM9c3JjLnNwbGl0bGluZXMoa2VlcGVuZHM9VHJ1ZSkKICAgIHJldHVybiAnJy5qb2luKGxpbmVzW25vZGUubGluZW5vLTE6bm9kZS5lbmRfbGluZW5vXSkKCgpkZWYgcmVwbGFjZV9mdW5jdGlvbihzcmM6c3RyLG5vZGUsbmV3X2ZuOnN0ciktPnN0cjoKICAgIGxpbmVzPXNyYy5zcGxpdGxpbmVzKGtlZXBlbmRzPVRydWUpCiAgICBpZiBuZXdfZm4gYW5kIG5vdCBuZXdfZm4uZW5kc3dpdGgoJ1xuJyk6CiAgICAgICAgbmV3X2ZuKz0nXG4nCiAgICBsaW5lc1tub2RlLmxpbmVuby0xOm5vZGUuZW5kX2xpbmVub109W25ld19mbl0KICAgIHJldHVybiAnJy5qb2luKGxpbmVzKQoKCmRlZiBmaW5kX2Fzc2lnbihmbixuYW1lOnN0cik6CiAgICBmb3VuZD1bXQogICAgZm9yIG5vZGUgaW4gYXN0LndhbGsoZm4pOgogICAgICAgIGlmIHRhcmdldF9uYW1lKG5vZGUpPT1uYW1lOgogICAgICAgICAgICBmb3VuZC5hcHBlbmQobm9kZSkKICAgIGlmIG5vdCBmb3VuZDoKICAgICAgICByZXR1cm4gTm9uZQogICAgcmV0dXJuIHNvcnRlZChmb3VuZCxrZXk9bGFtYmRhIG46KGdldGF0dHIobiwnbGluZW5vJywxMCoqOSksZ2V0YXR0cihuLCdjb2xfb2Zmc2V0JywwKSkpWzBdCgoKZGVmIHBhdGNoX2N0bChwYXRoOlBhdGgpOgogICAgc3JjPXBhdGgucmVhZF90ZXh0KGVuY29kaW5nPSd1dGYtOCcsZXJyb3JzPSdzdXJyb2dhdGVlc2NhcGUnKQoKICAgIGlmICdkZWYgX3YzMjBfcHJlcGFyZV9ydW50aW1lKCcgbm90IGluIHNyYzoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ3YzLjIyIHJlcXVpcmVzIGluc3RhbGxlZCB2My4yMCBhZGFwdGl2ZSBydW50aW1lJykKCiAgICBpZiBNQVJLRVIgbm90IGluIHNyYzoKICAgICAgICBwb3M9c3JjLmZpbmQoJ1xuZGVmIGluc3RhbGxfY3VzdG9tX2J1aWxkKCcpCiAgICAgICAgaWYgcG9zPDA6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignaW5zdGFsbF9jdXN0b21fYnVpbGQgbm90IGZvdW5kJykKICAgICAgICBzcmM9c3JjWzpwb3NdKydcbicrSEVMUEVSK3NyY1twb3M6XQoKICAgIHRyZWU9cGFyc2Uoc3JjKQogICAgZm49ZnVuY3Rpb25fbm9kZSh0cmVlLCdpbnN0YWxsX2N1c3RvbV9idWlsZCcpCiAgICBpZiBmbiBpcyBOb25lOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignaW5zdGFsbF9jdXN0b21fYnVpbGQgbm90IGZvdW5kIGFmdGVyIGhlbHBlciBpbnNlcnRpb24nKQoKICAgIGZzcmM9ZnVuY19zb3VyY2Uoc3JjLGZuKQoKICAgIGlmICdvcHRpb25hbF9yZWZzPV92MzIyX3NraXBfbWlzc2luZ19vcHRpb25hbF9yZWZzKHN0YWdlKScgbm90IGluIGZzcmM6CiAgICAgICAgYXNzaWdubWVudD1maW5kX2Fzc2lnbihmbiwncGx1Z2luX2NvbW1lbnRfZml4JykKCiAgICAgICAgaWYgYXNzaWdubWVudCBpcyBOb25lOgogICAgICAgICAgICBhc3NpZ25tZW50PWZpbmRfYXNzaWduKGZuLCdwbGF0Zm9ybV9ydW50aW1lJykKCiAgICAgICAgaWYgYXNzaWdubWVudCBpcyBOb25lOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ3NhZmUgb3B0aW9uYWwtZmlsZSBpbnNlcnRpb24gcG9pbnQgbm90IGZvdW5kJykKCiAgICAgICAgYmxvY2s9KAogICAgICAgICAgICAiICAgICAgICBvcHRpb25hbF9yZWZzPV92MzIyX3NraXBfbWlzc2luZ19vcHRpb25hbF9yZWZzKHN0YWdlKVxuIgogICAgICAgICAgICAiICAgICAgICBpZiBvcHRpb25hbF9yZWZzLmdldCgnY3JpdGljYWxfbWlzc2luZ19wbHVnaW5zJyk6XG4iCiAgICAgICAgICAgICIgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ0NyaXRpY2FsIGdhbWVwbGF5IHBsdWdpbiBmaWxlKHMpIGFyZSBtaXNzaW5nOiAnKyIKICAgICAgICAgICAgImpzb24uZHVtcHMob3B0aW9uYWxfcmVmcy5nZXQoJ2NyaXRpY2FsX21pc3NpbmdfcGx1Z2lucycpLGVuc3VyZV9hc2NpaT1GYWxzZSkpXG4iCiAgICAgICAgICAgICIgICAgICAgIHF1YXJhbnRpbmVkX3BsdWdpbnM9W11cbiIKICAgICAgICApCgogICAgICAgIGlmIHRhcmdldF9uYW1lKGFzc2lnbm1lbnQpPT0ncGx1Z2luX2NvbW1lbnRfZml4JzoKICAgICAgICAgICAgc3JjPWluc2VydF9hZnRlcl9saW5lKHNyYyxhc3NpZ25tZW50LmVuZF9saW5lbm8sYmxvY2spCiAgICAgICAgZWxzZToKICAgICAgICAgICAgIyBJbnNlcnQgZGlyZWN0bHkgYmVmb3JlIHBsYXRmb3JtX3J1bnRpbWUuCiAgICAgICAgICAgIHNyYz1pbnNlcnRfYWZ0ZXJfbGluZShzcmMsYXNzaWdubWVudC5saW5lbm8tMSxibG9jaykKCiAgICB0cmVlPXBhcnNlKHNyYykKICAgIGZuPWZ1bmN0aW9uX25vZGUodHJlZSwnaW5zdGFsbF9jdXN0b21fYnVpbGQnKQogICAgZnNyYz1mdW5jX3NvdXJjZShzcmMsZm4pCgogICAgZnNyYz1yZS5zdWIoCiAgICAgICAgcicoP20pXihccyopcGx1Z2luX3JlcGFpcnNccyo9XHMqXFtcXVxzKjtccyptb2R1bGVfcmVwYWlyc1xzKj1ccypce1x9XHMqO1xzKm1ldGFtb2RfcmVwYWlyc1xzKj1ccypce1x9XHMqJCcsCiAgICAgICAgciJcMXBsdWdpbl9yZXBhaXJzPWxpc3Qob3B0aW9uYWxfcmVmcy5nZXQoJ2FjdGlvbnMnKSBvciBbXSk7IG1vZHVsZV9yZXBhaXJzPXt9OyBtZXRhbW9kX3JlcGFpcnM9e30iLAogICAgICAgIGZzcmMsCiAgICAgICAgY291bnQ9MSwKICAgICkKCiAgICBmc3JjPXJlLnN1YigKICAgICAgICByIig/bSleXHMqaW1wb3J0X21vZGVccyo9XHMqaW1wb3J0X21vZGVccypcK1xzKlsnXCJdXCttYW5hZ2VkLXJ1bnRpbWUtdjMxNlsnXCJdXHMqJCIsCiAgICAgICAgJycsCiAgICAgICAgZnNyYywKICAgICkKCiAgICBpZiAnK3NraXAtbWlzc2luZy12MzIyJyBub3QgaW4gZnNyYzoKICAgICAgICBsaW5lcz1mc3JjLnNwbGl0bGluZXMoKQogICAgICAgIGluc2VydF9pZHg9Tm9uZQoKICAgICAgICBmb3IgaSxsaW5lIGluIGVudW1lcmF0ZShsaW5lcyk6CiAgICAgICAgICAgIGlmICdpbXBvcnRfbW9kZScgaW4gbGluZSBhbmQgJ3J1bnRpbWUtdjMyMC0nIGluIGxpbmU6CiAgICAgICAgICAgICAgICBpbnNlcnRfaWR4PWkrMQoKICAgICAgICBpZiBpbnNlcnRfaWR4IGlzIE5vbmU6CiAgICAgICAgICAgIGZvciBpLGxpbmUgaW4gZW51bWVyYXRlKGxpbmVzKToKICAgICAgICAgICAgICAgIGlmICgKICAgICAgICAgICAgICAgICAgICAnaW1wb3J0X21vZGU9JyBpbiBsaW5lIGFuZAogICAgICAgICAgICAgICAgICAgICdleGFjdC1zZXJ2ZXItcm9vdCcgaW4gbGluZSBhbmQKICAgICAgICAgICAgICAgICAgICAnZXhhY3QtY3N0cmlrZS1hcmNoaXZlJyBpbiBsaW5lCiAgICAgICAgICAgICAgICApOgogICAgICAgICAgICAgICAgICAgIGluc2VydF9pZHg9aSsxCgogICAgICAgIGlmIGluc2VydF9pZHggaXMgTm9uZToKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdpbXBvcnRfbW9kZSBpbnNlcnRpb24gcG9pbnQgbm90IGZvdW5kJykKCiAgICAgICAgbGluZXMuaW5zZXJ0KGluc2VydF9pZHgsIiAgICAgICAgaW1wb3J0X21vZGU9aW1wb3J0X21vZGUrJytza2lwLW1pc3NpbmctdjMyMiciKQogICAgICAgIGZzcmM9J1xuJy5qb2luKGxpbmVzKSsnXG4nCgogICAgc3JjPXJlcGxhY2VfZnVuY3Rpb24oc3JjLGZuLGZzcmMpCgogICAgdHJlZT1wYXJzZShzcmMpCiAgICBmbj1mdW5jdGlvbl9ub2RlKHRyZWUsJ2luc3RhbGxfY3VzdG9tX2J1aWxkJykKICAgIGZzcmM9ZnVuY19zb3VyY2Uoc3JjLGZuKQoKICAgIGlmICdxdWFyYW50aW5lX29wdGlvbmFsPV92MzIyX3F1YXJhbnRpbmVfcnVudGltZV9iYWRfcGx1Z2lucycgbm90IGluIGZzcmM6CiAgICAgICAgcmVwb3J0PWZpbmRfYXNzaWduKGZuLCdydW50aW1lX3JlcG9ydCcpCgogICAgICAgIGlmIHJlcG9ydCBpcyBOb25lOgogICAgICAgICAgICBmb3Igbm9kZSBpbiBmbi5ib2R5OgogICAgICAgICAgICAgICAgaWYgbm90IGlzaW5zdGFuY2Uobm9kZSxhc3QuQXNzaWduKToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgc2VnPWFzdC5nZXRfc291cmNlX3NlZ21lbnQoc3JjLG5vZGUpIG9yICcnCiAgICAgICAgICAgICAgICBpZiAnX3J1bnRpbWVfbW9kX3JlcG9ydCcgaW4gc2VnOgogICAgICAgICAgICAgICAgICAgIHJlcG9ydD1ub2RlCiAgICAgICAgICAgICAgICAgICAgYnJlYWsKCiAgICAgICAgaWYgcmVwb3J0IGlzIE5vbmU6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigncnVudGltZSByZXBvcnQgYXNzaWdubWVudCBub3QgZm91bmQgc3RydWN0dXJhbGx5JykKCiAgICAgICAgYmxvY2s9KAogICAgICAgICAgICAiICAgICAgICBxdWFyYW50aW5lX29wdGlvbmFsPV92MzIyX3F1YXJhbnRpbmVfcnVudGltZV9iYWRfcGx1Z2lucyhzaWQsYyxwYXRoLHJ1bnRpbWVfcmVwb3J0KVxuIgogICAgICAgICAgICAiICAgICAgICBxdWFyYW50aW5lZF9wbHVnaW5zPWxpc3QocXVhcmFudGluZV9vcHRpb25hbC5nZXQoJ3BsdWdpbnMnKSBvciBbXSlcbiIKICAgICAgICAgICAgIiAgICAgICAgaWYgcXVhcmFudGluZV9vcHRpb25hbC5nZXQoJ2NoYW5nZWQnKTpcbiIKICAgICAgICAgICAgIiAgICAgICAgICAgIHJ1bnRpbWVfcmVwb3J0PXF1YXJhbnRpbmVfb3B0aW9uYWwuZ2V0KCdyZXBvcnQnKSBvciBydW50aW1lX3JlcG9ydFxuIgogICAgICAgICAgICAiICAgICAgICAgICAgZGV0ZWN0ZWQ9cXVhcmFudGluZV9vcHRpb25hbC5nZXQoJ2RldGVjdGVkJykgb3IgX2RldGVjdF9tb2RfcHJvZmlsZV9hdChwYXRoKVxuIgogICAgICAgICAgICAiICAgICAgICAgICAgaWYgcXVhcmFudGluZV9vcHRpb25hbC5nZXQoJ3N0YXJ0X21hcmsnKTpcbiIKICAgICAgICAgICAgIiAgICAgICAgICAgICAgICBzdGFydF9tYXJrPWZsb2F0KHF1YXJhbnRpbmVfb3B0aW9uYWwuZ2V0KCdzdGFydF9tYXJrJykpXG4iCiAgICAgICAgKQogICAgICAgIHNyYz1pbnNlcnRfYWZ0ZXJfbGluZShzcmMscmVwb3J0LmVuZF9saW5lbm8sYmxvY2spCgogICAgdHJlZT1wYXJzZShzcmMpCiAgICBmbj1mdW5jdGlvbl9ub2RlKHRyZWUsJ2luc3RhbGxfY3VzdG9tX2J1aWxkJykKICAgIGZzcmM9ZnVuY19zb3VyY2Uoc3JjLGZuKQoKICAgIGlmICdfdjMyMl9maWx0ZXJfcnVudGltZV9lcnJvcnMoX3J1bnRpbWVfZXJyb3JfbGluZXMnIG5vdCBpbiBmc3JjOgogICAgICAgIGZzcmM9cmUuc3ViKAogICAgICAgICAgICByJyg/bSleKFxzKikocnVudGltZV9lcnJvcnN8ZnJlc2hfZXJyb3JzKVxzKj1ccypfcnVudGltZV9lcnJvcl9saW5lc1woKFteXG5dKilcKVxzKiQnLAogICAgICAgICAgICByJ1wxXDI9X3YzMjJfZmlsdGVyX3J1bnRpbWVfZXJyb3JzKF9ydW50aW1lX2Vycm9yX2xpbmVzKFwzKSknLAogICAgICAgICAgICBmc3JjLAogICAgICAgICkKCiAgICBzcmM9cmVwbGFjZV9mdW5jdGlvbihzcmMsZm4sZnNyYykKCiAgICB0cmVlPXBhcnNlKHNyYykKICAgIGZuPWZ1bmN0aW9uX25vZGUodHJlZSwnaW5zdGFsbF9jdXN0b21fYnVpbGQnKQogICAgZnNyYz1mdW5jX3NvdXJjZShzcmMsZm4pCgogICAgaWYgInJlc3VsdFsnc2tpcHBlZF9taXNzaW5nX2ZpbGVzJ10iIG5vdCBpbiBmc3JjOgogICAgICAgIHJlc3VsdF9ub2RlPWZpbmRfYXNzaWduKGZuLCdyZXN1bHQnKQogICAgICAgIGlmIHJlc3VsdF9ub2RlIGlzIG5vdCBOb25lOgogICAgICAgICAgICBibG9jaz0oCiAgICAgICAgICAgICAgICAiICAgICAgICByZXN1bHRbJ3NraXBwZWRfbWlzc2luZ19maWxlcyddPVt4LmdldCgncGx1Z2luJywnJykgZm9yIHggaW4gIgogICAgICAgICAgICAgICAgIm9wdGlvbmFsX3JlZnMuZ2V0KCdtaXNzaW5nX3BsdWdpbnMnLFtdKSBpZiB4LmdldCgncGx1Z2luJyldXG4iCiAgICAgICAgICAgICAgICAiICAgICAgICByZXN1bHRbJ3NraXBwZWRfbWlzc2luZ19tZXRhbW9kJ109bGlzdChvcHRpb25hbF9yZWZzLmdldCgnbWlzc2luZ19tZXRhbW9kX3BsdWdpbnMnKSBvciBbXSlcbiIKICAgICAgICAgICAgICAgICIgICAgICAgIHJlc3VsdFsnY2FzZV9maXhlZF9wbHVnaW5zJ109bGlzdChvcHRpb25hbF9yZWZzLmdldCgnY2FzZV9maXhlZF9wbHVnaW5zJykgb3IgW10pXG4iCiAgICAgICAgICAgICAgICAiICAgICAgICByZXN1bHRbJ3F1YXJhbnRpbmVkX3BsdWdpbnMnXT1saXN0KHF1YXJhbnRpbmVkX3BsdWdpbnMgb3IgW10pXG4iCiAgICAgICAgICAgICkKICAgICAgICAgICAgc3JjPWluc2VydF9hZnRlcl9saW5lKHNyYyxyZXN1bHRfbm9kZS5lbmRfbGluZW5vLGJsb2NrKQoKICAgIHRtcD1wYXRoLndpdGhfbmFtZShwYXRoLm5hbWUrJy52MzIydG1wJykKICAgIHRtcC53cml0ZV90ZXh0KHNyYyxlbmNvZGluZz0ndXRmLTgnLGVycm9ycz0nc3Vycm9nYXRlZXNjYXBlJykKICAgIG9zLmNobW9kKHRtcCxwYXRoLnN0YXQoKS5zdF9tb2RlKQoKICAgIHB5X2NvbXBpbGUuY29tcGlsZShzdHIodG1wKSxkb3JhaXNlPVRydWUpCgogICAgZmluYWw9dG1wLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnLGVycm9ycz0nc3Vycm9nYXRlZXNjYXBlJykKICAgIHJlcXVpcmVkPVsKICAgICAgICBNQVJLRVIsCiAgICAgICAgJ29wdGlvbmFsX3JlZnM9X3YzMjJfc2tpcF9taXNzaW5nX29wdGlvbmFsX3JlZnMoc3RhZ2UpJywKICAgICAgICAncXVhcmFudGluZV9vcHRpb25hbD1fdjMyMl9xdWFyYW50aW5lX3J1bnRpbWVfYmFkX3BsdWdpbnMnLAogICAgICAgICcrc2tpcC1taXNzaW5nLXYzMjInLAogICAgICAgICdkZWYgX3YzMjJfZmlsdGVyX3J1bnRpbWVfZXJyb3JzJywKICAgIF0KCiAgICBtaXNzaW5nPVt4IGZvciB4IGluIHJlcXVpcmVkIGlmIHggbm90IGluIGZpbmFsXQogICAgaWYgbWlzc2luZzoKICAgICAgICB0bXAudW5saW5rKG1pc3Npbmdfb2s9VHJ1ZSkKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ3YzLjIyIHZlcmlmaWNhdGlvbiBmYWlsZWQ6ICcrcmVwcihtaXNzaW5nKSkKCiAgICBvcy5yZXBsYWNlKHRtcCxwYXRoKQogICAgcHJpbnQoJ1tQQVRDSEVEXScscGF0aCkKCgpkZWYgcGF0Y2hfaW5kZXgocGF0aDpQYXRoKToKICAgIHNyYz1wYXRoLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnLGVycm9ycz0nc3Vycm9nYXRlZXNjYXBlJykKCiAgICBzcmM9c3JjLnJlcGxhY2UoCiAgICAgICAgIigkY2ZncD4wPycgQU1YWDogJy4kcnVucC4nLycuJGNmZ3AuJyDQt9Cw0LPRgNGD0LbQtdC90L4sICcuJHJ1bm5pbmcuJyBydW5uaW5nLic6JycpIiwKICAgICAgICAiKCgkcnVucD4wfHwkY2ZncD4wKT8nIEFNWFg6ICcuJHJ1bm5pbmcuJyBydW5uaW5nOyDQvdCw0YHRgtGA0L7QtdC90L46ICcuJGNmZ3AuJy4nOicnKSIKICAgICkKCiAgICBtYXJrZXI9IiR3YXJuPXRyaW0oKHN0cmluZykoJHJbJ3dhcm5pbmcnXT8/JycpKTsiCiAgICBpbmZvPSgKICAgICAgICAiJHNraXBNaXNzaW5nPWlzX2FycmF5KCRyWydza2lwcGVkX21pc3NpbmdfZmlsZXMnXT8/bnVsbCk/YXJyYXlfdmFsdWVzKGFycmF5X2ZpbHRlcigkclsnc2tpcHBlZF9taXNzaW5nX2ZpbGVzJ10pKTpbXTsiCiAgICAgICAgIiRza2lwTWV0YT1pc19hcnJheSgkclsnc2tpcHBlZF9taXNzaW5nX21ldGFtb2QnXT8/bnVsbCk/YXJyYXlfdmFsdWVzKGFycmF5X2ZpbHRlcigkclsnc2tpcHBlZF9taXNzaW5nX21ldGFtb2QnXSkpOltdOyIKICAgICAgICAiJHF1YXJhbnRpbmU9aXNfYXJyYXkoJHJbJ3F1YXJhbnRpbmVkX3BsdWdpbnMnXT8/bnVsbCk/YXJyYXlfdmFsdWVzKGFycmF5X2ZpbHRlcigkclsncXVhcmFudGluZWRfcGx1Z2lucyddKSk6W107IgogICAgKQoKICAgIGlmICckc2tpcE1pc3Npbmc9JyBub3QgaW4gc3JjIGFuZCBtYXJrZXIgaW4gc3JjOgogICAgICAgIHNyYz1zcmMucmVwbGFjZShtYXJrZXIsbWFya2VyK2luZm8sMSkKCiAgICBuZWVkbGU9ImlmKCEkaGVhbHRoeSkkbXNnLj0nINCh0LHQvtGA0LrQsCDQvtGB0YLQsNCy0LvQtdC90LAg0YPRgdGC0LDQvdC+0LLQu9C10L3QvdC+0LksINC90L4gcnVudGltZSDRgtGA0LXQsdGD0LXRgiDQstC90LjQvNCw0L3QuNGPJyIKICAgIGluamVjdD0oCiAgICAgICAgImlmKGlzc2V0KCRza2lwTWlzc2luZykmJiRza2lwTWlzc2luZykkbXNnLj0nINCf0YDQvtC/0YPRidC10L3RiyDQvtGC0YHRg9GC0YHRgtCy0YPRjtGJ0LjQtSDQvdC10L7QsdGP0LfQsNGC0LXQu9GM0L3Ri9C1IEFNWFgt0YTQsNC50LvRizogJy5pbXBsb2RlKCcsICcsYXJyYXlfc2xpY2UoJHNraXBNaXNzaW5nLDAsMTIpKS4nLic7IgogICAgICAgICJpZihpc3NldCgkc2tpcE1ldGEpJiYkc2tpcE1ldGEpJG1zZy49JyDQn9GA0L7Qv9GD0YnQtdC90Ysg0L7RgtGB0YPRgtGB0YLQstGD0Y7RidC40LUg0L3QtdC+0LHRj9C30LDRgtC10LvRjNC90YvQtSBNZXRhbW9kLdGE0LDQudC70Ys6ICcuaW1wbG9kZSgnLCAnLGFycmF5X3NsaWNlKCRza2lwTWV0YSwwLDgpKS4nLic7IgogICAgICAgICJpZihpc3NldCgkcXVhcmFudGluZSkmJiRxdWFyYW50aW5lKSRtc2cuPScg0J7RgtC60LvRjtGH0LXQvdGLINC/0L7QstGA0LXQttC00ZHQvdC90YvQtSDQvdC10L7QsdGP0LfQsNGC0LXQu9GM0L3Ri9C1INC/0LvQsNCz0LjQvdGLOiAnLmltcGxvZGUoJywgJyxhcnJheV9zbGljZSgkcXVhcmFudGluZSwwLDEyKSkuJy4nOyIKICAgICkKCiAgICBpZiAn0J/RgNC+0L/Rg9GJ0LXQvdGLINC+0YLRgdGD0YLRgdGC0LLRg9GO0YnQuNC1INC90LXQvtCx0Y/Qt9Cw0YLQtdC70YzQvdGL0LUgQU1YWC3RhNCw0LnQu9GLJyBub3QgaW4gc3JjIGFuZCBuZWVkbGUgaW4gc3JjOgogICAgICAgIHNyYz1zcmMucmVwbGFjZShuZWVkbGUsaW5qZWN0K25lZWRsZSkKCiAgICB0bXA9cGF0aC53aXRoX25hbWUocGF0aC5uYW1lKycudjMyMnRtcCcpCiAgICB0bXAud3JpdGVfdGV4dChzcmMsZW5jb2Rpbmc9J3V0Zi04JyxlcnJvcnM9J3N1cnJvZ2F0ZWVzY2FwZScpCiAgICBvcy5jaG1vZCh0bXAscGF0aC5zdGF0KCkuc3RfbW9kZSkKICAgIG9zLnJlcGxhY2UodG1wLHBhdGgpCiAgICBwcmludCgnW1BBVENIRURdJyxwYXRoKQoKCmRlZiBtYWluKCk6CiAgICBpZiBsZW4oc3lzLmFyZ3YpIT0zOgogICAgICAgIHJhaXNlIFN5c3RlbUV4aXQoJ3VzYWdlOiBwYXRjaF92MzIyLnB5IGN0bHxpbmRleCBQQVRIJykKCiAgICBtb2RlPXN5cy5hcmd2WzFdCiAgICBwYXRoPVBhdGgoc3lzLmFyZ3ZbMl0pCgogICAgaWYgbW9kZT09J2N0bCc6CiAgICAgICAgcGF0Y2hfY3RsKHBhdGgpCiAgICBlbGlmIG1vZGU9PSdpbmRleCc6CiAgICAgICAgcGF0Y2hfaW5kZXgocGF0aCkKICAgIGVsc2U6CiAgICAgICAgcmFpc2UgU3lzdGVtRXhpdCgndW5rbm93biBtb2RlJykKCmlmIF9fbmFtZV9fPT0nX19tYWluX18nOgogICAgbWFpbigpCg==' | base64 -d >"$PATCHER"
python3 -m py_compile "$PATCHER" || die "Embedded v3.22 patcher is invalid"

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local safe
  safe="$(printf '%s' "$f" | sed 's#^/##;s#/#__#g')"
  mkdir -p "$BACKUP/$(dirname "$safe")"
  cp -a "$f" "$BACKUP/$safe"
}

echo "[1/8] Backing up controller..."
backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"

echo
echo "[2/8] Patching LIVE controller structurally..."
python3 "$PATCHER" ctl "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller syntax validation failed"

echo "[OK] live controller patched"

echo
echo "[3/8] Synchronizing verified controller into repo..."
install -m 0755 "$LIVE_CTL" "$REPO_CTL"
python3 -m py_compile "$REPO_CTL" || die "Repository controller validation failed"

echo "[OK] repo controller synchronized"

echo
echo "[4/8] Patching panel message / AMXX counter..."

for root in   "/var/www/hyper-host-sites/$DOMAIN/public_html"   "/var/www/$DOMAIN/public_html"   "/var/www/$DOMAIN"
do
  [[ -f "$root/index.php" ]] && echo "$root" >>"$ROOTS"
done

if command -v nginx >/dev/null 2>&1; then
  nginx -T >"$NGTMP" 2>&1 || true
  python3 - "$NGTMP" "$DOMAIN" >>"$ROOTS" <<'PYROOTS'
import re,sys
text=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
domain=sys.argv[2]
for block in re.findall(r'server\s*\{.*?\n\}',text,re.S):
    if domain not in block:
        continue
    for root in re.findall(r'(?m)^\s*root\s+([^;]+);',block):
        root=root.strip()
        if root.startswith('/'):
            print(root)
PYROOTS
fi

while IFS= read -r idx; do
  grep -q "serverTabs" "$idx" 2>/dev/null || continue
  echo "$(dirname "$idx")" >>"$ROOTS"
done < <(find /var/www -xdev -type f -name index.php 2>/dev/null || true)

sort -u "$ROOTS" -o "$ROOTS"

PANEL_COUNT=0
FIRST_ROOT=""
while IFS= read -r DOCROOT; do
  [[ -n "$DOCROOT" ]] || continue
  [[ -f "$DOCROOT/index.php" ]] || continue
  grep -q "serverTabs" "$DOCROOT/index.php" || continue

  PANEL_COUNT=$((PANEL_COUNT+1))
  [[ -n "$FIRST_ROOT" ]] || FIRST_ROOT="$DOCROOT"

  backup_file "$DOCROOT/index.php"
  python3 "$PATCHER" index "$DOCROOT/index.php" || die "Panel patch failed: $DOCROOT"
  php -l "$DOCROOT/index.php" >/dev/null || die "PHP syntax error: $DOCROOT/index.php"
  echo "[PATCHED PANEL] $DOCROOT"
done <"$ROOTS"

if [[ "$PANEL_COUNT" -gt 0 && -n "$FIRST_ROOT" ]]; then
  install -m 0644 "$FIRST_ROOT/index.php" "$REPO/cs16-panel/public/index.php"
  php -l "$REPO/cs16-panel/public/index.php" >/dev/null || die "Repo panel PHP validation failed"
else
  echo "[WARN] CS16 panel root not found. Backend is patched; panel wording unchanged."
fi

while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*fpm/ {print $1}')

echo
echo "[5/8] Sanitizing CURRENT server #$SID..."

STATE="/var/lib/hyper-cs16/servers/${SID}.json"
if [[ -f "$STATE" ]]; then
  readarray -t INFO < <(python3 - "$STATE" <<'PYSTATE'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
sid=int(d.get('id') or 0)
print(str(d.get('path') or f'/srv/hyper-cs16/servers/{sid}'))
print(int(d.get('port') or 0))
PYSTATE
)
  SERVER_PATH="${INFO[0]}"
  PORT="${INFO[1]}"
  CFG_DIR="$SERVER_PATH/cstrike/addons/amxmodx/configs"

  mkdir -p "$BACKUP/current-server-configs"
  if [[ -d "$CFG_DIR" ]]; then
    find "$CFG_DIR" -maxdepth 1 -type f -name 'plugins*.ini' -exec cp -a {} "$BACKUP/current-server-configs/" \; 2>/dev/null || true
  fi
  [[ -f "$SERVER_PATH/cstrike/addons/metamod/plugins.ini" ]] &&     cp -a "$SERVER_PATH/cstrike/addons/metamod/plugins.ini" "$BACKUP/current-server-configs/metamod-plugins.ini"

  python3 - "$SERVER_PATH" <<'PYCURRENT'
from pathlib import Path
import re,sys

root=Path(sys.argv[1])
cstrike=root/'cstrike'
plugdir=cstrike/'addons/amxmodx/plugins'
cfgdir=cstrike/'addons/amxmodx/configs'

def critical(name):
    n=Path(name).name.lower()
    return n in {
        'zombie_plague.amxx','zombie_plague40.amxx',
        'zp_core.amxx','zp50_core.amxx',
    }

actual={}
if plugdir.is_dir():
    for p in plugdir.iterdir():
        if p.is_file() and p.suffix.lower()=='.amxx':
            actual[p.name.lower()]=p.name

cfgs=[]
main=cfgdir/'plugins.ini'
if main.is_file(): cfgs.append(main)
if cfgdir.is_dir():
    cfgs += sorted(
        p for p in cfgdir.glob('plugins-*.ini')
        if p.is_file() and not p.name.startswith('disabled-')
    )

missing=[]
casefix=[]

for cfg in cfgs:
    raw=cfg.read_bytes().replace(b'\r\n',b'\n').replace(b'\r',b'\n').decode('latin1','ignore')
    out=[]; changed=False
    for line in raw.splitlines():
        st=line.strip()
        if not st or st.startswith((';','//','#')):
            out.append(line); continue

        body=re.split(r'\s*(?:;|//)',st,maxsplit=1)[0].strip()
        parts=body.split()
        token=(parts[0].strip('"') if parts else '')
        if not token.lower().endswith('.amxx'):
            out.append(line); continue

        name=Path(token.replace('\\','/')).name
        if (plugdir/name).is_file():
            out.append(line); continue

        alt=actual.get(name.lower())
        if alt:
            idx=line.find(token)
            if idx>=0:
                line=line[:idx]+alt+line[idx+len(token):]
                changed=True; casefix.append((name,alt))
            out.append(line); continue

        if critical(name):
            out.append(line)
            print('[WARN] critical plugin is missing and was NOT skipped:',name)
            continue

        out.append('; HYPER-HOST v3.22 skipped missing optional plugin: '+line)
        changed=True; missing.append(name)

    if changed:
        cfg.write_bytes(('\n'.join(out).rstrip()+'\n').encode('latin1','replace'))

print('[INFO] skipped missing optional AMXX:', ', '.join(dict.fromkeys(missing)) or 'none')
print('[INFO] fixed case-only names:', ', '.join(a+'->'+b for a,b in casefix) or 'none')
PYCURRENT

  systemctl reset-failed "hyper-cs16@$SID.service" 2>/dev/null || true
  systemctl restart "hyper-cs16@$SID.service" || true

  OPENED=0
  for _ in $(seq 1 45); do
    if systemctl is-active --quiet "hyper-cs16@$SID.service"; then
      if [[ "$PORT" -gt 0 ]] && ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$"; then
        OPENED=1
        break
      fi
    fi
    sleep 1
  done

  if [[ "$OPENED" -eq 1 ]]; then
    sleep 3
    echo "--- AMXX plugins before invalid-plugin quarantine ---"
    AMXX_OUT="$("$LIVE_CTL" rcon "$SID" "amxx plugins" 2>&1 || true)"
    echo "$AMXX_OUT"

    BAD_FILE="$BACKUP/current-bad-plugins.txt"
    python3 - "$AMXX_OUT" >"$BAD_FILE" <<'PYBAD'
import json,re,sys
raw=sys.argv[1]
try:
    d=json.loads(raw.strip().splitlines()[-1])
    text=str(d.get('output') or '')
except Exception:
    text=raw

critical={
    'zombie_plague.amxx','zombie_plague40.amxx',
    'zp_core.amxx','zp50_core.amxx',
}
names=[]
for pat in (
    r'Plugin file open error\s*\(plugin\s+"([^"]+[.]amxx)"\)',
    r'Invalid Plugin\s*\(plugin\s+"([^"]+[.]amxx)"\)',
):
    for m in re.finditer(pat,text,re.I):
        name=m.group(1).replace('\\','/').split('/')[-1]
        if name.lower() not in critical:
            names.append(name)

for name in dict.fromkeys(names):
    print(name)
PYBAD

    if [[ -s "$BAD_FILE" ]]; then
      echo "[INFO] Quarantining invalid optional plugin(s):"
      cat "$BAD_FILE"

      python3 - "$SERVER_PATH" "$BAD_FILE" <<'PYQUAR'
from pathlib import Path
import re,sys

root=Path(sys.argv[1])
wanted={
    x.strip().lower()
    for x in Path(sys.argv[2]).read_text(encoding='utf-8').splitlines()
    if x.strip()
}
cfg=root/'cstrike/addons/amxmodx/configs'

files=[]
main=cfg/'plugins.ini'
if main.is_file(): files.append(main)
if cfg.is_dir():
    files += sorted(
        p for p in cfg.glob('plugins-*.ini')
        if p.is_file() and not p.name.startswith('disabled-')
    )

for p in files:
    raw=p.read_bytes().replace(b'\r\n',b'\n').replace(b'\r',b'\n').decode('latin1','ignore')
    out=[]; changed=False
    for line in raw.splitlines():
        st=line.strip()
        if not st or st.startswith((';','//','#')):
            out.append(line); continue

        body=re.split(r'\s*(?:;|//)',st,maxsplit=1)[0].strip()
        parts=body.split()
        token=(parts[0].strip('"') if parts else '')
        name=Path(token.replace('\\','/')).name.lower()

        if name in wanted:
            out.append('; HYPER-HOST v3.22 quarantined invalid optional plugin: '+line)
            changed=True
        else:
            out.append(line)

    if changed:
        p.write_bytes(('\n'.join(out).rstrip()+'\n').encode('latin1','replace'))
PYQUAR

      systemctl restart "hyper-cs16@$SID.service" || true
      sleep 5

      if ! systemctl is-active --quiet "hyper-cs16@$SID.service"; then
        echo "[WARN] Quarantine restart failed; restoring plugin configs."
        if [[ -d "$BACKUP/current-server-configs" ]]; then
          for f in "$BACKUP/current-server-configs"/plugins*.ini; do
            [[ -f "$f" ]] || continue
            cp -a "$f" "$CFG_DIR/$(basename "$f")"
          done
        fi
        systemctl restart "hyper-cs16@$SID.service" || true
      fi
    fi

    echo "--- AMXX plugins after sanitize ---"
    "$LIVE_CTL" rcon "$SID" "amxx plugins" 2>&1 || true
  else
    echo "[WARN] Server #$SID did not expose UDP after sanitize."
    journalctl -u "hyper-cs16@$SID.service" -n 120 --no-pager || true
  fi

  python3 - "$STATE" <<'PYSTATEFIX'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
d=json.loads(p.read_text(encoding='utf-8'))
mode=str(d.get('custom_build_import_mode') or '')
if mode:
    mode=mode.replace('+managed-runtime-v316','')
    mode=mode.replace('+skip-missing-v321','')
    if '+skip-missing-v322' not in mode:
        mode+='+skip-missing-v322'
    d['custom_build_import_mode']=mode
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('[OK] current import mode:',mode)
PYSTATEFIX
else
  echo "[INFO] Server #$SID does not exist; current-server sanitize skipped."
fi

echo
echo "[6/8] Verifying future importer..."
python3 - "$LIVE_CTL" <<'PYVERIFY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
ast.parse(s)

checks={
    'v3.22 helper':'def _v322_skip_missing_optional_refs' in s,
    'pre-start sanitize':'optional_refs=_v322_skip_missing_optional_refs(stage)' in s,
    'invalid plugin quarantine':'quarantine_optional=_v322_quarantine_runtime_bad_plugins' in s,
    'v3.22 suffix':'+skip-missing-v322' in s,
    'old v3.16 suffix removed':"import_mode=import_mode+'+managed-runtime-v316'" not in s,
    'benign Meta filter':'def _v322_filter_runtime_errors' in s,
}

bad=[]
for name,ok in checks.items():
    print(('[OK] ' if ok else '[FAIL] ')+name)
    if not ok: bad.append(name)

if bad:
    raise SystemExit('[ERROR] verification failed: '+', '.join(bad))
PYVERIFY

echo
echo "[7/8] Checking controller idempotence..."
python3 "$PATCHER" ctl "$LIVE_CTL" || die "Second idempotence pass failed"
python3 -m py_compile "$LIVE_CTL" || die "Controller invalid after second pass"
install -m 0755 "$LIVE_CTL" "$REPO_CTL"
echo "[OK] repeated patch pass is valid"

echo
echo "[8/8] Service state..."
systemctl --no-pager --full status "hyper-cs16@$SID.service" 2>/dev/null | sed -n '1,16p' || true

echo
echo "============================================================"
echo " v3.22 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "Future assembly behavior:"
echo " - missing OPTIONAL .amxx -> skip"
echo " - Linux case mismatch -> fix"
echo " - missing OPTIONAL Metamod .so -> skip"
echo " - Invalid Plugin / open-error non-core .amxx -> quarantine"
echo " - ZP core and runtime core -> never silently skip"
echo
echo "Import suffix: +skip-missing-v322"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
