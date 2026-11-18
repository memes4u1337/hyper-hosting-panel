#!/usr/bin/env bash
# HYPER-HOST CS1.6 V11: restore nested Python launcher chain safely.
# Optional separate stages: attach game #26 to existing SQL #25; activate installed YaPB.
# Usage: sudo bash HH_CS16_RECOVER_LAUNCHER_V11.sh check|repair|sql|bots|apply
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|repair|sql|bots|apply) ;; *) echo 'Usage: check | repair | sql | bots | apply' >&2; exit 2 ;; esac
if (( EUID != 0 )); then echo '[V11-ERROR] Run with sudo/root' >&2; exit 2; fi
say(){ printf '[V11] %s\n' "$*"; }
die(){ printf '[V11-ERROR] %s\n' "$*" >&2; exit 1; }

# Repair ONLY exact Python wrapper handoffs, preserving all other functions.
# This does not replace the runtime with the GitHub version, or alter CS1.6/SQL data.
launcher_stage(){
  python3 - "$1" <<'PY'
import ast, os, re, shutil, stat, subprocess, sys, tempfile, time
from pathlib import Path
mode=sys.argv[1]
live=Path(os.environ.get('HH_V11_LIVE','/usr/local/sbin/hyper-cs16-ctl'))
base=live.parent
backup_root=Path(os.environ.get('HH_V11_BACKUPS','/opt/hyper-cs16/backups'))
if not live.is_file() or live.is_symlink():
    raise SystemExit('[V11-ERROR] Runtime controller missing or a symlink: '+str(live))
if not live.name.startswith('hyper-cs16-ctl'):
    raise SystemExit('[V11-ERROR] Unexpected controller filename')
# Only the actual CLI and its strictly named .real layers; ignore all other files.
rx_name=re.compile(re.escape(live.name)+r'(?:\.real)*\Z')
paths=sorted((p for p in base.iterdir() if rx_name.fullmatch(p.name)), key=lambda p:(len(p.name),p.name))
if len(paths)>12: raise SystemExit('[V11-ERROR] Too many nested wrapper layers')
rx_exec=re.compile(r'os\s*\.\s*execv\s*\(\s*REAL\s*,\s*\[\s*REAL\s*\]\s*\+\s*sys\s*\.\s*argv\s*\[\s*1\s*:\s*\]\s*\)')
replacement='os.execv(sys.executable, [sys.executable, REAL] + sys.argv[1:])'
changes={}
for p in paths:
    if not p.is_file() or p.is_symlink(): raise SystemExit('[V11-ERROR] Unsafe symlink/non-file: '+str(p))
    raw=p.read_bytes()
    if len(raw)>5_000_000: raise SystemExit('[V11-ERROR] Unexpectedly large controller file: '+str(p))
    try: code=raw.decode('utf-8'); tree=ast.parse(code,filename=str(p))
    except (UnicodeDecodeError,SyntaxError):
        if p == live: raise SystemExit('[V11-ERROR] Runtime is not valid Python: '+str(p))
        continue  # A non-Python .real target: leave unchanged, and verify CLI help later.
    matched=list(rx_exec.finditer(code))
    if matched:
        new=rx_exec.sub(replacement,code)
        ast.parse(new,filename=str(p)); compile(new,str(p),'exec')
        if p == live and not code.startswith(b'#!/'.decode()):
            raise SystemExit('[V11-ERROR] Main controller lacks executable shebang')
        changes[p]=new.encode('utf-8')
        print('[V11] Python exec handoff fix needed:',p.name, '(matches='+str(len(matched))+')')
    elif replacement in code:
        print('[V11] Python exec handoff already fixed:',p.name)
    else:
        print('[V11] File left untouched:',p.name)
if not changes:
    print('[V11] No matching broken exec handoffs remain; checking the real CLI.')
try:
    existing=subprocess.run([str(live),'--help'],capture_output=True,text=True,timeout=18)
    working=existing.returncode == 0 and 'server-create' in existing.stdout and 'sql-status' in existing.stdout
except (OSError,subprocess.TimeoutExpired): working=False
if working:
    print('[V11] CLI --help already WORKS; no need to modify wrappers.')
    sys.exit(0)
if not changes:
    raise SystemExit('[V11-ERROR] CLI still broken but no recognized safe replacement. Stop: inspect actual wrapper chain.')
if mode=='check':
    print('[V11] CHECK PASSED: exact wrapper edits prepared; no files changed.')
    print('[V11] Run repair to back up and test the real installed CLI.')
    sys.exit(0)
backup_root.mkdir(parents=True, exist_ok=True)
snap=backup_root/('v11-launcher-'+time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid()))
snap.mkdir(mode=0o700)
for p in changes: shutil.copy2(p,snap/p.name)
print('[V11] Backed up changed wrappers:',str(snap))
completed=[]
try:
    for p, data in changes.items():
        fd,tmp=tempfile.mkstemp(prefix='.hh-v11-',dir=str(p.parent))
        try:
            with os.fdopen(fd,'wb') as f:
                f.write(data); f.flush(); os.fsync(f.fileno())
            st=p.stat()
            os.chown(tmp,st.st_uid,st.st_gid)
            os.chmod(tmp,stat.S_IMODE(st.st_mode))
            os.replace(tmp,p)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
        completed.append(p)
    r=subprocess.run([str(live),'--help'],capture_output=True,text=True,timeout=20)
    if r.returncode or 'server-create' not in r.stdout or 'sql-status' not in r.stdout:
        raise RuntimeError('CLI --help still does not show the expected CS1.6 commands; exit '+str(r.returncode)+'; stderr tail: '+r.stderr[-700:])
    print('[V11] REPAIR SUCCESS: real CLI --help works, existing controller functions preserved.')
except Exception as exc:
    for p in completed:
        shutil.copy2(snap/p.name,p)
    raise SystemExit('[V11-ERROR] CLI test failed; ALL modified wrappers restored. '+str(exc))
PY
}

sql_stage(){
  # Use only locally patched V4.1 source. Never recreate/copy/overwrite MySQL tables.
  local src=/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl
  local shared=/etc/hyper-cs16/shared-sql.json
  local s25=/var/lib/hyper-cs16/servers/25.json
  local s26=/var/lib/hyper-cs16/servers/26.json
  local root=/srv/hyper-cs16/servers/26
  for f in "$src" "$shared" "$s25" "$s26"; do [[ -f "$f" && ! -L "$f" ]] || die "Missing required SQL file: $f"; done
  [[ -d "$root" ]] || die 'Server #26 missing on disk'
  python3 - "$src" "$shared" "$s25" "$s26" "$root" <<'PY'
import ast,json,subprocess,sys,time,shutil
from pathlib import Path
src,shared,s25,s26,root=map(Path,sys.argv[1:])
src_code=src.read_text(); t=ast.parse(src_code)
fun={n.name:n for n in t.body if isinstance(n,ast.FunctionDef)}
for name in ('sql_provision','sql_status','server_delete'):
    if name not in fun: raise SystemExit('[V11-ERROR] Patched source function absent: '+name)
provider=ast.get_source_segment(src_code,fun['sql_provision']) or ''
if not any(x in provider for x in ('HH_SQL25_SHARED_V4_1','HH_SHARED_SQL_PATCH_2026_11')):
    raise SystemExit('[V11-ERROR] Source does not have verified shared SQL protection')
strings=' '.join(n.value.upper() for n in ast.walk(fun['sql_provision']) if isinstance(n,ast.Constant) and isinstance(n.value,str))
if any(k in strings for k in ('CREATE DATABASE','DROP DATABASE','CREATE USER','DROP USER','ALTER USER')):
    raise SystemExit('[V11-ERROR] Unsafe SQL creation/deletion in provider')
deleter=ast.get_source_segment(src_code,fun['server_delete']) or ''
if 'DROP DATABASE' in deleter or 'DROP USER' in deleter:
    raise SystemExit('[V11-ERROR] SQL deletion protection absent')
a=json.loads(s25.read_text()); b=json.loads(s26.read_text()); c=json.loads(shared.read_text())
if c.get('database')!='cs16_srv_25' or c.get('user')!='cs16_s25' or a.get('sql_db')!='cs16_srv_25':
    raise SystemExit('[V11-ERROR] Shared SQL config not verified')
if not c.get('password') or c.get('password')!=a.get('sql_password'):
    raise SystemExit('[V11-ERROR] SQL credentials mismatch')
if Path(str(b.get('path') or '')).resolve()!=root.resolve():
    raise SystemExit('[V11-ERROR] Server 26 path does not match its state')
try: import pymysql
except ImportError: raise SystemExit('[V11-ERROR] python3-pymysql is missing')
try:
    cn=pymysql.connect(host=c.get('host') or '127.0.0.1',port=int(c.get('port') or 3306),user=c['user'],password=c['password'],database=c['database'],connect_timeout=7)
    with cn.cursor() as cur:
        cur.execute('SHOW FULL TABLES'); count=len(cur.fetchall())
    cn.close()
except Exception as exc:
    raise SystemExit('[V11-ERROR] Could not verify SQL25 login: '+type(exc).__name__)
if count<1: raise SystemExit('[V11-ERROR] SQL25 has no tables')
print('[V11] Verified shared DB:',c['database'],'tables/views:',count)
print('[V11] Previous server #26 database:',b.get('sql_db'))
# Local backup before V4.1 SQL provisioning updates server state and AMXX sql.cfg.
snap=Path('/opt/hyper-cs16/backups')/('v11-sql26-'+time.strftime('%Y%m%d-%H%M%S'))
snap.mkdir(parents=True,mode=0o700,exist_ok=False)
shutil.copy2(s26,snap/'26.json')
for rel in ('cstrike/addons/amxmodx/configs/sql.cfg','cstrike/addons/amxmodx/configs/hyper_sql.cfg'):
    f=root/rel
    if f.is_file():
        out=snap/rel;out.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,out)
print('[V11] SQL file backup:',snap)
for action in ('sql-provision','sql-status'):
    try: r=subprocess.run([sys.executable,str(src),action,'26'],capture_output=True,text=True,timeout=90)
    except subprocess.TimeoutExpired: raise SystemExit('[V11-ERROR] '+action+' timed out')
    if r.returncode: raise SystemExit('[V11-ERROR] '+action+' returned nonzero (secret output suppressed)')
    try: d=json.loads(r.stdout.strip().splitlines()[-1])
    except Exception: raise SystemExit('[V11-ERROR] '+action+' returned invalid JSON (secret output suppressed)')
    if not d.get('ok') or d.get('database')!='cs16_srv_25':
        raise SystemExit('[V11-ERROR] '+action+' did not confirm cs16_srv_25')
    if action=='sql-status' and (not d.get('connected') or not d.get('tables')):
        raise SystemExit('[V11-ERROR] #26 cannot read tables from cs16_srv_25')
state=json.loads(s26.read_text())
if (state.get('sql_db'),state.get('sql_user'))!=('cs16_srv_25','cs16_s25'):
    raise SystemExit('[V11-ERROR] Server 26 state still points to the old database')
print('[V11] SQL #26 SUCCESS: cs16_srv_25 with existing tables; cs16_srv_26 NOT deleted.')
PY
}

bots_stage(){
  local helper=/usr/local/sbin/hh-cs16-bots-enable
  [[ -f "$helper" && ! -L "$helper" ]] || die 'Existing YaPB helper missing; no automatic download attempted'
  [[ -f /srv/hyper-cs16/servers/26/cstrike/addons/yapb/bin/yapb.so ]] || die 'YaPB binary missing'
  [[ -f /srv/hyper-cs16/servers/26/cstrike/addons/yapb/conf/yapb.cfg ]] || die 'YaPB config missing'
  [[ -f /srv/hyper-cs16/servers/26/cstrike/addons/metamod/plugins.ini ]] || die 'Metamod plugin list missing'
  say 'Activating existing YaPB on #26 (10 bots; difficulty 3; game will restart)'
  python3 "$helper" 26 --quota 10 --difficulty 3
  systemctl is-active --quiet hyper-cs16@26.service || die 'Game service #26 is not running after YaPB activation'
  say 'YaPB helper completed and service is active. Confirm bot population in game.'
}

case "$MODE" in
  check) launcher_stage check ;;
  repair) launcher_stage repair ;;
  sql) sql_stage ;;
  bots) bots_stage ;;
  apply)
    launcher_stage repair
    sql_stage
    bots_stage
    say 'APPLY finished. Run hyper-cs16-ctl --help and sql-status 26.'
    ;;
esac
