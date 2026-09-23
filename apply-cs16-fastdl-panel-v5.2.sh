#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run as root/sudo" >&2; exit 1; }

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
SRC="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-panel-v52-backup-${STAMP}"

[[ -f "$SRC" ]] || { echo "[ERROR] Missing $SRC" >&2; exit 2; }
[[ -f "$LIVE" ]] || { echo "[ERROR] Missing $LIVE" >&2; exit 2; }

echo "========================================================"
echo " HYPER-HOST CS16 FASTDL PANEL v5.2"
echo " Server: #$SID"
echo " Fix: clean/sync race + locking"
echo "========================================================"

mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/hyper-cs16-ctl.source"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live"

echo "[1/7] Stopping automatic FastDL sync before cache maintenance..."
systemctl stop hyper-cs16-fastdl-sync.timer 2>/dev/null || true
systemctl stop hyper-cs16-fastdl-sync.service 2>/dev/null || true

for i in $(seq 1 30); do
    if ! pgrep -af 'hyper-cs16-ctl fastdl-sync' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

echo "[2/7] Adding process lock + atomic FastDL cleanup..."

python3 - "$SRC" "$LIVE" <<'PY'
from pathlib import Path
import sys

for filename in sys.argv[1:]:
    p=Path(filename)
    s=p.read_text(encoding='utf-8')

    if 'FASTDL_RULES={' not in s:
        raise SystemExit(f'[PATCH ERROR] {p} is not v5.1 backend (FASTDL_RULES missing)')

    clean_start=s.find('def fastdl_clean(sid:int):')
    sync_start=s.find('def fastdl_sync(sid:int, configure:bool=True):', clean_start)
    status_start=s.find('def fastdl_status(sid:int):', sync_start)

    if min(clean_start,sync_start,status_start) < 0:
        raise SystemExit(f'[PATCH ERROR] FastDL v5.1 function anchors missing in {p}')

    sync_text=s[sync_start:status_start]
    sync_text=sync_text.replace(
        'def fastdl_sync(sid:int, configure:bool=True):',
        'def _fastdl_sync_unlocked(sid:int, configure:bool=True):',
        1
    )

    prefix=r'''def _fastdl_lock():
    import fcntl
    FASTDL_ROOT.mkdir(parents=True,exist_ok=True)
    lock_path=FASTDL_ROOT/'.fastdl-operation.lock'
    fh=open(lock_path,'a+')
    fcntl.flock(fh.fileno(),fcntl.LOCK_EX)
    return fh


def _fastdl_unlock(fh):
    import fcntl
    try:
        fcntl.flock(fh.fileno(),fcntl.LOCK_UN)
    finally:
        fh.close()


def fastdl_clean(sid:int):
    require_root()
    lock=_fastdl_lock()
    try:
        c=load_server(sid)
        dest=FASTDL_ROOT/str(sid)

        if dest.exists():
            trash=FASTDL_ROOT/f'.delete-{sid}-{os.getpid()}-{secrets.token_hex(4)}'
            try:
                os.replace(dest,trash)
            except FileNotFoundError:
                trash=None
            if trash is not None:
                shutil.rmtree(trash,ignore_errors=True)

        for stale in FASTDL_ROOT.glob(f'.delete-{sid}-*'):
            try:
                if stale.is_dir():
                    shutil.rmtree(stale,ignore_errors=True)
                else:
                    stale.unlink()
            except OSError:
                pass

        c['fastdl_last_sync']=0
        c['fastdl_files']=0
        c['fastdl_bytes']=0
        c['fastdl_asset_files']=0
        c['fastdl_compressed_files']=0
        c['fastdl_saved_bytes']=0
        save_server(c)

        return {
            'ok':True,
            'id':sid,
            'root':str(dest),
            'deleted':True,
            'game_files_untouched':True,
            'locked':True,
        }
    finally:
        _fastdl_unlock(lock)


'''

    wrapper=r'''
def fastdl_sync(sid:int, configure:bool=True):
    require_root()
    lock=_fastdl_lock()
    try:
        return _fastdl_sync_unlocked(sid,configure)
    finally:
        _fastdl_unlock(lock)


'''

    replacement=prefix+sync_text+wrapper
    s=s[:clean_start]+replacement+s[status_start:]
    p.write_text(s,encoding='utf-8')
    print(f'[OK] lock/atomic-clean patched: {p}')
PY

python3 -m py_compile "$SRC"
python3 -m py_compile "$LIVE"

echo "[3/7] Removing stale half-deleted cache leftovers..."
find /srv/hyper-cs16/fastdl -maxdepth 1 -type d -name ".delete-${SID}-*" -exec rm -rf -- {} + 2>/dev/null || true

echo "[4/7] Clean FastDL cache atomically..."
"$LIVE" fastdl-clean "$SID"

if [[ -d "/srv/hyper-cs16/servers/${SID}/cstrike" ]]; then
    echo "[OK] Game cstrike still exists and was not deleted."
else
    echo "[ERROR] Game cstrike tree is missing; refusing to continue." >&2
    exit 3
fi

echo "[5/7] Rebuilding ONLY client-downloadable resources..."
SYNC_JSON="$("$LIVE" fastdl-sync "$SID")"
echo "$SYNC_JSON"

echo "[6/7] Verifying generated cache..."
DEST="/srv/hyper-cs16/fastdl/${SID}"

[[ -d "$DEST" ]] || { echo "[ERROR] FastDL cache was not created" >&2; exit 4; }

for bad in addons configs scripting plugins dlls logs; do
    if [[ -e "$DEST/$bad" ]]; then
        echo "[ERROR] Server-only directory leaked into FastDL: $DEST/$bad" >&2
        exit 5
    fi
done

BAD_FILE="$(find "$DEST" -type f \( -name '*.amxx' -o -name '*.sma' -o -name '*.so' -o -name '*.dll' -o -name 'server.cfg' \) -print -quit 2>/dev/null || true)"
if [[ -n "$BAD_FILE" ]]; then
    echo "[ERROR] Server-only file leaked into FastDL: $BAD_FILE" >&2
    exit 6
fi

echo
echo "--- FASTDL STATUS ---"
"$LIVE" fastdl-status "$SID"

echo
echo "--- FASTDL TOP LEVEL ---"
find "$DEST" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort

echo
echo "--- RESOURCE COUNTS ---"
printf "maps:    "; find "$DEST/maps" -type f ! -name '*.bz2' 2>/dev/null | wc -l
printf "models:  "; find "$DEST/models" -type f ! -name '*.bz2' 2>/dev/null | wc -l
printf "sound:   "; find "$DEST/sound" -type f ! -name '*.bz2' 2>/dev/null | wc -l
printf "sprites: "; find "$DEST/sprites" -type f ! -name '*.bz2' 2>/dev/null | wc -l
printf "bz2:     "; find "$DEST" -type f -name '*.bz2' 2>/dev/null | wc -l

PUBLIC_IP="$(python3 - <<'PY'
import json
from pathlib import Path
try:
    print(json.loads(Path('/etc/hyper-cs16/runtime.json').read_text(encoding='utf-8')).get('public_ip',''))
except Exception:
    print('')
PY
)"

TEST="$(find "$DEST" -type f ! -name '*.bz2' \( -name '*.mdl' -o -name '*.bsp' -o -name '*.wav' -o -name '*.spr' -o -name '*.wad' \) | head -n1 || true)"
if [[ -n "$TEST" && -n "$PUBLIC_IP" ]]; then
    REL="${TEST#$DEST/}"
    HEAD="$(mktemp)"
    BODY="$(mktemp)"
    trap 'rm -f "$HEAD" "$BODY"' EXIT

    CODE="$(curl -sS -D "$HEAD" -o "$BODY" -w '%{http_code}' \
        -H "Host: ${PUBLIC_IP}" \
        "http://127.0.0.1/fastdl/${SID}/${REL}")"

    REAL_SHA="$(sha256sum "$TEST" | awk '{print $1}')"
    HTTP_SHA="$(sha256sum "$BODY" | awk '{print $1}')"

    echo
    echo "--- HTTP REAL-FILE TEST ---"
    echo "Resource: $REL"
    echo "HTTP: $CODE"
    grep -iE '^(HTTP/|Content-Type:|Content-Length:|X-Hyper-FastDL:)' "$HEAD" || true
    echo "REAL_SHA=$REAL_SHA"
    echo "HTTP_SHA=$HTTP_SHA"

    [[ "$CODE" == "200" && "$REAL_SHA" == "$HTTP_SHA" ]] || {
        echo "[ERROR] HTTP FastDL did not return the real resource" >&2
        exit 7
    }
fi

echo "[7/7] Enabling automatic incremental synchronization..."
systemctl daemon-reload
systemctl enable hyper-cs16-fastdl-sync.timer >/dev/null 2>&1 || true
systemctl start hyper-cs16-fastdl-sync.timer
systemctl is-active hyper-cs16-fastdl-sync.timer

echo
echo "========================================================"
echo "[SUCCESS] FASTDL PANEL v5.2"
echo "Race condition fixed."
echo "Game server files untouched."
echo "FastDL contains client resources only."
echo "Automatic synchronization enabled again."
echo
echo "FastDL URL:"
echo "  http://${PUBLIC_IP}/fastdl/${SID}/"
echo
echo "Backup:"
echo "  $BACKUP"
echo "========================================================"
