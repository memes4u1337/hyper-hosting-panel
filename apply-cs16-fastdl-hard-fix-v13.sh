#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
PUBLIC_IP="${3:-90.189.208.25}"

SRC_CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
SERVER_ROOT="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER_ROOT/cstrike"
FASTDL_ROOT="/srv/hyper-cs16/fastdl"
FASTDL="$FASTDL_ROOT/$SID"
STATE="/var/lib/hyper-cs16/servers/$SID.json"
RUNTIME="/etc/hyper-cs16/runtime.json"
CFG="$CSTRIKE/server.cfg"
NGINX_IP_CONF="/etc/nginx/conf.d/00-hyper-cs16-fastdl-ip.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v13-${STAMP}"
QUARANTINE="$BACKUP/nginx-quarantine"
URL="http://$PUBLIC_IP/fastdl/$SID/"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$CSTRIKE" ]] || fail "missing $CSTRIKE"
[[ -d "$CSTRIKE/maps" ]] || fail "missing $CSTRIKE/maps"
[[ -f "$SRC_CTL" ]] || fail "missing $SRC_CTL"

mkdir -p "$BACKUP" "$QUARANTINE"
cp -a "$SRC_CTL" "$BACKUP/hyper-cs16-ctl.repo.before"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -f "$CFG" ]] && cp -a "$CFG" "$BACKUP/server.cfg.before" || true
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/25.json.before" || true
[[ -f "$RUNTIME" ]] && cp -a "$RUNTIME" "$BACKUP/runtime.json.before" || true
[[ -f "$NGINX_IP_CONF" ]] && cp -a "$NGINX_IP_CONF" "$BACKUP/nginx-ip.before.conf" || true

echo "================================================================"
echo " HYPER-HOST CS 1.6 FASTDL HARD FIX v13"
echo " Server:     #$SID"
echo " Game IP:    $PUBLIC_IP"
echo " FastDL URL: $URL"
echo " Backup:     $BACKUP"
echo "================================================================"

echo "[1/12] Validate source BSP files..."
python3 - "$CSTRIKE/maps" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1])
maps=sorted(root.glob("*.bsp"))
if not maps:
    raise SystemExit("no BSP files")
bad=[]
for p in maps:
    b=p.read_bytes()[:4]
    ver=struct.unpack("<I",b)[0] if len(b)==4 else None
    if ver != 30:
        bad.append((p.name,ver,b.hex()))
print("maps:",len(maps),"valid:",len(maps)-len(bad),"bad:",len(bad))
for x in bad[:50]: print("BAD",x)
if bad: raise SystemExit(20)
PY

echo "[2/12] Quarantine stale nginx backup artifacts safely..."
python3 - "$QUARANTINE" <<'PY'
from pathlib import Path
import hashlib,os,re,shutil,sys
dst=Path(sys.argv[1]); dst.mkdir(parents=True,exist_ok=True)
roots=[Path('/etc/nginx/sites-enabled'),Path('/etc/nginx/conf.d'),Path('/etc/nginx/hyper-host-managed'),Path('/etc/nginx/hyper-host-managed/sites-enabled')]
rx=re.compile(r'(?i)(?:\.bak(?:\.|$)|\.fastdl-v\d+(?:\.|$)|\.pre-v\d+(?:\.|$)|\.disabled-v\d+(?:\.|$)|before-cleanurls)')
manifest=[]; count=0
for root in roots:
    if not root.is_dir(): continue
    try: entries=list(root.iterdir())
    except OSError: continue
    for p in entries:
        if not rx.search(p.name): continue
        short=hashlib.sha256(str(p).encode('utf-8','surrogateescape')).hexdigest()[:20]
        target=dst/(root.name+'__'+short+'.q')
        n=1
        while target.exists() or target.is_symlink():
            target=dst/(root.name+'__'+short+f'_{n}.q'); n+=1
        try:
            if p.is_symlink():
                target.write_text('SYMLINK -> '+os.readlink(p)+'\n',encoding='utf-8'); p.unlink()
            else:
                shutil.move(str(p),str(target))
            manifest.append(f'{target.name}\t{p}\n'); count+=1
        except FileNotFoundError:
            pass
if manifest: (dst/'manifest.tsv').write_text(''.join(manifest),encoding='utf-8')
print('quarantined:',count)
PY

echo "[3/12] Restore clean FastDL controller functions and remove old HTTP gate..."
python3 - "$SRC_CTL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')

fastdl_url = '''def _fastdl_url(c:dict)->str:
    sid=int(c.get('id') or 0)
    public=''
    try:
        rt=load_runtime(); public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()
    except Exception:
        public=str(c.get('public_ip') or '').strip()
    try:
        addr=ipaddress.ip_address(public)
        if addr.version==4 and not addr.is_unspecified and not addr.is_loopback:
            return f'http://{public}/fastdl/{sid}/'
    except Exception:
        pass
    return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'
'''

apply_cfg = '''def _fastdl_apply_cfg(c:dict, root:Path|None=None)->dict:
    root=Path(root or c['path'])
    cfg=root/'cstrike/server.cfg'; cfg.parent.mkdir(parents=True,exist_ok=True)
    text=cfg.read_text(encoding='utf-8',errors='ignore') if cfg.exists() else ''
    text=text.replace('\\r\\n','\\n').replace('\\r','\\n')
    text=re.sub(r'(?ims)^\\s*// HYPER-HOST FASTDL BEGIN\\s*$.*?^\\s*// HYPER-HOST FASTDL END\\s*$\\n?', '', text)
    managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
    kept=[]; replaced=[]
    for line in text.splitlines():
        m=re.match(r'^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s+',line)
        if m and m.group(1).lower() in managed:
            replaced.append(line.strip()); continue
        kept.append(line)
    url=_fastdl_url(c)
    block=['// HYPER-HOST FASTDL BEGIN','// Managed automatically by HYPER-HOST.','sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl "{url}"','// HYPER-HOST FASTDL END']
    cfg.write_text('\\n'.join(kept).rstrip()+'\\n\\n'+'\\n'.join(block)+'\\n',encoding='utf-8')
    return {'ok':True,'url':url,'config':str(cfg),'replaced':replaced}
'''

copy_tree = '''def _fastdl_copy_tree(src:Path,dst:Path):
    if not src.is_dir():
        if dst.exists(): shutil.rmtree(dst,ignore_errors=True)
        return
    dst.mkdir(parents=True,exist_ok=True)
    cp=run(['rsync','-a','--delete','--safe-links',str(src)+'/',str(dst)+'/'],check=False,timeout=1200)
    if cp.returncode!=0:
        raise RuntimeError('FastDL rsync failed for '+str(src)+': '+(cp.stdout or '')[-2500:])
'''

sync_func = '''def fastdl_sync(sid:int, configure:bool=True):
    require_root(); c=load_server(sid); root=Path(c['path']); cstrike=root/'cstrike'
    if not cstrike.is_dir(): raise RuntimeError(f'cstrike directory is missing: {cstrike}')
    FASTDL_ROOT.mkdir(parents=True,exist_ok=True)
    dest=FASTDL_ROOT/str(sid); dest.mkdir(parents=True,exist_ok=True)
    copied_dirs=[]
    for name in FASTDL_DIRS:
        src=cstrike/name; dd=dest/name
        _fastdl_copy_tree(src,dd)
        if src.is_dir(): copied_dirs.append(name)
    source_wads={x.name:x for x in cstrike.iterdir() if x.is_file() and x.suffix.lower()=='.wad'}
    for old in dest.glob('*.wad'):
        if old.name not in source_wads:
            try: old.unlink()
            except OSError: pass
    for name,src in source_wads.items(): shutil.copy2(src,dest/name)
    cfg_result=_fastdl_apply_cfg(c,root) if configure else {'url':_fastdl_url(c)}
    run(['chown','-R','root:www-data',str(dest)],check=False)
    run(['find',str(dest),'-type','d','-exec','chmod','0755','{}','+'],check=False)
    run(['find',str(dest),'-type','f','-exec','chmod','0644','{}','+'],check=False)
    files=0; total=0
    for fp in dest.rglob('*'):
        try:
            if fp.is_file(): files+=1; total+=fp.stat().st_size
        except OSError: pass
    c['fastdl_url']=cfg_result.get('url') or _fastdl_url(c)
    c['fastdl_last_sync']=int(time.time()); c['fastdl_files']=files; c['fastdl_bytes']=total
    save_server(c)
    runtime_applied=False; runtime_errors=[]
    if service_status(sid)=='active' and udp_listening(int(c.get('port') or 0)):
        for cmd in ['sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl "{c["fastdl_url"]}"']:
            try: query_rcon('127.0.0.1',int(c['port']),str(c.get('rcon_password','')),cmd,2.0)
            except Exception as exc: runtime_errors.append(str(exc))
        runtime_applied=not runtime_errors
    return {'ok':True,'id':sid,'url':c['fastdl_url'],'root':str(dest),'files':files,'bytes':total,'dirs':copied_dirs,'config':cfg_result,'runtime_applied':runtime_applied,'runtime_errors':runtime_errors[:5]}
'''

start=s.find('def _fastdl_url(c:dict)->str:')
end=s.find('\ndef fastdl_status(',start)
if start < 0 or end < 0: raise SystemExit('FastDL core boundaries not found')
s=s[:start]+fastdl_url+'\n'+apply_cfg+'\n'+copy_tree+'\n'+sync_func+s[end:]
if 'FastDL HTTP is not serving raw BSP bytes' in s:
    raise SystemExit('old HTTP validation gate still exists outside FastDL core')
marker='# HYPER-HOST FASTDL HARD FIX v13'
if marker not in s: s=s.replace('#!/usr/bin/env python3\n','#!/usr/bin/env python3\n'+marker+'\n',1)
p.write_text(s,encoding='utf-8')
print('patched:',p)
PY

python3 -m py_compile "$SRC_CTL"
install -m 0755 "$SRC_CTL" "$LIVE_CTL"
python3 -m py_compile "$LIVE_CTL"
grep -Fq 'FastDL HTTP is not serving raw BSP bytes' "$LIVE_CTL" && fail "old FastDL HTTP gate still exists in LIVE controller" || true
echo "controller HTTP gate: removed"

echo "[4/12] Persist public IP..."
python3 - "$RUNTIME" "$STATE" "$PUBLIC_IP" "$SID" <<'PY'
from pathlib import Path
import json,sys
runtime,state=Path(sys.argv[1]),Path(sys.argv[2]); ip=sys.argv[3]; sid=int(sys.argv[4])
for p in (runtime,state):
    if not p.exists(): continue
    d=json.loads(p.read_text(encoding='utf-8')); d['public_ip']=ip
    if p==state: d['fastdl_url']=f'http://{ip}/fastdl/{sid}/'
    tmp=p.with_name('.'+p.name+'.v13.tmp'); tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); tmp.replace(p)
    print('updated:',p)
PY

echo "[5/12] Build FastDL mirror DIRECTLY (controller is NOT called)..."
mkdir -p "$FASTDL"
for d in maps models sound sprites gfx resource overviews events media; do
    if [[ -d "$CSTRIKE/$d" ]]; then
        mkdir -p "$FASTDL/$d"
        rsync -a --delete --safe-links "$CSTRIKE/$d/" "$FASTDL/$d/"
    else
        rm -rf "$FASTDL/$d"
    fi
done
find "$FASTDL" -maxdepth 1 -type f -iname '*.wad' -delete
find "$CSTRIKE" -maxdepth 1 -type f -iname '*.wad' -exec cp -a {} "$FASTDL/" \;
chown -R root:www-data "$FASTDL"
find "$FASTDL" -type d -exec chmod 0755 {} +
find "$FASTDL" -type f -exec chmod 0644 {} +

echo "[6/12] Validate mirror BSP files..."
python3 - "$CSTRIKE/maps" "$FASTDL/maps" <<'PY'
from pathlib import Path
import struct,sys
src,dst=Path(sys.argv[1]),Path(sys.argv[2]); missing=[]; bad=[]; mismatch=[]
for p in sorted(src.glob('*.bsp')):
    q=dst/p.name
    if not q.is_file(): missing.append(p.name); continue
    b=q.read_bytes()[:4]; ver=struct.unpack('<I',b)[0] if len(b)==4 else None
    if ver!=30: bad.append((p.name,ver,b.hex()))
    if p.stat().st_size!=q.stat().st_size: mismatch.append((p.name,p.stat().st_size,q.stat().st_size))
print('source:',len(list(src.glob('*.bsp'))),'mirror:',len(list(dst.glob('*.bsp'))))
print('missing:',len(missing),'bad:',len(bad),'size mismatch:',len(mismatch))
if missing or bad or mismatch: raise SystemExit(30)
PY

echo "[7/12] Write dedicated nginx IP FastDL vhost..."
cat >"$NGINX_IP_CONF" <<EOF
# HYPER-HOST CS 1.6 FastDL - managed by v13
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;

    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-error.log warn;

    location ^~ /fastdl/ {
        alias $FASTDL_ROOT/;
        autoindex off;
        sendfile on;
        tcp_nopush on;
        types { }
        default_type application/octet-stream;
        add_header X-Hyper-FastDL "raw-v13" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "public, max-age=86400" always;
        try_files \$uri =404;
    }

    location / { return 404; }
}
EOF

nginx -t
systemctl reload nginx

echo "[8/12] Verify LOCAL nginx routing for Host $PUBLIC_IP..."
PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname 'zm_*.bsp' -print -quit)"
[[ -n "$PROBE" ]] || PROBE="$(find "$FASTDL/maps" -maxdepth 1 -type f -iname '*.bsp' -print -quit)"
[[ -n "$PROBE" ]] || fail "no BSP in mirror"
REL="${PROBE#"$FASTDL/"}"
LOCAL_HDR="$BACKUP/local.headers"; LOCAL_BODY="$BACKUP/local.body"
curl -sS --resolve "$PUBLIC_IP:80:127.0.0.1" -H 'Range: bytes=0-3' -D "$LOCAL_HDR" -o "$LOCAL_BODY" "http://$PUBLIC_IP/fastdl/$SID/$REL"
head -n 30 "$LOCAL_HDR"
LOCAL_HEX="$(xxd -l 4 -p "$LOCAL_BODY")"
echo "local body head: $LOCAL_HEX"
grep -qi '^X-Hyper-FastDL: raw-v13' "$LOCAL_HDR" || fail "request did not hit v13 FastDL vhost"
[[ "$LOCAL_HEX" == "1e000000" ]] || fail "local nginx returned non-BSP bytes: $LOCAL_HEX"

echo "[9/12] Write exactly one FastDL block to server.cfg..."
python3 - "$CFG" "$URL" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); url=sys.argv[2]
text=p.read_text(encoding='utf-8',errors='ignore') if p.exists() else ''
text=text.replace('\r\n','\n').replace('\r','\n')
text=re.sub(r'(?ims)^\s*// HYPER-HOST FASTDL BEGIN\s*$.*?^\s*// HYPER-HOST FASTDL END\s*$\n?','',text)
managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}; keep=[]
for line in text.splitlines():
    m=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+',line)
    if m and m.group(1).lower() in managed: continue
    keep.append(line)
block=['// HYPER-HOST FASTDL BEGIN','// Managed automatically by HYPER-HOST.','sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl "{url}"','// HYPER-HOST FASTDL END']
p.write_text('\n'.join(keep).rstrip()+'\n\n'+'\n'.join(block)+'\n',encoding='utf-8')
print('FastDL blocks:',p.read_text(encoding='utf-8').count('// HYPER-HOST FASTDL BEGIN')); print('url:',url)
PY

echo "[10/12] Test CLEAN controller fastdl-sync only AFTER nginx is fixed..."
SYNC_OUT="$BACKUP/controller-sync.json"
set +e
"$LIVE_CTL" fastdl-sync "$SID" >"$SYNC_OUT" 2>&1
SYNC_RC=$?
set -e
cat "$SYNC_OUT"
[[ $SYNC_RC -eq 0 ]] || fail "clean controller fastdl-sync failed; see $SYNC_OUT"
grep -Fq 'FastDL HTTP is not serving raw BSP bytes' "$SYNC_OUT" && fail "stale HTTP validation unexpectedly executed" || true

echo "[11/12] Restart server and apply runtime FastDL cvars..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
"$LIVE_CTL" rcon "$SID" "sv_allowdownload 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allowupload 0" || true
"$LIVE_CTL" rcon "$SID" "sv_send_resources 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allow_dlfile 1" || true
"$LIVE_CTL" rcon "$SID" "sv_downloadurl \"$URL\"" || true
"$LIVE_CTL" rcon "$SID" "sv_downloadurl" || true

echo "[12/12] Verify PUBLIC endpoint..."
PUBLIC_HDR="$BACKUP/public.headers"; PUBLIC_BODY="$BACKUP/public.body"
set +e
curl -sS --connect-timeout 5 --max-time 20 -H 'Range: bytes=0-3' -D "$PUBLIC_HDR" -o "$PUBLIC_BODY" "http://$PUBLIC_IP/fastdl/$SID/$REL"
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
    head -n 30 "$PUBLIC_HDR"
    PUB_HEX="$(xxd -l 4 -p "$PUBLIC_BODY" 2>/dev/null || true)"
    echo "public body head: $PUB_HEX"
    if [[ "$PUB_HEX" == "1e000000" ]] && grep -qi '^X-Hyper-FastDL: raw-v13' "$PUBLIC_HDR"; then
        echo "[OK] PUBLIC FastDL returns raw BSP through v13"
    else
        echo "[WARN] LOCAL nginx is correct but PUBLIC request does not reach the same vhost."
        echo "[WARN] Check router/NAT/reverse-proxy TCP/80 forwarding."
    fi
else
    echo "[WARN] Public self-request failed (possible no NAT hairpin). Local nginx test PASSED."
fi

PORT="$(python3 - "$STATE" <<'PY'
from pathlib import Path
import json,sys
try:
    d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')); print(int(d.get('port') or 27015))
except Exception: print(27015)
PY
)"

echo
echo "================================================================"
echo " [SUCCESS] FASTDL HARD FIX v13 COMPLETE"
echo "================================================================"
echo " Game server: $PUBLIC_IP:$PORT"
echo " FastDL:      $URL"
echo " Probe:       $REL"
echo " BSP header:  1e000000 = version 30"
echo " HTML header: 3c21646f = <!do = decimal 1868833084"
echo " Backup:      $BACKUP"
echo " nginx conf:  $NGINX_IP_CONF"
echo
"$LIVE_CTL" fastdl-status "$SID" || true
