#!/usr/bin/env bash
# HYPER-HOST CS 1.6 recovery after V9: fix Python wrapper exec format,
# attach server 26 to existing SQL 25, activate already-installed YaPB.
# Modes: check | repair | sql | bots | apply
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|repair|sql|bots|apply) ;; *) echo 'Usage: sudo bash HH_CS16_RECOVER_V10.sh check|repair|sql|bots|apply' >&2; exit 2;; esac
((EUID == 0)) || { echo '[V10-ERROR] Run as root (sudo)' >&2; exit 2; }
LIVE=/usr/local/sbin/hyper-cs16-ctl
SRC=/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl
SHARED=/etc/hyper-cs16/shared-sql.json
S25=/var/lib/hyper-cs16/servers/25.json
S26=/var/lib/hyper-cs16/servers/26.json
GAME=/srv/hyper-cs16/servers/26
BOTHELP=/usr/local/sbin/hh-cs16-bots-enable
BACKUP_ROOT=/opt/hyper-cs16/backups
log(){ printf '[V10] %s\n' "$*"; }
fail(){ printf '[V10-ERROR] %s\n' "$*" >&2; exit 1; }
for p in "$LIVE" "$SRC" "$SHARED" "$S25" "$S26"; do [[ -f "$p" && ! -L "$p" ]] || fail "Required file absent or symlinked: $p"; done
[[ -d "$GAME" && ! -L "$GAME" ]] || fail "Server #26 directory missing: $GAME"
[[ -f "$BOTHELP" && ! -L "$BOTHELP" ]] || fail "V9 YaPB helper missing: $BOTHELP; no bots files will be downloaded"
command -v python3 >/dev/null || fail 'Python 3 is missing'
command -v systemctl >/dev/null || fail 'systemctl is missing'

# Generate candidate in /usr/local/sbin, the SAME directory as the live wrapper.
# Do not touch the live filename or replace any controller functions in preflight.
STAGED="$(mktemp /usr/local/sbin/.hh-cs16-v10-stage.XXXXXXXX)"
trap 'rm -f -- "$STAGED"' EXIT
python3 - "$LIVE" "$STAGED" "$SRC" "$SHARED" "$S25" "$S26" "$GAME" "$BOTHELP" <<'PY'
import ast,json,os,re,stat,subprocess,sys
from pathlib import Path
live,staged,source,shared,p25,p26,game,bothelp=map(Path,sys.argv[1:])
ls=live.read_text(encoding='utf-8')
ss=source.read_text(encoding='utf-8')
for name,body in (('live',ls),('source',ss)):
    try: ast.parse(body);compile(body,str(live if name=='live' else source),'exec')
    except Exception as e: raise SystemExit('[V10-ERROR] '+name+' Python code invalid: '+str(e))
if not ls.startswith('#!') or 'python' not in ls.splitlines()[0].lower():
    raise SystemExit('[V10-ERROR] Runtime wrapper has no Python shebang; manual inspection required')
# Match only the exact failing line reported by the server. Preserve all other code.
pattern=r'(?m)^(?P<ws>[ \t]*)os\.execv\(REAL,\s*\[REAL\]\s*\+\s*sys\.argv\[1:\]\)\s*$'
fixed='os.execv(sys.executable, [sys.executable, REAL] + sys.argv[1:])'
match=list(re.finditer(pattern,ls))
if len(match)==1:
    candidate=re.sub(pattern,lambda m:m.group('ws')+fixed,ls,count=1)
    action='repair Python wrapper REAL execv'
elif not match and fixed in ls:
    candidate=ls
    action='wrapper already repaired'
else:
    raise SystemExit('[V10-ERROR] Expected wrapper execv(REAL, ...) not found exactly once. No changes made.')
ast.parse(candidate);compile(candidate,str(staged),'exec')
staged.write_text(candidate,encoding='utf-8')
st=os.stat(live);os.chmod(staged,stat.S_IMODE(st.st_mode) | stat.S_IXUSR)
# A real CLI help test with zero modifications to deployed runtime.
try:
    r=subprocess.run([str(staged),'--help'],capture_output=True,text=True,timeout=20)
except Exception as e:
    raise SystemExit('[V10-ERROR] Staged wrapper help test failed: '+type(e).__name__+': '+str(e))
if r.returncode!=0 or 'sql-status' not in (r.stdout+r.stderr) or 'bots-config' not in (r.stdout+r.stderr):
    raise SystemExit('[V10-ERROR] Staged wrapper does not run real CS 1.6 CLI; refusing live replacement. Error: '+(r.stderr or '')[:250])
# Verify independent source supports shared SQL, never the public GitHub default CREATE DATABASE code.
t=ast.parse(ss)
f={n.name:n for n in t.body if isinstance(n,ast.FunctionDef)}
required={'sql_provision','sql_status','server_delete','load_server','save_server','_write_amxx_sql_cfg','_sql_meta_update','main'}
missing=required-set(f)
if missing: raise SystemExit('[V10-ERROR] Local SQL source incomplete: '+', '.join(sorted(missing)))
provision=ast.get_source_segment(ss,f['sql_provision']) or ''
if 'HH_SQL25_SHARED_V4_1' not in provision and 'HH_SHARED_SQL_PATCH_2026_11' not in provision:
    raise SystemExit('[V10-ERROR] Local source is not the verified shared-SQL V4.1; refusing SQL changes')
strings=' '.join(n.value.upper() for n in ast.walk(f['sql_provision']) if isinstance(n,ast.Constant) and isinstance(n.value,str))
if any(keyword in strings for keyword in ('CREATE DATABASE','DROP DATABASE','CREATE USER','DROP USER','ALTER USER')):
    raise SystemExit('[V10-ERROR] SQL provider contains database/user DDL. No changes made.')
deleter=ast.get_source_segment(ss,f['server_delete']) or ''
if 'DROP DATABASE' in deleter or 'DROP USER' in deleter:
    raise SystemExit('[V10-ERROR] Shared SQL deletion protection absent. No changes made.')
a=json.loads(p25.read_text()); b=json.loads(p26.read_text()); c=json.loads(shared.read_text())
if a.get('sql_db')!='cs16_srv_25' or c.get('database')!='cs16_srv_25' or c.get('user')!='cs16_s25':
    raise SystemExit('[V10-ERROR] Database #25 or shared credentials do not match cs16_srv_25')
if not c.get('password') or (a.get('sql_user'),a.get('sql_password'))!=(c['user'],c['password']):
    raise SystemExit('[V10-ERROR] Shared credentials disagree with server 25; refusing')
if Path(str(b.get('path') or '')).resolve()!=game.resolve():
    raise SystemExit('[V10-ERROR] Server 26 game directory does not match state; refusing')
try:
    import pymysql
    cn=pymysql.connect(host='127.0.0.1',port=3306,user=c['user'],password=c['password'],database=c['database'],connect_timeout=8)
    with cn.cursor() as cur:
        cur.execute('SHOW TABLES'); count=len(cur.fetchall())
    cn.close()
except Exception as e:
    raise SystemExit('[V10-ERROR] Shared MySQL login verification failed: '+type(e).__name__)
if count<1: raise SystemExit('[V10-ERROR] Source game database has no tables')
metamod=game/'cstrike/addons/metamod/plugins.ini'
lib=game/'cstrike/addons/yapb/bin/yapb.so'
cfg=game/'cstrike/addons/yapb/conf/yapb.cfg'
if not all(p.is_file() for p in (metamod,lib,cfg)):
    raise SystemExit('[V10-ERROR] YaPB files are incomplete; refusing to reinstall or overwrite them')
# --help on helper: safe, no game changes.
r=subprocess.run([sys.executable,str(bothelp),'--help'],capture_output=True,text=True,timeout=15)
if r.returncode!=0: raise SystemExit('[V10-ERROR] Existing YaPB helper failed CLI help check')
print('[V10] Runtime preflight:',action,'; staged --help OK')
print('[V10] SQL source: cs16_srv_25, tables/views:',count,'; server #26 currently:',b.get('sql_db'))
print('[V10] YaPB installation: complete; existing helper --help OK')
print('[V10] All preflight checks passed; no DB writes or game changes.')
PY

if [[ "$MODE" == check ]]; then
  log 'CHECK PASSED. No deployed files changed.'
  exit 0
fi

# A dedicated backup for this run. Contains PRIVATE server state/config with SQL passwords.
mkdir -p -- "$BACKUP_ROOT"
SNAP="$BACKUP_ROOT/v10-recover-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 "$SNAP"
cp -a -- "$LIVE" "$SNAP/controller.before"
cp -a -- "$S26" "$SNAP/26.json.before"
for rel in cstrike/addons/amxmodx/configs/sql.cfg cstrike/addons/metamod/plugins.ini cstrike/addons/yapb/conf/yapb.cfg; do
  if [[ -f "$GAME/$rel" ]]; then
    mkdir -p -- "$SNAP/$(dirname "$rel")"
    cp -a -- "$GAME/$rel" "$SNAP/$rel"
  fi
done
log "Private backup: $SNAP"

if [[ "$MODE" == repair || "$MODE" == apply ]]; then
  # Only the wrapper's os.execv line changes; every existing function remains intact.
  LIVE_STAGED="$(mktemp /usr/local/sbin/.hh-cs16-v10-install.XXXXXXXX)"
  install -o root -g root -m 0755 "$STAGED" "$LIVE_STAGED"
  mv -f -- "$LIVE_STAGED" "$LIVE"
  if ! "$LIVE" --help >/dev/null 2>&1; then
    cp -a -- "$SNAP/controller.before" "$LIVE"
    fail 'Installed CLI test failed; previous wrapper automatically restored.'
  fi
  log 'Controller works again. No functions replaced (including fastdl_clean).'
fi
if [[ "$MODE" == repair ]]; then
  log 'REPAIR COMPLETE. Database and bots were not changed.'
  exit 0
fi

if [[ "$MODE" == sql || "$MODE" == apply ]]; then
  # V4.1 patched local SOURCE, executed explicitly with Python. Suppress command
  # stdout because sql-provision returns the SQL password in its JSON response.
  python3 - "$SRC" "$S26" <<'PY'
import json,subprocess,sys
from pathlib import Path
src,state=sys.argv[1:]
for command in ('sql-provision','sql-status'):
    try: cp=subprocess.run([sys.executable,src,command,'26'],capture_output=True,text=True,timeout=90)
    except subprocess.TimeoutExpired: raise SystemExit('[V10-ERROR] '+command+' timed out')
    if cp.returncode:
        raise SystemExit('[V10-ERROR] '+command+' failed (exit '+str(cp.returncode)+'). Output hidden to protect credentials.')
    try: r=json.loads(cp.stdout.strip().splitlines()[-1])
    except Exception: raise SystemExit('[V10-ERROR] '+command+' returned invalid JSON (hidden).')
    if not r.get('ok') or r.get('database')!='cs16_srv_25':
        raise SystemExit('[V10-ERROR] '+command+' did not confirm source database cs16_srv_25')
    if command=='sql-status':
        tables=r.get('tables') or []
        if not r.get('connected') or not tables:
            raise SystemExit('[V10-ERROR] #26 did not connect to SQL source or see its tables')
        print('[V10] #26 SQL VERIFIED: cs16_srv_25, tables='+str(len(tables)))
s=json.loads(Path(state).read_text())
if (s.get('sql_db'),s.get('sql_user'))!=('cs16_srv_25','cs16_s25'):
    raise SystemExit('[V10-ERROR] Server 26 state still points to incorrect SQL')
print('[V10] #26 state updated; previous cs16_srv_26 database not deleted.')
PY
fi
if [[ "$MODE" == bots || "$MODE" == apply ]]; then
  log 'Activating installed YaPB: server 26, 10 bots, difficulty 3. Game will restart.'
  python3 "$BOTHELP" 26 --quota 10 --difficulty 3
  systemctl is-active --quiet hyper-cs16@26.service || fail 'Game service #26 is not active after YaPB activation'
  log 'YaPB helper completed; service is active. Verify real bot count in-game.'
fi
log 'COMPLETE. The old cs16_srv_26 MySQL database has NOT been deleted.'
