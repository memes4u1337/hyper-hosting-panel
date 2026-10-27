#!/usr/bin/env bash
# HYPER-HOST CS2 FTP v15: reconcile only CS2 #2 password with native ProFTPD.
# Does not reinstall CS2, change user/group accounts, or add FTP daemons.
set -Eeuo pipefail
umask 077
if (( EUID != 0 )); then echo '[ERROR] Run as root (sudo bash)' >&2; exit 1; fi
for exe in python3 openssl systemctl; do command -v "$exe" >/dev/null || { echo "[ERROR] Missing $exe" >&2; exit 1; }; done
TMP="$(mktemp -d /tmp/hyper-cs2-ftp-v15.XXXXXXXX)"
chmod 0700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/repair.py" <<'PY'
#!/usr/bin/env python3
"""Conservative, account-scoped repair for native HYPER-HOST virtual FTP."""
from pathlib import Path
import fcntl, ftplib, hashlib, json, os, re, shutil, socket, stat, subprocess, sys, tempfile, time

ROOT = Path('/opt/hyper-host')
AUTH = ROOT / 'data/vsftpd_virtual_users.txt'
CONF = ROOT / 'ftp/user_conf'
GEN = ROOT / 'bin/proftpd_auth_sync.py'
PASS = ROOT / 'proftpd/ftpd.passwd'
GROUP = ROOT / 'proftpd/ftpd.group'
CREDS = Path('/var/lib/hyper-cs2/ftp-v10/2.json')
HOME = Path('/srv/hyper-cs2/servers/2/gamefiles/game/csgo')
USERNAME = 'cs2_2'
TARGETS = {'cs2_2', 'hhftp_cs2_2'}
USER_RE = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_-]{1,63}$')

def die(s): raise RuntimeError(s)
def run(args, timeout=60):
    p=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
    if p.returncode:die(f'Command failed ({args[0]}): {(p.stderr or p.stdout)[-450:]}')
    return p

def norm(s):
    # Exactly matches normalize_pairs() in the native generator.
    return s.replace('\\r\\n','\n').replace('\\n','\n') if '\\n' in s and s.count('\n')<=1 else s

def effective(lines):
    d={}
    for n in range(0,len(lines)-1,2):
        u=lines[n].strip(); pw=lines[n+1]
        if USER_RE.fullmatch(u) and pw and u not in d:d[u]=pw
    return d

def atomic(dest, content):
    dest.parent.mkdir(parents=True,exist_ok=True)
    old=dest.stat() if dest.exists() else None
    fd,path=tempfile.mkstemp(prefix='.'+dest.name+'.v15-',dir=str(dest.parent))
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(content);f.flush();os.fsync(f.fileno())
        os.chmod(path,stat.S_IMODE(old.st_mode) if old else 0o600)
        os.chown(path,old.st_uid if old else 0,old.st_gid if old else 0)
        os.replace(path,dest)
    finally:
        if os.path.exists(path):os.unlink(path)

def ftp_test(password):
    hosts=['127.0.0.1']
    p=subprocess.run(['ip','-o','-4','addr','show','scope','global'],capture_output=True,text=True,timeout=5)
    for match in re.findall(r'\binet\s+(\d+\.\d+\.\d+\.\d+)/',p.stdout):
        if match not in hosts:hosts.append(match)
    succeeded=[]
    for host in hosts:
        f=ftplib.FTP()
        try:
            f.connect(host,21,timeout=6)
            f.login(USERNAME,password)
            print(f'[OK] FTP login {USERNAME} accepted on {host}:21')
            succeeded.append(host)
        except (OSError,ftplib.Error) as exc:
            print(f'[INFO] {host}:21 -> {type(exc).__name__}: {str(exc)[:160]}')
        finally:
            try:f.quit()
            except Exception:pass
    return succeeded,hosts

def main():
    for p in (AUTH,GEN,CREDS,CONF/USERNAME):
        if not p.is_file() or p.is_symlink():die(f'Missing/unsafe source: {p}')
    if not HOME.is_dir() or HOME.is_symlink():die(f'Invalid CS2 FTP home: {HOME}')
    if CREDS.stat().st_mode & 0o077:die('Unsafe credentials file permissions')
    c=json.loads(CREDS.read_text())
    password=c.get('password')
    if c.get('username')!=USERNAME or not isinstance(password,str) or not password or any(ch in password for ch in '\n\r\x00'):
        die('CS2 panel credentials missing or invalid')
    cfg=(CONF/USERNAME).read_text(errors='replace').splitlines()
    if 'local_root='+str(HOME) not in cfg:die('CS2 FTP root in user config does not match server #2')
    for p in (HOME,HOME.parent,HOME.parent.parent,Path('/srv/hyper-cs2/servers/2')):
        if p.is_symlink():die(f'Symlinked CS2 FTP home component: {p}')
    # Never load the actual password into CLI arguments or log it.
    lock=Path('/run/lock/hyper-cs2-ftp-v15.lock')
    lock.parent.mkdir(parents=True,exist_ok=True)
    with lock.open('a+') as l:
        try:fcntl.flock(l,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:die('Another v15 FTP repair is running')
        backups=Path('/root/hyper-cs2-ftp-v15-'+time.strftime('%Y%m%d-%H%M%S',time.gmtime())+'-'+str(os.getpid()))
        backups.mkdir(mode=0o700)
        for path in (AUTH,PASS,GROUP):
            if path.is_file():shutil.copy2(path,backups/path.name)
        print(f'[1/5] Backup: {backups}')
        original_bytes=AUTH.read_bytes()
        raw=original_bytes.decode('utf-8','surrogateescape')
        nraw=norm(raw)
        lines=nraw.splitlines()
        before=effective(lines)
        duplicates=len([u for i in range(0,len(lines)-1,2) if (u:=lines[i].strip()) in before])-len(before)
        invalid=sum(1 for i in range(0,len(lines)-1,2) if not USER_RE.fullmatch(lines[i].strip()) or not lines[i+1])
        print(f'[2/5] FTP source: {len(before)} effective accounts; {max(0,duplicates)} duplicates; {invalid} invalid pairs (left untouched)')
        if len(lines)%2 and lines[-1]=='':
            # Native normalize_pairs ignores this trailing blank item.
            lines.pop()
        elif len(lines)%2 and USERNAME not in before:
            die('FTP source has an unpaired trailing item and no cs2_2 entry; refusing to append')
        # If real login already works, no file modifications are needed.
        try:
            ok,hosts=ftp_test(password)
            if ok:
                print('[OK] CS2 FTP already authenticates. Global FTP database not changed.')
                return
        except Exception as exc:print(f'[INFO] Initial FTP check unavailable: {type(exc).__name__}')
        changes=0
        after_lines=lines.copy()
        for i in range(0,len(after_lines)-1,2):
            user=after_lines[i].strip()
            if user in TARGETS and USER_RE.fullmatch(user):
                if after_lines[i+1]!=password:
                    after_lines[i+1]=password;changes+=1
        if USERNAME not in before:
            after_lines.extend([USERNAME,password]);changes+=1
        after=effective(after_lines)
        if after.get(USERNAME)!=password:die('Cannot locate an unambiguous active CS2 login. No changes made')
        for u,p in before.items():
            if u not in TARGETS and after.get(u)!=p:
                die(f'Guard rejected a change to unrelated FTP account {u!r}')
        if set(after)-set(before)-{USERNAME}:
            die('Guard rejected an unexpected new account')
        # Keep native literal-newline format if that is what the native generator accepted.
        out='\n'.join(after_lines)+'\n'
        escaped='\\n' in raw and raw.count('\n')<=1
        if escaped:
            out=out.replace('\n','\\n')
            if raw.endswith('\n'):out+='\n'
        staged=Path(sys.argv[1]);staged.mkdir(mode=0o700,exist_ok=True)
        stage_auth=staged/'auth.txt';stage_auth.write_bytes(out.encode('utf-8','surrogateescape'))
        stage_pass=staged/'ftpd.passwd';stage_group=staged/'ftpd.group'
        uid=run(['id','-u','www-data']).stdout.strip()
        gid=run(['id','-g','www-data']).stdout.strip()
        run([sys.executable,str(GEN),'--auth-text',str(stage_auth),'--user-conf-dir',str(CONF),
             '--ftp-dir',str(ROOT/'ftp'),'--passwd-file',str(stage_pass),'--group-file',str(stage_group),
             '--uid',uid,'--gid',gid,'--group-name','www-data'],timeout=90)
        def generated_names(p):
            return {line.split(':',1)[0] for line in p.read_text().splitlines() if ':' in line} if p.is_file() else set()
        prior_users=generated_names(PASS)
        new_users=generated_names(stage_pass)
        if not prior_users.issubset(new_users):
            die(f'Guard refused to remove existing ProFTPD accounts: {len(prior_users-new_users)} affected')
        if USERNAME not in new_users:die('Staged ProFTPD output does not contain cs2_2')
        if len(new_users)!=len(after):die('Staged ProFTPD user count inconsistent with source')
        print(f'[3/5] Staged {len(new_users)} FTP users; other effective passwords preserved; CS2 entries repaired: {changes}')
        if AUTH.read_bytes()!=original_bytes:die('FTP source changed concurrently; no changes made')
        modified=[]
        try:
            for dest,contents in ((AUTH,stage_auth.read_bytes()),(PASS,stage_pass.read_bytes()),(GROUP,stage_group.read_bytes())):
                atomic(dest,contents);modified.append(dest)
            print('[4/5] Applied native FTP auth files; reloading active ProFTPD...')
            for service in ('hyper-host-proftpd-lan.service','hyper-host-proftpd-wan.service'):
                if subprocess.run(['systemctl','is-active','--quiet',service],capture_output=True).returncode==0:
                    p=subprocess.run(['systemctl','reload',service],capture_output=True,text=True,timeout=12)
                    print(f'[INFO] {service} reload: {"OK" if p.returncode==0 else "unsupported/failed"}')
            ok,hosts=ftp_test(password)
            if not ok:die('FTP authentication still fails; previous FTP auth files will be restored')
            if any(h!='127.0.0.1' for h in hosts) and not any(h!='127.0.0.1' for h in ok):
                print('[WARN] Localhost login succeeded, LAN login did not: check FTP LAN listener / firewall')
            print('[5/5] OK: FTP cs2_2 verified, credential files synchronized')
        except Exception:
            for dest in reversed(modified):
                saved=backups/dest.name
                if saved.is_file():atomic(dest,saved.read_bytes())
                else:dest.unlink(missing_ok=True)
            for service in ('hyper-host-proftpd-lan.service','hyper-host-proftpd-wan.service'):
                if subprocess.run(['systemctl','is-active','--quiet',service],capture_output=True).returncode==0:
                    subprocess.run(['systemctl','reload',service],capture_output=True,timeout=10)
            print('[ROLLBACK] FTP auth files restored from backup')
            raise

if __name__=='__main__':
    try:main()
    except Exception as e:
        print(f'[ERROR] {type(e).__name__}: {e}',file=sys.stderr)
        sys.exit(1)
PY
python3 -m py_compile "$TMP/repair.py"
python3 "$TMP/repair.py" "$TMP"
