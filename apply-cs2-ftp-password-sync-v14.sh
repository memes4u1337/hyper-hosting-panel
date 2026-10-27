#!/usr/bin/env bash
# HYPER-HOST CS2 FTP v14 - reconcile panel password with native CS1.6 FTP.
# Does not create Linux users, alter CS1.6 game files or install a new daemon.
set -Eeuo pipefail
umask 077
if (( EUID != 0 )); then echo '[ERROR] Run: sudo bash apply-cs2-ftp-password-sync-v14.sh' >&2; exit 1; fi
for x in python3 openssl flock systemctl ss; do command -v "$x" >/dev/null || { echo "[ERROR] Missing tool: $x" >&2; exit 1; }; done

ROOT=/opt/hyper-host
AUTH="$ROOT/data/vsftpd_virtual_users.txt"
CFG="$ROOT/ftp/user_conf"
SYNC="$ROOT/bin/proftpd_auth_sync.py"
PASS="$ROOT/proftpd/ftpd.passwd"
GROUP="$ROOT/proftpd/ftpd.group"
CRED=/var/lib/hyper-cs2/ftp-v10/2.json
HOME_CS2=/srv/hyper-cs2/servers/2/gamefiles/game/csgo
for x in "$AUTH" "$SYNC" "$CRED" "$CFG/cs2_2"; do
  [[ -f "$x" && ! -L "$x" ]] || { echo "[ERROR] Required regular file not found: $x" >&2; exit 1; }
done
[[ -d "$HOME_CS2" && ! -L "$HOME_CS2" ]] || { echo '[ERROR] CS2 FTP directory missing or symlinked' >&2; exit 1; }
for parent in /srv/hyper-cs2/servers/2 /srv/hyper-cs2/servers/2/gamefiles /srv/hyper-cs2/servers/2/gamefiles/game; do
  [[ -d "$parent" && ! -L "$parent" ]] || { echo "[ERROR] Symlinked or missing FTP parent: $parent" >&2; exit 1; }
done
[[ -d "$(dirname "$PASS")" && ! -L "$AUTH" ]] || { echo '[ERROR] FTP backend missing' >&2; exit 1; }
mkdir -p /run/lock
exec 9>/run/lock/hyper-cs2-ftp-password-v14.lock
flock -n 9 || { echo '[ERROR] Another CS2 FTP repair is active' >&2; exit 1; }
TMP=$(mktemp -d /tmp/hyper-cs2-ftp-v14.XXXXXXXX)
chmod 0700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
BACKUP=/root/hyper-cs2-ftp-v14-$(date -u +%Y%m%d-%H%M%S)-$$
install -d -m 0700 "$BACKUP"
for name in "$AUTH" "$PASS" "$GROUP" "$CFG/cs2_2"; do
  [[ -f "$name" ]] && cp -a "$name" "$BACKUP/$(basename "$name")" || true
done
printf '[1/5] Backups: %s\n' "$BACKUP"

# Normalize using the SAME parser rules as ProFTPD's auth generator; check the
# full source of virtual users before changing anything. Only CS2 #2 credentials
# may be changed. Do not print passwords to stdout, stderr or process arguments.
python3 - "$AUTH" "$CRED" "$CFG/cs2_2" "$HOME_CS2" "$TMP/auth.txt" "$TMP/source.sha256" <<'PY'
from pathlib import Path
import hashlib,json,os,re,sys
src,credentials,conf,expected,out,sha=map(Path,sys.argv[1:])
if src.is_symlink() or credentials.is_symlink():raise SystemExit('[ERROR] Symlinked credential source')
if credentials.stat().st_mode & 0o077:raise SystemExit('[ERROR] Unsafe CS2 panel credential permissions')
c=json.loads(credentials.read_text(encoding='utf-8'))
if c.get('username')!='cs2_2' or not isinstance(c.get('password'),str) or not c['password']:
    raise SystemExit('[ERROR] Panel FTP credentials are absent or invalid')
if any(x in c['password'] for x in ('\n','\r','\x00')):raise SystemExit('[ERROR] Invalid password characters')
if 'local_root='+str(expected) not in conf.read_text(encoding='utf-8').splitlines():
    raise SystemExit('[ERROR] cs2_2 FTP config points to wrong home')
rawbytes=src.read_bytes()
raw=rawbytes.decode('utf-8','surrogateescape')
# Match normalize_pairs() in HYPER-HOST's proftpd_auth_sync.py.
if '\\n' in raw and raw.count('\n') <= 1:
    raw=raw.replace('\\r\\n','\n').replace('\\n','\n')
lines=raw.splitlines()
pattern=re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_-]{1,63}$')
if len(lines)%2:raise SystemExit('[ERROR] Odd number of FTP auth lines; refusing unsafe rewrite')
pairs=[]; seen=set()
for i in range(0,len(lines),2):
    user=lines[i].strip(); password=lines[i+1]
    if not pattern.fullmatch(user) or not password or user in seen:
        raise SystemExit('[ERROR] Invalid or duplicated FTP user source; refusing unsafe rewrite')
    pairs.append((user,password));seen.add(user)
if not pairs:raise SystemExit('[ERROR] FTP database is empty; refusing unsafe rewrite')
updated=0; matched=[]
for n,(user,password) in enumerate(pairs):
    if user in ('cs2_2','hhftp_cs2_2'):
        matched.append(user)
        if password!=c['password']:
            pairs[n]=(user,c['password']);updated+=1
if 'cs2_2' not in seen:
    pairs.append(('cs2_2',c['password']));updated+=1
# Preserve the FULL set of existing virtual FTP accounts and their passwords.
assert set(user for user,_ in pairs)==seen|{'cs2_2'}
rendered=''.join(user+'\n'+password+'\n' for user,password in pairs)
out.write_bytes(rendered.encode('utf-8','surrogateescape'))
sha.write_text(hashlib.sha256(rawbytes).hexdigest())
print(f'[OK] Virtual FTP source parsed: {len(seen)} original accounts, {updated} CS2 credential entries reconciled')
PY

printf '[2/5] Staging native ProFTPD database...\n'
python3 -m py_compile "$SYNC"
python3 "$SYNC" \
 --auth-text "$TMP/auth.txt" --user-conf-dir "$CFG" --ftp-dir "$ROOT/ftp" \
 --passwd-file "$TMP/ftpd.passwd" --group-file "$TMP/ftpd.group" \
 --uid "$(id -u www-data)" --gid "$(id -g www-data)" --group-name www-data \
 >"$TMP/generator.log"
python3 - "$TMP/ftpd.passwd" "$PASS" "$TMP/auth.txt" <<'PY'
import sys
from pathlib import Path
new,old,source=map(Path,sys.argv[1:])
def users(p):return {line.partition(':')[0] for line in p.read_text().splitlines() if ':' in line} if p.exists() else set()
old_users,new_users=users(old),users(new)
if not old_users.issubset(new_users):
    raise SystemExit('[ERROR] Refusing to remove FTP users: '+str(sorted(old_users-new_users)[:10]))
if 'cs2_2' not in new_users:raise SystemExit('[ERROR] cs2_2 absent from generated ProFTPD passwd')
print(f'[OK] Staged FTP accounts: {len(new_users)}; existing ProFTPD users preserved: {len(old_users)}')
PY

printf '[3/5] Committing CS2 password + generated ProFTPD users...\n'
python3 - "$AUTH" "$TMP/auth.txt" "$TMP/source.sha256" "$PASS" "$TMP/ftpd.passwd" "$GROUP" "$TMP/ftpd.group" <<'PY'
from pathlib import Path
import hashlib,os,stat,sys,tempfile
source,staged,checksum,passfile,pass_staged,groupfile,group_staged=map(Path,sys.argv[1:])
if hashlib.sha256(source.read_bytes()).hexdigest()!=checksum.read_text().strip():
    raise SystemExit('[ERROR] FTP auth source changed during repair; aborting')
def replace(dest,data,mode):
    dest.parent.mkdir(parents=True,exist_ok=True)
    st=dest.stat() if dest.exists() else None
    fd,fn=tempfile.mkstemp(prefix='.'+dest.name+'.v14-',dir=str(dest.parent))
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        os.chmod(fn,stat.S_IMODE(st.st_mode) if st else mode)
        if st:os.chown(fn,st.st_uid,st.st_gid)
        os.replace(fn,dest)
    finally:
        if os.path.exists(fn):os.unlink(fn)
replace(source,staged.read_bytes(),0o600)
replace(passfile,pass_staged.read_bytes(),0o600)
replace(groupfile,group_staged.read_bytes(),0o600)
print('[OK] Password and ProFTPD data synchronized')
PY

printf '[4/5] Reloading active ProFTPD listeners...\n'
ACTIVE=0
for unit in hyper-host-proftpd-lan.service hyper-host-proftpd-wan.service; do
  if systemctl is-active --quiet "$unit"; then
    ACTIVE=$((ACTIVE+1))
    if systemctl reload "$unit"; then echo "[OK] Reloaded $unit";
    else echo "[WARN] Reload unsupported for $unit; service was NOT restarted"; fi
  fi
done
if (( ACTIVE == 0 )); then echo '[WARN] No ProFTPD service active. Check TCP 21 and native FTP service.'; fi
ss -ltnp '( sport = :21 )' | sed -n '1,7p' || true

printf '[5/5] Testing actual FTP login (password hidden)...\n'
python3 - "$CRED" <<'PY'
import ftplib,json,subprocess,sys
from pathlib import Path
cred=json.loads(Path(sys.argv[1]).read_text())
addresses=['127.0.0.1']
try:
    p=subprocess.run(['ip','-o','-4','addr','show'],text=True,capture_output=True,timeout=5)
    for line in p.stdout.splitlines():
        for word in line.split():
            if word.count('.')==3 and '/' in word:
                host=word.split('/')[0]
                if host not in addresses:addresses.append(host)
except Exception:pass
logged=[]
for host in addresses:
    f=ftplib.FTP()
    try:
        f.connect(host,21,timeout=5)
        f.login('cs2_2',cred['password'])
        print(f'[OK] cs2_2 authenticated on {host}:21')
        logged.append(host)
    except Exception as e:
        print(f'[WARN] {host}:21: {type(e).__name__}: {str(e)[:180]}')
    finally:
        try:f.quit()
        except Exception:pass
if not logged:
    raise SystemExit('[ERROR] FTP credentials synchronized, but no local login succeeded. Check ProFTPD service logs. Backup retained.')
print('[OK] FTP password matches the CS2 panel; live login succeeded')
PY

echo 'HYPER-HOST CS2 FTP v14: completed. CS1.6 and CS2 game files not changed.'
