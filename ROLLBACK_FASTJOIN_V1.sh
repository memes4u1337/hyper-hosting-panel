#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run with sudo/root'; exit 1; }
BACKUP="${1:-}"
SID="${2:-25}"
[[ -n "$BACKUP" && -d "$BACKUP" ]] || {
  echo 'Usage: sudo bash ROLLBACK_FASTJOIN_V1.sh /root/old-zombie-fastjoin-v1-backup-25-YYYYMMDD-HHMMSS [SERVER_ID]'
  exit 2
}
echo "[ROLLBACK] backup=$BACKUP server=$SID"
# Restore files backed up with their absolute-path hierarchy.
for top in etc srv usr root; do
  if [[ -d "$BACKUP/$top" ]]; then
    cp -a "$BACKUP/$top/." "/$top/"
  fi
done
# Restore quarantined stale resources if any.
Q="$BACKUP/quarantine-stale-r6-r7"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
if [[ -d "$Q" ]]; then
  while IFS= read -r -d '' src; do
    rel="${src#$Q/}"
    dst="$CSTRIKE/$rel"
    mkdir -p "$(dirname "$dst")"
    [[ -e "$dst" ]] || mv "$src" "$dst"
  done < <(find "$Q" -depth -type f -print0)
fi
python3 -m py_compile /usr/local/sbin/hyper-cs16-ctl 2>/dev/null || true
/usr/local/sbin/hyper-cs16-ctl fastdl-sync "$SID" || true
systemctl restart "hyper-cs16@${SID}.service" || true
echo '[DONE] rollback attempted. Check server and FastDL.'
