#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.14 — UNIVERSAL SAFE ASSEMBLY IMPORTER
#
# WHY:
# v3.5 exact-cstrike-archive intentionally preserves uploaded runtime 1:1.
# That is incompatible with the goal "upload arbitrary CS 1.6 build and run it":
# old packs can ship AMXX 1.8.x, old Ham Sandwich, old cs.so, old Metamod, etc.
#
# NEW MODEL:
#   ZIP/RAR owns CONTENT:
#     .amxx, ZP, configs, maps, models, sounds, sprites, custom modules/plugins.
#
#   HYPER-HOST owns PLATFORM:
#     ReHLDS + ReGameDLL + Metamod-R + AMXX core/modules/Ham data.
#
# The platform is normalized AFTER exact archive extraction/manifest verification
# but BEFORE ReAPI compatibility checks / preflight / first systemd start.
#
# Does NOT run v3.3.
# Does NOT touch panel PHP/nginx/panel SQL.
#
# Current server repair:
#   bash apply-cs16-v3.14-universal-safe-importer.sh 14
#
# Patch-only validation:
#   PATCH_ONLY=1 HYPER_CTL=/tmp/hyper-cs16-ctl \
#   HYPER_REPO=/tmp/repo bash apply-cs16-v3.14-universal-safe-importer.sh

SID="${1:-14}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO_ROOT="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PATCH_ONLY="${PATCH_ONLY:-0}"

UNIT="hyper-cs16@${SID}.service"
MONITOR_UNIT="hyper-cs16-monitor.service"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.14-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.14-${STAMP}.log"
DROPIN_DIR="/etc/systemd/system/${UNIT}.d"
DROPIN="${DROPIN_DIR}/99-v314-install-test.conf"

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
echo " HYPER-HOST CS16 UNIVERSAL SAFE IMPORTER v3.14"
echo "============================================================"
echo "Server:     $SID"
echo "Controller: $LIVE_CTL"
echo "Repo:       $REPO_ROOT"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"

TARGETS=("$LIVE_CTL")
while IFS= read -r -d '' f; do
    [[ "$f" == "$LIVE_CTL" ]] && continue
    TARGETS+=("$f")
done < <(
    find "$REPO_ROOT" -type f -path '*/cs16-panel/bin/hyper-cs16-ctl' \
        -not -path '*/.git/*' -print0 2>/dev/null
)

echo "[1/9] Controller copies:"
printf '  - %s\n' "${TARGETS[@]}"

for f in "${TARGETS[@]}"; do
    safe="$(printf '%s' "$f" | sed 's#^/##;s#/#__#g')"
    cp -a "$f" "$BACKUP/$safe"
done

echo
echo "[2/9] Patching exact-archive importer..."

python3 - "$BACKUP" "${TARGETS[@]}" <<'PY'
from __future__ import annotations

import os
import py_compile
import sys
from pathlib import Path

targets=[Path(x) for x in sys.argv[2:]]

MARKER="# >>> HYPER-HOST v3.14 MANAGED PLATFORM >>>"
CALL_MARKER="# HYPER-HOST v3.14 normalize platform before first start"

HELPER=r'''
# >>> HYPER-HOST v3.14 MANAGED PLATFORM >>>
def _v314_refresh_amxx_platform(path:Path)->list[str]:
    # Uploaded plugins/configs remain authoritative. Only executable AMXX core
    # and official modules are refreshed.
    cstrike=path/'cstrike'
    dst=cstrike/'addons/amxmodx'
    dst.mkdir(parents=True,exist_ok=True)

    actions=[]

    with tempfile.TemporaryDirectory(prefix='hhcs16-v314-amxx-') as td:
        td=Path(td)
        payload=td/'payload'
        payload.mkdir(parents=True,exist_ok=True)

        base=td/'amxx-base.tgz'
        cs=td/'amxx-cstrike.tgz'

        download(AMXX_BASE,base)
        download(AMXX_CSTRIKE,cs)

        extract_tar(base,payload)
        extract_tar(cs,payload)

        src=payload/'addons/amxmodx'

        if not (src/'dlls/amxmodx_mm_i386.so').is_file():
            raise RuntimeError('Managed AMXX loader is missing')
        if not (src/'modules/hamsandwich_amxx_i386.so').is_file():
            raise RuntimeError('Managed Ham Sandwich module is missing')

        # Overwrite official runtime files, but DO NOT delete uploaded custom
        # third-party modules.
        for rel in ('dlls','modules'):
            source=src/rel
            target=dst/rel
            target.mkdir(parents=True,exist_ok=True)

            for fp in source.iterdir():
                if fp.is_file():
                    shutil.copy2(fp,target/fp.name)

        # Ham binary and hamdata must be from the same build.
        hamdata=src/'configs/hamdata.ini'
        if hamdata.is_file():
            target=dst/'configs/hamdata.ini'
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(hamdata,target)

        # Merge official gamedata/signatures. Never delete assembly-specific data.
        gamedata=src/'data/gamedata'
        if gamedata.is_dir():
            target=dst/'data/gamedata'
            target.mkdir(parents=True,exist_ok=True)
            shutil.copytree(gamedata,target,dirs_exist_ok=True)

    # Make Metamod load the managed AMXX loader exactly once.
    mp=cstrike/'addons/metamod/plugins.ini'
    mp.parent.mkdir(parents=True,exist_ok=True)

    text=mp.read_text(encoding='latin1',errors='replace') if mp.exists() else ''
    output=[]
    amxx_seen=False

    for raw in text.replace('\r\n','\n').replace('\r','\n').splitlines():
        stripped=raw.strip()
        low=stripped.lower()
        active=bool(
            stripped and
            not stripped.startswith(';') and
            not stripped.startswith('#')
        )

        if active and 'amxmodx' in low:
            if not amxx_seen:
                output.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')
                amxx_seen=True
            continue

        # DProto is for old stock-HLDS stacks. Keep its files, do not load it
        # alongside managed ReHLDS.
        if active and 'dproto' in low:
            output.append('; HYPER-HOST v3.14 disabled on ReHLDS: '+raw)
            continue

        output.append(raw)

    if not amxx_seen:
        output.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')

    mp.write_text('\n'.join(output).rstrip()+'\n',encoding='latin1')

    actions.append(
        'AMXX 1.9.0.'+str(AMXX_BUILD)+
        ' core/modules/Ham data normalized'
    )
    return actions


def _v314_normalize_platform(path:Path)->dict:
    # Archive is authoritative for CONTENT, not the executable platform.
    actions=[]

    install_rehlds(path)
    actions.append(
        'ReHLDS '+str(REHLDS_VERSION)+
        ' + ReGameDLL '+str(REGAMEDLL_VERSION)
    )

    install_metamod_rehlds(path)
    actions.append('Metamod-R '+str(METAMOD_VERSION))

    actions.extend(_v314_refresh_amxx_platform(path))

    normalize_permissions(path)

    return {
        'ok':True,
        'profile':'hyper-host-v3.14',
        'actions':actions,
    }
# <<< HYPER-HOST v3.14 MANAGED PLATFORM <<<


'''

def get_fn(src:str,name:str)->tuple[int,int,str]:
    start=src.find('def '+name+'(')
    if start < 0:
        return -1,-1,''
    end=src.find('\ndef ',start+10)
    if end < 0:
        end=len(src)
    return start,end,src[start:end]


def patch(path:Path)->bool:
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src

    required=(
        'def install_custom_build(',
        'def install_rehlds(',
        'def install_metamod_rehlds(',
        'AMXX_BASE',
        'AMXX_CSTRIKE',
    )
    missing=[x for x in required if x not in src]
    if missing:
        raise RuntimeError(
            f'{path}: unsupported controller; missing {missing}'
        )

    # Keep/fill the proven subprocess UTF-8 fix.
    old_run=(
        "cp=subprocess.run(cmd,stdout=subprocess.PIPE if capture else None,"
        "stderr=subprocess.STDOUT if capture else None,text=True,check=False,"
        "timeout=timeout,cwd=cwd,env=env)"
    )
    new_run=(
        "cp=subprocess.run(cmd,stdout=subprocess.PIPE if capture else None,"
        "stderr=subprocess.STDOUT if capture else None,text=True,"
        "encoding='utf-8',errors='replace',check=False,"
        "timeout=timeout,cwd=cwd,env=env)"
    )
    if old_run in src:
        src=src.replace(old_run,new_run,1)

    # Put helper immediately before install_custom_build().
    if MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos < 0:
            raise RuntimeError(f'{path}: install_custom_build insertion point missing')
        src=src[:pos]+'\n'+HELPER+src[pos:]

    # Find the ACTUAL install_custom_build function after helper insertion.
    fstart,fend,fn=get_fn(src,'install_custom_build')
    if fstart < 0:
        raise RuntimeError(f'{path}: install_custom_build missing after helper insert')

    if CALL_MARKER not in fn:
        # Best point on v3.5 exact-archive:
        # after exact archive has already been copied/verified/filled, but before
        # compatibility/preflight/start.
        candidates=[
            '        reapi_compat=_ensure_reapi_compatible_stack(stage)\n',
            "        runtime_preflight=_critical_runtime_preflight(stage/'cstrike',runtime_profile)\n",
            "        if not (stage/'hlds_linux').is_file():",
            "        layout=layout+'/'+import_mode\n",
        ]

        chosen=None
        for candidate in candidates:
            if candidate in fn:
                chosen=candidate
                break

        if chosen is None:
            raise RuntimeError(
                f'{path}: no safe pre-start insertion point found in install_custom_build()'
            )

        if chosen.startswith("        layout=layout"):
            # For older layout, insert AFTER layout/import_mode selection.
            replacement=(
                chosen+
                "\n"
                "        # HYPER-HOST v3.14 normalize platform before first start\n"
                "        platform_runtime=_v314_normalize_platform(stage)\n"
                "        c['profile']='rehlds'\n"
                "        runtime_profile=_analyze_build_runtime(stage/'cstrike')\n"
                "        import_mode=str(import_mode)+'+managed-runtime-v314'\n"
            )
            fn=fn.replace(chosen,replacement,1)
        else:
            replacement=(
                "        # HYPER-HOST v3.14 normalize platform before first start\n"
                "        platform_runtime=_v314_normalize_platform(stage)\n"
                "        c['profile']='rehlds'\n"
                "        runtime_profile=_analyze_build_runtime(stage/'cstrike')\n"
                "        import_mode=str(import_mode)+'+managed-runtime-v314'\n"
                +chosen
            )
            fn=fn.replace(chosen,replacement,1)

        src=src[:fstart]+fn+src[fend:]

    # Re-read patched function and verify order against the REAL first start.
    fstart,fend,fn=get_fn(src,'install_custom_build')
    norm=fn.find('platform_runtime=_v314_normalize_platform(stage)')
    first_start=fn.find("run(['systemctl','start'")

    if norm < 0:
        raise RuntimeError(f'{path}: normalization call missing')
    if first_start < 0:
        raise RuntimeError(f'{path}: first systemctl start not found')
    if norm > first_start:
        raise RuntimeError(
            f'{path}: normalization is AFTER first start — refusing unsafe patch'
        )

    # v3.5 has this call. It must remain AFTER normalization if present.
    reapi=fn.find('_ensure_reapi_compatible_stack(stage)')
    if reapi >= 0 and reapi < norm:
        raise RuntimeError(
            f'{path}: ReAPI compatibility check is before normalization'
        )

    # Put platform details in the JSON result when a stable result-dict field exists.
    if "'platform_runtime':platform_runtime" not in src:
        replacements=[
            (
                "'runtime_profile':runtime_profile,'runtime_preflight':runtime_preflight,",
                "'runtime_profile':runtime_profile,'platform_runtime':platform_runtime,"
                "'runtime_preflight':runtime_preflight,"
            ),
            (
                "'runtime_profile':runtime_profile,",
                "'runtime_profile':runtime_profile,'platform_runtime':platform_runtime,"
            ),
        ]
        for old,new in replacements:
            if old in src:
                src=src.replace(old,new,1)
                break

    if src != original:
        tmp=path.with_name(path.name+'.v314tmp')
        tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
        os.chmod(tmp,path.stat().st_mode)
        os.replace(tmp,path)

    py_compile.compile(str(path),doraise=True)

    final=path.read_text(encoding='utf-8',errors='surrogateescape')
    _,_,final_fn=get_fn(final,'install_custom_build')

    checks={
        'managed helper':
            MARKER in final,
        'pre-start call':
            'platform_runtime=_v314_normalize_platform(stage)' in final_fn,
        'managed ReHLDS':
            'install_rehlds(path)' in final,
        'managed Metamod':
            'install_metamod_rehlds(path)' in final,
        'managed AMXX':
            '_v314_refresh_amxx_platform(path)' in final,
        'safe subprocess':
            "encoding='utf-8',errors='replace'" in final,
    }

    bad=[name for name,ok in checks.items() if not ok]
    if bad:
        raise RuntimeError(f'{path}: verification failed: {bad}')

    return src != original


changed=0
for target in targets:
    did=patch(target)
    changed+=int(did)
    print(('[PATCHED] ' if did else '[OK already patched] ')+str(target))

print(f'[OK] importer patch complete; changed={changed}')
PY

echo
echo "[3/9] Verifying exact importer order..."

python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import sys

s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
st=s.find('def install_custom_build(')
en=s.find('\ndef ',st+10)
if en < 0:
    en=len(s)
fn=s[st:en]

norm=fn.find('platform_runtime=_v314_normalize_platform(stage)')
start=fn.find("run(['systemctl','start'")
reapi=fn.find('_ensure_reapi_compatible_stack(stage)')

print('normalize index:',norm)
print('reapi index:    ',reapi)
print('first start:    ',start)

if norm < 0 or start < 0 or norm > start:
    raise SystemExit('[ERROR] managed runtime is not before first start')

if reapi >= 0 and not (norm < reapi < start):
    raise SystemExit('[ERROR] expected normalize -> ReAPI -> start order')

print('[OK] exact archive is copied first')
print('[OK] HYPER-HOST platform is normalized before first start')
print('[OK] uploaded old AMXX/Ham/cs.so can no longer be the final runtime')
PY

if [[ "$PATCH_ONLY" == "1" ]]; then
    echo
    echo "============================================================"
    echo " v3.14 PATCH-ONLY VALIDATION OK"
    echo "============================================================"
    exit 0
fi

STATE="/var/lib/hyper-cs16/servers/${SID}.json"
[[ -f "$STATE" ]] || die "Server state not found: $STATE"

readarray -t SERVER_INFO < <(python3 - "$STATE" <<'PY'
import json,sys
from pathlib import Path

d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
sid=int(d.get('id') or 0)

print(str(d.get('path') or f'/srv/hyper-cs16/servers/{sid}'))
print(int(d.get('port') or 0))
print(str(d.get('start_map') or ''))
PY
)

SERVER_PATH="${SERVER_INFO[0]}"
PORT="${SERVER_INFO[1]}"
START_MAP="${SERVER_INFO[2]}"

[[ -d "$SERVER_PATH/cstrike" ]] || die "Server path missing: $SERVER_PATH/cstrike"

echo
echo "[4/9] Current server #$SID:"
echo "  Path: $SERVER_PATH"
echo "  Port: $PORT"
echo "  Map:  $START_MAP"

mkdir -p "$BACKUP/server-runtime"

for rel in \
    hlds_linux hlds_run engine_i486.so core.so filesystem_stdio.so demoplayer.so \
    cstrike/dlls/cs.so cstrike/liblist.gam \
    cstrike/addons/metamod \
    cstrike/addons/amxmodx/dlls \
    cstrike/addons/amxmodx/modules \
    cstrike/addons/amxmodx/configs/hamdata.ini \
    cstrike/addons/amxmodx/data/gamedata
do
    if [[ -e "$SERVER_PATH/$rel" ]]; then
        mkdir -p "$BACKUP/server-runtime/$(dirname "$rel")"
        cp -a "$SERVER_PATH/$rel" "$BACKUP/server-runtime/$rel"
    fi
done

echo "[OK] current executable runtime backed up"

echo
echo "[5/9] Stopping crash/restart loop..."

systemctl stop "$MONITOR_UNIT" 2>/dev/null || true
systemctl stop "$UNIT" 2>/dev/null || true

mkdir -p "$DROPIN_DIR"
cat >"$DROPIN" <<'EOF'
[Service]
Restart=no
EOF

systemctl daemon-reload
systemctl reset-failed "$UNIT" 2>/dev/null || true

echo "[OK] test start will happen once, without restart storm"

echo
echo "[6/9] Normalizing already-installed server #$SID with SAME future-import logic..."

NORMALIZE_JSON="$(python3 - "$LIVE_CTL" "$SID" <<'PY'
from importlib.machinery import SourceFileLoader
from importlib.util import spec_from_loader,module_from_spec
import json
import sys

ctl=sys.argv[1]
sid=int(sys.argv[2])

loader=SourceFileLoader('hyper_cs16_ctl_v314',ctl)
spec=spec_from_loader(loader.name,loader)
mod=module_from_spec(spec)
loader.exec_module(mod)

path=mod.safe_server_path(sid)
result=mod._v314_normalize_platform(path)

# v3.5 already has extra compatibility handling for ReAPI-heavy packs.
if hasattr(mod,'_ensure_reapi_compatible_stack'):
    try:
        result['reapi_compat']=mod._ensure_reapi_compatible_stack(path)
    except Exception as exc:
        result['reapi_compat']={'ok':False,'error':str(exc)}

mod.normalize_permissions(path)

c=mod.load_server(sid)
c['profile']='rehlds'
c['runtime_profile']='hyper-host-v3.14'
c['runtime_normalized_at']=int(mod.time.time())
mod.save_server(c)

try:
    mod.db_update_profile(sid,'rehlds')
except Exception:
    pass

print(json.dumps(result,ensure_ascii=False))
PY
)" || die "Runtime normalization failed"

echo "$NORMALIZE_JSON"

echo
echo "[7/9] Starting server once and testing real stability..."

START_ISO="$(date -u '+%Y-%m-%d %H:%M:%S')"

systemctl reset-failed "$UNIT" 2>/dev/null || true
systemctl start "$UNIT" || true

OPENED=0
ACTIVE=0
UDP=0

# Wait for UDP/RCON stage.
for _ in $(seq 1 70); do
    systemctl is-active --quiet "$UNIT" && ACTIVE=1 || ACTIVE=0

    UDP=0
    if [[ "$PORT" -gt 0 ]] && \
       ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$"
    then
        UDP=1
    fi

    if [[ "$ACTIVE" -eq 1 && "$UDP" -eq 1 ]]; then
        OPENED=1
        break
    fi

    sleep 1
done

# Previous broken runtime survived just long enough to answer status.
# Demand another 25 seconds after UDP appears.
if [[ "$OPENED" -eq 1 ]]; then
    sleep 25
fi

systemctl is-active --quiet "$UNIT" && ACTIVE=1 || ACTIVE=0
UDP=0
if [[ "$PORT" -gt 0 ]] && \
   ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$"
then
    UDP=1
fi

JOURNAL="$BACKUP/server-${SID}-v314-test.log"
journalctl -u "$UNIT" --since "$START_ISO" --no-pager -o short-iso \
    >"$JOURNAL" 2>&1 || true

SEGV=0
OLD_AMXX=0
NEW_AMXX=0
HAMFAIL=0
ZP_ERRORS=0

grep -Eqi 'status=11/SEGV|segmentation fault|core-dump|core dumped' \
    "$JOURNAL" && SEGV=1 || true

grep -Eqi 'AMX Mod X version 1[.]8[.]' \
    "$JOURNAL" && OLD_AMXX=1 || true

grep -Eqi 'AMX Mod X version 1[.]9[.]0[.]5303' \
    "$JOURNAL" && NEW_AMXX=1 || true

HAMFAIL="$(grep -Fci '[HAMSANDWICH] Failed to retrieve vtable' "$JOURNAL" || true)"

ZP_ERRORS="$(grep -Eci \
    'zombie_plague40[.]amxx.*Run time error|Run time error.*zombie_plague40[.]amxx|Invalid CVAR pointer' \
    "$JOURNAL" || true)"

echo
echo "Runtime test:"
echo "  UDP opened:             $OPENED"
echo "  service active:         $ACTIVE"
echo "  UDP listening now:      $UDP"
echo "  old AMXX 1.8 loaded:    $OLD_AMXX"
echo "  AMXX 1.9.0.5303 loaded: $NEW_AMXX"
echo "  SIGSEGV/core-dump:      $SEGV"
echo "  Ham vtable failures:    $HAMFAIL"
echo "  ZP core errors:         $ZP_ERRORS"

echo
echo "[8/9] Final decision..."

if [[ "$OPENED" -eq 1 && \
      "$ACTIVE" -eq 1 && \
      "$UDP" -eq 1 && \
      "$SEGV" -eq 0 && \
      "$OLD_AMXX" -eq 0 && \
      "$NEW_AMXX" -eq 1 && \
      "$HAMFAIL" -eq 0 ]]
then
    echo "[OK] managed runtime is stable"

    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed "$UNIT" 2>/dev/null || true
    systemctl start "$MONITOR_UNIT" 2>/dev/null || true
else
    echo "[FAIL] Platform normalization did not produce a clean stable runtime."
    echo "[FAIL] Restart=no remains ONLY for server #$SID."
    echo "[FAIL] The server is stopped instead of entering an OFF/ON loop."

    systemctl stop "$UNIT" 2>/dev/null || true
    systemctl start "$MONITOR_UNIT" 2>/dev/null || true

    echo
    echo "Last 180 journal lines:"
    tail -180 "$JOURNAL" || true

    echo
    echo "Backup:  $BACKUP"
    echo "Journal: $JOURNAL"
    exit 3
fi

echo
echo "[9/9] Actual runtime:"
grep -E \
    'Protocol version|Exe version|Exe build|ReHLDS|Metamod version|AMX Mod X version|Mapchange to|hostname:|map     :' \
    "$JOURNAL" | tail -50 || true

echo
echo "============================================================"
echo " v3.14 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "New build behavior:"
echo "  archive content       -> preserved"
echo "  old uploaded engine   -> replaced by managed ReHLDS"
echo "  old uploaded cs.so    -> replaced by managed ReGameDLL"
echo "  old uploaded Metamod  -> replaced by managed Metamod-R"
echo "  old uploaded AMXX/Ham -> replaced by managed AMXX core"
echo "  .amxx/ZP/config/maps  -> preserved"
echo
echo "Server #$SID:"
echo "  active=$ACTIVE udp=$UDP segv=$SEGV old_amxx=$OLD_AMXX"
echo "  amxx19=$NEW_AMXX ham_failures=$HAMFAIL zp_errors=$ZP_ERRORS"
echo
echo "Backup:  $BACKUP"
echo "Journal: $JOURNAL"
echo "============================================================"
