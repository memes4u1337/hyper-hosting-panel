#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
PUBLIC_IP="${3:-90.189.208.25}"

SRC="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STATE="/var/lib/hyper-cs16/servers/${SID}.json"
RUNTIME="/etc/hyper-cs16/runtime.json"
CSTRIKE="/srv/hyper-cs16/servers/${SID}/cstrike"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-panel-fastdl-fix-v14-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -d "$ROOT/.git" ]] || fail "not a git repo: $ROOT"
[[ -d "$CSTRIKE" ]] || fail "missing cstrike: $CSTRIKE"

mkdir -p "$BACKUP"
[[ -f "$SRC" ]] && cp -a "$SRC" "$BACKUP/hyper-cs16-ctl.repo.before" || true
[[ -f "$LIVE" ]] && cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" || true
[[ -f "$STATE" ]] && cp -a "$STATE" "$BACKUP/state.before.json" || true
[[ -f "$RUNTIME" ]] && cp -a "$RUNTIME" "$BACKUP/runtime.before.json" || true

echo "================================================================"
echo " HYPER-HOST CS 1.6 PANEL FASTDL FIX v14"
echo " Server:     #$SID"
echo " Public IP:  $PUBLIC_IP"
echo " FastDL:     http://$PUBLIC_IP/fastdl/$SID/"
echo " Backup:     $BACKUP"
echo "================================================================"

echo "[1/9] Restore controller from fetched GitHub main..."
TMP="$BACKUP/hyper-cs16-ctl.clean"
git -C "$ROOT" show FETCH_HEAD:cs16-panel/bin/hyper-cs16-ctl > "$TMP" \
  || git -C "$ROOT" show origin/main:cs16-panel/bin/hyper-cs16-ctl > "$TMP" \
  || fail "cannot read clean controller from FETCH_HEAD/origin/main"

grep -q '^def fastdl_sync' "$TMP" || fail "clean controller does not contain fastdl_sync"
cp -a "$TMP" "$SRC"

echo "[2/9] Patch canonical IP URL, add fastdl_clean, and keep nginx untouched..."
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

start=s.find("def _fastdl_url(c:dict)->str:")
end=s.find("\ndef _fastdl_apply_cfg", start)
if start < 0 or end < 0:
    raise SystemExit("cannot locate _fastdl_url")

url_func = """def _fastdl_url(c:dict)->str:
    \"\"\"Canonical per-server FastDL URL. Prefer node public IPv4.\"\"\"
    sid=int(c.get('id') or 0)
    public=''
    try:
        rt=load_runtime()
        public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()
    except Exception:
        public=str(c.get('public_ip') or '').strip()
    try:
        ip=ipaddress.ip_address(public)
        if ip.version==4 and not ip.is_unspecified and not ip.is_loopback:
            return f'http://{public}/fastdl/{sid}/'
    except Exception:
        pass
    return f'https://{FASTDL_DOMAIN}/fastdl/{sid}/'
"""
s=s[:start]+url_func+s[end:]

s=s.replace("'sv_allowupload 1',", "'sv_allowupload 0',")
s=s.replace("['sv_allowdownload 1','sv_allowupload 1','sv_send_resources 1'",
            "['sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1'")

insert_at=s.find("\ndef fastdl_sync(")
if insert_at < 0:
    raise SystemExit("cannot locate fastdl_sync")

repair_func = r'''
def _fastdl_repair_map_names(c:dict)->dict:
    """Repair literal backslashes accidentally embedded in GoldSrc map names."""
    root=Path(c['path'])
    maps=root/'cstrike/maps'
    renamed=[]
    if maps.is_dir():
        for fp in sorted(maps.glob('*.bsp')):
            if '\\' not in fp.name:
                continue
            clean_name=fp.name.replace('\\','')
            if not clean_name or clean_name==fp.name:
                continue
            dst=fp.with_name(clean_name)
            if dst.exists():
                try:
                    if fp.stat().st_size==dst.stat().st_size:
                        fp.unlink()
                        renamed.append({'from':fp.name,'to':dst.name,'mode':'duplicate-removed'})
                        continue
                except OSError:
                    pass
                raise RuntimeError(f'Cannot repair malformed map filename {fp.name}: {dst.name} already exists')
            fp.rename(dst)
            renamed.append({'from':fp.name,'to':dst.name,'mode':'renamed'})

    raw=str(c.get('start_map') or '').strip()
    clean=raw.replace('\\','').replace('/','')
    if clean.lower().endswith('.bsp'):
        clean=clean[:-4]
    if clean and SAFE_MAP.fullmatch(clean) and clean!=raw:
        c['start_map']=clean
        save_server(c)
        db_update_start_map(int(c['id']),clean)

    for rel in ('cstrike/mapcycle.txt','cstrike/addons/amxmodx/configs/maps.ini'):
        fp=root/rel
        if not fp.is_file():
            continue
        try:
            text=fp.read_text(encoding='utf-8',errors='ignore')
            new=[]
            changed=False
            for line in text.splitlines():
                stripped=line.strip()
                if not stripped or stripped.startswith((';','#','//')):
                    new.append(line)
                    continue
                m=re.match(r'^(\s*)([A-Za-z0-9_\\\-.]+)(.*)$',line)
                if not m:
                    new.append(line)
                    continue
                token=m.group(2)
                fixed=token.replace('\\','')
                if fixed.lower().endswith('.bsp'):
                    fixed=fixed[:-4]
                if SAFE_MAP.fullmatch(fixed) and fixed!=token:
                    line=m.group(1)+fixed+m.group(3)
                    changed=True
                new.append(line)
            if changed:
                fp.write_text('\n'.join(new)+'\n',encoding='utf-8')
        except Exception:
            pass

    return {'renamed':renamed,'start_map':str(c.get('start_map') or '')}
'''
s=s[:insert_at]+repair_func+s[insert_at:]

needle="def fastdl_sync(sid:int, configure:bool=True):\n    \"\"\"Mirror only client-downloadable game assets to the web FastDL tree.\"\"\"\n    require_root(); c=load_server(sid); root=Path(c['path']); cstrike=root/'cstrike'"
repl="def fastdl_sync(sid:int, configure:bool=True):\n    \"\"\"Mirror only client-downloadable game assets to the web FastDL tree.\"\"\"\n    require_root(); c=load_server(sid); repair=_fastdl_repair_map_names(c); c=load_server(sid); root=Path(c['path']); cstrike=root/'cstrike'"
if needle not in s:
    raise SystemExit("unexpected fastdl_sync signature/body")
s=s.replace(needle,repl,1)

old="return {'ok':True,'id':sid,'url':c['fastdl_url'],'root':str(dest),'files':files,'bytes':total,'dirs':copied_dirs,'config':cfg_result,'runtime_applied':runtime_applied,'runtime_errors':runtime_errors[:5]}"
new="return {'ok':True,'id':sid,'url':c['fastdl_url'],'root':str(dest),'files':files,'bytes':total,'dirs':copied_dirs,'config':cfg_result,'repair':repair,'runtime_applied':runtime_applied,'runtime_errors':runtime_errors[:5]}"
if old not in s:
    raise SystemExit("cannot locate fastdl_sync return")
s=s.replace(old,new,1)

status_pos=s.find("\ndef fastdl_status(")
if status_pos < 0:
    raise SystemExit("cannot locate fastdl_status")
clean_func=r'''
def fastdl_clean(sid:int):
    """Clear one FastDL mirror without touching nginx configuration."""
    require_root()
    c=load_server(sid)
    dest=FASTDL_ROOT/str(sid)
    removed_files=0
    removed_bytes=0
    if dest.is_dir():
        for fp in dest.rglob('*'):
            try:
                if fp.is_file():
                    removed_files+=1
                    removed_bytes+=fp.stat().st_size
            except OSError:
                pass
        shutil.rmtree(dest)
    c['fastdl_files']=0
    c['fastdl_bytes']=0
    c['fastdl_last_sync']=0
    c['fastdl_url']=_fastdl_url(c)
    save_server(c)
    return {
        'ok':True,'id':sid,'cleaned':True,'root':str(dest),
        'removed_files':removed_files,'removed_bytes':removed_bytes,
        'url':c['fastdl_url'],'nginx_touched':False
    }
'''
s=s[:status_pos]+clean_func+s[status_pos:]

parser_old="for a in ['start','stop','restart','status','players','maps','plugins','update','reinstall','ftp-reset','ftp-repair','ftp-test','network','delete','repair-runtime','build-repair-current','mods-status','nat-upnp','network-fix','repair-content','sql-status','fastdl-sync','fastdl-status']:"
parser_new="for a in ['start','stop','restart','status','players','maps','plugins','update','reinstall','ftp-reset','ftp-repair','ftp-test','network','delete','repair-runtime','build-repair-current','mods-status','nat-upnp','network-fix','repair-content','sql-status','fastdl-sync','fastdl-clean','fastdl-status']:"
if parser_old not in s:
    raise SystemExit("cannot locate CLI parser command list")
s=s.replace(parser_old,parser_new,1)

handler_old="elif args.cmd=='fastdl-sync': result=fastdl_sync(args.id,True)\n        elif args.cmd=='fastdl-status': result=fastdl_status(args.id)"
handler_new="elif args.cmd=='fastdl-sync': result=fastdl_sync(args.id,True)\n        elif args.cmd=='fastdl-clean': result=fastdl_clean(args.id)\n        elif args.cmd=='fastdl-status': result=fastdl_status(args.id)"
if handler_old not in s:
    raise SystemExit("cannot locate CLI fastdl handlers")
s=s.replace(handler_old,handler_new,1)

marker="# HYPER-HOST PANEL FASTDL FIX v14"
if marker not in s:
    s=s.replace("#!/usr/bin/env python3\n","#!/usr/bin/env python3\n"+marker+"\n",1)

if "00-old-zombie-fastdl-http.conf" in s:
    raise SystemExit("stale nginx writer still present")

p.write_text(s,encoding='utf-8')
print("patched:",p)
PY

python3 -m py_compile "$SRC"
install -m 0755 "$SRC" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[3/9] Persist public IP in runtime/state..."
python3 - "$RUNTIME" "$STATE" "$PUBLIC_IP" "$SID" <<'PY'
from pathlib import Path
import json,sys
runtime=Path(sys.argv[1]); state=Path(sys.argv[2]); ip=sys.argv[3]; sid=int(sys.argv[4])
for p in (runtime,state):
    if not p.is_file():
        continue
    d=json.loads(p.read_text(encoding='utf-8'))
    d['public_ip']=ip
    if p==state:
        d['fastdl_url']=f'http://{ip}/fastdl/{sid}/'
        raw=str(d.get('start_map') or '').strip()
        clean=raw.replace('\\','').replace('/','')
        if clean.lower().endswith('.bsp'):
            clean=clean[:-4]
        if clean:
            d['start_map']=clean
    tmp=p.with_name('.'+p.name+'.v14.tmp')
    tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    tmp.replace(p)
    print("updated:",p)
PY

echo "[4/9] Repair malformed map filenames/config entries..."
python3 - "$CSTRIKE" <<'PY'
from pathlib import Path
import re,sys
cs=Path(sys.argv[1]); maps=cs/'maps'; renamed=[]
if maps.is_dir():
    for fp in sorted(maps.glob('*.bsp')):
        if '\\' not in fp.name:
            continue
        clean=fp.name.replace('\\','')
        dst=fp.with_name(clean)
        if dst.exists():
            if fp.stat().st_size==dst.stat().st_size:
                fp.unlink(); renamed.append((fp.name,dst.name,'duplicate removed'))
            else:
                raise SystemExit(f"collision: {fp.name} -> {dst.name}")
        else:
            fp.rename(dst); renamed.append((fp.name,dst.name,'renamed'))
print("renamed maps:",len(renamed))
for x in renamed:
    print(" ",x)

for fp in (cs/'mapcycle.txt', cs/'addons/amxmodx/configs/maps.ini'):
    if not fp.is_file():
        continue
    text=fp.read_text(encoding='utf-8',errors='ignore')
    out=[]; changed=0
    for line in text.splitlines():
        st=line.strip()
        if not st or st.startswith((';','#','//')):
            out.append(line); continue
        m=re.match(r'^(\s*)([A-Za-z0-9_\\\-.]+)(.*)$',line)
        if not m:
            out.append(line); continue
        token=m.group(2); fixed=token.replace('\\','')
        if fixed.lower().endswith('.bsp'):
            fixed=fixed[:-4]
        if fixed!=token:
            line=m.group(1)+fixed+m.group(3); changed+=1
        out.append(line)
    if changed:
        fp.write_text('\n'.join(out)+'\n',encoding='utf-8')
    print(fp, "fixed lines:",changed)
PY

echo "[5/9] Confirm broken nginx writer is gone..."
if grep -RFn "00-old-zombie-fastdl-http.conf" "$SRC" "$LIVE" >/dev/null 2>&1; then
    fail "stale read-only nginx writer still present"
fi
echo "OK: controller does not touch /etc/nginx/conf.d/00-old-zombie-fastdl-http.conf"

echo "[6/9] Test panel FastDL CLEAN..."
"$LIVE" fastdl-clean "$SID"

echo "[7/9] Rebuild FastDL from panel controller..."
"$LIVE" fastdl-sync "$SID"

echo "[8/9] Verify URL + map filenames..."
STATUS="$("$LIVE" fastdl-status "$SID")"
echo "$STATUS"
python3 - "$STATUS" "$PUBLIC_IP" "$SID" "$CSTRIKE" <<'PY'
import json,sys
from pathlib import Path
st=json.loads(sys.argv[1]); ip=sys.argv[2]; sid=sys.argv[3]; cs=Path(sys.argv[4])
expect=f"http://{ip}/fastdl/{sid}/"
url=str(st.get('url') or '')
cfg=str(st.get('configured_url') or '')
print("expected:",expect)
print("reported:",url)
print("configured:",cfg)
if url.rstrip('/') != expect.rstrip('/'):
    raise SystemExit("wrong FastDL URL")
if cfg.rstrip('/') != expect.rstrip('/'):
    raise SystemExit("wrong sv_downloadurl")
bad=[p.name for p in (cs/'maps').glob('*.bsp') if '\\' in p.name]
print("malformed map filenames:",bad)
if bad:
    raise SystemExit("malformed map filenames remain")
PY

echo "[9/9] Restart server to clear malformed live map/resource state..."
systemctl restart "hyper-cs16@${SID}.service"
sleep 3
"$LIVE" status "$SID" || true

echo
echo "================================================================"
echo " [SUCCESS] PANEL FASTDL FIX v14"
echo "================================================================"
echo " FastDL URL: http://$PUBLIC_IP/fastdl/$SID/"
echo " Clean command:   $LIVE fastdl-clean $SID"
echo " Rebuild command: $LIVE fastdl-sync $SID"
echo " nginx configs were NOT modified."
echo " Backup: $BACKUP"
