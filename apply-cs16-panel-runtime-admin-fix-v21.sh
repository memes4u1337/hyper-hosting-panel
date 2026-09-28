#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"

CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
UI="$ROOT/cs16-panel/public/index.php"
SERVER="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER/cstrike"
CFGDIR="$CSTRIKE/addons/amxmodx/configs"
PLUGDIR="$CSTRIKE/addons/amxmodx/plugins"
MMCFG="$CSTRIKE/addons/metamod/plugins.ini"
LIBLIST="$CSTRIKE/liblist.gam"
STATE="/var/lib/hyper-cs16/servers/$SID.json"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-panel-runtime-admin-v21-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing controller: $CTL"
[[ -d "$CSTRIKE" ]] || fail "missing server: $CSTRIKE"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -f "$UI" ]] && cp -a "$UI" "$BACKUP/index.php.before" || true
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/state.before.json" || true
[[ -d "$CFGDIR" ]] && cp -a "$CFGDIR" "$BACKUP/amxx-configs.before" || true
[[ -f "$MMCFG" ]] && cp -a "$MMCFG" "$BACKUP/metamod-plugins.before.ini" || true
[[ -f "$LIBLIST" ]] && cp -a "$LIBLIST" "$BACKUP/liblist.before.gam" || true

echo "================================================================"
echo " HYPER-HOST PANEL + ZM RUNTIME + SQL ADMINS v21"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/9] Restore SQL Admin Manager commands..."
SQL_PATCH="$ROOT/apply-cs16-sql-admin-manager-v1.sh"
if [[ -f "$SQL_PATCH" ]]; then
    chmod +x "$SQL_PATCH"
    bash "$SQL_PATCH" "$ROOT" "$SID"
else
    fail "missing $SQL_PATCH in repository"
fi

[[ -f "$CTL" ]] || fail "controller disappeared after SQL admin patch"

echo "[2/9] Patch Quick Map so it NEVER quarantines plugins..."
python3 - "$CTL" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="strict")

# Replace only the destructive tail of activate_map().
old = """    rollback=old_map if old_map and (Path(c['path'])/'cstrike/maps'/(old_map+'.bsp')).is_file() else _choose_safe_map(c)
    c['start_map']=rollback
    _persist_start_map(c,rollback)
    recovery=recover_server(sid,False)
    raise RuntimeError(f'Map {map_name} could not be started safely. Server was automatically restored on {rollback}. Reason: {detail}; recovery actions: {", ".join(recovery.get("actions",[])) or "safe restart"}')
"""
new = """    rollback=old_map if old_map and (Path(c['path'])/'cstrike/maps'/(old_map+'.bsp')).is_file() else _choose_safe_map(c)
    c['start_map']=rollback
    _persist_start_map(c,rollback)
    # IMPORTANT: a map change must never invoke generic content recovery.
    # recover_server()/repair_amxx_content() may quarantine perfectly valid custom
    # plugins based on stale startup/resource logs. Roll back the map only.
    run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
    run(['systemctl','restart',f'hyper-cs16@{sid}.service'],check=False)
    rb_ok,rb_detail=wait_server_ready(c,25.0)
    raise RuntimeError(
        f'Map {map_name} could not be started safely. Rolled back to {rollback} WITHOUT changing plugins. '
        f'Reason: {detail}; rollback_ready={rb_ok}; rollback_detail={rb_detail}'
    )
"""

if old in s:
    s=s.replace(old,new,1)
elif "recovery=recover_server(sid,False)" in s:
    raise SystemExit("activate_map layout changed; refusing unsafe automatic replacement")
else:
    print("Quick Map destructive recovery already absent")

marker="# HYPER-HOST QUICK MAP NON-DESTRUCTIVE v21"
if marker not in s:
    s=s.replace("#!/usr/bin/env python3\n","#!/usr/bin/env python3\n"+marker+"\n",1)

p.write_text(s,encoding="utf-8")
print("patched:",p)
PY

python3 -m py_compile "$CTL"

echo "[3/9] Restore AMXX plugin entries quarantined by HYPER-HOST..."
python3 - "$CFGDIR" "$PLUGDIR" "$BACKUP" <<'PY'
from pathlib import Path
import re,sys,json,shutil

cfgdir=Path(sys.argv[1])
plugdir=Path(sys.argv[2])
backup=Path(sys.argv[3])

restored=[]
missing=[]
files=[]

if cfgdir.is_dir():
    for f in sorted(cfgdir.glob("plugins*.ini")):
        if f.is_file():
            files.append(f)

for f in files:
    text=f.read_text(encoding="utf-8",errors="ignore")
    out=[]
    changed=False
    for line in text.splitlines():
        # Lines created by _disable_plugin_in_file():
        # ; HYPER-HOST QUARANTINE [reason]: plugin.amxx
        m=re.match(r'^\s*;\s*HYPER-HOST QUARANTINE\s*\[[^\]]*\]\s*:\s*([A-Za-z0-9_.-]+\.amxx)\s*$',line,re.I)
        if m:
            name=m.group(1)
            if (plugdir/name).is_file():
                out.append(name)
                restored.append({"file":f.name,"plugin":name})
                changed=True
                continue
            missing.append({"file":f.name,"plugin":name})
        out.append(line)
    if changed:
        f.write_text("\n".join(out).rstrip()+"\n",encoding="utf-8")

report={"restored":restored,"missing":missing}
(backup/"plugin-restore.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("quarantine entries restored:",len(restored))
for x in restored:
    print(" ",x["file"],"->",x["plugin"])
print("quarantined entries whose .amxx is missing:",len(missing))
PY

echo "[4/9] Restore Zombie Plague plugin list if auto-recovery disabled it..."
python3 - "$CFGDIR" "$PLUGDIR" "$STATE" <<'PY'
from pathlib import Path
import json,sys

cfg=Path(sys.argv[1]); plug=Path(sys.argv[2]); state=Path(sys.argv[3])
enabled=cfg/"plugins-zplague.ini"
disabled=cfg/"disabled-zplague.ini"

cores=[
    "zombie_plague40.amxx",
    "zp_zclasses40.amxx",
]
has_core=(plug/"zombie_plague40.amxx").is_file()

actions=[]
if has_core and not enabled.exists() and disabled.exists():
    disabled.rename(enabled)
    actions.append("disabled-zplague.ini -> plugins-zplague.ini")

if has_core and not enabled.exists():
    existing=[x for x in cores if (plug/x).is_file()]
    if existing:
        enabled.write_text("\n".join(existing)+"\n",encoding="utf-8")
        actions.append("created plugins-zplague.ini from installed ZP core files")

if has_core and state.exists():
    try:
        d=json.loads(state.read_text(encoding="utf-8"))
        if d.get("game_mode")!="zp43":
            d["game_mode"]="zp43"
            tmp=state.with_name("."+state.name+".v21.tmp")
            tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
            tmp.replace(state)
            actions.append("state game_mode -> zp43")
    except Exception as exc:
        print("state warning:",exc)

print("ZP core installed:",has_core)
for a in actions:
    print(" ",a)
PY

echo "[5/9] Ensure Metamod loads AMX Mod X (without replacing existing config)..."
python3 - "$CSTRIKE" "$MMCFG" "$LIBLIST" <<'PY'
from pathlib import Path
import re,sys

cstrike=Path(sys.argv[1]); mmcfg=Path(sys.argv[2]); liblist=Path(sys.argv[3])

metamod_candidates=[
    cstrike/"addons/metamod/dlls/metamod.so",
    cstrike/"addons/metamod/dlls/metamod_i386.so",
    cstrike/"addons/metamod/metamod.so",
]
amxx_candidates=[
    cstrike/"addons/amxmodx/dlls/amxmodx_mm_i386.so",
    cstrike/"addons/amxmodx/dlls/amxmodx_mm.so",
]

meta=next((p for p in metamod_candidates if p.is_file()),None)
amxx=next((p for p in amxx_candidates if p.is_file()),None)

print("metamod binary:",meta or "MISSING")
print("amxx binary:",amxx or "MISSING")

if not meta:
    raise SystemExit("Metamod binary is missing; refusing to invent/reinstall files")
if not amxx:
    raise SystemExit("AMX Mod X binary is missing; refusing to invent/reinstall files")

# liblist.gam: only make sure gamedll_linux points to an actually existing metamod binary.
libtext=liblist.read_text(encoding="utf-8",errors="ignore") if liblist.exists() else ""
rel_meta=str(meta.relative_to(cstrike)).replace("\\","/")
line=f'gamedll_linux "{rel_meta}"'
if re.search(r'(?im)^\s*gamedll_linux\s+.*$',libtext):
    libtext=re.sub(r'(?im)^\s*gamedll_linux\s+.*$',line,libtext,count=1)
else:
    libtext=libtext.rstrip()+"\n"+line+"\n"
liblist.write_text(libtext,encoding="utf-8")

# metamod/plugins.ini: ensure AMXX is active once.
mmcfg.parent.mkdir(parents=True,exist_ok=True)
text=mmcfg.read_text(encoding="utf-8",errors="ignore") if mmcfg.exists() else ""
rel_amxx=str(amxx.relative_to(cstrike)).replace("\\","/")
active=False
for ln in text.splitlines():
    st=ln.strip()
    if not st or st.startswith(";") or st.startswith("#"):
        continue
    if "amxmodx" in st.lower() and ".so" in st.lower():
        active=True
        break
if not active:
    text=text.rstrip()+("\n" if text.strip() else "")+f'linux {rel_amxx}\n'
    mmcfg.write_text(text,encoding="utf-8")
    print("added AMXX to metamod/plugins.ini:",rel_amxx)
else:
    print("AMXX already active in metamod/plugins.ini")
PY

echo "[6/9] Install patched controller and verify SQL commands exist..."
install -m 0755 "$CTL" "$LIVE_CTL"
python3 -m py_compile "$LIVE_CTL"

HELP="$("$LIVE_CTL" --help 2>&1 || true)"
echo "$HELP" | grep -q "sql-admins-list" || fail "sql-admins-list still missing after SQL Admin Manager patch"
echo "$HELP" | grep -q "sql-admins-save" || fail "sql-admins-save still missing after SQL Admin Manager patch"
echo "$HELP" | grep -q "sql-admins-delete" || fail "sql-admins-delete still missing after SQL Admin Manager patch"
echo "SQL admin commands: OK"

echo "[7/9] Restart server WITHOUT generic auto-recovery..."
systemctl reset-failed "hyper-cs16@${SID}.service" || true
systemctl restart "hyper-cs16@${SID}.service"
sleep 4

echo "[8/9] Verify Process / UDP / A2S / AMXX / plugins..."
STATUS="$("$LIVE_CTL" status "$SID" || true)"
echo "$STATUS"

echo
echo "--- metamod list ---"
"$LIVE_CTL" rcon "$SID" "meta list" || true

echo
echo "--- amxx plugins ---"
"$LIVE_CTL" rcon "$SID" "amxx plugins" || true

echo
echo "--- zp status ---"
"$LIVE_CTL" rcon "$SID" "zp_on" || true

echo
echo "--- panel mods-status ---"
"$LIVE_CTL" mods-status "$SID" || true

echo "[9/9] Verify SQL admin manager..."
"$LIVE_CTL" sql-admins-list "$SID" || true

echo
echo "================================================================"
echo " [SUCCESS] PANEL/RUNTIME/SQL ADMIN FIX v21 COMPLETE"
echo "================================================================"
echo " Server: #$SID"
echo " FastDL: NOT MODIFIED"
echo " nginx:  NOT MODIFIED"
echo " site:   NOT MODIFIED"
echo
echo "Changes:"
echo "  - SQL admin commands restored"
echo "  - Quick Map no longer invokes plugin quarantine/recovery"
echo "  - HYPER-HOST quarantined plugin entries restored when .amxx exists"
echo "  - Zombie Plague plugin list restored when ZP core exists"
echo "  - Metamod -> AMXX linkage verified/repaired"
echo "  - server restarted normally"
echo
echo "Backup: $BACKUP"
echo "================================================================"
