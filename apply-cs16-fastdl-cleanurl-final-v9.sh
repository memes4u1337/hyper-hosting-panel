#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
DOMAIN="old-zombie.ru"
CSTRIKE="/srv/hyper-cs16/servers/${SID}/cstrike"
FASTDL="/srv/hyper-cs16/fastdl/${SID}"
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
CTL="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-fastdl-v9-${STAMP}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] run as root"; exit 1; }
[[ -d "$CSTRIKE" ]] || { echo "[ERROR] missing $CSTRIKE"; exit 2; }
mkdir -p "$BACKUP"

echo "=============================================================="
echo " OLD ZOMBIE FASTDL + CLEAN URL FINAL v9"
echo " Server: #$SID"
echo " URL:    http://$DOMAIN/fastdl/$SID/"
echo " Backup: $BACKUP"
echo "=============================================================="

echo "[1/8] Validate source BSP..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import struct,sys
bad=[]; files=sorted(Path(sys.argv[1]).glob('*.bsp'))
for p in files:
    b=p.read_bytes()[:4]
    v=struct.unpack('<I',b)[0] if len(b)==4 else None
    if v!=30: bad.append((p.name,v,b.hex()))
print('valid BSP:',len(files)-len(bad)); print('bad BSP:',len(bad))
for x in bad[:30]: print('BAD',x)
if bad: raise SystemExit(10)
PY

echo "[2/8] Patch nginx vhost files that nginx -T REALLY loads..."
nginx -T >"$BACKUP/nginx-T-before.txt" 2>&1

python3 - "$BACKUP/nginx-T-before.txt" "$BACKUP" <<'PY'
from pathlib import Path
import re,sys,shutil

dump=Path(sys.argv[1]).read_text(encoding='utf-8',errors='ignore')
backup=Path(sys.argv[2])
domain='old-zombie.ru'; www='www.old-zombie.ru'
site_root=Path('/var/www/hyper-host-sites/old-zombie.ru/public_html')

sections=[]; cur=None; buf=[]
def flush():
    global cur,buf
    if cur and re.search(r'(?im)^\s*server_name\b[^\n;]*old-zombie\.ru','\n'.join(buf)):
        sections.append(cur)
for line in dump.splitlines():
    m=re.match(r'^# configuration file (.+):$',line)
    if m:
        flush(); cur=m.group(1); buf=[]
    else:
        buf.append(line)
flush()

paths=[]
for x in sections:
    p=Path(x)
    try: real=p.resolve(strict=True)
    except Exception: real=p
    if real.exists() and real not in paths:
        paths.append(real)
print('loaded vhost targets:')
for p in paths: print(' ',p)
if not paths: raise SystemExit('No loaded old-zombie.ru nginx config found')

for p in paths:
    t=p.read_text(encoding='utf-8',errors='ignore')
    m=re.search(r'(?im)^\s*root\s+([^;]+);',t)
    if m:
        r=Path(m.group(1).strip().strip('"\''))
        if r.is_dir(): site_root=r; break
print('site root:',site_root)

def blocks(text):
    out=[]
    for m in re.finditer(r'(?m)^[ \t]*server\s*\{',text):
        start=m.start(); i=text.find('{',m.start()); depth=0; quote=None; esc=False
        while i<len(text):
            ch=text[i]
            if quote:
                if esc: esc=False
                elif ch=='\\': esc=True
                elif ch==quote: quote=None
            else:
                if ch in ("'",'"'): quote=ch
                elif ch=='#':
                    n=text.find('\n',i)
                    if n<0: break
                    i=n; continue
                elif ch=='{': depth+=1
                elif ch=='}':
                    depth-=1
                    if depth==0:
                        out.append((start,i+1,text[start:i+1])); break
            i+=1
    return out

rules=[]
if site_root.is_dir():
    for fp in sorted(site_root.glob('*.php')):
        stem=fp.stem
        if stem=='index':
            rules += [
                '    if ($request_method = GET) { rewrite ^/index\\.php$ / permanent; }',
                '    rewrite ^/index/?$ /index.php last;'
            ]
        else:
            q=re.escape(stem)
            rules += [
                f'    if ($request_method = GET) {{ rewrite ^/{q}\\.php$ /{stem} permanent; }}',
                f'    rewrite ^/{q}/?$ /{stem}.php last;'
            ]
clean='\n'.join(rules)

http=(
    'server {\n'
    '    listen 80;\n'
    '    listen [::]:80;\n'
    f'    server_name {domain} {www};\n\n'
    '    location ^~ /.well-known/acme-challenge/ {\n'
    f'        root {site_root};\n'
    '        try_files $uri =404;\n'
    '    }\n\n'
    '    # CS 1.6 FastDL: raw files, NEVER PHP/HTML/HTTPS redirect.\n'
    '    location ^~ /fastdl/ {\n'
    '        alias /srv/hyper-cs16/fastdl/;\n'
    '        autoindex off;\n'
    '        sendfile on;\n'
    '        default_type application/octet-stream;\n'
    '        add_header X-Hyper-FastDL "raw" always;\n'
    '        add_header Cache-Control "public, max-age=86400" always;\n'
    '    }\n\n'
    '    location / {\n'
    f'        return 301 https://{domain}$request_uri;\n'
    '    }\n'
    '}'
)

def patch_ssl(b):
    b=re.sub(r'(?ms)\n\s*# OLDZ V9 BEGIN.*?# OLDZ V9 END\s*\n?','\n',b)
    ins=(
        '\n    # OLDZ V9 BEGIN\n'
        '    location ^~ /fastdl/ {\n'
        '        alias /srv/hyper-cs16/fastdl/;\n'
        '        autoindex off;\n'
        '        sendfile on;\n'
        '        default_type application/octet-stream;\n'
        '        add_header X-Hyper-FastDL "raw" always;\n'
        '        add_header Cache-Control "public, max-age=86400" always;\n'
        '    }\n\n'
        + clean + '\n'
        '    # OLDZ V9 END\n'
    )
    x=b.find('{')+1
    return b[:x]+ins+b[x:]

done=False
for p in paths:
    txt=p.read_text(encoding='utf-8',errors='ignore')
    reps=[]
    for a,b,blk in blocks(txt):
        if not re.search(r'(?im)^\s*server_name\b[^\n;]*old-zombie\.ru',blk):
            continue
        l80=bool(re.search(r'(?im)^\s*listen\s+(?:\[[^\]]+\]:)?80\b',blk))
        l443=bool(re.search(r'(?im)^\s*listen\s+(?:\[[^\]]+\]:)?443\b',blk))
        if l80 and not l443:
            reps.append((a,b,http))
        elif l443:
            reps.append((a,b,patch_ssl(blk)))
    if not reps: continue
    safe=p.as_posix().strip('/').replace('/','__')
    shutil.copy2(p,backup/(safe+'.before'))
    for a,b,new in sorted(reps,reverse=True): txt=txt[:a]+new+txt[b:]
    p.write_text(txt,encoding='utf-8')
    print('patched:',p)
    done=True
if not done: raise SystemExit('No patchable old-zombie.ru server block found')
PY

nginx -t
systemctl reload nginx

echo "[3/8] Clean rebuild FastDL mirror..."
rm -rf "$FASTDL"
mkdir -p "$FASTDL"
for d in maps models sound sprites gfx resource overviews events media; do
  if [[ -d "$CSTRIKE/$d" ]]; then
    mkdir -p "$FASTDL/$d"
    rsync -a --delete --exclude='*.ztmp' "$CSTRIKE/$d/" "$FASTDL/$d/"
  fi
done
find "$CSTRIKE" -maxdepth 1 -type f -iname '*.wad' -exec cp -a -t "$FASTDL" -- {} + 2>/dev/null || true
find "$FASTDL" -type f -name '*.ztmp' -delete 2>/dev/null || true
chown -R root:www-data "$FASTDL" 2>/dev/null || true
find "$FASTDL" -type d -exec chmod 0755 {} +
find "$FASTDL" -type f -exec chmod 0644 {} +

echo "[4/8] Validate mirror BSP..."
python3 - "$CSTRIKE/maps" "$FASTDL/maps" <<'PY'
from pathlib import Path
import struct,sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2])
bad=[]; missing=[]; size=[]
for p in sorted(src.glob('*.bsp')):
    q=dst/p.name
    if not q.is_file(): missing.append(p.name); continue
    b=q.read_bytes()[:4]; v=struct.unpack('<I',b)[0] if len(b)==4 else None
    if v!=30: bad.append((p.name,v,b.hex()))
    if p.stat().st_size!=q.stat().st_size: size.append(p.name)
print('source:',len(list(src.glob('*.bsp'))),'mirror:',len(list(dst.glob('*.bsp'))))
print('missing:',len(missing),'bad:',len(bad),'size mismatch:',len(size))
if missing or bad or size:
    print('MISSING',missing[:30]); print('BAD',bad[:30]); print('SIZE',size[:30])
    raise SystemExit(20)
PY

echo "[5/8] Normalize server.cfg and keep exactly ONE FastDL block..."
python3 - "$CSTRIKE/server.cfg" "$BACKUP/server.cfg.before" "$SID" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); backup=Path(sys.argv[2]); sid=sys.argv[3]
raw=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
backup.write_text(raw,encoding='utf-8')
if raw.count('\\n')>=5 and raw.count('\n')<=2:
    raw=raw.replace('\\r\\n','\n').replace('\\n','\n').replace('\\r','\n')
text=raw.replace('\r\n','\n').replace('\r','\n')
text=re.sub(r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?','',text)
managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
kept=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+',line)
    if m and m.group(1).lower() in managed: continue
    kept.append(line.rstrip())
out=[]; blank=False
for line in kept:
    b=not line.strip()
    if b and blank: continue
    out.append(line); blank=b
url=f'http://old-zombie.ru/fastdl/{sid}/'
block=['','// HYPER-HOST FASTDL BEGIN','sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl "{url}"','// HYPER-HOST FASTDL END','']
content='\n'.join(out).rstrip()+'\n'+'\n'.join(block)
p.write_text(content,encoding='utf-8')
print('lines:',len(content.splitlines()))
print('FastDL blocks:',content.count('// HYPER-HOST FASTDL BEGIN'))
print('url:',url)
PY

cat >"$CSTRIKE/fastdl.cfg" <<EOF2
sv_allowdownload 1
sv_allowupload 0
sv_send_resources 1
sv_allow_dlfile 1
sv_downloadurl "http://$DOMAIN/fastdl/$SID/"
EOF2
for f in server_download_fix.cfg SAFE_DOWNLOAD_MODE.cfg ENABLE_FASTDL_AFTER_VERIFY.cfg; do
  cp -f "$CSTRIKE/fastdl.cfg" "$CSTRIKE/$f" 2>/dev/null || true
done

if [[ -f "$STATE" ]]; then
python3 - "$STATE" "$SID" <<'PY'
import json,sys
p=sys.argv[1]; sid=sys.argv[2]
d=json.load(open(p,encoding='utf-8'))
d['fastdl_url']=f'http://old-zombie.ru/fastdl/{sid}'
with open(p,'w',encoding='utf-8') as f: json.dump(d,f,ensure_ascii=False,indent=2)
PY
fi

echo "[6/8] Verify RAW BSP locally on HTTP and HTTPS..."
PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname 'zm_*.bsp' -print -quit)"
[[ -n "$PROBE" ]] || PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname '*.bsp' -print -quit)"
[[ -n "$PROBE" ]] || { echo "[ERROR] no BSP in FastDL"; exit 30; }
REL="${PROBE#"$FASTDL/"}"

for SCHEME in http https; do
  PORT=80; OPT=()
  [[ "$SCHEME" == "https" ]] && { PORT=443; OPT=(-k); }
  HDR="$BACKUP/${SCHEME}.headers"; BODY="$BACKUP/${SCHEME}.body"
  curl "${OPT[@]}" -sS --resolve "$DOMAIN:$PORT:127.0.0.1" -H 'Range: bytes=0-3' -D "$HDR" -o "$BODY" "$SCHEME://$DOMAIN/fastdl/$SID/$REL"
  echo "--- $SCHEME ---"
  head -n 12 "$HDR"
  HEX="$(xxd -l 4 -p "$BODY")"
  echo "body head: $HEX"
  [[ "$HEX" == "1e000000" ]] || { echo "[ERROR] $SCHEME still returns HTML/non-BSP"; exit 31; }
done

echo "[7/8] Restart CS server and apply runtime FastDL..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
if [[ -x "$CTL" ]]; then
  "$CTL" rcon "$SID" "sv_allowdownload 1" || true
  "$CTL" rcon "$SID" "sv_allow_dlfile 1" || true
  "$CTL" rcon "$SID" "sv_downloadurl \"http://$DOMAIN/fastdl/$SID/\"" || true
  "$CTL" rcon "$SID" "sv_downloadurl" || true
fi

echo "[8/8] Public diagnostic..."
HDR="$BACKUP/public.headers"; BODY="$BACKUP/public.body"
set +e
curl -sS --connect-timeout 4 --max-time 15 -H 'Range: bytes=0-3' -D "$HDR" -o "$BODY" "http://$DOMAIN/fastdl/$SID/$REL"
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  head -n 12 "$HDR"
  HEX="$(xxd -l 4 -p "$BODY" 2>/dev/null || true)"
  echo "public body head: $HEX"
  [[ "$HEX" == "1e000000" ]] && echo "[OK] PUBLIC FastDL is raw BSP" || echo "[WARN] public route differs from local nginx"
else
  echo "[WARN] public self-test failed from server; possible NAT hairpin"
fi

echo
echo "=============================================================="
echo " [SUCCESS] FASTDL + CLEAN URL FINAL v9"
echo "=============================================================="
echo "FastDL: http://$DOMAIN/fastdl/$SID/"
echo "Probe:  $REL"
echo "Correct BSP head: 1e000000"
echo
echo "HTTP 206 is NORMAL for Range: bytes=0-3."
echo "The old failure was 206 + text/html + 3c21646f ('<!do')."
echo "Backup: $BACKUP"
