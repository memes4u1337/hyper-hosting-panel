#!/usr/bin/env bash
# HYPER-HOST | Counter-Strike 2 hosting module v1.0
# Does not touch CS 1.6 game data, unit files, controllers or SQL tables.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '[ERROR] Use sudo/root'; exit 1; }
export DEBIAN_FRONTEND=noninteractive
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/hyper-cs2-patch-v1-$STAMP"
mkdir -p "$BACKUP"
trap 'echo "[ERROR] Patch failed at line $LINENO (backup: $BACKUP)" >&2' ERR
log(){ printf '\n[CS2 PATCH] %s\n' "$*"; }
need(){ command -v "$1" >/dev/null || { echo "[ERROR] Missing $1" >&2; exit 1; }; }
for cmd in php python3 systemctl apt-get; do need "$cmd"; done
[[ "$(uname -m)" == "x86_64" ]] || { echo "[ERROR] CS2 requires x86_64 Linux"; exit 1; }
[[ -r /etc/hyper-cs16/panel.php ]] || { echo '[ERROR] Existing CS1.6 hosting not detected'; exit 1; }
DOMAIN=$(php -r '$c=require "/etc/hyper-cs16/panel.php";echo $c["domain"]??"";')
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo '[ERROR] Invalid existing panel domain'; exit 1; }
WEB="/var/www/hyper-host-sites/$DOMAIN/public_html"
APP="/var/www/hyper-host-sites/$DOMAIN/app"
[[ -f "$WEB/index.php" && -f "$APP/bootstrap.php" ]] || { echo "[ERROR] CS16 panel missing under $WEB"; exit 1; }
log "Panel: $DOMAIN; creating backup"
cp -a "$WEB/index.php" "$BACKUP/index.php"
[[ ! -e "$WEB/cs2.php" ]] || cp -a "$WEB/cs2.php" "$BACKUP/cs2.php"
[[ ! -e /usr/local/sbin/hyper-cs2-ctl ]] || cp -a /usr/local/sbin/hyper-cs2-ctl "$BACKUP/hyper-cs2-ctl"
log 'Installing 64-bit CS2 / 32-bit SteamCMD dependencies'
apt-get update -qq
apt-get install -y -qq ca-certificates curl tar rsync sudo python3 libatomic1 libstdc++6 libgcc-s1 lib32gcc-s1 lib32stdc++6 >/dev/null
install -d -m 0755 /opt/hyper-cs2 /srv/hyper-cs2 /var/lib/hyper-cs2 /var/lib/hyper-cs2/servers
if ! id cs2build >/dev/null 2>&1; then useradd --system --user-group --create-home --home-dir /opt/hyper-cs2 --shell /usr/sbin/nologin cs2build; fi
if ! getent group cs2build >/dev/null; then groupadd --system cs2build; usermod -g cs2build cs2build; fi
install -d -o cs2build -g cs2build -m 0755 /opt/hyper-cs2/steamcmd /srv/hyper-cs2/base
install -d -m 0755 /srv/hyper-cs2/servers
chmod 0700 /var/lib/hyper-cs2/servers
if [[ ! -f /opt/hyper-cs2/steamcmd/steamcmd.sh ]]; then
  log 'Installing isolated SteamCMD for CS2'
  curl -fLSs --retry 4 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' -o /opt/hyper-cs2/steamcmd/steamcmd.tar.gz
  tar -xzf /opt/hyper-cs2/steamcmd/steamcmd.tar.gz -C /opt/hyper-cs2/steamcmd
  rm /opt/hyper-cs2/steamcmd/steamcmd.tar.gz
fi
chown -R cs2build:cs2build /opt/hyper-cs2/steamcmd /srv/hyper-cs2/base
chmod 0755 /opt/hyper-cs2/steamcmd/steamcmd.sh

log 'Installing CS2 privileged controller'
cat > /usr/local/sbin/hyper-cs2-ctl <<'PY'
#!/usr/bin/env python3
"""HYPER-HOST CS2 controller: root only, JSON output, no shell=True."""
import argparse, json, os, pathlib, pwd, re, shutil, socket, struct, subprocess, sys, tempfile, time
ROOT=pathlib.Path('/srv/hyper-cs2')
BASE=ROOT/'base'
SERVERS=ROOT/'servers'
STATE=pathlib.Path('/var/lib/hyper-cs2/servers')
STEAMCMD=pathlib.Path('/opt/hyper-cs2/steamcmd/steamcmd.sh')
MAP_RE=re.compile(r'^[A-Za-z0-9_]{1,64}$')
MODES={'competitive':(0,1),'casual':(0,0),'deathmatch':(1,2),'wingman':(0,2)}

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
def validate_map(s):
    if not isinstance(s,str) or not MAP_RE.fullmatch(s): fail('Invalid map')
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

def base_ready(): return (BASE/'game/bin/linuxsteamrt64/cs2').is_file()

def prepare_sdk(home,steamroot):
    dest=home/'.steam/sdk64'
    dest.mkdir(parents=True,exist_ok=True)
    target=steamroot/'linux64/steamclient.so'
    if target.is_file():
        link=dest/'steamclient.so'
        if link.is_symlink() or link.is_file(): link.unlink()
        link.symlink_to(target)

def steam_update(root,steamroot,uname):
    # SteamCMD uses local writable self-update files; never use shared CS16 steamcmd.
    cmd=steamroot/'steamcmd.sh'
    if not cmd.is_file(): fail(f'SteamCMD not installed: {cmd}')
    home=pwd.getpwnam(uname).pw_dir
    env=dict(os.environ,HOME=home,USER=uname,LOGNAME=uname)
    p=cp(['runuser','-u',uname,'--',str(cmd),'+force_install_dir',str(root),'+login','anonymous','+app_update','730','validate','+quit'],check=False,timeout=14400,env=env)
    if p.returncode: fail('SteamCMD failed: '+(p.stdout or '')[-4000:])
    if not (root/'game/bin/linuxsteamrt64/cs2').is_file(): fail('SteamCMD completed but CS2 executable missing')
    prepare_sdk(pathlib.Path(home),steamroot)

def base_install():
    BASE.mkdir(parents=True,exist_ok=True)
    if not base_ready() and shutil.disk_usage(str(BASE)).free < 70*1024**3:
        fail('For initial CS2 base download reserve at least 70 GiB free disk space')
    shutil.chown(BASE,user='cs2build',group='cs2build')
    steam_update(BASE,STEAMCMD.parent,'cs2build')
    output({'ok':True,'base':str(BASE),'message':'CS2 base installed (App 730)'})

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
    if not base_ready(): fail('CS2 base not installed. Run sudo hyper-cs2-ctl base-install')
    port=int(data['port']);slots=int(data['slots'])
    if not 2<=slots<=32: fail('Slots must be 2..32')
    check_port(port)
    name=validate_field(data.get('name',''),96);hostname=validate_field(data.get('hostname',''),160)
    mp=validate_map(data.get('map','de_dust2'))
    mode=data.get('mode','competitive')
    if mode not in MODES: fail('Unknown CS2 mode')
    for key,limit in [('password',80),('rcon',80),('token',128)]:
        value=str(data.get(key,'')).strip()
        if len(value)>limit or not re.fullmatch(r'[A-Za-z0-9._!@#%+^?=-]*',value): fail('Invalid '+key)
    if not data.get('rcon'): fail('RCON password is required')
    c={'id':i,'name':name,'hostname':hostname,'port':port,'slots':slots,'map':mp,'mode':mode,
       'password':str(data.get('password','')),'rcon':str(data['rcon']),'token':str(data.get('token','')),
       'state':'installing','error':'','created_at':int(time.time())}
    save(c)
    p=cp(['systemctl','start','--no-block',installunit(i)],check=False)
    if p.returncode:
        c['state']='failed';c['error']=p.stdout.strip()[-2000:];save(c)
        fail(c['error'])
    output({'ok':True,'id':i,'state':'installing','detail':'Provisioning started in systemd'})

def provision(i):
    c=load(i)
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
            'map':c['map'],'mode':c['mode'],**query,'token_set':bool(c.get('token')),'state':c['state'],
            'service':service,'running':service=='active','cpu':cpu,'ram_mb':mem,'uptime':uptime,
            'error':c.get('error',''),'path':str(root)}

def list_servers():
    result=[]
    for path in sorted(STATE.glob('*.json')):
        try: result.append(current_status(load(ident(path.stem))))
        except Exception: pass
    output({'ok':True,'servers':result,'base_ready':base_ready()})

def cfg_set(i,d):
    c=load(i)
    if c['state'] not in ('ready','updating'): fail('Server not ready')
    port=int(d.get('port',c['port'])); slots=int(d.get('slots',c['slots']))
    if not 2<=slots<=32: fail('Slots must be 2..32')
    check_port(port,own=i)
    for key,lim in [('hostname',160),('name',96)]:
        if key in d: c[key]=validate_field(d[key],lim)
    if 'map' in d: c['map']=validate_map(d['map'])
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
    c=load(i);p=gamepath(i)/'gamefiles/game/csgo/cfg/server.cfg'
    body=p.read_text(errors='replace') if p.is_file() else ''
    redacted='\n'.join('// [SECRET REDACTED] '+ln.split()[0] if re.match(r'^\s*(sv_setsteamaccount|rcon_password|sv_password)\b',ln,re.I) else ln for ln in body.splitlines())
    output({'ok':True,'text':redacted})

def config_save(i,body):
    c=load(i);root=gamepath(i)/'gamefiles/game/csgo/cfg';p=root/'server.cfg'
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
    parser.add_argument('action',choices=['doctor','base-install','list','status','create','_provision','start','stop','restart','update','_update','settings','config-get','config-save','rcon','delete','logs'])
    parser.add_argument('id',nargs='?')
    a=parser.parse_args();act=a.action
    if act=='doctor':
        usage=shutil.disk_usage(str(ROOT))
        output({'ok':True,'base_ready':base_ready(),'steamcmd':STEAMCMD.is_file(),'free_gb':round(usage.free/1024**3,1),'server_count':len(list(STATE.glob('*.json')))})
        return
    if act=='base-install': return base_install()
    if act=='list': return list_servers()
    if not a.id: fail('server ID required')
    i=ident(a.id)
    if act=='create':
        raw=sys.stdin.read(4096)
        return create(i,json.loads(raw))
    if act=='_provision': return provision(i)
    if act=='_update': return update(i)
    c=load(i)
    if act=='status': return output({'ok':True,**current_status(c)})
    if act in ('start','stop','restart'):
        if c['state']!='ready': fail('Server is not ready: '+c['state'])
        p=cp(['systemctl',act,unit(i)],check=False,timeout=90)
        if p.returncode: fail(p.stdout[-3000:])
        return output({'ok':True,'action':act,**current_status(c)})
    if act=='update':
        if c['state']!='ready': fail('Server not ready')
        p=cp(['systemctl','start','--no-block',updateunit(i)],check=False)
        if p.returncode: fail(p.stdout)
        return output({'ok':True,'state':'updating','id':i})
    if act=='settings': return cfg_set(i,json.loads(sys.stdin.read(4096)))
    if act=='config-get': return config_get(i)
    if act=='config-save': return config_save(i,sys.stdin.read(32769))
    if act=='rcon': return rcon(i,sys.stdin.read(320).strip())
    if act=='logs':
        p=cp(['journalctl','-u',unit(i),'-n','100','--no-pager','-o','cat'],check=False,timeout=15)
        output({'ok':True,'logs':p.stdout[-15000:]})
        return
    if act=='delete': return deletion(i)
if __name__=='__main__':
    try: main()
    except Exception as ex:
        output({'ok':False,'error':str(ex)[-3000:]});sys.exit(1)
PY
chmod 0755 /usr/local/sbin/hyper-cs2-ctl
python3 -m py_compile /usr/local/sbin/hyper-cs2-ctl

cat > /usr/local/sbin/hyper-cs2-run <<'PY'
#!/usr/bin/env python3
import json,os,pathlib,re,sys
if len(sys.argv)!=2 or not re.fullmatch(r'[1-9][0-9]{0,3}',sys.argv[1]): sys.exit(2)
i=int(sys.argv[1]);root=pathlib.Path('/srv/hyper-cs2/servers')/str(i)
d=json.loads((root/'run.json').read_text())
if d.get('id')!=i: sys.exit(3)
port=int(d['port']);slots=int(d['slots']);mp=str(d['map'])
if not (27015<=port<=27200 and 2<=slots<=32 and re.fullmatch(r'[A-Za-z0-9_]{1,64}',mp)): sys.exit(4)
script=root/'gamefiles/game/cs2.sh';binary=root/'gamefiles/game/bin/linuxsteamrt64/cs2'
if script.is_file(): args=['/bin/bash',str(script)]
elif binary.is_file(): args=[str(binary)]
else: sys.exit('CS2 binary missing')
args+=['-dedicated','-usercon','-port',str(port),'-maxplayers',str(slots),'+game_type',str(d['game_type']),'+game_mode',str(d['game_mode']),'+map',mp,'+exec','server.cfg']
os.chdir(str(root/'gamefiles/game'))
os.execv(args[0],args)
PY
chmod 0755 /usr/local/sbin/hyper-cs2-run
python3 -m py_compile /usr/local/sbin/hyper-cs2-run

cat > /etc/systemd/system/hyper-cs2@.service <<'UNIT'
[Unit]
Description=HYPER-HOST Counter-Strike 2 #%i
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=cs2s%i
Group=cs2s%i
WorkingDirectory=/srv/hyper-cs2/servers/%i/gamefiles/game
ExecStart=/usr/local/sbin/hyper-cs2-run %i
Restart=on-failure
RestartSec=8
TimeoutStopSec=45
KillSignal=SIGTERM
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/srv/hyper-cs2/servers/%i
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/hyper-cs2-install@.service <<'UNIT'
[Unit]
Description=HYPER-HOST CS2 provision server #%i
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hyper-cs2-ctl _provision %i
TimeoutStartSec=14400
UNIT
cat > /etc/systemd/system/hyper-cs2-update@.service <<'UNIT'
[Unit]
Description=HYPER-HOST CS2 update server #%i
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hyper-cs2-ctl _update %i
TimeoutStartSec=14400
UNIT
cat > /etc/sudoers.d/hyper-cs2-panel <<'SUDO'
# Dedicated input-validated CS2 controller only. No arbitrary shell.
www-data ALL=(root) NOPASSWD: /usr/local/sbin/hyper-cs2-ctl *
SUDO
chmod 0440 /etc/sudoers.d/hyper-cs2-panel
visudo -cf /etc/sudoers.d/hyper-cs2-panel >/dev/null
systemctl daemon-reload

log 'Creating separate CS2 SQL table (CS1.6 tables untouched)'
php <<'PHP'
<?php
$c=require '/etc/hyper-cs16/panel.php';
$pdo=new PDO('mysql:host='.$c['db_host'].';port='.$c['db_port'].';dbname='.$c['db_name'].';charset=utf8mb4',$c['db_user'],$c['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$pdo->exec('CREATE TABLE IF NOT EXISTS cs2_servers (
 id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 owner_user_id INT UNSIGNED NOT NULL,
 name VARCHAR(96) NOT NULL,
 hostname VARCHAR(160) NOT NULL,
 port INT UNSIGNED NOT NULL UNIQUE,
 slots TINYINT UNSIGNED NOT NULL DEFAULT 10,
 start_map VARCHAR(64) NOT NULL DEFAULT "de_dust2",
 game_mode VARCHAR(24) NOT NULL DEFAULT "competitive",
 created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
 INDEX idx_cs2_owner (owner_user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci');
echo "[OK] cs2_servers table\n";
PHP

log 'Installing CS2 PHP section with existing panel sessions and CSRF'
cat > "$WEB/cs2.php" <<'PHP'
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
    if(!$r){http_response_code(404);exit('CS2 server not found');}
    global $user;
    if(!in_array($user['role'],['owner','admin'],true)&&(int)$r['owner_user_id']!==(int)$user['id']){http_response_code(403);exit('Access denied');}
    return $r;
}
function cs2url(int $id=0):string{return '/cs2.php'.($id?'?id='.$id:'');}
if($_SERVER['REQUEST_METHOD']==='POST'){
    check_csrf();$action=(string)($_POST['action']??'');$id=(int)($_POST['id']??0);
    try{
        if($action==='create'){
            require_perm('servers.create');
            $port=(int)($_POST['port']??27101);$slots=(int)($_POST['slots']??10);
            $name=trim((string)($_POST['name']??''));$hostname=trim((string)($_POST['hostname']??''));
            $map=trim((string)($_POST['map']??'de_dust2'));$mode=(string)($_POST['mode']??'competitive');
            if($name===''||mb_strlen($name)>96||$hostname===''||mb_strlen($hostname)>160||$port<27015||$port>27200||$slots<2||$slots>32||!preg_match('/^[A-Za-z0-9_]{1,64}$/',$map)||!in_array($mode,['competitive','casual','deathmatch','wingman'],true))throw new RuntimeException('Некорректные параметры');
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
    }catch(Throwable $ex){flash($ex->getMessage(),'danger');redirect(cs2url($id>0?$id:0));}
}
$all=cs2ctl(['list']);$live=[];foreach(($all['servers']??[]) as $s)$live[(int)$s['id']]=$s;
if(in_array((string)$user['role'],['owner','admin'],true))$rows=db()->query('SELECT * FROM cs2_servers ORDER BY id DESC')->fetchAll();
else{$st=db()->prepare('SELECT * FROM cs2_servers WHERE owner_user_id=? ORDER BY id DESC');$st->execute([(int)$user['id']]);$rows=$st->fetchAll();}
$id=(int)($_GET['id']??0);$row=$id?cs2row($id):null;$status=$id?($live[$id]??null):null;
$log=$id?cs2ctl(['logs',$id]):[];$config=$id?cs2ctl(['config-get',$id]):[];
$flash=flash();$canCreate=can_perm('servers.create');
?><!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CS2 HOSTING — HYPER-HOST</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.6.0/css/all.min.css">
<link rel="stylesheet" href="/assets/style.css?v=350"><style>
body{background:#0b1020;color:#edf3ff}.cs2-wrap{max-width:1370px;margin:auto;padding:30px 22px}.cs2-top{display:flex;justify-content:space-between;align-items:center;gap:18px;flex-wrap:wrap;margin-bottom:25px}.cs2-h{font-size:clamp(26px,4vw,42px);font-weight:800;letter-spacing:-1px}.cs2-muted{color:#99a9c7}.cs2-card{background:linear-gradient(145deg,#161e35,#10172a);border:1px solid #293652;border-radius:18px;padding:24px;margin-bottom:20px;box-shadow:0 14px 45px #05091c77}.cs2-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(285px,1fr));gap:16px}.cs2-grid .cs2-card{margin:0}.cs2-label{font-weight:600;margin-bottom:8px;display:block}.cs2-card input,.cs2-card select,.cs2-card textarea{background:#0c1425!important;color:#ecf2ff!important;border:1px solid #354563!important}.cs2-card input:focus,.cs2-card textarea:focus{box-shadow:0 0 0 3px #247dfc44}.cs2-card textarea{font-family:monospace;font-size:13px;min-height:270px}.cs2-line{display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap}.cs2-stat{display:inline-block;padding:6px 12px;border:1px solid #3b496a;border-radius:30px;color:#c6d4ff;font-size:12px}.cs2-log{background:#070b15;color:#a8efbb;padding:16px;border-radius:12px;white-space:pre-wrap;word-break:break-word;max-height:460px;overflow:auto;font-size:12px}.cs2-btn{background:linear-gradient(120deg,#2274ff,#6148fa);color:white;border:0}.cs2-btn:hover{color:white;filter:brightness(1.2)}.cs2-danger{color:#ff8585}.cs2-srv{display:block;text-decoration:none;color:#f3f6ff}.cs2-srv:hover{color:#fff;border-color:#497bde}.cs2-note{background:#111e36;border-left:3px solid #528aff;padding:14px;border-radius:6px}
</style></head><body><main class="cs2-wrap"><div class="cs2-top"><div><div class="cs2-muted fw-semibold">HYPER-HOST / GAME HOSTING</div><div class="cs2-h"><i class="fa-solid fa-crosshairs text-primary"></i> Counter-Strike 2</div><div class="cs2-muted">Dedicated Server · SteamCMD App 730 · systemd</div></div><div class="d-flex gap-2"><a href="/" class="btn btn-outline-light"><i class="fa-solid fa-arrow-left"></i> CS 1.6</a><a href="/cs2.php" class="btn cs2-btn">Все CS2 серверы</a></div></div>
<?php if($flash):?><div class="alert alert-<?=e((string)$flash['type'])?>"><?=e($flash['message'])?></div><?php endif;?>
<?php if(empty($all['base_ready'])):?><div class="alert alert-warning">Базовая игра CS2 ещё не установлена. На сервере выполни: <code>sudo hyper-cs2-ctl base-install</code>. Для установки требуется много свободного места.</div><?php endif;?>
<?php if(!$row):?>
<div class="cs2-grid mb-4"><?php foreach($rows as $r):$s=$live[(int)$r['id']]??[];?><a class="cs2-card cs2-srv" href="?id=<?=(int)$r['id']?>"><div class="cs2-line"><h4><?=e($r['name'])?></h4><span class="cs2-stat"><?=e((string)($s['state']??'not ready'))?></span></div><div class="cs2-muted">#<?=(int)$r['id']?> · <?=e((string)cfg('public_ip'))?>:<?=(int)$r['port']?> · <?=e($r['start_map'])?></div><div class="mt-3">Сервис: <b><?=e((string)($s['service']??'unknown'))?></b> · Игроки: <?=e(isset($s['players'])?((string)$s['players'].' / '.(string)($s['max_players']??$r['slots'])):'—')?> · RAM: <?=e((string)($s['ram_mb']??0))?> MB</div></a><?php endforeach;?></div>
<?php if($canCreate):?><section class="cs2-card"><h3 class="mb-3">Создать сервер CS2</h3><div class="cs2-note mb-3">При создании выполняется независимое копирование базовой игры и автоматический запуск. GSLT нужен для публичного сервера, Steam App ID 730. Порт CS2 по умолчанию 27101, отдельно от CS 1.6.</div><form method="post" class="row g-3"><?=csrf_field()?><input type="hidden" name="action" value="create">
<div class="col-md-6"><label class="cs2-label">Название</label><input class="form-control" name="name" value="HYPER-HOST CS2" required></div><div class="col-md-6"><label class="cs2-label">Hostname</label><input class="form-control" name="hostname" value="HYPER-HOST | Counter-Strike 2" required></div>
<div class="col-md-3"><label class="cs2-label">Порт</label><input class="form-control" type="number" name="port" value="27101" min="27015" max="27200" required></div><div class="col-md-3"><label class="cs2-label">Слоты</label><input class="form-control" type="number" name="slots" value="10" min="2" max="32" required></div>
<div class="col-md-3"><label class="cs2-label">Карта</label><input class="form-control" name="map" value="de_dust2" required></div><div class="col-md-3"><label class="cs2-label">Режим</label><select class="form-select" name="mode"><option value="competitive">Competitive</option><option value="casual">Casual</option><option value="deathmatch">Deathmatch</option><option value="wingman">Wingman</option></select></div>
<div class="col-md-6"><label class="cs2-label">Steam GSLT (App 730)</label><input class="form-control" name="token" type="password" autocomplete="off" placeholder="Steam Game Server Login Token"></div>
<div class="col-md-6"><label class="cs2-label">RCON пароль (обязательно)</label><input class="form-control" name="rcon" type="password" minlength="8" required autocomplete="new-password"></div>
<div class="col-md-6"><label class="cs2-label">Пароль входа на сервер (необязательно)</label><input class="form-control" name="password" type="password" autocomplete="off"></div>
<div class="col-12"><button class="btn cs2-btn btn-lg">Установить CS2 сервер</button></div></form></section><?php endif;?>
<?php else:?>
<div class="cs2-card"><div class="cs2-line"><div><h2><?=e($row['name'])?></h2><p class="cs2-muted mb-2"><?=e((string)cfg('public_ip'))?>:<?=(int)$row['port']?> · <?=e($row['start_map'])?></p><span class="cs2-stat"><?=e((string)($status['state']??'unknown'))?> / <?=e((string)($status['service']??'offline'))?></span></div><div><span class="cs2-stat">CPU <?=e((string)($status['cpu']??0))?>%</span> <span class="cs2-stat">RAM <?=e((string)($status['ram_mb']??0))?> MB</span> <span class="cs2-stat">Игроки <?=e(isset($status['players'])?((string)$status['players'].' / '.(string)($status['max_players']??$row['slots'])):'—')?></span></div></div>
<?php if(!empty($status['error'])):?><div class="alert alert-danger mt-3"><?=e($status['error'])?></div><?php endif;?>
<form method="post" class="d-flex flex-wrap gap-2 mt-3"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="power"><button class="btn btn-success" name="op" value="start">Запустить</button><button class="btn btn-warning" name="op" value="restart">Перезапустить</button><button class="btn btn-danger" name="op" value="stop">Остановить</button></form>
<form method="post" class="mt-2"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><button name="action" value="update" class="btn btn-outline-info">Обновить через SteamCMD</button></form></div>
<div class="cs2-grid"><section class="cs2-card"><h4>Настройки сервера</h4><form method="post" class="row g-3 mt-1"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="settings">
<div class="col-12"><label class="cs2-label">Название</label><input class="form-control" name="name" value="<?=e($row['name'])?>"></div><div class="col-12"><label class="cs2-label">Hostname</label><input class="form-control" name="hostname" value="<?=e($row['hostname'])?>"></div>
<div class="col-6"><label class="cs2-label">Порт</label><input class="form-control" type="number" name="port" value="<?=(int)$row['port']?>"></div><div class="col-6"><label class="cs2-label">Слоты</label><input class="form-control" type="number" name="slots" value="<?=(int)$row['slots']?>"></div>
<div class="col-6"><label class="cs2-label">Карта</label><input class="form-control" name="map" value="<?=e($row['start_map'])?>"></div><div class="col-6"><label class="cs2-label">Режим</label><select class="form-select" name="mode"><?php foreach(['competitive'=>'Competitive','casual'=>'Casual','deathmatch'=>'Deathmatch','wingman'=>'Wingman'] as $k=>$v):?><option value="<?=e($k)?>" <?=$k===$row['game_mode']?'selected':''?>><?=e($v)?></option><?php endforeach;?></select></div>
<div class="col-12"><label class="cs2-label">Новый GSLT (пусто = не менять)</label><input class="form-control" type="password" name="token" autocomplete="off"></div>
<div class="col-12"><label class="cs2-label">Новый RCON пароль (пусто = не менять)</label><input class="form-control" type="password" name="rcon" autocomplete="off"></div>
<div class="col-12"><label class="cs2-label">Новый пароль сервера</label><input class="form-control" type="password" name="password" autocomplete="off"></div>
<div class="col-12"><button class="btn cs2-btn">Сохранить (нужен Restart)</button></div></form></section>
<section class="cs2-card"><h4>RCON консоль</h4><form method="post"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="rcon"><label class="cs2-label mt-3">Команда</label><input class="form-control mb-2" name="command" placeholder="status / changelevel de_dust2" required><button class="btn cs2-btn">Выполнить</button></form><pre class="cs2-log mt-3"><?=e((string)($_SESSION['cs2_last_rcon']??'Здесь появится результат RCON'))?></pre><?php unset($_SESSION['cs2_last_rcon']);?><h4 class="mt-4">Логи</h4><pre class="cs2-log"><?=e((string)($log['logs']??'Нет данных'))?></pre></section></div>
<section class="cs2-card"><h4>Редактор server.cfg</h4><p class="cs2-muted">Пароль RCON и GSLT управляются отдельными полями; здесь они не изменяются. После сохранения требуется перезапуск.</p><form method="post"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="save_cfg"><textarea class="form-control" name="config" rows="14" spellcheck="false"><?=e((string)($config['text']??''))?></textarea><button class="btn cs2-btn mt-3">Сохранить server.cfg</button></form></section>
<?php if(can_perm('server.delete')):?><section class="cs2-card"><h4 class="cs2-danger">Удаление сервера</h4><form method="post" onsubmit="return confirm('Удалить сервер CS2 и все файлы?')"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="delete"><div class="d-flex gap-2"><input class="form-control" name="confirm" placeholder="Введи DELETE" required><button class="btn btn-danger">Удалить навсегда</button></div></form></section><?php endif;?>
<?php endif;?><div class="text-center cs2-muted mt-4">HYPER-HOST · CS2 module v1 · <a href="/" class="text-info">CS 1.6 панель</a></div></main></body></html>
PHP
chown www-data:www-data "$WEB/cs2.php"
chmod 0644 "$WEB/cs2.php"
php -l "$WEB/cs2.php"

# Insert one navigation link; do not change PHP request handling for CS 1.6.
python3 - "$WEB/index.php" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text(encoding='utf-8')
link='<a href="/cs2.php"><i class="fa-solid fa-crosshairs"></i>Counter-Strike 2</a>'
if link not in s:
    marker='<div class="nav-section">ХОСТИНГ</div>'
    if marker not in s: raise SystemExit('Could not safely insert CS2 navigation into index.php')
    s=s.replace(marker,link+marker,1)
    p.write_text(s,encoding='utf-8')
PY
php -l "$WEB/index.php"
chown www-data:www-data "$WEB/index.php"
if command -v ufw >/dev/null 2>&1; then ufw allow 27101:27200/udp comment 'HYPER-HOST CS2 game servers' >/dev/null || true; fi

log 'Checking installed module'
/usr/local/sbin/hyper-cs2-ctl doctor
if [[ "${CS2_INSTALL_GAME:-1}" == '1' ]]; then
  log 'Installing CS2 base game through SteamCMD (large download, free disk needed)'
  if ! /usr/local/sbin/hyper-cs2-ctl base-install; then
    echo '[WARNING] UI installed but base game download failed. Retry: sudo hyper-cs2-ctl base-install' >&2
  fi
else
  echo '[INFO] Skipped game files (CS2_INSTALL_GAME=0). Later: sudo hyper-cs2-ctl base-install'
fi
cat <<EOF

==========================================================
 HYPER-HOST CS2 MODULE v1 INSTALLED
 Panel: https://$DOMAIN/cs2.php
 Backup: $BACKUP
 Check: sudo hyper-cs2-ctl doctor
 Base:  sudo hyper-cs2-ctl base-install
 CS2:   /srv/hyper-cs2/servers/<ID>/gamefiles
 Ports: UDP 27101..27200 (default CS2 27101)
==========================================================
Existing CS1.6 instances were not modified.
You need GSLT App ID 730 for public CS2.
EOF
