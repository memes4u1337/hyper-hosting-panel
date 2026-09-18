#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$ROOT_DIR/install-cs16-panel.sh" && -d "$ROOT_DIR/cs16-panel" ]] || { echo '[ERROR] Run this script from the patched HYPER-HOST repository root' >&2; exit 2; }

say(){ printf '\033[1;36m[CS16 v1.6]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CS16 v1.6 WARNING]\033[0m %s\n' "$*" >&2; }

say 'Reading current CS16 network settings...'
CURRENT_DOMAIN='www.avito.hyper-host.pw'; CURRENT_PUBLIC=''; CURRENT_LAN=''
if [[ -f /etc/hyper-cs16/panel.php ]] && command -v php >/dev/null 2>&1; then
  CURRENT_DOMAIN="$(php -r '$c=require "/etc/hyper-cs16/panel.php"; echo $c["domain"]??"";' 2>/dev/null || true)"
  CURRENT_PUBLIC="$(php -r '$c=require "/etc/hyper-cs16/panel.php"; echo $c["public_ip"]??"";' 2>/dev/null || true)"
  CURRENT_LAN="$(php -r '$c=require "/etc/hyper-cs16/panel.php"; echo $c["lan_ip"]??"";' 2>/dev/null || true)"
fi
if [[ -z "$CURRENT_LAN" ]]; then
  CURRENT_LAN="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
fi
export CS16_PANEL_DOMAIN="${CURRENT_DOMAIN:-www.avito.hyper-host.pw}"
[[ -n "$CURRENT_PUBLIC" ]] && export CS16_PUBLIC_IP="$CURRENT_PUBLIC"
[[ -n "$CURRENT_LAN" ]] && export CS16_LAN_IP="$CURRENT_LAN"
export CS16_SKIP_GAME_DOWNLOAD=1
export CS16_CREATE_DEFAULT=0

say 'Installing matching HYPER-HOST FTP controller with direct CS16 chroot support...'
install -m 0755 "$ROOT_DIR/scripts/hhctl" /usr/local/sbin/hyper-host-ctl

say 'Updating CS16 panel/runtime without deleting game files...'
bash "$ROOT_DIR/install-cs16-panel.sh"

say 'Opening Ubuntu firewall for game UDP and FTP passive mode...'
if command -v ufw >/dev/null 2>&1; then
  ufw allow 27015:27100/udp >/dev/null 2>&1 || true
  ufw allow 21/tcp >/dev/null 2>&1 || true
  ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p udp --dport 27015:27100 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport 27015:27100 -j ACCEPT >/dev/null 2>&1 || true
  iptables -C INPUT -p tcp --dport 21 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 21 -j ACCEPT >/dev/null 2>&1 || true
  iptables -C INPUT -p tcp --dport 40000:40100 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 40000:40100 -j ACCEPT >/dev/null 2>&1 || true
fi

say 'Repairing existing servers, classic Metamod config, direct FTP roots and health checks...'
failed=0
shopt -s nullglob
for cfg in /var/lib/hyper-cs16/servers/*.json; do
  sid="$(basename "$cfg" .json)"
  [[ "$sid" =~ ^[0-9]+$ ]] || continue
  say "Server #$sid: HLDS runtime"
  if ! /usr/local/sbin/hyper-cs16-ctl repair-runtime "$sid"; then
    warn "Server #$sid HLDS health check failed"
    failed=1
    continue
  fi
  say "Server #$sid: direct-root FTP"
  if ! /usr/local/sbin/hyper-cs16-ctl ftp-repair "$sid"; then
    warn "Server #$sid FTP self-test failed"
    failed=1
  fi
  say "Server #$sid: network"
  /usr/local/sbin/hyper-cs16-ctl network "$sid" || failed=1
done
shopt -u nullglob

say 'Final sockets:'
ss -lunp | grep -E ':(27015|27016|27017|27018|27019|27020|27021|27022|27023|27024|27025|27026|27027|27028|27029|27030|27031|27032|27033|27034|27035|27036|27037|27038|27039|27040|27041|27042|27043|27044|27045|27046|27047|27048|27049|27050|27051|27052|27053|27054|27055|27056|27057|27058|27059|27060|27061|27062|27063|27064|27065|27066|27067|27068|27069|27070|27071|27072|27073|27074|27075|27076|27077|27078|27079|27080|27081|27082|27083|27084|27085|27086|27087|27088|27089|27090|27091|27092|27093|27094|27095|27096|27097|27098|27099|27100)\b' || true
ss -ltnp | grep -E ':(21|40000|40100)\b' || true

echo
say "LAN IP:    ${CURRENT_LAN:-unknown}"
say "Public IP: ${CURRENT_PUBLIC:-unknown}"
echo 'If you play from the same home/LAN network, use the LAN address shown by the panel.'
echo 'For Internet players, the router must forward each CS UDP port to the LAN IP.'
echo 'FTP from Internet additionally needs TCP 21 and TCP 40000-40100 forwarded to the LAN IP.'

if ((failed)); then
  warn 'Patch installed, but one or more self-tests failed. Open the panel and use the new network/FTP checks for the exact error.'
  exit 2
fi
say 'DONE: HLDS local health + direct per-server FTP checks passed.'
