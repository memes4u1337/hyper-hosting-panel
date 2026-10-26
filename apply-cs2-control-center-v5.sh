#!/usr/bin/env bash
# HYPER-HOST CS2 v5 - full automatic v2 -> v3 -> v4 -> v5 migration
# CS1.6 code and game files are not modified. No game base download is triggered.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo '[ERROR] Execute with sudo bash' >&2; exit 1; }
for c in php python3 systemctl install grep; do command -v "$c" >/dev/null || { echo "[ERROR] Missing $c" >&2; exit 1; }; done
CTL=/usr/local/sbin/hyper-cs2-ctl
[[ -f "$CTL" && ! -L "$CTL" ]] || { echo '[ERROR] CS2 module v2 not found' >&2; exit 1; }
[[ -f /etc/hyper-cs16/panel.php ]] || { echo '[ERROR] Missing panel config' >&2; exit 1; }
DOMAIN=$(php -r '$c=require "/etc/hyper-cs16/panel.php"; echo $c["domain"]??"";')
[[ $DOMAIN =~ ^[a-zA-Z0-9.-]+$ ]] || { echo '[ERROR] Invalid panel domain' >&2; exit 1; }
WEB="/var/www/hyper-host-sites/$DOMAIN/public_html"
PANEL="$WEB/cs2.php"
[[ -f "$PANEL" && ! -L "$PANEL" ]] || { echo '[ERROR] Missing CS2 panel page' >&2; exit 1; }
[[ -d /srv/hyper-cs2/base && -d /srv/hyper-cs2/servers ]] || { echo '[ERROR] CS2 game paths missing' >&2; exit 1; }
TEMP=$(mktemp -d /tmp/hyper-cs2-v5.XXXXXXXX)
trap 'rm -rf "$TEMP"' EXIT
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/hyper-cs2-v5-$STAMP"
mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs2-ctl"
cp -a "$PANEL" "$BACKUP/cs2.php"
[[ -f /etc/ssh/sshd_config ]] && cp -a /etc/ssh/sshd_config "$BACKUP/sshd_config" || true
[[ -f /etc/systemd/system/hyper-cs2@.service ]] && cp -a /etc/systemd/system/hyper-cs2@.service "$BACKUP/hyper-cs2@.service" || true
printf '[1/7] CS2 backup: %s\n' "$BACKUP"
# Bundle the original tested migration scripts: works without fetching any other patch.
cat > "$TEMP/apply-v3.sh" <<'__CS2_V5_V3_EMBED_END__'
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

__CS2_V5_V3_EMBED_END__
cat > "$TEMP/apply-v4.sh" <<'__CS2_V5_V4_EMBED_END__'
#!/usr/bin/env bash
# HYPER-HOST CS2 v4 - AJAX admin + secure SFTP per instance
# Patch requires CS2 Shared Storage v3. Does not change existing CS1.6, CS2 game assets, SteamCMD or game services.
set -Eeuo pipefail
[[ ${EUID:-999} == 0 ]] || { echo '[ERROR] Run as root'; exit 1; }
for app in php python3 systemctl grep install cp chmod chown usermod passwd sshd; do
  if [[ $app == sshd ]]; then
    [[ -x /usr/sbin/sshd ]] || { echo '[ERROR] OpenSSH server not found. Install openssh-server first'; exit 1; }
  else command -v "$app" >/dev/null || { echo "[ERROR] Missing $app"; exit 1; };fi
done
[[ -f /etc/hyper-cs16/panel.php ]] || { echo '[ERROR] Missing HYPER-HOST panel.php'; exit 1; }
DOMAIN=$(php -r '$c=require "/etc/hyper-cs16/panel.php";echo $c["domain"]??"";')
[[ $DOMAIN =~ ^[a-zA-Z0-9.-]+$ ]] || { echo '[ERROR] Invalid domain'; exit 1; }
WEB="/var/www/hyper-host-sites/$DOMAIN/public_html"
PANEL="$WEB/cs2.php"
CTL=/usr/local/sbin/hyper-cs2-ctl
[[ -f $CTL && ! -L $CTL && -f $PANEL && ! -L $PANEL ]] || { echo '[ERROR] CS2 page/controller not found'; exit 1; }
grep -q 'def mount_overlay_unlocked' "$CTL" || { echo '[ERROR] Apply CS2 Shared Storage v3 before v4'; exit 1; }
[[ -e /srv/hyper-cs2/base && -d /srv/hyper-cs2/servers ]] || { echo '[ERROR] CS2 directories are missing'; exit 1; }
[[ -f /etc/ssh/sshd_config && ! -L /etc/ssh/sshd_config ]] || { echo '[ERROR] OpenSSH config missing or symlinked'; exit 1; }
/usr/sbin/sshd -t || { echo '[ERROR] SSH config currently invalid. No changes applied'; exit 1; }
TMP=$(mktemp -d /tmp/hyper-cs2-v4.XXXXXXXX)
trap 'rm -rf "$TMP"' EXIT
BACKUP="/root/hyper-cs2-v4-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs2-ctl"
cp -a "$PANEL" "$BACKUP/cs2.php"
cp -a /etc/ssh/sshd_config "$BACKUP/sshd_config"
rollback_v4() {
  local code=$?
  trap - ERR
  echo "[ERROR] v4 installation failed (exit $code); restoring controller, PHP and SSH config from $BACKUP" >&2
  cp -a "$BACKUP/hyper-cs2-ctl" "$CTL" || true
  cp -a "$BACKUP/cs2.php" "$PANEL" || true
  cp -a "$BACKUP/sshd_config" /etc/ssh/sshd_config || true
  /usr/sbin/sshd -t || true
  if systemctl is-active --quiet ssh; then systemctl reload ssh || true
  elif systemctl is-active --quiet sshd; then systemctl reload sshd || true; fi
  exit "$code"
}
trap rollback_v4 ERR
cat > "$TMP/addon.py" <<'HYPER_CS2_SFTP_ADDON_V4'
# HYPER-HOST v4 SFTP isolated per CS2 instance (injected before def main())
import grp, secrets

SFTP_GROUP='hypercs2sftp'

def sftp_info(i):
    c=load(i)
    uname=user(i)
    try:
        info=pwd.getpwnam(uname)
    except KeyError:
        return {'ok':True,'enabled':False,'ready':False,'username':uname,'message':'Сначала дождитесь подготовки игрового сервера'}
    try:
        g=grp.getgrnam(SFTP_GROUP)
        member=uname in g.gr_mem or info.pw_gid==g.gr_gid
    except KeyError:
        member=False
    locked=True
    try:
        for line in pathlib.Path('/etc/shadow').read_text().splitlines():
            if line.startswith(uname+':'):
                shadow=line.split(':',2)[1]
                locked=not bool(shadow) or shadow.startswith(('!','*'))
                break
    except OSError: pass
    port=22;configured=False
    sshd=shutil.which('sshd') or '/usr/sbin/sshd'
    try:
        cfg=cp([sshd,'-T','-C',f'user={uname},host=localhost,addr=127.0.0.1'],check=False,timeout=5)
        if cfg.returncode==0:
            d=dict((line.split(' ',1) for line in cfg.stdout.splitlines() if ' ' in line))
            try: port=int(d.get('port','22').split()[0])
            except ValueError: port=22
            configured=(d.get('chrootdirectory','') in ('%h',str(gamepath(i)))
                        and d.get('forcecommand','').startswith('internal-sftp')
                        and d.get('passwordauthentication','').lower()=='yes')
    except Exception: pass
    return {'ok':True,'enabled':member and not locked and configured,'configured':configured,'ready':bool(gamepath(i).is_dir()),
            'username':uname,'port':port,'remote_dir':'/gamefiles/game/csgo',
            'protocol':'SFTP','mode':storage_mode(c)}

def sftp_chroot_preflight(i):
    root=gamepath(i)
    if not root.exists() or root.is_symlink(): fail('Не найдена папка сервера или обнаружена ссылка')
    if storage_mode(load(i))=='overlay':
        with base_lock(shared=True):
            if base_busy(): fail('Общая сборка CS2 сейчас обновляется')
            mount_overlay_unlocked(i)
    if not (root/'gamefiles/game/csgo').is_dir(): fail('Не подготовлена игровая директория CS2')
    # OpenSSH requires root-owned, non-writable-by-group/other chroot path.
    # Changing owners of ROOT/SERVERS globally is unsafe; verify each component.
    for part in [pathlib.Path('/srv'),ROOT,SERVERS]:
        st=part.stat()
        if part.is_symlink() or st.st_uid!=0 or st.st_mode&0o022:
            fail('SFTP chroot требует root-owned директорию без групповой записи: '+str(part))
    st=root.stat()
    if st.st_mode&0o022 or st.st_uid!=0:
        # Fix only this instance's outer directory. Never recursively chown the game.
        os.chown(root,0,0)
        os.chmod(root,0o755)
    if root.is_symlink() or root.stat().st_mode&0o022: fail('Некорректные права SFTP chroot')

def sftp_enable(i):
    if load(i).get('state')!='ready': fail('Дождитесь завершения установки сервера')
    sftp_chroot_preflight(i)
    uname=user(i)
    try: grp.getgrnam(SFTP_GROUP)
    except KeyError: fail('Не установлена системная группа SFTP (повторите патч v4)')
    password=secrets.token_urlsafe(24)
    cp(['usermod','-a','-G',SFTP_GROUP,uname],timeout=10)
    if not sftp_info(i)['configured']:
        fail('Текущая конфигурация sshd не обеспечивает ChrootDirectory, internal-sftp и парольный вход для группы. Пароль не активирован.')
    p=subprocess.run(['chpasswd'],input=f'{uname}:{password}\n',text=True,capture_output=True,timeout=10)
    if p.returncode: fail('Не удалось установить пароль SFTP: '+p.stderr[-400:])
    data=sftp_info(i)
    if not data['enabled']: fail('SFTP учётная запись не активировалась; проверьте sshd и PAM')
    output({**data,'password':password,'message':'Пароль показан один раз. Сохраните его в менеджере паролей.'})

def sftp_disable(i):
    load(i)
    uname=user(i)
    try: pwd.getpwnam(uname)
    except KeyError: fail('Системный пользователь CS2 ещё не создан')
    cp(['passwd','-l',uname],timeout=10)
    cp(['gpasswd','-d',uname,SFTP_GROUP],check=False,timeout=10)
    output({'ok':True,'enabled':False,'username':uname,'message':'Доступ для новых подключений заблокирован. Существующие SFTP-сеансы могут оставаться открытыми.'})
HYPER_CS2_SFTP_ADDON_V4
cat > "$TMP/cs2.php" <<'HYPER_CS2_AJAX_PANEL_V4'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$user=require_auth();
$isAdmin=in_array((string)$user['role'],['owner','admin'],true);
$isAjax=(isset($_GET['ajax'])||strtolower((string)($_SERVER['HTTP_X_REQUESTED_WITH']??''))==='xmlhttprequest');
function cs4json(array $v,int $code=200):void {http_response_code($code);header('Content-Type: application/json; charset=utf-8');header('Cache-Control: private, no-store');echo json_encode($v,JSON_UNESCAPED_UNICODE|JSON_INVALID_UTF8_SUBSTITUTE);exit;}
function cs4ctl(array $args,?string $input=null,int $timeout=30):array {
  $cmd=['sudo','-n','/usr/local/sbin/hyper-cs2-ctl'];foreach($args as $a)$cmd[]=(string)$a;
  $p=proc_open(implode(' ',array_map('escapeshellarg',$cmd)),[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes,null,['PATH'=>'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']);
  if(!is_resource($p))return ['ok'=>false,'error'=>'Контроллер недоступен'];
  fwrite($pipes[0],$input??'');fclose($pipes[0]);
  stream_set_blocking($pipes[1],false);stream_set_blocking($pipes[2],false);
  $start=microtime(true);$out='';$err='';$timed=false;
  do{$status=proc_get_status($p);$out.=stream_get_contents($pipes[1]);$err.=stream_get_contents($pipes[2]);if(!$status['running'])break;if(microtime(true)-$start>$timeout){proc_terminate($p);$timed=true;break;}usleep(40000);}while(true);
  $out.=stream_get_contents($pipes[1]);$err.=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);proc_close($p);
  $v=json_decode(trim($out),true);
  return is_array($v)?$v:['ok'=>false,'error'=>$timed?'Время ожидания превышено':(trim($err)?:trim($out)?:'Ошибка контроллера')];
}
function cs4row(int $id):array{
  global $user,$isAdmin;
  if($id<1)throw new RuntimeException('Некорректный ID');
  $q=db()->prepare('SELECT * FROM cs2_servers WHERE id=?');$q->execute([$id]);$r=$q->fetch();
  if(!$r)throw new RuntimeException('Сервер CS2 #'.$id.' не найден');
  if(!$isAdmin&&(int)$r['owner_user_id']!==(int)$user['id'])throw new RuntimeException('Нет доступа к серверу');
  return $r;
}
function cs4require(bool $allowed):void{if(!$allowed)throw new RuntimeException('Недостаточно прав для операции');}
function cs4post(array $row,int $id,string $action):array{
  global $isAdmin,$user;
  if($action==='power'){
    cs4require(can_perm('server.power')||(int)$row['owner_user_id']===(int)$user['id']);
    $op=(string)($_POST['op']??'');if(!in_array($op,['start','stop','restart'],true))throw new RuntimeException('Неверное действие');
    $r=cs4ctl([$op,$id],null,110);return $r+['message'=>['start'=>'Запуск сервера выполнен','stop'=>'Сервер остановлен','restart'=>'Сервер перезапущен'][$op]];
  }
  if($action==='update'){
    cs4require($isAdmin); // shared base update affects ALL tenants
    $r=cs4ctl(['update',$id]);return $r+['message'=>'Обновление общей CS2 запущено. Все серверы могут быть временно остановлены.'];
  }
  if($action==='settings'){
    $p=['name'=>(string)($_POST['name']??$row['name']),'hostname'=>(string)($_POST['hostname']??$row['hostname']),
      'port'=>(int)($_POST['port']??$row['port']),'slots'=>(int)($_POST['slots']??$row['slots']),
      'map'=>(string)($_POST['map']??$row['start_map']),'mode'=>(string)($_POST['mode']??$row['game_mode'])];
    foreach(['token','password','rcon'] as $key){$v=(string)($_POST[$key]??'');if($v!=='')$p[$key]=$v;}
    $r=cs4ctl(['settings',$id],json_encode($p,JSON_UNESCAPED_UNICODE));
    if(!empty($r['ok']))db()->prepare('UPDATE cs2_servers SET name=?,hostname=?,port=?,slots=?,start_map=?,game_mode=? WHERE id=?')->execute([$p['name'],$p['hostname'],$p['port'],$p['slots'],$p['map'],$p['mode'],$id]);
    return $r+['message'=>'Настройки сохранены. Примените их перезапуском сервера.'];
  }
  if($action==='rcon')return cs4ctl(['rcon',$id],(string)($_POST['command']??''),20);
  if($action==='save_cfg')return cs4ctl(['config-save',$id],(string)($_POST['config']??''))+['message'=>'server.cfg сохранён. Для применения нужен перезапуск.'];
  if($action==='sftp-enable'||$action==='sftp-reset')return cs4ctl(['sftp-enable',$id],null,35);
  if($action==='sftp-disable')return cs4ctl(['sftp-disable',$id],null,20);
  if($action==='delete'){
    cs4require(can_perm('server.delete'));
    if((string)($_POST['confirm']??'')!=='DELETE')throw new RuntimeException('Для удаления введи DELETE');
    $r=cs4ctl(['delete',$id],null,120);
    if(!empty($r['ok'])){db()->prepare('DELETE FROM cs2_servers WHERE id=?')->execute([$id]);audit('cs2_delete','#'.$id);$r['redirect']='/cs2.php';$r['message']='Сервер удалён';}
    return $r;
  }
  throw new RuntimeException('Неизвестное действие');
}
if(isset($_GET['ajax'])){
  try{
    $act=(string)$_GET['ajax'];$id=(int)($_GET['id']??0);
    if($act==='base'){$v=cs4ctl(['base-status']);cs4json($v);}
    $r=cs4row($id);
    if($act==='status'){$v=cs4ctl(['status',$id]);cs4json($v);}
    if($act==='logs'){$v=cs4ctl(['logs',$id]);cs4json($v);}
    if($act==='config'){$v=cs4ctl(['config-get',$id]);cs4json($v);}
    if($act==='sftp'){$v=cs4ctl(['sftp-status',$id]);cs4json($v);}
    throw new RuntimeException('Неизвестный запрос');
  }catch(Throwable $e){cs4json(['ok'=>false,'error'=>$e->getMessage()],400);}
}
if($_SERVER['REQUEST_METHOD']==='POST'){
  try{
    check_csrf();$act=(string)($_POST['action']??'');$id=(int)($_POST['id']??0);
    if($act==='install_base'){require_perm('servers.create');$r=cs4ctl(['base-start']);$r['message']='Установка CS2 запущена';}
    elseif($act==='create'){
      require_perm('servers.create');
      $p=['name'=>trim((string)($_POST['name']??'')),'hostname'=>trim((string)($_POST['hostname']??'')),
        'port'=>(int)($_POST['port']??27101),'slots'=>(int)($_POST['slots']??10),'map'=>(string)($_POST['map']??'de_dust2'),
        'mode'=>(string)($_POST['mode']??'competitive'),'token'=>(string)($_POST['token']??''),
        'password'=>(string)($_POST['password']??''),'rcon'=>(string)($_POST['rcon']??'')];
      if($p['name']===''||$p['hostname']===''||$p['rcon']==='')throw new RuntimeException('Заполни название, hostname и RCON-пароль');
      $maps=cs4ctl(['maps']);if(empty($maps['base_ready'])||!in_array($p['map'],$maps['maps']??[],true))throw new RuntimeException('Базовая CS2 пока не готова или карта отсутствует');
      $pdo=db();$pdo->prepare('INSERT INTO cs2_servers(owner_user_id,name,hostname,port,slots,start_map,game_mode) VALUES(?,?,?,?,?,?,?)')
        ->execute([(int)$user['id'],$p['name'],$p['hostname'],$p['port'],$p['slots'],$p['map'],$p['mode']]);
      $id=(int)$pdo->lastInsertId();$r=cs4ctl(['create',$id],json_encode($p,JSON_UNESCAPED_UNICODE));
      if(empty($r['ok'])){$pdo->prepare('DELETE FROM cs2_servers WHERE id=?')->execute([$id]);}
      else{$r['redirect']='/cs2.php?id='.$id;$r['message']='Подготовка сервера запущена';audit('cs2_create','#'.$id);}
    }else{$row=cs4row($id);$r=cs4post($row,$id,$act);if(!empty($r['ok']))audit('cs2_'.$act,'#'.$id);}
    if(empty($r['ok']))throw new RuntimeException((string)($r['error']??'Неизвестная ошибка'));
    if($isAjax)cs4json($r);
    flash((string)($r['message']??'Операция выполнена'));redirect((string)($r['redirect']??('/cs2.php'.($id?'?id='.$id:''))));
  }catch(Throwable $e){if($isAjax)cs4json(['ok'=>false,'error'=>$e->getMessage()],400);flash($e->getMessage(),'danger');redirect('/cs2.php'.(!empty($id)?'?id='.(int)$id:''));}
}
$all=cs4ctl(['list']);$live=[];foreach(($all['servers']??[]) as $s)$live[(int)$s['id']]=$s;
if($isAdmin)$rows=db()->query('SELECT * FROM cs2_servers ORDER BY id DESC')->fetchAll();
else{$q=db()->prepare('SELECT * FROM cs2_servers WHERE owner_user_id=? ORDER BY id DESC');$q->execute([(int)$user['id']]);$rows=$q->fetchAll();}
$id=(int)($_GET['id']??0);$row=null;$status=[];$config=['text'=>''];
if($id){try{$row=cs4row($id);$status=$live[$id]??cs4ctl(['status',$id]);$config=cs4ctl(['config-get',$id]);}catch(Throwable $e){flash($e->getMessage(),'danger');redirect('/cs2.php');}}
$maps=array_values(array_filter($all['maps']??[],fn($v)=>is_string($v)&&preg_match('/^[A-Za-z0-9_]{1,64}$/',$v)));
$base=$all['base']??['state'=>'missing','ready'=>false,'maps_count'=>0];$ready=!empty($base['ready']);
$ip=(string)cfg('public_ip');$flash=flash();
$modeNames=['competitive'=>'Соревновательный','casual'=>'Обычный','deathmatch'=>'Бой насмерть','wingman'=>'Напарники'];
?><!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>CS2 · HYPER-HOST</title>
<style>
:root{--bg:#070b15;--surface:#11182a;--surface2:#17223a;--line:#26354f;--muted:#91a4c2;--txt:#f0f5ff;--blue:#4288ff;--purple:#735aff;--green:#32d99d;--red:#fb6577;--amber:#ffbf64}*{box-sizing:border-box}html,body{margin:0;min-height:100%;background:var(--bg);color:var(--txt);font:14px/1.5 system-ui,-apple-system,Segoe UI,Arial,sans-serif}a{color:#81b4ff;text-decoration:none}button,input,select,textarea{font:inherit}button{cursor:pointer}button:disabled{cursor:not-allowed;opacity:.45} .app{max-width:1540px;margin:auto;padding:26px 28px 70px} .top{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap;margin-bottom:26px}.brand{font-size:11px;letter-spacing:.18em;font-weight:800;color:#83b3ff}.heading{font-size:clamp(25px,3vw,36px);font-weight:800;letter-spacing:-.035em;margin:4px 0 2px}.muted{color:var(--muted)}.small{font-size:12px}.topright{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;border:1px solid #40516d;border-radius:11px;padding:10px 16px;color:#f4f7ff;background:#1b2941;font-weight:700;white-space:nowrap;transition:background .15s,border-color .15s,transform .15s}.btn:hover:not(:disabled){background:#273b60;border-color:#5a81ca;transform:translateY(-1px)}.btn.primary{background:linear-gradient(120deg,#2675fa,#6049ee);border-color:#5d65f9}.btn.green{background:#115d49;border-color:#197e60}.btn.red{background:#4a2231;border-color:#804159}.btn.amber{background:#48371c;border-color:#8b6738}.btn.ghost{background:transparent}.btn.sm{padding:7px 12px;font-size:12px;border-radius:9px}.card{background:linear-gradient(145deg,var(--surface),#10182a);border:1px solid var(--line);border-radius:18px;box-shadow:0 16px 50px #02071332;padding:23px}.card h2{font-size:19px;margin:0 0 16px;letter-spacing:-.015em}.stack{display:grid;gap:16px}.grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:18px}.col8{grid-column:span 8}.col7{grid-column:span 7}.col6{grid-column:span 6}.col5{grid-column:span 5}.col4{grid-column:span 4}.col12{grid-column:span 12}.flex{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.between{justify-content:space-between}.badge{display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border:1px solid #40516c;border-radius:99px;color:#c0cee5;background:#18233a;font-size:12px;font-weight:700}.badge.good{color:#60e8bb;border-color:#1e765c;background:#0d382d}.badge.bad{color:#ff9ba4;border-color:#824050;background:#381c2b}.badge.wait{color:#ffd18c;border-color:#806039;background:#422e1b}.dot{width:7px;height:7px;border-radius:50%;background:currentColor}.hero{padding:26px;background:radial-gradient(ellipse at 80% -80%,#4b48aa65,transparent 55%),linear-gradient(120deg,#162640,#11182a)}.hero h2{font-size:26px;margin:0 0 5px}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:18px 0}.metric{background:#0c1425;border:1px solid #263550;border-radius:13px;padding:16px}.metric .value{font-size:23px;font-weight:800;letter-spacing:-.02em;margin-top:5px}.metric .label{font-size:12px;color:#a2b5d4}.navtabs{display:flex;gap:5px;padding:5px;background:#101b2d;border:1px solid var(--line);border-radius:13px;overflow-x:auto;margin:20px 0}.tab{flex:1;min-width:105px;padding:11px 14px;background:transparent;border:0;border-radius:9px;color:#9caec9;font-weight:700}.tab:hover{color:#fff;background:#1a2a46}.tab.active{background:#30436b;color:white}.panel{display:none}.panel.active{display:block}.formgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}.field{display:grid;gap:7px}.field.full{grid-column:1/-1}.field label{font-weight:700;font-size:12px;color:#b8c9e5}.field input,.field select,.field textarea,.terminal-input{width:100%;min-width:0;border-radius:10px;padding:11px 12px;color:#edf4ff;background:#0a1223;border:1px solid #344563;outline:none}.field input:focus,.field select:focus,.field textarea:focus,.terminal-input:focus{border-color:#488dff;box-shadow:0 0 0 3px #2877ee33}.field textarea{min-height:330px;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;resize:vertical}.field select option{color:#fff;background:#111b2d}.hint{font-size:12px;color:#9eb0cc}.terminal{padding:17px;background:#050a13;border:1px solid #22324a;color:#91f1bd;min-height:180px;max-height:460px;overflow:auto;border-radius:13px;white-space:pre-wrap;word-break:break-word;font:12px/1.7 ui-monospace,SFMono-Regular,Consolas,monospace}.notice{padding:14px;border:1px solid #38557f;background:#122441;border-radius:11px;color:#c5defe}.notice.warn{background:#392b19;border-color:#715433;color:#ffdb9c}.srvcard{display:block;color:inherit;transition:border-color .15s}.srvcard:hover{border-color:#5082dc}.srvcard h3{margin:0;font-size:18px}.pill{color:#7fc6ff;font-size:12px;font-weight:700}.statgroup{display:flex;align-items:center;flex-wrap:wrap;gap:9px}.split{display:grid;grid-template-columns:1fr auto;gap:16px;align-items:center}.sidebarline{border-top:1px solid var(--line);padding-top:16px;margin-top:18px}.mono{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}.secretreveal{padding:15px;background:#142841;border:1px solid #3b5a7c;border-radius:12px;margin:12px 0}.alertbox{padding:11px 15px;border-radius:11px;background:#382232;border:1px solid #764155;color:#ffb5bf;white-space:pre-wrap}.toastbox{position:fixed;right:22px;bottom:22px;max-width:420px;z-index:1000;border-radius:13px;padding:14px 18px;background:#163c33;color:#a7ffe0;border:1px solid #2a977a;box-shadow:0 12px 45px #0009}.toastbox.error{background:#48252b;color:#ffd4d8;border-color:#c45b71}.hidden{display:none!important}.spinner{display:inline-block;width:14px;height:14px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:spin .75s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}.footer{margin-top:30px;text-align:center;color:#7c8dac;font-size:12px}@media(max-width:950px){.col8,.col7,.col6,.col5,.col4{grid-column:span 12}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:550px){.app{padding:15px 12px 40px}.card{padding:17px;border-radius:14px}.metrics{gap:8px}.metric{padding:11px}.metric .value{font-size:19px}.formgrid{grid-template-columns:1fr}.split{grid-template-columns:1fr}.tab{min-width:96px;padding:10px 8px}.hero h2{font-size:22px}}
</style></head><body><main class="app">
<header class="top"><div><div class="brand">HYPER-HOST / GAME HOSTING</div><div class="heading">Counter-Strike <span style="color:#669bff">2</span></div><div class="muted small">Steam Dedicated Server · App 730 · Shared Storage</div></div><div class="topright"><a class="btn ghost" href="/">← CS 1.6</a><a class="btn <?=$id?'':'primary'?>" href="/cs2.php">Все серверы</a></div></header>
<?php if(is_array($flash)&&!empty($flash['message'])):?><div class="notice" style="margin-bottom:16px"><?=e((string)$flash['message'])?></div><?php endif;?>
<section class="card" style="margin-bottom:18px"><div class="split"><div><div class="flex"><strong style="font-size:19px">Общая сборка CS2</strong><span id="base-badge" class="badge <?=$ready?'good':'wait'?>"><?= $ready?'Установлена':'Проверяется / устанавливается' ?></span></div><div class="muted small" style="margin-top:5px">SteamCMD App 730 · /srv/hyper-cs2/base · карт CS2: <span id="mapcount"><?=(int)($base['maps_count']??0)?></span></div><div class="hint" id="base-message" style="margin-top:8px"><?= $ready?'Одна сборка для всех серверов. Конфигурации и дополнения клиентов изолированы.':'Создание доступно после завершения загрузки и проверки сборки.' ?></div></div><div><?php if(can_perm('servers.create')):?><form method="post" class="ajaxform" data-quiet="1"><?=csrf_field()?><input type="hidden" name="action" value="install_base"><button class="btn ghost" type="submit">Проверить / установить</button></form><?php endif;?></div></div></section>
<?php if(!$row):?>
<div class="flex between" style="margin:24px 0 14px"><div><h2 style="margin:0">Мои игровые серверы</h2><div class="muted small"><?=count($rows)?> сервер(ов)</div></div></div>
<div class="grid" style="margin-bottom:20px"><?php if(!$rows):?><div class="col12 card"><h2>Серверов пока нет</h2><div class="muted">Создай первый CS2-сервер после установки базовой сборки.</div></div><?php endif;?><?php foreach($rows as $s):$ss=$live[(int)$s['id']]??[];$run=!empty($ss['running']);?><a class="card srvcard col4" href="/cs2.php?id=<?=(int)$s['id']?>"><div class="flex between"><h3><?=e($s['name'])?></h3><span class="badge <?=$run?'good':'wait'?>"><?=$run?'Онлайн':e((string)($ss['state']??'Офлайн'))?></span></div><div class="muted small" style="margin:11px 0"><?=e($ip)?>:<?=(int)$s['port']?> · <?=e($s['start_map'])?></div><div class="flex"><span class="pill"><?=(int)$s['slots']?> слотов</span><span class="pill"><?=e($modeNames[$s['game_mode']]??$s['game_mode'])?></span></div></a><?php endforeach;?></div>
<?php if(can_perm('servers.create')):?><section class="card"><div class="flex between"><h2 style="margin:0">Создать сервер CS2</h2><span class="badge <?=$ready?'good':'wait'?>"><?=$ready?'Можно создавать':'Ожидаем установку'?></span></div><p class="muted">Новая игровая папка использует общую сборку через OverlayFS, без повторной загрузки десятков гигабайт.</p><form method="post" class="ajaxform formgrid" style="margin-top:18px"><?=csrf_field()?><input type="hidden" name="action" value="create"><div class="field"><label>Название</label><input name="name" value="HYPER-HOST CS2" maxlength="96" required></div><div class="field"><label>Имя игрового сервера (hostname)</label><input name="hostname" value="HYPER-HOST | Counter-Strike 2" maxlength="160" required></div><div class="field"><label>UDP порт</label><input type="number" name="port" value="27101" min="27015" max="27200" required></div><div class="field"><label>Слоты</label><input type="number" name="slots" value="10" min="2" max="32" required></div><div class="field"><label>Карта CS2</label><select name="map" required><?php foreach($maps as $m):?><option value="<?=e($m)?>" <?=$m==='de_dust2'?'selected':''?>><?=e($m)?></option><?php endforeach;?></select></div><div class="field"><label>Режим</label><select name="mode"><?php foreach($modeNames as $k=>$v):?><option value="<?=e($k)?>"><?=e($v)?></option><?php endforeach;?></select></div><div class="field"><label>Steam GSLT (App 730)</label><input type="password" name="token" autocomplete="new-password" placeholder="Для публичного сервера"></div><div class="field"><label>RCON пароль</label><input type="password" name="rcon" minlength="8" required autocomplete="new-password"></div><div class="field full"><label>Пароль входа в игру (необязательно)</label><input type="password" name="password" autocomplete="new-password"></div><div class="field full"><button type="submit" class="btn primary" <?=$ready?'':'disabled'?>>＋ Создать игровой сервер</button></div></form></section><?php endif;?>
<?php else:?>
<section class="card hero"><div class="split"><div><div class="muted small">ИГРОВОЙ СЕРВЕР #<?=$id?></div><h2 id="server-name"><?=e($row['name'])?></h2><div class="flex"><span id="server-badge" class="badge <?=!empty($status['running'])?'good':'wait'?>"><span class="dot"></span><span id="state-text"><?=!empty($status['running'])?'Работает':e((string)($status['state']??'Ожидание'))?></span></span><span class="muted small mono" id="connect-label"><?=e($ip)?>:<?=(int)$row['port']?></span><button class="btn ghost sm" type="button" data-copy="<?=e($ip.':'.(int)$row['port'])?>">Скопировать адрес</button></div></div><div class="flex"><form method="post" class="ajaxform flex powerform"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="power"><button class="btn green" name="op" value="start" type="submit">▶ Запустить</button><button class="btn amber" name="op" value="restart" type="submit">↻ Рестарт</button><button class="btn red" name="op" value="stop" type="submit">■ Остановить</button></form></div></div><div id="server-error" class="alertbox <?=empty($status['error'])?'hidden':''?>" style="margin-top:15px"><?=e((string)($status['error']??''))?></div></section>
<div class="metrics"><div class="metric"><div class="label">Статус</div><div class="value" id="service-value"><?=e((string)($status['service']??'unknown'))?></div></div><div class="metric"><div class="label">Игроки</div><div class="value" id="players-value"><?=isset($status['players'])?(int)$status['players'].' / '.(int)($status['max_players']??$row['slots']):'—'?></div></div><div class="metric"><div class="label">CPU</div><div class="value" id="cpu-value"><?=e((string)($status['cpu']??0))?>%</div></div><div class="metric"><div class="label">Оперативная память</div><div class="value" id="ram-value"><?=e((string)($status['ram_mb']??0))?> МБ</div></div></div>
<nav class="navtabs" aria-label="Разделы сервера"><button type="button" class="tab active" data-tab="overview">Обзор</button><button type="button" class="tab" data-tab="console">Консоль</button><button type="button" class="tab" data-tab="files">Файлы / SFTP</button><button type="button" class="tab" data-tab="settings">Настройки</button><button type="button" class="tab" data-tab="config">server.cfg</button><button type="button" class="tab" data-tab="logs">Логи</button></nav>
<section class="panel active" data-panel="overview"><div class="grid"><div class="col8 card"><h2>Информация о сервере</h2><div class="stack"><div class="flex between"><span class="muted">Адрес</span><strong class="mono"><?=e($ip)?>:<?=(int)$row['port']?></strong></div><div class="flex between"><span class="muted">Стартовая карта</span><strong id="current-map"><?=e($row['start_map'])?></strong></div><div class="flex between"><span class="muted">Режим</span><strong><?=e($modeNames[$row['game_mode']]??$row['game_mode'])?></strong></div><div class="flex between"><span class="muted">Хранилище</span><strong><?=($status['storage']??'')==='overlay'?'Общая сборка / OverlayFS':'Отдельная копия'?></strong></div><div class="flex between"><span class="muted">Время работы</span><strong id="uptime">—</strong></div><div class="flex between"><span class="muted">Игровые файлы</span><strong class="mono small">/srv/hyper-cs2/servers/<?=$id?>/gamefiles</strong></div></div><div class="notice" style="margin-top:20px">Обновление статуса автоматически каждые 7 секунд, без перезагрузки страницы.</div></div><div class="col4 card"><h2>Быстрые действия</h2><div class="stack"><button class="btn" type="button" data-gotab="console">⌘ Открыть RCON-консоль</button><button class="btn" type="button" data-gotab="files">⇪ Настроить SFTP-доступ</button><button class="btn" type="button" data-gotab="logs">☷ Журнал запуска</button><?php if($isAdmin):?><form method="post" class="ajaxform" data-confirm="Обновление общей CS2 остановит ВСЕ серверы OverlayFS на время обновления. Продолжить?"><?=csrf_field()?><input type="hidden" name="action" value="update"><input type="hidden" name="id" value="<?=$id?>"><button class="btn ghost" style="width:100%">↻ Обновить общую CS2</button></form><?php endif;?></div></div></div></section>
<section class="panel" data-panel="console"><div class="card"><h2>RCON консоль</h2><p class="muted small">Удалённые команды для запущенного CS2. Например: <span class="mono">status</span> или <span class="mono">changelevel de_dust2</span>.</p><form method="post" class="ajaxform flex" data-result="console-out"><?=csrf_field()?><input type="hidden" name="action" value="rcon"><input type="hidden" name="id" value="<?=$id?>"><input class="terminal-input" style="flex:1;min-width:220px" name="command" placeholder="Введите RCON команду..." maxlength="300" required><button class="btn primary">Выполнить</button></form><pre id="console-out" class="terminal" style="margin-top:16px">Результат команды появится здесь.</pre></div></section>
<section class="panel" data-panel="files"><div class="grid"><div class="col7 card"><h2>Доступ к файлам CS2 через SFTP</h2><div class="notice">SFTP — защищённый файловый протокол через SSH. Работает с FileZilla и WinSCP. Обычный незашифрованный FTP не используется.</div><div class="formgrid" style="margin:20px 0"><div class="field"><label>Хост</label><input id="sftp-host" readonly value="<?=e($ip)?>"></div><div class="field"><label>Протокол</label><input readonly value="SFTP — SSH File Transfer"></div><div class="field"><label>Порт SSH</label><input id="sftp-port" readonly value="22"></div><div class="field"><label>Логин</label><input id="sftp-user" readonly value="cs2s<?=$id?>"></div><div class="field full"><label>Стартовая папка</label><input id="sftp-dir" class="mono" readonly value="/gamefiles/game/csgo"></div></div><div class="flex"><span id="sftp-badge" class="badge wait">Проверяется</span><form method="post" class="ajaxform" data-sftp="1"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="sftp-enable"><button class="btn primary" id="sftp-enable">Включить / сменить пароль</button></form><form method="post" class="ajaxform" data-sftp="1" data-confirm="Отключить вход по SFTP для данного сервера?"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="sftp-disable"><button class="btn red">Отключить</button></form></div><div class="secretreveal hidden" id="sftp-secret"><strong>Новый SFTP пароль — показывается только сейчас!</strong><div class="flex" style="margin-top:9px"><code id="sftp-password" class="mono" style="font-size:15px;overflow-wrap:anywhere"></code><button class="btn sm" type="button" id="copy-password">Скопировать</button></div><div class="hint">После закрытия страницы пароль нельзя посмотреть — можно только создать новый.</div></div></div><div class="col5 card"><h2>Как подключиться</h2><div class="stack"><div><strong>1.</strong> Открой FileZilla или WinSCP</div><div><strong>2.</strong> Выбери протокол <b>SFTP</b> (не FTP)</div><div><strong>3.</strong> Введи IP, порт SSH и логин из панели</div><div><strong>4.</strong> Введи сгенерированный пароль</div><div><strong>5.</strong> Загружай конфиги и плагины в <code>addons/</code> и <code>cfg/</code></div></div><div class="notice warn" style="margin-top:20px">В общую базовую сборку записывать нельзя. Изменения сохраняются только в слое конкретного сервера. При обновлении общей базы активные SFTP-подключения следует закрыть.</div></div></div></section>
<section class="panel" data-panel="settings"><div class="card"><h2>Настройки сервера</h2><form method="post" class="ajaxform formgrid"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="settings"><div class="field"><label>Название в панели</label><input name="name" maxlength="96" value="<?=e($row['name'])?>" required></div><div class="field"><label>Hostname в игре</label><input name="hostname" maxlength="160" value="<?=e($row['hostname'])?>" required></div><div class="field"><label>UDP порт</label><input type="number" name="port" min="27015" max="27200" value="<?=(int)$row['port']?>" required></div><div class="field"><label>Слоты</label><input type="number" name="slots" min="2" max="32" value="<?=(int)$row['slots']?>" required></div><div class="field"><label>Стартовая карта</label><select name="map"><?php foreach($maps as $m):?><option value="<?=e($m)?>" <?=$m===$row['start_map']?'selected':''?>><?=e($m)?></option><?php endforeach;?></select></div><div class="field"><label>Режим</label><select name="mode"><?php foreach($modeNames as $k=>$v):?><option value="<?=e($k)?>" <?=$k===$row['game_mode']?'selected':''?>><?=e($v)?></option><?php endforeach;?></select></div><div class="field"><label>Новый GSLT (пусто = оставить)</label><input type="password" name="token" autocomplete="new-password"></div><div class="field"><label>Новый RCON пароль (пусто = оставить)</label><input type="password" name="rcon" autocomplete="new-password"></div><div class="field full"><label>Новый пароль входа в игру (пусто = оставить)</label><input type="password" name="password" autocomplete="new-password"></div><div class="field full"><button class="btn primary">Сохранить настройки</button><div class="hint" style="margin-top:6px">После изменения карты, режима и других параметров требуется перезапуск.</div></div></form></div><?php if(can_perm('server.delete')):?><div class="card" style="margin-top:18px;border-color:#6a3345"><h2 style="color:#ffa6b5">Удалить сервер</h2><p class="muted small">Безвозвратно удалятся настройки и индивидуальные файлы этого CS2-сервера. Общая сборка CS2 не удаляется.</p><form method="post" class="ajaxform flex" data-confirm="Удалить сервер и все его индивидуальные файлы? Действие необратимо."><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="delete"><input class="terminal-input" style="max-width:300px" name="confirm" placeholder="Введите DELETE" required><button class="btn red">Удалить сервер</button></form></div><?php endif;?></section>
<section class="panel" data-panel="config"><div class="card"><h2>Редактор server.cfg</h2><p class="muted small">Секреты RCON и GSLT скрыты и редактируются во вкладке «Настройки». Изменения сохраняются отдельно для этого сервера.</p><form method="post" class="ajaxform"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="save_cfg"><div class="field"><textarea name="config" spellcheck="false" id="cfg-editor" class="mono" maxlength="32768"><?=e((string)($config['text']??''))?></textarea></div><div class="flex" style="margin-top:14px"><button class="btn primary">Сохранить server.cfg</button><button type="button" class="btn ghost" id="reload-cfg">Обновить из сервера</button></div></form></div></section>
<section class="panel" data-panel="logs"><div class="card"><div class="flex between"><h2 style="margin:0">Логи запуска и работы</h2><button type="button" class="btn sm" id="reload-logs">↻ Обновить</button></div><p class="hint">Журнал systemd игрового сервера. Обновление каждые 8 секунд при открытой вкладке.</p><pre class="terminal" id="logs-out">Загрузка журнала...</pre></div></section>
<?php endif;?><footer class="footer">HYPER-HOST · CS2 v4 AJAX & SFTP · <a href="/">CS 1.6</a></footer></main><div id="toast" class="toastbox hidden" role="status" aria-live="polite"></div>
<script>
(()=>{'use strict';const id=<?=$id?>;const $=(s)=>document.querySelector(s);const $$=(s)=>Array.from(document.querySelectorAll(s));let tab='overview',busy=false,logPending=false;const esc=(s)=>String(s??'');
function toast(message,error=false){const t=$('#toast');if(!t)return;t.textContent=esc(message);t.classList.toggle('error',error);t.classList.remove('hidden');clearTimeout(window.csToastTimer);window.csToastTimer=setTimeout(()=>t.classList.add('hidden'),5000)}
async function get(action){let u='?ajax='+encodeURIComponent(action)+'&id='+encodeURIComponent(id);const r=await fetch(u,{credentials:'same-origin',cache:'no-store',headers:{'Accept':'application/json'}});const j=await r.json();if(!r.ok||j.ok===false)throw new Error(j.error||'Ошибка запроса');return j;}
async function send(form,submitter){if(busy)return;const msg=form.dataset.confirm;if(msg&&!confirm(msg))return;busy=true;const fd=new FormData(form);if(submitter&&submitter.name)fd.set(submitter.name,submitter.value);const btn=submitter||form.querySelector('button[type=submit],button');const old=btn?.innerHTML;if(btn){btn.disabled=true;btn.innerHTML='<span class="spinner"></span> Выполняется';}
try{const r=await fetch(location.pathname+location.search,{method:'POST',credentials:'same-origin',headers:{'X-Requested-With':'XMLHttpRequest','Accept':'application/json'},body:fd});const text=await r.text();let j;try{j=JSON.parse(text)}catch{throw new Error('Сервер вернул не JSON (HTTP '+r.status+'). Проверь PHP-лог.')}if(!r.ok||!j.ok)throw new Error(j.error||'Ошибка операции');if(j.password&&$('#sftp-secret')){$('#sftp-secret').classList.remove('hidden');$('#sftp-password').textContent=j.password;}
if(form.dataset.result==='console-out'&&$('#console-out'))$('#console-out').textContent=j.output||'(пустой ответ RCON)';if(j.redirect){location.assign(j.redirect);return;}toast(j.message||'Операция выполнена');if(form.dataset.sftp)loadSftp();if(id)refresh();else refreshBase();}
catch(e){toast(e.message,true)}finally{busy=false;if(btn){btn.disabled=false;btn.innerHTML=old;}}}
$$('.ajaxform').forEach(form=>form.addEventListener('submit',e=>{e.preventDefault();send(form,e.submitter)}));
$$('[data-tab]').forEach(b=>b.addEventListener('click',()=>openTab(b.dataset.tab)));
$$('[data-gotab]').forEach(b=>b.addEventListener('click',()=>openTab(b.dataset.gotab)));
function openTab(next){tab=next;$$('[data-tab]').forEach(b=>b.classList.toggle('active',b.dataset.tab===next));$$('[data-panel]').forEach(p=>p.classList.toggle('active',p.dataset.panel===next));if(next==='logs')loadLogs();if(next==='files')loadSftp();}
$$('[data-copy]').forEach(b=>b.addEventListener('click',()=>copy(b.dataset.copy)));
function copy(text){if(navigator.clipboard&&window.isSecureContext)navigator.clipboard.writeText(text).then(()=>toast('Скопировано')).catch(()=>toast('Не удалось скопировать',true));else toast('Скопируй значение вручную',true)}
$('#copy-password')?.addEventListener('click',()=>copy($('#sftp-password').textContent));
function prettyTime(sec){sec=Number(sec||0);if(!sec)return '—';const h=Math.floor(sec/3600),m=Math.floor(sec%3600/60);return h+' ч '+m+' мин';}
async function refresh(){if(!id||busy||document.hidden)return;try{const s=await get('status');const badge=$('#server-badge');badge.classList.toggle('good',!!s.running);badge.classList.toggle('wait',!s.running);$('#state-text').textContent=s.running?'Онлайн':s.state==='installing'?'Установка сервера':s.state==='failed'?'Ошибка установки':'Остановлен';$('#service-value').textContent=esc(s.service||'unknown');$('#players-value').textContent=s.players!==undefined?s.players+' / '+(s.max_players??s.slots):'—';$('#cpu-value').textContent=(s.cpu??0)+'%';$('#ram-value').textContent=(s.ram_mb??0)+' МБ';$('#current-map').textContent=s.current_map||s.map||'—';$('#uptime').textContent=prettyTime(s.uptime);$('#server-error').textContent=s.error||'';$('#server-error').classList.toggle('hidden',!s.error);}
catch(e){if(!document.hidden)toast('Статус: '+e.message,true)}}
async function loadLogs(){if(!id||logPending)return;logPending=true;try{const j=await get('logs');const box=$('#logs-out');if(box){const atBottom=box.scrollTop+box.clientHeight>=box.scrollHeight-40;box.textContent=j.logs||'Нет записей';if(atBottom)box.scrollTop=box.scrollHeight;}}catch(e){toast(e.message,true)}finally{logPending=false}}
async function loadSftp(){if(!id)return;try{const x=await get('sftp');$('#sftp-badge').textContent=x.enabled?'SFTP включён':x.ready?'SFTP отключён':'Сервер ещё устанавливается';$('#sftp-badge').classList.toggle('good',!!x.enabled);$('#sftp-badge').classList.toggle('wait',!x.enabled);$('#sftp-port').value=x.port||22;$('#sftp-user').value=x.username||('cs2s'+id);$('#sftp-dir').value=x.remote_dir||'/gamefiles/game/csgo';}catch(e){toast(e.message,true)}}
async function refreshBase(){try{const b=await get('base');$('#base-badge').textContent=b.ready?'Установлена':b.state==='installing'?'Устанавливается':'Не готова';$('#base-badge').classList.toggle('good',!!b.ready);$('#base-badge').classList.toggle('wait',!b.ready);$('#mapcount').textContent=b.maps_count??0;}catch(e){console.debug(e)}}
$('#reload-logs')?.addEventListener('click',loadLogs);$('#reload-cfg')?.addEventListener('click',async()=>{if(!confirm('Заменить несохранённый текст текущим server.cfg?'))return;try{$('#cfg-editor').value=(await get('config')).text||'';toast('Конфигурация обновлена')}catch(e){toast(e.message,true)}});
if(id){refresh();setInterval(()=>{if(tab==='logs')loadLogs();},8000);setInterval(refresh,7000);}setInterval(refreshBase,15000);
})();
</script></body></html>
HYPER_CS2_AJAX_PANEL_V4
python3 - "$CTL" "$TMP/addon.py" "$TMP/controller" <<'PATCH_PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);addon=pathlib.Path(sys.argv[2]).read_text();src=p.read_text()
if 'HYPER-HOST v4 SFTP isolated' not in src:
    old='def main():\n'
    if src.count(old)!=1: raise SystemExit('[ERROR] CS2 controller structure changed: no main()')
    src=src.replace(old,addon+'\n\n'+old,1)
    mark="'config-save','rcon','delete','logs']"
    if src.count(mark)!=1: raise SystemExit('[ERROR] CS2 controller actions changed')
    src=src.replace(mark,"'config-save','rcon','delete','logs','sftp-status','sftp-enable','sftp-reset','sftp-disable']",1)
    mark2="    if act=='_mount': return mount_overlay(i)"
    if src.count(mark2)!=1: raise SystemExit('[ERROR] CS2 controller routing changed')
    addition="    if act=='sftp-status': return output(sftp_info(i))\n    if act in ('sftp-enable','sftp-reset'): return sftp_enable(i)\n    if act=='sftp-disable': return sftp_disable(i)\n"
    src=src.replace(mark2,addition+mark2,1)
    # Include asynchronous provisioning logs; otherwise "installing/inactive" has no useful diagnostics in UI.
    old_log="['journalctl','-u',unit(i),'-n','100','--no-pager','-o','cat']"
    new_log="['journalctl','-u',unit(i),'-u',installunit(i),'-n','140','--no-pager','-o','cat']"
    if src.count(old_log)!=1: raise SystemExit('[ERROR] CS2 controller logs route changed')
    src=src.replace(old_log,new_log,1)
else:
    print('[OK] Controller already contains v4 SFTP extension')
pathlib.Path(sys.argv[3]).write_text(src)
PATCH_PY
python3 -m py_compile "$TMP/controller"
php -l "$TMP/cs2.php"
# Add SFTP-only OpenSSH Match section at the end of main config; using a drop-in
# at the beginning of Debian sshd_config would incorrectly apply Match to subsequent global directives.
# Never change SSH port, root login, or default authentication rules.
if ! grep -q '^# HYPER-HOST CS2 SFTP v4 BEGIN$' /etc/ssh/sshd_config; then
  cat >> /etc/ssh/sshd_config <<'SFTP_MATCH'

# HYPER-HOST CS2 SFTP v4 BEGIN
Match Group hypercs2sftp
    ChrootDirectory %h
    ForceCommand internal-sftp -d /gamefiles/game/csgo -u 0027
    PasswordAuthentication yes
    PermitTTY no
    X11Forwarding no
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTunnel no
# HYPER-HOST CS2 SFTP v4 END
SFTP_MATCH
fi
if ! /usr/sbin/sshd -t; then
    cp -a "$BACKUP/sshd_config" /etc/ssh/sshd_config
    /usr/sbin/sshd -t || true
    echo '[ERROR] SSH syntax check failed. Original sshd_config restored. CS2 unchanged.' >&2
    exit 1
fi
if ! getent group hypercs2sftp >/dev/null; then
    groupadd --system hypercs2sftp
fi
# Reload, not restart; existing SSH connections continue.
if systemctl is-active --quiet ssh; then
    systemctl reload ssh || { echo '[WARN] ssh reload failed: check sudo systemctl status ssh'; }
elif systemctl is-active --quiet sshd; then
    systemctl reload sshd || { echo '[WARN] sshd reload failed: check sudo systemctl status sshd'; }
else
    echo '[WARN] SSH service not active: SFTP will require an active OpenSSH daemon'
fi
install -m 0755 "$TMP/controller" "$CTL"
install -m 0644 "$TMP/cs2.php" "$PANEL"
chown www-data:www-data "$PANEL"
python3 -m py_compile "$CTL"
php -l "$PANEL"
echo
printf '%s
' '====================================================' ' HYPER-HOST CS2 AJAX + SFTP v4 INSTALLED' " Panel: https://$DOMAIN/cs2.php" " Backup: $BACKUP" ' Status: sudo hyper-cs2-ctl doctor' ' SFTP: FileZilla / WinSCP, SFTP over SSH' ' CS 1.6 and CS2 SteamCMD/download untouched.' '===================================================='
"$CTL" doctor || true

__CS2_V5_V4_EMBED_END__

if ! grep -q 'def mount_overlay_unlocked' "$CTL"; then
  printf '[2/7] Shared storage v3 missing. Installing it (preserving current CS2 base)...\n'
  bash "$TEMP/apply-v3.sh"
else echo '[2/7] Shared storage v3 detected'; fi
if ! grep -q 'HYPER-HOST v4 SFTP isolated' "$CTL"; then
  printf '[3/7] AJAX and SFTP v4 missing. Installing...\n'
  bash "$TEMP/apply-v4.sh"
else echo '[3/7] AJAX/SFTP v4 detected'; fi
printf '[4/7] Adding secure file editor and dedicated diagnostics...\n'
cat > "$TEMP/v5_addon.py" <<'__CS2_V5_ADDON_END__'
# HYPER-HOST v5 scoped browser editor and diagnostics; injected before main()
import stat as v5_stat, hashlib as v5_hash, datetime as v5_dt
V5_ROOT_DIRS = {'cfg','addons','logs','maps','scripts'}
V5_TEXT_EXTENSIONS = {'.cfg','.txt','.json','.ini','.toml','.yaml','.yml','.xml','.vdf','.md','.js','.py','.cs','.log','.properties','.kv3'}
V5_LIMIT = 200000

def v5_body(limit=230000):
    content=sys.stdin.buffer.read(limit+1)
    if len(content)>limit: fail('Превышен лимит запроса')
    try: return json.loads(content)
    except (ValueError,UnicodeDecodeError): fail('Некорректный JSON')

def v5_path(i, relative='.', directory=False):
    if not isinstance(relative,str) or len(relative)>400: fail('Некорректный путь')
    if relative in ('','.'): bits=[]
    else:
        bits=relative.split('/')
        if not bits or bits[0] not in V5_ROOT_DIRS: fail('Доступен только cfg, addons, scripts, maps и logs')
        if any(not re.fullmatch(r'[a-zA-Z0-9_\- .+@()]{1,100}',v) or v in ('.','..') or v.startswith('.') for v in bits):
            fail('Недопустимое имя папки/файла')
    c=load(i)
    if c.get('state')!='ready': fail('Файлы станут доступны после установки экземпляра CS2')
    if storage_mode(c)=='overlay':
        with base_lock(shared=True):
            if base_busy(): fail('Общая база CS2 сейчас обновляется')
            mount_overlay_unlocked(i)
    root=gamepath(i)/'gamefiles/game/csgo'
    if not root.is_dir() or root.is_symlink(): fail('Игровая директория не подготовлена')
    dest=root
    for component in bits:
        dest=dest/component
        if dest.is_symlink(): fail('Символьные ссылки недоступны в редакторе')
    if directory and dest.exists() and not dest.is_dir(): fail('Путь не является директорией')
    return dest

def v5_allow_text(path,relative):
    if relative in ('','.'): fail('Укажи файл')
    if str(relative).lower()=='cfg/server.cfg': fail('server.cfg меняется в отдельном защищённом редакторе')
    if path.suffix.lower() not in V5_TEXT_EXTENSIONS: fail('Этот тип файла редактируется через SFTP, а не через браузер')

def v5_list(i,data):
    rel=str(data.get('path','.'))
    folder=v5_path(i,rel,directory=True)
    if not folder.is_dir(): fail('Директория не существует')
    items=[]
    for child in folder.iterdir():
        if child.is_symlink() or child.name.startswith('.'): continue
        if rel in ('','.'): 
            if child.name not in V5_ROOT_DIRS: continue
        if len(items)>=300: break
        try:
            st=child.lstat()
            if not (v5_stat.S_ISDIR(st.st_mode) or v5_stat.S_ISREG(st.st_mode)): continue
            isdir=v5_stat.S_ISDIR(st.st_mode)
            items.append({'name':child.name,'type':'directory' if isdir else 'file',
                          'size':st.st_size if not isdir else None,
                          'editable':not isdir and child.suffix.lower() in V5_TEXT_EXTENSIONS
                                     and (rel.rstrip('/')+'/'+child.name).lstrip('./').lower()!='cfg/server.cfg'})
        except OSError: continue
    items.sort(key=lambda v:(v['type']!='directory',v['name'].lower()))
    output({'ok':True,'path':rel,'items':items,'limit':300})

def v5_read(i,data):
    rel=str(data.get('path',''))
    path=v5_path(i,rel)
    v5_allow_text(path,rel)
    if not path.is_file(): fail('Файл не найден')
    if path.stat().st_size>V5_LIMIT: fail('Файл больше 200 КБ — используй SFTP')
    try: body=path.read_text(encoding='utf-8')
    except UnicodeError: fail('Файл не является текстом UTF-8 — используй SFTP')
    output({'ok':True,'path':rel,'content':body})

def v5_save(i,data):
    rel=str(data.get('path',''))
    body=data.get('content')
    if not isinstance(body,str) or len(body.encode('utf-8'))>V5_LIMIT or '\0' in body: fail('Допустим текст UTF-8 до 200 КБ')
    p=v5_path(i,rel)
    v5_allow_text(p,rel)
    parent=v5_path(i,str(pathlib.PurePosixPath(rel).parent),directory=True)
    if not parent.is_dir(): fail('Родительская директория не существует')
    if p.exists() and not p.is_file(): fail('Можно сохранять только обычные файлы')
    if p.exists() and p.stat().st_size>V5_LIMIT: fail('Файл слишком большой, используй SFTP')
    if p.exists():
        backup=gamepath(i)/'edit-backups'
        backup.mkdir(mode=0o700,exist_ok=True)
        if backup.is_symlink(): fail('Недопустимая папка резервных копий')
        name=v5_hash.sha256(rel.encode()).hexdigest()[:12]+'-'+v5_dt.datetime.utcnow().strftime('%Y%m%d%H%M%S%f')+'.bak'
        shutil.copyfile(p,backup/name)
        os.chmod(backup/name,0o600)
    fd,tmp=tempfile.mkstemp(prefix='.cs2edit-',dir=parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            f.write(body);f.flush();os.fsync(f.fileno())
        info=pwd.getpwnam(user(i))
        os.chown(tmp,info.pw_uid,info.pw_gid)
        os.chmod(tmp,0o640)
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
    output({'ok':True,'message':'Файл сохранён','path':rel,'restart_required':True})

def v5_mkdir(i,data):
    rel=str(data.get('path',''))
    p=v5_path(i,rel)
    if len(rel.split('/'))<2: fail('Корневые директории изменить нельзя')
    parent=v5_path(i,str(pathlib.PurePosixPath(rel).parent),directory=True)
    if not parent.is_dir(): fail('Родительская директория не существует')
    if p.exists(): fail('Папка уже существует')
    p.mkdir(mode=0o750)
    info=pwd.getpwnam(user(i));os.chown(p,info.pw_uid,info.pw_gid)
    output({'ok':True,'message':'Папка создана','path':rel})

def v5_delete(i,data):
    rel=str(data.get('path',''))
    p=v5_path(i,rel)
    v5_allow_text(p,rel)
    if not p.is_file(): fail('Для безопасности через панель удаляются только текстовые файлы')
    if p.stat().st_size>V5_LIMIT: fail('Большие файлы удаляются через SFTP')
    backup=gamepath(i)/'edit-backups'; backup.mkdir(mode=0o700,exist_ok=True)
    if backup.is_symlink(): fail('Недопустимая папка резервных копий')
    name=v5_hash.sha256(rel.encode()).hexdigest()[:12]+'-'+v5_dt.datetime.utcnow().strftime('%Y%m%d%H%M%S%f')+'.deleted'
    shutil.copyfile(p,backup/name); os.chmod(backup/name,0o600)
    p.unlink()
    output({'ok':True,'message':'Файл удалён (создана резервная копия)','path':rel})

def v5_log(i,data):
    kind=str(data.get('kind','runtime'))
    if kind=='runtime':
        result=cp(['journalctl','-u',unit(i),'-n','160','--no-pager','-o','short-iso'],check=False,timeout=12)
        content=result.stdout
    elif kind=='install':
        result=cp(['journalctl','-u',installunit(i),'-n','160','--no-pager','-o','short-iso'],check=False,timeout=12)
        content=result.stdout
    elif kind=='game':
        folder=v5_path(i,'logs',directory=True)
        logs=[p for p in folder.iterdir() if p.is_file() and not p.is_symlink() and p.suffix.lower() in ('.log','.txt')]
        logs.sort(key=lambda p:p.stat().st_mtime,reverse=True)
        content=(logs[0].read_bytes()[-30000:].decode('utf-8','replace') if logs else 'Файлового лога игры пока нет. Используй вкладку «Процесс CS2».')
    elif kind=='base':
        result=cp(['journalctl','-u','hyper-cs2-base-install.service','-u','hyper-cs2-base-update.service',
                   '-n','120','--no-pager','-o','short-iso'],check=False,timeout=12)
        content=result.stdout
    else: fail('Недопустимый тип лога')
    output({'ok':True,'kind':kind,'logs':content[-40000:] if content else 'Записей пока нет'})

__CS2_V5_ADDON_END__
cat > "$TEMP/v5_patcher.py" <<'__CS2_V5_PATCHER_END__'
import pathlib,sys,re
ctl=pathlib.Path(sys.argv[1]);panel=pathlib.Path(sys.argv[2]);addon=pathlib.Path(sys.argv[3]).read_text()
s=ctl.read_text()
if 'HYPER-HOST v5 scoped browser' not in s:
    def rep(old,new,count=1):
        global s
        if s.count(old)!=count:raise RuntimeError('Controller structure unexpected: '+old[:100]+' count '+str(s.count(old)))
        s=s.replace(old,new,count)
    rep('def main():\n', addon+'\n\ndef main():\n')
    pat=r"(parser\.add_argument\('action',choices=\[)([^\]]+)(\]\))"
    m=re.search(pat,s)
    if not m:raise RuntimeError('Python argparse choices not found')
    choices=m.group(2)
    s=s[:m.start()]+m.group(1)+choices+",'file-list','file-read','file-save','file-mkdir','file-delete','log-v5'"+m.group(3)+s[m.end():]
    mark="    if act=='_mount': return mount_overlay(i)"
    addition="""    if act in ('file-list','file-read','file-save','file-mkdir','file-delete','log-v5'):
        data=v5_body()
        if not isinstance(data,dict): fail('Expected JSON object')
        # Hold a shared lock for the WHOLE operation; base-update requires exclusive lock.
        if act=='log-v5' and data.get('kind','runtime') in ('runtime','install','base'):
            return v5_log(i,data)
        with base_lock(shared=True):
            if base_busy(): fail('Общая CS2 сейчас устанавливается или обновляется')
            if act=='file-list': return v5_list(i,data)
            if act=='file-read': return v5_read(i,data)
            if act=='file-save': return v5_save(i,data)
            if act=='file-mkdir': return v5_mkdir(i,data)
            if act=='file-delete': return v5_delete(i,data)
            if act=='log-v5': return v5_log(i,data)
"""
    rep(mark,addition+mark)
    ctl.write_text(s)

p=panel.read_text()
if 'HYPER-HOST CS2 v5 FILES API' not in p:
    def phrep(old,new,count=1):
        global p
        if p.count(old)!=count:raise RuntimeError('PHP structure unexpected: '+old[:140]+' count '+str(p.count(old)))
        p=p.replace(old,new,count)
    # backend: existing owner / admin authorization from cs4row() and CSRF on POST
    phrep("  if($action==='delete'){", """  // HYPER-HOST CS2 v5 FILES API. Ownership and CSRF are enforced above.
  if(in_array($action,['file-save','file-mkdir','file-delete'],true)){
    $path=(string)($_POST['path']??'');
    if(strlen($path)>400)throw new RuntimeException('Слишком длинный путь');
    $operation=['file-save'=>'file-save','file-mkdir'=>'file-mkdir','file-delete'=>'file-delete'][$action];
    $payload=['path'=>$path];
    if($action==='file-save'){
      $content=(string)($_POST['content']??'');
      if(strlen($content)>200000)throw new RuntimeException('Лимит редактора — 200 КБ');
      $payload['content']=$content;
    }
    return cs4ctl([$operation,$id],json_encode($payload,JSON_UNESCAPED_UNICODE|JSON_INVALID_UTF8_SUBSTITUTE),35);
  }
  if($action==='delete'){""")
    phrep("    if($act==='sftp'){$v=cs4ctl(['sftp-status',$id]);cs4json($v);}","""    if($act==='sftp'){$v=cs4ctl(['sftp-status',$id]);cs4json($v);}
    if($act==='v5-files'){
      $v=cs4ctl(['file-list',$id],json_encode(['path'=>(string)($_GET['path']??'.')]),15);cs4json($v);
    }
    if($act==='v5-read'){
      $v=cs4ctl(['file-read',$id],json_encode(['path'=>(string)($_GET['path']??'')]),15);cs4json($v);
    }
    if($act==='v5-logs'){
      $kind=(string)($_GET['kind']??'runtime');
      if(!in_array($kind,['runtime','install','game','base'],true))throw new RuntimeException('Неверный тип лога');
      if($kind==='base'&&!$isAdmin)throw new RuntimeException('Общий SteamCMD-журнал доступен администратору');
      $v=cs4ctl(['log-v5',$id],json_encode(['kind'=>$kind]),18);cs4json($v);
    }""")
    # Ensure readable IP; never use outside HTTP forwarding headers.
    phrep("$ip=(string)cfg('public_ip');$flash=flash();", """$ip=trim((string)cfg('public_ip'));
if($ip==='')$ip=(string)($_SERVER['SERVER_ADDR']??'');
if($ip==='')$ip='IP не указан';
$flash=flash();""")
    # Show one-click connect address in Overview.
    phrep('<strong class="mono"><?=e($ip)?>:<?=(int)$row[\'port\']?></strong>',
          '<div class="flex"><strong class="mono"><?=e($ip)?>:<?=(int)$row[\'port\']?></strong><button type="button" class="btn sm" data-copy="<?=e($ip.\':\'.$row[\'port\'])?>">Копировать IP:порт</button></div>')
    # Editor with own file path; editor only text files, binary through SFTP.
    browser='''
<div class="card" style="margin-top:18px" id="v5-browser">
 <div class="flex between"><h2 style="margin:0">Файловый менеджер CS2</h2><button type="button" class="btn sm" id="v5-reload">↻ Обновить</button></div>
 <p class="hint">Настройки, дополнения, скрипты и логи сервера. В браузере редактируются текстовые файлы до 200 КБ, бинарные файлы загружаются через SFTP. server.cfg — в отдельной вкладке.</p>
 <div class="flex" style="margin:12px 0"><button type="button" class="btn sm" id="v5-up">↑ Назад</button><code id="v5-dir" class="mono" style="overflow-wrap:anywhere">.</code><button type="button" class="btn sm" id="v5-new-file">+ Файл</button><button type="button" class="btn sm" id="v5-new-dir">+ Папка</button></div>
 <div id="v5-file-list" class="v5-list" aria-live="polite">Нажми «Обновить» для просмотра файлов</div>
 <form method="post" id="v5-editor-form" class="ajaxform hidden" data-v5edit="1" style="margin-top:20px">
  <?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="file-save"><input type="hidden" name="path" id="v5-edit-path">
  <div class="flex between"><h2 style="margin:0">Текстовый редактор</h2><strong id="v5-edit-title" class="mono small"></strong></div>
  <div class="field" style="margin:13px 0"><textarea name="content" id="v5-edit-body" maxlength="200000" rows="16" class="mono" spellcheck="false" style="min-height:300px"></textarea></div>
  <div class="flex"><button type="submit" class="btn primary">Сохранить файл</button><button type="button" class="btn ghost" id="v5-close-file">Закрыть</button><button type="button" class="btn red" id="v5-delete-file">Удалить файл</button></div>
 </form>
 <form method="post" class="ajaxform hidden" id="v5-delete-form" data-v5edit="1" data-confirm="Удалить файл? Перед удалением будет создана резервная копия."><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="file-delete"><input type="hidden" name="path" id="v5-del-path"><button type="submit">Удалить</button></form>
 <form method="post" class="ajaxform hidden" id="v5-mkdir-form" data-v5edit="1"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="file-mkdir"><input type="hidden" name="path" id="v5-mkdir-path"><button type="submit">Создать</button></form>
</div>
'''
    phrep('</div></section>\n<section class="panel" data-panel="settings">', '</div>'+browser+'</section>\n<section class="panel" data-panel="settings">')
    phrep('<h2 style="margin:0">Логи запуска и работы</h2>', '''<h2 style="margin:0">Живые логи</h2><select id="v5-log-kind" class="terminal-input" style="max-width:230px" aria-label="Тип журнала"><option value="runtime">Процесс CS2</option><option value="install">Установка сервера</option><option value="game">Файловый лог CS2</option><?php if($isAdmin):?><option value="base">SteamCMD / база</option><?php endif;?></select>''')
    phrep('<p class="hint">Журнал systemd игрового сервера. Обновление каждые 8 секунд при открытой вкладке.</p>', '<p class="hint">Раздельные журналы с отметками времени; автоматическое обновление каждые 8 секунд. При установке выбери «Установка сервера».</p>')
    phrep('<pre id="console-out" class="terminal" style="margin-top:16px">Результат команды появится здесь.</pre>', '<pre id="console-out" class="terminal" style="margin-top:16px">Результат команды появится здесь.</pre><h2 style="margin-top:24px">Вывод процесса CS2</h2><p class="hint">Живой вывод игрового процесса из systemd. При неисправном запуске смотри также вкладку «Логи → Установка сервера».</p><pre id="v5-console-stream" class="terminal">Загрузка...</pre>')
    phrep('</style></head><body>', '''.v5-list{display:grid;gap:5px;max-height:330px;overflow:auto;margin-top:10px}.v5-item{display:flex;gap:8px;align-items:center;justify-content:space-between;text-align:left;width:100%;padding:10px 12px;color:#d9e8ff;background:#0c1629;border:1px solid #263c5d;border-radius:10px}.v5-item:hover{background:#142542;border-color:#4b82db}.v5-item small{font-size:11px;color:#91a4c2}#v5-browser .field textarea{width:100%;background:#060c17;color:#d5fce3;border:1px solid #34506b;border-radius:11px;padding:14px}
</style></head><body>''')
    # Small extensions to v4 JS. get() takes extra query safely through URLSearchParams.
    phrep("function get(action){let u='?ajax='+encodeURIComponent(action)+'&id='+encodeURIComponent(id);", "function get(action,extra={}){let u='?'+new URLSearchParams({ajax:action,id:String(id),...extra}).toString();")
    phrep("if(form.dataset.sftp)loadSftp();if(id)refresh();", "if(form.dataset.sftp)loadSftp();if(form.dataset.v5edit)loadFiles();if(id)refresh();")
    phrep("if(next==='logs')loadLogs();if(next==='files')loadSftp();", "if(next==='logs')loadLogs();if(next==='files'){loadSftp();loadFiles();}")
    phrep("const j=await get('logs');const box=$('#logs-out');", "const j=await get('v5-logs',{kind:$('#v5-log-kind')?.value||'runtime'});const box=$('#logs-out');")
    phrep("$('#reload-logs')?.addEventListener('click',loadLogs);", "$('#reload-logs')?.addEventListener('click',loadLogs);$('#v5-log-kind')?.addEventListener('change',loadLogs);")
    # Insert scripts inside existing IIFE before if(id)...
    marker="if(id){refresh();setInterval(()=>{if(tab==='logs')loadLogs();},8000);"
    extra_js=pathlib.Path(sys.argv[4]).read_text()
    phrep(marker, extra_js+'\n'+marker)
    phrep('HYPER-HOST · CS2 v4 AJAX & SFTP', 'HYPER-HOST · CS2 v5 AJAX / Files / SFTP')
    panel.write_text(p)
__CS2_V5_PATCHER_END__
cat > "$TEMP/v5_js.txt" <<'__CS2_V5_JS_END__'
// HYPER-HOST CS2 v5 file browser (all entries rendered as textContent)
let v5Folder='.';
let v5File='';
function v5Path(name){return v5Folder==='.'?name:v5Folder+'/'+name;}
function v5Close(){const form=$('#v5-editor-form');if(form)form.classList.add('hidden');v5File='';}
function v5ShowEditor(path,content){v5File=path;$('#v5-edit-path').value=path;$('#v5-edit-title').textContent=path;$('#v5-edit-body').value=content;$('#v5-editor-form').classList.remove('hidden');}
async function loadFiles(){
 if(!id)return;
 const holder=$('#v5-file-list');if(!holder)return;
 try{
  const data=await get('v5-files',{path:v5Folder});
  $('#v5-dir').textContent='/game/csgo/'+(v5Folder==='.'?'':v5Folder);
  holder.replaceChildren();
  for(const f of data.items||[]){
   const line=document.createElement('button');line.type='button';line.className='v5-item';
   const name=document.createElement('span');name.textContent=(f.type==='directory'?'📁 ':'📄 ')+f.name;
   const meta=document.createElement('small');meta.textContent=f.type==='directory'?'Каталог':(f.editable?'Редактировать · ':'SFTP · ')+(Number(f.size||0)/1024).toFixed(1)+' КБ';
   line.append(name,meta);
   line.addEventListener('click',async()=>{
    if(f.type==='directory'){v5Folder=v5Path(f.name);v5Close();loadFiles();return;}
    if(!f.editable){toast('Этот файл можно изменить через SFTP',true);return;}
    try{const x=await get('v5-read',{path:v5Path(f.name)});v5ShowEditor(x.path,x.content);}
    catch(e){toast(e.message,true)}
   });holder.append(line);
  }
  if(!holder.childNodes.length)holder.textContent='Здесь нет доступных файлов';
 }catch(e){holder.textContent=e.message;toast(e.message,true)}
}
$('#v5-reload')?.addEventListener('click',loadFiles);
$('#v5-up')?.addEventListener('click',()=>{v5Folder=v5Folder.includes('/')?v5Folder.slice(0,v5Folder.lastIndexOf('/')):'.';v5Close();loadFiles();});
$('#v5-close-file')?.addEventListener('click',v5Close);
$('#v5-new-file')?.addEventListener('click',()=>{
 if(v5Folder==='.')return toast('Сначала открой cfg, addons или scripts',true);
 const name=prompt('Имя нового текстового файла (например, settings.cfg)');
 if(!name)return;
 if(!/^[\w .+@()-]{1,100}$/.test(name)||name.startsWith('.')||name.includes('/')||name==='..')return toast('Недопустимое имя',true);
 v5ShowEditor(v5Path(name),'');
});
$('#v5-new-dir')?.addEventListener('click',async()=>{
 if(v5Folder==='.')return toast('Сначала открой каталог',true);
 const name=prompt('Название новой папки');if(!name)return;
 if(!/^[\w .+@()-]{1,100}$/.test(name)||name.startsWith('.'))return toast('Недопустимое имя',true);
 $('#v5-mkdir-path').value=v5Path(name);$('#v5-mkdir-form').requestSubmit();
});
$('#v5-delete-file')?.addEventListener('click',()=>{
 if(!v5File)return;
 $('#v5-del-path').value=v5File;
 $('#v5-delete-form').requestSubmit();
 v5Close();
});

async function v5LoadConsole(){
 if(!id||tab!=='console')return;
 const box=$('#v5-console-stream');if(!box)return;
 try{const x=await get('v5-logs',{kind:'runtime'});const wasBottom=box.scrollTop+box.clientHeight>=box.scrollHeight-35;box.textContent=x.logs||'Нет сообщений';if(wasBottom)box.scrollTop=box.scrollHeight;}
 catch(e){box.textContent=e.message;}
}
$$('[data-tab="console"]').forEach(b=>b.addEventListener('click',v5LoadConsole));
setInterval(()=>{if(tab==='console'&&!document.hidden)v5LoadConsole();},5000);
__CS2_V5_JS_END__

# Generate both files in a staging area; lint before replacing live services.
cp -a "$CTL" "$TEMP/hyper-cs2-ctl.new"
cp -a "$PANEL" "$TEMP/cs2.php.new"
python3 "$TEMP/v5_patcher.py" "$TEMP/hyper-cs2-ctl.new" "$TEMP/cs2.php.new" "$TEMP/v5_addon.py" "$TEMP/v5_js.txt"
python3 -m py_compile "$TEMP/hyper-cs2-ctl.new"
php -l "$TEMP/cs2.php.new"
if command -v node >/dev/null 2>&1; then
  python3 - "$TEMP/cs2.php.new" "$TEMP/ui.js" <<'EXTRACTJS'
import re,pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(); found=re.findall(r'<script>(.*?)</script>',s,re.S)
if len(found)==1: pathlib.Path(sys.argv[2]).write_text(re.sub(r'<\?=.*?\?>','1',found[0]))
EXTRACTJS
  [[ ! -s "$TEMP/ui.js" ]] || node --check "$TEMP/ui.js"
fi
printf '[5/7] Installing validated CS2 files...\n'
cp -a "$CTL" "$TEMP/controller.before-v5"
cp -a "$PANEL" "$TEMP/panel.before-v5"
install -m 0755 "$TEMP/hyper-cs2-ctl.new" "$CTL"
install -m 0644 "$TEMP/cs2.php.new" "$PANEL"
chown www-data:www-data "$PANEL"
# Restore files if a post-install check fails.
if ! python3 -m py_compile "$CTL" || ! php -l "$PANEL"; then
  echo '[ERROR] Post-install validation failed, restoring controller and panel immediately before v5 changes' >&2
  cp -a "$TEMP/controller.before-v5" "$CTL"
  cp -a "$TEMP/panel.before-v5" "$PANEL"
  exit 1
fi
printf '[6/7] Checking SSH syntax (no SSH changes by v5 beyond optional v4 setup)...\n'
if [[ -x /usr/sbin/sshd ]]; then /usr/sbin/sshd -t; fi
printf '[7/7] Final diagnostics...\n'
"$CTL" doctor || true
printf '\n===============================================================\n'
printf ' HYPER-HOST CS2 v5 INSTALLED\n'
printf ' Panel: https://%s/cs2.php\n' "$DOMAIN"
printf ' Backup: %s\n' "$BACKUP"
printf ' Includes v3 shared storage and v4 AJAX/SFTP where needed\n'
printf ' CS1.6 files and common CS2 game download untouched\n'
printf '===============================================================\n'
