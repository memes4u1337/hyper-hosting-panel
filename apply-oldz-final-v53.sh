#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
IP="${2:-90.189.208.25}"

CS="/srv/hyper-cs16/servers/$SID/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
CTL="/usr/local/sbin/hyper-cs16-ctl"
SERVER_CFG="$CS/server.cfg"

OLD1="models/oldz_knife_r7/v_gold_wolf.mdl"
OLD2="models/oldz_knife_r7/v_gold_wolf_v2.mdl"
NEW="models/oldz_knife_r7/v_gold_wolf_v3.mdl"

SRC_MODEL="$CS/$OLD2"
[[ -f "$SRC_MODEL" ]] || SRC_MODEL="$CS/$OLD1"
NEW_CS="$CS/$NEW"
NEW_FD="$FASTDL/$NEW"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-v53-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
command -v nginx >/dev/null 2>&1 || fail "nginx not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
[[ -d "$CS" ]] || fail "missing $CS"
[[ -d "$FASTDL" ]] || fail "missing $FASTDL"
[[ -f "$SRC_MODEL" ]] || fail "no valid source model candidate found"
[[ -x "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP/files" "$BACKUP/nginx"

echo "================================================================"
echo " OLD ZOMBIE FINAL v53"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Full cstrike reference scan"
echo " No AMXX compiler"
echo " No FastDL sync"
echo "================================================================"

echo "[1/9] Build/verify v3 model in cstrike + FastDL..."
python3 - "$SRC_MODEL" "$NEW_CS" "$NEW_FD" <<'PY'
from pathlib import Path
import shutil,sys,hashlib

src=Path(sys.argv[1]); a=Path(sys.argv[2]); b=Path(sys.argv[3])
data=src.read_bytes()

if len(data)<8 or data[:4]!=b'IDST':
    raise SystemExit(f'bad source model header: {data[:16]!r}')
ver=int.from_bytes(data[4:8],'little',signed=True)
if ver not in (10,11):
    raise SystemExit(f'bad model version: {ver}')

for dst in (a,b):
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(src,dst)
    x=dst.read_bytes()
    if x[:4]!=b'IDST':
        raise SystemExit(f'copy invalid: {dst}')

print('version:',ver)
print('size:',len(data))
print('sha256:',hashlib.sha256(data).hexdigest())
PY

echo "[2/9] Scan ALL cstrike files for old/v2 references..."
python3 - "$CS" "$BACKUP/reference-scan-before.txt" "$OLD1" "$OLD2" <<'PY'
from pathlib import Path
import sys

root=Path(sys.argv[1])
report=Path(sys.argv[2])
needles=[sys.argv[3].encode(),sys.argv[4].encode()]

skip_ext={'.mdl','.bsp','.wav','.spr','.wad','.ztmp','.bz2','.zip','.rar','.7z','.so'}
hits=[]

for p in root.rglob('*'):
    if not p.is_file():
        continue
    if p.suffix.lower() in skip_ext:
        continue
    try:
        data=p.read_bytes()
    except Exception:
        continue
    counts=[data.count(n) for n in needles]
    if any(counts):
        hits.append((p.relative_to(root).as_posix(),counts[0],counts[1],p.suffix.lower()))

for row in hits:
    print(f'{row[0]} old={row[1]} v2={row[2]} ext={row[3]}')

report.write_text(
    '\n'.join(f'{p}\told={a}\tv2={b}\text={e}' for p,a,b,e in hits)+'\n',
    encoding='utf-8'
)
print('reference files:',len(hits))
PY

echo "[3/9] Patch every SAFE reference..."
python3 - "$CS" "$BACKUP/files" "$OLD1" "$OLD2" "$NEW" <<'PY'
from pathlib import Path
import shutil,sys

root=Path(sys.argv[1])
backup=Path(sys.argv[2])
old1=sys.argv[3]
old2=sys.argv[4]
new=sys.argv[5]

old1b=old1.encode()
old2b=old2.encode()
newb=new.encode()

# Text/config/source/resource formats safe to rewrite with different lengths.
text_ext={
    '.sma','.inc','.ini','.cfg','.res','.txt','.json','.xml','.lst',
    '.list','.conf','.php','.html','.htm','.js','.css'
}

changed=[]
amxx_changed=[]
old1_amxx=[]

for p in root.rglob('*'):
    if not p.is_file():
        continue
    try:
        data=p.read_bytes()
    except Exception:
        continue

    c1=data.count(old1b)
    c2=data.count(old2b)
    if not (c1 or c2):
        continue

    rel=p.relative_to(root)

    # AMXX: only v2 -> v3 is binary safe because byte lengths match.
    if p.suffix.lower()=='.amxx':
        if c1:
            old1_amxx.append((rel.as_posix(),c1))
        if c2:
            if len(old2b)!=len(newb):
                raise SystemExit('v2/new length mismatch; refusing AMXX patch')
            dst=backup/rel
            dst.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(p,dst)
            patched=data.replace(old2b,newb)
            tmp=p.with_name('.'+p.name+'.v53tmp')
            tmp.write_bytes(patched)
            tmp.chmod(p.stat().st_mode)
            tmp.replace(p)
            amxx_changed.append((rel.as_posix(),c2))
        continue

    # Safe textual files.
    if p.suffix.lower() in text_ext:
        dst=backup/rel
        dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(p,dst)
        s=data.decode('utf-8',errors='ignore')
        s2=s.replace(old1,new).replace(old2,new)
        p.write_text(s2,encoding='utf-8')
        changed.append((rel.as_posix(),c1,c2))
        continue

    print('[WARN] reference in unsupported file left unchanged:',rel,'old=',c1,'v2=',c2)

print('text/resource files patched:',len(changed))
for x in changed:
    print(' PATCHED:',x)

print('AMXX v2->v3 patched:',len(amxx_changed))
for x in amxx_changed:
    print(' AMXX:',x)

if old1_amxx:
    print('[WARN] AMXX files still contain OLD non-v2 path; cannot length-change safely without compile:')
    for x in old1_amxx:
        print(' OLD-AMXX:',x)
PY

echo "[4/9] Verify no v2 reference remains anywhere safe/active..."
python3 - "$CS" "$OLD2" "$NEW" <<'PY'
from pathlib import Path
import sys

root=Path(sys.argv[1])
old=sys.argv[2].encode()
new=sys.argv[3].encode()

skip_ext={'.mdl','.bsp','.wav','.spr','.wad','.ztmp','.bz2','.zip','.rar','.7z','.so'}
old_hits=[]
new_hits=[]

for p in root.rglob('*'):
    if not p.is_file() or p.suffix.lower() in skip_ext:
        continue
    try:
        d=p.read_bytes()
    except Exception:
        continue
    if old in d:
        old_hits.append(p.relative_to(root).as_posix())
    if new in d:
        new_hits.append(p.relative_to(root).as_posix())

print('remaining v2 refs:',len(old_hits))
for x in old_hits:
    print(' V2:',x)

print('v3 refs:',len(new_hits))
for x in new_hits[:50]:
    print(' V3:',x)

if old_hits:
    raise SystemExit('v2 references still remain')
PY

echo "[5/9] Inspect ALL loaded nginx configs for FastDL/IP conflicts..."
NGDUMP="$BACKUP/nginx-T-before.txt"
nginx -T >"$NGDUMP" 2>&1 || true

python3 - "$NGDUMP" "$IP" "$SID" "$BACKUP/nginx-conflicts.txt" <<'PY'
from pathlib import Path
import re,sys

dump=Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore')
ip=sys.argv[2]
sid=sys.argv[3]
out=Path(sys.argv[4])

blocks=[]
for m in re.finditer(r'^# configuration file (.+?):\s*$',dump,re.M):
    p=Path(m.group(1).strip())
    if not p.is_file():
        continue
    try:
        txt=p.read_text(encoding='utf-8',errors='ignore')
    except Exception:
        continue
    if ip in txt or f'/fastdl/{sid}' in txt:
        blocks.append(str(p))

uniq=list(dict.fromkeys(blocks))
out.write_text('\n'.join(uniq)+'\n',encoding='utf-8')
for x in uniq:
    print(' conflict candidate:',x)
PY

echo "[6/9] Disable included FastDL conflicts and install one canonical vhost..."
CONF_DIR="/etc/nginx/hyper-host-managed"
[[ -d "$CONF_DIR" ]] || CONF_DIR="/etc/nginx/conf.d"
[[ -d "$CONF_DIR" ]] || fail "nginx include dir missing"

TARGET="$CONF_DIR/00-oldz-fastdl-${SID}-FINAL-v53.conf"

while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    [[ "$f" == "$TARGET" ]] && continue

    case "$f" in
        "$CONF_DIR"/*.conf)
            base="$(basename "$f")"
            cp -a "$f" "$BACKUP/nginx/$base"
            mv "$f" "$f.disabled-v53-$STAMP"
            echo " disabled: $f"
            ;;
        *)
            echo " left untouched (outside managed include dir): $f"
            ;;
    esac
done < "$BACKUP/nginx-conflicts.txt"

cat > "$TARGET" <<EOF
server {
    listen ${IP}:80;
    server_name ${IP};

    charset utf-8;

    location = / {
        add_header X-OLDZ-FastDL "server-${SID}-v53" always;
        return 302 /fastdl/${SID}/;
    }

    location = /fastdl/${SID} {
        add_header X-OLDZ-FastDL "server-${SID}-v53" always;
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

        add_header X-OLDZ-FastDL "server-${SID}-v53" always;
        add_header Cache-Control "public, max-age=300" always;
    }

    location / {
        add_header X-OLDZ-FastDL "server-${SID}-v53" always;
        return 404;
    }

    access_log /var/log/nginx/oldz-fastdl-${SID}.access.log;
    error_log  /var/log/nginx/oldz-fastdl-${SID}.error.log warn;
}
EOF

nginx -t || fail "nginx -t failed"
systemctl reload nginx
ok "nginx reload OK"

echo "[7/9] Canonical server.cfg FastDL URL..."
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
    '// OLD ZOMBIE FASTDL FINAL v53',
    'sv_allowdownload 1',
    f'sv_downloadurl "{url}"',
]
p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print(url)
PY

echo "[8/9] HTTP verification by v53 header + RAW model + real 404..."
HDR="/tmp/oldz-v53-hdr.$$"
BODY="/tmp/oldz-v53-body.$$"
trap 'rm -f "$HDR" "$BODY"' EXIT

curl -sS -D "$HDR" "http://${IP}/fastdl/${SID}/" -o "$BODY" || fail "FastDL root request failed"

grep -qi "^X-OLDZ-FastDL: server-${SID}-v53" "$HDR" || {
    echo "--- HEADERS ---"; cat "$HDR" || true
    echo "--- BODY ---"; head -n 40 "$BODY" || true
    fail "FastDL request is still handled by another nginx vhost"
}

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "HYPER-HOST placeholder still returned"
fi
ok "FastDL root is handled by v53"

curl -fsS -D "$HDR" "http://${IP}/fastdl/${SID}/${NEW}" -o "$BODY"
grep -qi "^X-OLDZ-FastDL: server-${SID}-v53" "$HDR" || fail "model not served by v53"
MAGIC="$(dd if="$BODY" bs=1 count=4 status=none 2>/dev/null || true)"
[[ "$MAGIC" == "IDST" ]] || {
    xxd -l 32 "$BODY" || true
    fail "v3 model HTTP is not RAW IDST"
}
ok "v3 model HTTP = RAW IDST"

MISS="__missing_v53_${RANDOM}.mdl"
CODE="$(curl -sS -D "$HDR" -o "$BODY" -w '%{http_code}' "http://${IP}/fastdl/${SID}/models/$MISS" || true)"
[[ "$CODE" == "404" ]] || fail "missing asset expected 404, got $CODE"
grep -qi "^X-OLDZ-FastDL: server-${SID}-v53" "$HDR" || fail "404 not from v53"
if grep -qi 'Домен не настроен' "$BODY"; then
    fail "missing file still routed to site placeholder"
fi
ok "missing assets = real 404"

echo "[9/9] Restart server once and verify..."
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

echo "--- sv_downloadurl ---"
"$CTL" rcon "$SID" "sv_downloadurl" || true

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FINAL v53"
echo "================================================================"
echo " FastDL route: VERIFIED by X-OLDZ-FastDL v53"
echo " FastDL source: $FASTDL"
echo " v3 model HTTP: RAW IDST"
echo " v2 references: REMOVED"
echo " AMXX compiler: NOT USED"
echo " FastDL files: NOT SYNCED / NOT RESTORED"
echo " PROCESS: ON"
echo " UDP: ON"
echo " A2S: ON"
echo " Backup: $BACKUP"
echo "================================================================"
