#!/usr/bin/env bash
# HYPER-HOST CS2 v8 — SFTP only. No passwd/shadow/group edits, no CS2 reinstall.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo '[ERROR] Run: sudo bash apply-cs2-sftp-virtual-v8.sh' >&2; exit 1; }
CTL=/usr/local/sbin/hyper-cs2-ctl
PANEL=/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/cs2.php
BINARY=/usr/local/bin/hyper-cs2-sftpgo
[[ -f $CTL && -f $PANEL ]] || { echo '[ERROR] Installed HYPER-HOST CS2 v7.1 panel and controller required.' >&2; exit 1; }
for prog in python3 php curl sha256sum systemctl runuser; do command -v "$prog" >/dev/null || { echo "[ERROR] Missing $prog" >&2; exit 1; }; done
python3 -m py_compile "$CTL"
php -l "$PANEL" >/dev/null
if ! grep -q 'HYPER-HOST CS2 v7: network status' "$CTL"; then
  echo '[ERROR] Controller does not contain CS2 v7.1. Nothing modified.' >&2; exit 1
fi
if grep -q 'HYPER-HOST CS2 SFTP v8: portable virtual SFTP' "$CTL"; then
  echo '[OK] CS2 v8 already installed. No files changed.'
  exit 0
fi
TMP=$(mktemp -d /tmp/hyper-cs2-sftp-v8.XXXXXXXX)
chmod 0700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
printf '[1/6] Detecting SFTPGo binary (official v2.7.6)...\n'
if [[ -x $BINARY ]] && "$BINARY" --version | grep -q '2.7.6'; then
  echo '[OK] Already installed.'
else
  ARCH=$(uname -m)
  case "$ARCH" in x86_64|amd64) ASSET=sftpgo_v2.7.6_linux_amd64.tar.xz;; aarch64|arm64) ASSET=sftpgo_v2.7.6_linux_arm64.tar.xz;; *) echo "[ERROR] Unsupported SFTPGo architecture: $ARCH" >&2; exit 1;; esac
  curl --http1.1 -fsSL --retry 4 --connect-timeout 12 --max-time 50 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: HYPER-HOST-CS2-v8' \
    https://api.github.com/repos/drakkan/sftpgo/releases/tags/v2.7.6 -o "$TMP/release.json"
  python3 - "$TMP/release.json" "$ASSET" "$TMP/release-asset" <<'PYMETA'
import json,sys,pathlib,re
j=json.load(open(sys.argv[1]))
assets=[a for a in j.get('assets',[]) if a.get('name')==sys.argv[2]]
if len(assets)!=1:raise SystemExit('[ERROR] Asset not found in official release: '+sys.argv[2])
a=assets[0]; url=a.get('browser_download_url',''); digest=a.get('digest','')
if url!='https://github.com/drakkan/sftpgo/releases/download/v2.7.6/'+sys.argv[2]:
    raise SystemExit('[ERROR] Unexpected official download URL')
if not re.fullmatch('sha256:[a-f0-9]{64}',digest):raise SystemExit('[ERROR] Missing GitHub asset SHA256 digest')
pathlib.Path(sys.argv[3]).write_text(url+'\n'+digest[7:]+'\n')
PYMETA
  URL=$(head -n1 "$TMP/release-asset")
  SUM=$(tail -n1 "$TMP/release-asset")
  curl --http1.1 -fL --retry 5 --retry-delay 2 --connect-timeout 12 \
    --max-time 240 "$URL" -o "$TMP/sftpgo.tar.xz"
  printf '%s  %s\n' "$SUM" "$TMP/sftpgo.tar.xz" | sha256sum -c -
  python3 - "$TMP/sftpgo.tar.xz" "$TMP/sftpgo" <<'PYEXTRACT'
import tarfile,sys,os,pathlib
with tarfile.open(sys.argv[1],'r:xz') as tar:
    files=[m for m in tar.getmembers() if m.isfile() and pathlib.PurePosixPath(m.name).name=='sftpgo']
    if len(files)!=1 or files[0].size>120*1024*1024:raise SystemExit('[ERROR] Unexpected SFTPGo archive format')
    with tar.extractfile(files[0]) as src,open(sys.argv[2],'wb') as out:
        while True:
            block=src.read(1024*1024)
            if not block:break
            out.write(block)
os.chmod(sys.argv[2],0o755)
PYEXTRACT
  "$TMP/sftpgo" --version || { echo '[ERROR] Binary cannot run (wrong architecture/dependencies)' >&2;exit 1; }
  install -m 0755 "$TMP/sftpgo" "$BINARY"
fi
printf '[2/6] Generate patches in staging area...\n'
cat > "$TMP/patcher.py" <<'PYV8PATCH'
from pathlib import Path
import re
import sys

root=Path('/mnt/data')
ctrl = Path(sys.argv[1]).read_text()
panel= Path(sys.argv[2]).read_text()

# The sftpgo code inserts new definitions immediately before main, overriding obsolete v7 account logic.
addon = r'''# HYPER-HOST CS2 SFTP v8: portable virtual SFTP, no writes to passwd/shadow/group.
# Per-server systemd service runs with the preexisting CS2 game owner's UID.
import secrets as _v8_secrets
import datetime as _v8_datetime

V8_SFTP_BINARY='/usr/local/bin/hyper-cs2-sftpgo'
V8_SFTP_SYSTEMD='hyper-cs2-sftp@{}.service'

def _v8_paths(i):
    home=gamepath(i)
    root=home/'gamefiles/game/csgo'
    private=home/'sftpgo'
    if home.is_symlink() or not home.is_dir(): fail('CS2 server path invalid')
    if not root.is_dir(): fail('CS2 files are not ready for SFTP')
    realhome=home.resolve(strict=True)
    if not root.resolve(strict=True).is_relative_to(realhome):
        fail('Unsafe SFTP directory: outside the CS2 server')
    if private.is_symlink(): fail('Unsafe SFTP config symlink')
    return home,root,private

def _v8_secret_file(i):
    return gamepath(i)/'sftpgo'/'password'

def _v8_service(i):return V8_SFTP_SYSTEMD.format(i)

def _v8_running(i):
    p=cp(['systemctl','is-active',_v8_service(i)],check=False,timeout=6)
    return p.stdout.strip()=='active'

def _v8_port_ready(i):
    sock=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    try:
        sock.settimeout(.4)
        return sock.connect_ex(('127.0.0.1',23000+i))==0
    finally:sock.close()

def sftp_info(i):
    c=load(i)
    _,root,private=_v8_paths(i)
    password_file=private/'password'
    disabled=(private/'disabled').exists()
    active=_v8_running(i) and _v8_port_ready(i)
    password=''
    if password_file.is_file() and not password_file.is_symlink():
        try:password=password_file.read_text().strip()
        except OSError: pass
    port=23000+i
    return {'ok':True,'enabled':bool(active and password and not disabled),
            'ready':c.get('state')=='ready', 'username':user(i),
            'protocol':'SFTP','port':port,'remote_dir':'/',
            'password':password if active and not disabled else '',
            'auto_setup':bool(c.get('state')=='ready' and not password and not disabled),
            'message':('SFTP запущен на отдельном защищённом порту' if active else
                       'SFTP выключен или служба не запущена'),
            'backend':'sftpgo-portable-v8'}

def _v8_write_secret(path,password,uid,gid):
    tmp=path.parent/('.password-'+_v8_secrets.token_hex(6))
    fd=os.open(str(tmp),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        os.fchown(fd,uid,gid)
        with os.fdopen(fd,'w') as f:
            f.write(password+'\n');f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if tmp.exists():tmp.unlink()

def _v8_create_sftp(i,rotate=False):
    c=load(i)
    if c.get('state')!='ready':fail('Дождитесь подготовки CS2 сервера')
    if not pathlib.Path(V8_SFTP_BINARY).is_file():
        fail('SFTPGo не установлен. Повторно запустите патч v8.')
    home,root,private=_v8_paths(i)
    try:acct=pwd.getpwnam(user(i))
    except KeyError:fail('Linux пользователь сервера '+user(i)+' отсутствует. SFTP не запускается.')
    # A direct file permission check performed as the actual unprivileged account.
    probe=cp(['runuser','-u',user(i),'--','test','-r',str(root)],check=False,timeout=7)
    if probe.returncode:fail('CS2 пользователь не может читать свою папку SFTP')
    for writable in ('cfg','addons'):
        entry=root/writable
        if entry.is_dir() and not entry.is_symlink():
            check=cp(['runuser','-u',user(i),'--','test','-w',str(entry)],check=False,timeout=7)
            if check.returncode:fail('Нет прав загрузки в '+str(entry)+'. Исправьте владельца только каталога этого сервера.')
    if private.exists() and (not private.is_dir() or private.is_symlink()):fail('Invalid SFTP private directory')
    if not private.exists():private.mkdir(mode=0o700)
    os.chown(private,acct.pw_uid,acct.pw_gid)
    os.chmod(private,0o700)
    secret=private/'password'
    if secret.is_symlink():fail('SFTP password file must not be a symlink')
    previous=secret.read_text().strip() if secret.is_file() else ''
    disabled=private/'disabled'
    if disabled.is_symlink():fail('Invalid SFTP disabled marker')
    # Independent virtual credentials. No groupadd, usermod, chpasswd, passwd or shadow files.
    fresh=rotate or not previous
    password=(_v8_secrets.token_urlsafe(24) if fresh else previous)
    if len(password)<18:password=_v8_secrets.token_urlsafe(24);fresh=True
    if disabled.exists():disabled.unlink()
    if fresh:_v8_write_secret(secret,password,acct.pw_uid,acct.pw_gid)
    srv=_v8_service(i)
    if not _v8_running(i):
        # Reject conflicting listeners rather than silently taking an unrelated TCP port.
        sock=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
        try:
            sock.settimeout(.25)
            if sock.connect_ex(('127.0.0.1',23000+i))==0:
                fail('TCP порт SFTP '+str(23000+i)+' уже используется другим процессом')
        finally:sock.close()
    cp(['systemctl','daemon-reload'],timeout=12)
    cp(['systemctl','enable',srv],timeout=12)
    # Restart only the SFTP service, never the running CS2 game.
    result=cp(['systemctl','restart',srv],check=False,timeout=30)
    if result.returncode:
        fail('Не удалось запустить SFTP: '+result.stdout[-700:])
    for tries in range(40):
        if _v8_running(i) and _v8_port_ready(i):break
        time.sleep(.25)
    if not (_v8_running(i) and _v8_port_ready(i)):
        p=cp(['journalctl','-u',srv,'-n','8','--no-pager','-o','cat'],check=False,timeout=7)
        fail('SFTP не стартовал: '+p.stdout[-800:])
    res=sftp_info(i)
    if not res['enabled']:fail('Сервис SFTP пока не подтвердил запуск')
    res['password']=password
    res['message']='SFTP активирован. Логин, оба IP и пароль доступны во вкладке SFTP.'
    return res

def sftp_enable(i):
    # Explicit enable resets the password only if one was already set. This makes
    # the existing 'Change password' button behave as expected.
    exists=_v8_secret_file(i).is_file()
    return output(_v8_create_sftp(i,rotate=exists))

def sftp_disable(i):
    load(i)
    _,_,private=_v8_paths(i)
    private.mkdir(exist_ok=True)
    marker=private/'disabled'
    marker.touch(mode=0o600)
    cp(['systemctl','stop',_v8_service(i)],check=False,timeout=15)
    output({'ok':True,'enabled':False,'message':'SFTP отключён. Игровой сервер продолжает работать.'})
'''

# Main block JS inserted after v7 functions, preserving installed controller behavior.
assert ctrl.count('def main():')==1
ctrl8=ctrl.replace('def main():',addon+'\n\ndef main():',1)
# UI surgical changes
assert panel.count('<div class="formgrid" style="margin:20px 0"><div class="field"><label>Хост</label>')==1
panel=panel.replace('<div class="formgrid" style="margin:20px 0"><div class="field"><label>Хост</label>', '''<div class="formgrid" style="margin:20px 0"><div class="field"><label>Локальный IP</label><input id="v8-sftp-local" readonly value="Определяется…"></div><div class="field"><label>Внешний IP</label><input id="v8-sftp-external" readonly value="Определяется…"></div><div class="field"><label>Хост</label>''',1)
panel=panel.replace('<label>Порт SSH</label><input id="sftp-port" readonly value="22">','<label>Порт SFTP</label><input id="sftp-port" readonly value="23002">',1)
panel=panel.replace('Новый SFTP пароль — показывается только сейчас!','Пароль SFTP · доступен сразу в панели',1)
panel=panel.replace('После закрытия страницы пароль нельзя посмотреть — можно только создать новый.','Пароль хранится в защищённом файле на сервере и доступен владельцу в панели. Кнопка выше создаёт новый пароль.',1)
panel=panel.replace('Введи IP, порт SSH и логин из панели','Введи локальный или внешний IP, порт SFTP и логин из панели',1)
panel=panel.replace('id="sftp-enable">Включить / сменить пароль','id="sftp-enable">Сменить пароль / включить',1)
panel=panel.replace('Если не удалось', 'Если не удалось', 1)
old_line = next(x for x in panel.splitlines(keepends=True) if x.startswith('async function loadSftp(){'))
new_line = '''let v8SftpProvisionAttempted=false;
async function loadSftp(){
 if(!id)return;
 try{
  const x=await get('sftp');
  $('#sftp-badge').textContent=x.enabled?'SFTP включён':x.ready?'SFTP отключён':'Сервер ещё устанавливается';
  $('#sftp-badge').classList.toggle('good',!!x.enabled);
  $('#sftp-badge').classList.toggle('wait',!x.enabled);
  $('#sftp-port').value=x.port||23000+Number(id);
  $('#sftp-user').value=x.username||('cs2s'+id);
  $('#sftp-dir').value=x.remote_dir||'/';
  const secret=$('#sftp-secret'); if(secret)secret.classList.remove('hidden');
  if($('#sftp-password'))$('#sftp-password').textContent=x.password||'SFTP ещё не настроен';
  if(x.auto_setup&&!v8SftpProvisionAttempted){
   v8SftpProvisionAttempted=true;
   const form=$('form[data-sftp="1"]');
   if(form)form.requestSubmit();
  }
  try{
   const net=await get('network');
   const lan=net.local_ip||'Не определён'; const wan=net.external_ip||'Не определён';
   if($('#v8-sftp-local'))$('#v8-sftp-local').value=lan;
   if($('#v8-sftp-external'))$('#v8-sftp-external').value=wan;
   if($('#sftp-host'))$('#sftp-host').value=wan!=='Не определён'&&!wan.startsWith('Не определён')?wan:lan;
  }catch(e){if($('#v8-sftp-external'))$('#v8-sftp-external').value='Не удалось определить';}
 }catch(e){toast(e.message,true)}
}
'''
assert panel.count(old_line)==1
panel=panel.replace(old_line,new_line,1)
# existing JS auto loadSftp call only on tab; include it after page load even if files not visited
panel=panel.replace('if(id){refresh();setInterval(()=>{if(tab===\'logs\')loadLogs();},8000);',"if(id){refresh();loadSftp();setInterval(()=>{if(tab==='logs')loadLogs();},8000);",1)
# avoid one-time placeholder password being overwritten on success by loadSftp: backend persists and returns.
panel=panel.replace('HYPER-HOST · CS2 v7 / SFTP / Plugins / IP', 'HYPER-HOST · CS2 v8 / SFTP / Plugins / IP',1)
# Since status API emits plaintext password: prevent intermediate caches as well.
panel=panel.replace('header(\'Cache-Control: private, no-store\');', "header('Cache-Control: private, no-store, max-age=0');header('Pragma: no-cache');",1)
Path(sys.argv[3]).write_text(ctrl8)
Path(sys.argv[4]).write_text(panel)
print('STAGED',len(ctrl8),len(panel),'SFTP function definitions:',len(re.findall(r'^def sftp_info\(',ctrl8,re.M)))
PYV8PATCH
python3 "$TMP/patcher.py" "$CTL" "$PANEL" "$TMP/controller" "$TMP/cs2.php"
python3 -m py_compile "$TMP/controller"
php -l "$TMP/cs2.php"
if command -v node >/dev/null 2>&1; then
  python3 - "$TMP/cs2.php" "$TMP/ui.js" <<'PYJS'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
m=re.search(r'(?s)<script>\s*(.*?)\s*</script>',s)
if not m:raise SystemExit('No JS script block')
js=re.sub(r'<\?=\$id\?>','2',m.group(1))
pathlib.Path(sys.argv[2]).write_text(js)
PYJS
  node --check "$TMP/ui.js"
fi
printf '[3/6] Install standalone SFTPGo instance service (no SSH config modifications)...\n'
cat > "$TMP/sftp-exec" <<'PYV8RUN'
#!/usr/bin/env python3
"""SFTPGo portable launcher for an existing CS2 instance; no passwd updates."""
import os, pathlib, pwd, re, sys
if len(sys.argv)!=2 or not re.fullmatch(r'[1-9][0-9]{0,3}',sys.argv[1]):
    raise SystemExit('Invalid CS2 server ID')
sid=int(sys.argv[1]); uname='cs2s'+str(sid)
if os.geteuid()!=pwd.getpwnam(uname).pw_uid:
    raise SystemExit('Wrong SFTPGo service UID')
root=pathlib.Path('/srv/hyper-cs2/servers')/str(sid)
secret=root/'sftpgo/password'; directory=root/'gamefiles/game/csgo'
if secret.is_symlink() or not secret.is_file() or not directory.is_dir():
    raise SystemExit('SFTP credentials or CS2 files are missing')
if not directory.resolve().is_relative_to(root.resolve()):
    raise SystemExit('Unsafe SFTP directory')
port=23000+sid
args=['/usr/local/bin/hyper-cs2-sftpgo','portable','-c',str(root/'sftpgo'),
      '--directory',str(directory),'--username',uname,
      '--password-file',str(secret),'--sftpd-port',str(port),
      '--ftpd-port','-1','--httpd-port','-1','--webdav-port','-1',
      '--permissions','*','--ssh-commands','pwd']
os.execv(args[0],args)
PYV8RUN
cat > "$TMP/hyper-cs2-sftp@.service" <<'V8UNIT'
[Unit]
Description=HYPER-HOST CS2 SFTP virtual access for instance %i
After=network-online.target
Wants=network-online.target
ConditionPathExists=/srv/hyper-cs2/servers/%i/gamefiles/game/csgo

[Service]
Type=simple
User=cs2s%i
Group=cs2s%i
WorkingDirectory=/srv/hyper-cs2/servers/%i/sftpgo
Environment=HOME=/srv/hyper-cs2/servers/%i/sftpgo
ExecStart=/usr/bin/python3 /usr/local/libexec/hyper-cs2-sftp-exec %i
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ReadWritePaths=/srv/hyper-cs2/servers/%i
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
CapabilityBoundingSet=
RestrictSUIDSGID=yes
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
V8UNIT
python3 -m py_compile "$TMP/sftp-exec"
install -d -m 0755 /usr/local/libexec
install -m 0755 "$TMP/sftp-exec" /usr/local/libexec/hyper-cs2-sftp-exec
install -m 0644 "$TMP/hyper-cs2-sftp@.service" /etc/systemd/system/hyper-cs2-sftp@.service
systemctl daemon-reload
STAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP=/root/hyper-cs2-sftp-v8-backup-$STAMP
mkdir -m 0700 "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs2-ctl"
cp -a "$PANEL" "$BACKUP/cs2.php"
restore(){
  echo '[ROLLBACK] Restore CS2 controller and PHP page...' >&2
  cp -a "$BACKUP/hyper-cs2-ctl" "$CTL" || true
  cp -a "$BACKUP/cs2.php" "$PANEL" || true
}
trap 'restore; exit 1' ERR
printf '[4/6] Apply CS2 SFTP-only controller and panel patch...\n'
install -m 0755 "$TMP/controller" "$CTL"
chmod --reference="$BACKUP/hyper-cs2-ctl" "$CTL"
chown --reference="$BACKUP/hyper-cs2-ctl" "$CTL"
cp --preserve=mode,ownership "$TMP/cs2.php" "$PANEL"
chown --reference="$BACKUP/cs2.php" "$PANEL"
chmod --reference="$BACKUP/cs2.php" "$PANEL"
python3 -m py_compile "$CTL";php -l "$PANEL"
printf '[5/6] Create SFTP virtual access for existing ready CS2 servers...\n'
for cfg in /var/lib/hyper-cs2/servers/*.json; do
  [[ -f "$cfg" ]] || continue
  SID=$(basename "$cfg" .json)
  [[ $SID =~ ^[1-9][0-9]{0,3}$ ]] || continue
  READY=$(python3 - "$cfg" <<'PYREADY'
import json,sys
try: print('yes' if json.load(open(sys.argv[1])).get('state')=='ready' else 'no')
except Exception:print('no')
PYREADY
)
  if [[ "$READY" == yes ]]; then
    echo "[CS2 #$SID] Setting up virtual SFTP..."
    /usr/local/sbin/hyper-cs2-ctl sftp-enable "$SID"
  fi
done
printf '[6/6] Health check...\n'
/usr/sbin/sshd -t
python3 -m py_compile "$CTL"
php -l "$PANEL"
trap - ERR
printf '\n===============================================\n'
printf ' HYPER-HOST CS2 SFTP v8 INSTALLED\n'
printf ' Panel: https://www.avito.hyper-host.pw/cs2.php\n'
printf ' Backup: %s\n' "$BACKUP"
printf ' SFTP port: TCP 23000 + server ID (e.g. #2 => 23002)\n'
printf ' No changes to /etc/passwd, /etc/shadow, CS2 game or CS1.6\n'
printf '===============================================\n'
