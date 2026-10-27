#!/usr/bin/env bash
# HYPER-HOST CS2 v10: use EXACTLY existing hyper-host-ctl FTP backend from CS1.6
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '[ERROR] Запустите через sudo bash' >&2; exit 1; }
CTL=/usr/local/sbin/hyper-cs2-ctl
PANEL=/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/cs2.php
HELPER=/usr/local/sbin/hyper-cs2-ftp
HOSTCTL=/usr/local/sbin/hyper-host-ctl
[[ -f "$CTL" && -f "$PANEL" && -f "$HOSTCTL" ]] || { echo '[ERROR] Модуль CS2 не найден' >&2;exit 1; }
for x in python3 php; do command -v "$x" >/dev/null || { echo "[ERROR] Нет команды $x" >&2;exit 1; }; done
TMP=$(mktemp -d /tmp/hyper-cs2-ftp-v10.XXXXXXXX)
chmod 0700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
if grep -q '^# CS2 FTP v10:' "$CTL" && grep -q 'cs2|counter-strike-2) echo cs2' "$HOSTCTL" && grep -q 'id="cs2ftp-card"' "$PANEL" && [[ -x "$HELPER" ]]; then
 echo '[OK] HYPER-HOST CS2 FTP v10 already installed'; exit 0
fi
cat > "$TMP/helper.py" <<'END_HELPER'
#!/usr/bin/env python3
"""Reuse the actual HYPER-HOST CS1.6 FTP account creation/runtime for CS2."""
import fcntl, ftplib, ipaddress, json, os, pathlib, pwd, re, secrets, socket, stat, subprocess, sys, tempfile
from pathlib import Path
CTL='/usr/local/sbin/hyper-host-ctl'
ROOT=Path('/srv/hyper-cs2/servers')
STATE=Path('/var/lib/hyper-cs2/servers')
CREDS=Path('/var/lib/hyper-cs2/ftp-v10')

def err(message): raise RuntimeError(str(message))
def output(data):print(json.dumps(data,ensure_ascii=False))
def cmd(argv,timeout=55):
    p=subprocess.run(argv,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if p.returncode: err((p.stderr or p.stdout or 'FTP controller failed').strip()[-900:])
    return p.stdout.strip()
def check_id(raw):
    try:i=int(raw)
    except ValueError:err('Некорректный ID')
    if not 1<=i<=9999:err('Некорректный ID')
    return i

def get_root(i):
    st=STATE/(str(i)+'.json')
    if not st.is_file() or st.is_symlink():err('Сервер CS2 отсутствует в панели')
    obj=json.loads(st.read_text())
    if int(obj.get('id',-1))!=i or obj.get('state')!='ready':err('Сервер CS2 ещё не подготовлен')
    base=ROOT/str(i)
    root=base/'gamefiles/game/csgo'
    if base.is_symlink() or root.is_symlink() or not root.is_dir():err('Файлы сервера CS2 ещё не подготовлены')
    if not root.resolve().is_relative_to(base.resolve()):err('Некорректная ссылка на каталог CS2')
    for part in ('cfg','addons'):
        p=root/part
        if not p.is_dir() or p.is_symlink() or not p.resolve().is_relative_to(root.resolve()):
            err('Каталог '+part+' CS2 отсутствует или небезопасен')
    return base,root

def lan_ip():
    try:
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        s.connect(('1.1.1.1',53));addr=s.getsockname()[0];s.close();return addr
    except OSError:return ''

def wan_ip(i):
    # Reuse configured CS2 network status; it may cache public IP.
    try:
        p=subprocess.run(['/usr/local/sbin/hyper-cs2-ctl','network-info',str(i)],capture_output=True,text=True,timeout=7)
        d=json.loads(p.stdout)
        for key in ('external_ip','public_ip'):
            value=str(d.get(key,'')).strip()
            if value:
                try:
                    if ipaddress.ip_address(value).version==4:return value
                except ValueError:continue
    except (OSError,ValueError,KeyError,TypeError,subprocess.TimeoutExpired):pass
    try:
        env=Path('/etc/hyper-host/config.env')
        if env.exists():
            txt=env.read_text(errors='ignore')
            for name in ('STATIC_PUBLIC_IP','PUBLIC_IP','SERVER_IP'):
                m=re.search(r'^'+name+r'=([0-9.]+)\s*$',txt,re.M)
                if m and ipaddress.ip_address(m.group(1)).version==4:return m.group(1)
    except (OSError,ValueError):pass
    return ''

def secretfile(i):return CREDS/(str(i)+'.json')
def read_creds(i):
    f=secretfile(i)
    if f.is_symlink():err('Небезопасный файл FTP-пароля')
    if f.is_file():
        c=json.loads(f.read_text())
        if c.get('username')!='cs2_'+str(i):err('Данные FTP повреждены')
        return c
    return None

def save(i,data):
    CREDS.mkdir(mode=0o700,parents=True,exist_ok=True)
    os.chmod(CREDS,0o700)
    fd,p=tempfile.mkstemp(prefix='.cs2ftp-',dir=CREDS)
    try:
        with os.fdopen(fd,'w') as out:
            out.write(json.dumps(data,ensure_ascii=False)+'\n');out.flush();os.fsync(out.fileno())
        os.chmod(p,0o600);os.replace(p,secretfile(i))
    finally:
        if os.path.exists(p):os.unlink(p)

def allow_writes(root):
    guest=pwd.getpwnam('www-data')
    # Apply permissions only to per-instance writable CS2 folders, never shared base.
    for part in ('cfg','addons'):
        folder=root/part
        if folder.is_symlink():err('Нельзя изменять права через ссылку: '+part)
        if subprocess.run(['bash','-c','command -v setfacl >/dev/null'],capture_output=True).returncode==0:
            # ACL preserves CS2 owner/group. Default ACL applies to new uploaded content.
            for current,dirs,files in os.walk(folder,followlinks=False):
                dirs[:]=[d for d in dirs if not (Path(current)/d).is_symlink()]
                if Path(current).is_symlink():continue
                cmd(['setfacl','-m','u:www-data:rwx,d:u:www-data:rwx',current],timeout=8)
                for name in files:
                    path=Path(current)/name
                    if not path.is_symlink():cmd(['setfacl','-m','u:www-data:rw-',str(path)],timeout=8)
        else:
            # No ACL available: retain CS2 file owner, give guest group access only to cfg/addons.
            for current,dirs,files in os.walk(folder,followlinks=False):
                dirs[:]=[d for d in dirs if not (Path(current)/d).is_symlink()]
                st=os.stat(current,follow_symlinks=False)
                os.chown(current,st.st_uid,guest.pw_gid,follow_symlinks=False)
                os.chmod(current,stat.S_IMODE(st.st_mode)|0o2770,follow_symlinks=False)
                for name in files:
                    p=Path(current)/name
                    if p.is_symlink():continue
                    st=os.stat(p,follow_symlinks=False)
                    os.chown(p,st.st_uid,guest.pw_gid,follow_symlinks=False)
                    os.chmod(p,stat.S_IMODE(st.st_mode)|0o660,follow_symlinks=False)
    # FTP guest must traverse gamefiles and the per-instance parent tree.
    # Apply only to this server's path; the large shared base is never chmodded.
    acl_available=subprocess.run(['bash','-c','command -v setfacl >/dev/null'],capture_output=True).returncode==0
    parent=root
    while parent == root or parent.is_relative_to(ROOT):
        if parent.is_symlink():err('Недопустимая ссылка на корневой каталог FTP')
        if acl_available:
            cmd(['setfacl','-m','u:www-data:'+('rx' if parent==root else 'x'),str(parent)],timeout=8)
        else:
            st=parent.stat()
            os.chmod(parent,stat.S_IMODE(st.st_mode)|(0o005 if parent==root else 0o001))
        parent=parent.parent

def try_ftp(login,password):
    ftp=ftplib.FTP()
    try:
        ftp.connect('127.0.0.1',21,timeout=7)
        ftp.login(login,password)
        # Don't require data connection here: passive-port NAT can differ.
        return True
    finally:
        try:ftp.quit()
        except Exception:pass

def details(i,c,active=True):
    return {'ok':True,'enabled':active,'ready':True,'username':c.get('username','cs2_'+str(i)),
            'password':c.get('password','') if active else '', 'protocol':'FTP','port':21,
            'external_ip':wan_ip(i),'local_ip':lan_ip(),'remote_dir':'/',
            'message':'FTP через штатный HYPER-HOST FTP, как в CS1.6'}

def change(i,action):
    base,root=get_root(i)
    username='cs2_'+str(i)
    CREDS.mkdir(mode=0o700,parents=True,exist_ok=True)
    with open('/run/lock/hyper-cs2-ftp-v10.lock','a+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        previous=read_creds(i)
        if action=='disable':
            if previous:
                cmd([CTL,'delete-ftp',username])
                secretfile(i).unlink(missing_ok=True)
            (CREDS/(str(i)+'.disabled')).write_text('disabled\n')
            return details(i,{},False)
        disabled=CREDS/(str(i)+'.disabled')
        if disabled.exists() and action=='status':
            return details(i,{},False)
        if previous and action=='status':
            return details(i,previous,True)
        # CS1.6 uses this SAME create-ftp command. No edits to passwd/shadow, no manual authfile.
        password=secrets.token_urlsafe(18)
        allow_writes(root)
        cmd([CTL,'create-ftp',username,password,'cs2',str(i)],timeout=65)
        try:
            try_ftp(username,password)
        except Exception as ex:
            # A failure here is reported; credentials are kept so the user can diagnose FTP connectivity.
            save(i,{'username':username,'password':password,'connection_warning':str(ex)})
            disabled.unlink(missing_ok=True)
            return {**details(i,{'username':username,'password':password},True),
                    'warning':'FTP создан, но тест входа на 127.0.0.1:21 не прошёл: '+str(ex)}
        save(i,{'username':username,'password':password})
        disabled.unlink(missing_ok=True)
        return details(i,{'username':username,'password':password},True)

def main():
    if os.geteuid()!=0:err('Необходимо запустить от root')
    action=sys.argv[1] if len(sys.argv)>1 else 'preflight'
    if action=='preflight':
        txt=Path(CTL).read_text()
        if 'ftp_scope_normalize' not in txt or 'create-ftp' not in txt or 'cs2|counter-strike-2)' not in txt:
            err('Существующий FTP-контроллер не поддерживает CS2')
        output({'ok':True,'backend':'hyper-host-ctl','port':21});return
    if action not in ('status','enable','reset','disable'):err('Неизвестная команда FTP')
    i=check_id(sys.argv[2])
    output(change(i,action))

if __name__=='__main__':
    try:main()
    except Exception as ex:output({'ok':False,'error':str(ex)});sys.exit(1)
END_HELPER
cat > "$TMP/addon.py" <<'END_ADDON'

# CS2 FTP v10: use hyper-host-ctl create-ftp, as in CS 1.6.
# Controllers keep their historical sftp-* action names only for API compatibility.
CS2_FTP_V10='/usr/local/sbin/hyper-cs2-ftp'
def _cs2_ftp_v10(action,i):
    p=cp([CS2_FTP_V10,action,str(i)],check=False,timeout=28)
    try:data=json.loads(p.stdout.strip())
    except Exception:fail('FTP helper: '+p.stdout[-600:])
    if p.returncode or not data.get('ok'):fail(data.get('error','FTP не настроен'))
    return data
def sftp_info(i):return _cs2_ftp_v10('status',i)
def sftp_enable(i):output(_cs2_ftp_v10('reset',i))
def sftp_disable(i):output(_cs2_ftp_v10('disable',i))
END_ADDON
cat > "$TMP/ftp.html" <<'END_HTML'
<section class="panel" data-panel="files">
  <div class="grid">
    <div class="col7 card" id="cs2ftp-card">
      <div class="flex between" style="margin-bottom:14px"><div><span class="muted small" style="letter-spacing:.12em">HYPER-HOST · FILE ACCESS</span><h2 style="margin:5px 0 0">FTP-доступ к CS2</h2></div><span class="badge wait" id="sftp-badge">Проверка FTP</span></div>
      <div class="notice" style="margin-bottom:15px">Тот же FTP-сервер FTP и порт 21, что используются в хостинге CS 1.6. Доступ ограничен папкой вашего CS2-сервера.</div>
      <div class="formgrid" style="margin-bottom:18px">
        <div class="field"><label>Внешний IP сервера</label><div class="flex"><input id="cs2ftp-public" readonly value="<?=e($ip)?>"><button type="button" class="btn sm" id="cs2ftp-copy-public">Копировать</button></div></div>
        <div class="field"><label>Локальный IP сервера</label><div class="flex"><input id="cs2ftp-local" readonly value="<?=e($localIp)?>"><button type="button" class="btn sm" id="cs2ftp-copy-local">Копировать</button></div></div>
        <div class="field"><label>FTP-порт</label><input id="sftp-port" value="21" readonly></div>
        <div class="field"><label>Протокол</label><input readonly value="FTP (HYPER-HOST · CS 1.6)"></div>
        <div class="field"><label>Логин FTP</label><div class="flex"><input id="sftp-user" readonly value="cs2_<?=$id?>"><button type="button" class="btn sm" id="cs2ftp-copy-user">Копировать</button></div></div>
        <div class="field"><label>Стартовая папка</label><input id="sftp-dir" readonly value="/"></div>
      </div>
      <div class="secretreveal" id="sftp-secret" style="display:block"><div class="flex between"><strong>Пароль FTP</strong><span class="muted small">Доступен сразу, без генерации по кнопке</span></div><div class="flex" style="margin-top:10px"><code id="sftp-password" class="mono" style="font-size:16px;overflow-wrap:anywhere;flex:1">Проверка...</code><button class="btn sm" type="button" id="copy-password">Скопировать</button></div></div>
      <div id="v7-sftp-error" class="alertbox hidden" style="margin:13px 0"></div>
      <div class="flex" style="margin-top:16px;flex-wrap:wrap">
        <button type="button" class="btn sm" id="cs2ftp-refresh">↻ Обновить данные</button>
        <form class="ajaxform" method="post" data-sftp="1" data-confirm="Создать новый FTP-пароль? Старый перестанет работать."><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="sftp-enable"><button class="btn ghost sm" type="submit">Сменить пароль</button></form>
        <form class="ajaxform" method="post" data-sftp="1" data-confirm="Отключить FTP-аккаунт этого сервера?\nДля включения снова понадобится обновить страницу."><?=csrf_field()?><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="action" value="sftp-disable"><button class="btn red sm" type="submit">Отключить FTP</button></form>
      </div>
    </div>
    <div class="col5 card"><h2>Подключение — как в CS 1.6</h2><div class="stack"><div><b>1.</b> Откройте FileZilla</div><div><b>2.</b> Протокол FTP, порт <b>21</b></div><div><b>3.</b> Адрес — внешний или локальный IP</div><div><b>4.</b> Введите логин и пароль слева</div><div><b>5.</b> В корне сервера находятся <code>cfg/</code> и <code>addons/</code></div></div><div class="notice warn" style="margin-top:19px">Внешнее подключение зависит от доступности TCP 21 и пассивных портов FTP на маршрутизаторе. В публичной сети предпочитайте FTPS, если на существующем ProFTPD включён TLS.</div></div>
  </div>
END_HTML
cat > "$TMP/ftp.js" <<'END_JS'
async function loadSftp(){
 if(!id)return;
 try{
  const x=await get('sftp');
  const badge=$('#sftp-badge');badge.textContent=x.enabled?'FTP работает':'FTP не готов';badge.classList.toggle('good',!!x.enabled);badge.classList.toggle('wait',!x.enabled);
  $('#sftp-port').value=String(x.port||21);$('#sftp-user').value=x.username||('cs2_'+id);$('#sftp-dir').value=x.remote_dir||'/';
  $('#sftp-password').textContent=x.password||'Нет данных';
  if(x.external_ip)$('#cs2ftp-public').value=x.external_ip;
  if(x.local_ip)$('#cs2ftp-local').value=x.local_ip;
  const err=$('#v7-sftp-error');if(err){err.textContent='';err.classList.add('hidden');}
 }catch(e){const box=$('#v7-sftp-error');if(box){box.textContent=e.message;box.classList.remove('hidden');}$('#sftp-badge').textContent='Ошибка FTP';$('#sftp-password').textContent='Недоступен';}
}
$('#cs2ftp-refresh')?.addEventListener('click',loadSftp);
$('#cs2ftp-copy-public')?.addEventListener('click',()=>copy($('#cs2ftp-public').value+':21'));
$('#cs2ftp-copy-local')?.addEventListener('click',()=>copy($('#cs2ftp-local').value+':21'));
$('#cs2ftp-copy-user')?.addEventListener('click',()=>copy($('#sftp-user').value));
END_JS
cat > "$TMP/patch.py" <<'END_PATCH'
#!/usr/bin/env python3
from pathlib import Path
import sys,re
ctl=Path(sys.argv[1]).read_text()
panel=Path(sys.argv[2]).read_text()
addon=Path(sys.argv[3]).read_text()
block=Path(sys.argv[4]).read_text()
js=Path(sys.argv[5]).read_text()
if '# CS2 FTP v10:' in ctl:
    raise SystemExit('CONTROLLER_ALREADY_PATCHED')
if ctl.count('\ndef main():')!=1:raise SystemExit('Cannot locate CS2 controller main()')
if not all(x in ctl for x in ('def sftp_info(i):','def sftp_enable(i):','def sftp_disable(i):')):
    raise SystemExit('Unsupported CS2 controller: no SFTP API')
ctl=ctl.replace('\ndef main():','\n'+addon+'\ndef main():',1)
start=panel.find('<section class="panel" data-panel="files">')
end=panel.find('<div class="card" style="margin-top:18px" id="v5-browser">',start)
if start<0 or end<0 or end<start:raise SystemExit('Cannot locate CS2 FTP UI region')
panel=panel[:start]+block+panel[end:]
old_start=panel.find('async function loadSftp(){')
if old_start<0:raise SystemExit('Cannot locate JS loadSftp()')
# Scan JS braces, aware of strings and templates, to preserve all adjacent logic.
i=old_start+len('async function loadSftp(){');depth=1;quote=None;escape=False
while i<len(panel) and depth:
    c=panel[i]
    if quote:
        if escape:escape=False
        elif c=='\\':escape=True
        elif c==quote:quote=None
    elif c in ('"',"'",'`'):quote=c
    elif c=='{':depth+=1
    elif c=='}':depth-=1
    i+=1
if depth:raise SystemExit('Broken JS brace nesting in loadSftp()')
panel=panel[:old_start]+js+panel[i:]
panel=panel.replace('Файлы / SFTP','Файлы / FTP').replace('⇪ Настроить SFTP-доступ','⇪ Открыть FTP-доступ').replace('бинарные файлы загружаются через SFTP','бинарные файлы загружаются через FTP')
if '#cs2ftp-card' not in panel and 'id="cs2ftp-card"' not in panel:raise SystemExit('FTP markup missing')
Path(sys.argv[6]).write_text(ctl)
Path(sys.argv[7]).write_text(panel)
END_PATCH

cat > "$TMP/patch-host.py" <<'PYHOST'
#!/usr/bin/env python3
from pathlib import Path
import sys,re
host=Path(sys.argv[1]).read_text()
def insert_once(text,needle,repl,desc):
    count=text.count(needle)
    if count!=1:raise SystemExit(f'[ERROR] {desc}: expected 1 match, got {count}; no files modified')
    return text.replace(needle,repl,1)
if 'cs2|counter-strike-2) echo cs2 ;;' in host:
    print('[INFO] hyper-host-ctl already supports CS2 scope')
    Path(sys.argv[2]).write_text(host)
    raise SystemExit(0)
# Minimal patch to the EXISTING CS1.6 FTP scope, no changes to password backend.
host=insert_once(host,'    cs16|game|game-server|counter-strike) echo cs16 ;;',
    '    cs16|game|game-server|counter-strike) echo cs16 ;;\n    cs2|counter-strike-2) echo cs2 ;;','FTP scope normalize')
host=insert_once(host,'    cs16) echo "CS 1.6 сервер #${target:-?}" ;;',
    '    cs16) echo "CS 1.6 сервер #${target:-?}" ;;\n    cs2) echo "CS 2 сервер #${target:-?}" ;;','FTP scope label')
# The only bare cs16 case belongs to ftp_prepare_scope (confirmed from live controller dump).
needle='    cs16)\n'
if host.count(needle)!=1:raise SystemExit('[ERROR] Cannot identify FTP CS16 directory case uniquely')
idx=host.index(needle)
end=host.find('\n      ;;',idx)
if end<0 or end-idx>1000:raise SystemExit('[ERROR] Unexpected FTP directory case layout')
segment=host[idx:end]
if '/srv/hyper-cs16/servers/$target' not in segment:raise SystemExit('[ERROR] CS16 FTP scope content mismatch')
cs2="""    cs2)
      [[ "$target" =~ ^[0-9]+$ ]] || err "Для режима cs2 укажи числовой ID сервера"
      local_root="/srv/hyper-cs2/servers/$target/gamefiles/game/csgo"
      [[ -d "$local_root" && ! -L "$local_root" ]] || err "Папка CS2 FTP не найдена: $local_root"
      [[ -f "/var/lib/hyper-cs2/servers/$target.json" ]] || err "CS2 сервер не найден: $target"
      ;;"""
host=host[:end+len('\n      ;;')]+ '\n'+cs2 +host[end+len('\n      ;;'):]
Path(sys.argv[2]).write_text(host)
PYHOST

printf '[1/6] Read and stage CS1.6 FTP backend...\n'
python3 "$TMP/patch-host.py" "$HOSTCTL" "$TMP/new-hostctl"
bash -n "$TMP/new-hostctl"

printf '[2/6] Stage CS2 controller and frontend...\n'
python3 "$TMP/patch.py" "$CTL" "$PANEL" "$TMP/addon.py" "$TMP/ftp.html" "$TMP/ftp.js" "$TMP/new-controller" "$TMP/new-panel"
python3 -m py_compile "$TMP/helper.py" "$TMP/patch.py" "$TMP/new-controller"
php -l "$TMP/new-panel"
if command -v node >/dev/null; then
  python3 - "$TMP/new-panel" "$TMP/ui.js" <<'PYJS'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]).read_text()
s=re.findall(r'<script[^>]*>(.*?)</script>',p,re.S)
if s: Path(sys.argv[2]).write_text(s[-1].replace('const id=<?=$id?>;','const id=2;'))
PYJS
  [[ ! -s "$TMP/ui.js" ]] || node --check "$TMP/ui.js"
fi

printf '[3/6] Backing up exact current files...\n'
BKP="/root/hyper-cs2-ftp-v10-$(date -u +%Y%m%d-%H%M%S)"
mkdir -m 0700 "$BKP"
cp -a "$HOSTCTL" "$BKP/hyper-host-ctl"
cp -a "$CTL" "$BKP/hyper-cs2-ctl"
cp -a "$PANEL" "$BKP/cs2.php"
[[ ! -f "$HELPER" ]] || cp -a "$HELPER" "$BKP/hyper-cs2-ftp.old"

printf '[4/6] Apply native CS1.6 FTP scope to CS2...\n'
rollback() {
  echo '[ERROR] Rolling back controllers and PHP...' >&2
  cp -a "$BKP/hyper-host-ctl" "$HOSTCTL"
  cp -a "$BKP/hyper-cs2-ctl" "$CTL"
  cp -a "$BKP/cs2.php" "$PANEL"
  if [[ -f "$BKP/hyper-cs2-ftp.old" ]]; then cp -a "$BKP/hyper-cs2-ftp.old" "$HELPER";else rm -f "$HELPER";fi
}
trap 'rollback' ERR
install -o root -g root -m 0755 "$TMP/new-hostctl" "$HOSTCTL"
install -o root -g root -m 0750 "$TMP/helper.py" "$HELPER"
install -o root -g root -m 0755 "$TMP/new-controller" "$CTL"
install -o root -g root -m 0644 "$TMP/new-panel" "$PANEL"
bash -n "$HOSTCTL"
python3 -m py_compile "$CTL"
php -l "$PANEL" >/dev/null
"$HELPER" preflight
trap - ERR

printf '[5/6] CS2 FTP smoke checks...\n'
# Do not expose new passwords in install output; they are shown via authenticated CS2 panel.
if [[ -f /var/lib/hyper-cs2/servers/2.json ]]; then
  if "$HELPER" status 2 > "$TMP/ftp-result.json"; then
    python3 - "$TMP/ftp-result.json" <<'PYSTATUS'
import json,sys
v=json.load(open(sys.argv[1]))
print('CS2 #2 FTP:', 'configured' if v.get('enabled') else 'disabled', 'user:',v.get('username'),'port:',v.get('port'))
if v.get('warning'):print('WARNING:',v['warning'])
PYSTATUS
  else
    python3 - "$TMP/ftp-result.json" <<'PYSTATUS'
import json,sys
try:print('[WARN] CS2 #2 FTP:',json.load(open(sys.argv[1])).get('error','Unknown'))
except Exception:print('[WARN] CS2 #2 FTP setup failed; inspect panel / API diagnostics')
PYSTATUS
  fi
fi
printf '[6/6] Finished.\n'
printf '\nHYPER-HOST CS2 FTP v10 installed\nBackup: %s\nFTP: existing CS1.6 backend / port 21\nPanel: https://www.avito.hyper-host.pw/cs2.php?id=2\n' "$BKP"
printf 'Game files, SteamCMD and CS1.6 instances were not reinstalled.\n'
