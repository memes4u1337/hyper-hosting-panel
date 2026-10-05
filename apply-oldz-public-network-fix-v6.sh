#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CTL="/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl"
UNIT="hyper-cs16@${SID}.service"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/root/oldz-network-fix-v6-${SID}-${STAMP}.log"

exec > >(tee -a "$LOG") 2>&1

echo "================================================================"
echo " OLD ZOMBIE PUBLIC NETWORK FIX v6"
echo " Server: #${SID}"
echo " Log: $LOG"
echo "================================================================"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

if [[ ! -x "$CTL" ]]; then
  echo "[ERROR] Controller not found: $CTL"
  exit 2
fi

PORT="$("$CTL" status "$SID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("port",27015))' 2>/dev/null || echo 27015)"
echo "[INFO] Game port: $PORT"

echo
echo "[1/7] Checking local UDP listener..."
ss -lunp | grep -E "[:.]${PORT}[[:space:]]" || true

echo
echo "[2/7] Running built-in HYPER-HOST network repair..."
set +e
NET_JSON="$("$CTL" network-fix "$SID" 2>&1)"
NET_RC=$?
set -e
echo "$NET_JSON"

if [[ $NET_RC -ne 0 ]]; then
  echo "[WARN] network-fix returned rc=$NET_RC; continuing with manual repair."
fi

echo
echo "[3/7] Opening host firewall for UDP/TCP ${PORT}..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/udp" || true
  ufw allow "${PORT}/tcp" || true
fi

if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport "$PORT" -j ACCEPT
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT
  iptables -C OUTPUT -p udp --sport "$PORT" -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p udp --sport "$PORT" -j ACCEPT
fi

echo
echo "[4/7] Forcing Internet mode and Steam master heartbeat..."
"$CTL" rcon "$SID" "sv_lan 0" || true
"$CTL" rcon "$SID" "setmaster enable" || true
"$CTL" rcon "$SID" "heartbeat" || true

# Persist sv_lan 0.
STATUS_JSON="$("$CTL" status "$SID")"
ROOT="$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("/srv/hyper-cs16/servers/%s" % d["id"])')"
SERVER_CFG="$ROOT/cstrike/server.cfg"
if [[ -f "$SERVER_CFG" ]]; then
  python3 - "$SERVER_CFG" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='ignore')
if re.search(r'(?im)^\s*sv_lan\b',s):
    s=re.sub(r'(?im)^\s*sv_lan\s+.*$', 'sv_lan 0', s)
else:
    s=s.rstrip()+'\nsv_lan 0\n'
p.write_text(s,encoding='utf-8')
PY
fi

echo
echo "[5/7] Checking UPnP/router mapping..."
if command -v upnpc >/dev/null 2>&1; then
  upnpc -s || true
  echo
  upnpc -l | grep -E "${PORT}|ExternalIPAddress" || true
else
  echo "[WARN] upnpc is not installed."
fi

echo
echo "[6/7] Restarting server and re-sending heartbeat..."
systemctl restart "$UNIT"
sleep 8

"$CTL" rcon "$SID" "sv_lan 0" || true
"$CTL" rcon "$SID" "setmaster enable" || true
"$CTL" rcon "$SID" "heartbeat" || true
sleep 2

echo
echo "[7/7] Final status..."
FINAL="$("$CTL" status "$SID")"
echo "$FINAL"

echo
echo "--- UDP LISTENER ---"
ss -lunp | grep -E "[:.]${PORT}[[:space:]]" || true

echo
echo "--- FIREWALL ---"
if command -v ufw >/dev/null 2>&1; then ufw status | grep -E "${PORT}|Status" || true; fi

echo
echo "================================================================"
echo " RESULT"
echo "================================================================"

python3 - "$NET_JSON" "$FINAL" "$PORT" <<'PY'
import json,sys
net_raw, final_raw, port = sys.argv[1], sys.argv[2], sys.argv[3]
try: net=json.loads(net_raw)
except: net={}
try: final=json.loads(final_raw)
except: final={}

print("service:", final.get("service"))
print("udp_listening:", final.get("udp_listening"))
q=final.get("query") or {}
print("query_ok:", final.get("query_ok"))
print("map:", q.get("map"))
print("players:", q.get("players"), "bots:", q.get("bots"))

upnp=net.get("upnp") or {}
print("upnp_mapped:", upnp.get("mapped", upnp.get("ok")))
print("router_external_ip:", net.get("router_external_ip",""))
print("panel_public_ip:", net.get("public_ip",""))
for w in net.get("warnings",[]) or []:
    print("WARNING:",w)

if final.get("service")=="active" and final.get("udp_listening"):
    print("LOCAL_SERVER_OK=YES")
else:
    print("LOCAL_SERVER_OK=NO")

if upnp and not upnp.get("mapped", upnp.get("ok",False)):
    print("PUBLIC_ROUTER_MAPPING_OK=NO")
    print(f"NEEDED_ROUTER_RULE=UDP {port} -> server LAN IP:{port}")
else:
    print("PUBLIC_ROUTER_MAPPING_OK=YES_OR_UNKNOWN")
PY

echo
echo "If LOCAL_SERVER_OK=YES but PUBLIC_ROUTER_MAPPING_OK=NO,"
echo "the game server itself is healthy; the router/NAT is blocking public access."
echo
echo "Log saved to: $LOG"
