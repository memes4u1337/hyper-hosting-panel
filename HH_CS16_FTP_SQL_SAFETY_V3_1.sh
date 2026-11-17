#!/usr/bin/env bash
# HYPER-HOST CS 1.6 V3.1 (recovers mismatched deployed controller).
# Purge only obsolete CS2 virtual FTP accounts; rebuild FTP for CS1.6;
# preserve game SQL databases on server deletion; make doctor work offline.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
[[ "$MODE" == check || "$MODE" == apply ]] || { echo 'Usage: sudo bash HH_CS16_FTP_SQL_SAFETY_V3_1.sh [check|apply]' >&2; exit 2; }
[[ $(id -u) == 0 ]] || { echo 'Root privileges required' >&2; exit 2; }
REPO="${HYPER_REPO_DIR:-/root/hyper-hosting-panel}"
SRC="$REPO/cs16-panel/bin/hyper-cs16-ctl"
CTL=/usr/local/sbin/hyper-cs16-ctl
HHCTL=/usr/local/sbin/hyper-host-ctl
STATE=/var/lib/hyper-cs16/servers
SHARED=/etc/hyper-cs16/shared-sql.json
SQLITE=/opt/hyper-host/data/hyperhost.sqlite
AUTH=/opt/hyper-host/data/vsftpd_virtual_users.txt
USERCONF=/opt/hyper-host/ftp/user_conf
PROFPASS=/opt/hyper-host/proftpd/ftpd.passwd
PROFGROUP=/opt/hyper-host/proftpd/ftpd.group
BACKUP="/opt/hyper-cs16/backups/v31-ftp-sql-$(date +%Y%m%d_%H%M%S)-$$"
for f in "$SRC" "$CTL" "$HHCTL" "$SHARED" "$STATE/26.json" "$SQLITE"; do
    [[ -f "$f" ]] || { echo "[V3.1-ERROR] Missing required file: $f" >&2; exit 2; }
done
command -v python3 >/dev/null || exit 2
command -v systemctl >/dev/null || exit 2
WORK=$(mktemp -d /tmp/hh-v3.XXXXXX)
trap 'rm -rf -- "$WORK"' EXIT

# Validate both copies, and if one lost the V2 patch, use the other as the source
# of truth. CHECK writes nothing to the system; APPLY backs up both copies first.
python3 - "$SRC" "$CTL" "$WORK/source.py" "$WORK/live.py" "$SHARED" <<'INNER_PY'
from pathlib import Path
import sys, ast, json
source, live, outsrc, outlive, shared = map(Path, sys.argv[1:])
d = json.loads(shared.read_text())
if not all(d.get(k) for k in ('database', 'user', 'password')):
    raise SystemExit('[V3.1-ERROR] Shared SQL credentials are incomplete; refusing to proceed')
source_text = source.read_text(encoding='utf-8')
live_text = live.read_text(encoding='utf-8')
v2_marker = 'HH_SHARED_SQL_PATCH_2026_11'
if v2_marker in source_text:
    canonical, origin = source_text, 'repository source'
elif v2_marker in live_text:
    canonical, origin = live_text, 'installed controller'
else:
    raise SystemExit('[V3.1-ERROR] V2 marker missing from BOTH source and live controller. Stopping safely.')
if v2_marker not in source_text or v2_marker not in live_text:
    print('[V3.1] One controller lost V2; recovery source:', origin)
    print('[V3.1] After backup, APPLY will synchronize both controller files; CHECK will not change them.')

def transform(s):
    if 'def server_delete(' not in s or 'def doctor():' not in s:
        raise SystemExit('[V3.1-ERROR] Unexpected controller functions; not safe to modify')
    ast.parse(s)
    if 'HH_V3_PRESERVE_GAME_SQL_2026_11' not in s:
        a = s.find("    sql_cleanup_warning=''", s.index('def server_delete('))
        b = s.find("    return {'ok':True,'id':sid", a)
        if a < 0 or b < 0 or b <= a:
            raise SystemExit('[V3.1-ERROR] SQL deletion block changed; unsafe to rewrite')
        section = s[a:b]
        if 'DROP DATABASE IF EXISTS' not in section or 'DROP USER IF EXISTS' not in section:
            raise SystemExit('[V3.1-ERROR] Expected DROP statements not found; refusing to rewrite')
        s = s[:a] + (
            '    # HH_V3_PRESERVE_GAME_SQL_2026_11\n'
            '    # Always preserve game SQL on server deletion.\n'
            "    sql_cleanup_warning='Game SQL retained; automatic DROP disabled'\n"
        ) + s[b:]
    if 'HH_V3_OFFLINE_DOCTOR_2026_11' not in s:
        a = s.find('    for name,cmd in {', s.index('def doctor():'))
        b = s.find("    checks['base_game']=", a)
        if a < 0 or b < 0 or b <= a:
            raise SystemExit('[V3.1-ERROR] doctor checks changed; unsafe to rewrite')
        if "'steamcmd':" not in s[a:b]:
            raise SystemExit('[V3.1-ERROR] Original SteamCMD test not found')
        s = s[:a] + (
            '    # HH_V3_OFFLINE_DOCTOR_2026_11\n'
            '    # Check local binary, never run online steamcmd +quit during doctor.\n'
            "    steamcmd=Path(str(rt.get('steamcmd','/opt/steamcmd/steamcmd.sh')))\n"
            "    checks['steamcmd']={'ok':steamcmd.is_file() and os.access(steamcmd,os.X_OK),\n"
            "                        'path':str(steamcmd), 'output':'Binary checked; online SteamCMD execution was not tested'}\n"
            "    for name,cmd in {'nginx':['nginx','-t'], 'mariadb':['systemctl','is-active','mariadb'], 'ftp':['ss','-ltn','sport = :21']}.items():\n"
            '        try:\n'
            "            cp=run(cmd,check=False,timeout=15); checks[name]={'ok':cp.returncode==0,'output':(cp.stdout or '').strip()[-500:]}\n"
            '        except Exception as exc:\n'
            "            checks[name]={'ok':False,'output':f'{type(exc).__name__}: {str(exc)[:300]}'}\n"
        ) + s[b:]
    ast.parse(s)
    for marker in (v2_marker, 'HH_V3_PRESERVE_GAME_SQL_2026_11', 'HH_V3_OFFLINE_DOCTOR_2026_11'):
        if marker not in s:
            raise SystemExit('[V3.1-ERROR] Post-patch verification failed for '+marker)
    return s

# Preserve each controller's existing differences when it already has V2.
# Recover only the missing-V2 copy from the known patched canonical variant.
patched_src = transform(source_text if v2_marker in source_text else canonical)
patched_live = transform(live_text if v2_marker in live_text else canonical)
outsrc.write_text(patched_src, encoding='utf-8')
outlive.write_text(patched_live, encoding='utf-8')
print('[V3.1] Both controllers prepared and parsed. No files changed yet.')
INNER_PY
python3 -m py_compile "$WORK/source.py" "$WORK/live.py"

# Inspect exact account names only. Never print passwords or user data.
python3 - "$SQLITE" "$AUTH" <<'PY'
from pathlib import Path
import sys,sqlite3,re
names=set(); r=re.compile(r'(?:hhftp_)?cs2_\d+$',re.I)
try:
    db=sqlite3.connect(f'file:{sys.argv[1]}?mode=ro',uri=True)
    if db.execute("select count(*) from sqlite_master where type='table' and name='ftp_accounts'").fetchone()[0]:
        names.update(v[0] for v in db.execute('select username from ftp_accounts') if v[0] and r.fullmatch(v[0]))
    db.close()
except sqlite3.Error as e: raise SystemExit('Cannot inspect FTP SQLite database: '+str(e))
p=Path(sys.argv[2]); lines=p.read_text(errors='replace').splitlines() if p.exists() else []
if len(lines) % 2:
    raise SystemExit('[V3.1-ERROR] FTP auth text has unpaired lines; refusing to modify auth data')
names.update(lines[i].strip() for i in range(0,len(lines)-1,2) if r.fullmatch(lines[i].strip()))
print('[V3.1] Obsolete dedicated CS2 FTP accounts:',', '.join(sorted(names)) or 'none')
PY
if [[ $MODE == check ]]; then
    echo '[V3.1] CHECK PASSED: no changes made.'
    echo '[V3.1] To apply: sudo bash HH_CS16_FTP_SQL_SAFETY_V3_1.sh apply'
    exit 0
fi
mkdir -p "$BACKUP"
cp -a "$SRC" "$BACKUP/source-controller"
cp -a "$CTL" "$BACKUP/live-controller"
cp -a "$SHARED" "$BACKUP/shared-sql.json"
[[ -f "$AUTH" ]] && cp -a "$AUTH" "$BACKUP/ftp-auth.txt" || true
[[ -d "$USERCONF" ]] && cp -a "$USERCONF" "$BACKUP/user_conf" || true
[[ -f "$PROFPASS" ]] && cp -a "$PROFPASS" "$BACKUP/ftpd.passwd" || true
[[ -f "$PROFGROUP" ]] && cp -a "$PROFGROUP" "$BACKUP/ftpd.group" || true
python3 - "$SQLITE" "$BACKUP/main-panel.sqlite" <<'PY'
import sqlite3,sys
src=sqlite3.connect(f'file:{sys.argv[1]}?mode=ro',uri=True)
dst=sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()
print('[V3.1] SQLite backup verified')
PY
printf '[V3.1] Backup: %s\n' "$BACKUP"

# Install controller safety first, preserving existing ownership/mode.
python3 - "$SRC" "$CTL" "$WORK/source.py" "$WORK/live.py" <<'PY'
import sys,os,shutil,tempfile,pathlib
for destination,source in [(pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[3])),(pathlib.Path(sys.argv[2]),pathlib.Path(sys.argv[4]))]:
    st=destination.stat(); fd,tmp=tempfile.mkstemp(dir=destination.parent,prefix='.hh-v3-')
    try:
        with os.fdopen(fd,'wb') as f: f.write(source.read_bytes()); f.flush(); os.fsync(f.fileno())
        os.chown(tmp,st.st_uid,st.st_gid); os.chmod(tmp,st.st_mode & 0o7777)
        os.replace(tmp,destination)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
print('[V3.1] SQL deletion safety and offline doctor applied to repo+runtime')
PY

# Remove stale CS2 accounts *only*. Do not remove site FTP, CS1.6 FTP, or CS2 game data.
python3 - "$SQLITE" "$AUTH" "$USERCONF" <<'PY'
from pathlib import Path
import sqlite3,sys,re,os,tempfile
sql,auth,conf=Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]); re_cs2=re.compile(r'(?:hhftp_)?cs2_\d+$',re.I)
db=sqlite3.connect(sql)
try:
    if db.execute("select count(*) from sqlite_master where type='table' and name='ftp_accounts'").fetchone()[0]:
        usernames=[v[0] for v in db.execute('select username from ftp_accounts') if v[0] and re_cs2.fullmatch(v[0])]
        with db:
            db.executemany('delete from ftp_accounts where username=?',[(u,) for u in usernames])
        print('[V3.1] Stale CS2 accounts deleted from SQLite:',len(usernames))
finally: db.close()
if auth.exists():
    lines=auth.read_text(encoding='utf-8',errors='surrogateescape').splitlines()
    if len(lines)%2: raise SystemExit('FTP auth has uneven user/password lines; refusing to edit')
    out=[]; removed=0
    for i in range(0,len(lines),2):
        if re_cs2.fullmatch(lines[i].strip()): removed+=1
        else: out.extend(lines[i:i+2])
    if removed:
        st=auth.stat(); fd,tmp=tempfile.mkstemp(dir=auth.parent,prefix='.hh-v3-')
        try:
            with os.fdopen(fd,'w',encoding='utf-8',errors='surrogateescape') as f: f.write('\n'.join(out)+'\n' if out else ''); f.flush(); os.fsync(f.fileno())
            os.chown(tmp,st.st_uid,st.st_gid); os.chmod(tmp,st.st_mode & 0o7777)
            os.replace(tmp,auth)
        finally:
            try: os.unlink(tmp)
            except FileNotFoundError: pass
    print('[V3.1] Stale CS2 entries removed from FTP auth:',removed)
if conf.is_dir():
    count=0
    for p in conf.iterdir():
        if re_cs2.fullmatch(p.name) and (p.is_file() or p.is_symlink()): p.unlink(); count+=1
    print('[V3.1] Stale CS2 FTP home configurations removed:',count)
PY

# Explicitly rebuild generated ProFTPD user hashes after removing stale accounts.
echo '[V3.1] Rebuilding ProFTPD configuration and virtual users...'
if ! "$HHCTL" ftp-fix; then
    echo '[V3.1-WARN] Global FTP rebuild returned an error. See ProFTPD journal; controller safety patch remains installed.' >&2
fi
sleep 1
for SID in 25 26; do
    echo "[V3.1] Checking CS1.6 #$SID FTP..."
    [[ -f "$STATE/$SID.json" ]] || { echo "[V3.1-WARN] No server $SID configuration" >&2; continue; }
    if RESULT=$("$CTL" ftp-repair "$SID" 2>&1); then
        printf '%s' "$RESULT" | python3 -c 'import json,sys; x=json.load(sys.stdin); print("[V3.1] FTP", x.get("ftp_user","?"), "OK" if x.get("ok") else "FAILED", "root:",x.get("root",""))'
    else
        printf '%s' "$RESULT" | python3 -c 'import json,sys; raw=sys.stdin.read();
try:
 d=json.loads(raw); print("[V3.1-WARN] FTP", d.get("ftp_user","?"),d.get("test",{}).get("error") or d.get("error") or "failed", "warning:",str(d.get("warning") or "")[:300])
except Exception: print("[V3.1-WARN] FTP repair failed; inspect proftpd logs; raw output hidden to protect credentials")' >&2
    fi
done
printf '\n[V3.1] FTP status (no credentials):\n'
for SID in 25 26; do
    [[ -f "$STATE/$SID.json" ]] || continue
    "$CTL" ftp-test "$SID" 2>/dev/null | python3 -c 'import json,sys; v=json.load(sys.stdin); print("ftp-test:", "OK" if v.get("ok") else "ERROR", v.get("error", ""))' || true
done
printf '\n[V3.1] Running doctor (SteamCMD binary only):\n'
"$CTL" doctor || true
printf '\n[V3.1] Done. Backup: %s\n' "$BACKUP"
echo '[V3.1] If ftp-test for #26 still fails, send `sudo journalctl -u hyper-host-proftpd-lan -n 50 --no-pager` and the failure code (not passwords).'
