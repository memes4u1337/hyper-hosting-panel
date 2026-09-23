#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERROR] Run as root/sudo" >&2; exit 1; }

ROOT="${1:-/root/hyper-hosting-panel}"
TARGET_ID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
UI="$ROOT/cs16-panel/public/index.php"
INSTALLER="$ROOT/install-cs16-panel.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-fastdl-panel-v5-backup-${STAMP}"

[[ -f "$CTL" ]] || { echo "[ERROR] Missing $CTL" >&2; exit 2; }
[[ -f "$UI" ]] || { echo "[ERROR] Missing $UI" >&2; exit 2; }
[[ -f "$INSTALLER" ]] || { echo "[ERROR] Missing $INSTALLER" >&2; exit 2; }

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl"
cp -a "$UI" "$BACKUP/index.php"
cp -a "$INSTALLER" "$BACKUP/install-cs16-panel.sh"

echo "========== HYPER CS16 FASTDL PANEL v5 =========="
echo "Repo:      $ROOT"
echo "Server:    #$TARGET_ID"
echo "Backup:    $BACKUP"
echo

python3 - "$CTL" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

rules = """FASTDL_RULES={
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

s,n=re.subn(r"(?m)^FASTDL_DIRS=.*$", rules, s, count=1)
if n != 1:
    raise SystemExit("[PATCH ERROR] FASTDL_DIRS not found")

url_func = """def _fastdl_url(c:dict)->str:
    # Per-server FastDL URL on the node plain HTTP endpoint.
    sid=int(c.get('id') or 0)
    public=''
    try:
        rt=load_runtime(); public=str(rt.get('public_ip') or c.get('public_ip') or '').strip()
    except Exception:
        public=str(c.get('public_ip') or '').strip()
    try:
        ip=ipaddress.ip_address(public)
        if ip.version==4 and not ip.is_unspecified:
            return f'http://{public}/fastdl/{sid}/'
    except Exception:
        pass
    return f'http://{FASTDL_DOMAIN}/fastdl/{sid}/'

"""

s,n=re.subn(
    r"(?ms)^def _fastdl_url\(c:dict\)->str:\n.*?(?=^def _fastdl_apply_cfg\()",
    url_func, s, count=1
)
if n != 1:
    raise SystemExit("[PATCH ERROR] _fastdl_url block not found")

cfg_func = """def _fastdl_apply_cfg(c:dict, root:Path|None=None)->dict:
    # Write one canonical FastDL block and disable slow HLDS file fallback.
    root=Path(root or c['path'])
    cfg=root/'cstrike/server.cfg'; cfg.parent.mkdir(parents=True,exist_ok=True)
    text=cfg.read_text(encoding='utf-8',errors='ignore') if cfg.exists() else ''
    text=text.replace('\\r\\n','\\n').replace('\\r','\\n')
    begin='// HYPER-HOST FASTDL BEGIN'
    end='// HYPER-HOST FASTDL END'
    text=re.sub(r'(?ims)^\\s*// HYPER-HOST FASTDL BEGIN\\s*$.*?^\\s*// HYPER-HOST FASTDL END\\s*$\\n?', '', text)
    managed={'sv_downloadurl','sv_allowdownload','sv_allowupload','sv_send_resources','sv_allow_dlfile'}
    kept=[]; replaced=[]
    for line in text.splitlines():
        m=re.match(r'^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s+',line)
        if m and m.group(1).lower() in managed:
            replaced.append(line.strip())
            continue
        kept.append(line)
    url=_fastdl_url(c)
    block=[
        begin,
        '// Managed automatically by HYPER-HOST.',
        'sv_allowdownload 1',
        'sv_allowupload 0',
        'sv_send_resources 1',
        'sv_allow_dlfile 0',
        f'sv_downloadurl "{url}"',
        end,
    ]
    content='\\n'.join(kept).rstrip()+'\\n\\n'+'\\n'.join(block)+'\\n'
    cfg.write_text(content,encoding='utf-8')
    return {'ok':True,'url':url,'config':str(cfg),'replaced':replaced}

"""

s,n=re.subn(
    r"(?ms)^def _fastdl_apply_cfg\(c:dict,\s*root:Path\|None=None\)->dict:\n.*?(?=^def _fastdl_copy_tree\()",
    cfg_func, s, count=1
)
if n != 1:
    raise SystemExit("[PATCH ERROR] _fastdl_apply_cfg block not found")

sync_block = """def _fastdl_bz2(src:Path):
    # Create .bz2 sidecar, never modify original resource.
    if src.suffix.lower() not in FASTDL_COMPRESS_EXTS:
        return {'compressed':False,'saved':0}
    try:
        size=src.stat().st_size
    except OSError:
        return {'compressed':False,'saved':0}
    if size < FASTDL_COMPRESS_MIN_BYTES:
        return {'compressed':False,'saved':0}
    bz=Path(str(src)+'.bz2')
    try:
        if bz.is_file() and bz.stat().st_size>0 and bz.stat().st_mtime >= src.stat().st_mtime:
            return {'compressed':True,'saved':max(0,size-bz.stat().st_size)}
    except OSError:
        pass
    if not shutil.which('bzip2'):
        return {'compressed':False,'saved':0}
    tmp=bz.with_name('.'+bz.name+'.tmp-'+secrets.token_hex(4))
    try:
        with open(tmp,'wb') as wf:
            cp=subprocess.run(['bzip2','-9','-c',str(src)],stdout=wf,stderr=subprocess.PIPE,check=False,timeout=300)
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


def _fastdl_copy_tree(src:Path,dst:Path,allowed_exts:set[str]):
    # Incremental mirror of only whitelisted client resources.
    if not src.is_dir():
        if dst.exists(): shutil.rmtree(dst,ignore_errors=True)
        return {'files':0,'compressed':0,'saved':0,'copied':0}

    dst.mkdir(parents=True,exist_ok=True)
    expected=set()
    copied=0; compressed=0; saved=0

    for fp in src.rglob('*'):
        try:
            if not fp.is_file() or fp.is_symlink(): continue
        except OSError:
            continue
        if fp.suffix.lower() not in allowed_exts:
            continue
        rel=fp.relative_to(src)
        rel_key=rel.as_posix()
        expected.add(rel_key)
        target=dst/rel
        target.parent.mkdir(parents=True,exist_ok=True)

        do_copy=True
        try:
            a=fp.stat(); b=target.stat()
            do_copy=(a.st_size!=b.st_size or int(a.st_mtime)!=int(b.st_mtime))
        except OSError:
            pass
        if do_copy:
            shutil.copy2(fp,target); copied+=1

        comp=_fastdl_bz2(target)
        if comp.get('compressed'):
            compressed+=1
            saved+=int(comp.get('saved') or 0)

    for old in sorted(dst.rglob('*'),key=lambda x:len(x.parts),reverse=True):
        try:
            if old.is_file():
                rel=old.relative_to(dst).as_posix()
                raw_rel=rel[:-4] if rel.lower().endswith('.bz2') else rel
                if raw_rel not in expected:
                    old.unlink()
            elif old.is_dir() and not any(old.iterdir()):
                old.rmdir()
        except OSError:
            pass

    return {'files':len(expected),'compressed':compressed,'saved':saved,'copied':copied}


def _fastdl_sync_root_files(cstrike:Path,dest:Path):
    expected=set(); copied=0; compressed=0; saved=0
    for fp in cstrike.iterdir():
        try:
            if not fp.is_file() or fp.is_symlink() or fp.suffix.lower() not in FASTDL_ROOT_EXTS:
                continue
        except OSError:
            continue
        expected.add(fp.name)
        target=dest/fp.name
        do_copy=True
        try:
            a=fp.stat(); b=target.stat()
            do_copy=(a.st_size!=b.st_size or int(a.st_mtime)!=int(b.st_mtime))
        except OSError:
            pass
        if do_copy:
            shutil.copy2(fp,target); copied+=1
        comp=_fastdl_bz2(target)
        if comp.get('compressed'):
            compressed+=1; saved+=int(comp.get('saved') or 0)

    for old in list(dest.iterdir()):
        try:
            if not old.is_file(): continue
            rel=old.name
            raw=rel[:-4] if rel.lower().endswith('.bz2') else rel
            if Path(raw).suffix.lower() in FASTDL_ROOT_EXTS and raw not in expected:
                old.unlink()
        except OSError:
            pass
    return {'files':len(expected),'compressed':compressed,'saved':saved,'copied':copied}


def fastdl_clean(sid:int):
    # Delete generated FastDL cache only.
    require_root(); c=load_server(sid); dest=FASTDL_ROOT/str(sid)
    if dest.exists(): shutil.rmtree(dest)
    c['fastdl_last_sync']=0; c['fastdl_files']=0; c['fastdl_bytes']=0
    c['fastdl_asset_files']=0; c['fastdl_compressed_files']=0
    save_server(c)
    return {'ok':True,'id':sid,'root':str(dest),'deleted':True,'game_files_untouched':True}


def fastdl_sync(sid:int, configure:bool=True):
    # Mirror ONLY client-downloadable assets. Never copy addons/configs/plugins.
    require_root(); c=load_server(sid); root=Path(c['path']); cstrike=root/'cstrike'
    if not cstrike.is_dir(): raise RuntimeError(f'cstrike directory is missing: {cstrike}')

    FASTDL_ROOT.mkdir(parents=True,exist_ok=True)
    dest=FASTDL_ROOT/str(sid); dest.mkdir(parents=True,exist_ok=True)

    allowed_top=set(FASTDL_RULES)
    for old in list(dest.iterdir()):
        try:
            if old.is_dir() and old.name not in allowed_top:
                shutil.rmtree(old,ignore_errors=True)
            elif old.is_file():
                raw=old.name[:-4] if old.name.lower().endswith('.bz2') else old.name
                if Path(raw).suffix.lower() not in FASTDL_ROOT_EXTS:
                    old.unlink()
        except OSError:
            pass

    copied_dirs=[]; asset_files=0; compressed_files=0; saved_bytes=0; copied_files=0
    for name,exts in FASTDL_RULES.items():
        src=cstrike/name; dd=dest/name
        stat=_fastdl_copy_tree(src,dd,exts)
        if src.is_dir(): copied_dirs.append(name)
        asset_files+=int(stat.get('files') or 0)
        compressed_files+=int(stat.get('compressed') or 0)
        saved_bytes+=int(stat.get('saved') or 0)
        copied_files+=int(stat.get('copied') or 0)

    root_stat=_fastdl_sync_root_files(cstrike,dest)
    asset_files+=int(root_stat.get('files') or 0)
    compressed_files+=int(root_stat.get('compressed') or 0)
    saved_bytes+=int(root_stat.get('saved') or 0)
    copied_files+=int(root_stat.get('copied') or 0)

    cfg_result=_fastdl_apply_cfg(c,root) if configure else {'url':_fastdl_url(c)}

    run(['chown','-R','root:www-data',str(dest)],check=False)
    run(['find',str(dest),'-type','d','-exec','chmod','0755','{}','+'],check=False)
    run(['find',str(dest),'-type','f','-exec','chmod','0644','{}','+'],check=False)

    disk_files=0; disk_bytes=0
    for fp in dest.rglob('*'):
        try:
            if fp.is_file(): disk_files+=1; disk_bytes+=fp.stat().st_size
        except OSError: pass

    c['fastdl_url']=cfg_result.get('url') or _fastdl_url(c)
    c['fastdl_last_sync']=int(time.time())
    c['fastdl_files']=disk_files
    c['fastdl_bytes']=disk_bytes
    c['fastdl_asset_files']=asset_files
    c['fastdl_compressed_files']=compressed_files
    c['fastdl_saved_bytes']=saved_bytes
    save_server(c)

    runtime_applied=False; runtime_errors=[]
    if service_status(sid)=='active' and udp_listening(int(c.get('port') or 0)):
        for cmd in [
            'sv_allowdownload 1',
            'sv_allowupload 0',
            'sv_send_resources 1',
            'sv_allow_dlfile 0',
            f'sv_downloadurl "{c["fastdl_url"]}"'
        ]:
            try: query_rcon('127.0.0.1',int(c['port']),str(c.get('rcon_password','')),cmd,2.0)
            except Exception as exc: runtime_errors.append(str(exc))
        runtime_applied=not runtime_errors

    return {
        'ok':True,'id':sid,'url':c['fastdl_url'],'root':str(dest),
        'files':disk_files,'bytes':disk_bytes,
        'asset_files':asset_files,'compressed_files':compressed_files,
        'saved_bytes':saved_bytes,'copied_files':copied_files,
        'dirs':copied_dirs,'root_extensions':sorted(FASTDL_ROOT_EXTS),
        'config':cfg_result,'runtime_applied':runtime_applied,
        'runtime_errors':runtime_errors[:5],
        'only_client_assets':True
    }


def fastdl_status(sid:int):
    c=load_server(sid); dest=FASTDL_ROOT/str(sid); cfg=Path(c['path'])/'cstrike/server.cfg'
    url=_fastdl_url(c); files=0; total=0; assets=0; compressed=0
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
            m=re.findall(r'(?im)^\\s*sv_downloadurl\\s+"?([^"\\r\\n]+)',cfg.read_text(encoding='utf-8',errors='ignore'))
            if m: current=m[-1].strip()
        except Exception: pass
    return {
        'ok':True,'id':sid,'url':url,'configured_url':current,
        'configured':current.rstrip('/')==url.rstrip('/'),
        'root':str(dest),'exists':dest.is_dir(),'files':files,'bytes':total,
        'asset_files':assets,'compressed_files':compressed,
        'last_sync':int(c.get('fastdl_last_sync') or 0),
        'only_client_assets':True
    }

"""

s,n=re.subn(
    r"(?ms)^def _fastdl_copy_tree\(src:Path,dst:Path\):\n.*?(?=^def _extract_external_fastdl_url\()",
    sync_block, s, count=1
)
if n != 1:
    raise SystemExit("[PATCH ERROR] FastDL sync/status block not found")

old="'repair-content','sql-status','fastdl-sync','fastdl-status']:"
new="'repair-content','sql-status','fastdl-sync','fastdl-status','fastdl-clean']:"
if old not in s:
    raise SystemExit("[PATCH ERROR] CLI command list not found")
s=s.replace(old,new,1)

old_dispatch="elif args.cmd=='fastdl-status': result=fastdl_status(args.id)"
new_dispatch="elif args.cmd=='fastdl-status': result=fastdl_status(args.id)\n        elif args.cmd=='fastdl-clean': result=fastdl_clean(args.id)"
if old_dispatch not in s:
    raise SystemExit("[PATCH ERROR] FastDL dispatch not found")
s=s.replace(old_dispatch,new_dispatch,1)

p.write_text(s,encoding='utf-8')
PY

python3 -m py_compile "$CTL"
echo "[OK] Backend patched"

python3 - "$UI" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

needle="""        if($action==='fastdl_sync'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);$r=ctl(['fastdl-sync',$id],900);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось синхронизировать FastDL'));audit('fastdl_sync',(string)($r['url']??''),$id);flash('FastDL обновлён: '.(string)($r['files']??0).' файлов · '.(string)($r['url']??''));redirect('/?page=server&id='.$id.'#ftp');
        }
"""
replacement="""        if($action==='fastdl_sync'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);$r=ctl(['fastdl-sync',$id],900);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось синхронизировать FastDL'));audit('fastdl_sync',(string)($r['url']??''),$id);flash('FastDL пересобран: '.(string)($r['asset_files']??0).' клиентских ресурсов · '.(string)($r['compressed_files']??0).' сжатых копий · '.(string)($r['url']??''));redirect('/?page=server&id='.$id.'#ftp');
        }
        if($action==='fastdl_clean'){
            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);$r=ctl(['fastdl-clean',$id],120);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось очистить FastDL'));audit('fastdl_clean',(string)($r['root']??''),$id);flash('FastDL-кэш очищен. Игровые файлы сервера не затронуты.');redirect('/?page=server&id='.$id.'#ftp');
        }
"""
if needle not in s:
    raise SystemExit("[PATCH ERROR] UI fastdl_sync action block not found")
s=s.replace(needle,replacement,1)

old_text='Панель автоматически обновляет FastDL после установки сборки, карты, рестарта и периодически после FTP-изменений.'
new_text='В FastDL попадают только клиентские ресурсы: maps, models, sound, sprites, gfx/resource/overviews/events/media и корневые WAD. addons, AMXX, configs, DLL и серверные файлы сюда не копируются. После FTP-изменений FastDL синхронизируется автоматически и его можно пересобрать вручную.'
if old_text not in s:
    raise SystemExit("[PATCH ERROR] UI FastDL description not found")
s=s.replace(old_text,new_text,1)

old_form='</p><form method="post" class="mt-2"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_sync"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-soft"><i class="fa-solid fa-arrows-rotate me-2"></i>Обновить FastDL сейчас</button></form></div></div>'
new_form='</p><div class="d-flex gap-2 flex-wrap mt-2"><form method="post"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_sync"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-primary"><i class="fa-solid fa-bolt me-2"></i>Пересобрать FastDL</button></form><form method="post" onsubmit="return confirm(\\'Очистить только FastDL-кэш? Игровые файлы сервера останутся на месте.\\')"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_clean"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-soft"><i class="fa-solid fa-trash-can me-2"></i>Очистить FastDL</button></form></div></div></div>'
if old_form not in s:
    raise SystemExit("[PATCH ERROR] UI FastDL form not found")
s=s.replace(old_form,new_form,1)

p.write_text(s,encoding='utf-8')
PY

php -l "$UI" >/dev/null
echo "[OK] Panel UI patched"

python3 - "$INSTALLER" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

old="apt-get install -y ca-certificates curl unzip rsync sudo openssl sqlite3 python3 python3-pymysql php-mysql"
new="apt-get install -y ca-certificates curl unzip rsync bzip2 sudo openssl sqlite3 python3 python3-pymysql php-mysql"
if old in s:
    s=s.replace(old,new,1)

marker="# HYPER-HOST FASTDL PANEL v5 BEGIN"
if marker not in s:
    anchor='chown root:root "$ETC/runtime.json"\n'
    if anchor not in s:
        raise SystemExit("[PATCH ERROR] installer runtime anchor not found")
    block="""chown root:root "$ETC/runtime.json"

# HYPER-HOST FASTDL PANEL v5 BEGIN
mkdir -p /srv/hyper-cs16/fastdl /etc/nginx/hyper-host-managed
chown root:www-data /srv/hyper-cs16/fastdl
chmod 0755 /srv/hyper-cs16/fastdl
cat >/etc/nginx/hyper-host-managed/00-hyper-cs16-fastdl.conf <<EOF
# HYPER-HOST CS16 FastDL PANEL v5
server {
    listen 80;
    listen [::]:80;
    server_name $GAME_PUBLIC_IP;

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
        add_header X-Hyper-FastDL "panel-v5" always;
        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000" always;
    }

    location / {
        default_type text/plain;
        return 404 "HYPER-HOST CS16 FastDL\\n";
    }
}
EOF
nginx -t
systemctl reload nginx || systemctl restart nginx

cat >/etc/systemd/system/hyper-cs16-fastdl-sync.service <<'EOF'
[Unit]
Description=HYPER-HOST CS 1.6 incremental FastDL synchronization
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '/usr/local/sbin/hyper-cs16-ctl fastdl-sync-all || true'
EOF

cat >/etc/systemd/system/hyper-cs16-fastdl-sync.timer <<'EOF'
[Unit]
Description=Synchronize CS 1.6 FastDL after FTP/resource changes

[Timer]
OnBootSec=75
OnUnitActiveSec=60
AccuracySec=15
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now hyper-cs16-fastdl-sync.timer >/dev/null 2>&1 || true
# HYPER-HOST FASTDL PANEL v5 END
"""
    s=s.replace(anchor,block,1)

p.write_text(s,encoding='utf-8')
PY

bash -n "$INSTALLER"
echo "[OK] Installer persistence patched"

echo "[1/6] Installing bzip2..."
apt-get update -qq
apt-get install -y -qq bzip2 >/dev/null

echo "[2/6] Installing controller runtime..."
install -m 0755 "$CTL" /usr/local/sbin/hyper-cs16-ctl
python3 -m py_compile /usr/local/sbin/hyper-cs16-ctl

echo "[3/6] Installing patched panel UI..."
DOMAIN="$(python3 - <<'PY'
import json
from pathlib import Path
try:
    print(json.loads(Path('/etc/hyper-cs16/runtime.json').read_text()).get('domain','www.avito.hyper-host.pw'))
except Exception:
    print('www.avito.hyper-host.pw')
PY
)"
LIVE_UI="/var/www/hyper-host-sites/${DOMAIN}/public_html/index.php"
if [[ -d "$(dirname "$LIVE_UI")" ]]; then
    install -m 0644 "$UI" "$LIVE_UI"
    chown www-data:www-data "$LIVE_UI" || true
    php -l "$LIVE_UI" >/dev/null
    echo "[OK] Live UI: $LIVE_UI"
else
    echo "[WARN] Live panel path not found; next update-cs16-panel.sh will install patched UI."
fi

echo "[4/6] Installing persistent nginx FastDL endpoint..."
PUBLIC_IP="$(python3 - <<'PY'
import json
from pathlib import Path
try:
    print(json.loads(Path('/etc/hyper-cs16/runtime.json').read_text()).get('public_ip',''))
except Exception:
    print('')
PY
)"
[[ -n "$PUBLIC_IP" ]] || { echo "[ERROR] public_ip missing from runtime.json" >&2; exit 3; }

mkdir -p /srv/hyper-cs16/fastdl /etc/nginx/hyper-host-managed
chown root:www-data /srv/hyper-cs16/fastdl
chmod 0755 /srv/hyper-cs16/fastdl

cat >/etc/nginx/hyper-host-managed/00-hyper-cs16-fastdl.conf <<EOF
# HYPER-HOST CS16 FastDL PANEL v5
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
        add_header X-Hyper-FastDL "panel-v5" always;
        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000" always;
    }
    location / {
        default_type text/plain;
        return 404 "HYPER-HOST CS16 FastDL\n";
    }
}
EOF

nginx -t
systemctl reload nginx || systemctl restart nginx

echo "[5/6] Installing automatic incremental FTP -> FastDL synchronization..."
cat >/etc/systemd/system/hyper-cs16-fastdl-sync.service <<'EOF'
[Unit]
Description=HYPER-HOST CS 1.6 incremental FastDL synchronization
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '/usr/local/sbin/hyper-cs16-ctl fastdl-sync-all || true'
EOF
cat >/etc/systemd/system/hyper-cs16-fastdl-sync.timer <<'EOF'
[Unit]
Description=Synchronize CS 1.6 FastDL after FTP/resource changes

[Timer]
OnBootSec=75
OnUnitActiveSec=60
AccuracySec=15
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now hyper-cs16-fastdl-sync.timer >/dev/null 2>&1 || true

echo "[6/6] Purging old mirror and rebuilding ONLY client assets for server #${TARGET_ID}..."
/usr/local/sbin/hyper-cs16-ctl fastdl-clean "$TARGET_ID"
/usr/local/sbin/hyper-cs16-ctl fastdl-sync "$TARGET_ID"

echo
echo "--- FASTDL STATUS ---"
/usr/local/sbin/hyper-cs16-ctl fastdl-status "$TARGET_ID"

echo
echo "--- CONTENT SAFETY CHECK ---"
DEST="/srv/hyper-cs16/fastdl/${TARGET_ID}"
for forbidden in addons dlls configs scripting plugins logs; do
    if [[ -e "$DEST/$forbidden" ]]; then
        echo "[ERROR] Forbidden server-only directory found in FastDL: $DEST/$forbidden" >&2
        exit 4
    fi
done
echo "[OK] No addons/configs/plugins/DLL server tree in FastDL"

echo
echo "--- FASTDL TOP LEVEL ---"
find "$DEST" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort

echo
echo "--- HTTP CHECK ---"
TEST="$(find "$DEST" -type f ! -name '*.bz2' | head -n1 || true)"
if [[ -n "$TEST" ]]; then
    REL="${TEST#$DEST/}"
    curl -sSI -H "Host: ${PUBLIC_IP}" "http://127.0.0.1/fastdl/${TARGET_ID}/${REL}" | \
      grep -iE '^(HTTP/|Content-Type:|Content-Length:|Content-Encoding:|X-Hyper-FastDL:)' || true
fi

echo
echo "=========================================================="
echo "[DONE] FASTDL PANEL v5 installed"
echo "FastDL: http://${PUBLIC_IP}/fastdl/${TARGET_ID}/"
echo
echo "Only client resources are mirrored:"
echo "  maps models sound sprites gfx resource overviews events media + root WAD"
echo
echo "NEVER mirrored:"
echo "  addons AMXX configs DLL source code logs server.cfg plugins"
echo
echo "Game files under /srv/hyper-cs16/servers/${TARGET_ID}/ are untouched."
echo "Auto-sync timer: every ~60 seconds (incremental; only changed files are copied/compressed)."
echo "Panel buttons: Пересобрать FastDL / Очистить FastDL"
echo "Backup: $BACKUP"
echo "=========================================================="
