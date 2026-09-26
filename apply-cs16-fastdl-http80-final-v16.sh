#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
PUBLIC_IP="${3:-90.189.208.25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE_CTL="/usr/local/sbin/hyper-cs16-ctl"
STATE="/var/lib/hyper-cs16/servers/$SID.json"
RUNTIME="/etc/hyper-cs16/runtime.json"
SERVER_ROOT="/srv/hyper-cs16/servers/$SID"
CSTRIKE="$SERVER_ROOT/cstrike"
FASTDL_ROOT="/srv/hyper-cs16/fastdl"
FASTDL="$FASTDL_ROOT/$SID"
MANAGED_DIR="/etc/nginx/hyper-host-managed"
NGINX_CONF="$MANAGED_DIR/00-cs16-fastdl-ip80.conf"
URL="http://$PUBLIC_IP/fastdl/$SID/"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-v16-$STAMP"
fail(){ echo "[ERROR] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing controller: $CTL"
[[ -f "$STATE" ]] || fail "missing state: $STATE"
[[ -d "$CSTRIKE/maps" ]] || fail "missing maps directory"
mkdir -p "$BACKUP" "$MANAGED_DIR"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
[[ -f "$LIVE_CTL" ]] && cp -a "$LIVE_CTL" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/state.before.json" || true
[[ -f "$RUNTIME" ]] && cp -a "$RUNTIME" "$BACKUP/runtime.before.json" || true
[[ -f "$CSTRIKE/server.cfg" ]] && cp -a "$CSTRIKE/server.cfg" "$BACKUP/server.cfg.before" || true
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$BACKUP/nginx-fastdl.before.conf" || true
PORT="$(python3 - "$STATE" <<'PY'
from pathlib import Path
import json,sys
try:
 d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')); print(int(d.get('port') or 27015))
except Exception: print(27015)
PY
)"
echo "================================================================"
echo " HYPER-HOST CS 1.6 FASTDL HTTP/80 FINAL v16"
echo " Server:       #$SID"
echo " Game:         $PUBLIC_IP:$PORT / UDP"
echo " FastDL:       $URL"
echo " Backup:       $BACKUP"
echo "================================================================"

echo "[1/12] Validate source BSP and inspect source models/WAV..."
python3 - "$CSTRIKE" <<'PY'
from pathlib import Path
import struct,sys
root=Path(sys.argv[1]); maps=sorted((root/'maps').glob('*.bsp')); bad=[]
for p in maps:
 h=p.read_bytes()[:4]; ver=struct.unpack('<I',h)[0] if len(h)==4 else None
 if ver!=30: bad.append((p.name,ver,h.hex()))
print('BSP:',len(maps),'valid:',len(maps)-len(bad),'bad:',len(bad))
for row in bad[:50]: print('BAD BSP:',row)
if bad: raise SystemExit(20)
for rel in ['models/player/oldz_vip_r8/oldz_vip_r8.mdl','models/player/oldz_admin_r8/oldz_admin_r8.mdl']:
 p=root/rel
 print(('MODEL:' if p.is_file() else 'MODEL MISSING:'),rel,('head='+p.read_bytes()[:16].hex() if p.is_file() else ''))
wav_total=wav_bad=0; examples=[]
snd=root/'sound'
if snd.is_dir():
 for p in snd.rglob('*.wav'):
  wav_total+=1; b=p.read_bytes()[:12]
  if len(b)<12 or b[:4]!=b'RIFF' or b[8:12]!=b'WAVE':
   wav_bad+=1
   if len(examples)<20: examples.append((str(p.relative_to(root)),b.hex()))
print('WAV:',wav_total,'invalid source:',wav_bad)
for x in examples: print('SOURCE WAV WARNING:',x)
PY

echo "[2/12] Patch PANEL FastDL core..."
python3 - "$CTL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8',errors='strict')
start=s.find('def _fastdl_url(c:dict)->str:'); end=s.find('\ndef _fastdl_apply_cfg',start)
if start<0 or end<0: raise SystemExit('cannot locate _fastdl_url')
new_url='''def _fastdl_url(c:dict)->str:\n    """Canonical GoldSrc FastDL URL: HTTP/80 on public IPv4."""\n    sid=int(c.get('id') or 0)\n    public=''\n    try:\n        rt=load_runtime(); public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()\n    except Exception:\n        public=str(c.get('public_ip') or '').strip()\n    try:\n        ip=ipaddress.ip_address(public)\n        if ip.version==4 and not ip.is_unspecified and not ip.is_loopback:\n            return f'http://{public}/fastdl/{sid}/'\n    except Exception:\n        pass\n    return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'\n'''
s=s[:start]+new_url+s[end:]
a=s.find('def _fastdl_apply_cfg'); b=s.find('\ndef _fastdl_copy_tree',a)
if a<0 or b<0: raise SystemExit('cannot locate _fastdl_apply_cfg')
sec=s[a:b].replace("'sv_allowupload 1'","'sv_allowupload 0'"); s=s[:a]+sec+s[b:]
a=s.find('def fastdl_sync('); b=s.find('\ndef fastdl_status(',a)
if a<0 or b<0: raise SystemExit('cannot locate fastdl_sync')
sec=s[a:b].replace("'sv_allowupload 1'","'sv_allowupload 0'")
for bad in ['/etc/nginx/conf.d/00-old-zombie-fastdl-http.conf','/etc/nginx/conf.d/00-hyper-cs16-fastdl-ip.conf']:
 if bad in sec: raise SystemExit('old nginx writer still inside fastdl_sync: '+bad)
s=s[:a]+sec+s[b:]
clean='''def fastdl_clean(sid:int):\n    """Delete only the generated mirror. Never touch nginx."""\n    require_root(); c=load_server(sid); dest=FASTDL_ROOT/str(sid); files=0; total=0\n    if dest.exists() or dest.is_symlink():\n        if dest.is_symlink(): dest.unlink()\n        else:\n            for fp in dest.rglob('*'):\n                try:\n                    if fp.is_file(): files+=1; total+=fp.stat().st_size\n                except OSError: pass\n            shutil.rmtree(dest)\n    dest.mkdir(parents=True,exist_ok=True)\n    run(['chown','root:www-data',str(dest)],check=False)\n    try: os.chmod(dest,0o755)\n    except OSError: pass\n    c['fastdl_url']=_fastdl_url(c); c['fastdl_last_sync']=0; c['fastdl_files']=0; c['fastdl_bytes']=0; save_server(c)\n    return {'ok':True,'id':sid,'cleaned':True,'root':str(dest),'removed_files':files,'removed_bytes':total,'url':c['fastdl_url'],'nginx_touched':False}\n\n'''
cs=s.find('def fastdl_clean('); status=s.find('def fastdl_status(')
if status<0: raise SystemExit('cannot locate fastdl_status')
if cs>=0 and cs<status:
 nxt=s.find('\ndef ',cs+5)
 if nxt<0: raise SystemExit('cannot find end fastdl_clean')
 s=s[:cs]+clean+s[nxt+1:]
else: s=s[:status]+clean+s[status:]
if "'fastdl-clean'" not in s:
 old="'fastdl-sync','fastdl-status'"
 if old not in s: raise SystemExit('cannot locate parser fastdl commands')
 s=s.replace(old,"'fastdl-sync','fastdl-clean','fastdl-status'",1)
if "elif args.cmd=='fastdl-clean'" not in s:
 needle="elif args.cmd=='fastdl-sync': result=fastdl_sync(args.id,True)"
 if needle not in s: raise SystemExit('cannot locate fastdl-sync dispatcher')
 s=s.replace(needle,needle+"\n        elif args.cmd=='fastdl-clean': result=fastdl_clean(args.id)",1)
s=s.replace('# HYPER-HOST FASTDL TCP/IP FINAL v15\n','')
marker='# HYPER-HOST FASTDL HTTP80 FINAL v16'
if marker not in s: s=s.replace('#!/usr/bin/env python3\n','#!/usr/bin/env python3\n'+marker+'\n',1)
p.write_text(s,encoding='utf-8'); print('patched:',p)
PY
python3 -m py_compile "$CTL"
install -m 0755 "$CTL" "$LIVE_CTL"
python3 -m py_compile "$LIVE_CTL"

echo "[3/12] Persist public IP + HTTP/80 URL..."
python3 - "$RUNTIME" "$STATE" "$PUBLIC_IP" "$SID" <<'PY'
from pathlib import Path
import json,sys
runtime=Path(sys.argv[1]); state=Path(sys.argv[2]); ip=sys.argv[3]; sid=int(sys.argv[4]); url=f'http://{ip}/fastdl/{sid}/'
for p in (runtime,state):
 if not p.exists(): continue
 d=json.loads(p.read_text(encoding='utf-8')); d['public_ip']=ip
 if p==state: d['fastdl_url']=url
 tmp=p.with_name('.'+p.name+'.v16.tmp'); tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); tmp.replace(p); print('updated:',p)
print('FastDL URL:',url)
PY

echo "[4/12] Remove old TCP/game-port FastDL configs..."
for old in "$MANAGED_DIR/90-cs16-fastdl-$SID.conf" "$MANAGED_DIR/90-cs16-fastdl-managed.conf" "$MANAGED_DIR/99-cs16-fastdl-$SID.conf"; do
 if [[ -e "$old" || -L "$old" ]]; then cp -a "$old" "$BACKUP/$(basename "$old").before" 2>/dev/null || true; rm -f "$old"; echo "removed: $old"; fi
done

echo "[5/12] Clean + rebuild mirror through panel..."
"$LIVE_CTL" fastdl-clean "$SID"
"$LIVE_CTL" fastdl-sync "$SID"

echo "[6/12] Validate mirror byte-for-byte..."
python3 - "$CSTRIKE" "$FASTDL" <<'PY'
from pathlib import Path
import hashlib,struct,sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2])
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()
missing=[]; bad=[]; mismatch=[]; maps=sorted((src/'maps').glob('*.bsp'))
for p in maps:
 q=dst/'maps'/p.name
 if not q.is_file(): missing.append(p.name); continue
 h=q.read_bytes()[:4]; ver=struct.unpack('<I',h)[0] if len(h)==4 else None
 if ver!=30: bad.append((p.name,ver,h.hex()))
 if p.stat().st_size!=q.stat().st_size or sha(p)!=sha(q): mismatch.append(p.name)
print('maps:',len(maps),'missing:',len(missing),'bad:',len(bad),'hash mismatch:',len(mismatch))
for rel in [Path('models/player/oldz_vip_r8/oldz_vip_r8.mdl'),Path('models/player/oldz_admin_r8/oldz_admin_r8.mdl')]:
 a=src/rel; b=dst/rel
 if a.is_file():
  if not b.is_file(): raise SystemExit('mirror missing '+str(rel))
  same=a.stat().st_size==b.stat().st_size and sha(a)==sha(b); print('model',rel,'same=',same,'head=',b.read_bytes()[:12].hex())
  if not same: raise SystemExit('model mismatch '+str(rel))
if missing or bad or mismatch: raise SystemExit(30)
PY

echo "[7/12] Install exact IP FastDL vhost on HTTP/80..."
cat > "$NGINX_CONF" <<NGINX_EOF
# HYPER-HOST FASTDL IP/80 FINAL v16
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    error_log  /var/log/nginx/hyper-cs16-fastdl-error.log warn;
    location ^~ /fastdl/ {
        alias $FASTDL_ROOT/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        sendfile on;
        tcp_nopush on;
        etag on;
        types { }
        default_type application/octet-stream;
        add_header X-Hyper-FastDL "raw-v16" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "public, max-age=86400" always;
        limit_except GET HEAD { deny all; }
    }
    location / { return 404; }
}
NGINX_EOF
nginx -t
systemctl reload nginx
nginx -T > "$BACKUP/nginx-T.after.txt" 2>&1
grep -Fq 'HYPER-HOST FASTDL IP/80 FINAL v16' "$BACKUP/nginx-T.after.txt" || fail "nginx does not load $NGINX_CONF"

echo "[8/12] Verify BSP over LOCAL exact-IP HTTP route..."
PROBE_REL="maps/zm_2day.bsp"
if [[ ! -f "$FASTDL/$PROBE_REL" ]]; then PROBE_REL="maps/$(find "$FASTDL/maps" -maxdepth 1 -type f -name '*.bsp' -printf '%f\n' | head -1)"; fi
[[ -f "$FASTDL/$PROBE_REL" ]] || fail "no BSP probe"
HDR="$BACKUP/local-bsp.headers"; BODY="$BACKUP/local-bsp.body"
curl -fsS --resolve "$PUBLIC_IP:80:127.0.0.1" -H 'Range: bytes=0-3' -D "$HDR" -o "$BODY" "http://$PUBLIC_IP/fastdl/$SID/$PROBE_REL"
head -n 30 "$HDR"
HEX="$(xxd -l 4 -p "$BODY")"; echo "BSP HTTP head: $HEX"
grep -qi '^X-Hyper-FastDL: raw-v16' "$HDR" || fail "request did not hit v16 FastDL vhost"
[[ "$HEX" == "1e000000" ]] || fail "HTTP returned non-BSP: $HEX (3c21646f = HTML <!do)"

echo "[9/12] Verify player models over HTTP match source..."
python3 - "$CSTRIKE" "$PUBLIC_IP" "$SID" <<'PY'
from pathlib import Path
import subprocess,sys
root=Path(sys.argv[1]); ip=sys.argv[2]; sid=sys.argv[3]
for rel in ['models/player/oldz_vip_r8/oldz_vip_r8.mdl','models/player/oldz_admin_r8/oldz_admin_r8.mdl']:
 src=root/rel
 if not src.is_file(): print('skip missing model:',rel); continue
 cp=subprocess.run(['curl','-fsS','--resolve',f'{ip}:80:127.0.0.1',f'http://{ip}/fastdl/{sid}/{rel}'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if cp.returncode: raise SystemExit('HTTP model failed '+rel+': '+cp.stderr.decode(errors='replace'))
 a=src.read_bytes(); b=cp.stdout; print(rel,'source=',len(a),'http=',len(b),'head=',b[:12].hex(),'equal=',a==b)
 if a!=b: raise SystemExit('HTTP model differs: '+rel)
PY

echo "[10/12] Verify browser index + one WAV..."
INDEX="$BACKUP/index.html"
curl -fsS --resolve "$PUBLIC_IP:80:127.0.0.1" "http://$PUBLIC_IP/fastdl/$SID/" -o "$INDEX"
echo "index bytes: $(wc -c < "$INDEX")"
WAV="$(find "$CSTRIKE/sound" -type f -iname '*.wav' -print -quit 2>/dev/null || true)"
if [[ -n "$WAV" ]]; then
 REL="${WAV#"$CSTRIKE/"}"; WAV_HEAD="$BACKUP/wav.head"
 curl -fsS --resolve "$PUBLIC_IP:80:127.0.0.1" -H 'Range: bytes=0-11' "http://$PUBLIC_IP/fastdl/$SID/$REL" -o "$WAV_HEAD"
 echo "WAV: $REL"; echo "source: $(xxd -l 12 -p "$WAV")"; echo "HTTP:   $(xxd -l 12 -p "$WAV_HEAD")"
fi

echo "[11/12] Restart server with canonical URL..."
"$LIVE_CTL" fastdl-sync "$SID" >/tmp/hyper-fastdl-v16-sync.json || true
cat /tmp/hyper-fastdl-v16-sync.json
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
"$LIVE_CTL" rcon "$SID" "sv_allowdownload 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allowupload 0" || true
"$LIVE_CTL" rcon "$SID" "sv_send_resources 1" || true
"$LIVE_CTL" rcon "$SID" "sv_allow_dlfile 1" || true
"$LIVE_CTL" rcon "$SID" "sv_downloadurl \"$URL\"" || true

echo "[12/12] Final status + public self-test..."
"$LIVE_CTL" fastdl-status "$SID" || true
grep -E '^[[:space:]]*sv_(downloadurl|allowdownload|allowupload|send_resources|allow_dlfile)' "$CSTRIKE/server.cfg" || true
PUB_BODY="$BACKUP/public.body"
set +e
curl -sS --connect-timeout 5 --max-time 15 -H 'Range: bytes=0-3' -o "$PUB_BODY" "http://$PUBLIC_IP/fastdl/$SID/$PROBE_REL"
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
 PUB_HEX="$(xxd -l 4 -p "$PUB_BODY" 2>/dev/null || true)"; echo "public self-test head: $PUB_HEX"
 [[ "$PUB_HEX" == "1e000000" ]] && echo "public self-test: OK" || echo "[WARN] public loopback differs; test from another PC/network"
else
 echo "[WARN] public self-test from server failed (possible NAT hairpin); local exact-IP test passed"
fi

echo "================================================================"
echo " [SUCCESS] FASTDL HTTP/80 FINAL v16"
echo " Game server: $PUBLIC_IP:$PORT"
echo " FastDL:      $URL"
echo " BSP HTTP:    $HEX"
echo " Clean:       $LIVE_CTL fastdl-clean $SID"
echo " Rebuild:     $LIVE_CTL fastdl-sync $SID"
echo " Backup:      $BACKUP"
echo "================================================================"
