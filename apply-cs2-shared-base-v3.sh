#!/usr/bin/env bash
# HYPER-HOST CS2 v3: one Steam App 730 installation + isolated OverlayFS layers.
# Installs over CS2 v2, safe to apply DURING the initial SteamCMD download.
# Does not touch CS1.6 files, running game data, SteamCMD process or initial base service.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '[ERROR] Run as root (sudo bash...)' >&2; exit 1; }
for cmd in php python3 systemctl mount umount findmnt runuser; do
  command -v "$cmd" >/dev/null || { echo "[ERROR] Missing command: $cmd" >&2; exit 1; }
done
[[ -r /etc/hyper-cs16/panel.php ]] || { echo '[ERROR] HYPER-HOST CS1.6 panel config missing' >&2; exit 1; }
DOMAIN=$(php -r '$c=require "/etc/hyper-cs16/panel.php";echo $c["domain"]??"";')
[[ $DOMAIN =~ ^[A-Za-z0-9.-]+$ ]] || { echo '[ERROR] Unsafe panel domain' >&2; exit 1; }
WEB="/var/www/hyper-host-sites/$DOMAIN/public_html"
CONTROLLER=/usr/local/sbin/hyper-cs2-ctl
PANEL="$WEB/cs2.php"
[[ -f $CONTROLLER && ! -L $CONTROLLER ]] || { echo '[ERROR] CS2 controller missing / symlink' >&2; exit 1; }
[[ -f $PANEL && ! -L $PANEL ]] || { echo '[ERROR] CS2 PHP page missing / symlink' >&2; exit 1; }
[[ -d /srv/hyper-cs2/base && ! -L /srv/hyper-cs2/base ]] || { echo '[ERROR] CS2 base missing / symlink' >&2; exit 1; }
[[ -d /srv/hyper-cs2/servers && ! -L /srv/hyper-cs2/servers ]] || { echo '[ERROR] CS2 server directory missing / symlink' >&2; exit 1; }
grep -q 'def installed_maps' "$CONTROLLER" || { echo '[ERROR] Install CS2 fix v2 before v3' >&2; exit 1; }
grep -q 'CS2 module v2\|CS2 module v3' "$PANEL" || { echo '[ERROR] Expected CS2 v2/v3 panel; refusing to overwrite unknown version' >&2; exit 1; }
grep -qw overlay /proc/filesystems || { echo '[ERROR] Linux kernel OverlayFS is unavailable. No changes applied.' >&2; exit 1; }
BASE_FSTYPE=$(stat -f -c %T /srv/hyper-cs2/servers)
if [[ $BASE_FSTYPE == nfs* || $BASE_FSTYPE == fuseblk ]]; then
  echo "[ERROR] /srv/hyper-cs2/servers filesystem $BASE_FSTYPE is unsuitable for OverlayFS upperdir" >&2
  exit 1
fi
if systemctl list-units --all --no-legend 'hyper-cs2-install@*.service' | grep -Eq '[[:space:]](activating|active)[[:space:]]'; then
  echo '[ERROR] CS2 instance provisioning is currently running. Apply v3 after it finishes.' >&2
  exit 1
fi
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/hyper-cs2-shared-v3-$STAMP"
mkdir -p "$BACKUP"
cp -a "$CONTROLLER" "$BACKUP/hyper-cs2-ctl"
cp -a "$PANEL" "$BACKUP/cs2.php"
cp -a /etc/systemd/system/hyper-cs2@.service "$BACKUP/hyper-cs2@.service"
if [[ -f /etc/systemd/system/hyper-cs2-base-update.service ]]; then
  cp -a /etc/systemd/system/hyper-cs2-base-update.service "$BACKUP/hyper-cs2-base-update.service"
fi
TMP=$(mktemp -d /tmp/hyper-cs2-shared-v3.XXXXXXXX)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/hyper-cs2-ctl" <<'HYPER_CS2_SHARED_CONTROLLER_V3'
#!/usr/bin/env python3
"""HYPER-HOST CS2 controller: root only, JSON output, no shell=True."""
import argparse, contextlib, fcntl, json, os, pathlib, pwd, re, shutil, socket, struct, subprocess, sys, tempfile, time
ROOT=pathlib.Path('/srv/hyper-cs2')
BASE=ROOT/'base'
SERVERS=ROOT/'servers'
STATE=pathlib.Path('/var/lib/hyper-cs2/servers')
STEAMCMD=pathlib.Path('/opt/hyper-cs2/steamcmd/steamcmd.sh')
MAP_RE=re.compile(r'^[A-Za-z0-9_]{1,64}$')
MODES={'competitive':(0,1),'casual':(0,0),'deathmatch':(1,2),'wingman':(0,2)}
LOCKFILE=pathlib.Path('/run/lock/hyper-cs2-shared.lock')

def fail(msg): raise RuntimeError(str(msg))
def output(data): print(json.dumps(data,ensure_ascii=False,default=str))
def cp(args,check=True,timeout=None,**kwargs):
    p=subprocess.run([str(x) for x in args],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout,**kwargs)
    if check and p.returncode: fail((p.stdout or '').strip()[-3000:] or f'command failed: {args[0]}')
    return p

def ident(s):
    try: n=int(s)
    except (TypeError,ValueError): fail('Invalid ID')
    if n<1 or n>9999: fail('Invalid ID range')
    return n

def cfgpath(i): return STATE/f'{i}.json'
def load(i):
    p=cfgpath(i)
    if not p.is_file(): fail(f'CS2 server #{i} not found')
    obj=json.loads(p.read_text())
    if obj.get('id')!=i: fail('Corrupted server ID')
    return obj

def save(c):
    STATE.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=STATE,prefix='.cs2-',suffix='.tmp')
    try:
        with os.fdopen(fd,'w') as f:
            json.dump(c,f,indent=2,ensure_ascii=False);f.write('\n');f.flush();os.fsync(f.fileno())
        os.chmod(tmp,0o600)
        os.replace(tmp,cfgpath(c['id']))
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def gamepath(i): return SERVERS/str(i)
def unit(i): return f'hyper-cs2@{i}.service'
def installunit(i): return f'hyper-cs2-install@{i}.service'
def updateunit(i): return f'hyper-cs2-update@{i}.service'
def user(i): return f'cs2s{i}'
def validate_field(s,length=150):
    if not isinstance(s,str) or not s.strip() or len(s)>length or any(ord(x)<32 for x in s) or '"' in s or '\\' in s: fail('Invalid text field')
    return s.strip()
def validate_map(s, root=BASE):
    if not isinstance(s,str) or not MAP_RE.fullmatch(s): fail('Invalid CS2 map name')
    if s not in installed_maps(root): fail(f'CS2 map {s} not present in installed CS2 build')
    return s

def check_port(port,own=None):
    if not 27015<=port<=27200: fail('Port must be 27015..27200')
    for root in (STATE,pathlib.Path('/var/lib/hyper-cs16/servers'),pathlib.Path('/etc/hyper-cs16/servers')):
        if root.exists():
            for p in root.glob('*.json'):
                try:
                    d=json.loads(p.read_text())
                    if root==STATE and own is not None and d.get('id')==own: continue
                    if int(d.get('port',-1))==port: fail(f'Port {port} is already assigned')
                except (ValueError,KeyError,json.JSONDecodeError,PermissionError): continue
    # Bind test on both UDP and TCP; own running port is exempt for config changes.
    if own is None or int(load(own).get('port',0))!=port:
        for typ in (socket.SOCK_DGRAM,socket.SOCK_STREAM):
            s=socket.socket(socket.AF_INET,typ)
            try: s.bind(('0.0.0.0',port))
            except OSError: fail(f'Port {port} is already bound')
            finally: s.close()

def installed_maps(root=BASE):
    # Real Source 2 map packages, NOT CS 1.6 .bsp maps or a hardcoded list.
    directory=root/'game/csgo/maps'
    try:
        return sorted({p.stem for p in directory.glob('*.vpk')
                       if p.is_file() and MAP_RE.fullmatch(p.stem)},key=str.casefold)
    except OSError:
        return []

def base_files():
    return {
        'binary':(BASE/'game/bin/linuxsteamrt64/cs2').is_file(),
        'launcher':(BASE/'game/cs2.sh').is_file(),
        'assets':(BASE/'game/csgo/pak01_dir.vpk').is_file(),
        'maps_count':len(installed_maps(BASE))
    }

def base_ready():
    files=base_files()
    return bool(files['binary'] and files['launcher'] and files['assets'] and files['maps_count'])

def base_status():
    files=base_files();files_ready=base_ready()
    p=cp(['systemctl','is-active','hyper-cs2-base-install.service'],check=False,timeout=5)
    service=p.stdout.strip()
    upgrading=systemd_active('hyper-cs2-base-update.service')
    installing=service in ('active','activating') or upgrading
    ready=bool(files_ready and not installing and service!='failed')
    state='installing' if installing else ('ready' if ready else ('failed' if service=='failed' else 'missing'))
    details={'state':state,'ready':ready,'service':service,'path':str(BASE),**files}
    if state=='failed':
        logs=cp(['journalctl','-u','hyper-cs2-base-install.service','--no-pager','-n','25','-o','cat'],check=False,timeout=6)
        details['last_error']=(logs.stdout or '')[-1900:]
    return details

def base_start():
    if all_shared() and not base_busy(): fail('Shared instances exist. Use base-update for coordinated update; do not run base-start')
    if base_usable(): return output({'ok':True,'state':'ready','message':'CS2 game files already installed'})
    cur=base_status()
    if cur['state']=='installing': return output({'ok':True,'state':'installing','message':'Base download already running'})
    cp(['systemctl','reset-failed','hyper-cs2-base-install.service'],check=False)
    p=cp(['systemctl','start','--no-block','hyper-cs2-base-install.service'],check=False,timeout=15)
    if p.returncode: fail('Cannot start CS2 download: '+p.stdout[-1200:])
    output({'ok':True,'state':'installing','message':'CS2 SteamCMD installation started'})

def prepare_sdk(home,steamroot):
    dest=home/'.steam/sdk64'
    dest.mkdir(parents=True,exist_ok=True)
    target=steamroot/'linux64/steamclient.so'
    if target.is_file():
        link=dest/'steamclient.so'
        if link.is_symlink() or link.is_file(): link.unlink()
        link.symlink_to(target)

def steam_update(root,steamroot,uname):
    # SteamCMD's HOME, logs, cache, cwd and game directory MUST all be writable.
    cmd=steamroot/'steamcmd.sh'
    if not cmd.is_file(): fail(f'SteamCMD not installed: {cmd}')
    home=pathlib.Path(pwd.getpwnam(uname).pw_dir)
    for path in (home,home/'Steam',home/'.steam',home/'.cache',steamroot,root):
        path.mkdir(parents=True,exist_ok=True)
        if path.is_symlink(): fail('Unsafe SteamCMD directory symlink: '+str(path))
        if not os.access(path,os.W_OK):
            # Root can access directories even if the SteamCMD service user cannot.
            pass
        shutil.chown(path,user=uname)
    # Run a write probe AS the SteamCMD user before downloading dozens of GiB.
    probe=cp(['runuser','-u',uname,'--','/usr/bin/env',f'HOME={home}',
              '/usr/bin/python3','-c',
              'from pathlib import Path; import sys; p=Path(sys.argv[1]); p.write_text("ok"); p.unlink()',
              str(home/'Steam'/'.hyper-cs2-writecheck')],check=False,timeout=15,cwd=str(steamroot))
    if probe.returncode: fail('SteamCMD HOME not writable by '+uname+': '+probe.stdout[-1000:])
    env=dict(os.environ,HOME=str(home),USER=uname,LOGNAME=uname,
             XDG_CACHE_HOME=str(home/'.cache'))
    args=['runuser','-u',uname,'--','/usr/bin/env',f'HOME={home}',f'USER={uname}',
          f'LOGNAME={uname}',f'XDG_CACHE_HOME={home/".cache"}',str(cmd),
          '+force_install_dir',str(root),'+login','anonymous','+app_update','730','validate','+quit']
    p=cp(args,check=False,timeout=14400,env=env,cwd=str(steamroot))
    if p.returncode: fail('SteamCMD failed: '+(p.stdout or '')[-4000:])
    if not (root/'game/bin/linuxsteamrt64/cs2').is_file(): fail('SteamCMD completed but CS2 executable missing')
    prepare_sdk(home,steamroot)

def base_install():
    if all_shared(): fail('Shared CS2 instances exist: use base-update to stop/unmount instances safely')
    with base_lock(shared=False):
        return _base_install_unlocked()

def _base_install_unlocked():
    BASE.mkdir(parents=True,exist_ok=True)
    if not base_ready():
        free=shutil.disk_usage(str(BASE)).free
        # A partially downloaded Steam depot may be resumed without requiring
        # another full 70 GiB on top of the data already on disk.
        partial=any(BASE.iterdir())
        min_free=(10 if partial else 70)*1024**3
        if free < min_free:
            fail(f'Insufficient free disk: {free//1024**3} GiB. CS2 needs about 70 GiB for a new installation.')
    home=pathlib.Path(pwd.getpwnam('cs2build').pw_dir)
    # Fix v1: Steam logs /opt/hyper-cs2/Steam were owned by root.
    # This directory is dedicated to the cs2build user and contains SteamCMD only.
    for folder in (home,BASE):
        if folder.is_symlink(): fail('Unsafe CS2 directory symlink: '+str(folder))
    cp(['chown','-R','cs2build:cs2build',str(home),str(BASE)],timeout=3600)
    steam_update(BASE,STEAMCMD.parent,'cs2build')
    if not base_ready(): fail('SteamCMD finished but CS2 build is incomplete: '+json.dumps(base_files()))
    output({'ok':True,'base':str(BASE),'maps':len(installed_maps(BASE)),
            'message':'CS2 base installed (Steam App 730)'})

# One Steam installation, separate writable OverlayFS layers per server.
# Running SteamCMD against BASE while an overlay is mounted is UNSAFE.
@contextlib.contextmanager
def base_lock(shared=True, blocking=True):
    LOCKFILE.parent.mkdir(parents=True,exist_ok=True)
    fd=os.open(str(LOCKFILE),os.O_CREAT|os.O_RDWR|os.O_CLOEXEC,0o600)
    flags=fcntl.LOCK_SH if shared else fcntl.LOCK_EX
    if not blocking: flags |= fcntl.LOCK_NB
    try:
        try: fcntl.flock(fd,flags)
        except BlockingIOError: fail('Another CS2 base operation is in progress')
        yield
    finally:
        os.close(fd)

def systemd_active(name):
    return cp(['systemctl','is-active',name],check=False,timeout=8).stdout.strip() in ('active','activating')

def base_busy():
    return systemd_active('hyper-cs2-base-install.service') or systemd_active('hyper-cs2-base-update.service')

def base_usable():
    return base_ready() and not base_busy()

def storage_mode(c):
    return c.get('storage','legacy-copy')

def all_shared():
    found=[]
    for entry in STATE.glob('*.json'):
        if not entry.stem.isdecimal(): continue
        try:
            c=load(ident(entry.stem))
            if storage_mode(c)=='overlay': found.append(c)
        except Exception: pass
    return sorted(found,key=lambda d:d['id'])

def overlay_paths(i):
    root=gamepath(i)
    return root,root/'upper',root/'work',root/'gamefiles'

def safe_overlay_dirs(i):
    root,upper,work,merged=overlay_paths(i)
    if root.is_symlink() or not root.is_dir(): fail('Unsafe/missing instance directory')
    for part in (upper,work,merged):
        if part.is_symlink(): fail('Unsafe symlink in OverlayFS instance')
        if not part.is_dir(): fail('OverlayFS instance directory missing: '+str(part))
    return root,upper,work,merged

def mounted(i):
    _,_,_,merged=overlay_paths(i)
    return os.path.ismount(str(merged))

def mount_overlay_unlocked(i):
    c=load(i)
    if storage_mode(c)!='overlay': return
    if not base_ready(): fail('Common CS2 base is not ready')
    _,upper,work,merged=safe_overlay_dirs(i)
    if mounted(i):
        t=cp(['findmnt','-n','-M',str(merged),'-o','FSTYPE'],check=False,timeout=8).stdout.strip()
        if t!='overlay': fail('Unexpected mount at '+str(merged))
        return
    options=f'lowerdir={BASE},upperdir={upper},workdir={work},index=off,metacopy=off,redirect_dir=off,xino=off'
    cp(['mount','-t','overlay','overlay','-o',options,str(merged)],timeout=25)
    if not mounted(i): fail('OverlayFS mount not active after mount call')

def mount_overlay(i):
    if storage_mode(load(i))!='overlay': return output({'ok':True,'storage':'legacy-copy'})
    with base_lock(shared=True): mount_overlay_unlocked(i)
    output({'ok':True,'storage':'overlay','mounted':True,'id':i})

def unmount_overlay_unlocked(i):
    if storage_mode(load(i))!='overlay': return
    if mounted(i):
        cp(['umount',str(overlay_paths(i)[-1])],timeout=60)
    if mounted(i): fail(f'CS2 #{i} overlay still mounted; refusing to change common base')

def writable_instance_dirs(i):
    """Copy up directory metadata only; don't chown game assets recursively."""
    c=load(i)
    if storage_mode(c)!='overlay': return
    root,_,_,merged=safe_overlay_dirs(i)
    uid=pwd.getpwnam(user(i)).pw_uid;gid=pwd.getpwnam(user(i)).pw_gid
    for rel in ('game','game/csgo','game/csgo/cfg','game/csgo/addons',
                'game/csgo/logs','game/csgo/maps'):
        dest=merged/rel
        if dest.is_symlink(): fail('Unsafe writable CS2 game path: '+str(dest))
        dest.mkdir(parents=True,exist_ok=True)
        os.chown(dest,uid,gid)
    for x in (root/'.steam',root/'.steam/sdk64'):
        if x.exists(): os.chown(x,uid,gid)

def provision_shared(i):
    c=load(i)
    if storage_mode(c)!='overlay': fail('Not a shared server')
    with base_lock(shared=True):
        if base_busy(): fail('CS2 base is still installing/updating')
        if not base_ready(): fail('CS2 base is not ready')
        root=gamepath(i)
        if root.exists(): fail('Instance folder exists: inspect before retry')
        try:
            root.mkdir(parents=True,mode=0o755)
            uname=user(i)
            try: pwd.getpwnam(uname)
            except KeyError:
                cp(['useradd','--system','--user-group','--home-dir',str(root),
                    '--no-create-home','--shell','/usr/sbin/nologin',uname])
            account=pwd.getpwnam(uname)
            for folder in ('upper','work','gamefiles'):
                (root/folder).mkdir(mode=0o700 if folder!='gamefiles' else 0o755)
            for folder in ('.steam','.cache','.local','Steam'):
                d=root/folder;d.mkdir(mode=0o750)
                os.chown(d,account.pw_uid,account.pw_gid)
            mount_overlay_unlocked(i)
            prepare_sdk(root,STEAMCMD.parent)
            writable_instance_dirs(i)
            write_config(c)
            if not (root/'gamefiles/game/bin/linuxsteamrt64/cs2').is_file():
                fail('Common CS2 binary missing in instance overlay')
            c['state']='ready';c['error']='';save(c)
            cp(['systemctl','enable',unit(i)])
            # Startup triggers ExecStartPre mount (which is already active).
            cp(['systemctl','start','--no-block',unit(i)],timeout=15)
            output({'ok':True,'id':i,'state':'ready','storage':'overlay','base':str(BASE)})
        except Exception as ex:
            c['state']='failed';c['error']=str(ex)[-1600:];save(c)
            raise

def base_update_all():
    # Planned maintenance: stop every shared process and unmount before touching LOWER.
    if systemd_active('hyper-cs2-base-install.service'):
        fail('Initial CS2 SteamCMD download is running; do not interrupt it')
    stopped=[]
    with base_lock(shared=False,blocking=False):
        instances=all_shared()
        for c in instances:
            i=c['id']
            if systemd_active(unit(i)):
                cp(['systemctl','stop',unit(i)],timeout=100)
                stopped.append(i)
        for c in instances: unmount_overlay_unlocked(c['id'])
        # No active OverlayFS lowerdir references may remain.
        if any(mounted(c['id']) for c in instances): fail('A CS2 overlay is still mounted')
        steam_update(BASE,STEAMCMD.parent,'cs2build')
        if not base_ready(): fail('Updated CS2 base lacks game binary/maps/assets')
        for c in instances:
            mount_overlay_unlocked(c['id'])
            writable_instance_dirs(c['id'])
            # Their own upper layer preserves cfg, addons and logs.
    failures=[]
    for i in stopped:
        r=cp(['systemctl','start',unit(i)],check=False,timeout=100)
        if r.returncode: failures.append(f'#{i}: '+r.stdout[-500:])
    if failures: fail('Base updated but some servers could not restart: '+'; '.join(failures))
    output({'ok':True,'updated':True,'shared_instances':len(instances),'restarted':stopped})

def config_lines(c):
    def val(x): return str(x).replace('\\','').replace('"','').replace('\r',' ').replace('\n',' ')
    rows=['// HYPER-HOST CS2 | server.cfg',f'hostname "{val(c["hostname"])}"',f'rcon_password "{val(c["rcon"])}"',f'sv_password "{val(c.get("password",""))}"',
          f'sv_visiblemaxplayers {int(c["slots"])}','sv_lan 0','sv_cheats 0','log on']
    if c.get('token'): rows.append(f'sv_setsteamaccount {val(c["token"])}')
    return '\n'.join(rows)+'\n'

def write_config(c):
    root=gamepath(c['id'])
    cfgdir=root/'gamefiles/game/csgo/cfg'
    cfgdir.mkdir(parents=True,exist_ok=True)
    cfg=cfgdir/'server.cfg'
    cfg.write_text(config_lines(c),encoding='utf-8')
    mode=MODES[c['mode']]
    launch={'id':c['id'],'port':c['port'],'slots':c['slots'],'map':c['map'],'game_type':mode[0],'game_mode':mode[1]}
    p=root/'run.json'
    p.write_text(json.dumps(launch)+'\n')
    os.chmod(p,0o640);os.chmod(cfg,0o640)
    os.chown(p,0,pwd.getpwnam(user(c['id'])).pw_gid)
    os.chown(cfg,pwd.getpwnam(user(c['id'])).pw_uid,pwd.getpwnam(user(c['id'])).pw_gid)

def create(i,data):
    if cfgpath(i).exists() or gamepath(i).exists(): fail('CS2 server ID already exists')
    if not base_usable(): fail('CS2 base is incomplete or SteamCMD is running. Wait until installation finishes')
    port=int(data['port']);slots=int(data['slots'])
    if not 2<=slots<=32: fail('Slots must be 2..32')
    check_port(port)
    name=validate_field(data.get('name',''),96);hostname=validate_field(data.get('hostname',''),160)
    mp=validate_map(data.get('map','de_dust2'),BASE)
    mode=data.get('mode','competitive')
    if mode not in MODES: fail('Unknown CS2 mode')
    for key,limit in [('password',80),('rcon',80),('token',128)]:
        value=str(data.get(key,'')).strip()
        if len(value)>limit or not re.fullmatch(r'[A-Za-z0-9._!@#%+^?=-]*',value): fail('Invalid '+key)
    if not data.get('rcon'): fail('RCON password is required')
    c={'id':i,'name':name,'hostname':hostname,'port':port,'slots':slots,'map':mp,'mode':mode,
       'password':str(data.get('password','')),'rcon':str(data['rcon']),'token':str(data.get('token','')),
       'state':'installing','error':'','created_at':int(time.time()),'storage':'overlay'}
    save(c)
    p=cp(['systemctl','start','--no-block',installunit(i)],check=False)
    if p.returncode:
        c['state']='failed';c['error']=p.stdout.strip()[-2000:];save(c)
        fail(c['error'])
    output({'ok':True,'id':i,'state':'installing','detail':'Provisioning started in systemd'})

def provision(i):
    c=load(i)
    if storage_mode(c)=='overlay': return provision_shared(i)
    if not base_ready(): fail('Base files not ready')
    root=gamepath(i)
    if root.exists(): fail('Partial server directory already exists; manual inspection required')
    try:
        root.mkdir(mode=0o750,parents=True)
        if not shutil.which('cp'): fail('cp required')
        # cp -a --reflink=auto SOURCE/. DEST creates an independent installation (CoW where supported).
        base_bytes=sum(p.stat().st_size for p in BASE.rglob('*') if p.is_file() and not p.is_symlink())
        if shutil.disk_usage(str(SERVERS)).free < base_bytes + 3*1024**3:
            fail('Not enough disk space to create an independent CS2 server copy')
        (root/'gamefiles').mkdir()
        cp(['cp','-a','--reflink=auto',str(BASE)+'/.',str(root/'gamefiles')],timeout=7200)
        shutil.copytree(STEAMCMD.parent,root/'.steamcmd',symlinks=True)
        uname=user(i)
        if not any(u.pw_name==uname for u in pwd.getpwall()):
            cp(['useradd','--system','--user-group','--home-dir',str(root),'--no-create-home','--shell','/usr/sbin/nologin',uname])
        # chown huge game tree; ownership can't remain cs2build for independent Steam updates.
        cp(['chown','-R',f'{uname}:{uname}',str(root)],timeout=3600)
        prepare_sdk(root,root/'.steamcmd')
        write_config(c)
        # Check launch script format after copying.
        if not (root/'gamefiles/game/bin/linuxsteamrt64/cs2').is_file(): fail('CS2 binary missing in cloned instance')
        c['state']='ready';c['error']='';save(c)
        cp(['systemctl','daemon-reload'])
        cp(['systemctl','enable',unit(i)])
        cp(['systemctl','start',unit(i)])
        output({'ok':True,'id':i,'state':'ready'})
    except Exception as exc:
        c['state']='failed';c['error']=str(exc)[-1600:];save(c)
        raise

def update(i):
    c=load(i);root=gamepath(i);uname=user(i)
    if storage_mode(c)=='overlay':
        return base_update_all()
    if c['state'] not in ('ready','updating'): fail('Server not provisioned')
    c['state']='updating';save(c)
    active=cp(['systemctl','is-active',unit(i)],check=False).stdout.strip()=='active'
    try:
        cp(['systemctl','stop',unit(i)],check=False)
        steam_update(root/'gamefiles',root/'.steamcmd',uname)
        write_config(c)
        c['state']='ready';c['error']='';save(c)
        if active: cp(['systemctl','start',unit(i)])
        output({'ok':True,'id':i,'updated':True})
    except Exception as exc:
        c['state']='failed';c['error']='Update: '+str(exc)[-1500:];save(c)
        raise

def a2s_info(port):
    """Read vanilla Source2 A2S_INFO (including optional challenge)."""
    query=b'\xff\xff\xff\xffTSource Engine Query\x00'
    try:
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
            s.settimeout(0.65)
            s.sendto(query,('127.0.0.1',port))
            data,_=s.recvfrom(4096)
            if data[:5]==b'\xff\xff\xff\xffA' and len(data)>=9:
                s.sendto(query+data[5:9],('127.0.0.1',port))
                data,_=s.recvfrom(4096)
        if data[:5]!=b'\xff\xff\xff\xffI': return {}
        pos=6
        fields=[]
        for _ in range(4):
            end=data.index(b'\0',pos)
            fields.append(data[pos:end].decode('utf8','replace'))
            pos=end+1
        if len(data)<pos+5: return {}
        appid,players,maximum,bots=struct.unpack_from('<HBBB',data,pos)
        return {'query_ok':True,'current_map':fields[1],'players':players,'max_players':maximum,'bots':bots,'appid':appid}
    except (OSError,ValueError,IndexError,struct.error): return {}

def current_status(c):
    i=c['id'];root=gamepath(i)
    p=cp(['systemctl','is-active',unit(i)],check=False)
    service=p.stdout.strip()
    pidtext=cp(['systemctl','show',unit(i),'-p','MainPID','--value'],check=False).stdout.strip()
    pid=int(pidtext) if pidtext.isdigit() else 0
    cpu=mem=0.0;uptime=0
    if pid>0:
        raw=cp(['ps','-p',str(pid),'-o','%cpu=,rss=,etimes='],check=False).stdout.split()
        if len(raw)==3:
            try: cpu=round(float(raw[0]),1);mem=round(float(raw[1])/1024,1);uptime=int(raw[2])
            except ValueError: pass
    query=a2s_info(int(c['port'])) if service=='active' else {}
    return {'id':i,'name':c['name'],'hostname':c['hostname'],'port':c['port'],'slots':c['slots'],
            'storage':storage_mode(c),'overlay_mounted':mounted(i) if storage_mode(c)=='overlay' else False,
            'map':c['map'],'mode':c['mode'],**query,'token_set':bool(c.get('token')),'state':c['state'],
            'service':service,'running':service=='active','cpu':cpu,'ram_mb':mem,'uptime':uptime,
            'error':c.get('error',''),'path':str(root)}

def list_servers():
    result=[]
    for path in sorted(STATE.glob('*.json')):
        try: result.append(current_status(load(ident(path.stem))))
        except Exception: pass
    base=base_status()
    output({'ok':True,'servers':result,'base_ready':base['ready'],
            'shared_storage':True,'base':base,'maps':installed_maps(BASE) if base['ready'] else []})

def cfg_set(i,d):
    c=load(i)
    if c['state'] not in ('ready','updating'): fail('Server not ready')
    port=int(d.get('port',c['port'])); slots=int(d.get('slots',c['slots']))
    if not 2<=slots<=32: fail('Slots must be 2..32')
    check_port(port,own=i)
    for key,lim in [('hostname',160),('name',96)]:
        if key in d: c[key]=validate_field(d[key],lim)
    if storage_mode(c)=='overlay':
        with base_lock(shared=True):
            if base_busy(): fail('CS2 base is installing/updating')
            mount_overlay_unlocked(i)
    if 'map' in d: c['map']=validate_map(d['map'],BASE if storage_mode(c)=='overlay' else gamepath(i)/'gamefiles')
    if 'mode' in d:
        if d['mode'] not in MODES: fail('Invalid game mode')
        c['mode']=d['mode']
    for key,lim in [('token',128),('password',80),('rcon',80)]:
        if key in d and d[key] is not None and str(d[key])!='':
            v=str(d[key]).strip()
            if len(v)>lim or not re.fullmatch(r'[A-Za-z0-9._!@#%+^?=-]*',v): fail('Invalid '+key)
            c[key]=v
    c['port']=port;c['slots']=slots
    save(c);write_config(c)
    output({'ok':True,'id':i,'restart_required':True})

def rcon(i,command):
    c=load(i)
    if len(command)>300 or not command.strip() or any(ord(k)<32 for k in command): fail('Invalid RCON command')
    secret=c['rcon'].encode();requestid=1549
    def pkt(kind,payload):
        data=struct.pack('<ii',requestid,kind)+payload+b'\0\0'
        return struct.pack('<i',len(data))+data
    def recv(sock):
        head=sock.recv(4)
        if len(head)!=4: fail('RCON connection closed')
        length=struct.unpack('<i',head)[0]
        if length<10 or length>1024*1024: fail('Invalid RCON response')
        data=b''
        while len(data)<length:
            chunk=sock.recv(length-len(data))
            if not chunk: fail('RCON response truncated')
            data+=chunk
        return struct.unpack('<ii',data[:8]),data[8:-2]
    with socket.create_connection(('127.0.0.1',int(c['port'])),timeout=3.0) as sock:
        sock.settimeout(3.0)
        sock.sendall(pkt(3,secret)); header,_=recv(sock)
        if header[0]==-1: fail('RCON authorization failed')
        # Source RCON can return auth prelude type 0 followed by 2.
        if header[1]==0:
            header,_=recv(sock)
        if header[0]==-1: fail('RCON authorization failed')
        sock.sendall(pkt(2,command.encode('utf-8')))
        parts=[]
        for n in range(3):
            try:
                meta,body=recv(sock)
                if meta[0]==requestid: parts.append(body)
                if len(body)<4096: break
            except socket.timeout: break
    output({'ok':True,'output':b''.join(parts).decode('utf-8','replace')[:12000]})

def config_get(i):
    c=load(i)
    if storage_mode(c)=='overlay':
        with base_lock(shared=True):
            if base_busy(): fail('CS2 shared base updating')
            mount_overlay_unlocked(i)
    p=gamepath(i)/'gamefiles/game/csgo/cfg/server.cfg'
    body=p.read_text(errors='replace') if p.is_file() else ''
    redacted='\n'.join('// [SECRET REDACTED] '+ln.split()[0] if re.match(r'^\s*(sv_setsteamaccount|rcon_password|sv_password)\b',ln,re.I) else ln for ln in body.splitlines())
    output({'ok':True,'text':redacted})

def config_save(i,body):
    c=load(i)
    if storage_mode(c)=='overlay':
        with base_lock(shared=True):
            if base_busy(): fail('CS2 shared base updating')
            mount_overlay_unlocked(i)
    root=gamepath(i)/'gamefiles/game/csgo/cfg';p=root/'server.cfg'
    if len(body)>32768 or '\0' in body or '\r' in body: fail('Invalid cfg size/content')
    # Keep GSLT/RCON configuration under controller ownership, not arbitrary web input.
    forbidden=re.compile(r'^\s*(sv_setsteamaccount|rcon_password|sv_password)\b',re.I)
    lines=[ln for ln in body.splitlines() if not forbidden.search(ln)]
    lines=[ln for ln in lines if not re.match(r'^\s*exec\b',ln,re.I)]
    controlled=[ln for ln in config_lines(c).splitlines() if re.match(r'^(sv_setsteamaccount|rcon_password|sv_password)\b',ln)]
    p.write_text('\n'.join(controlled+lines)+'\n',encoding='utf-8')
    shutil.chown(p,user=user(i),group=user(i))
    output({'ok':True,'restart_required':True})

def deletion(i):
    c=load(i)
    for target in (installunit(i),updateunit(i),unit(i)):
        cp(['systemctl','stop',target],check=False,timeout=120)
    cp(['systemctl','disable',unit(i)],check=False)
    root=gamepath(i)
    if storage_mode(c)=='overlay':
        with base_lock(shared=True):
            unmount_overlay_unlocked(i)
    # Never follow symlinks or delete outside the dedicated CS2 server root.
    if root.is_symlink(): fail('Unsafe symlink server dir')
    if root.is_dir(): shutil.rmtree(root)
    cfgpath(i).unlink(missing_ok=True)
    cp(['userdel',user(i)],check=False)
    cp(['systemctl','reset-failed',unit(i)],check=False)
    output({'ok':True,'deleted':i})

def main():
    if os.geteuid()!=0: fail('root required')
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['doctor','base-install','base-start','base-status','base-update','_mount','maps','list','status','create','_provision','start','stop','restart','update','_update','settings','config-get','config-save','rcon','delete','logs'])
    parser.add_argument('id',nargs='?')
    a=parser.parse_args();act=a.action
    if act=='doctor':
        usage=shutil.disk_usage(str(ROOT));home=pathlib.Path(pwd.getpwnam('cs2build').pw_dir)
        output({'ok':True,'base_ready':base_status()['ready'],'shared_storage':True,'steamcmd':STEAMCMD.is_file(),
                'free_gb':round(usage.free/1024**3,1),
                'server_count':len(list(STATE.glob('*.json'))),
                'base':base_status(),'steam_home':str(home),
                'steam_home_owner':pwd.getpwuid(home.stat().st_uid).pw_name if home.exists() else 'missing'})
        return
    if act=='base-install': return base_install()
    if act=='base-update': return base_update_all()
    if act=='base-start': return base_start()
    if act=='base-status': return output({'ok':True,**base_status()})
    if act=='maps': return output({'ok':True,'maps':installed_maps(BASE) if base_usable() else [],'base_ready':base_usable()})
    if act=='list': return list_servers()
    if not a.id: fail('server ID required')
    i=ident(a.id)
    if act=='create':
        raw=sys.stdin.read(4096)
        return create(i,json.loads(raw))
    if act=='_provision': return provision(i)
    if act=='_update': return update(i)
    c=load(i)
    if act=='_mount': return mount_overlay(i)
    if act=='status': return output({'ok':True,**current_status(c)})
    if act in ('start','stop','restart'):
        if c['state']!='ready': fail('Server is not ready: '+c['state'])
        if storage_mode(c)=='overlay' and not base_usable(): fail('CS2 base currently installing/updating')
        p=cp(['systemctl',act,unit(i)],check=False,timeout=90)
        if p.returncode: fail(p.stdout[-3000:])
        return output({'ok':True,'action':act,**current_status(c)})
    if act=='update':
        if c['state']!='ready': fail('Server not ready')
        if storage_mode(c)=='overlay':
            if base_busy(): fail('CS2 common base installation/update is already running')
            p=cp(['systemctl','start','--no-block','hyper-cs2-base-update.service'],check=False,timeout=15)
            if p.returncode: fail(p.stdout[-1500:])
            return output({'ok':True,'state':'updating','scope':'all-shared','id':i})
        p=cp(['systemctl','start','--no-block',updateunit(i)],check=False)
        if p.returncode: fail(p.stdout)
        return output({'ok':True,'state':'updating','id':i})
    if act in ('settings','config-get','config-save','delete'):
        with base_lock(shared=True,blocking=False):
            if act=='settings': return cfg_set(i,json.loads(sys.stdin.read(4096)))
            if act=='config-get': return config_get(i)
            if act=='config-save': return config_save(i,sys.stdin.read(32769))
            if act=='delete': return deletion(i)
    if act=='rcon': return rcon(i,sys.stdin.read(320).strip())
    if act=='logs':
        p=cp(['journalctl','-u',unit(i),'-n','100','--no-pager','-o','cat'],check=False,timeout=15)
        output({'ok':True,'logs':p.stdout[-15000:]})
        return
if __name__=='__main__':
    try: main()
    except Exception as ex:
        output({'ok':False,'error':str(ex)[-3000:]});sys.exit(1)

HYPER_CS2_SHARED_CONTROLLER_V3

cat > "$TMP/cs2.php" <<'HYPER_CS2_SHARED_PHP_V3'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$user=require_auth();
function cs2ctl(array $args,?string $input=null,int $timeout=60):array {
    $cmd=['sudo','-n','/usr/local/sbin/hyper-cs2-ctl'];
    foreach($args as $a)$cmd[]=(string)$a;
    $command=implode(' ',array_map('escapeshellarg',$cmd));
    $p=proc_open($command,[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes,null,['PATH'=>'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']);
    if(!is_resource($p))return ['ok'=>false,'error'=>'Cannot start CS2 controller'];
    fwrite($pipes[0],$input??'');fclose($pipes[0]);
    stream_set_blocking($pipes[1],false);stream_set_blocking($pipes[2],false);
    $start=microtime(true);$out='';$err='';$timed=false;
    do{$st=proc_get_status($p);$out.=stream_get_contents($pipes[1]);$err.=stream_get_contents($pipes[2]);if(!$st['running'])break;if(microtime(true)-$start>$timeout){proc_terminate($p);$timed=true;break;}usleep(40000);}while(true);
    $out.=stream_get_contents($pipes[1]);$err.=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);proc_close($p);
    $j=json_decode(trim($out),true);
    return is_array($j)?$j:['ok'=>false,'error'=>$timed?'Controller timed out':(trim($err)?:trim($out)?:'Unknown error')];
}
function cs2row(int $id):array{
    $st=db()->prepare('SELECT * FROM cs2_servers WHERE id=?');$st->execute([$id]);$r=$st->fetch();
    if(!$r){flash('Сервер CS2 #'.$id.' не найден. Возможно, его создание ранее завершилось ошибкой.','warning');redirect(cs2url());}
    global $user;
    if(!in_array($user['role'],['owner','admin'],true)&&(int)$r['owner_user_id']!==(int)$user['id']){http_response_code(403);exit('Access denied');}
    return $r;
}
function cs2url(int $id=0):string{return '/cs2.php'.($id?'?id='.$id:'');}
if($_SERVER['REQUEST_METHOD']==='POST'){
    check_csrf();$action=(string)($_POST['action']??'');$id=(int)($_POST['id']??0);
    try{
        if($action==='install_base'){
            require_perm('servers.create');
            $r=cs2ctl(['base-start']);
            if(empty($r['ok']))throw new RuntimeException((string)($r['error']??'SteamCMD start error'));
            flash('Скачивание CS2 (App 730) запущено. Статус появится в панели.');
            redirect(cs2url());
        }
        if($action==='create'){
            require_perm('servers.create');
            $port=(int)($_POST['port']??27101);$slots=(int)($_POST['slots']??10);
            $name=trim((string)($_POST['name']??''));$hostname=trim((string)($_POST['hostname']??''));
            $map=trim((string)($_POST['map']??'de_dust2'));$mode=(string)($_POST['mode']??'competitive');
            if($name===''||mb_strlen($name)>96||$hostname===''||mb_strlen($hostname)>160||$port<27015||$port>27200||$slots<2||$slots>32||!preg_match('/^[A-Za-z0-9_]{1,64}$/',$map)||!in_array($mode,['competitive','casual','deathmatch','wingman'],true))throw new RuntimeException('Некорректные параметры');
            $detected=cs2ctl(['maps']);
            if(empty($detected['base_ready'])||!in_array($map,$detected['maps']??[],true))throw new RuntimeException('Карта отсутствует в сборке CS2, дождись установки SteamCMD');
            $payload=['name'=>$name,'hostname'=>$hostname,'port'=>$port,'slots'=>$slots,'map'=>$map,'mode'=>$mode,
              'token'=>(string)($_POST['token']??''),'password'=>(string)($_POST['password']??''),'rcon'=>(string)($_POST['rcon']??'')];
            $pdo=db();$pdo->prepare('INSERT INTO cs2_servers(owner_user_id,name,hostname,port,slots,start_map,game_mode) VALUES(?,?,?,?,?,?,?)')->execute([(int)$user['id'],$name,$hostname,$port,$slots,$map,$mode]);
            $id=(int)$pdo->lastInsertId();
            $r=cs2ctl(['create',$id],json_encode($payload,JSON_UNESCAPED_UNICODE));
            if(empty($r['ok'])){$pdo->prepare('DELETE FROM cs2_servers WHERE id=?')->execute([$id]);throw new RuntimeException((string)($r['error']??'Installation error'));}
            audit('cs2_create','#'.$id.' '.$name);flash('Установка CS2 #'.$id.' запущена. Обнови страницу через несколько минут.');redirect(cs2url($id));
        }
        if($id<1)throw new RuntimeException('Invalid CS2 server ID');
        $row=cs2row($id);
        if($action==='power'){
            if(!can_perm('server.power') && (int)$row['owner_user_id']!==(int)$user['id'])throw new RuntimeException('Недостаточно прав');
            $op=(string)($_POST['op']??'');if(!in_array($op,['start','stop','restart'],true))throw new RuntimeException('Invalid operation');
            $r=cs2ctl([$op,$id]);
        }elseif($action==='update'){
            if(!can_perm('server.maintenance')&&(int)$row['owner_user_id']!==(int)$user['id'])throw new RuntimeException('Недостаточно прав');
            $r=cs2ctl(['update',$id]);
        }elseif($action==='settings'){
            $payload=['name'=>(string)($_POST['name']??$row['name']),'hostname'=>(string)($_POST['hostname']??$row['hostname']),
              'port'=>(int)($_POST['port']??$row['port']),'slots'=>(int)($_POST['slots']??$row['slots']),
              'map'=>(string)($_POST['map']??$row['start_map']),'mode'=>(string)($_POST['mode']??$row['game_mode'])];
            foreach(['token','password','rcon'] as $field)if(!empty($_POST[$field]))$payload[$field]=(string)$_POST[$field];
            $r=cs2ctl(['settings',$id],json_encode($payload,JSON_UNESCAPED_UNICODE));
            if(!empty($r['ok']))db()->prepare('UPDATE cs2_servers SET name=?,hostname=?,port=?,slots=?,start_map=?,game_mode=? WHERE id=?')->execute([$payload['name'],$payload['hostname'],$payload['port'],$payload['slots'],$payload['map'],$payload['mode'],$id]);
        }elseif($action==='rcon'){
            $r=cs2ctl(['rcon',$id],(string)($_POST['command']??''));
            if(!empty($r['ok']))$_SESSION['cs2_last_rcon']=(string)($r['output']??'');
        }elseif($action==='save_cfg'){
            $r=cs2ctl(['config-save',$id],(string)($_POST['config']??''));
        }elseif($action==='delete'){
            if(!can_perm('server.delete'))throw new RuntimeException('Недостаточно прав для удаления');
            if((string)($_POST['confirm']??'')!=='DELETE')throw new RuntimeException('Введи DELETE');
            $r=cs2ctl(['delete',$id],null,120);
            if(!empty($r['ok'])){db()->prepare('DELETE FROM cs2_servers WHERE id=?')->execute([$id]);audit('cs2_delete','#'.$id);flash('CS2 сервер удалён');redirect(cs2url());}
        }else throw new RuntimeException('Unknown operation');
        if(empty($r['ok']))throw new RuntimeException((string)($r['error']??'Controller error'));
        audit('cs2_'.$action,'#'.$id);
        flash($action==='rcon'?'RCON команда выполнена.':($action==='update'?'Обновление запущено.':'Операция выполнена. Для применения конфигурации при необходимости перезапусти сервер.'));
        redirect(cs2url($id));
    }catch(Throwable $ex){flash($ex->getMessage(),'danger');redirect(cs2url($action==='create'?0:($id>0?$id:0)));}
}
$all=cs2ctl(['list']);$live=[];foreach(($all['servers']??[]) as $s)$live[(int)$s['id']]=$s;
if(in_array((string)$user['role'],['owner','admin'],true))$rows=db()->query('SELECT * FROM cs2_servers ORDER BY id DESC')->fetchAll();
else{$st=db()->prepare('SELECT * FROM cs2_servers WHERE owner_user_id=? ORDER BY id DESC');$st->execute([(int)$user['id']]);$rows=$st->fetchAll();}
$id=(int)($_GET['id']??0);$row=$id?cs2row($id):null;$status=$id?($live[$id]??null):null;
$log=$id?cs2ctl(['logs',$id]):[];$config=$id?cs2ctl(['config-get',$id]):[];
$flash=flash();$canCreate=can_perm('servers.create');
$cs2maps=[];
foreach(($all['maps']??[]) as $m)if(is_string($m)&&preg_match('/^[A-Za-z0-9_]{1,64}$/',$m))$cs2maps[]=$m;
$base=$all['base']??['state'=>'missing','ready'=>false,'path'=>'/srv/hyper-cs2/base'];
$baseReady=!empty($base['ready']);$baseInstalling=(($base['state']??'')==='installing');
?><!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CS2 HOSTING — HYPER-HOST</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.6.0/css/all.min.css">
<link rel="stylesheet" href="/assets/style.css?v=350"><style>
body{background:#0b1020;color:#edf3ff}.cs2-wrap{max-width:1370px;margin:auto;padding:30px 22px}.cs2-top{display:flex;justify-content:space-between;align-items:center;gap:18px;flex-wrap:wrap;margin-bottom:25px}.cs2-h{font-size:clamp(26px,4vw,42px);font-weight:800;letter-spacing:-1px}.cs2-muted{color:#99a9c7}.cs2-card{background:linear-gradient(145deg,#161e35,#10172a);border:1px solid #293652;border-radius:18px;padding:24px;margin-bottom:20px;box-shadow:0 14px 45px #05091c77}.cs2-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(285px,1fr));gap:16px}.cs2-grid .cs2-card{margin:0}.cs2-label{font-weight:600;margin-bottom:8px;display:block}.cs2-card input,.cs2-card select,.cs2-card textarea{background:#0c1425!important;color:#ecf2ff!important;border:1px solid #354563!important}.cs2-card input:focus,.cs2-card textarea:focus{box-shadow:0 0 0 3px #247dfc44}.cs2-card textarea{font-family:monospace;font-size:13px;min-height:270px}.cs2-line{display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap}.cs2-stat{display:inline-block;padding:6px 12px;border:1px solid #3b496a;border-radius:30px;color:#c6d4ff;font-size:12px}.cs2-log{background:#070b15;color:#a8efbb;padding:16px;border-radius:12px;white-space:pre-wrap;word-break:break-word;max-height:460px;overflow:auto;font-size:12px}.cs2-btn{background:linear-gradient(120deg,#2274ff,#6148fa);color:white;border:0}.cs2-btn:hover{color:white;filter:brightness(1.2)}.cs2-danger{color:#ff8585}.cs2-srv{display:block;text-decoration:none;color:#f3f6ff}.cs2-srv:hover{color:#fff;border-color:#497bde}.cs2-note{background:#111e36;border-left:3px solid #528aff;padding:14px;border-radius:6px}
</style></head><body><main class="cs2-wrap"><div class="cs2-top"><div><div class="cs2-muted fw-semibold">HYPER-HOST / GAME HOSTING</div><div class="cs2-h"><i class="fa-solid fa-crosshairs text-primary"></i> Counter-Strike 2</div><div class="cs2-muted">Shared Dedicated Servers · SteamCMD App 730 · OverlayFS</div></div><div class="d-flex gap-2"><a href="/" class="btn btn-outline-light"><i class="fa-solid fa-arrow-left"></i> CS 1.6</a><a href="/cs2.php" class="btn cs2-btn">Все CS2 серверы</a></div></div>
<?php if($flash):?><div class="alert alert-<?=e((string)$flash['type'])?>"><?=e($flash['message'])?></div><?php endif;?>
<section class="cs2-card mb-4"><div class="cs2-line"><h3 class="mb-0">Общая сборка CS2 · одна на весь хостинг</h3><span class="cs2-stat"><?= $baseReady?'Установлена':($baseInstalling?'Устанавливается':(($base['state']??'')==='failed'?'Ошибка установки':'Не установлена')) ?></span></div>
<div class="cs2-muted mt-2">SteamCMD App 730 · <?=e((string)$base['path'])?> · обнаружено карт CS2: <b><?=count($cs2maps)?></b></div>
<?php if(!$baseReady):?><div class="alert alert-warning mt-3">Создание серверов временно недоступно, пока не установлена полноценная сборка CS2 (исполняемый файл, ресурсы и карты).<?php if($baseInstalling):?> SteamCMD сейчас скачивает файлы игры.<?php endif;?></div>
<?php if(!empty($base['last_error'])):?><details class="mb-3"><summary>Последняя ошибка SteamCMD</summary><pre class="cs2-log mt-2"><?=e((string)$base['last_error'])?></pre></details><?php endif;?>
<?php if($canCreate):?><form method="post" class="mt-3"><?=csrf_field()?><input type="hidden" name="action" value="install_base"><button class="btn cs2-btn" <?=$baseInstalling?'disabled':''?>><?=$baseInstalling?'Установка CS2 выполняется':'Скачать / восстановить обычный CS2 сервер'?></button></form><?php endif;?>
<p class="cs2-muted mt-2 mb-0">SSH команды отдельно: <code>sudo hyper-cs2-ctl doctor</code></p><p class="cs2-muted mb-0"><code>sudo journalctl -u hyper-cs2-base-install.service -n 60 --no-pager</code></p>
<?php else:?><p class="cs2-muted mt-3 mb-0">Общая сборка готова. Каждый сервер использует её игровые файлы, но имеет собственные конфиги, плагины и процессы. Карты автоматически обнаружены в CS2.</p><?php endif;?></section>
<?php if(!$row):?>
<div class="cs2-grid mb-4"><?php foreach($rows as $r):$s=$live[(int)$r['id']]??[];?><a class="cs2-card cs2-srv" href="?id=<?=(int)$r['id']?>"><div class="cs2-line"><h4><?=e($r['name'])?></h4><span class="cs2-stat"><?=e((string)($s['state']??'not ready'))?></span></div><div class="cs2-muted">#<?=(int)$r['id']?> · <?=e((string)cfg('public_ip'))?>:<?=(int)$r['port']?> · <?=e($r['start_map'])?> · <?= (($s['storage']??'')==='overlay')?'Общая CS2 (OverlayFS)':'Отдельная копия' ?></div><div class="mt-3">Сервис: <b><?=e((string)($s['service']??'unknown'))?></b> · Игроки: <?=e(isset($s['players'])?((string)$s['players'].' / '.(string)($s['max_players']??$r['slots'])):'—')?> · RAM: <?=e((string)($s['ram_mb']??0))?> MB</div></a><?php endforeach;?></div>
<?php if($canCreate && $baseReady && count($cs2maps)>0):?><section class="cs2-card"><h3 class="mb-3">Создать сервер CS2</h3><div class="cs2-note mb-3">При создании используется общая сборка CS2 через OverlayFS — без копирования десятков ГБ. У каждого сервера свои CFG, addons, логи, пользователь Linux и порт. Для публичного сервера нужен GSLT (App ID 730).</div><form method="post" class="row g-3"><?=csrf_field()?><input type="hidden" name="action" value="create">
<div class="col-md-6"><label class="cs2-label">Название</label><input class="form-control" name="name" value="HYPER-HOST CS2" required></div><div class="col-md-6"><label class="cs2-label">Hostname</label><input class="form-control" name="hostname" value="HYPER-HOST | Counter-Strike 2" required></div>
<div class="col-md-3"><label class="cs2-label">Порт</label><input class="form-control" type="number" name="port" value="27101" min="27015" max="27200" required></div><div class="col-md-3"><label class="cs2-label">Слоты</label><input class="form-control" type="number" name="slots" value="10" min="2" max="32" required></div>
<div class="col-md-3"><label class="cs2-label">Карта</label><select class="form-select" name="map" required><?php foreach($cs2maps as $m):?><option value="<?=e($m)?>" <?=$m==='de_dust2'?'selected':''?>><?=e($m)?></option><?php endforeach;?></select></div><div class="col-md-3"><label class="cs2-label">Режим</label><select class="form-select" name="mode"><option value="competitive">Competitive</option><option value="casual">Casual</option><option value="deathmatch">Deathmatch</option><option value="wingman">Wingman</option></select></div>
<div class="col-md-6"><label class="cs2-label">Steam GSLT (App 730)</label><input class="form-control" name="token" type="password" autocomplete="off" placeholder="Steam Game Server Login Token"></div>
<div class="col-md-6"><label class="cs2-label">RCON пароль (обязательно)</label><input class="form-control" name="rcon" type="password" minlength="8" required autocomplete="new-password"></div>
<div class="col-md-6"><label class="cs2-label">Пароль входа на сервер (необязательно)</label><input class="form-control" name="password" type="password" autocomplete="off"></div>
<div class="col-12"><button class="btn cs2-btn btn-lg">Установить CS2 сервер</button></div></form></section><?php endif;?>
<?php else:?>
<div class="cs2-card"><div class="cs2-line"><div><h2><?=e($row['name'])?></h2><p class="cs2-muted mb-2"><?=e((string)cfg('public_ip'))?>:<?=(int)$row['port']?> · <?=e($row['start_map'])?></p><span class="cs2-stat"><?=e((string)($status['state']??'unknown'))?> / <?=e((string)($status['service']??'offline'))?></span></div><div><span class="cs2-stat"><?= (($status['storage']??'')==='overlay')?'Общая сборка / свои дополнения':'Независимая копия' ?></span> <span class="cs2-stat">CPU <?=e((string)($status['cpu']??0))?>%</span> <span class="cs2-stat">RAM <?=e((string)($status['ram_mb']??0))?> MB</span> <span class="cs2-stat">Игроки <?=e(isset($status['players'])?((string)$status['players'].' / '.(string)($status['max_players']??$row['slots'])):'—')?></span></div></div>
<?php if(!empty($status['error'])):?><div class="alert alert-danger mt-3"><?=e($status['error'])?></div><?php endif;?>
<form method="post" class="d-flex flex-wrap gap-2 mt-3"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="power"><button class="btn btn-success" name="op" value="start">Запустить</button><button class="btn btn-warning" name="op" value="restart">Перезапустить</button><button class="btn btn-danger" name="op" value="stop">Остановить</button></form>
<form method="post" class="mt-2"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><button name="action" value="update" class="btn btn-outline-info" <?= (($status['storage']??'')==='overlay')?'onclick="return confirm(&quot;Обновление общей CS2 временно остановит ВСЕ серверы OverlayFS. Продолжить?&quot;)"':'' ?>><?= (($status['storage']??'')==='overlay')?'Обновить общую CS2 (все серверы)':'Обновить этот сервер' ?></button></form></div>
<div class="cs2-grid"><section class="cs2-card"><h4>Настройки сервера</h4><form method="post" class="row g-3 mt-1"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="settings">
<div class="col-12"><label class="cs2-label">Название</label><input class="form-control" name="name" value="<?=e($row['name'])?>"></div><div class="col-12"><label class="cs2-label">Hostname</label><input class="form-control" name="hostname" value="<?=e($row['hostname'])?>"></div>
<div class="col-6"><label class="cs2-label">Порт</label><input class="form-control" type="number" name="port" value="<?=(int)$row['port']?>"></div><div class="col-6"><label class="cs2-label">Слоты</label><input class="form-control" type="number" name="slots" value="<?=(int)$row['slots']?>"></div>
<div class="col-6"><label class="cs2-label">Карта</label><select class="form-select" name="map" required><?php foreach($cs2maps as $m):?><option value="<?=e($m)?>" <?=$m===$row['start_map']?'selected':''?>><?=e($m)?></option><?php endforeach;?></select></div><div class="col-6"><label class="cs2-label">Режим</label><select class="form-select" name="mode"><?php foreach(['competitive'=>'Competitive','casual'=>'Casual','deathmatch'=>'Deathmatch','wingman'=>'Wingman'] as $k=>$v):?><option value="<?=e($k)?>" <?=$k===$row['game_mode']?'selected':''?>><?=e($v)?></option><?php endforeach;?></select></div>
<div class="col-12"><label class="cs2-label">Новый GSLT (пусто = не менять)</label><input class="form-control" type="password" name="token" autocomplete="off"></div>
<div class="col-12"><label class="cs2-label">Новый RCON пароль (пусто = не менять)</label><input class="form-control" type="password" name="rcon" autocomplete="off"></div>
<div class="col-12"><label class="cs2-label">Новый пароль сервера</label><input class="form-control" type="password" name="password" autocomplete="off"></div>
<div class="col-12"><button class="btn cs2-btn">Сохранить (нужен Restart)</button></div></form></section>
<section class="cs2-card"><h4>RCON консоль</h4><form method="post"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="rcon"><label class="cs2-label mt-3">Команда</label><input class="form-control mb-2" name="command" placeholder="status / changelevel de_dust2" required><button class="btn cs2-btn">Выполнить</button></form><pre class="cs2-log mt-3"><?=e((string)($_SESSION['cs2_last_rcon']??'Здесь появится результат RCON'))?></pre><?php unset($_SESSION['cs2_last_rcon']);?><h4 class="mt-4">Логи</h4><pre class="cs2-log"><?=e((string)($log['logs']??'Нет данных'))?></pre></section></div>
<section class="cs2-card"><h4>Редактор server.cfg</h4><p class="cs2-muted">Пароль RCON и GSLT управляются отдельными полями; здесь они не изменяются. После сохранения требуется перезапуск.</p><form method="post"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="save_cfg"><textarea class="form-control" name="config" rows="14" spellcheck="false"><?=e((string)($config['text']??''))?></textarea><button class="btn cs2-btn mt-3">Сохранить server.cfg</button></form></section>
<?php if(can_perm('server.delete')):?><section class="cs2-card"><h4 class="cs2-danger">Удаление сервера</h4><form method="post" onsubmit="return confirm('Удалить сервер CS2 и все файлы?')"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="delete"><div class="d-flex gap-2"><input class="form-control" name="confirm" placeholder="Введи DELETE" required><button class="btn btn-danger">Удалить навсегда</button></div></form></section><?php endif;?>
<?php endif;?><div class="text-center cs2-muted mt-4">HYPER-HOST · CS2 module v3 Shared Storage · <a href="/" class="text-info">CS 1.6 панель</a></div></main></body></html>

HYPER_CS2_SHARED_PHP_V3

cat > "$TMP/hyper-cs2@.service" <<'SERVICE'
[Unit]
Description=HYPER-HOST CS2 instance #%i (Shared OverlayFS or legacy copy)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=cs2s%i
Group=cs2s%i
WorkingDirectory=/srv/hyper-cs2/servers/%i
ExecStartPre=+/usr/local/sbin/hyper-cs2-ctl _mount %i
ExecStart=/usr/local/sbin/hyper-cs2-run %i
Restart=on-failure
RestartSec=8
TimeoutStopSec=45
KillSignal=SIGTERM
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/srv/hyper-cs2/servers/%i
[Install]
WantedBy=multi-user.target
SERVICE
cat > "$TMP/hyper-cs2-base-update.service" <<'SERVICE'
[Unit]
Description=HYPER-HOST CS2 shared Steam App 730 update (stop all shared servers safely)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hyper-cs2-ctl base-update
TimeoutStartSec=14400
SERVICE
printf '[1/6] Backups: %s\n' "$BACKUP"
python3 -m py_compile "$TMP/hyper-cs2-ctl"
php -l "$TMP/cs2.php"
printf '[2/6] Installing shared-storage CS2 controller and web page...\n'
install -m 0755 "$TMP/hyper-cs2-ctl" "$CONTROLLER"
install -m 0644 "$TMP/cs2.php" "$PANEL"
chown www-data:www-data "$PANEL"
printf '[3/6] Updating CS2-only systemd unit and maintenance service...\n'
install -m 0644 "$TMP/hyper-cs2@.service" /etc/systemd/system/hyper-cs2@.service
install -m 0644 "$TMP/hyper-cs2-base-update.service" /etc/systemd/system/hyper-cs2-base-update.service
systemctl daemon-reload
printf '[4/6] Validating PHP and Python...\n'
python3 -m py_compile "$CONTROLLER"
php -l "$PANEL"
printf '[5/6] Detecting current shared base status (SteamCMD is NOT interrupted)...\n'
"$CONTROLLER" doctor
printf '[6/6] Checking existing CS2 servers...\n'
"$CONTROLLER" list
cat <<EOF

===============================================================
 HYPER-HOST CS2 SHARED BASE v3 INSTALLED
 Panel: https://$DOMAIN/cs2.php
 Backup: $BACKUP
 Base build: /srv/hyper-cs2/base (ONE shared install)
 Per-server: /srv/hyper-cs2/servers/<ID>/{upper,work,gamefiles}
 Status: sudo hyper-cs2-ctl doctor
 Maps:   sudo hyper-cs2-ctl maps
 Update: sudo systemctl start --no-block hyper-cs2-base-update.service
 Logs:   sudo journalctl -u hyper-cs2-base-update.service -n 80 --no-pager
===============================================================
 Initial SteamCMD download was NOT stopped/restarted.
 CS1.6 code, services and game data were NOT modified.
 NEW instances use OverlayFS; any existing legacy CS2 copies remain unchanged.
EOF
