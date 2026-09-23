#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root/sudo' >&2; exit 1; }

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL_SRC="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
UI_SRC="$ROOT/cs16-panel/public/index.php"
CTL_LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-panel-v51-backup-${STAMP}"

[[ -f "$CTL_SRC" ]] || { echo "[ERROR] Missing $CTL_SRC" >&2; exit 2; }
[[ -f "$UI_SRC" ]] || { echo "[ERROR] Missing $UI_SRC" >&2; exit 2; }

mkdir -p "$BACKUP"
cp -a "$CTL_SRC" "$BACKUP/hyper-cs16-ctl"
cp -a "$UI_SRC" "$BACKUP/index.php"
[[ -f "$CTL_LIVE" ]] && cp -a "$CTL_LIVE" "$BACKUP/hyper-cs16-ctl.live" || true

echo '========================================================='
echo ' HYPER-HOST CS 1.6 FASTDL PANEL v5.1'
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo '========================================================='

echo '[1/8] Patching FastDL backend...'

python3 - "$CTL_SRC" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

old="FASTDL_DIRS=('maps','models','sound','sprites','gfx','resource','overviews','events','media')"
rules="""FASTDL_RULES={
    'maps':{'.bsp','.res','.txt','.nav'},
    'models':{'.mdl'},
    'sound':{'.wav','.mp3'},
    'sprites':{'.spr','.txt'},
    'gfx':{'.tga','.bmp','.pcx'},
    'resource':{'.res','.txt','.tga','.bmp','.ttf','.otf'},
    'overviews':{'.txt','.bmp','.tga','.spr'},
    'events':{'.sc'},
    'media':{'.mp3','.wav'},
}
FASTDL_ROOT_EXTS={'.wad'}
FASTDL_COMPRESS_EXTS={'.bsp','.wad','.mdl','.wav','.mp3','.spr','.tga','.bmp','.pcx','.ttf','.otf','.sc','.txt','.res'}
FASTDL_COMPRESS_MIN_BYTES=1024"""
if old in s:
    s=s.replace(old,rules,1)
elif 'FASTDL_RULES={' not in s:
    raise SystemExit('[PATCH ERROR] FastDL constants anchor not found')

start=s.find('def _fastdl_url(c:dict)->str:')
end=s.find('def _extract_external_fastdl_url(', start)
if start < 0 or end < 0 or end <= start:
    raise SystemExit('[PATCH ERROR] FastDL function block boundaries not found')

block="""def _fastdl_url(c:dict)->str:
    sid=int(c.get('id') or 0)
    public=''
    try:
        rt=load_runtime()
        public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()
    except Exception:
        public=str(c.get('public_ip') or '').strip()
    try:
        ip=ipaddress.ip_address(public)
        if ip.version==4 and not ip.is_unspecified:
            return f'http://{public}/fastdl/{sid}/'
    except Exception:
        pass
    return f'http://{FASTDL_DOMAIN}/fastdl/{sid}/'


def _fastdl_apply_cfg(c:dict, root:Path|None=None)->dict:
    root=Path(root or c['path'])
    cfg=root/'cstrike/server.cfg'
    cfg.parent.mkdir(parents=True,exist_ok=True)
    text=cfg.read_text(encoding='utf-8',errors='ignore') if cfg.exists() else ''
    text=text.replace('\\r\\n','\\n').replace('\\r','\\n')
    begin='// HYPER-HOST FASTDL BEGIN'
    end='// HYPER-HOST FASTDL END'
    text=re.sub(r'(?ims)^\\s*// HYPER-HOST FASTDL BEGIN\\s*$.*?^\\s*// HYPER-HOST FASTDL END\\s*$\\n?', '', text)
    managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
    kept=[]
    replaced=[]
    for line in text.splitlines():
        m=re.match(r'^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s+',line)
        if m and m.group(1).lower() in managed:
            replaced.append(line.strip())
            continue
        kept.append(line)
    url=_fastdl_url(c)
    fastdl=[
        begin,
        '// Managed automatically by HYPER-HOST FASTDL PANEL v5.1.',
        'sv_allowdownload 1',
        'sv_allowupload 0',
        'sv_send_resources 1',
        'sv_allow_dlfile 0',
        f'sv_downloadurl \"{url}\"',
        end,
    ]
    cfg.write_text('\\n'.join(kept).rstrip()+'\\n\\n'+'\\n'.join(fastdl)+'\\n',encoding='utf-8')
    return {'ok':True,'url':url,'config':str(cfg),'replaced':replaced}


def _fastdl_bz2(src:Path)->dict:
    if src.suffix.lower() not in FASTDL_COMPRESS_EXTS:
        return {'compressed':False,'saved':0}
    try:
        size=src.stat().st_size
    except OSError:
        return {'compressed':False,'saved':0}
    if size < FASTDL_COMPRESS_MIN_BYTES or not shutil.which('bzip2'):
        return {'compressed':False,'saved':0}
    bz=Path(str(src)+'.bz2')
    try:
        if bz.is_file() and bz.stat().st_size>0 and bz.stat().st_mtime >= src.stat().st_mtime:
            return {'compressed':True,'saved':max(0,size-bz.stat().st_size)}
    except OSError:
        pass
    tmp=bz.with_name('.'+bz.name+'.tmp-'+secrets.token_hex(4))
    try:
        with open(tmp,'wb') as fh:
            cp=subprocess.run(['bzip2','-9','-c',str(src)],stdout=fh,stderr=subprocess.PIPE,check=False,timeout=300)
        if cp.returncode!=0 or not tmp.is_file() or tmp.stat().st_size<=0:
            try: tmp.unlink()
            except OSError: pass
            return {'compressed':False,'saved':0}
        if tmp.stat().st_size >= size:
            try: tmp.unlink()
            except OSError: pass
            try:
                if bz.exists(): bz.unlink()
            except OSError: pass
            return {'compressed':False,'saved':0}
        os.replace(tmp,bz)
        return {'compressed':True,'saved':size-bz.stat().st_size}
    except Exception:
        try: tmp.unlink()
        except OSError: pass
        return {'compressed':False,'saved':0}


def _fastdl_copy_tree(src:Path,dst:Path,allowed_exts:set[str])->dict:
    if not src.is_dir():
        if dst.exists(): shutil.rmtree(dst,ignore_errors=True)
        return {'assets':0,'compressed':0,'saved':0,'copied':0}
    dst.mkdir(parents=True,exist_ok=True)
    expected=set()
    assets=compressed=saved=copied=0
    for fp in src.rglob('*'):
        try:
            if not fp.is_file() or fp.is_symlink(): continue
        except OSError:
            continue
        if fp.suffix.lower() not in allowed_exts: continue
        rel=fp.relative_to(src)
        expected.add(rel.as_posix())
        target=dst/rel
        target.parent.mkdir(parents=True,exist_ok=True)
        needs_copy=True
        try:
            a=fp.stat(); b=target.stat()
            needs_copy=(a.st_size!=b.st_size or int(a.st_mtime)!=int(b.st_mtime))
        except OSError:
            pass
        if needs_copy:
            shutil.copy2(fp,target); copied+=1
        assets+=1
        cr=_fastdl_bz2(target)
        if cr.get('compressed'):
            compressed+=1; saved+=int(cr.get('saved') or 0)
    for old in sorted(dst.rglob('*'),key=lambda x:len(x.parts),reverse=True):
        try:
            if old.is_file():
                rel=old.relative_to(dst).as_posix()
                raw=rel[:-4] if rel.lower().endswith('.bz2') else rel
                if raw not in expected: old.unlink()
            elif old.is_dir() and not any(old.iterdir()):
                old.rmdir()
        except OSError:
            pass
    return {'assets':assets,'compressed':compressed,'saved':saved,'copied':copied}


def _fastdl_root_files(cstrike:Path,dest:Path)->dict:
    expected=set(); assets=compressed=saved=copied=0
    for fp in cstrike.iterdir():
        try:
            if not fp.is_file() or fp.is_symlink(): continue
        except OSError:
            continue
        if fp.suffix.lower() not in FASTDL_ROOT_EXTS: continue
        expected.add(fp.name)
        target=dest/fp.name
        needs_copy=True
        try:
            a=fp.stat(); b=target.stat()
            needs_copy=(a.st_size!=b.st_size or int(a.st_mtime)!=int(b.st_mtime))
        except OSError:
            pass
        if needs_copy:
            shutil.copy2(fp,target); copied+=1
        assets+=1
        cr=_fastdl_bz2(target)
        if cr.get('compressed'):
            compressed+=1; saved+=int(cr.get('saved') or 0)
    for old in list(dest.iterdir()):
        try:
            if not old.is_file(): continue
            raw=old.name[:-4] if old.name.lower().endswith('.bz2') else old.name
            if Path(raw).suffix.lower() in FASTDL_ROOT_EXTS and raw not in expected:
                old.unlink()
        except OSError:
            pass
    return {'assets':assets,'compressed':compressed,'saved':saved,'copied':copied}


def fastdl_clean(sid:int):
    require_root(); c=load_server(sid); dest=FASTDL_ROOT/str(sid)
    if dest.exists(): shutil.rmtree(dest)
    c['fastdl_last_sync']=0; c['fastdl_files']=0; c['fastdl_bytes']=0
    c['fastdl_asset_files']=0; c['fastdl_compressed_files']=0
    save_server(c)
    return {'ok':True,'id':sid,'root':str(dest),'deleted':True,'game_files_untouched':True}


def fastdl_sync(sid:int, configure:bool=True):
    require_root(); c=load_server(sid); root=Path(c['path']); cstrike=root/'cstrike'
    if not cstrike.is_dir(): raise RuntimeError(f'cstrike directory is missing: {cstrike}')
    FASTDL_ROOT.mkdir(parents=True,exist_ok=True)
    dest=FASTDL_ROOT/str(sid); dest.mkdir(parents=True,exist_ok=True)
    allowed_dirs=set(FASTDL_RULES.keys())
    for old in list(dest.iterdir()):
        try:
            if old.is_dir() and old.name not in allowed_dirs:
                shutil.rmtree(old,ignore_errors=True)
            elif old.is_file():
                raw=old.name[:-4] if old.name.lower().endswith('.bz2') else old.name
                if Path(raw).suffix.lower() not in FASTDL_ROOT_EXTS: old.unlink()
        except OSError:
            pass
    asset_files=compressed_files=saved_bytes=copied_files=0
    dirs=[]
    for name,exts in FASTDL_RULES.items():
        src=cstrike/name; dst=dest/name
        st=_fastdl_copy_tree(src,dst,exts)
        if src.is_dir(): dirs.append(name)
        asset_files+=int(st.get('assets') or 0)
        compressed_files+=int(st.get('compressed') or 0)
        saved_bytes+=int(st.get('saved') or 0)
        copied_files+=int(st.get('copied') or 0)
    st=_fastdl_root_files(cstrike,dest)
    asset_files+=int(st.get('assets') or 0)
    compressed_files+=int(st.get('compressed') or 0)
    saved_bytes+=int(st.get('saved') or 0)
    copied_files+=int(st.get('copied') or 0)
    cfg_result=_fastdl_apply_cfg(c,root) if configure else {'url':_fastdl_url(c)}
    run(['chown','-R','root:www-data',str(dest)],check=False)
    run(['find',str(dest),'-type','d','-exec','chmod','0755','{}','+'],check=False)
    run(['find',str(dest),'-type','f','-exec','chmod','0644','{}','+'],check=False)
    files=total=0
    for fp in dest.rglob('*'):
        try:
            if fp.is_file(): files+=1; total+=fp.stat().st_size
        except OSError: pass
    c['fastdl_url']=cfg_result.get('url') or _fastdl_url(c)
    c['fastdl_last_sync']=int(time.time()); c['fastdl_files']=files; c['fastdl_bytes']=total
    c['fastdl_asset_files']=asset_files; c['fastdl_compressed_files']=compressed_files; c['fastdl_saved_bytes']=saved_bytes
    save_server(c)
    runtime_applied=False; runtime_errors=[]
    if service_status(sid)=='active' and udp_listening(int(c.get('port') or 0)):
        for cmd in ['sv_allowdownload 1','sv_allowupload 0','sv_send_resources 1','sv_allow_dlfile 0',f'sv_downloadurl \"{c["fastdl_url"]}\"']:
            try: query_rcon('127.0.0.1',int(c['port']),str(c.get('rcon_password','')),cmd,2.0)
            except Exception as exc: runtime_errors.append(str(exc))
        runtime_applied=not runtime_errors
    return {'ok':True,'id':sid,'url':c['fastdl_url'],'root':str(dest),'files':files,'bytes':total,
            'asset_files':asset_files,'compressed_files':compressed_files,'saved_bytes':saved_bytes,'copied_files':copied_files,
            'dirs':dirs,'only_client_assets':True,'config':cfg_result,'runtime_applied':runtime_applied,'runtime_errors':runtime_errors[:5]}


def fastdl_status(sid:int):
    c=load_server(sid); dest=FASTDL_ROOT/str(sid); cfg=Path(c['path'])/'cstrike/server.cfg'; url=_fastdl_url(c)
    files=total=assets=compressed=0
    if dest.is_dir():
        for fp in dest.rglob('*'):
            try:
                if fp.is_file():
                    files+=1; total+=fp.stat().st_size
                    if fp.name.lower().endswith('.bz2'): compressed+=1
                    else: assets+=1
            except OSError: pass
    current=''
    if cfg.is_file():
        try:
            vals=re.findall(r'(?im)^\\s*sv_downloadurl\\s+\"?([^\"\\r\\n]+)',cfg.read_text(encoding='utf-8',errors='ignore'))
            if vals: current=vals[-1].strip()
        except Exception: pass
    return {'ok':True,'id':sid,'url':url,'configured_url':current,'configured':current.rstrip('/')==url.rstrip('/'),
            'root':str(dest),'exists':dest.is_dir(),'files':files,'bytes':total,'asset_files':assets,
            'compressed_files':compressed,'last_sync':int(c.get('fastdl_last_sync') or 0),'only_client_assets':True}


"""

s=s[:start]+block+s[end:]

old="'repair-content','sql-status','fastdl-sync','fastdl-status']:"
new="'repair-content','sql-status','fastdl-sync','fastdl-status','fastdl-clean']:"
if old in s:
    s=s.replace(old,new,1)
elif "'fastdl-clean'" not in s:
    raise SystemExit('[PATCH ERROR] CLI parser anchor not found')

anchor="elif args.cmd=='fastdl-status': result=fastdl_status(args.id)"
if "elif args.cmd=='fastdl-clean':" not in s:
    if anchor not in s: raise SystemExit('[PATCH ERROR] CLI dispatch anchor not found')
    s=s.replace(anchor,anchor+"\n        elif args.cmd=='fastdl-clean': result=fastdl_clean(args.id)",1)

p.write_text(s,encoding='utf-8')
print('[OK] backend source patched')
PY

python3 -m py_compile "$CTL_SRC"

echo '[2/8] Patching panel UI...'
python3 - "$UI_SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "if($action==='fastdl_clean')" not in s:
    old="""        if($action==='fastdl_sync'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);$r=ctl(['fastdl-sync',$id],900);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось синхронизировать FastDL'));audit('fastdl_sync',(string)($r['url']??''),$id);flash('FastDL обновлён: '.(string)($r['files']??0).' файлов · '.(string)($r['url']??''));redirect('/?page=server&id='.$id.'#ftp');
        }
"""
    new="""        if($action==='fastdl_sync'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);$r=ctl(['fastdl-sync',$id],900);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось синхронизировать FastDL'));audit('fastdl_sync',(string)($r['url']??''),$id);flash('FastDL: '.(string)($r['asset_files']??0).' ресурсов · '.(string)($r['compressed_files']??0).' сжатых копий · '.(string)($r['url']??''));redirect('/?page=server&id='.$id.'#ftp');
        }
        if($action==='fastdl_clean'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);$r=ctl(['fastdl-clean',$id],120);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось очистить FastDL'));audit('fastdl_clean',(string)($r['root']??''),$id);flash('FastDL-кэш очищен. Файлы игрового сервера не удалялись.');redirect('/?page=server&id='.$id.'#ftp');
        }
"""
    if old not in s: raise SystemExit('[PATCH ERROR] fastdl_sync UI action anchor not found')
    s=s.replace(old,new,1)

desc='Панель автоматически обновляет FastDL после установки сборки, карты, рестарта и периодически после FTP-изменений.'
if desc in s:
    s=s.replace(desc,'FastDL берёт только клиентские ресурсы сервера: карты, модели, звуки, спрайты, WAD и связанные resource/gfx/overview/event файлы. AMXX, addons, configs, DLL/SO и серверные файлы сюда не копируются.',1)

old='<form method="post" class="mt-2"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_sync"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-soft"><i class="fa-solid fa-arrows-rotate me-2"></i>Обновить FastDL сейчас</button></form>'
new='<div class="d-flex flex-wrap gap-2 mt-2"><form method="post"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_sync"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-primary"><i class="fa-solid fa-bolt me-2"></i>Пересобрать FastDL</button></form><form method="post" onsubmit="return confirm(\'Очистить только FastDL-кэш? Файлы игрового сервера останутся на месте.\')"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_clean"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-soft"><i class="fa-solid fa-trash-can me-2"></i>Очистить FastDL</button></form></div>'
if 'name="action" value="fastdl_clean"' not in s:
    if old not in s: raise SystemExit('[PATCH ERROR] FastDL button anchor not found')
    s=s.replace(old,new,1)
p.write_text(s,encoding='utf-8')
print('[OK] panel UI source patched')
PY
php -l "$UI_SRC" >/dev/null

echo '[3/8] Installing bzip2...'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bzip2 >/dev/null

echo '[4/8] Installing backend/UI runtime...'
install -m 0755 "$CTL_SRC" "$CTL_LIVE"
python3 -m py_compile "$CTL_LIVE"

DOMAIN="$(python3 - <<'PY'
import json
from pathlib import Path
try: print(str(json.loads(Path('/etc/hyper-cs16/runtime.json').read_text()).get('domain') or 'www.avito.hyper-host.pw'))
except Exception: print('www.avito.hyper-host.pw')
PY
)"
PUBLIC_IP="$(python3 - <<'PY'
import json
from pathlib import Path
try: print(str(json.loads(Path('/etc/hyper-cs16/runtime.json').read_text()).get('public_ip') or ''))
except Exception: print('')
PY
)"
[[ -n "$PUBLIC_IP" ]] || { echo '[ERROR] public_ip missing in runtime.json' >&2; exit 3; }

LIVE_UI="/var/www/hyper-host-sites/${DOMAIN}/public_html/index.php"
if [[ -f "$LIVE_UI" ]]; then
    cp -a "$LIVE_UI" "$BACKUP/index.php.live"
    install -m 0644 "$UI_SRC" "$LIVE_UI"
    chown www-data:www-data "$LIVE_UI" || true
    php -l "$LIVE_UI" >/dev/null
    echo "[OK] live panel UI updated: $LIVE_UI"
else
    echo "[WARN] live UI not found at $LIVE_UI"
fi

echo '[5/8] Installing nginx FastDL endpoint...'
mkdir -p /srv/hyper-cs16/fastdl /etc/nginx/hyper-host-managed
chown root:www-data /srv/hyper-cs16/fastdl
chmod 0755 /srv/hyper-cs16/fastdl
cat >/etc/nginx/hyper-host-managed/00-hyper-cs16-fastdl.conf <<EOF
# HYPER-HOST CS16 FASTDL PANEL v5.1
server {
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_IP};
    access_log /var/log/nginx/hyper-cs16-fastdl-access.log combined;
    error_log /var/log/nginx/hyper-cs16-fastdl-error.log warn;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65s;
    keepalive_requests 2000;
    gzip on;
    gzip_vary on;
    gzip_http_version 1.0;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_types *;
    location = /fastdl { return 301 /fastdl/; }
    location ^~ /fastdl/ {
        alias /srv/hyper-cs16/fastdl/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        default_type application/octet-stream;
        limit_except GET HEAD { deny all; }
        add_header X-Hyper-FastDL "panel-v5.1" always;
        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000" always;
    }
    location / { default_type text/plain; return 404 "HYPER-HOST FastDL\n"; }
}
EOF
nginx -t
systemctl reload nginx

echo '[6/8] Installing automatic incremental sync...'
cat >/etc/systemd/system/hyper-cs16-fastdl-sync.service <<'EOF'
[Unit]
Description=HYPER-HOST CS16 FastDL incremental sync
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -lc '/usr/local/sbin/hyper-cs16-ctl fastdl-sync-all || true'
EOF
cat >/etc/systemd/system/hyper-cs16-fastdl-sync.timer <<'EOF'
[Unit]
Description=HYPER-HOST CS16 automatic FastDL sync
[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now hyper-cs16-fastdl-sync.timer >/dev/null

echo '[7/8] Clearing OLD FastDL cache and rebuilding only client assets...'
"$CTL_LIVE" fastdl-clean "$SID"
"$CTL_LIVE" fastdl-sync "$SID"

echo '[8/8] Verifying...'
DEST="/srv/hyper-cs16/fastdl/${SID}"
for bad in addons configs scripting plugins dlls logs; do
    [[ ! -e "$DEST/$bad" ]] || { echo "[ERROR] server-only directory leaked into FastDL: $DEST/$bad" >&2; exit 4; }
done
BAD="$(find "$DEST" -type f \( -name '*.amxx' -o -name '*.sma' -o -name '*.so' -o -name '*.dll' -o -name 'server.cfg' \) -print -quit 2>/dev/null || true)"
[[ -z "$BAD" ]] || { echo "[ERROR] server-only file leaked into FastDL: $BAD" >&2; exit 5; }

echo
echo '--- FASTDL STATUS ---'
"$CTL_LIVE" fastdl-status "$SID"
echo
echo '--- TOP LEVEL ---'
find "$DEST" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
echo
echo '--- SERVER.CFG FASTDL ---'
grep -nEi 'sv_downloadurl|sv_allowdownload|sv_allowupload|sv_send_resources|sv_allow_dlfile' "/srv/hyper-cs16/servers/${SID}/cstrike/server.cfg" || true

TEST="$(find "$DEST" -type f ! -name '*.bz2' \( -name '*.mdl' -o -name '*.bsp' -o -name '*.wav' -o -name '*.spr' -o -name '*.wad' \) | head -n1 || true)"
if [[ -n "$TEST" ]]; then
    REL="${TEST#$DEST/}"
    HEADERS="$(mktemp)"; BODY="$(mktemp)"; trap 'rm -f "$HEADERS" "$BODY"' EXIT
    CODE="$(curl -sS -D "$HEADERS" -o "$BODY" -w '%{http_code}' -H "Host: ${PUBLIC_IP}" "http://127.0.0.1/fastdl/${SID}/${REL}")"
    echo; echo "--- HTTP TEST: $REL ---"; echo "HTTP=$CODE"
    grep -iE '^(HTTP/|Content-Type:|Content-Length:|X-Hyper-FastDL:)' "$HEADERS" || true
    [[ "$CODE" == 200 ]] && grep -qi '^X-Hyper-FastDL: *panel-v5\.1' "$HEADERS" || { echo '[ERROR] request did not hit FastDL v5.1' >&2; exit 6; }
    REAL_SHA="$(sha256sum "$TEST" | awk '{print $1}')"; HTTP_SHA="$(sha256sum "$BODY" | awk '{print $1}')"
    echo "REAL_SHA=$REAL_SHA"; echo "HTTP_SHA=$HTTP_SHA"
    [[ "$REAL_SHA" == "$HTTP_SHA" ]] || { echo '[ERROR] HTTP file differs from FastDL file' >&2; exit 7; }
fi

echo
echo '========================================================='
echo '[SUCCESS] FASTDL PANEL v5.1 INSTALLED'
echo 'Only existing client resources are mirrored:'
echo '  maps models sound sprites gfx resource overviews events media + root WAD'
echo 'Never mirrored: addons AMXX configs DLL/SO source logs server.cfg'
echo "FastDL: http://${PUBLIC_IP}/fastdl/${SID}/"
echo 'Auto-sync: ~60 seconds, incremental'
echo 'Panel buttons: Пересобрать FastDL / Очистить FastDL'
echo "Backup: $BACKUP"
echo '========================================================='
