#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run as root/sudo" >&2; exit 1; }

ROOT="${1:-/root/hyper-hosting-panel}"
DOMAIN="${CS16_PANEL_DOMAIN:-www.avito.hyper-host.pw}"
SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
RUN_CTL="/usr/local/sbin/hyper-cs16-ctl"
SITE_CONF="/etc/nginx/sites-available/hyper-host-site-${DOMAIN}.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v42-backup-${STAMP}"

echo "========== HYPER CS16 FASTDL v4.2 =========="
echo "[v4.2] Repo:   $ROOT"
echo "[v4.2] Domain: $DOMAIN"

[[ -f "$SRC_CTL" ]] || { echo "[ERROR] Missing $SRC_CTL" >&2; exit 2; }
[[ -f "$RUN_CTL" ]] || { echo "[ERROR] Missing $RUN_CTL" >&2; exit 2; }

mkdir -p "$BACKUP"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.source"
cp -a "$RUN_CTL" "$BACKUP/hyper-cs16-ctl.runtime"
[[ -f "$SITE_CONF" ]] && cp -a "$SITE_CONF" "$BACKUP/" || true
[[ -f /etc/nginx/conf.d/hyper-cs16-fastdl.conf ]] && cp -a /etc/nginx/conf.d/hyper-cs16-fastdl.conf "$BACKUP/" || true
echo "[v4.2] Backup: $BACKUP"

if command -v hyper >/dev/null 2>&1; then
  hyper nginx fix >/dev/null 2>&1 || true
fi

python3 - "$SRC_CTL" "$RUN_CTL" "$DOMAIN" <<'PY'
from pathlib import Path
import re, sys

domain=sys.argv[3]
replacement = (
    "def _fastdl_url(c:dict)->str:\n"
    "    # Serve FastDL through the existing HYPER-HOST HTTP vhost on port 80.\n"
    "    sid=int(c.get('id') or 0)\n"
    f"    return f'http://{domain}/fastdl/{{sid}}'\n\n"
)

for name in sys.argv[1:3]:
    p=Path(name)
    s=p.read_text(encoding='utf-8')
    s=re.sub(r'(?m)^FASTDL_PORT\s*=\s*8088\s*\n', '', s)
    pattern=r'(?ms)^def _fastdl_url\(c:dict\)->str:\n.*?(?=^def _fastdl_apply_cfg\(c:dict,\s*root:Path\|None=None\)->dict:)'
    new,n=re.subn(pattern,replacement,s,count=1)
    if n != 1:
        raise SystemExit(f'[PATCH ERROR] _fastdl_url function not found safely in {p}')
    p.write_text(new,encoding='utf-8')
PY

python3 -m py_compile "$SRC_CTL"
python3 -m py_compile "$RUN_CTL"
chmod 0755 "$RUN_CTL"
echo "[v4.2] FastDL URL switched to http://${DOMAIN}/fastdl/<id>"

rm -f /etc/nginx/conf.d/hyper-cs16-fastdl.conf

[[ -f "$SITE_CONF" ]] || {
  echo "[ERROR] HYPER-HOST nginx site config not found: $SITE_CONF" >&2
  ls -la /etc/nginx/sites-available/ || true
  exit 3
}

python3 - "$SITE_CONF" "$DOMAIN" <<'PY'
from pathlib import Path
import re, sys

path=Path(sys.argv[1])
domain=sys.argv[2]
text=path.read_text(encoding='utf-8',errors='strict')

location = '''    # HYPER-HOST CS16 FASTDL BEGIN
    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex off;
        sendfile on;
        tcp_nopush on;
        gzip off;
        etag on;
        default_type application/octet-stream;
        limit_except GET HEAD { deny all; }
        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
    }
    # HYPER-HOST CS16 FASTDL END
'''

text=re.sub(
    r'(?ms)^[ \t]*# HYPER-HOST CS16 FASTDL BEGIN\s*$.*?^[ \t]*# HYPER-HOST CS16 FASTDL END\s*$\n?',
    '',
    text
)

starts=[m.start() for m in re.finditer(r'(?m)^[ \t]*server[ \t]*\{',text)]
blocks=[]

for start in starts:
    brace=text.find('{',start)
    depth=0
    quote=None
    esc=False
    end=None
    for i in range(brace,len(text)):
        ch=text[i]
        if quote:
            if esc:
                esc=False
            elif ch=='\\':
                esc=True
            elif ch==quote:
                quote=None
            continue
        if ch in ("'",'"'):
            quote=ch
            continue
        if ch=='{':
            depth+=1
        elif ch=='}':
            depth-=1
            if depth==0:
                end=i+1
                break
    if end:
        body=text[start:end]
        if re.search(r'(?m)^\s*server_name\s+[^;]*\b'+re.escape(domain)+r'\b[^;]*;',body):
            blocks.append((start,end))

if not blocks:
    raise SystemExit(f'[PATCH ERROR] No nginx server block owns {domain} in {path}')

for start,end in reversed(blocks):
    body=text[start:end]
    pos=body.rfind('}')
    body=body[:pos].rstrip()+'\n\n'+location+body[pos:]
    text=text[:start]+body+text[end:]

path.write_text(text,encoding='utf-8')
print(f'[v4.2] FastDL location inserted into {len(blocks)} nginx server block(s)')
PY

nginx -t
systemctl reload nginx || systemctl restart nginx
sleep 0.5

echo
echo "--- NGINX HTTP LISTENERS ---"
ss -lntp 2>/dev/null | grep -E ':(80|443|8088)\b' || true

echo
echo "--- REBUILD FASTDL / APPLY URL ---"
"$RUN_CTL" fastdl-sync-all || true

TEST_FILE="$(find /srv/hyper-cs16/fastdl -type f \( -name '*.mdl' -o -name '*.bsp' -o -name '*.wav' -o -name '*.spr' -o -name '*.bz2' \) 2>/dev/null | head -n 1 || true)"
echo
echo "--- FASTDL LOCAL HTTP TEST ---"

if [[ -n "$TEST_FILE" ]]; then
  REL="${TEST_FILE#/srv/hyper-cs16/fastdl/}"
  URL="http://127.0.0.1/fastdl/$REL"
  echo "File: $TEST_FILE"
  echo "URL:  http://${DOMAIN}/fastdl/$REL"
  STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" --max-time 8 "$URL" || true)"
  echo "HTTP status: $STATUS"
  if [[ "$STATUS" != "200" ]]; then
    echo "[ERROR] FastDL local HTTP test is not 200." >&2
    echo "Check: nginx -T | grep -n -A20 -B5 'HYPER-HOST CS16 FASTDL'" >&2
    exit 4
  fi
else
  echo "[WARNING] No FastDL resource found yet."
fi

echo
echo "--- SERVER #25 (if it exists) ---"
if [[ -f /var/lib/hyper-cs16/servers/25.json || -f /etc/hyper-cs16/servers/25.json ]]; then
  "$RUN_CTL" fastdl-status 25 || true
  grep -nEi 'sv_downloadurl|sv_allowdownload|sv_send_resources|sv_allow_dlfile' \
    /srv/hyper-cs16/servers/25/cstrike/server.cfg || true
fi

echo
echo "[DONE] FastDL no longer depends on TCP 8088."
echo "Expected URL: http://${DOMAIN}/fastdl/<SERVER_ID>/"
echo "For server #25:"
echo "  sudo hyper-cs16-ctl fastdl-sync 25"
echo "  sudo hyper-cs16-ctl fastdl-status 25"
echo "============================================="
