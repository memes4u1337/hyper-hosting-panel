#!/usr/bin/env bash
# Safe pre-migration for legacy HYPER-HOST FTP auth text.
# Does not touch SQLite, game SQL, FTP users' home dirs, or running services.
# It retains exactly the credentials that the installed ProFTPD generator currently uses.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply) ;; *) printf 'Usage: sudo bash %s check|apply\n' "$0" >&2; exit 2;; esac
if (( EUID != 0 )); then echo '[FTP-PREP-ERROR] Run as root via sudo.' >&2; exit 2; fi
AUTH=/opt/hyper-host/data/vsftpd_virtual_users.txt
SYNC=/opt/hyper-host/bin/proftpd_auth_sync.py
[[ -f "$AUTH" && ! -L "$AUTH" ]] || { echo '[FTP-PREP-ERROR] Auth file missing or symlink; stopped.' >&2; exit 2; }
[[ -f "$SYNC" ]] || { echo '[FTP-PREP-ERROR] Installed ProFTPD generator missing; stopped.' >&2; exit 2; }
python3 - "$MODE" "$AUTH" "$SYNC" <<'PY'
import importlib.util
import os
import re
import shutil
import stat
import sys
import tempfile
import time
from pathlib import Path

mode, filename, module_file = sys.argv[1:]
path = Path(filename)
source = Path(module_file)

spec = importlib.util.spec_from_file_location('hyper_proftpd_read_only', source)
if spec is None or spec.loader is None:
    raise SystemExit('[FTP-PREP-ERROR] Cannot inspect installed generator')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
if not callable(getattr(module, 'normalize_pairs', None)):
    raise SystemExit('[FTP-PREP-ERROR] Generator has no expected normalize_pairs(); stopped')

original = path.read_bytes()
try:
    raw = original.decode('utf-8', 'surrogateescape')
except UnicodeError:
    raise SystemExit('[FTP-PREP-ERROR] Unknown text encoding; stopped')

legacy = '\\n' in raw and raw.count('\n') <= 1
normalized = raw.replace('\\r\\n', '\n').replace('\\n', '\n') if legacy else raw
lines = normalized.splitlines()
if len(lines) % 2:
    raise SystemExit('[FTP-PREP-ERROR] Odd number of lines; stopped without changes')

pattern = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_-]{1,63}$')
seen = {}
kept = []
blanks = 0
dups = 0
conflicts = 0
for index in range(0, len(lines), 2):
    name = lines[index].strip()
    password = lines[index + 1]
    if not name and not password:
        blanks += 1
        continue
    if not pattern.fullmatch(name) or not password:
        raise SystemExit(f'[FTP-PREP-ERROR] Invalid non-empty record at pair {index // 2}; no changes')
    if name in seen:
        dups += 1
        if seen[name] != password:
            conflicts += 1
        continue
    seen[name] = password
    kept.append((name, password))

# Critical invariant: byte-for-byte equal username-password tuples to the
# active ProFTPD generator's *effective* records (its first valid occurrence).
actual = module.normalize_pairs(raw)
if kept != actual:
    raise SystemExit('[FTP-PREP-ERROR] Active generator selection differs; stopped without changes')

rendered = ''.join(name + '\n' + password + '\n' for name, password in kept)
if module.normalize_pairs(rendered) != actual:
    raise SystemExit('[FTP-PREP-ERROR] Normalization would change effective credentials; stopped')
new_bytes = rendered.encode('utf-8', 'surrogateescape')
print('[FTP-PREP] Legacy escaped newlines:', legacy)
print('[FTP-PREP] Original pairs:', len(lines)//2)
print('[FTP-PREP] Empty pairs:', blanks)
print('[FTP-PREP] Duplicate pairs:', dups)
print('[FTP-PREP] Conflicting duplicate passwords:', conflicts)
print('[FTP-PREP] Effective accounts kept:', len(kept))
print('[FTP-PREP] Identical effective credentials according to installed generator: YES')

if mode == 'check':
    print('[FTP-PREP] CHECK PASSED: no files changed')
    raise SystemExit(0)

# Write only if the source has not changed since preflight, and keep a private backup.
backup_root = Path('/opt/hyper-host/backups')
backup_dir = backup_root / ('ftp-auth-prep-' + time.strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()))
backup_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
os.chmod(backup_dir, 0o700)
backup = backup_dir / 'vsftpd_virtual_users.txt'
shutil.copy2(path, backup)
os.chmod(backup, 0o600)
if backup.read_bytes() != original or path.read_bytes() != original:
    raise SystemExit('[FTP-PREP-ERROR] Auth file changed before write; backup saved; stopped')

info = path.stat()
fd, temp = tempfile.mkstemp(prefix='.ftp-auth-prep-', dir=str(path.parent))
try:
    with os.fdopen(fd, 'wb') as writer:
        writer.write(new_bytes)
        writer.flush()
        os.fsync(writer.fileno())
    os.chown(temp, info.st_uid, info.st_gid)
    os.chmod(temp, stat.S_IMODE(info.st_mode))
    if path.read_bytes() != original:
        raise SystemExit('[FTP-PREP-ERROR] Auth file changed concurrently; stopped')
    os.replace(temp, path)
    dir_fd = os.open(str(path.parent), os.O_RDONLY)
    try: os.fsync(dir_fd)
    finally: os.close(dir_fd)
finally:
    if os.path.exists(temp): os.unlink(temp)
if module.normalize_pairs(path.read_text(encoding='utf-8', errors='surrogateescape')) != actual:
    # We do not attempt an unsafe automatic rollback of potentially concurrent writes.
    raise SystemExit('[FTP-PREP-ERROR] Postwrite mismatch: restore private backup before FTP restart!')
print('[FTP-PREP] APPLY PASSED: normalized auth file, no effective password changed')
print('[FTP-PREP] Private backup:', backup)
print('[FTP-PREP] Next run V3.3 check/apply; no service was restarted here')
PY
