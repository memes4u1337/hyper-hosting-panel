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
BACKUP="/root/oldz-plugins-restore-v24-${STAMP}"

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

echo "================================================================"
echo " OLD ZOMBIE PLUGIN RESTORE FINAL v24"
echo " Server: #$SID"
echo " Port:   $PORT"
echo " Backup: $BACKUP"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/6] Restore ONLY HYPER-HOST SAFE MODE plugin lines..."
python3 - "$CFGDIR" "$PLUGDIR" "$BACKUP" <<'PY'
from pathlib import Path
import re,sys,json

cfgdir=Path(sys.argv[1])
plugdir=Path(sys.argv[2])
backup=Path(sys.argv[3])

safe_rx=re.compile(
    r'^\s*;\s*HYPER-HOST SAFE MODE\s*\[[^\]]*\]\s*:\s*([A-Za-z0-9_.-]+\.amxx)\s*$',
    re.I
)

files=[p for p in sorted(cfgdir.glob("plugins*.ini")) if p.is_file()]

# Plugins already enabled anywhere.
active=set()
for p in files:
    for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        st=line.strip()
        if not st or st.startswith(";") or st.startswith("#"):
            continue
        token=st.split()[0]
        if token.lower().endswith(".amxx"):
            active.add(token.lower())

restored=[]
duplicates=[]
missing=[]

# Prefer plugins-zplague.ini as the canonical loader for ZP core.
canonical={"zp_zclasses40.amxx":"plugins-zplague.ini",
           "zombie_plague40.amxx":"plugins-zplague.ini"}

for p in files:
    lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
    out=[]
    changed=False

    for line in lines:
        m=safe_rx.match(line)
        if not m:
            out.append(line)
            continue

        name=m.group(1)
        low=name.lower()

        if not (plugdir/name).is_file():
            out.append(f"; HYPER-HOST SAFE MODE [binary missing]: {name}")
            missing.append({"config":p.name,"plugin":name})
            changed=True
            continue

        # Already loaded elsewhere -> do not create duplicate.
        if low in active:
            out.append(f"; {name} ; already loaded from another plugins*.ini")
            duplicates.append({"config":p.name,"plugin":name})
            changed=True
            continue

        # If this is ZP core and canonical config exists, don't duplicate it.
        canon=canonical.get(low)
        if canon and (cfgdir/canon).exists() and p.name != canon:
            out.append(f"; {name} ; loaded by {canon}")
            duplicates.append({"config":p.name,"plugin":name})
            changed=True
            active.add(low)
            continue

        out.append(name)
        active.add(low)
        restored.append({"config":p.name,"plugin":name})
        changed=True

    if changed:
        p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")

report={
    "restored":restored,
    "duplicates_skipped":duplicates,
    "missing":missing,
}
(backup/"restore-report.json").write_text(
    json.dumps(report,ensure_ascii=False,indent=2)+"\n",
    encoding="utf-8"
)

print("restored:",len(restored))
for x in restored:
    print(" +",x["config"],"->",x["plugin"])

print("duplicates skipped:",len(duplicates))
for x in duplicates:
    print(" =",x["config"],"->",x["plugin"])

print("missing binaries:",len(missing))
for x in missing:
    print(" !",x["config"],"->",x["plugin"])
PY

echo "[2/6] Show resulting active plugin list before restart..."
python3 - "$CFGDIR" <<'PY'
from pathlib import Path
import sys
cfgdir=Path(sys.argv[1])
seen=set()
count=0
for p in sorted(cfgdir.glob("plugins*.ini")):
    if not p.is_file(): continue
    for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        st=line.strip()
        if not st or st.startswith(";") or st.startswith("#"): continue
        tok=st.split()[0]
        if not tok.lower().endswith(".amxx"): continue
        if tok.lower() in seen:
            print("DUPLICATE ACTIVE:",tok,"in",p.name)
            continue
        seen.add(tok.lower()); count+=1
        print(f"{count:3d}. {tok} [{p.name}]")
print("TOTAL ACTIVE:",count)
PY

echo "[3/6] Restart HLDS..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service" || true

echo "[4/6] Wait up to 45 seconds for Process + UDP..."
READY=0
for i in $(seq 1 45); do
    ACTIVE=0
    UDP=0
    systemctl is-active --quiet "hyper-cs16@${SID}.service" && ACTIVE=1 || true
    ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$" && UDP=1 || true

    printf " %02ds: service=%s udp=%s\n" "$i" "$ACTIVE" "$UDP"

    if [[ "$ACTIVE" -eq 1 && "$UDP" -eq 1 ]]; then
        READY=1
        break
    fi
    sleep 1
done

if [[ "$READY" -ne 1 ]]; then
    echo
    echo "[FAIL] Server really did not start with restored plugin set."
    echo "Rolling back plugins*.ini to exact pre-v24 state..."

    rm -f "$CFGDIR"/plugins*.ini
    cp -a "$BACKUP/configs.before"/plugins*.ini "$CFGDIR"/ 2>/dev/null || true

    systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
    systemctl restart "hyper-cs16@${SID}.service" || true
    sleep 5

    echo
    echo "===== SYSTEMD JOURNAL ====="
    journalctl -u "hyper-cs16@${SID}.service" -n 120 --no-pager || true

    echo
    echo "===== RECENT AMXX LOGS ====="
    find "$CSTRIKE/addons/amxmodx/logs" -maxdepth 1 -type f -name '*.log' \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 5 | cut -d' ' -f2- | \
      while read -r f; do
        echo "----- $f -----"
        tail -n 80 "$f" || true
      done

    fail "restored plugin set prevented HLDS startup; configs rolled back safely"
fi

echo "[5/6] Verify A2S + Metamod + AMXX..."
sleep 3

echo "--- STATUS ---"
"$LIVE" status "$SID" || true

echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- AMXX PLUGINS ---"
"$LIVE" rcon "$SID" "amxx plugins" || true

echo "--- SQL ADMINS ---"
"$LIVE" sql-admins-list "$SID" || true

echo "[6/6] Remaining intentionally-disabled entries..."
echo "--- SAFE MODE remaining ---"
grep -RniE '^[[:space:]]*;[[:space:]]*HYPER-HOST SAFE MODE' \
    "$CFGDIR"/plugins*.ini 2>/dev/null || true

echo
echo "--- Other intentionally disabled lines were preserved ---"
grep -RniE 'disabled: replaced|duplicate disabled|OLD - replaced|R6 DISABLED|quarantined invalid|skipped missing' \
    "$CFGDIR"/plugins*.ini 2>/dev/null || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE PLUGIN RESTORE v24"
echo "================================================================"
echo " Server Process/UDP: ON"
echo " FastDL: NOT MODIFIED"
echo " nginx:  NOT MODIFIED"
echo " site:   NOT MODIFIED"
echo " Backup: $BACKUP"
echo " Report: $BACKUP/restore-report.json"
echo "================================================================"
