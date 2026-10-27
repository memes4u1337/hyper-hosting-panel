#!/usr/bin/env bash
# HYPER-HOST CS2 v9: same ProFTPD FTP runtime as CS1.6. No SFTPGo or passwd/shadow modification.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '[ERROR] Запустите через sudo bash' >&2; exit 1; }
CTL=/usr/local/sbin/hyper-cs2-ctl
PANEL=/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/cs2.php
HELPER=/usr/local/sbin/hyper-cs2-ftp
[[ -f "$CTL" && -f "$PANEL" ]] || { echo '[ERROR] Модуль CS2 не найден' >&2;exit 1; }
for x in python3 php openssl ss; do command -v "$x" >/dev/null || { echo "[ERROR] Нет команды $x" >&2;exit 1; }; done
TMP=$(mktemp -d /tmp/hyper-cs2-ftp-v9.XXXXXXXX)
chmod 0700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/helper.py" <<'END_HELPER'
#!/usr/bin/env python3
"""CS2 FTP accounts in the SAME ProFTPD AuthUserFile runtime as CS1.6.
No OS accounts are created or modified. Never touch existing CS16 entries.
"""
import fcntl, ftplib, json, os, pathlib, pwd, re, secrets, socket, subprocess, sys, time, hashlib, tempfile, stat
from pathlib import Path
AUTHRE=re.compile(r'^\s*AuthUserFile\s+(\S+)',re.I)
BASE=Path('/srv/hyper-cs2/servers')
STATE=Path('/var/lib/hyper-cs2/servers')
SECRETS=Path('/var/lib/hyper-cs2/ftp')

def error(msg): raise RuntimeError(str(msg))
def jprint(d): print(json.dumps(d,ensure_ascii=False))
def run(cmd,inp=None,timeout=12):
    p=subprocess.run(cmd,input=inp,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if p.returncode: error(' '.join(cmd[:2])+': '+(p.stderr or p.stdout).strip()[-450:])
    return p.stdout.strip()
def ident(raw):
    i=int(raw)
    if not 1<=i<=9999:error('Неверный ID CS2 сервера')
    return i

def setup(i):
    cf=STATE/f'{i}.json'
    if not cf.is_file():error('Сервер CS2 отсутствует')
    c=json.loads(cf.read_text())
    if int(c['id'])!=i or c.get('state')!='ready':error('CS2 сервер ещё не подготовлен')
    base=BASE/str(i)
    if base.is_symlink() or not base.is_dir():error('Некорректный каталог сервера')
    root=base/'gamefiles/game/csgo'
    if not root.is_dir() or root.is_symlink() or not root.resolve().is_relative_to(base.resolve()):
        error('Каталог CS2 для FTP не готов или содержит небезопасную ссылку')
    if not (root/'addons').is_dir() or not (root/'cfg').is_dir():error('Не найдены cfg и addons в CS2')
    try:account=pwd.getpwnam('cs2s'+str(i))
    except KeyError:error('Linux-пользователь игрового сервера отсутствует (cs2s'+str(i)+')')
    return base,root,account

def find_auth():
    # Parse only existing ProFTPD configuration, not arbitrary system files.
    paths=[]
    for folder in ('/etc/proftpd','/etc/hyper-host','/etc/hyper-hosting'):
        base=Path(folder)
        if not base.exists():continue
        for file in base.rglob('*'):
            if not file.is_file() or file.is_symlink() or file.stat().st_size>2_000_000:continue
            if file.suffix.lower() not in ('.conf','.cfg','') and file.name!='proftpd.conf':continue
            try:txt=file.read_text(errors='replace')
            except OSError:continue
            for line in txt.splitlines():
                if line.lstrip().startswith('#'):continue
                match=AUTHRE.search(line)
                if match:
                    p=Path(match.group(1).strip('"\''))
                    if not p.is_absolute():continue
                    if p.is_file() and not p.is_symlink():paths.append(p)
    matches=[]
    for path in dict.fromkeys(paths):
        lines=path.read_text(errors='replace').splitlines()
        if any(re.match(r'^cs16_\d+:',x) for x in lines): matches.append(path)
    if len(matches)!=1:
        error('Не удалось однозначно определить FTP-базу CS 1.6 (найдено: '+str(len(matches))+'). '+
              'Проверьте AuthUserFile ProFTPD. Файлы CS1.6 не изменены.')
    return matches[0]

def public_ip():
    # Prefer the SAME configured public IP used by the existing CS16 runtime.
    try:
        rt=json.loads(Path('/etc/hyper-cs16/runtime.json').read_text())
        value=str(rt.get('public_ip','')).strip()
        if re.fullmatch(r'\d{1,3}(?:\.\d{1,3}){3}',value):return value
    except Exception:pass
    return ''
def local_ip():
    try:
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(('1.1.1.1',53));ip=s.getsockname()[0];s.close();return ip
    except OSError:return ''

def creds_file(i):return SECRETS/f'{i}.json'
def read_creds(i):
    p=creds_file(i)
    if not p.is_file() or p.is_symlink():return None
    d=json.loads(p.read_text())
    if d.get('username') != 'cs2_'+str(i):error('FTP данные сервера повреждены')
    return d

def atomic(path,data,uid=None,gid=None,mode=None):
    st=path.stat() if path.exists() else None
    fd,tmp=tempfile.mkstemp(prefix='.hypercs2-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as f:f.write(data);f.flush();os.fsync(f.fileno())
        os.chmod(tmp,mode if mode is not None else (stat.S_IMODE(st.st_mode) if st else 0o600))
        os.chown(tmp,uid if uid is not None else (st.st_uid if st else 0),gid if gid is not None else (st.st_gid if st else 0))
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def lines_account(auth,username):
    lines=auth.read_text().splitlines()
    return lines,[line for line in lines if line.startswith(username+':')]

def ftp_probe(username,password):
    ftp=ftplib.FTP()
    try:
        ftp.connect('127.0.0.1',21,timeout=6)
        ftp.login(username,password)
        # Verify that the chroot is CS2 root, not an unrelated existing account.
        ftp.set_pasv(False)
        entries=set(ftp.nlst())
        if not any('cfg' == x.rstrip('/').split('/')[-1] for x in entries) or not any('addons' == x.rstrip('/').split('/')[-1] for x in entries):
            error('FTP авторизован, но открывается не папка CS2 (нет cfg/addons)')
        return True
    finally:
        try:ftp.quit()
        except Exception:pass

def save_secret(i,data):
    SECRETS.mkdir(parents=True,exist_ok=True,mode=0o700)
    os.chmod(SECRETS,0o700)
    atomic(creds_file(i),json.dumps(data,ensure_ascii=False,indent=2)+'\n',mode=0o600)

def _update(i,rotate=False,disable=False):
    base,root,acct=setup(i)
    username='cs2_'+str(i)
    SECRETS.mkdir(parents=True,exist_ok=True,mode=0o700)
    lock='/run/lock/hyper-cs2-ftp-v9.lock'
    with open(lock,'a+') as f:
        fcntl.flock(f,fcntl.LOCK_EX)
        auth=find_auth()
        lines,entries=lines_account(auth,username)
        if len(entries)>1:error('Дубли учётной записи '+username+' в ProFTPD')
        previous=read_creds(i)
        marker=SECRETS/f'{i}.disabled'
        if disable:
            if entries:atomic(auth,'\n'.join(x for x in lines if not x.startswith(username+':'))+'\n')
            if creds_file(i).exists():creds_file(i).unlink()
            marker.write_text('disabled\n');os.chmod(marker,0o600)
            return {'ok':True,'enabled':False,'message':'FTP отключён'}
        if marker.exists() and not rotate:
            return {'ok':True,'enabled':False,'ready':True,'username':username,'port':21,
                    'protocol':'FTP','password':'','local_ip':local_ip(),'external_ip':public_ip(),
                    'remote_dir':'/','message':'FTP отключён. Для повторного включения нажми «Сменить пароль».'}
        if previous and entries and not rotate:
            try:ftp_probe(username,previous['password'])
            except Exception as exc:error('Ранее созданный FTP не проходит проверку: '+str(exc))
            return details(i,previous,True)
        password=secrets.token_urlsafe(18)
        hashed=run(['openssl','passwd','-6','-stdin'],password+'\n')
        # One virtual ProFTPD entry; CS1.6 entries are preserved byte-for-byte.
        newentry=f'{username}:{hashed}:{acct.pw_uid}:{acct.pw_gid}:CS2 {i}:{root}:/bin/false'
        updated=[line for line in lines if not line.startswith(username+':')]
        updated.append(newentry)
        original=auth.read_text()
        atomic(auth,'\n'.join(updated)+'\n')
        try:
            # Allow ProFTPD to re-read AuthUserFile; do NOT restart the running FTP daemon.
            time.sleep(.4)
            ftp_probe(username,password)
        except Exception as exc:
            atomic(auth,original)
            error('Новый FTP не прошёл проверку, база восстановлена: '+str(exc))
        if marker.exists():marker.unlink()
        result={'username':username,'password':password}
        save_secret(i,result)
        return details(i,result,True)

def details(i,c,enabled):
    return {'ok':True,'enabled':enabled,'ready':True,'protocol':'FTP','username':c['username'],
            'password':c['password'],'port':21,'local_ip':local_ip(), 'external_ip':public_ip(),
            'remote_dir':'/','message':'FTP через тот же ProFTPD, что и CS 1.6'}

def main():
    if os.geteuid()!=0:error('Требуется root')
    a=sys.argv[1] if len(sys.argv)>1 else ''
    if a=='preflight':
        p=find_auth()
        st=p.stat()
        if st.st_mode & 0o002:error('FTP-база ProFTPD доступна на запись всем: '+str(p))
        jprint({'ok':True,'authfile':str(p),'mode':oct(stat.S_IMODE(st.st_mode))});return
    i=ident(sys.argv[2]) if len(sys.argv)>2 else 0
    if a not in ('status','enable','reset','disable'):error('Неизвестная команда')
    if a=='disable':result=_update(i,disable=True)
    else:result=_update(i,rotate=(a=='reset'))
    jprint(result)
if __name__=='__main__':
    try:main()
    except Exception as exc:jprint({'ok':False,'error':str(exc)});sys.exit(1)
END_HELPER
cat > "$TMP/addon.py" <<'END_ADDON'

# CS2 FTP v9: use the same ProFTPD virtual-user AuthUserFile as CS 1.6.
# Controllers keep their historical sftp-* action names only for API compatibility.
CS2_FTP_V9='/usr/local/sbin/hyper-cs2-ftp'
def _cs2_ftp_v9(action,i):
    p=cp([CS2_FTP_V9,action,str(i)],check=False,timeout=28)
    try:data=json.loads(p.stdout.strip())
    except Exception:fail('FTP helper: '+p.stdout[-600:])
    if p.returncode or not data.get('ok'):fail(data.get('error','FTP не настроен'))
    return data
def sftp_info(i):return _cs2_ftp_v9('status',i)
def sftp_enable(i):output(_cs2_ftp_v9('reset',i))
def sftp_disable(i):output(_cs2_ftp_v9('disable',i))
END_ADDON
cat > "$TMP/ftp.html" <<'END_HTML'
<section class="panel" data-panel="files">
  <div class="grid">
    <div class="col7 card" id="cs2ftp-card">
      <div class="flex between" style="margin-bottom:14px"><div><span class="muted small" style="letter-spacing:.12em">HYPER-HOST · FILE ACCESS</span><h2 style="margin:5px 0 0">FTP-доступ к CS2</h2></div><span class="badge wait" id="sftp-badge">Проверка FTP</span></div>
      <div class="notice" style="margin-bottom:15px">Тот же FTP-сервер ProFTPD и порт 21, что используются в хостинге CS 1.6. Доступ ограничен папкой вашего CS2-сервера.</div>
      <div class="formgrid" style="margin-bottom:18px">
        <div class="field"><label>Внешний IP сервера</label><div class="flex"><input id="cs2ftp-public" readonly value="<?=e($ip)?>"><button type="button" class="btn sm" id="cs2ftp-copy-public">Копировать</button></div></div>
        <div class="field"><label>Локальный IP сервера</label><div class="flex"><input id="cs2ftp-local" readonly value="<?=e($localIp)?>"><button type="button" class="btn sm" id="cs2ftp-copy-local">Копировать</button></div></div>
        <div class="field"><label>FTP-порт</label><input id="sftp-port" value="21" readonly></div>
        <div class="field"><label>Протокол</label><input readonly value="FTP (ProFTPD · CS 1.6)"></div>
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
if '# CS2 FTP v9:' in ctl:
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

python3 -m py_compile "$TMP/helper.py" "$TMP/patch.py"
if grep -q '# CS2 FTP v9:' "$CTL"; then
  echo '[INFO] CS2 FTP v9 уже применён. Повторно файлы не меняем.'
  exit 0
fi
python3 "$TMP/patch.py" "$CTL" "$PANEL" "$TMP/addon.py" "$TMP/ftp.html" "$TMP/ftp.js" "$TMP/new-controller" "$TMP/new-panel"
python3 -m py_compile "$TMP/new-controller"
php -l "$TMP/new-panel" >/dev/null
if command -v node >/dev/null; then
  python3 - "$TMP/new-panel" "$TMP/ui.js" <<'END_JS_EXTRACT'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]).read_text()
s=re.findall(r'<script[^>]*>(.*?)</script>',p,re.S)
if s:Path(sys.argv[2]).write_text(s[-1].replace('const id=<?=$id?>;', 'const id=2;'))
END_JS_EXTRACT
  if [[ -f "$TMP/ui.js" ]]; then node --check "$TMP/ui.js"; fi
fi
# Validate the currently running CS1.6 FTP service before touching shared auth.
if ! timeout 3 bash -c '</dev/tcp/127.0.0.1/21' 2>/dev/null; then
  echo '[ERROR] ProFTPD CS 1.6 не слушает порт 21. Ничего не меняем.' >&2;exit 1
fi
# Check CS1.6 virtual FTP backend BEFORE touching any PHP/controller files.
if ! python3 "$TMP/helper.py" preflight; then
  echo '[ERROR] FTP CS 1.6 не использует однозначно определяемый AuthUserFile. CS2 не изменён.' >&2
  exit 1
fi
BKP="/root/hyper-cs2-ftp-v9-$(date -u +%Y%m%d-%H%M%S)"
mkdir -m 0700 "$BKP"
cp -a "$CTL" "$BKP/hyper-cs2-ctl"
cp -a "$PANEL" "$BKP/cs2.php"
# Backup the EXACT virtual authentication file used by CS1.6 before adding CS2 users.
AUTHFILE=$(python3 "$TMP/helper.py" preflight | python3 -c 'import sys,json;print(json.load(sys.stdin)["authfile"])')
cp -a "$AUTHFILE" "$BKP/proftpd-auth-before"
if [[ -f "$HELPER" ]]; then cp -a "$HELPER" "$BKP/hyper-cs2-ftp.old";fi
# Atomic staged replacement with backups. Existing CS1.6 accounts are NOT edited here.
install -o root -g root -m 0750 "$TMP/helper.py" "$HELPER"
cp "$TMP/new-controller" "$TMP/controller.tmp"
cp "$TMP/new-panel" "$TMP/panel.tmp"
install -o root -g root -m 0755 "$TMP/controller.tmp" "$CTL"
install -o root -g root -m 0644 "$TMP/panel.tmp" "$PANEL"
python3 -m py_compile "$CTL" && php -l "$PANEL" >/dev/null || {
  cp -a "$BKP/hyper-cs2-ctl" "$CTL"
  cp -a "$BKP/cs2.php" "$PANEL"
  echo '[ERROR] Обнаружена ошибка после установки, выполнен откат' >&2;exit 1
}
# Pre-create FTP only for already prepared instances. Failed accounts do not affect CS1.6.
PROVISION_FAILED=0
for f in /var/lib/hyper-cs2/servers/[0-9]*.json; do
  [[ -f "$f" ]] || continue
  ID=$(basename "$f" .json)
  echo "[FTP CS2 #$ID] Настройка через ProFTPD CS1.6..."
  if ! "$HELPER" status "$ID"; then
    echo "[WARN] FTP для CS2 #$ID не подтверждён. См. сообщение выше; другие службы не изменены." >&2
    PROVISION_FAILED=1
  fi
done
echo
printf '============================================================
'
echo ' HYPER-HOST CS2 FTP v9: установлен модуль FTP из CS1.6'
echo " Backup: $BKP"
echo ' Panel: https://www.avito.hyper-host.pw/cs2.php?id=2'
echo ' FTP порт: 21 (тот же ProFTPD, что CS1.6)'
echo ' Game files and CS1.6 service unchanged.'
printf '============================================================
'
if [[ $PROVISION_FAILED -ne 0 ]]; then
  echo '[ERROR] Модуль установлен, но как минимум один FTP-аккаунт не прошёл проверку.' >&2
  exit 1
fi
