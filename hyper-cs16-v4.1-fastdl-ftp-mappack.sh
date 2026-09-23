#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS 1.6 patch v4.1
# - Dedicated FastDL HTTP service on :8088 + BZip2 mirror
# - Server-side FTP/PASV repair + external diagnostics
# - ZIP/RAR map-pack upload in CS16 panel
# - FastDL UI: rebuild + safe full cache purge
# Target: current main branch of memes4u1337/hyper-hosting-panel (2026-09-23)

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run as root: sudo bash hyper-cs16-v4-fastdl-ftp-mappack.sh' >&2; exit 1; }

ROOT="${1:-$(pwd)}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
WEB="$ROOT/cs16-panel/public/index.php"
INSTALL="$ROOT/install-cs16-panel.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-patch-v4-backup-$STAMP"

for f in "$CTL" "$WEB" "$INSTALL"; do
  [[ -f "$f" ]] || { echo "[ERROR] Missing $f. Run this script from the repository root or pass it as arg #1." >&2; exit 2; }
done

mkdir -p "$BACKUP"
cp -a "$CTL" "$WEB" "$INSTALL" "$BACKUP/"
echo "[v4] Backup: $BACKUP"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y bzip2 p7zip-full unzip rsync curl nginx >/dev/null
apt-get install -y unrar-free >/dev/null 2>&1 || true

python3 - "$CTL" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
orig=s

# FastDL endpoint uses a dedicated plain-HTTP port. This avoids SSL/redirect issues
# with legacy GoldSrc clients and keeps the panel virtual host independent.
s=s.replace("FASTDL_DOMAIN='www.avito.hyper-host.pw'\n", "FASTDL_DOMAIN='www.avito.hyper-host.pw'\nFASTDL_PORT=8088\n")

old="""        if ip.version==4 and not ip.is_unspecified:\n            return f'http://{public}/fastdl/{sid}'\n    except Exception:\n        pass\n    return f'https://{FASTDL_DOMAIN}/fastdl/{sid}'\n"""
new="""        if ip.version==4 and not ip.is_unspecified:\n            return f'http://{public}:{FASTDL_PORT}/{sid}'\n    except Exception:\n        pass\n    # Hostname fallback is also plain HTTP: old CS 1.6 clients are much more\n    # predictable here than through an HTTPS redirect.\n    return f'http://{FASTDL_DOMAIN}:{FASTDL_PORT}/{sid}'\n"""
if old not in s:
    raise SystemExit('[PATCH ERROR] _fastdl_url anchor changed; refusing unsafe patch')
s=s.replace(old,new,1)

start=s.index('def _fastdl_copy_tree(src:Path,dst:Path):')
end=s.index('\ndef fastdl_status(sid:int):', start)
fastdl_block=r'''def _fastdl_copy_tree(src:Path,dst:Path):
    """Create a byte-for-byte mirror without ever modifying game-server files."""
    if not src.is_dir():
        if dst.exists(): shutil.rmtree(dst,ignore_errors=True)
        return
    dst.mkdir(parents=True,exist_ok=True)
    # --safe-links prevents a pack from making FastDL expose a symlink outside
    # the game content tree. --delete makes removed/replaced files disappear on
    # the next sync instead of leaving stale models/maps behind.
    cp=run(['rsync','-a','--delete','--safe-links',str(src)+'/',str(dst)+'/'],check=False,timeout=1200)
    if cp.returncode!=0:
        raise RuntimeError('FastDL rsync failed for '+str(src)+': '+(cp.stdout or '')[-2500:])


def _fastdl_bzip_tree(dest:Path)->dict:
    """Build GoldSrc .bz2 siblings atomically. Originals remain available too."""
    bzip=shutil.which('bzip2')
    if not bzip: return {'compressed':0,'bytes':0,'warning':'bzip2 is not installed'}
    # GoldSrc custom resources. We intentionally do not include executables,
    # AMXX plugins or server-only configs in the public tree.
    allowed={'.bsp','.nav','.res','.wad','.mdl','.spr','.wav','.mp3','.tga','.bmp','.pcx','.txt','.vmt','.vtf'}
    made=0; saved=0
    for fp in sorted(dest.rglob('*')):
        try:
            if not fp.is_file() or fp.is_symlink() or fp.suffix.lower()=='.bz2': continue
            if fp.suffix.lower() not in allowed: continue
            bz=Path(str(fp)+'.bz2')
            # Rebuild only when source is newer or size/hash-relevant metadata changed.
            if bz.is_file() and bz.stat().st_mtime_ns >= fp.stat().st_mtime_ns: continue
            tmp=bz.with_name('.'+bz.name+'.tmp-'+secrets.token_hex(4))
            # run() is text-oriented, so use subprocess directly for binary output.
            with open(tmp,'wb') as outfh:
                raw=subprocess.run([bzip,'-9','-c',str(fp)],stdout=outfh,stderr=subprocess.PIPE,check=False,timeout=300)
            if raw.returncode!=0:
                try: tmp.unlink()
                except OSError: pass
                continue
            os.chmod(tmp,0o644); os.replace(tmp,bz)
            try:
                os.utime(bz,ns=(fp.stat().st_atime_ns,fp.stat().st_mtime_ns))
                saved += max(0,fp.stat().st_size-bz.stat().st_size)
            except OSError: pass
            made+=1
        except (OSError,subprocess.SubprocessError):
            continue
    return {'compressed':made,'saved_bytes':saved}


def fastdl_clean(sid:int):
    require_root(); load_server(sid)
    dest=FASTDL_ROOT/str(sid)
    if dest.exists(): shutil.rmtree(dest)
    return {'ok':True,'id':sid,'root':str(dest),'deleted':True}


def fastdl_sync(sid:int, configure:bool=True):
    """Rebuild a clean client-only FastDL mirror and pre-compress resources."""
    require_root(); c=load_server(sid); root=Path(c['path']); cstrike=root/'cstrike'
    if not cstrike.is_dir(): raise RuntimeError(f'cstrike directory is missing: {cstrike}')
    FASTDL_ROOT.mkdir(parents=True,exist_ok=True)
    dest=FASTDL_ROOT/str(sid)
    # Build into a sibling and swap it in one operation. Players never see a
    # half-synced tree and stale resources cannot survive a re-upload.
    temp=FASTDL_ROOT/f'.{sid}.sync-{secrets.token_hex(5)}'
    if temp.exists(): shutil.rmtree(temp,ignore_errors=True)
    temp.mkdir(parents=True,exist_ok=True)
    copied_dirs=[]
    try:
        for name in FASTDL_DIRS:
            src=cstrike/name; dd=temp/name
            _fastdl_copy_tree(src,dd)
            if src.is_dir(): copied_dirs.append(name)
        source_wads={p.name:p for p in cstrike.iterdir() if p.is_file() and not p.is_symlink() and p.suffix.lower()=='.wad'}
        for name,src in source_wads.items(): shutil.copy2(src,temp/name)
        bz=_fastdl_bzip_tree(temp)
        run(['chown','-R','root:www-data',str(temp)],check=False)
        run(['find',str(temp),'-type','d','-exec','chmod','0755','{}','+'],check=False)
        run(['find',str(temp),'-type','f','-exec','chmod','0644','{}','+'],check=False)
        old=FASTDL_ROOT/f'.{sid}.old-{secrets.token_hex(4)}'
        if dest.exists(): os.replace(dest,old)
        os.replace(temp,dest)
        if old.exists(): shutil.rmtree(old,ignore_errors=True)
    finally:
        if temp.exists(): shutil.rmtree(temp,ignore_errors=True)
    cfg_result=_fastdl_apply_cfg(c,root) if configure else {'url':_fastdl_url(c)}
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
        for cmd in ['sv_allowdownload 1','sv_allowupload 1','sv_send_resources 1','sv_allow_dlfile 1',f'sv_downloadurl "{c["fastdl_url"]}"']:
            try: query_rcon('127.0.0.1',int(c['port']),str(c.get('rcon_password','')),cmd,2.0)
            except Exception as exc: runtime_errors.append(str(exc))
        runtime_applied=not runtime_errors
    return {'ok':True,'id':sid,'url':c['fastdl_url'],'root':str(dest),'files':files,'bytes':total,'dirs':copied_dirs,'compression':bz,'config':cfg_result,'runtime_applied':runtime_applied,'runtime_errors':runtime_errors[:5]}
'''
s=s[:start]+fastdl_block+s[end:]

insert_at=s.index('\ndef plugin_upload(sid:int,token:str,plugin_name:str):')
map_pack=r'''

def _map_pack_install_from_archive(sid:int,archive:Path):
    require_root(); c=load_server(sid); server=Path(c['path']); cstrike=server/'cstrike'
    if not cstrike.is_dir(): raise RuntimeError('cstrike directory is missing')
    work=STATE_ROOT/f'.map-pack-{sid}-{secrets.token_hex(8)}'
    backup=APP_ROOT/'backups'/f'map-pack-{sid}-{time.strftime("%Y%m%d-%H%M%S")}-{secrets.token_hex(4)}'
    installed=[]; overwritten=[]; maps=[]; kind=''
    allowed_top=set(FASTDL_DIRS)|{'maps'}
    allowed_ext={'.bsp','.nav','.res','.wad','.mdl','.spr','.wav','.mp3','.tga','.bmp','.pcx','.txt','.vmt','.vtf'}
    try:
        kind=_extract_build_archive(archive,work)
        payload=_unwrap_single_dir(work)
        if (payload/'cstrike').is_dir(): payload=payload/'cstrike'
        # Accept a conventional maps/ + models/ + sound/ pack. If the archive
        # contains bare map files, place BSP/RES/NAV into maps and WAD at cstrike root.
        candidates=[]
        for item in payload.rglob('*'):
            if not item.is_file() or item.is_symlink(): continue
            rel=item.relative_to(payload)
            if '__MACOSX' in rel.parts: continue
            ext=item.suffix.lower()
            if ext not in allowed_ext: continue
            if len(rel.parts)==1:
                if ext in {'.bsp','.res','.nav'}: target_rel=Path('maps')/item.name
                elif ext=='.wad': target_rel=Path(item.name)
                else: continue
            else:
                top=rel.parts[0].lower()
                if top not in allowed_top: continue
                target_rel=rel
            if '..' in target_rel.parts: continue
            candidates.append((item,target_rel))
        if not candidates: raise RuntimeError('В архиве не найден контент карты: ожидаются maps/*.bsp и при необходимости models/sound/sprites/gfx/resource/*.')
        backup.mkdir(parents=True,exist_ok=True)
        for src,rel in candidates:
            dst=(cstrike/rel).resolve(); base=cstrike.resolve()
            if dst!=base and base not in dst.parents: raise RuntimeError('Unsafe map-pack destination')
            dst.parent.mkdir(parents=True,exist_ok=True)
            if dst.exists():
                b=backup/rel; b.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(dst,b); overwritten.append(str(rel))
            tmp=dst.with_name('.'+dst.name+'.mappack-'+secrets.token_hex(4))
            shutil.copy2(src,tmp); os.replace(tmp,dst); installed.append(str(rel))
            if rel.parts and rel.parts[0].lower()=='maps' and dst.suffix.lower()=='.bsp' and SAFE_MAP.fullmatch(dst.stem): maps.append(dst.stem)
        normalize_permissions(server)
        fd=fastdl_sync(sid,True)
        return {'ok':True,'id':sid,'archive':kind,'installed_files':len(installed),'overwritten_files':len(overwritten),'maps':sorted(set(maps)),'backup':str(backup) if overwritten else '','fastdl':fd}
    finally:
        shutil.rmtree(work,ignore_errors=True)
        try: archive.unlink()
        except OSError: pass


def map_pack_install(sid:int,token:str):
    archive=_build_take_staged(token)
    return _map_pack_install_from_archive(sid,archive)
'''
s=s[:insert_at]+map_pack+s[insert_at:]

s=s.replace("q=sp.add_parser('map-upload'); q.add_argument('id',type=int); q.add_argument('token'); q.add_argument('map_name')\n",
            "q=sp.add_parser('map-upload'); q.add_argument('id',type=int); q.add_argument('token'); q.add_argument('map_name')\n    q=sp.add_parser('map-pack-install'); q.add_argument('id',type=int); q.add_argument('token')\n",1)
s=s.replace("for a in ['start','stop','restart','status','players','maps','plugins','update','reinstall','ftp-reset','ftp-repair','ftp-test','network','delete','repair-runtime','build-repair-current','mods-status','nat-upnp','network-fix','repair-content','sql-status','fastdl-sync','fastdl-status']:",
            "for a in ['start','stop','restart','status','players','maps','plugins','update','reinstall','ftp-reset','ftp-repair','ftp-test','network','delete','repair-runtime','build-repair-current','mods-status','nat-upnp','network-fix','repair-content','sql-status','fastdl-sync','fastdl-status','fastdl-clean']:",1)
s=s.replace("elif args.cmd=='map-upload': result=map_upload(args.id,args.token,args.map_name)\n",
            "elif args.cmd=='map-upload': result=map_upload(args.id,args.token,args.map_name)\n        elif args.cmd=='map-pack-install': result=map_pack_install(args.id,args.token)\n",1)
s=s.replace("elif args.cmd=='fastdl-status': result=fastdl_status(args.id)\n",
            "elif args.cmd=='fastdl-status': result=fastdl_status(args.id)\n        elif args.cmd=='fastdl-clean': result=fastdl_clean(args.id)\n",1)

if s==orig: raise SystemExit('[PATCH ERROR] controller was not changed')
p.write_text(s,encoding='utf-8')
PY

python3 - "$WEB" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8'); orig=s
# FastDL full-cache purge handler. It removes only the generated mirror, never the game server files.
fastdl_anchor="""        if($action==='nat_upnp'){\n"""
fastdl_handler="""        if($action==='fastdl_clean'){\n            $id=(int)($_POST['id']??0);require_perm('server.maintenance',$id);server_row($id);$r=ctl(['fastdl-clean',$id],120);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось очистить FastDL'));audit('fastdl_clean','full purge',$id);flash('FastDL полностью очищен. Игровые файлы сервера не удалялись. После изменений через FTP нажми «Пересобрать FastDL».','success');redirect('/?page=server&id='.$id.'#ftp');\n        }\n"""
if fastdl_anchor not in s: raise SystemExit('[PATCH ERROR] fastdl_clean handler anchor not found')
s=s.replace(fastdl_anchor,fastdl_handler+fastdl_anchor,1)

needle="""        if($action==='upload_plugin'){\n"""
handler="""        if($action==='upload_map_pack'){\n            $id=(int)($_POST['id']??0);require_perm('server.plugins',$id);server_row($id);$file=$_FILES['map_pack_file']??[];$original=basename((string)($file['name']??''));$ext=strtolower(pathinfo($original,PATHINFO_EXTENSION));if(!in_array($ext,['zip','rar'],true))throw new RuntimeException('Архив карт должен быть .zip или .rar');[$token,$original]=stage_upload($file,'build','.'.$ext,PHP_INT_MAX);$r=ctl(['map-pack-install',$id,$token],900);if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось установить архив карт'));$maps=is_array($r['maps']??null)?$r['maps']:[];$fd=is_array($r['fastdl']??null)?$r['fastdl']:[];audit('map_pack_upload',$original.' / '.count($maps).' maps',$id);flash('Архив карт установлен: '.count($maps).' карт, '.(int)($r['installed_files']??0).' файлов. FastDL: '.(int)($fd['files']??0).' файлов.');redirect('/?page=server&id='.$id.'#maps');\n        }\n"""
if needle not in s: raise SystemExit('[PATCH ERROR] upload_plugin anchor not found')
s=s.replace(needle,handler+needle,1)

old='''<form method="post" enctype="multipart/form-data" class="map-upload"><?=csrf_field()?><input type="hidden" name="action" value="upload_map"><input type="hidden" name="id" value="<?=$id?>"><input class="form-control form-control-sm" type="file" name="map_file" accept=".bsp" required><button class="btn btn-primary btn-sm"><i class="fa-solid fa-upload me-1"></i>Загрузить BSP</button></form>'''
new='''<div class="d-flex gap-2 flex-wrap"><form method="post" enctype="multipart/form-data" class="map-upload"><?=csrf_field()?><input type="hidden" name="action" value="upload_map"><input type="hidden" name="id" value="<?=$id?>"><input class="form-control form-control-sm" type="file" name="map_file" accept=".bsp" required><button class="btn btn-primary btn-sm"><i class="fa-solid fa-upload me-1"></i>BSP</button></form><form method="post" enctype="multipart/form-data" class="map-upload"><?=csrf_field()?><input type="hidden" name="action" value="upload_map_pack"><input type="hidden" name="id" value="<?=$id?>"><input class="form-control form-control-sm" type="file" name="map_pack_file" accept=".zip,.rar,application/zip,application/vnd.rar" required><button class="btn btn-soft btn-sm"><i class="fa-solid fa-file-zipper me-1"></i>ZIP/RAR карты</button></form></div>'''
if old not in s: raise SystemExit('[PATCH ERROR] map form anchor not found')
s=s.replace(old,new,1)

old_fastdl='''<form method="post" class="mt-2"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_sync"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-soft"><i class="fa-solid fa-arrows-rotate me-2"></i>Обновить FastDL сейчас</button></form>'''
new_fastdl='''<div class="d-flex flex-wrap gap-2 mt-2"><form method="post"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_sync"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-primary"><i class="fa-solid fa-arrows-rotate me-2"></i>Пересобрать FastDL</button></form><form method="post" onsubmit="return confirm('Полностью удалить все файлы из FastDL? Карты, модели и остальные файлы самого игрового сервера останутся на месте.')"><?=csrf_field()?><input type="hidden" name="action" value="fastdl_clean"><input type="hidden" name="id" value="<?=$id?>"><button class="btn btn-danger"><i class="fa-solid fa-trash-can me-2"></i>Удалить всё из FastDL</button></form></div>'''
if old_fastdl not in s: raise SystemExit('[PATCH ERROR] FastDL UI anchor not found')
s=s.replace(old_fastdl,new_fastdl,1)
if s==orig: raise SystemExit('[PATCH ERROR] web panel was not changed')
p.write_text(s,encoding='utf-8')
PY

# Ensure future normal panel installs keep the required packages.
python3 - "$INSTALL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
old='apt-get install -y ca-certificates curl unzip rsync sudo openssl sqlite3 python3 python3-pymysql php-mysql lib32gcc-s1 libc6:i386 libstdc++6:i386 libgcc-s1:i386 lib32z1 >/dev/null'
new='apt-get install -y ca-certificates curl unzip bzip2 p7zip-full rsync sudo openssl sqlite3 python3 python3-pymysql php-mysql lib32gcc-s1 libc6:i386 libstdc++6:i386 libgcc-s1:i386 lib32z1 >/dev/null'
if old in s: s=s.replace(old,new,1)
p.write_text(s,encoding='utf-8')
PY

# Validate source before touching installed runtime.
python3 -m py_compile "$CTL"
php -l "$WEB" >/dev/null
bash -n "$INSTALL"

echo '[v4.1] Source validation OK'

# Install updated CS16 runtime + web panel without replacing game data.
export CS16_SKIP_GAME_DOWNLOAD=1
export CS16_CREATE_DEFAULT=0
bash "$ROOT/install-cs16-panel.sh"

# Dedicated FastDL HTTP endpoint. No gzip/content-encoding: GoldSrc receives .bz2
# as a real file and decompresses it on the client side.
cat >/etc/nginx/conf.d/hyper-cs16-fastdl.conf <<'NGINX'
server {
    listen 0.0.0.0:8088;
    listen [::]:8088;
    server_name _;

    root /srv/hyper-cs16/fastdl;
    autoindex off;
    sendfile on;
    tcp_nopush on;
    gzip off;
    etag on;
    client_max_body_size 1m;

    location / {
        limit_except GET HEAD { deny all; }
        try_files $uri =404;
        default_type application/octet-stream;
        add_header Accept-Ranges bytes always;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
    }
}
NGINX
nginx -t
systemctl reload nginx

if command -v ufw >/dev/null 2>&1; then
  ufw allow 8088/tcp >/dev/null 2>&1 || true
  ufw allow 21/tcp >/dev/null 2>&1 || true
  ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport 8088 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8088 -j ACCEPT 2>/dev/null || true
fi

# Repair FTP backend and accounts using the project's own controller.
if command -v hyper >/dev/null 2>&1; then
  hyper access fix || true
  hyper ftp fix || true
fi
/usr/local/sbin/hyper-cs16-ctl ftp-restore || true

# Rebuild FastDL for all existing servers.
/usr/local/sbin/hyper-cs16-ctl fastdl-sync-all || true

# Runtime checks.
echo
echo '========== HYPER CS16 PATCH v4.1 =========='
ss -ltnp 2>/dev/null | grep -E ':(21|8088)\b' || true
if command -v hyper >/dev/null 2>&1; then
  echo '--- FTP doctor ---'
  hyper ftp doctor || true
fi

echo '--- FastDL local probe ---'
curl -sSI --max-time 5 http://127.0.0.1:8088/ | head -n 8 || true

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
PUBLIC_IP=""
if [[ -f /etc/hyper-cs16/runtime.json ]]; then
  PUBLIC_IP="$(python3 - <<'PY'
import json
try: print(json.load(open('/etc/hyper-cs16/runtime.json')).get('public_ip',''))
except Exception: pass
PY
)"
fi

echo
echo '[DONE] Code + runtime installed.'
echo "FastDL public endpoint: http://${PUBLIC_IP:-PUBLIC_IP}:8088/<SERVER_ID>/"
echo "FTP server: ${PUBLIC_IP:-PUBLIC_IP}:21, passive TCP 40000-40100"
echo
echo 'IMPORTANT FOR A SERVER BEHIND A ROUTER/NAT:'
echo "  TCP 21          -> ${LAN_IP:-SERVER_LAN_IP}:21"
echo "  TCP 40000-40100 -> ${LAN_IP:-SERVER_LAN_IP}:40000-40100"
echo "  TCP 8088        -> ${LAN_IP:-SERVER_LAN_IP}:8088   # FastDL"
echo 'Without these router forwards an FTP/FastDL service can work inside LAN and still be unreachable from home/Internet.'
echo
echo 'Useful commands:'
echo '  sudo hyper-cs16-ctl fastdl-sync-all'
echo '  sudo hyper-cs16-ctl fastdl-clean SERVER_ID'
echo '  sudo hyper-cs16-ctl fastdl-sync SERVER_ID'
echo '  sudo hyper-cs16-ctl ftp-repair SERVER_ID'
echo '  sudo hyper-cs16-ctl ftp-test SERVER_ID'
echo '  sudo hyper ftp doctor'
echo '========================================='
