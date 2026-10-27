#!/usr/bin/env bash
# HYPER-HOST CS2 FTP v13 — repair only the CS2 virtual FTP account
# Reuses CS1.6 ProFTPD, no additional FTP daemons; never changes CS1.6 game files.
set -Eeuo pipefail
umask 077
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run with sudo bash' >&2; exit 1; }
for tool in python3 systemctl openssl sha256sum; do command -v "$tool" >/dev/null || { echo "[ERROR] Missing command: $tool" >&2; exit 1; }; done
SRC=/opt/hyper-host/bin/proftpd_auth_sync.py
HOSTCTL=/usr/local/sbin/hyper-host-ctl
CS2HELP=/usr/local/sbin/hyper-cs2-ftp
CREDS=/var/lib/hyper-cs2/ftp-v10/2.json
CSDIR=/srv/hyper-cs2/servers/2/gamefiles/game/csgo
BASE=/opt/hyper-host
CONF="$BASE/ftp/user_conf"
AUTH="$BASE/data/vsftpd_virtual_users.txt"
PASS="$BASE/proftpd/ftpd.passwd"
GROUP="$BASE/proftpd/ftpd.group"
[[ -f "$SRC" && -x "$HOSTCTL" && -x "$CS2HELP" ]] || { echo '[ERROR] CS2 FTP v10 or existing CS1.6 ProFTPD backend is missing' >&2; exit 1; }
[[ -d "$CSDIR" && ! -L "$CSDIR" && -d "$CONF" ]] || { echo '[ERROR] CS2 game directory missing, symlinked or FTP config directory missing' >&2; exit 1; }
mkdir -p /run/lock
exec 9>/run/lock/hyper-cs2-ftp-reconcile-v13.lock
flock -n 9 || { echo '[ERROR] Another FTP repair is running' >&2; exit 1; }
TMP=$(mktemp -d /tmp/hyper-cs2-ftp-v13.XXXXXXXX)
chmod 0700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
BACKUP="/root/hyper-cs2-ftp-v13-$(date -u +%Y%m%d-%H%M%S)-$$"
install -d -m 700 "$BACKUP"
echo "[1/6] Backup: $BACKUP"
# Capture ProFTPD generated users BEFORE calling create-ftp, so we can detect user loss.
if [[ -f "$PASS" ]]; then cp -a "$PASS" "$BACKUP/ftpd.passwd"; fi
if [[ -f "$GROUP" ]]; then cp -a "$GROUP" "$BACKUP/ftpd.group"; fi
if [[ -f /var/lib/hyper-cs2/ftp-v10/2.disabled ]]; then
  echo '[ERROR] FTP #2 is disabled in the CS2 panel. Enable it there first.' >&2
  exit 1
fi
# Do not replace or reset the password used in the CS2 panel.
echo '[2/6] Ensure CS2 is allowed by the existing ProFTPD auth generator...'
cp -a "$SRC" "$BACKUP/proftpd_auth_sync.py"
python3 - "$SRC" "$TMP/auth_sync.py" <<'PY'
from pathlib import Path
import ast,sys
src,dest=map(Path,sys.argv[1:]);s=src.read_text()
needle='    match = re.fullmatch(r"(?:hhftp_)?cs16_(\\d+)", username)'
marker='# HYPER-HOST: CS2 virtual FTP home, scoped to own server (v12)'
if marker not in s:
 if s.count(needle)!=1:raise SystemExit('[ERROR] Unexpected auth generator structure — refusing unsafe patch')
 addon='''    # HYPER-HOST: CS2 virtual FTP home, scoped to own server (v12)
    cs2_match = re.fullmatch(r"(?:hhftp_)?cs2_([1-9][0-9]{0,3})", username)
    if cs2_match:
        server_id = int(cs2_match.group(1))
        cs2_root = Path(f"/srv/hyper-cs2/servers/{server_id}")
        expected = cs2_root / "gamefiles/game/csgo"
        if absolute != expected:
            raise SystemExit(f"unsafe CS2 FTP home for {username}: {absolute} (expected {expected})")
        if not expected.is_dir():
            raise SystemExit(f"CS2 FTP home missing for {username}: {expected}")
        for component in (cs2_root, cs2_root / "gamefiles", cs2_root / "gamefiles/game", expected):
            if component.is_symlink() or Path(os.path.realpath(component)) != component:
                raise SystemExit(f"unsafe symlinked CS2 FTP home for {username}: {component}")
        return expected
'''
 s=s.replace(needle,addon+needle,1)
ast.parse(s)
dest.write_text(s)
print('[OK] Auth generator accepts exactly the CS2 server home; CS1.6 checks remain unchanged')
PY
python3 -m py_compile "$TMP/auth_sync.py"
# Apply generator before create-ftp; this is necessary because create-ftp rebuilds ProFTPD authorization.
if ! cmp -s "$SRC" "$TMP/auth_sync.py"; then
  install -m 0700 -o root -g root "$TMP/auth_sync.py" "$SRC.new-v13"
  chmod --reference="$SRC" "$SRC.new-v13"
  chown --reference="$SRC" "$SRC.new-v13"
  mv -f "$SRC.new-v13" "$SRC"
fi

echo '[3/6] Prepare and reconcile cs2_2 using the same hyper-host-ctl as CS1.6...'
if [[ ! -f "$CREDS" ]]; then
  echo '[INFO] CS2 account has not yet been created; asking the existing helper to create it.'
  "$CS2HELP" status 2 > "$TMP/initial.json" || { echo '[ERROR] CS2 FTP account initialization failed:'; python3 - "$TMP/initial.json" <<'PY'
import sys,json
try: print(json.load(open(sys.argv[1])).get('error','Unknown error'))
except Exception:print('Invalid helper output')
PY
exit 1; }
fi
python3 - "$CREDS" "$CSDIR" "$CONF" <<'PY'
import json,os,sys
from pathlib import Path
cred,home,conf = map(Path,sys.argv[1:])
if cred.is_symlink() or not cred.is_file() or (cred.stat().st_mode & 0o077):
 raise SystemExit('[ERROR] FTP credential file is missing or has unsafe permissions')
c=json.loads(cred.read_text())
if c.get('username')!='cs2_2' or not isinstance(c.get('password'),str) or not c['password']:
 raise SystemExit('[ERROR] FTP credentials for cs2_2 are invalid')
expected=Path('/srv/hyper-cs2/servers/2/gamefiles/game/csgo')
if home != expected or home.is_symlink():raise SystemExit('[ERROR] FTP home does not match CS2 #2')
for p in [Path('/srv/hyper-cs2/servers/2'),expected.parent,expected.parent.parent,expected]:
 if p.is_symlink():raise SystemExit(f'[ERROR] Symlink in chroot ancestors: {p}')
print('[OK] CS2 credentials and home path validated (password not displayed)')
PY


# Pass password via a subprocess argv without echoing it. Other accounts are not modified intentionally.
python3 - "$CREDS" "$HOSTCTL" "$TMP/create.result" <<'PY'
import json,subprocess,sys
creds,ctl,out=sys.argv[1:]
c=json.load(open(creds))
p=subprocess.run([ctl,'create-ftp','cs2_2',c['password'],'cs2','2'],capture_output=True,text=True,timeout=90)
open(out,'w').write((p.stderr or p.stdout)[-1500:])
if p.returncode:print('[WARN] create-ftp returned an error; generated account will be checked directly')
else:print('[OK] Existing hyper-host-ctl create-ftp finished')
PY
# Validate the source of truth: config path and virtual password must match the panel credentials.
python3 - "$CREDS" "$AUTH" "$CONF/cs2_2" "$CSDIR" <<'PY'
import json,sys
from pathlib import Path
cred,auth,conf,home=map(Path,sys.argv[1:]);c=json.loads(cred.read_text())
if not auth.is_file():raise SystemExit('[ERROR] FTP auth source missing')
lines=auth.read_text(errors='surrogateescape').splitlines()
pairs={lines[i]:lines[i+1] for i in range(0,len(lines)-1,2)}
if pairs.get('cs2_2') != c['password']:
 raise SystemExit('[ERROR] Stored FTP password differs from the panel credentials; account creation failed')
if not conf.exists() or f'local_root={home}' not in conf.read_text():
 raise SystemExit('[ERROR] FTP user config does not point to the CS2 game directory')
print('[OK] FTP virtual login, password and home match the CS2 panel')
PY

echo '[4/6] Generate ProFTPD authorization safely in a staging directory...'
[[ -f "$AUTH" ]] || { echo '[ERROR] Virtual FTP auth source missing'; exit 1; }
python3 "$TMP/auth_sync.py" \
  --auth-text "$AUTH" --user-conf-dir "$CONF" --ftp-dir "$BASE/ftp" \
  --passwd-file "$TMP/ftpd.passwd" --group-file "$TMP/ftpd.group" \
  --uid "$(id -u www-data)" --gid "$(id -g www-data)" --group-name www-data
python3 - "$BACKUP/ftpd.passwd" "$TMP/ftpd.passwd" <<'PY'
from pathlib import Path
import sys
old,new=map(Path,sys.argv[1:])
def names(p):return {l.split(':',1)[0] for l in p.read_text().splitlines() if ':' in l} if p.exists() else set()
before,after=names(old),names(new)
if not before.issubset(after):
 raise SystemExit('[ERROR] New auth database would REMOVE other FTP users. Aborted. Missing: '+str(sorted(before-after)[:12]))
if 'cs2_2' not in after:raise SystemExit('[ERROR] Generated ProFTPD auth has no cs2_2')
print(f'[OK] Existing FTP users preserved: {len(before)}; generated accounts: {len(after)}')
PY
# Detect concurrent changes to auth file before commit is outside scope; create-ftp source state is already staged.
install -m 0600 -o root -g root "$TMP/ftpd.passwd" "$PASS.new-v13"
install -m 0600 -o root -g root "$TMP/ftpd.group" "$GROUP.new-v13"
mv -f "$PASS.new-v13" "$PASS"
mv -f "$GROUP.new-v13" "$GROUP"

echo '[5/6] Reload only the currently active ProFTPD services...'
for unit in hyper-host-proftpd-lan.service hyper-host-proftpd-wan.service; do
  if systemctl is-active --quiet "$unit"; then
    if systemctl reload "$unit"; then echo "[OK] Reloaded $unit"; else echo "[WARN] Reload failed: $unit"; fi
  fi
done
printf '[INFO] FTP listeners:\n'
ss -ltnp '( sport = :21 )' 2>/dev/null | sed -n '1,6p' || true

echo '[6/6] Test real FTP authentication without printing the password...'
python3 - "$CREDS" <<'PY'
import ftplib,json,socket,subprocess,sys
c=json.load(open(sys.argv[1]));addresses=['127.0.0.1']
try:
 p=subprocess.run(['ip','-o','-4','addr','show','scope','global'],capture_output=True,text=True,timeout=5)
 for line in p.stdout.splitlines():
  for item in line.split():
   if item.count('.')==3 and '/' in item:
    host=item.split('/')[0]
    if host not in addresses:addresses.append(host)
except Exception:pass
success=[]
for host in addresses:
 f=ftplib.FTP()
 try:
  f.connect(host,21,timeout=6)
  f.login(c['username'],c['password'])
  print(f'[OK] FTP login cs2_2 accepted by {host}:21 (PWD={f.pwd()})')
  try:
   f.nlst();print('[OK] FTP directory listing works')
  except Exception as e:print('[WARN] FTP login succeeded, but LIST failed:',str(e)[:170])
  success.append(host)
 except Exception as e:
  print(f'[WARN] {host}:21 -> {type(e).__name__}: {str(e)[:220]}')
 finally:
  try:f.quit()
  except Exception:pass
if not success:
 print('[ERROR] FTP login failed for all local addresses. Check journalctl for hyper-host-proftpd-lan.service and ...-wan.service')
 sys.exit(2)
if any(h != '127.0.0.1' for h in addresses) and not any(h != '127.0.0.1' for h in success):
 print('[ERROR] Login works on loopback only; the LAN listener still rejects the account')
 sys.exit(2)

PY

echo
printf '[OK] CS2 FTP v13 repaired and verified; CS1.6 was not reinstalled.\n'
echo 'In FileZilla use FTP, port 21, user cs2_2, the password shown in the CS2 panel.'
