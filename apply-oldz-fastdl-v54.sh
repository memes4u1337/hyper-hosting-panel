#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
IP="${2:-90.189.208.25}"
FASTDL="/srv/hyper-cs16/fastdl/$SID"
CS="/srv/hyper-cs16/servers/$SID/cstrike"
SERVER_CFG="$CS/server.cfg"
CTL="/usr/local/sbin/hyper-cs16-ctl"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-v54-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
command -v nginx >/dev/null 2>&1 || fail "nginx not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
[[ -d "$FASTDL" ]] || fail "missing FastDL root: $FASTDL"
[[ -d "$CS" ]] || fail "missing cstrike: $CS"
[[ -x "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP/nginx"

echo "================================================================"
echo " OLD ZOMBIE FASTDL CLEAN FINAL v54"
echo " Server: #$SID"
echo " IP: $IP"
echo " FastDL root: $FASTDL"
echo " Backup: $BACKUP"
echo "================================================================"

echo "[1/6] Dump full loaded nginx config..."
DUMP="$BACKUP/nginx-T-before.txt"
nginx -T >"$DUMP" 2>&1 || true

echo "[2/6] Find EVERY loaded FastDL/IP/v51 config..."
python3 - "$DUMP" "$IP" "$SID" "$BACKUP/loaded-fastdl-configs.txt" <<'PY'
from pathlib import Path
import re,sys

dump=Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore')
ip=sys.argv[2]
sid=sys.argv[3]
out=Path(sys.argv[4])

# Parse nginx -T into actual file sections.
matches=list(re.finditer(r'^# configuration file (.+?):\s*$',dump,re.M))
hits=[]

for i,m in enumerate(matches):
    path=Path(m.group(1).strip())
    start=m.end()
    end=matches[i+1].start() if i+1<len(matches) else len(dump)
    body=dump[start:end]

    reasons=[]
    if ip in body:
        reasons.append('IP')
    if f'/fastdl/{sid}' in body:
        reasons.append('FASTDL_PATH')
    if f'server-{sid}-v51' in body:
        reasons.append('V51_HEADER')
    if f'server-{sid}-v52' in body:
        reasons.append('V52_HEADER')
    if f'server-{sid}-v53' in body:
        reasons.append('V53_HEADER')

    if reasons and path.is_file():
        hits.append((str(path),','.join(reasons)))

uniq=[]
seen=set()
for p,r in hits:
    if p in seen:
        continue
    seen.add(p)
    uniq.append((p,r))

for p,r in uniq:
    print(f' {p} [{r}]')

out.write_text('\n'.join(p for p,_ in uniq)+'\n',encoding='utf-8')
print('loaded candidates:',len(uniq))
PY

echo "[3/6] Disable ALL included conflicting FastDL configs..."
TARGET_DIR="/etc/nginx/hyper-host-managed"
[[ -d "$TARGET_DIR" ]] || TARGET_DIR="/etc/nginx/conf.d"
[[ -d "$TARGET_DIR" ]] || fail "no nginx managed include dir"

TARGET="$TARGET_DIR/00-oldz-fastdl-${SID}-FINAL-v54.conf"

while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    [[ "$f" == "$TARGET" ]] && continue

    case "$f" in
        /etc/nginx/nginx.conf)
            echo " skip main nginx.conf"
            ;;
        /etc/nginx/sites-enabled/*|/etc/nginx/conf.d/*|/etc/nginx/hyper-host-managed/*|/etc/nginx/sites-available/*)
            base="$(echo "$f" | sed 's#/#_#g')"
            cp -a "$f" "$BACKUP/nginx/$base"
            mv "$f" "$f.disabled-v54-$STAMP"
            echo " disabled: $f"
            ;;
        *)
            echo " skip unknown path: $f"
            ;;
    esac
done < "$BACKUP/loaded-fastdl-configs.txt"

echo "[4/6] Install ONE canonical exact-IP v54 vhost..."
cat > "$TARGET" <<EOF
server {
    listen ${IP}:80;
    server_name ${IP};

    charset utf-8;

    location = / {
        add_header X-OLDZ-FastDL "server-${SID}-v54" always;
        return 302 /fastdl/${SID}/;
    }

    location = /fastdl/${SID} {
        add_header X-OLDZ-FastDL "server-${SID}-v54" always;
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

        add_header X-OLDZ-FastDL "server-${SID}-v54" always;
        add_header Cache-Control "public, max-age=300" always;
    }

    location / {
        add_header X-OLDZ-FastDL "server-${SID}-v54" always;
        return 404;
    }

    access_log /var/log/nginx/oldz-fastdl-${SID}.access.log;
    error_log  /var/log/nginx/oldz-fastdl-${SID}.error.log warn;
}
EOF

nginx -t || fail "nginx -t failed"
systemctl reload nginx
ok "nginx reloaded"

echo "[5/6] Verify v54 is REALLY serving the request..."
HDR="/tmp/oldz-v54-hdr.$$"
BODY="/tmp/oldz-v54-body.$$"
trap 'rm -f "$HDR" "$BODY"' EXIT

curl -sS -D "$HDR" "http://${IP}/fastdl/${SID}/" -o "$BODY" || fail "FastDL root request failed"

echo "--- HEADERS ---"
cat "$HDR"

grep -qi "^X-OLDZ-FastDL: server-${SID}-v54" "$HDR" || {
    echo "--- BODY ---"
    head -n 40 "$BODY" || true
    echo
    echo "--- STILL LOADED FASTDL CONFIGS AFTER RELOAD ---"
    nginx -T 2>&1 | grep -nE "server-${SID}-v5[1-4]|/fastdl/${SID}|${IP}" | head -n 200 || true
    fail "another nginx vhost still wins; v54 header missing"
}

if grep -qi 'Домен не настроен' "$BODY"; then
    fail "HYPER-HOST placeholder still returned"
fi

ok "v54 header confirmed"
ok "FastDL root is no longer handled by v51"

echo "[6/6] Verify listing + missing 404 + server.cfg..."
grep -qiE 'Index of|<html|<pre' "$BODY" || {
    head -n 40 "$BODY" || true
    fail "directory listing not visible"
}
ok "directory listing visible"

MISS="__oldz_v54_missing_${RANDOM}.mdl"
CODE="$(curl -sS -D "$HDR" -o "$BODY" -w '%{http_code}' "http://${IP}/fastdl/${SID}/models/$MISS" || true)"
[[ "$CODE" == "404" ]] || fail "missing asset expected 404, got $CODE"
grep -qi "^X-OLDZ-FastDL: server-${SID}-v54" "$HDR" || fail "404 not served by v54"
ok "missing assets return real 404"

URL="http://${IP}/fastdl/${SID}/"
cp -a "$SERVER_CFG" "$BACKUP/server.cfg.before" 2>/dev/null || true

python3 - "$SERVER_CFG" "$URL" <<'PY'
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
    '// OLD ZOMBIE FASTDL FINAL v54',
    'sv_allowdownload 1',
    f'sv_downloadurl "{url}"',
]
p.write_text('\n'.join(out).rstrip()+'\n',encoding='utf-8')
print(url)
PY

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE FASTDL v54"
echo "================================================================"
echo " Header: X-OLDZ-FastDL: server-${SID}-v54"
echo " Browse: http://${IP}/fastdl/${SID}/"
echo " Source: $FASTDL"
echo " Old v51/v52/v53 FastDL configs: DISABLED"
echo " Missing files: HTTP 404"
echo " No FastDL sync performed"
echo " Backup: $BACKUP"
echo "================================================================"
