#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.12 — UNIVERSAL ASSEMBLY RUNTIME NORMALIZER
#
# Goal:
#   Uploaded CS 1.6 archives are CONTENT, not trusted platform runtimes.
#
# Every complete uploaded Linux assembly is normalized BEFORE its first start:
#   - ReHLDS 3.15.0.896
#   - ReGameDLL_CS 5.30.0.814
#   - Metamod-R 1.3.0.149
#   - AMX Mod X 1.9.0.5303 core + official modules + matching Ham data
#
# Preserved from the user's archive:
#   - .amxx plugins
#   - plugins*.ini / modules.ini / ZP configs
#   - custom third-party AMXX modules that don't collide with official ones
#   - models/maps/sounds/sprites/WADs/configs
#   - server.cfg / hostname / gameplay settings
#
# This fixes the architecture that allowed an archive to replace the hosting
# runtime with AMXX 1.8.x / stale Ham Sandwich / old engine binaries.
#
# IMPORTANT:
#   - does NOT run apply-cs16-v3.3-fullbuild.sh
#   - does NOT touch panel PHP, nginx, or panel SQL
#   - patches both the live controller and repository controller copy
#   - repairs an already installed server (default #13) immediately
#
# Usage:
#   bash apply-cs16-v3.12-universal-runtime.sh
#   bash apply-cs16-v3.12-universal-runtime.sh 13

SID="${1:-13}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON="${HYPER_MON:-/usr/local/sbin/hyper-cs16-monitor}"
UNIT="hyper-cs16@${SID}.service"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.12-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.12-${STAMP}.log"
DROPIN_DIR="/etc/systemd/system/${UNIT}.d"
DROPIN="${DROPIN_DIR}/99-v312-test-no-restart.conf"

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
echo " HYPER-HOST CS16 UNIVERSAL RUNTIME v3.12"
echo "============================================================"
echo "Server:     $SID"
echo "Live ctl:   $LIVE_CTL"
echo "Repository: $REPO"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"

TARGETS=("$LIVE_CTL")
while IFS= read -r -d '' f; do
  [[ "$f" == "$LIVE_CTL" ]] && continue
  TARGETS+=("$f")
done < <(find "$REPO" -type f -path '*/cs16-panel/bin/hyper-cs16-ctl' -print0 2>/dev/null)

echo "[1/8] Controller copies:"
printf '  - %s\n' "${TARGETS[@]}"

for f in "${TARGETS[@]}"; do
  safe="$(echo "$f" | sed 's#^/##; s#/#__#g')"
  cp -a "$f" "$BACKUP/$safe"
done

echo
echo "[2/8] Installing PRE-START runtime normalization into the importer..."

python3 - "$BACKUP" "${TARGETS[@]}" <<'PY'
from __future__ import annotations

import os
import py_compile
import re
import shutil
import sys
from pathlib import Path

backup_root=Path(sys.argv[1])
targets=[Path(x) for x in sys.argv[2:]]

MARKER="# >>> HYPER-HOST v3.12 UNIVERSAL PLATFORM RUNTIME >>>"
CALL_MARKER="# HYPER-HOST v3.12 normalize exact runtime BEFORE first start"

HELPER=r'''
# >>> HYPER-HOST v3.12 UNIVERSAL PLATFORM RUNTIME >>>
def _platform_refresh_amxx_core(path:Path)->list[str]:
    # Preserve user plugins/configs. Replace only AMXX loader, official modules
    # and the Ham/gamedata files that MUST match those modules.
    cstrike=path/'cstrike'
    dst=cstrike/'addons/amxmodx'
    dst.mkdir(parents=True,exist_ok=True)
    actions=[]

    with tempfile.TemporaryDirectory(prefix='hhcs16-v312-amxx-') as td:
        td=Path(td)
        payload=td/'payload'
        payload.mkdir(parents=True,exist_ok=True)

        base=td/'amxx-base.tgz'
        cs=td/'amxx-cstrike.tgz'
        download(AMXX_BASE,base)
        download(AMXX_CSTRIKE,cs)
        extract_tar(base,payload)
        extract_tar(cs,payload)

        srcroot=payload/'addons/amxmodx'
        core=srcroot/'dlls/amxmodx_mm_i386.so'
        ham=srcroot/'modules/hamsandwich_amxx_i386.so'
        if not core.is_file() or not ham.is_file():
            raise RuntimeError('Official AMXX compatibility payload is incomplete')

        for rel in ('dlls','modules'):
            srcdir=srcroot/rel
            dstdir=dst/rel
            dstdir.mkdir(parents=True,exist_ok=True)
            if srcdir.is_dir():
                for fp in srcdir.iterdir():
                    if fp.is_file():
                        shutil.copy2(fp,dstdir/fp.name)

        hamdata=srcroot/'configs/hamdata.ini'
        if hamdata.is_file():
            target=dst/'configs/hamdata.ini'
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(hamdata,target)

        gamedata=srcroot/'data/gamedata'
        if gamedata.is_dir():
            target=dst/'data/gamedata'
            target.mkdir(parents=True,exist_ok=True)
            shutil.copytree(gamedata,target,dirs_exist_ok=True)

    # Keep the uploaded plugin list. Only ensure AMXX itself is loaded once.
    mp=cstrike/'addons/metamod/plugins.ini'
    mp.parent.mkdir(parents=True,exist_ok=True)
    text=mp.read_text(encoding='utf-8',errors='replace') if mp.exists() else ''
    lines=[]
    amxx_seen=False
    for raw in text.replace('\r\n','\n').replace('\r','\n').splitlines():
        low=raw.strip().lower()
        if 'amxmodx_mm' in low:
            if amxx_seen:
                continue
            lines.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')
            amxx_seen=True
            continue
        lines.append(raw)
    if not amxx_seen:
        lines.append('linux addons/amxmodx/dlls/amxmodx_mm_i386.so')
    mp.write_text('\n'.join(lines).rstrip()+'\n',encoding='utf-8')

    actions.append('AMXX 1.9.0.'+str(AMXX_BUILD)+' platform core normalized')
    return actions


def _disable_legacy_dproto_on_rehlds(path:Path)->list[str]:
    # DProto is an old stock-HLDS extension. Keep its files, but don't load it
    # together with ReHLDS. Reunion and other uploaded Metamod plugins remain.
    mp=path/'cstrike/addons/metamod/plugins.ini'
    if not mp.is_file():
        return []
    text=mp.read_text(encoding='utf-8',errors='replace')
    changed=False
    out=[]
    for raw in text.replace('\r\n','\n').replace('\r','\n').splitlines():
        low=raw.strip().lower()
        if low and not low.startswith(';') and not low.startswith('#') and 'dproto' in low:
            out.append('; HYPER-HOST v3.12 disabled on ReHLDS: '+raw)
            changed=True
        else:
            out.append(raw)
    if changed:
        mp.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
        return ['legacy DProto loader disabled on ReHLDS']
    return []


def _normalize_imported_platform_runtime(path:Path)->dict:
    # The archive owns game CONTENT. HYPER-HOST owns the executable platform.
    # This is intentionally done BEFORE the first server start.
    actions=[]
    install_rehlds(path)
    actions.append('ReHLDS '+str(REHLDS_VERSION)+' + ReGameDLL '+str(REGAMEDLL_VERSION)+' normalized')

    install_metamod_rehlds(path)
    actions.append('Metamod-R '+str(METAMOD_VERSION)+' normalized')

    actions.extend(_platform_refresh_amxx_core(path))
    actions.extend(_disable_legacy_dproto_on_rehlds(path))

    normalize_permissions(path)
    return {'ok':True,'actions':actions}


def normalize_server_platform_runtime(sid:int):
    require_root()
    c=load_server(sid)
    path=safe_server_path(sid)
    if not path.is_dir():
        raise RuntimeError('Server directory is missing: '+str(path))

    run(['systemctl','stop',f'hyper-cs16@{sid}.service'],check=False,timeout=90)
    result=_normalize_imported_platform_runtime(path)
    normalize_permissions(path)

    c['runtime_normalized']=True
    c['runtime_normalized_at']=int(time.time())
    c['runtime_profile']='hyper-host-v3.12'
    save_server(c)

    return {
        'ok':True,
        'id':sid,
        'path':str(path),
        'actions':result.get('actions') or [],
        'runtime_profile':'hyper-host-v3.12',
    }
# <<< HYPER-HOST v3.12 UNIVERSAL PLATFORM RUNTIME <<<


'''

def patch_one(path:Path):
    raw=path.read_bytes()
    src=raw.decode('utf-8',errors='surrogateescape')
    original=src

    required_defs=(
        "def install_rehlds(",
        "def install_metamod_rehlds(",
        "def install_custom_build(",
    )
    for item in required_defs:
        if item not in src:
            raise RuntimeError(f"{path}: expected {item} not found")

    # Preserve v3.8 safe subprocess decoding.
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

    if MARKER not in src:
        pos=src.find("\ndef install_custom_build(")
        if pos<0:
            raise RuntimeError(f"{path}: install_custom_build insertion point missing")
        src=src[:pos]+"\n"+HELPER+src[pos:]

    if CALL_MARKER not in src:
        needle="        compatibility_actions=[]\n"
        pos=src.find(needle,src.find("def install_custom_build("))
        if pos<0:
            raise RuntimeError(f"{path}: compatibility_actions insertion point missing")
        insert=(
            "        compatibility_actions=[]\n"
            "\n"
            "        # HYPER-HOST v3.12 normalize exact runtime BEFORE first start\n"
            "        if exact_runtime:\n"
            "            platform_norm=_normalize_imported_platform_runtime(stage)\n"
            "            compatibility_actions.extend(platform_norm.get('actions') or [])\n"
            "            runtime_profile=_analyze_build_runtime(stage/'cstrike')\n"
            "            import_mode += '+platform-runtime-v312'\n"
            "            layout=layout.split('/')[0]+'/'+import_mode\n"
        )
        src=src[:pos]+src[pos:].replace(needle,insert,1)

    # Add CLI command.
    if "'normalize-runtime'" not in src:
        loop_old="'delete','repair-runtime','mods-status'"
        loop_new="'delete','repair-runtime','normalize-runtime','mods-status'"
        if loop_old not in src:
            raise RuntimeError(f"{path}: CLI action list insertion point missing")
        src=src.replace(loop_old,loop_new,1)

    if "elif args.cmd=='normalize-runtime':" not in src:
        branch="        elif args.cmd=='repair-runtime': result=repair_server_runtime(args.id)\n"
        if branch not in src:
            raise RuntimeError(f"{path}: repair-runtime branch missing")
        src=src.replace(
            branch,
            "        elif args.cmd=='normalize-runtime': result=normalize_server_platform_runtime(args.id)\n"
            +branch,
            1
        )

    required=(
        MARKER,
        CALL_MARKER,
        "platform_norm=_normalize_imported_platform_runtime(stage)",
        "def normalize_server_platform_runtime(sid:int):",
        "'normalize-runtime'",
        "elif args.cmd=='normalize-runtime': result=normalize_server_platform_runtime(args.id)",
        "encoding='utf-8',errors='replace'",
    )
    missing=[x for x in required if x not in src]
    if missing:
        raise RuntimeError(f"{path}: verification missing {missing}")

    # Backup and atomically write.
    if src!=original:
        safe=str(path).lstrip('/').replace('/','__')
        backup=backup_root/safe
        backup.parent.mkdir(parents=True,exist_ok=True)
        if not backup.exists():
            shutil.copy2(path,backup)

        tmp=path.with_name(path.name+'.v312tmp')
        tmp.write_bytes(src.encode('utf-8',errors='surrogateescape'))
        os.chmod(tmp,path.stat().st_mode)
        os.replace(tmp,path)

    py_compile.compile(str(path),doraise=True)
    return src!=original

changed=0
for target in targets:
    did=patch_one(target)
    changed+=int(did)
    print(("[PATCHED] " if did else "[OK already patched] ")+str(target))

print(f"[OK] controller patch complete; changed={changed}")
PY

echo
echo "[3/8] Verifying importer now normalizes BEFORE first start..."

python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import sys

s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
install=s[s.find('def install_custom_build('):]
call=install.find("platform_norm=_normalize_imported_platform_runtime(stage)")
start=install.find("run(['systemctl','start'")
if call<0:
    raise SystemExit('[ERROR] normalization call missing')
if start<0:
    raise SystemExit('[ERROR] first systemctl start marker missing')
if call>start:
    raise SystemExit('[ERROR] runtime normalization is AFTER server start — unsafe')
print('[OK] platform normalization happens BEFORE first systemctl start')
print('[OK] uploaded AMXX/engine can no longer win over the platform runtime')
PY

if [[ ! -f "/var/lib/hyper-cs16/servers/${SID}.json" ]]; then
  echo
  echo "[INFO] Server #$SID does not exist. Importer patch is complete."
  echo "============================================================"
  exit 0
fi

SERVER_PATH="$(python3 - "$SID" <<'PY'
import json,sys
from pathlib import Path
sid=int(sys.argv[1])
p=Path(f'/var/lib/hyper-cs16/servers/{sid}.json')
d=json.loads(p.read_text(encoding='utf-8'))
print(str(d.get('path') or f'/srv/hyper-cs16/servers/{sid}'))
PY
)"

PORT="$(python3 - "$SID" <<'PY'
import json,sys
from pathlib import Path
sid=int(sys.argv[1])
d=json.loads(Path(f'/var/lib/hyper-cs16/servers/{sid}.json').read_text(encoding='utf-8'))
print(int(d.get('port') or 0))
PY
)"

[[ -d "$SERVER_PATH" ]] || die "Server path missing: $SERVER_PATH"

echo
echo "[4/8] Backing up current server platform runtime..."

mkdir -p "$BACKUP/current-server"
for p in \
  hlds_linux hlds_run engine_i486.so core.so filesystem_stdio.so demoplayer.so \
  cstrike/dlls/cs.so cstrike/liblist.gam \
  cstrike/addons/metamod cstrike/addons/amxmodx/dlls \
  cstrike/addons/amxmodx/modules cstrike/addons/amxmodx/configs/hamdata.ini \
  cstrike/addons/amxmodx/data/gamedata
do
  if [[ -e "$SERVER_PATH/$p" ]]; then
    mkdir -p "$BACKUP/current-server/$(dirname "$p")"
    cp -a "$SERVER_PATH/$p" "$BACKUP/current-server/$p"
  fi
done

echo "[OK] runtime backup created"

echo
echo "[5/8] Stopping crash loop and normalizing current server #$SID..."

systemctl stop hyper-cs16-monitor.service 2>/dev/null || true
systemctl stop "$UNIT" 2>/dev/null || true

mkdir -p "$DROPIN_DIR"
cat >"$DROPIN" <<'EOF'
[Service]
Restart=no
EOF

systemctl daemon-reload
systemctl reset-failed "$UNIT" 2>/dev/null || true

NORMALIZE_OUT="$("$LIVE_CTL" normalize-runtime "$SID" 2>&1)" || {
  echo "$NORMALIZE_OUT"
  die "normalize-runtime failed"
}
echo "$NORMALIZE_OUT"

echo
echo "[6/8] Starting ONCE and checking stability beyond the previous crash point..."

START_EPOCH="$(date +%s)"
START_ISO="$(date -u '+%Y-%m-%d %H:%M:%S')"

systemctl reset-failed "$UNIT" 2>/dev/null || true
systemctl start "$UNIT" || true

ACTIVE=0
UDP=0

# The bad build previously reached RCON and crashed about 1 second later.
# Require it to stay alive for at least 20 seconds after UDP appears.
for i in $(seq 1 70); do
  if systemctl is-active --quiet "$UNIT"; then
    ACTIVE=1
  else
    ACTIVE=0
  fi

  UDP=0
  if [[ "$PORT" -gt 0 ]] && ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$"; then
    UDP=1
  fi

  if [[ "$ACTIVE" -eq 1 && "$UDP" -eq 1 ]]; then
    sleep 20
    systemctl is-active --quiet "$UNIT" && ACTIVE=1 || ACTIVE=0
    UDP=0
    if [[ "$PORT" -gt 0 ]] && ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${PORT}$"; then
      UDP=1
    fi
    break
  fi

  sleep 1
done

JOURNAL="$BACKUP/server-${SID}-v312-test.log"
journalctl -u "$UNIT" --since "$START_ISO" --no-pager -o short-iso >"$JOURNAL" 2>&1 || true

SEGV=0
OLD_AMXX=0
NEW_AMXX=0
HAMFAIL=0

grep -Eqi 'status=11/SEGV|segmentation fault|core-dump|core dumped' "$JOURNAL" && SEGV=1 || true
grep -Eqi 'AMX Mod X version 1[.]8[.]' "$JOURNAL" && OLD_AMXX=1 || true
grep -Eqi 'AMX Mod X version 1[.]9[.]0[.]5303' "$JOURNAL" && NEW_AMXX=1 || true
HAMFAIL="$(grep -Fci '[HAMSANDWICH] Failed to retrieve vtable' "$JOURNAL" || true)"

echo
echo "Runtime verification:"
echo "  service active:      $ACTIVE"
echo "  UDP listening:       $UDP"
echo "  old AMXX 1.8 seen:   $OLD_AMXX"
echo "  AMXX 1.9.0.5303:     $NEW_AMXX"
echo "  SIGSEGV/core-dump:   $SEGV"
echo "  Ham vtable failures: $HAMFAIL"

echo
echo "[7/8] Finalizing service policy..."

if [[ "$ACTIVE" -eq 1 && "$UDP" -eq 1 && "$SEGV" -eq 0 && "$OLD_AMXX" -eq 0 ]]; then
  rm -f "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed "$UNIT" 2>/dev/null || true
  systemctl start hyper-cs16-monitor.service 2>/dev/null || true

  echo "[OK] normalized runtime stayed alive"
else
  # Keep this one server from flapping ON/OFF forever. The uploaded content and
  # backups stay intact for deterministic diagnosis.
  systemctl stop "$UNIT" 2>/dev/null || true
  systemctl start hyper-cs16-monitor.service 2>/dev/null || true

  echo
  echo "[FAIL] The normalized platform still did not stay healthy."
  echo "[FAIL] Automatic restart remains disabled ONLY for server #$SID."
  echo
  echo "Last 140 journal lines:"
  tail -140 "$JOURNAL" || true
  echo
  echo "Backup:  $BACKUP"
  echo "Journal: $JOURNAL"
  exit 3
fi

echo
echo "[8/8] Showing the actual platform that started..."

grep -E \
  'Protocol version|Exe version|Exe build|Metamod version|AMX Mod X version|Mapchange to|hostname:|map     :' \
  "$JOURNAL" | tail -30 || true

echo
echo "============================================================"
echo " v3.12 UNIVERSAL RUNTIME INSTALLED"
echo "============================================================"
echo "Future complete assemblies are normalized BEFORE first start."
echo "The archive supplies gameplay/content; HYPER-HOST supplies the runtime."
echo
echo "Current server #$SID:"
echo "  active=$ACTIVE udp=$UDP segv=$SEGV old_amxx=$OLD_AMXX ham_failures=$HAMFAIL"
echo
echo "Backup:  $BACKUP"
echo "Journal: $JOURNAL"
echo "============================================================"
