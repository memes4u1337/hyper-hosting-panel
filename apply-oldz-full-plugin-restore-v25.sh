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
BACKUP="/root/oldz-full-plugins-v25-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -x "$LIVE" ]] || fail "missing $LIVE"
[[ -d "$CFGDIR" ]] || fail "missing $CFGDIR"
[[ -d "$PLUGDIR" ]] || fail "missing $PLUGDIR"

mkdir -p "$BACKUP"
cp -a "$CFGDIR" "$BACKUP/configs.before"

echo "================================================================"
echo " OLD ZOMBIE FULL PLUGIN RESTORE v25"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Restore all HYPER-HOST SAFE MODE plugins that physically exist..."
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

# Build active set first to avoid duplicates.
active=set()
for p in files:
    for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        st=line.strip()
        if not st or st.startswith(";") or st.startswith("#"):
            continue
        tok=st.split()[0]
        if tok.lower().endswith(".amxx"):
            active.add(tok.lower())

restored=[]
duplicates=[]
missing=[]

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
            missing.append((p.name,name))
            changed=True
            continue

        if low in active:
            out.append(f"; {name} ; already loaded from another plugins*.ini")
            duplicates.append((p.name,name))
            changed=True
            continue

        out.append(name)
        active.add(low)
        restored.append((p.name,name))
        changed=True

    if changed:
        p.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")

(backup/"restore-report.json").write_text(
    json.dumps(
        {"restored":restored,"duplicates":duplicates,"missing":missing},
        ensure_ascii=False,
        indent=2
    )+"\n",
    encoding="utf-8"
)

print("restored:",len(restored))
for cfg,name in restored:
    print(" +",cfg,"->",name)
print("duplicates skipped:",len(duplicates))
print("missing binaries:",len(missing))
PY

echo "[2/5] Count active plugins..."
python3 - "$CFGDIR" <<'PY'
from pathlib import Path
import sys
cfg=Path(sys.argv[1])
seen=set()
rows=[]
for p in sorted(cfg.glob("plugins*.ini")):
    if not p.is_file():
        continue
    for line in p.read_text(encoding="utf-8",errors="ignore").splitlines():
        st=line.strip()
        if not st or st.startswith(";") or st.startswith("#"):
            continue
        tok=st.split()[0]
        if not tok.lower().endswith(".amxx"):
            continue
        if tok.lower() in seen:
            continue
        seen.add(tok.lower())
        rows.append((tok,p.name))
for i,(name,cfgname) in enumerate(rows,1):
    print(f"{i:3d}. {name} [{cfgname}]")
print("TOTAL ACTIVE:",len(rows))
if len(rows) < 50:
    raise SystemExit("unexpectedly small active plugin set")
PY

echo "[3/5] Restart server ONCE..."
systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service"

echo "[4/5] Wait for controller/RCON readiness..."
READY=0
for i in $(seq 1 45); do
    STATUS="$("$LIVE" status "$SID" 2>/dev/null || true)"
    OK="$(python3 - "$STATUS" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    print(0); raise SystemExit
running=bool(d.get("running"))
query=bool(d.get("query_ok"))
service=str(d.get("service") or "")
print(1 if running and query and service=="active" else 0)
PY
)"
    printf " %02ds: ready=%s\n" "$i" "$OK"
    if [[ "$OK" == "1" ]]; then
        READY=1
        break
    fi
    sleep 1
done

if [[ "$READY" != "1" ]]; then
    echo
    echo "[ERROR] controller did not report ready within 45 sec."
    echo "Plugins were NOT rolled back automatically."
    echo "Current status:"
    "$LIVE" status "$SID" || true
    echo
    echo "Journal:"
    journalctl -u "hyper-cs16@${SID}.service" -n 160 --no-pager || true
    exit 1
fi

echo "[5/5] Verify loaded plugins through RCON..."
echo "--- STATUS ---"
"$LIVE" status "$SID" || true

echo "--- META LIST ---"
"$LIVE" rcon "$SID" "meta list" || true

echo "--- AMXX PLUGINS ---"
AMXX_OUT="$("$LIVE" rcon "$SID" "amxx plugins" || true)"
echo "$AMXX_OUT"

echo "--- SQL ADMINS ---"
"$LIVE" sql-admins-list "$SID" || true

python3 - "$AMXX_OUT" <<'PY'
import json,re,sys
raw=sys.argv[1]
try:
    d=json.loads(raw)
    out=str(d.get("output") or "")
except Exception:
    out=raw

required=[
    "zombie_plague40",
    "zmpl",
    "zm_vip",
    "oldz_credits_sql",
    "oldz_privilege_models_r8",
    "oldz_vip_weapon_limit",
]
missing=[x for x in required if x.lower() not in out.lower()]
print("required plugin markers missing:",missing)
if missing:
    raise SystemExit(2)

m=re.search(r'(\d+)\s+plugins?,\s+(\d+)\s+running',out,re.I)
if m:
    print("AMXX total:",m.group(1),"running:",m.group(2))
PY

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FULL PLUGIN RESTORE v25"
echo "================================================================"
echo "Server is ON and controller/A2S is responding."
echo "Full OLD ZOMBIE plugin set restored."
echo "FastDL: NOT MODIFIED"
echo "nginx:  NOT MODIFIED"
echo "site:   NOT MODIFIED"
echo "Backup: $BACKUP"
echo "================================================================"
