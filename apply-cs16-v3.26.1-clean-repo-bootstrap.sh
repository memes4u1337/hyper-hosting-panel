#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.26.1 — FULL BUILD CLASSIFIER + CLEAN-REPO BOOTSTRAP
#
# Fixes v3.25 misclassification of a REAL cstrike assembly as a partial addon
# when the uploaded archive has no playable .bsp maps.
#
# Root cause in v3.25:
#   a cstrike-only archive without liblist.gam/cs.so was considered "full"
#   only when server.cfg + playable maps + >=5 content markers were present.
#   A mapless but otherwise complete ZM/AMXX build therefore became
#   partial-cstrike-overlay-v325 and was merged over the stock server.  That
#   preserves the stock plugins.ini, so the server can come up with only the
#   default ~21 AMXX plugins instead of the assembly's plugin set.
#
# v3.26 behavior:
# - playable maps are NOT required to recognize a complete assembly;
# - server.cfg + authoritative AMXX tree/plugin list + real plugin payload is
#   enough to classify a cstrike archive as a full assembly;
# - true addon/plugin packs without assembly-level config remain partial overlay;
# - v3.25 safe stock-map fallback is retained for full mapless assemblies;
# - import mode gets +classifier-v326 for diagnostics.
# - clean GitHub checkouts without v3.25 are bootstrapped from the already patched live controller instead of aborting.

SID="${1:-25}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.26.1-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.26.1-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die(){ echo; echo "[ERROR] $*"; echo "[ERROR] Log: $LOG"; echo "[ERROR] Backup: $BACKUP"; exit 1; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; local n; n="$(printf '%s' "$f"|sed 's#^/##;s#/#__#g')"; cp -a "$f" "$BACKUP/$n"; }

[[ "$EUID" -eq 0 ]] || die "Run as root"
[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"
grep -q "def _v325_payload_mode" "$LIVE_CTL" || die "v3.25 is not installed in live controller"
grep -q "partial-cstrike-overlay-v325" "$LIVE_CTL" || die "v3.25 partial overlay marker missing"

backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"

PATCHER="$(mktemp /tmp/hh-v326.XXXXXX.py)"
trap 'rm -f "$PATCHER" 2>/dev/null || true' EXIT

cat > "$PATCHER" <<'PY'
from __future__ import annotations
import ast, os, py_compile, re, sys
from pathlib import Path

MARKER = '# >>> HYPER-HOST v3.26 FULL BUILD CLASSIFIER FIX >>>'

NEW_FN = r'''def _v325_payload_mode(payload:Path,layout:str)->dict:
    # HYPER-HOST v3.26: classify assembly independently of map presence.
    # v3.25 incorrectly required playable maps for the common cstrike-only case,
    # turning complete mapless ZM builds into partial addon overlays.
    cs=_v325_cs_payload(payload,layout)
    markers=('addons','maps','models','sound','sprites','resource','gfx','events','overviews','dlls','classes')
    present=[x for x in markers if (cs/x).exists()]
    maps=_v325_playable_map_names(cs/'maps')
    root_engine=bool(layout=='server-root' and (payload/'hlds_linux').is_file())

    cfg=cs/'addons/amxmodx/configs'
    plugdir=cs/'addons/amxmodx/plugins'
    plugins_ini=cfg/'plugins.ini'
    server_cfg=cs/'server.cfg'
    mapcycle=cs/'mapcycle.txt'
    amxx_cfg=cfg/'amxx.cfg'

    plugin_files=0
    if plugdir.is_dir():
        try:
            plugin_files=sum(1 for p in plugdir.iterdir() if p.is_file() and p.suffix.lower()=='.amxx')
        except OSError:
            plugin_files=0

    plugin_entries=0
    plugin_lists=[]
    if cfg.is_dir():
        try:
            plugin_lists=sorted([p for p in cfg.glob('plugins*.ini') if p.is_file()],key=lambda p:p.name.lower())
        except OSError:
            plugin_lists=[]
    for pin in plugin_lists:
        try:
            for line in pin.read_text(encoding='utf-8',errors='ignore').splitlines():
                st=line.strip()
                if not st or st.startswith(';') or st.startswith('//'):
                    continue
                body=st.split(';',1)[0].strip()
                if body and body.split()[0].lower().endswith('.amxx'):
                    plugin_entries+=1
        except OSError:
            pass

    content_dirs=sum(1 for x in ('models','sound','sprites','resource','gfx','events','overviews') if (cs/x).exists())
    amxx_tree=bool((cs/'addons/amxmodx').is_dir() and cfg.is_dir() and plugdir.is_dir())

    # Hard full-build signals.
    hard_full=bool(
        root_engine or
        (cs/'liblist.gam').is_file() or
        (cs/'dlls/cs.so').is_file()
    )

    # Authoritative cstrike assembly signals. Maps are intentionally NOT part
    # of this test: v3.25's safe map fallback handles a full build with no BSPs.
    config_full=bool(
        server_cfg.is_file() and
        amxx_tree and
        plugins_ini.is_file() and
        (plugin_files>=3 or plugin_entries>=3)
    )

    broad_full=bool(
        server_cfg.is_file() and
        (
            (plugin_files>=8 and content_dirs>=1) or
            (plugin_entries>=8 and content_dirs>=1) or
            (amxx_cfg.is_file() and mapcycle.is_file() and len(present)>=3)
        )
    )

    strong=bool(hard_full or config_full or broad_full)
    partial=not strong

    reasons=[]
    if root_engine: reasons.append('own hlds_linux')
    if (cs/'liblist.gam').is_file(): reasons.append('liblist.gam')
    if (cs/'dlls/cs.so').is_file(): reasons.append('GameDLL cs.so')
    if config_full: reasons.append('server.cfg + authoritative AMXX plugin tree')
    if broad_full: reasons.append('broad server/config/content signals')
    if partial: reasons.append('no assembly-level signals; safe partial overlay')

    return {
        'partial_overlay':partial,
        'layout':layout,
        'markers':present,
        'playable_maps':maps[:200],
        'root_engine':root_engine,
        'server_cfg':server_cfg.is_file(),
        'plugins_ini':plugins_ini.is_file(),
        'plugin_files':plugin_files,
        'plugin_entries':plugin_entries,
        'plugin_lists':[p.name for p in plugin_lists[:50]],
        'content_dirs':content_dirs,
        'classifier':'v326',
        'reason':'; '.join(reasons),
    }
'''


def fn_bounds(src:str,name:str):
    tree=ast.parse(src)
    node=next((n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name),None)
    if node is None:
        return -1,-1,''
    lines=src.splitlines(keepends=True)
    st=sum(len(x) for x in lines[:node.lineno-1])
    en=sum(len(x) for x in lines[:node.end_lineno])
    return st,en,src[st:en]


def patch(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src

    if 'def _v325_payload_mode' not in src:
        raise RuntimeError(f'{path}: v3.25 classifier not found')
    if 'def install_custom_build(' not in src:
        raise RuntimeError(f'{path}: install_custom_build not found')

    st,en,old=fn_bounds(src,'_v325_payload_mode')
    if st<0:
        raise RuntimeError(f'{path}: classifier parse failed')
    src=src[:st]+NEW_FN+'\n'+src[en:]

    st,en,fn=fn_bounds(src,'install_custom_build')
    if st<0:
        raise RuntimeError(f'{path}: install_custom_build parse failed')

    # Add an explicit diagnostic marker to every future import.
    marker_line="        if '+classifier-v326' not in import_mode: import_mode=import_mode+'+classifier-v326'\n"
    if marker_line not in fn:
        anchor="        if partial_payload.get('partial_overlay'): import_mode='partial-cstrike-overlay-v325'\n"
        if anchor not in fn:
            raise RuntimeError(f'{path}: v3.25 import-mode anchor missing')
        fn=fn.replace(anchor,anchor+marker_line,1)

    src=src[:st]+fn+src[en:]

    if MARKER not in src:
        pos=src.find('\ndef _v325_payload_mode')
        if pos<0:
            raise RuntimeError(f'{path}: marker insertion point missing')
        src=src[:pos]+'\n'+MARKER+'\n'+src[pos:]

    ast.parse(src)
    tmp=path.with_name(path.name+'.v326tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True)
    os.replace(tmp,path)

    final=path.read_text(encoding='utf-8',errors='surrogateescape')
    checks={
        'v3.26 marker':MARKER in final,
        'map-independent full classifier':'server.cfg + authoritative AMXX plugin tree' in final,
        'classifier diagnostics':"'classifier':'v326'" in final,
        'import marker':'+classifier-v326' in final,
        'v3.25 overlay preserved':'partial-cstrike-overlay-v325' in final,
        'v3.25 map fallback preserved':'_v325_copy_base_map_fallback(stage,base)' in final,
    }
    bad=[k for k,v in checks.items() if not v]
    if bad:
        raise RuntimeError(f'{path}: verification failed: {bad}')
    return src!=original

for arg in sys.argv[1:]:
    p=Path(arg)
    changed=patch(p)
    print(('[PATCHED] ' if changed else '[OK already patched] ')+str(p))
PY

echo "============================================================"
echo " HYPER-HOST CS16 v3.26.1 — FULL BUILD CLASSIFIER + CLEAN-REPO BOOTSTRAP"
echo "============================================================"
echo "Server: $SID"
echo "Live:   $LIVE_CTL"
echo "Repo:   $REPO_CTL"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo

echo "[1/7] Patching/validating LIVE controller..."
python3 "$PATCHER" "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller syntax check failed"

echo "[2/7] Reconciling CLEAN GitHub repository controller..."
if grep -q "def _v325_payload_mode" "$REPO_CTL" && grep -q "partial-cstrike-overlay-v325" "$REPO_CTL"; then
  python3 "$PATCHER" "$REPO_CTL" || die "Repository controller patch failed"
else
  echo "[INFO] Repository controller is clean/older and does not contain v3.25."
  echo "[INFO] Copying the already verified LIVE controller into the repository checkout."
  install -m 0755 "$LIVE_CTL" "$REPO_CTL" || die "Could not sync live controller into repository"
fi
python3 -m py_compile "$REPO_CTL" || die "Repository controller syntax check failed"

echo "[3/7] Semantic checks..."
python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
ast.parse(s)
checks={
 'v3.26 classifier marker':'HYPER-HOST v3.26 FULL BUILD CLASSIFIER FIX' in s,
 'map-independent full build':'server.cfg + authoritative AMXX plugin tree' in s,
 'v3.25 partial overlay kept':'partial-cstrike-overlay-v325' in s,
 'v3.25 map fallback kept':'_v325_copy_base_map_fallback(stage,base)' in s,
 'v3.26 import marker':'+classifier-v326' in s,
}
for k,v in checks.items(): print(('[OK] ' if v else '[FAIL] ')+k)
if not all(checks.values()): raise SystemExit(1)
PY

echo "[4/7] Classifier regression test..."
python3 - <<'PY'
from pathlib import Path
import tempfile

# Standalone mirror of the v3.26 decision cases: this tests the two cases that
# v3.25 confused — a complete mapless server build vs a true plugin addon.
def classify(cs:Path):
    markers=('addons','maps','models','sound','sprites','resource','gfx','events','overviews','dlls','classes')
    present=[x for x in markers if (cs/x).exists()]
    cfg=cs/'addons/amxmodx/configs'; plugdir=cs/'addons/amxmodx/plugins'
    plugin_files=sum(1 for p in plugdir.glob('*.amxx')) if plugdir.is_dir() else 0
    entries=0
    if cfg.is_dir():
        for pin in cfg.glob('plugins*.ini'):
            for line in pin.read_text(errors='ignore').splitlines():
                st=line.strip()
                if st and not st.startswith((';','//')) and st.split(';',1)[0].strip().split()[0].lower().endswith('.amxx'):
                    entries+=1
    content_dirs=sum(1 for x in ('models','sound','sprites','resource','gfx','events','overviews') if (cs/x).exists())
    amxx_tree=(cs/'addons/amxmodx').is_dir() and cfg.is_dir() and plugdir.is_dir()
    config_full=(cs/'server.cfg').is_file() and amxx_tree and (cfg/'plugins.ini').is_file() and (plugin_files>=3 or entries>=3)
    broad_full=(cs/'server.cfg').is_file() and ((plugin_files>=8 and content_dirs>=1) or (entries>=8 and content_dirs>=1) or ((cfg/'amxx.cfg').is_file() and (cs/'mapcycle.txt').is_file() and len(present)>=3))
    return config_full or broad_full

with tempfile.TemporaryDirectory(prefix='hh-v326-test-') as td:
    t=Path(td)
    full=t/'full'; (full/'addons/amxmodx/plugins').mkdir(parents=True); (full/'addons/amxmodx/configs').mkdir(parents=True); (full/'models').mkdir()
    (full/'server.cfg').write_text('hostname "ZM"\n')
    (full/'addons/amxmodx/configs/plugins.ini').write_text('a.amxx\nb.amxx\nc.amxx\n')
    for n in ('a','b','c'): (full/f'addons/amxmodx/plugins/{n}.amxx').write_bytes(b'AMXX')
    assert classify(full), 'mapless full build was misclassified as partial'

    addon=t/'addon'; (addon/'addons/amxmodx/plugins').mkdir(parents=True); (addon/'models').mkdir()
    (addon/'addons/amxmodx/plugins/one.amxx').write_bytes(b'AMXX')
    assert not classify(addon), 'simple plugin addon was misclassified as full build'

print('[OK] mapless full assembly => FULL')
print('[OK] simple addon/plugin pack => PARTIAL')
PY

echo "[5/7] Idempotence pass on LIVE + repository..."
python3 "$PATCHER" "$LIVE_CTL" "$REPO_CTL" || die "Idempotence pass failed"
python3 -m py_compile "$LIVE_CTL" "$REPO_CTL" || die "Controller invalid after second pass"

echo "[6/7] Verify repository now carries v3.25 + v3.26..."
grep -q "def _v325_payload_mode" "$REPO_CTL" || die "Repository still lacks v3.25 helper"
grep -q "+classifier-v326" "$REPO_CTL" || die "Repository still lacks v3.26 marker"
cmp -s "$LIVE_CTL" "$REPO_CTL" && echo "[OK] live/repository controllers are byte-identical" || echo "[INFO] live/repository differ but both passed semantic checks"

echo "[7/7] Current server diagnostic only..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  "$LIVE_CTL" rcon "$SID" "status" 2>&1 || true
  echo "--- AMXX ---"
  "$LIVE_CTL" rcon "$SID" "amxx plugins" 2>&1 | tail -100 || true
else
  echo "[INFO] server #$SID does not exist; future imports are patched"
fi

echo
echo "============================================================"
echo " v3.26.1 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "FIXED: mapless complete cstrike builds are no longer treated as addon overlays."
echo "KEPT: true addon/plugin ZIPs still use partial-cstrike-overlay-v325."
echo "KEPT: v3.25 managed stock-map fallback for a complete build with no BSP maps."
echo
echo "IMPORTANT: server #$SID was already imported incorrectly by v3.25."
echo "After installing v3.26.1, RE-UPLOAD THE SAME img.zip once."
echo "Expected import for a real assembly: exact-cstrike-archive+classifier-v326..."
echo "It must NOT begin with partial-cstrike-overlay-v325."
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
