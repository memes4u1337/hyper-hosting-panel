#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
PUBLIC_IP="${2:-90.189.208.25}"

ROOT="/srv/hyper-cs16/servers/$SID"
CS="$ROOT/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
AMXX="$CS/addons/amxmodx"
SCRIPTING="$AMXX/scripting"
PLUGINS="$AMXX/plugins"
CTL="/usr/local/sbin/hyper-cs16-ctl"

KNIFE_SRC="$SCRIPTING/zm_addon_knife.sma"
KNIFE_PLUGIN="$PLUGINS/zm_addon_knife.amxx"

MODEL_NEW_REL="models/oldz_knife_r7/v_gold_wolf_v4.mdl"
MODEL_NEW_CS="$CS/$MODEL_NEW_REL"
MODEL_NEW_FD="$FASTDL/$MODEL_NEW_REL"

MAP_OLD="zm_2day"
MAP_NEW="zm_2day_v2"
MAP_OLD_CS="$CS/maps/${MAP_OLD}.bsp"
MAP_NEW_CS="$CS/maps/${MAP_NEW}.bsp"
MAP_NEW_FD="$FASTDL/maps/${MAP_NEW}.bsp"

URL="http://${PUBLIC_IP}/fastdl/${SID}/"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-client-cache-final-v56-${STAMP}"
TMP="/tmp/oldz-v56-$$"

AMXX_URL="https://github.com/alliedmodders/amxmodx/releases/download/1.9.0.5303/amxmodx-1.9.0-git5303-base-linux.tar.gz"
AMXX_SHA="1ed6898ced2c1fcf225c288b94effc19917e987b284e42911587738ee3c93699"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
command -v nginx >/dev/null 2>&1 || fail "nginx not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v tar >/dev/null 2>&1 || fail "tar not found"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found"

[[ -d "$CS" ]] || fail "missing $CS"
[[ -d "$FASTDL" ]] || fail "missing $FASTDL"
[[ -f "$KNIFE_SRC" ]] || fail "missing $KNIFE_SRC"
[[ -f "$MAP_OLD_CS" ]] || fail "missing $MAP_OLD_CS"
[[ -x "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP" "$TMP"

echo "================================================================"
echo " OLD ZOMBIE CLIENT CACHE FINAL v56"
echo " Server: #$SID"
echo " Model cache-bust: v_gold_wolf_v4.mdl"
echo " Map cache-bust: ${MAP_NEW}.bsp"
echo " FastDL: $URL"
echo " Backup: $BACKUP"
echo "================================================================"

echo "[1/10] Find a VALID current Gold Wolf model..."
MODEL_SRC=""

for p in \
    "$CS/models/oldz_knife_r7/v_gold_wolf_v3.mdl" \
    "$CS/models/oldz_knife_r7/v_gold_wolf_v2.mdl" \
    "$CS/models/oldz_knife_r7/v_gold_wolf.mdl"
do
    [[ -f "$p" ]] || continue
    if python3 - "$p" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
b=p.read_bytes()[:8]
ok=len(b)>=8 and b[:4]==b'IDST' and int.from_bytes(b[4:8],'little',signed=True) in (10,11)
raise SystemExit(0 if ok else 1)
PY
    then
        MODEL_SRC="$p"
        break
    fi
done

[[ -n "$MODEL_SRC" ]] || fail "no valid Gold Wolf IDST model found"
ok "model source: $MODEL_SRC"

mkdir -p "$(dirname "$MODEL_NEW_CS")" "$(dirname "$MODEL_NEW_FD")"
cp -a "$MODEL_SRC" "$MODEL_NEW_CS"
cp -a "$MODEL_SRC" "$MODEL_NEW_FD"

python3 - "$MODEL_NEW_CS" "$MODEL_NEW_FD" <<'PY'
from pathlib import Path
import hashlib,sys
for s in sys.argv[1:]:
    p=Path(s); b=p.read_bytes()
    if len(b)<8 or b[:4]!=b'IDST':
        raise SystemExit(f'bad IDST: {p}')
    ver=int.from_bytes(b[4:8],'little',signed=True)
    if ver not in (10,11):
        raise SystemExit(f'bad model version {ver}: {p}')
    print(p, 'version=',ver,'size=',len(b),'sha256=',hashlib.sha256(b).hexdigest())
PY

echo "[2/10] Cache-bust zm_2day -> zm_2day_v2..."
cp -a "$MAP_OLD_CS" "$BACKUP/${MAP_OLD}.bsp.before"
cp -a "$MAP_OLD_CS" "$MAP_NEW_CS"
mkdir -p "$FASTDL/maps"
cp -a "$MAP_OLD_CS" "$MAP_NEW_FD"

python3 - "$MAP_NEW_CS" "$MAP_NEW_FD" <<'PY'
from pathlib import Path
import hashlib,sys
for s in sys.argv[1:]:
    p=Path(s); b=p.read_bytes()
    if len(b)<4:
        raise SystemExit(f'tiny BSP: {p}')
    ver=int.from_bytes(b[:4],'little',signed=False)
    if ver!=30:
        raise SystemExit(f'bad BSP version {ver}: {p}')
    print(p,'BSP=',ver,'size=',len(b),'sha256=',hashlib.sha256(b).hexdigest())
PY

# Copy companion map files if present.
for ext in nav res txt; do
    if [[ -f "$CS/maps/${MAP_OLD}.${ext}" ]]; then
        cp -a "$CS/maps/${MAP_OLD}.${ext}" "$CS/maps/${MAP_NEW}.${ext}"
        cp -a "$CS/maps/${MAP_OLD}.${ext}" "$FASTDL/maps/${MAP_NEW}.${ext}" 2>/dev/null || true
    fi
done

echo "[3/10] Patch knife source to v4..."
cp -a "$KNIFE_SRC" "$BACKUP/zm_addon_knife.sma.before"

python3 - "$KNIFE_SRC" "$MODEL_NEW_REL" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); new=sys.argv[2]
s=p.read_text(encoding='utf-8',errors='ignore')

rx=r'models/oldz_knife_r7/v_gold_wolf(?:_v\d+)?\.mdl'
hits=re.findall(rx,s,re.I)
if not hits:
    raise SystemExit('Gold Wolf path not found in zm_addon_knife.sma')

s2=re.sub(rx,new,s,flags=re.I)
p.write_text(s2,encoding='utf-8')

print('old references replaced:',len(hits))
print('new path:',new)
PY

grep -Fq "$MODEL_NEW_REL" "$KNIFE_SRC" || fail "v4 path missing in source"

echo "[4/10] Download OFFICIAL AMX Mod X 1.9.0.5303 compiler..."
curl -fL --retry 3 --connect-timeout 15 "$AMXX_URL" -o "$TMP/amxx-base.tar.gz"

GOT_SHA="$(sha256sum "$TMP/amxx-base.tar.gz" | awk '{print $1}')"
[[ "$GOT_SHA" == "$AMXX_SHA" ]] || fail "AMXX archive sha256 mismatch: $GOT_SHA"
ok "official AMXX 5303 archive sha256 verified"

mkdir -p "$TMP/amxx"
tar -xzf "$TMP/amxx-base.tar.gz" -C "$TMP/amxx"

COMP="$TMP/amxx/addons/amxmodx/scripting/amxxpc"
[[ -x "$COMP" ]] || chmod +x "$COMP" 2>/dev/null || true
[[ -x "$COMP" ]] || fail "official amxxpc not found"

echo "[5/10] Compile zm_addon_knife with official compiler..."
# Compile inside official scripting directory while using the server source.
cp -a "$KNIFE_SRC" "$TMP/amxx/addons/amxmodx/scripting/zm_addon_knife.sma"

set +e
(
    cd "$TMP/amxx/addons/amxmodx/scripting"
    ./amxxpc zm_addon_knife.sma -o"$TMP/zm_addon_knife.amxx"
) >"$BACKUP/compile.log" 2>&1
RC=$?
set -e

cat "$BACKUP/compile.log"

[[ "$RC" -eq 0 ]] || fail "official AMXX compiler returned $RC"
[[ -s "$TMP/zm_addon_knife.amxx" ]] || fail "compiled AMXX missing"

if [[ -f "$KNIFE_PLUGIN" ]]; then
    cp -a "$KNIFE_PLUGIN" "$BACKUP/zm_addon_knife.amxx.before"
fi
install -m 0644 "$TMP/zm_addon_knife.amxx" "$KNIFE_PLUGIN"
ok "installed $KNIFE_PLUGIN"

echo "[6/10] Update mapcycle/config references to cache-busted map..."
python3 - "$CS" "$BACKUP" "$MAP_OLD" "$MAP_NEW" <<'PY'
from pathlib import Path
import shutil,sys,re

root=Path(sys.argv[1]); backup=Path(sys.argv[2]); old=sys.argv[3]; new=sys.argv[4]
allowed={'.txt','.cfg','.ini','.json','.lst','.list'}
changed=[]

for p in root.rglob('*'):
    if not p.is_file() or p.suffix.lower() not in allowed:
        continue
    try:
        s=p.read_text(encoding='utf-8',errors='ignore')
    except Exception:
        continue

    # Replace only standalone map token, not substrings of other map names.
    s2=re.sub(rf'(?<![A-Za-z0-9_]){re.escape(old)}(?![A-Za-z0-9_])',new,s)
    if s2==s:
        continue

    rel=p.relative_to(root)
    dst=backup/'maprefs'/rel
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(p,dst)
    p.write_text(s2,encoding='utf-8')
    changed.append(rel.as_posix())

print('map reference files changed:',len(changed))
for x in changed:
    print(' ',x)
PY

# Force start map in state/controller if supported.
"$CTL" map "$SID" "$MAP_NEW" >/dev/null 2>&1 || true

echo "[7/10] Make HYPER-HOST PLACEHOLDER webroot serve real FastDL too..."
# This is the fallback that makes even the wrong/default vhost serve binary files.
mapfile -t PLACEHOLDERS < <(
    grep -RIl --binary-files=without-match --include='*.html' --include='*.htm' --include='*.php' \
      'Домен не настроен' /var/www /usr/share/nginx /srv 2>/dev/null | head -n 20 || true
)

echo "placeholder files found: ${#PLACEHOLDERS[@]}"

for file in "${PLACEHOLDERS[@]}"; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    case "$base" in
        index.html|index.htm|index.php)
            webroot="$(dirname "$file")"
            mkdir -p "$webroot/fastdl"

            target="$webroot/fastdl/$SID"
            if [[ -e "$target" || -L "$target" ]]; then
                cp -aL "$target" "$BACKUP/placeholder-fastdl-${SID}-$(echo "$webroot" | tr '/' '_')" 2>/dev/null || true
                rm -rf "$target"
            fi

            ln -s "$FASTDL" "$target"
            echo " fallback link: $target -> $FASTDL"
            ;;
    esac
done

echo "[8/10] Install NAT-safe nginx FastDL route..."
CONF_DIR="/etc/nginx/hyper-host-managed"
[[ -d "$CONF_DIR" ]] || CONF_DIR="/etc/nginx/conf.d"
[[ -d "$CONF_DIR" ]] || fail "nginx conf dir missing"

TARGET="$CONF_DIR/00-oldz-fastdl-${SID}-FINAL-v56.conf"

shopt -s nullglob
for f in "$CONF_DIR"/*oldz*fastdl*"$SID"*.conf; do
    [[ "$f" == "$TARGET" ]] && continue
    [[ -f "$f" ]] || continue
    cp -a "$f" "$BACKUP/$(basename "$f")"
    mv "$f" "$f.disabled-v56-$STAMP"
done
shopt -u nullglob

cat > "$TARGET" <<EOF
server {
    listen 80;
    server_name ${PUBLIC_IP};

    location = /fastdl/${SID} {
        return 301 /fastdl/${SID}/;
    }

    location ^~ /fastdl/${SID}/ {
        alias ${FASTDL}/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        sendfile on;
        default_type application/octet-stream;
        add_header X-OLDZ-FastDL "server-${SID}-v56" always;
        add_header Cache-Control "no-cache" always;
    }
}
EOF

nginx -t || fail "nginx -t failed"
systemctl reload nginx
ok "nginx v56 reloaded"

echo "[9/10] Verify RAW bytes through LOCAL Host routing..."
HDR="$TMP/hdr"
BODY="$TMP/body"

check_raw() {
    local path="$1"
    local kind="$2"

    curl -fsS -D "$HDR" -H "Host: ${PUBLIC_IP}" \
        "http://127.0.0.1/fastdl/${SID}/${path}" -o "$BODY" \
        || fail "HTTP failed: $path"

    echo "--- $path ---"
    grep -Ei 'HTTP/|Content-Type|Content-Length|X-OLDZ-FastDL' "$HDR" || true

    if [[ "$kind" == "mdl" ]]; then
        magic="$(dd if="$BODY" bs=1 count=4 status=none 2>/dev/null || true)"
        [[ "$magic" == "IDST" ]] || {
            xxd -l 32 "$BODY" || true
            fail "$path is not RAW IDST over HTTP"
        }
    else
        ver="$(od -An -tu4 -N4 "$BODY" | tr -d '[:space:]')"
        [[ "$ver" == "30" ]] || {
            xxd -l 32 "$BODY" || true
            fail "$path is not RAW BSP30 over HTTP"
        }
    fi
}

check_raw "$MODEL_NEW_REL" mdl
check_raw "maps/${MAP_NEW}.bsp" bsp
ok "local nginx Host-routing returns RAW game files"

echo "[10/10] Write FastDL URL, restart on cache-busted map, verify..."
cp -a "$CS/server.cfg" "$BACKUP/server.cfg.before" 2>/dev/null || true

python3 - "$CS/server.cfg" "$URL" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); url=sys.argv[2]
s=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
out=[]
for line in s.splitlines():
    if re.match(r'^\s*sv_downloadurl\b',line,re.I): continue
    if re.match(r'^\s*sv_allowdownload\b',line,re.I): continue
    out.append(line)
out += [
    '',
    '// OLD ZOMBIE CLIENT CACHE FINAL v56',
    'sv_allowdownload 1',
    f'sv_downloadurl "{url}"',
]
p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
PY

# Persist cache-busted start map in state if state exists.
python3 - "$SID" "$MAP_NEW" <<'PY'
from pathlib import Path
import json,sys
sid=sys.argv[1]; m=sys.argv[2]
p=Path(f'/var/lib/hyper-cs16/servers/{sid}.json')
if not p.exists():
    raise SystemExit(0)
try:
    d=json.loads(p.read_text(encoding='utf-8'))
except Exception:
    raise SystemExit(0)
for k in ('start_map','current_map','map'):
    if k in d or k=='start_map':
        d[k]=m
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('state start_map:',m)
PY

systemctl reset-failed "hyper-cs16@${SID}.service" >/dev/null 2>&1 || true
systemctl restart "hyper-cs16@${SID}.service" || true

OK=0
STATUS=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    STATUS="$("$CTL" status "$SID" 2>/dev/null || true)"
    if echo "$STATUS" | grep -q '"running":true' \
       && echo "$STATUS" | grep -q '"udp_listening":true' \
       && echo "$STATUS" | grep -q '"query_ok":true'; then
        OK=1
        break
    fi
done

echo "$STATUS"
[[ "$OK" -eq 1 ]] || {
    journalctl -u "hyper-cs16@${SID}.service" -n 150 --no-pager || true
    fail "server not PROCESS+UDP+A2S ready"
}

echo "--- AMXX ---"
"$CTL" rcon "$SID" "amxx plugins" 2>/dev/null | grep -iE 'Knife|zm_addon_knife|running|plugins' || true

echo "--- DOWNLOAD URL ---"
"$CTL" rcon "$SID" "sv_downloadurl" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE CLIENT CACHE FINAL v56"
echo "================================================================"
echo " New model: $MODEL_NEW_REL"
echo " New map: maps/${MAP_NEW}.bsp"
echo " Knife plugin: rebuilt with OFFICIAL AMXX 1.9.0.5303"
echo " FastDL files: RAW verified locally through nginx"
echo " HYPER-HOST placeholder: fallback FastDL link installed"
echo " Old cached v2 model: NO LONGER USED"
echo " Old cached zm_2day.bsp: NO LONGER USED"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " Backup: $BACKUP"
echo "================================================================"
