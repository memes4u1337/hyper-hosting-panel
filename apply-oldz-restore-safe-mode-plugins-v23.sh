#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"

LIVE="/usr/local/sbin/hyper-cs16-ctl"
SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"
CFGDIR="$CSTRIKE/addons/amxmodx/configs"
PLUGDIR="$CSTRIKE/addons/amxmodx/plugins"
STATE="/var/lib/hyper-cs16/servers/$SID.json"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-plugins-restore-v23-${STAMP}"
REPORT="$BACKUP/report.tsv"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -x "$LIVE" ]] || fail "missing $LIVE"
[[ -d "$CFGDIR" ]] || fail "missing $CFGDIR"
[[ -d "$PLUGDIR" ]] || fail "missing $PLUGDIR"
[[ -f "$STATE" ]] || fail "missing $STATE"

PORT="$(python3 - "$STATE" <<'PY'
from pathlib import Path
import json,sys
d=json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(int(d.get("port") or 27015))
PY
)"

mkdir -p "$BACKUP"
cp -a "$CFGDIR" "$BACKUP/configs.before"
printf "plugin\tconfig\tresult\n" > "$REPORT"

echo "================================================================"
echo " OLD ZOMBIE SAFE-MODE PLUGIN RESTORE v23"
echo " Server: #$SID"
echo " Port:   $PORT"
echo " Backup: $BACKUP"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

server_ok() {
    systemctl is-active --quiet "hyper-cs16@${SID}.service" || return 1
    ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$" || return 1

    local out
    out="$("$LIVE" status "$SID" 2>/dev/null || true)"
    python3 - "$out" <<'PY' >/dev/null 2>&1
import json,sys
s=sys.argv[1]
try:
    d=json.loads(s)
except Exception:
    raise SystemExit(1)
ok=bool(d.get("running")) and bool(d.get("udp_listening"))
q=d.get("query_ok")
if q is False:
    raise SystemExit(1)
raise SystemExit(0 if ok else 1)
PY
}

restart_and_wait() {
    systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
    systemctl restart "hyper-cs16@${SID}.service" >/dev/null 2>&1 || return 1
    for _ in $(seq 1 15); do
        if server_ok; then
            return 0
        fi
        sleep 1
    done
    return 1
}

echo "[1/6] Verify current baseline is healthy..."
if ! server_ok; then
    echo "baseline not ready; restarting once..."
    restart_and_wait || fail "baseline server is not healthy; refusing plugin changes"
fi
echo "baseline: OK"

echo "[2/6] Build SAFE MODE candidate list..."
CAND="$BACKUP/candidates.tsv"
python3 - "$CFGDIR" "$PLUGDIR" > "$CAND" <<'PY'
from pathlib import Path
import re,sys

cfgdir=Path(sys.argv[1])
plugdir=Path(sys.argv[2])

safe=re.compile(
    r'^\s*;\s*HYPER-HOST SAFE MODE\s*\[[^\]]*\]\s*:\s*([A-Za-z0-9_.-]+\.amxx)\s*$',
    re.I
)

# Existing active plugin names anywhere in plugins*.ini.
active=set()
for f in sorted(cfgdir.glob("plugins*.ini")):
    if not f.is_file():
        continue
    for line in f.read_text(encoding="utf-8",errors="ignore").splitlines():
        st=line.strip()
        if not st or st.startswith(";") or st.startswith("#"):
            continue
        name=st.split()[0]
        if name.lower().endswith(".amxx"):
            active.add(name.lower())

# Desired order: core/framework first, then SQL/privileges, then weapons/features.
priority=[
    "zmpl.amxx",
    "admin_loader.amxx",
    "fresh_bans.amxx",
    "zm_vip.amxx",
    "oldz_credits_sql.amxx",
    "oldz_privilege_models_r8.amxx",
    "oldz_vip_weapon_limit.amxx",
    "new_vip_menu.amxx",
    "new_admin_menu.amxx",
    "oldz_vip_hook.amxx",
    "oldz_admin_hook.amxx",
    "oldz_chat_tags.amxx",
    "oldz_spectators.amxx",
    "oldz_damager.amxx",
    "oldz_asimov_admin.amxx",
    "oldz_sprifle_vip.amxx",
    "oldz_balrog_vip.amxx",
    "oldz_akblood_vip.amxx",
    "oldz_shield_vip.amxx",
    "oldz_frostm4_vip.amxx",
    "oldz_akm_vip.amxx",
    "oldz_dbarrel_vip.amxx",
    "oldz_scar_admin.amxx",
    "oldz_crossbow_admin.amxx",
    "oldz_balrogm4_admin.amxx",
    "oldz_lavam4_admin.amxx",
    "oldz_level_system.amxx",
    "oldz_level_ancient_keeper.amxx",
    "oldz_level_janus7.amxx",
    "oldz_level_pkm_th1.amxx",
    "oldz_level_sf11_balrog.amxx",
    "oldz_level_falconex.amxx",
    "oldz_level_m134_galaxy.amxx",
    "zp_class_teleport_vip_r8.amxx",
    "zp_class_holfi_admin_r8.amxx",
    "oldz_bans_sql.amxx",
    "oldz_store_sql.amxx",
    "oldz_store_sync.amxx",
    "oldz_store_models.amxx",
    "oldz_top_stats.amxx",
]

rank={x:i for i,x in enumerate(priority)}
rows=[]
seen=set()

for f in sorted(cfgdir.glob("plugins*.ini")):
    if not f.is_file():
        continue
    for lineno,line in enumerate(
        f.read_text(encoding="utf-8",errors="ignore").splitlines(),1
    ):
        m=safe.match(line)
        if not m:
            continue
        name=m.group(1)
        low=name.lower()

        # Do not enable a duplicate of a plugin already active elsewhere
        # (e.g. zp_zclasses40 is already active in plugins-zplague.ini).
        if low in active:
            continue
        if low in seen:
            continue
        if not (plugdir/name).is_file():
            continue

        seen.add(low)
        rows.append((rank.get(low,10000),low,str(f),lineno,name))

rows.sort(key=lambda x:(x[0],x[1],x[2],x[3]))
for _,_,f,lineno,name in rows:
    print(f"{f}\t{lineno}\t{name}")
PY

COUNT="$(wc -l < "$CAND" | tr -d ' ')"
echo "SAFE MODE candidates with existing .amxx: $COUNT"
cat "$CAND"

echo "[3/6] Restore candidates one-by-one with live health checks..."
ENABLED=0
FAILED=0

while IFS=$'\t' read -r CFG LINE PLUGIN; do
    [[ -n "${PLUGIN:-}" ]] || continue

    echo
    echo ">>> Testing $PLUGIN"

    cp -a "$CFG" "$BACKUP/$(basename "$CFG").pre-${PLUGIN}.bak"

    python3 - "$CFG" "$PLUGIN" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
plugin=sys.argv[2]
text=p.read_text(encoding="utf-8",errors="ignore")
rx=re.compile(
    r'^\s*;\s*HYPER-HOST SAFE MODE\s*\[[^\]]*\]\s*:\s*'
    + re.escape(plugin)
    + r'\s*$',
    re.I
)
out=[]
done=False
for line in text.splitlines():
    if not done and rx.match(line):
        out.append(plugin)
        done=True
    else:
        out.append(line)
if not done:
    raise SystemExit("SAFE MODE line not found for "+plugin)
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
PY

    if restart_and_wait; then
        echo "[OK] $PLUGIN"
        printf "%s\t%s\tENABLED\n" "$PLUGIN" "$CFG" >> "$REPORT"
        ENABLED=$((ENABLED+1))
    else
        echo "[FAIL] $PLUGIN caused unhealthy startup; reverting only this plugin"

        python3 - "$CFG" "$PLUGIN" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
plugin=sys.argv[2]
text=p.read_text(encoding="utf-8",errors="ignore")
out=[]
done=False
for line in text.splitlines():
    st=line.strip()
    if not done and st==plugin:
        out.append(f"; HYPER-HOST v23 TEST FAILED: {plugin}")
        done=True
    else:
        out.append(line)
p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")
PY

        restart_and_wait || fail "server did not recover after reverting $PLUGIN"
        printf "%s\t%s\tFAILED_AND_DISABLED\n" "$PLUGIN" "$CFG" >> "$REPORT"
        FAILED=$((FAILED+1))
    fi
done < "$CAND"

echo "[4/6] Remove SAFE MODE duplicate of zp_zclasses40 if it remains..."
python3 - "$CFGDIR" <<'PY'
from pathlib import Path
import re,sys
cfg=Path(sys.argv[1])
# zp_zclasses40 is intentionally loaded once from plugins-zplague.ini.
for name in ("plugins.ini","plugins-zmpl.ini"):
    p=cfg/name
    if not p.exists():
        continue
    text=p.read_text(encoding="utf-8",errors="ignore")
    text=re.sub(
        r'(?im)^\s*;\s*HYPER-HOST SAFE MODE\s*\[[^\]]*\]\s*:\s*zp_zclasses40\.amxx\s*$',
        '; zp_zclasses40.amxx ; loaded by plugins-zplague.ini',
        text
    )
    p.write_text(text,encoding="utf-8")
PY

echo "[5/6] Final restart and plugin inventory..."
restart_and_wait || fail "final server health check failed"

echo "--- STATUS ---"
"$LIVE" status "$SID" || true

echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- AMXX PLUGINS ---"
"$LIVE" rcon "$SID" "amxx plugins" || true

echo "--- SQL ADMINS ---"
"$LIVE" sql-admins-list "$SID" || true

echo "[6/6] Report..."
echo "Enabled successfully: $ENABLED"
echo "Failed and left disabled: $FAILED"
echo
cat "$REPORT"

echo
echo "Remaining SAFE MODE lines:"
grep -RniE '^[[:space:]]*;[[:space:]]*HYPER-HOST SAFE MODE' \
  "$CFGDIR"/plugins*.ini 2>/dev/null || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE PLUGIN RESTORE v23"
echo "================================================================"
echo "Enabled: $ENABLED"
echo "Failed:  $FAILED"
echo "Report:  $REPORT"
echo "Backup:  $BACKUP"
echo
echo "FastDL: NOT MODIFIED"
echo "nginx:  NOT MODIFIED"
echo "site:   NOT MODIFIED"
echo "================================================================"
