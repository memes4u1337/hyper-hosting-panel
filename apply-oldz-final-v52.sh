#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
IP="${2:-90.189.208.25}"

CS="/srv/hyper-cs16/servers/$SID/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
PLUGINS="$CS/addons/amxmodx/plugins"
SCRIPTING="$CS/addons/amxmodx/scripting"
SERVER_CFG="$CS/server.cfg"
CTL="/usr/local/sbin/hyper-cs16-ctl"

OLD_REL="models/oldz_knife_r7/v_gold_wolf_v2.mdl"
NEW_REL="models/oldz_knife_r7/v_gold_wolf_v3.mdl"
OLD_MODEL="$CS/$OLD_REL"
NEW_MODEL="$CS/$NEW_REL"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-v52-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
command -v nginx >/dev/null 2>&1 || fail "nginx not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v strings >/dev/null 2>&1 || fail "strings not found"
[[ -d "$CS" ]] || fail "missing $CS"
[[ -d "$FASTDL" ]] || fail "missing $FASTDL"
[[ -d "$PLUGINS" ]] || fail "missing $PLUGINS"
[[ -f "$OLD_MODEL" ]] || fail "missing $OLD_MODEL"
[[ -x "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP/nginx" "$BACKUP/plugins" "$BACKUP/scripting"

echo "================================================================"
echo " OLD ZOMBIE FINAL FASTDL + CACHE FIX v52"
echo " Server: #$SID"
echo " IP: $IP"
echo " Backup: $BACKUP"
echo " No AMXX compilation"
echo " No FastDL file sync"
echo "================================================================"

echo "[1/8] Create valid v3 model in cstrike AND FastDL..."
python3 - "$OLD_MODEL" "$NEW_MODEL" "$FASTDL/$NEW_REL" <<'PY'
from pathlib import Path
import shutil,sys,hashlib

src=Path(sys.argv[1])
dst=Path(sys.argv[2])
fd=Path(sys.argv[3])

b=src.read_bytes()
if len(b)<8 or b[:4]!=b'IDST':
    raise SystemExit(f'bad source model header: {b[:16]!r}')
ver=int.from_bytes(b[4:8],'little',signed=True)
if ver not in (10,11):
    raise SystemExit(f'bad source model version: {ver}')

for p in (dst,fd):
    p.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(src,p)
    x=p.read_bytes()
    if len(x)<8 or x[:4]!=b'IDST':
        raise SystemExit(f'copied model invalid: {p}')

print('model version:',ver)
print('size:',len(b))
print('sha256:',hashlib.sha256(b).hexdigest())
print('cstrike v3:',dst)
print('fastdl v3:',fd)
PY

echo "[2/8] Patch SMA v2 -> v3 where present..."
python3 - "$SCRIPTING" "$BACKUP/scripting" "$OLD_REL" "$NEW_REL" <<'PY'
from pathlib import Path
import shutil,sys

root=Path(sys.argv[1])
backup=Path(sys.argv[2])
old=sys.argv[3]
new=sys.argv[4]

changed=0
for p in root.rglob('*.sma'):
    try:
        s=p.read_text(encoding='utf-8',errors='ignore')
    except Exception:
        continue
    if old not in s:
        continue
    rel=p.relative_to(root)
    b=backup/rel
    b.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(p,b)
    n=s.count(old)
    p.write_text(s.replace(old,new),encoding='utf-8')
    changed+=1
    print('patched SMA:',rel,'occurrences=',n)

print('SMA files changed:',changed)
PY

echo "[3/8] Binary-patch ACTIVE AMXX v2 -> v3 without compiler..."
python3 - "$PLUGINS" "$BACKUP/plugins" "$OLD_REL" "$NEW_REL" <<'PY'
from pathlib import Path
import shutil,sys

root=Path(sys.argv[1])
backup=Path(sys.argv[2])
old=sys.argv[3].encode()
new=sys.argv[4].encode()

if len(old)!=len(new):
    raise SystemExit('old/new paths differ in length; binary patch unsafe')

changed=0
for p in sorted(root.glob('*.amxx')):
    try:
        data=p.read_bytes()
    except Exception:
        continue
    count=data.count(old)
    if count<1:
        continue

    b=backup/p.name
    shutil.copy2(p,b)

    patched=data.replace(old,new)
    if patched.count(old)!=0:
        raise SystemExit(f'old path remains after patch: {p}')
    if patched.count(new)<count:
        raise SystemExit(f'new path verification failed: {p}')

    tmp=p.with_name('.'+p.name+'.v52tmp')
    tmp.write_bytes(patched)
    tmp.chmod(p.stat().st_mode)
    tmp.replace(p)

    changed+=1
    print('patched AMXX:',p.name,'occurrences=',count)

print('AMXX files changed:',changed)
if changed<1:
    raise SystemExit('No active AMXX contained v2 path; refusing to guess')
PY

echo "[4/8] Discover and disable conflicting nginx configs..."
NGINX_T="$BACKUP/nginx-T-before.txt"
nginx -T >"$NGINX_T" 2>&1 || true

# Extract config files actually loaded by nginx.
python3 - "$NGINX_T" "$IP" "$SID" "$BACKUP/nginx/conflicts.txt" <<'PY'
from pathlib import Path
import re,sys

dump=Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore')
ip=sys.argv[2]
sid=sys.argv[3]
out=Path(sys.argv[4])

files=[]
for m in re.finditer(r'^# configuration file (.+?):\s*$',dump,re.M):
    p=Path(m.group(1).strip())
    if p.is_file():
        files.append(p)

hits=[]
for p in files:
    try:
        txt=p.read_text(encoding='utf-8',errors='ignore')
    except Exception:
        continue
    if ip in txt or f'/fastdl/{sid}' in txt:
        hits.append(str(p))

out.write_text('\n'.join(dict.fromkeys(hits))+'\n',encoding='utf-8')
print('loaded conflicting candidates:')
for x in dict.fromkeys(hits):
    print(' ',x)
PY

CONF_DIR="/etc/nginx/hyper-host-managed"
[[ -d "$CONF_DIR" ]] || CONF_DIR="/etc/nginx/conf.d"
[[ -d "$CONF_DIR" ]] || fail "nginx conf dir missing"

TARGET="$CONF_DIR/00-oldz-fastdl-${SID}-FINAL.conf"

while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    [[ "$f" == "$TARGET" ]] && continue

    # Do not move nginx.conf itself; only included .conf files.
    case "$f" in
        /etc/nginx/*.conf)
            # top-level nginx.conf or critical top-level files are left alone;
            # exact FastDL override below will still win by server_name.
            echo " leaving top-level config untouched: $f"
            ;;
        *)
            base="$(basename "$f")"
            cp -a "$f" "$BACKUP/nginx/$base"
            mv "$f" "$f.disabled-v52-$STAMP"
            echo " disabled conflict: $f"
            ;;
    esac
done < "$BACKUP/nginx/conflicts.txt"

echo "[5/8] Install ONE canonical exact-IP FastDL vhost..."
cat > "$TARGET" <<EOF
server {
    listen ${IP}:80;
    server_name ${IP};

    charset utf-8;

    location = / {
        add_header X-OLDZ-FastDL "server-${SID}-v52" always;
        return 302 /fastdl/${SID}/;
    }

    location = /fastdl/${SID} {
        add_header X-OLDZ-FastDL "server-${SID}-v52" always;
        return 301 /fastdl/${SID}/;
    }

    location ^~ /fastdl/${SID}/ {
        alias ${FASTDL}/;

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;

        sendfile on;
        tcp_nopush on;
        default_type application/octet-stream;

        add_header X-OLDZ-FastDL "server-${SID}-v52" always;
        add_header Cache-Control "public, max-age=300" always;
    }

    location / {
        add_header X-OLDZ-FastDL "server-${SID}-v52" always;
        return 404;
    }

    access_log /var/log/nginx/oldz-fastdl-${SID}.access.log;
    error_log  /var/log/nginx/oldz-fastdl-${SID}.error.log warn;
}
EOF

if ! nginx -t; then
    rm -f "$TARGET"
    fail "nginx -t failed; target removed. Backups are in $BACKUP"
fi
systemctl reload nginx
ok "nginx reload OK"

echo "[6/8] Write canonical server.cfg FastDL URL..."
URL="http://${IP}/fastdl/${SID}/"
cp -a "$SERVER_CFG" "$BACKUP/server.cfg.before" 2>/dev/null || true

python3 - "$SERVER_CFG" "$URL" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
url=sys.argv[2]
s=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
out=[]
for line in s.splitlines():
    if re.match(r'^\s*sv_downloadurl\b',line,re.I):
        continue
    if re.match(r'^\s*sv_allowdownload\b',line,re.I):
        continue
    out.append(line)
out += [
    '',
    '// OLD ZOMBIE FASTDL FINAL v52',
    'sv_allowdownload 1',
    f'sv_downloadurl "{url}"',
]
p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print(url)
PY

echo "[7/8] Verify HTTP comes from OUR vhost and assets are RAW..."
HDR="/tmp/oldz-v52-hdr.$$"
BODY="/tmp/oldz-v52-body.$$"
trap 'rm -f "$HDR" "$BODY"' EXIT

check_header() {
    local url="$1"
    curl -sS -D "$HDR" "$url" -o "$BODY" || return 1
    grep -qi '^X-OLDZ-FastDL: server-25-v52' "$HDR"
}

check_header "http://${IP}/fastdl/${SID}/" || {
    echo "--- HEADERS ---"; cat "$HDR" || true
    echo "--- BODY ---"; head -n 30 "$BODY" || true
    fail "request is still NOT handled by v52 FastDL vhost"
}
ok "FastDL root handled by v52 vhost"

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "HYPER-HOST placeholder still visible"
fi

grep -qiE 'Index of|<html|<pre' "$BODY" || {
    head -n 40 "$BODY" || true
    fail "directory listing not visible"
}
ok "directory listing visible"

curl -fsS -D "$HDR" "http://${IP}/fastdl/${SID}/${NEW_REL}" -o "$BODY"
grep -qi '^X-OLDZ-FastDL: server-25-v52' "$HDR" || fail "v3 model not served by v52"
MAGIC="$(dd if="$BODY" bs=1 count=4 status=none 2>/dev/null || true)"
[[ "$MAGIC" == "IDST" ]] || {
    xxd -l 32 "$BODY" || true
    fail "HTTP v3 model is NOT raw IDST"
}
ok "v_gold_wolf_v3.mdl = RAW IDST"

# Missing asset must be 404 from our vhost, never site placeholder.
MISS="__oldz_v52_missing_${RANDOM}.mdl"
CODE="$(curl -sS -D "$HDR" -o "$BODY" -w '%{http_code}' "http://${IP}/fastdl/${SID}/models/$MISS" || true)"
[[ "$CODE" == "404" ]] || fail "missing asset expected 404, got $CODE"
grep -qi '^X-OLDZ-FastDL: server-25-v52' "$HDR" || fail "404 not produced by v52"
if grep -qi 'Домен не настроен' "$BODY"; then
    fail "404 routed to site placeholder"
fi
ok "missing assets = real 404"

echo "[8/8] Restart once and verify server + runtime..."
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
[[ "$OK" -eq 1 ]] || fail "server did not become PROCESS+UDP+A2S ready"

echo "--- runtime sv_downloadurl ---"
"$CTL" rcon "$SID" "sv_downloadurl" || true

echo "--- active AMXX v3 refs ---"
for p in "$PLUGINS"/*.amxx; do
    [[ -f "$p" ]] || continue
    if strings -a "$p" | grep -Fq "$NEW_REL"; then
        echo " V3: $(basename "$p")"
    fi
done

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FINAL v52"
echo "================================================================"
echo " FastDL vhost: VERIFIED BY X-OLDZ-FastDL"
echo " Browse: http://${IP}/fastdl/${SID}/"
echo " v3 model HTTP: RAW IDST"
echo " AMXX compiler: NOT USED"
echo " v2 -> v3 AMXX: BINARY PATCHED"
echo " FastDL files: NOT SYNCED / NOT RESTORED"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " Backup: $BACKUP"
echo "================================================================"
