#!/usr/bin/env bash
# HYPER-HOST CS2 v7.1 — SFTP lock fix, separate LAN/WAN IP, official plugin installer.
# Safe upgrade for an already-installed v6 panel; no game reinstall.
set -Eeuo pipefail
umask 077

[[ "${EUID}" == 0 ]] || { echo '[ERROR] Run with sudo bash'; exit 1; }
CTL=/usr/local/sbin/hyper-cs2-ctl
PANEL=/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/cs2.php
[[ -f "$CTL" && -f "$PANEL" ]] || { echo '[ERROR] Existing CS2 controller/panel not found. v6 must be installed first.' >&2; exit 1; }
if grep -q 'HYPER-HOST CS2 v7: network status' "$CTL"; then
  echo '[OK] v7 already installed. No files changed.'
  exit 0
fi
for program in python3 php node systemctl systemd-run gpasswd chpasswd; do
  if ! command -v "$program" >/dev/null 2>&1; then
    if [[ "$program" == node ]]; then echo '[WARN] Node.js not found: skipping JS parser check'; else
      echo "[ERROR] Required executable missing: $program" >&2; exit 1
    fi
  fi
done
[[ -x /usr/sbin/sshd ]] || { echo '[ERROR] OpenSSH sshd not found' >&2; exit 1; }
/usr/sbin/sshd -t || { echo '[ERROR] Existing SSH config invalid; no files changed' >&2; exit 1; }
python3 -m py_compile "$CTL"
php -l "$PANEL" >/dev/null
if ! grep -q 'HYPER-HOST CS2 v6' "$CTL" && ! grep -q 'HYPER-HOST v6' "$CTL"; then
  echo '[ERROR] Installed CS2 controller is not v6. Refusing an unsafe partial patch.' >&2;exit 1
fi
NOW=$(date -u +%Y%m%d-%H%M%S)
BACKUP="/root/hyper-cs2-v7-backup-${NOW}"
mkdir -m 0700 "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs2-ctl"
cp -a "$PANEL" "$BACKUP/cs2.php"
TMP=$(mktemp -d /tmp/hyper-cs2-v7.XXXXXXXX)
chmod 700 "$TMP"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT
printf '[1/5] Backups: %s\n' "$BACKUP"
cat > "$TMP/upgrade.py" <<'V7_PYTHON_PATCHER'
#!/usr/bin/env python3
"""HYPER-HOST v7 - patch ONLY an installed v6 CS2 controller/panel."""
import pathlib,sys,re
if len(sys.argv)!=5: raise SystemExit('usage: upgrade.py old-ctl old-php new-ctl new-php')
ctl=pathlib.Path(sys.argv[1]).read_text(); php=pathlib.Path(sys.argv[2]).read_text()
def one(src,old,new,label):
    n=src.count(old)
    if n!=1: raise RuntimeError(f'Unexpected {label}: {n} matches for {old[:75]!r}')
    return src.replace(old,new,1)
def function_replace(src,name,code):
    match=re.search(r'(?ms)^def '+re.escape(name)+r'\(.*?(?=^def |^# HYPER-HOST |^if __name__|\Z)',src)
    if not match: raise RuntimeError('function missing: '+name)
    return src[:match.start()]+code.strip('\n')+'\n\n'+src[match.end():]
# These functions are defined near EOF of v6; replace without altering game-related methods.
functions=r'''
# HYPER-HOST v7: do not invoke usermod (takes an /etc/passwd lock) for SFTP group membership.
def v7_account_command(args, timeout=25):
    for attempt in range(4):
        try:
            p=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
        except subprocess.TimeoutExpired:
            fail('Системная база пользователей занята: операция превысила таймаут.')
        if p.returncode==0:return
        err=(p.stderr+' '+p.stdout).strip()[-500:]
        if not re.search(r'(cannot lock|password file busy|try again later|resource temporarily unavailable|lock.*passwd|shadow.*lock)',err,re.I):
            fail('Ошибка системной учётной записи: '+err)
        if attempt<3:time.sleep(2*(attempt+1))
    details=[]
    for f in ('/etc/passwd.lock','/etc/shadow.lock','/etc/group.lock','/etc/gshadow.lock'):
        if pathlib.Path(f).exists(): details.append(f)
    fail('Не удалось изменить системную учётную запись: /etc/passwd или /etc/shadow заблокирован. '
         +'Проверьте параллельные useradd/usermod/chpasswd и права /etc. Обнаружены файлы блокировки: '
         +(', '.join(details) or 'не обнаружены')+'. Блокировки автоматически не удаляются.')

def sftp_enable(i):
    if load(i).get('state')!='ready':fail('Сервер ещё не подготовлен')
    sftp_chroot_preflight(i)
    uname=user(i)
    try:pwd.getpwnam(uname)
    except KeyError:fail('Отсутствует Linux-пользователь '+uname)
    try:grp.getgrnam(SFTP_GROUP)
    except KeyError:fail('Группа hypercs2sftp отсутствует: повторите установку патча')
    # Add membership first; only then sshd -T -C can match the SFTP group.
    # gpasswd changes /etc/group membership, unlike usermod's passwd DB lock.
    if uname not in grp.getgrnam(SFTP_GROUP).gr_mem:
        v7_account_command(['gpasswd','-a',uname,SFTP_GROUP])
        grp.getgrnam(SFTP_GROUP) # group membership re-read via fresh getgrnam
    if not sftp_info(i)['configured']:
        fail('Настройки SSH не разрешают internal-sftp / ChrootDirectory / вход по паролю. Проверьте sshd -T -C user='+uname+',host=localhost,addr=127.0.0.1')
    password=secrets.token_urlsafe(24)
    v7_account_command_with_input(['chpasswd'],f'{uname}:{password}\n')
    result=sftp_info(i)
    if not result['enabled']:
        fail('Пароль установлен, но SFTP не активен. Проверьте Match Group в sshd и /etc/shadow.')
    output({**result,'password':password,'message':'SFTP включён. Новый пароль показан ниже один раз — сохраните его!'})

def v7_account_command_with_input(args,content):
    for attempt in range(4):
        try:p=subprocess.run(args,input=content,text=True,capture_output=True,timeout=20)
        except subprocess.TimeoutExpired:fail('Таймаут изменения пароля /etc/shadow')
        if p.returncode==0:return
        err=(p.stderr+' '+p.stdout).strip()[-500:]
        if not re.search(r'(cannot lock|busy|try again later|resource temporarily unavailable)',err,re.I):
            fail('Не удалось установить пароль: '+err)
        if attempt<3:time.sleep(2*(attempt+1))
    fail('Системная база паролей занята более 12 секунд. Проверить процессы chpasswd/passwd и lock-файлы; не удалять lock-файлы вслепую.')

def sftp_disable(i):
    load(i);uname=user(i)
    try:pwd.getpwnam(uname)
    except KeyError:fail('Учётная запись ещё не создана')
    # Avoid changing password of an OS service account that may be used elsewhere.
    try:
        if uname in grp.getgrnam(SFTP_GROUP).gr_mem:
            v7_account_command(['gpasswd','-d',uname,SFTP_GROUP])
    except KeyError: pass
    output({'ok':True,'enabled':False,'username':uname,'message':'SFTP-доступ выключен через группу. Текущие сеансы завершайте отдельно.'})
'''
# Source functions from existing v6 may have ordering constraints; process bottom-up.
for fn in ('sftp_enable','sftp_disable'):
    m=re.search(r'(?ms)^def '+fn+r'\(.*?(?=^def |^# HYPER-HOST |^if __name__|\Z)',functions)
    assert m,fn
    ctl=function_replace(ctl,fn,m.group(0))
# Insert helper funcs before main(); they refer only to globals.
insert=functions[:functions.index('def sftp_enable(i):')]
ctl=one(ctl,'def main():',insert+'\n\ndef main():','controller main')
# New core modules.
module=r'''
# HYPER-HOST CS2 v7: network status + official plugin installers.
import urllib.request, urllib.error, html, zipfile, tarfile, io, ipaddress, grp

def v7_ip_status(i):
    load(i)
    local=''
    try:
        sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        sock.connect(('1.1.1.1',443))
        local=sock.getsockname()[0]
        sock.close()
    except OSError:pass
    external=''
    cache=pathlib.Path('/var/cache/hyper-cs2/public-ip.json')
    try:
        d=json.loads(cache.read_text())
        if time.time()-float(d.get('timestamp',0))<900:
            external=d.get('ip','')
    except (OSError,ValueError,TypeError):pass
    if not external:
        try:
            req=urllib.request.Request('https://api.ipify.org',headers={'User-Agent':'HYPER-HOST-CS2/7'})
            with urllib.request.urlopen(req,timeout=3) as response:
                value=response.read(100).decode().strip()
            parsed=ipaddress.ip_address(value)
            if isinstance(parsed,ipaddress.IPv4Address) and parsed.is_global:
                external=value
                try:
                    cache.parent.mkdir(parents=True,exist_ok=True)
                    cache.write_text(json.dumps({'timestamp':int(time.time()),'ip':external}))
                    cache.chmod(0o600)
                except OSError:pass
        except (OSError,ValueError,urllib.error.URLError):pass
    return output({'ok':True,'local_ip':local or 'Не определён',
                   'external_ip':external or 'Не определён (проверьте публичный IP в настройках панели)',
                   'note':'Внешний IP получен по исходящему соединению. Для подключения из интернета нужен открытый игровой порт.'})

V7_PLUGIN_UNIT='hyper-cs2-plugins-{}.service'
def v7_unit(i):return V7_PLUGIN_UNIT.format(i)

def v7_download(url,location,limit=600*1024*1024):
    req=urllib.request.Request(url,headers={'User-Agent':'HYPER-HOST-CS2-plugin-installer/7','Accept':'application/octet-stream'})
    with urllib.request.urlopen(req,timeout=40) as resp,open(location,'wb') as out:
        resolved=resp.geturl()
        # Downloads may redirect to GitHub release asset CDN. No arbitrary user URL is accepted.
        if not resolved.startswith('https://'):fail('Insecure plugin download redirect')
        size=0
        while True:
            part=resp.read(1024*512)
            if not part:break
            size+=len(part)
            if size>limit:fail('Plugin archive exceeds size limit')
            out.write(part)
    if size<1024:fail('Plugin archive appears empty')

def v7_archive_mms():
    # Official AlliedModders snapshot directory; do not construct invalid GitHub URLs.
    base='https://mms.alliedmods.net/mmsdrop/2.0/'
    req=urllib.request.Request(base,headers={'User-Agent':'HYPER-HOST-CS2/7.1'})
    with urllib.request.urlopen(req,timeout=20) as r:
        listing=r.read(1000000).decode('utf-8','replace')
    versions=[int(v) for v in re.findall(r'mmsource-2\.0\.0-git(\d+)-linux\.tar\.gz',listing)]
    if not versions: fail('Не найден Metamod:Source 2.x Linux в официальном каталоге mms.alliedmods.net')
    build=max(versions)
    if not 1000<=build<=99999: fail('Некорректный номер сборки Metamod')
    return base+f'mmsource-2.0.0-git{build}-linux.tar.gz'

def v7_archive_css():
    req=urllib.request.Request('https://api.github.com/repos/roflmuffin/CounterStrikeSharp/releases/latest',headers={'User-Agent':'HYPER-HOST-CS2/7','Accept':'application/vnd.github+json'})
    with urllib.request.urlopen(req,timeout=20) as r: d=json.load(r)
    matching=[a for a in d.get('assets',[]) if re.fullmatch(r'counterstrikesharp-with-runtime-linux(?:[-_][A-Za-z0-9._-]+)?\.zip',a.get('name',''),re.I)]
    if not matching:fail('В последнем релизе CounterStrikeSharp нет Linux with-runtime архива (проверьте GitHub)')
    url=matching[0].get('browser_download_url','')
    if not url.startswith('https://github.com/roflmuffin/CounterStrikeSharp/releases/download/'):
        fail('Unexpected CounterStrikeSharp download URL')
    return url

def v7_members(archive,typ):
    with open(archive,'rb') as fd:
        if typ=='meta':
            with tarfile.open(fileobj=fd,mode='r:gz') as ar:
                raw=[(m.name,m.size,m.isfile(),m.isdir(),m) for m in ar.getmembers()]
                if len(raw)>15000:fail('Too many files in Metamod archive')
                return [(name,size,ar.extractfile(obj).read() if regular else None) for name,size,regular,isd,obj in raw if regular or isd]
        else:
            with zipfile.ZipFile(fd) as ar:
                raw=ar.infolist()
                if len(raw)>15000:fail('Too many files in CSS archive')
                parts=[]
                for m in raw:
                    if (m.external_attr>>16)&0o170000==0o120000:fail('Symlinks in plugin archive are forbidden')
                    parts.append((m.filename,m.file_size,None if m.is_dir() else ar.read(m)))
                return parts

def v7_unpack(archive,typ,dest):
    # Archive extraction always happens in a private temporary directory, never directly into the game.
    count=0;total=0
    for raw,size,data in v7_members(archive,typ):
        name=raw.replace('\\','/')
        while name.startswith('./'):name=name[2:]
        if name.startswith('game/csgo/'):name=name[len('game/csgo/'):]
        if name.startswith('csgo/'):name=name[len('csgo/'):]
        components=pathlib.PurePosixPath(name).parts
        if not components or components[0]!='addons':continue
        if any(x in ('..','.','') for x in components) or name.startswith('/') or len(name)>300:fail('Unsafe plugin archive path')
        if data is None:continue
        if size!=len(data):fail('Plugin archive size mismatch')
        total+=size;count+=1
        if total>700*1024*1024 or count>15000:fail('Plugin archive extraction limit exceeded')
        target=dest.joinpath(*components)
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(data)
    if count<3:fail('No CS2 addons files found in archive')
    return count

def v7_merge_plugin_files(i,staged):
    root=gamepath(i)/'gamefiles/game/csgo'
    if root.is_symlink() or not root.is_dir():fail('Unsafe CS2 instance directory')
    root=root.resolve(strict=True)
    acct=pwd.getpwnam(user(i))
    with tempfile.TemporaryDirectory(prefix='hyper-cs2-plugins-backup-') as folder:
        backups=[];created=[]
        try:
            files=[p for p in staged.rglob('*') if p.is_file()]
            if not files:fail('Plugin archive is empty')
            for file in files:
                rel=file.relative_to(staged)
                if rel.parts[0]!='addons':fail('Only game/csgo/addons path is allowed')
                destination=root/rel
                branch=root
                for component in rel.parts[:-1]:
                    branch=branch/component
                    if branch.is_symlink():fail('Symlink in plugin destination: '+str(branch))
                    branch.mkdir(mode=0o755,exist_ok=True)
                    if branch.stat().st_uid==0 and branch!=root:
                        os.chown(branch,acct.pw_uid,acct.pw_gid)
                if destination.is_symlink():fail('Refusing to replace symlink: '+str(rel))
                if destination.exists():
                    if not destination.is_file():fail('Destination is not regular file: '+str(rel))
                    backup=pathlib.Path(folder)/rel;backup.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copy2(destination,backup);backups.append((destination,backup))
                else: created.append(destination)
                shutil.copy2(file,destination)
                os.chown(destination,acct.pw_uid,acct.pw_gid)
                os.chmod(destination,0o755 if destination.suffix=='.so' else 0o644)
            return len(files)
        except BaseException:
            for dest in created:dest.unlink(missing_ok=True)
            for dest,backup in backups:
                shutil.copy2(backup,dest)
                os.chown(dest,acct.pw_uid,acct.pw_gid)
            raise

def v7_enable_metainf(i):
    path=gamepath(i)/'gamefiles/game/csgo/gameinfo.gi'
    if path.is_symlink() or not path.is_file():fail('gameinfo.gi must be a private file, not a symlink')
    content=path.read_text()
    if re.search(r'^\s*Game\s+csgo/addons/metamod\s*$',content,re.M):return
    patt=re.compile(r'^([ \t]*)Game_LowViolence[ \t]+csgo_lv(?:[ \t]*//[^\n]*)?[ \t]*$',re.M)
    if not patt.search(content):fail('gameinfo.gi: cannot locate Game_LowViolence section')
    backup=path.with_name('gameinfo.gi.hyperhost-v7.bak')
    if not backup.exists():shutil.copy2(path,backup)
    content=patt.sub(lambda m:m.group(0)+'\n'+m.group(1)+'Game csgo/addons/metamod',content,count=1)
    tmp=path.with_name('gameinfo.gi.hyperhost-v7.tmp')
    if tmp.exists() or tmp.is_symlink():fail('Temporary gameinfo file already exists')
    acct=pwd.getpwnam(user(i))
    try:
        tmp.write_text(content);os.chown(tmp,acct.pw_uid,acct.pw_gid);os.chmod(tmp,0o640);os.replace(tmp,path)
    finally:tmp.unlink(missing_ok=True)

def v7_install_plugins(i,kind):
    load(i)
    if kind not in ('metamod','css','both'):fail('Invalid plugin installer name')
    if systemd_active(unit(i)):fail('Останови сервер CS2 перед установкой модов.')
    with tempfile.TemporaryDirectory(prefix='hyper-cs2-download-') as tmp:
        path=pathlib.Path(tmp)
        for current in (['metamod','css'] if kind=='both' else [kind]):
            url=v7_archive_mms() if current=='metamod' else v7_archive_css()
            print('Downloading '+current+' from official source...',flush=True)
            archive=path/('download.tar.gz' if current=='metamod' else 'download.zip')
            v7_download(url,archive)
            target=path/'staged'
            if target.exists():shutil.rmtree(target)
            target.mkdir()
            count=v7_unpack(archive,'meta' if current=='metamod' else 'css',target)
            copied=v7_merge_plugin_files(i,target)
            print(f'Installed {current}: {count} archive entries / {copied} files',flush=True)
        if kind in ('metamod','both'):
            v7_enable_metainf(i)
    output({'ok':True,'message':'Файлы установлены. Запустите CS2 и проверьте meta list / логи.'})

def v7_plugin_start(i,kind):
    load(i)
    if kind not in ('metamod','css','both'):fail('Invalid plugin name')
    if systemd_active(unit(i)):fail('Останови CS2 сервер перед установкой Metamod / CSS')
    name=v7_unit(i)
    if cp(['systemctl','is-active',name],check=False,timeout=5).returncode==0:
        fail('Установка плагинов уже выполняется')
    # systemd-run returns immediately; avoids PHP timeout on large downloads.
    cp(['systemctl','reset-failed',name],check=False,timeout=5)
    p=cp(['systemd-run','--unit',name.removesuffix('.service'),'--collect',
          '--property=Type=exec','--property=TimeoutStartSec=900',
          '/usr/local/sbin/hyper-cs2-ctl','plugins-install',str(i),kind],check=False,timeout=12)
    if p.returncode:fail('Не получилось запустить установку: '+p.stdout[-900:])
    output({'ok':True,'installing':True,'message':'Загрузка плагинов запущена. Статус и ошибки доступны во вкладке «Плагины».'})

def v7_plugin_status(i):
    load(i)
    root=gamepath(i)/'gamefiles/game/csgo'
    meta=root/'addons/metamod';css=root/'addons/counterstrikesharp'
    info=root/'gameinfo.gi'
    enabled=False
    try:
        if info.is_file():enabled=bool(re.search(r'^\s*Game\s+csgo/addons/metamod\s*$',info.read_text(errors='replace'),re.M))
    except OSError:pass
    try:metaf=meta.is_dir() and any(meta.rglob('metamod.*.so'))
    except OSError:metaf=False
    try:cssf=css.is_dir() and any(css.rglob('CounterStrikeSharp.API.dll'))
    except OSError:cssf=False
    plugdir=css/'plugins'
    try:plugins=sorted(x.name for x in plugdir.iterdir() if x.is_dir() and not x.is_symlink())[:100]
    except OSError:plugins=[]
    unitname=v7_unit(i)
    state=cp(['systemctl','is-active',unitname],check=False,timeout=5).stdout.strip()
    logs=cp(['journalctl','-u',unitname,'-n','14','--no-pager','--output=cat'],check=False,timeout=8).stdout[-2800:]
    output({'ok':True,'metamod_files':bool(metaf),'metamod_enabled':enabled,
            'counterstrikesharp_files':bool(cssf),'custom_plugins':plugins,
            'plugin_directory':str(plugdir),'installer_state':state or 'inactive',
            'installer_logs':logs,'message':'Файлы != модуль загружен; проверьте meta list после запуска CS2.'})
'''
# injection BEFORE def main() where imports accessible.
ctl=one(ctl,'def main():',module+'\n\ndef main():','main injection')
# Modify a real argparse choices line, preserving all existing actions and order.
pattern = re.compile(r"(?m)^(?P<prefix>\s*parser\.add_argument\(['\"]action['\"],\s*choices=)(?P<list>\[[^\n]+?\])(?P<suffix>\)\s*)$")
match = pattern.search(ctl)
if not match: raise RuntimeError('Cannot locate argparse action choices')
import ast
choices = ast.literal_eval(match.group('list'))
required = {'sftp-enable','sftp-disable','sftp-status','plugins-status'}
if not required.issubset(choices): raise RuntimeError('Missing required v6 CLI actions')
for action in ('network-info','plugins-start','plugins-install'):
    if action not in choices: choices.append(action)
ctl = ctl[:match.start('list')] + repr(choices) + ctl[match.end('list'):]
ctl=one(ctl,"if act=='plugins-status': return plugin_status(i)","if act=='plugins-status': return v7_plugin_status(i)\n    if act=='network-info': return v7_ip_status(i)\n    if act=='plugins-start': return v7_plugin_start(i,a.kind or '')\n    if act=='plugins-install': return v7_install_plugins(i,a.kind or '')",'main actions')
# CLI parser only accepts [id] as positional; need extra positional 'kind' for plugins-start/install.
ctl=one(ctl,"parser.add_argument('id',nargs='?')","parser.add_argument('id',nargs='?')\n    parser.add_argument('kind',nargs='?')",'argparse kind')
# kind is the second optional CLI positional parameter
# PHP updates
php=one(php,"if($action==='metamod-enable')return cs4ctl(['metamod-enable',$id],null,30);",
"if($action==='metamod-enable')return cs4ctl(['metamod-enable',$id],null,30);\n  if($action==='plugins-start'){ $kind=(string)($_POST['kind']??'');if(!in_array($kind,['metamod','css','both'],true))throw new RuntimeException('Неверный компонент');return cs4ctl(['plugins-start',$id,$kind],null,20); }",'php post plugins')
php=one(php,"if($act==='plugins'){$v=cs4ctl(['plugins-status',$id]);cs4json($v);}",
"if($act==='plugins'){$v=cs4ctl(['plugins-status',$id]);cs4json($v);}\n    if($act==='network'){$v=cs4ctl(['network-info',$id]);cs4json($v);}", 'php ajax network')
# Put network call on render only for individual server.
php=one(php,"$ip=trim((string)cfg('public_ip'));", "$net=$row?cs4ctl(['network-info',$id],null,8):[];\n$ip=trim((string)cfg('public_ip'));\nif(($ip==='' || $ip==='IP не указан') && !empty($net['external_ip']) && filter_var($net['external_ip'],FILTER_VALIDATE_IP))$ip=$net['external_ip'];\n$localIp=(string)($net['local_ip']??'Не определён');",'php network variable')
php=one(php,'<span class="muted">Адрес</span><div class="flex"><strong class="mono"><?=e($ip)?>:<?=(int)$row[\'port\']?></strong><button type="button" class="btn sm" data-copy="<?=e($ip.\':\'.$row[\'port\'])?>">Копировать IP:порт</button></div></div>',
    '<span class="muted">Внешний IP:порт</span><div class="flex"><strong class="mono" id="v7-public-ip"><?=e($ip)?>:<?=(int)$row[\'port\']?></strong><button type="button" class="btn sm" data-copy="<?=e($ip.\':\'.$row[\'port\'])?>">Копировать</button></div></div><div class="flex between"><span class="muted">Локальный IP:порт</span><div class="flex"><strong class="mono" id="v7-local-ip"><?=e($localIp)?>:<?=(int)$row[\'port\']?></strong><button type="button" class="btn sm" data-copy="<?=e($localIp.\':\'.$row[\'port\'])?>">Копировать</button></div></div>', 'php ip view')
# enhanced SFTP details and strong error block
php=one(php,'<div class="secretreveal hidden" id="sftp-secret">','<div class="alertbox hidden" id="v7-sftp-error" style="margin-top:12px"></div><div class="secretreveal hidden" id="sftp-secret">','sftp error block')
php=one(php,"catch(e){toast(e.message,true)}finally{busy=false;", "catch(e){if(form.dataset.sftp){const box=$('#v7-sftp-error');if(box){box.textContent=e.message;box.classList.remove('hidden');}}toast(e.message,true)}finally{busy=false;",'js error')
php=one(php,"if(j.password&&$('#sftp-secret')){$('#sftp-secret').classList.remove('hidden');$('#sftp-password').textContent=j.password;}",
    "if(form.dataset.sftp){const box=$('#v7-sftp-error');if(box){box.classList.add('hidden');box.textContent='';}}if(j.password&&$('#sftp-secret')){$('#sftp-secret').classList.remove('hidden');$('#sftp-password').textContent=j.password;}", 'js password')
# Add real auto-install buttons to plugins tab.
php=one(php,'<h2 style="margin-top:25px">Установленные кастомные плагины</h2>',
'''<div class="notice" style="margin-top:18px">Автоустановка официальных Linux-сборок. <b>Сначала останови игровой сервер.</b> Metamod и CounterStrikeSharp загружаются непосредственно с сайтов разработчиков; во время установки будет показан журнал операции.</div>
    <div class="flex" style="margin-top:12px">
    <form class="ajaxform" method="post" data-v6plugins="1" data-confirm="Останови CS2. Скачать и установить Metamod:Source 2.x из официального релиза?"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="plugins-start"><input type="hidden" name="kind" value="metamod"><button class="btn primary">Установить Metamod</button></form>
    <form class="ajaxform" method="post" data-v6plugins="1" data-confirm="Останови CS2. Скачать и установить CounterStrikeSharp Linux with-runtime?"><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="plugins-start"><input type="hidden" name="kind" value="css"><button class="btn primary">Установить CounterStrikeSharp</button></form>
    </div>
    <div class="hint" style="margin-top:12px">Установка: <strong id="v7-plugin-install-status">не запущена</strong></div><pre class="terminal" style="min-height:65px;max-height:250px" id="v7-plugin-install-log">Журнал установки будет здесь.</pre>
    <h2 style="margin-top:25px">Установленные кастомные плагины</h2>''','php plugin buttons')
php=one(php, "const box=$('#v6-plugin-list');if(box)box.textContent=(d.custom_plugins||[]).join('\\n')||'Кастомные плагины пока не обнаружены';",
"const box=$('#v6-plugin-list');if(box)box.textContent=(d.custom_plugins||[]).join('\\n')||'Кастомные плагины пока не обнаружены'; const state=$('#v7-plugin-install-status');if(state)state.textContent=d.installer_state||'inactive';const log=$('#v7-plugin-install-log');if(log)log.textContent=d.installer_logs||'Установок ещё не было';",'js plugin refresh')
php=one(php,"$('#v6-plugin-refresh')?.addEventListener('click',v6RefreshPlugins);", "$('#v6-plugin-refresh')?.addEventListener('click',v6RefreshPlugins);\nsetInterval(()=>{if(tab==='plugins'&&!document.hidden&&!busy)v6RefreshPlugins();},5000);",'js plugin poll')
php=php.replace('HYPER-HOST · CS2 v5 AJAX / Files / SFTP','HYPER-HOST · CS2 v7 / SFTP / Plugins / IP')
# Post-patch integrity checks (no output file written until all succeed).
for signature in ("if act=='network-info'", "if act=='plugins-start'", "if act=='plugins-install'", "def v7_archive_mms():", "def sftp_enable(i):"):
    if ctl.count(signature)!=1: raise RuntimeError('Controller integrity check failed: '+signature)
for marker in ('id="v7-public-ip"','id="v7-local-ip"','id="v7-plugin-install-status"','id="sftp-password"'):
    if php.count(marker)!=1: raise RuntimeError('Panel integrity check failed: '+marker)
pathlib.Path(sys.argv[3]).write_text(ctl)
pathlib.Path(sys.argv[4]).write_text(php)
print('v7 staged controller and PHP:',len(ctl),len(php))

V7_PYTHON_PATCHER
printf '[2/5] Generate staged controller + panel...\n'
python3 "$TMP/upgrade.py" "$CTL" "$PANEL" "$TMP/controller" "$TMP/cs2.php"
chmod 0755 "$TMP/controller"
chmod 0644 "$TMP/cs2.php"
printf '[3/5] Static checks (Python, PHP, JS, SSH)...\n'
python3 -m py_compile "$TMP/controller"
php -l "$TMP/cs2.php"
python3 - "$TMP/cs2.php" "$TMP/panel.js" <<'JS_EXTRACT'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
blocks=re.findall(r'<script>(.*?)</script>',s,re.S)
if len(blocks)!=1:raise SystemExit('ERROR: Expected one JavaScript block')
js=re.sub(r'<\?=.*?\?>','1',blocks[0]);pathlib.Path(sys.argv[2]).write_text(js)
JS_EXTRACT
if command -v node >/dev/null 2>&1; then node --check "$TMP/panel.js"; fi
/usr/sbin/sshd -t
printf '[4/5] Installing controller + PHP only...\n'
rollback(){
  code=$?
  echo '[ERROR] Failure detected. Restoring original CS2 controller and PHP panel.' >&2
  cp -a "$BACKUP/hyper-cs2-ctl" "$CTL" || true
  cp -a "$BACKUP/cs2.php" "$PANEL" || true
  exit "$code"
}
trap rollback ERR
install -m 0755 "$TMP/controller" "$CTL"
install -m 0644 "$TMP/cs2.php" "$PANEL"
chown --reference="$BACKUP/cs2.php" "$PANEL"
python3 -m py_compile "$CTL"
php -l "$PANEL" >/dev/null
printf '[5/5] Final health checks...\n'
/usr/sbin/sshd -t
systemctl is-active hyper-cs2@2.service || true
printf '\nHYPER-HOST CS2 v7.1 INSTALLED\n'
printf 'Panel: https://www.avito.hyper-host.pw/cs2.php?id=2\n'
printf 'Backup: %s\n' "$BACKUP"
printf 'SFTP: sudo hyper-cs2-ctl sftp-status 2\n'
printf 'IPs: sudo hyper-cs2-ctl network-info 2\n'
printf 'Plugins: sudo hyper-cs2-ctl plugins-status 2\n'
printf 'To install mods: first stop CS2 server, then click Metamod/CSS install in Plugins tab\n'
printf 'CS 1.6, CS2 base and existing server files unchanged.\n'
