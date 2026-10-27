#!/usr/bin/env bash
# HYPER-HOST CS2 FTP v16 - targeted cs2_2 credential reconciliation.
# Reuses existing CS1.6 ProFTPD; does not rebuild or delete other accounts.
set -Eeuo pipefail
umask 077
if (( EUID != 0 )); then echo '[ERROR] Run with sudo bash' >&2; exit 1; fi
for binary in python3 openssl systemctl; do
  command -v "$binary" >/dev/null || { echo "[ERROR] Missing $binary" >&2; exit 1; }
done
WORK="$(mktemp -d /tmp/hyper-cs2-ftp-v16.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/repair.py" <<'PY'
#!/usr/bin/env python3
"""Change only CS2 #2 virtual FTP credentials, not the other HYPER-HOST accounts."""
from __future__ import annotations
import fcntl
import ftplib
import json
import os
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path('/opt/hyper-host')
AUTH = ROOT / 'data/vsftpd_virtual_users.txt'
PASSWD = ROOT / 'proftpd/ftpd.passwd'
GROUP = ROOT / 'proftpd/ftpd.group'
CONFDIR = ROOT / 'ftp/user_conf'
CREDS = Path('/var/lib/hyper-cs2/ftp-v10/2.json')
HOME = Path('/srv/hyper-cs2/servers/2/gamefiles/game/csgo')
LOGIN = 'cs2_2'
ALIAS = 'hhftp_cs2_2'
USER_RE = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_-]{1,63}$')
SERVICES = ('hyper-host-proftpd-lan.service', 'hyper-host-proftpd-wan.service')


def error(message):
    raise RuntimeError(message)


def normalize(raw):
    # Exactly the same interpretation as the native proftpd_auth_sync.py.
    if '\\n' in raw and raw.count('\n') <= 1:
        return raw.replace('\\r\\n', '\n').replace('\\n', '\n')
    return raw


def effective(raw):
    lines = normalize(raw).splitlines()
    result = {}
    for i in range(0, len(lines) - 1, 2):
        username = lines[i].strip()
        password = lines[i + 1]
        if USER_RE.fullmatch(username) and password and username not in result:
            result[username] = password
    return result


def source_for_accounts(raw, password, targets):
    prior = effective(raw)
    if all(prior.get(u) == password for u in targets):
        return raw
    # Prefix complete pairs (even number of entries). The native generator
    # keeps the first valid occurrence, so malformed and duplicate entries
    # belonging to unrelated accounts remain byte-for-byte untouched.
    sep = '\\n' if '\\n' in raw and raw.count('\n') <= 1 else '\n'
    prefix = ''.join(u + sep + password + sep for u in targets)
    updated = prefix + raw
    after = effective(updated)
    if any(after.get(u) != password for u in targets):
        error('FTP text source cannot represent CS2 credentials safely')
    for u, pw in prior.items():
        if u not in targets and after.get(u) != pw:
            error('Guard: change to unrelated virtual FTP account ' + u)
    if set(after) - set(prior) - set(targets):
        error('Guard: unexpected FTP account appeared')
    return updated


def parse_passwd(data):
    records = {}
    for line in data.splitlines():
        if not line:
            continue
        name, sep, remainder = line.partition(b':')
        if not sep or not USER_RE.fullmatch(name.decode('ascii', 'ignore')):
            error('Unsupported generated ProFTPD passwd format; not modifying it')
        user = name.decode('ascii')
        if user in records:
            error('Duplicate generated ProFTPD account: ' + user)
        if len(remainder.split(b':')) < 6:
            error('Malformed generated ProFTPD passwd row for ' + user)
        records[user] = line
    return records


def make_passwd(original, targets, password, uid, gid):
    hashed = subprocess.run(['openssl', 'passwd', '-6', '-stdin'], input=(password + '\n').encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    value = hashed.stdout.strip()
    if hashed.returncode or not value.startswith(b'$6$') or b':' in value:
        error('Cannot produce the password hash with openssl')
    old = parse_passwd(original)
    lines = []
    for line in original.splitlines(keepends=True):
        name = line.split(b':', 1)[0].decode('ascii', 'ignore')
        if name not in targets:
            lines.append(line)
    updated = b''.join(lines)
    if updated and not updated.endswith(b'\n'):
        updated += b'\n'
    for username in targets:
        record = f'{username}:'.encode() + value + f':{uid}:{gid}:HYPER-HOST FTP:{HOME}:/usr/sbin/nologin\n'.encode()
        updated += record
    new = parse_passwd(updated)
    if set(new) - set(old) - set(targets):
        error('Guard: unrelated generated FTP account appeared')
    if any(new.get(user) != row for user, row in old.items() if user not in targets):
        error('Guard: unrelated ProFTPD passwd row changed')
    for username in targets:
        if username not in new or str(HOME).encode() not in new[username]:
            error('Guard: generated CS2 passwd row invalid')
    return updated


def make_group(original, targets, gid):
    found = 0
    output = []
    for line in original.splitlines(keepends=True):
        base, ending = (line[:-1], b'\n') if line.endswith(b'\n') else (line, b'')
        fields = base.split(b':', 3)
        if len(fields) == 4 and fields[0] == b'www-data' and fields[2] == str(gid).encode():
            found += 1
            members = fields[3].decode('ascii').split(',') if fields[3] else []
            for username in targets:
                if username not in members:
                    members.append(username)
            fields[3] = ','.join(members).encode()
            line = b':'.join(fields) + ending
        output.append(line)
    if found != 1:
        error('Expected exactly one www-data FTP group; refusing changes')
    return b''.join(output)


def atomic_write(path, contents, previous_stat):
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.v16-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(contents)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, stat.S_IMODE(previous_stat.st_mode))
        os.chown(tmp, previous_stat.st_uid, previous_stat.st_gid)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def hosts():
    items = ['127.0.0.1']
    p = subprocess.run(['ip', '-o', '-4', 'addr', 'show', 'scope', 'global'],
                       text=True, capture_output=True, timeout=5)
    for address in re.findall(r'\binet\s+(\d+\.\d+\.\d+\.\d+)/', p.stdout):
        if address not in items:
            items.append(address)
    return items


def check_login(password):
    messages = []
    accepted = []
    for host in hosts():
        ftp = ftplib.FTP()
        try:
            ftp.connect(host, 21, timeout=7)
            ftp.login(LOGIN, password)
            path = ftp.pwd()
            accepted.append(host)
            messages.append(f'[OK] {host}:21: FTP login {LOGIN} successful, remote directory {path!r}')
        except (OSError, ftplib.Error, EOFError) as exc:
            messages.append(f'[INFO] {host}:21: {type(exc).__name__}: {str(exc)[:180]}')
        finally:
            try:
                ftp.close()
            except Exception:
                pass
    for message in messages:
        print(message, flush=True)
    return accepted


def reload_active():
    for service in SERVICES:
        active = subprocess.run(['systemctl', 'is-active', '--quiet', service],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if active:
            p = subprocess.run(['systemctl', 'reload', service], capture_output=True, text=True, timeout=15)
            print(f'[INFO] {service}: {"reloaded" if p.returncode == 0 else "reload not supported"}', flush=True)


def main():
    if os.geteuid():
        error('Must be root')
    for path in (AUTH, PASSWD, GROUP, CREDS, CONFDIR / LOGIN):
        if not path.is_file() or path.is_symlink():
            error('Missing or symlinked configuration file: ' + str(path))
    if CREDS.stat().st_mode & 0o077:
        error('Credentials file must be accessible to root only (mode 600)')
    config = json.loads(CREDS.read_text())
    password = config.get('password')
    if config.get('username') != LOGIN or not isinstance(password, str) or not password:
        error('FTP account/password not present in CS2 panel')
    if any(c in password for c in '\n\r\x00:'):
        error('Invalid FTP password in CS2 panel')
    server = Path('/srv/hyper-cs2/servers/2')
    for component in (server, server / 'gamefiles', HOME.parent.parent, HOME.parent, HOME):
        if component.is_symlink() or not component.is_dir():
            error('CS2 FTP home contains a link or missing directory: ' + str(component))
    if HOME.resolve(strict=True) != HOME:
        error('CS2 FTP home is not a physical directory')
    if 'local_root=' + str(HOME) not in (CONFDIR / LOGIN).read_text().splitlines():
        error('CS2 FTP virtual user has another home directory')
    for component in ('cfg', 'addons'):
        if not (HOME / component).is_dir():
            error('CS2 ' + component + ' directory does not exist')
    owner = pwd.getpwnam('www-data')
    lock_path = Path('/run/lock/hyper-cs2-ftp-v16.lock')
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        print('[1/5] Checking CS2 FTP credentials...', flush=True)
        before_login = check_login(password)
        if before_login:
            print('[OK] FTP cs2_2 already works. No authorization files modified.')
            return
        print('[2/5] Preparing isolated CS2 account changes...', flush=True)
        old = {p: p.read_bytes() for p in (AUTH, PASSWD, GROUP)}
        info = {p: p.stat() for p in old}
        raw = old[AUTH].decode('utf-8', 'surrogateescape')
        existing = effective(raw)
        generated = parse_passwd(old[PASSWD])
        targets = [LOGIN]
        if ALIAS in existing or ALIAS in generated:
            targets.append(ALIAS)
        text_new = source_for_accounts(raw, password, targets).encode('utf-8', 'surrogateescape')
        passwd_new = make_passwd(old[PASSWD], targets, password, owner.pw_uid, owner.pw_gid)
        group_new = make_group(old[GROUP], targets, owner.pw_gid)
        backup = Path('/root/hyper-cs2-ftp-v16-' + time.strftime('%Y%m%d-%H%M%S', time.gmtime()) + '-' + str(os.getpid()))
        backup.mkdir(mode=0o700)
        for path in old:
            shutil.copy2(path, backup / path.name)
        print('[3/5] Backup: ' + str(backup), flush=True)
        # Other generated users, their hashes, directory paths and text passwords
        # are not re-generated. Reject concurrent mutations before writing.
        if any(path.read_bytes() != content for path, content in old.items()):
            error('FTP files changed during staging; nothing applied')
        updates = {AUTH: text_new, PASSWD: passwd_new, GROUP: group_new}
        changed = []
        try:
            for path, data in updates.items():
                if data != old[path]:
                    atomic_write(path, data, info[path])
                    changed.append(path)
            print(f'[4/5] Applied {len(changed)} targeted FTP file changes, preserving other accounts.', flush=True)
            reload_active()
            if not check_login(password):
                error('FTP login still rejected. Changes will be rolled back. Check live ProFTPD AuthUserFile paths and server logs')
            print('[5/5] [OK] cs2_2 authenticated on FTP port 21; CS1.6 account records preserved.', flush=True)
        except Exception:
            for path in reversed(changed):
                atomic_write(path, old[path], info[path])
            reload_active()
            print('[ROLLBACK] Previous FTP authorization files restored.', flush=True)
            raise


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('[ERROR] ' + type(exc).__name__ + ': ' + str(exc), file=sys.stderr, flush=True)
        sys.exit(1)
PY
python3 -m py_compile "$WORK/repair.py"
python3 "$WORK/repair.py"
