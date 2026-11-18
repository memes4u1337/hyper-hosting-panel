#!/usr/bin/env bash
# HYPER-HOST CS 1.6 V9 — point #26 to existing cs16_srv_25 and activate YaPB.
# Avoids overwriting /usr/local/sbin/hyper-cs16-ctl (preserves fastdl_clean, FTP, etc.).
# Usage: sudo bash HH_CS16_SQL25_YAPB_V9.sh check|apply
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
[[ "$MODE" == check || "$MODE" == apply ]] || { echo 'Usage: sudo bash HH_CS16_SQL25_YAPB_V9.sh check|apply' >&2; exit 2; }
(( EUID == 0 )) || { echo '[V9-ERROR] Run as root/sudo' >&2; exit 2; }
SRC=/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl
LIVE=/usr/local/sbin/hyper-cs16-ctl
STATE25=/var/lib/hyper-cs16/servers/25.json
STATE26=/var/lib/hyper-cs16/servers/26.json
SHARED=/etc/hyper-cs16/shared-sql.json
SAFE=/opt/hyper-cs16/v9-safe/hyper-cs16-ctl
BOTHELP=/usr/local/sbin/hh-cs16-bots-enable
ROOT=/srv/hyper-cs16/servers/26
BACKUPS=/opt/hyper-cs16/backups
log(){ printf '[V9] %s\n' "$*"; }
fail(){ printf '[V9-ERROR] %s\n' "$*" >&2; exit 1; }
for f in "$SRC" "$LIVE" "$STATE25" "$STATE26" "$SHARED"; do
    [[ -f "$f" && ! -L "$f" ]] || fail "Missing or symlinked file: $f"
done
[[ -d "$ROOT" ]] || fail "Game directory #26 not found: $ROOT"
command -v python3 >/dev/null || fail 'Python 3 missing'
command -v systemctl >/dev/null || fail 'systemctl missing'

# READ ONLY: validate controller, state, SQL source, and addon state before ANY writes.
python3 - "$SRC" "$LIVE" "$STATE25" "$STATE26" "$SHARED" "$ROOT" <<'PY'
from pathlib import Path
import ast,json,sys
src,live,s25,s26,shared,root=map(Path,sys.argv[1:])
for p in (src,live):
    raw=p.read_text(encoding='utf-8'); tree=ast.parse(raw,filename=str(p)); compile(tree,str(p),'exec')
raw=src.read_text(encoding='utf-8'); tree=ast.parse(raw)
f={n.name:n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
need={'sql_provision','sql_status','server_create','server_delete','load_server','save_server',
      '_write_amxx_sql_cfg','_sql_meta_update','require_root','main','install_yapb','configure_yapb'}
if need-set(f): raise SystemExit('[V9-ERROR] Source controller missing: '+', '.join(sorted(need-set(f))))
fn=ast.get_source_segment(raw,f['sql_provision']) or ''
if not any(x in fn for x in ('HH_SQL25_SHARED_V4_1','HH_SHARED_SQL_PATCH_2026_11')):
    raise SystemExit('[V9-ERROR] Source controller is NOT patched for shared SQL; refusing')
s=' '.join(n.value.upper() for n in ast.walk(f['sql_provision']) if isinstance(n,ast.Constant) and isinstance(n.value,str))
if any(x in s for x in ('CREATE DATABASE','DROP DATABASE','CREATE USER','DROP USER','ALTER USER')):
    raise SystemExit('[V9-ERROR] Source sql_provision could create/alter/drop SQL')
deleter=ast.get_source_segment(raw,f['server_delete']) or ''
if 'DROP DATABASE' in deleter or 'DROP USER' in deleter:
    raise SystemExit('[V9-ERROR] Source server_delete could delete SQL')
a=json.loads(s25.read_text()); b=json.loads(s26.read_text()); c=json.loads(shared.read_text())
if a.get('sql_db')!='cs16_srv_25' or c.get('database')!='cs16_srv_25':
    raise SystemExit('[V9-ERROR] Server 25/shared SQL must be cs16_srv_25')
if (a.get('sql_user'),a.get('sql_password'))!=(c.get('user'),c.get('password')):
    raise SystemExit('[V9-ERROR] Existing SQL passwords differ, refusing')
if not c.get('password') or c.get('user')!='cs16_s25':
    raise SystemExit('[V9-ERROR] Shared credentials invalid')
if str(c.get('host') or '127.0.0.1') not in ('localhost','127.0.0.1') or int(c.get('port') or 3306)!=3306:
    raise SystemExit('[V9-ERROR] Unsupported SQL hostname/port')
if Path(b.get('path','')).resolve()!=root.resolve():
    raise SystemExit('[V9-ERROR] #26 game path differs from expected, refusing')
if not (root/'cstrike/addons/metamod/plugins.ini').is_file():
    raise SystemExit('[V9-ERROR] #26 Metamod plugins.ini missing')
addon=root/'cstrike/addons/yapb'
if addon.is_dir() and (not (addon/'bin/yapb.so').is_file() or not (addon/'conf/yapb.cfg').is_file()):
    raise SystemExit('[V9-ERROR] Existing YaPB is incomplete: refuse destructive reinstall')
try: import pymysql
except ImportError: raise SystemExit('[V9-ERROR] apt install python3-pymysql')
con=pymysql.connect(host='127.0.0.1',port=3306,database=c['database'],user=c['user'],password=c['password'],connect_timeout=8)
try:
    with con.cursor() as cur:
        cur.execute('SHOW FULL TABLES'); n=len(cur.fetchall())
finally: con.close()
if n < 1: raise SystemExit('[V9-ERROR] Shared database is empty')
print(f'[V9] SQL source verified: cs16_srv_25, tables/views={n}')
print('[V9] Current #26 db:',b.get('sql_db','(unset)'))
print('[V9] YaPB installed:',addon.is_dir())
print('[V9] Live controller will NOT be replaced, extra helpers retained')
PY
if [[ "$MODE" == check ]]; then
    log 'CHECK PASSED; no files or databases changed.'
    log 'APPLY attaches #26, preserves live controller, activates YaPB, restarts #26.'
    exit 0
fi

mkdir -p "$BACKUPS"
SNAP="$BACKUPS/sql25-yapb-v9-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 "$SNAP"
cp -a "$LIVE" "$SNAP/runtime-controller.before"
cp -a "$STATE26" "$SNAP/26.json.before"
for rel in \
  cstrike/addons/amxmodx/configs/sql.cfg \
  cstrike/addons/amxmodx/configs/hyper_sql.cfg \
  cstrike/addons/amxmodx/configs/modules.ini \
  cstrike/addons/metamod/plugins.ini \
  cstrike/addons/yapb/conf/yapb.cfg; do
    if [[ -f "$ROOT/$rel" ]]; then mkdir -p "$SNAP/$(dirname "$rel")"; cp -a "$ROOT/$rel" "$SNAP/$rel"; fi
done
log "Backup saved: $SNAP"

# Keep a private, verified copy of the already-patched repository controller.
mkdir -p /opt/hyper-cs16/v9-safe
install -o root -g root -m 0700 "$SRC" "$SAFE"
python3 -m py_compile "$SAFE" || fail 'Safe controller compile failed'

# Create a small, independent bots-enable implementation that relies on the
# already-vetted controller for installation and panel mode metadata.
cat > "$BOTHELP" <<'PY'
#!/usr/bin/env python3
import argparse,json,os,re,shutil,subprocess,sys,time
from pathlib import Path
SAFE='/opt/hyper-cs16/v9-safe/hyper-cs16-ctl'
p=argparse.ArgumentParser(prog='hyper-cs16-ctl bots-enable')
p.add_argument('id',type=int)
p.add_argument('--quota',type=int,default=10)
p.add_argument('--difficulty',type=int,default=3)
a=p.parse_args()
if os.geteuid()!=0: p.error('root required')
if not (1<=a.id<=65535) or not (0<=a.quota<=31) or not (0<=a.difficulty<=4): p.error('invalid id/quota/difficulty')
statefile=Path(f'/var/lib/hyper-cs16/servers/{a.id}.json')
if not statefile.is_file(): p.error('game server not found')
c=json.loads(statefile.read_text())
root=Path(c.get('path','')).resolve()
expected=Path(f'/srv/hyper-cs16/servers/{a.id}').resolve()
if root!=expected or not root.is_dir(): p.error('unsafe game server path')
plugins=root/'cstrike/addons/metamod/plugins.ini'
addon=root/'cstrike/addons/yapb'
lib=addon/'bin/yapb.so'
cfg=addon/'conf/yapb.cfg'
if not plugins.is_file(): p.error('Metamod plugins.ini not found')
def call_ctl(*args):
    cp=subprocess.run([SAFE,*map(str,args)],capture_output=True,text=True,timeout=240)
    if cp.returncode:
        raise RuntimeError('controller '+str(args[0])+' failed: '+(cp.stderr or cp.stdout)[-1000:])
    try: result=json.loads(cp.stdout.strip().splitlines()[-1]); assert result.get('ok')
    except Exception: raise RuntimeError('controller '+str(args[0])+' returned unexpected result')
    return result
if not addon.exists():
    print('[BOTS] Installing YaPB for #'+str(a.id),flush=True)
    call_ctl('bots-install',a.id,'--quota',a.quota,'--difficulty',a.difficulty)
if not lib.is_file() or not cfg.is_file():
    raise SystemExit('[BOTS-ERROR] YaPB incomplete; no existing add-on was overwritten')
# Ensure exactly one active YaPB Metamod entry, preserving other plugins.
old=plugins.read_text(encoding='utf-8',errors='replace')
lines=[]; seen=False
for line in old.splitlines():
    if 'addons/yapb/bin/yapb.so' in line.lower():
        if not seen: lines.append('linux addons/yapb/bin/yapb.so'); seen=True
        else: lines.append(line if line.lstrip().startswith(';') else ';'+line)
    else: lines.append(line)
if not seen: lines.append('linux addons/yapb/bin/yapb.so')
new='\n'.join(lines).rstrip()+'\n'
if new!=old:
    shutil.copy2(plugins,plugins.with_name(plugins.name+'.before-hh-v9-'+str(int(time.time()))))
    plugins.write_text(new,encoding='utf-8')
def setcvar(path,key,val):
    t=path.read_text(encoding='utf-8',errors='replace')
    pat=re.compile(r'^\s*'+re.escape(key)+r'\s+[^\r\n]*$',re.M|re.I)
    line=f'{key} {val}'
    t=pat.sub(line,t,count=1) if pat.search(t) else t.rstrip()+'\n'+line+'\n'
    path.write_text(t,encoding='utf-8')
for k,v in {'yb_quota':a.quota,'yb_quota_mode':'fill','yb_difficulty':a.difficulty,
            'yb_join_after_player':0,'yb_autovacate':1}.items(): setcvar(cfg,k,v)
# Synchronize panel mode/flags with the controller. Existing file remains intact.
call_ctl('bots-config',a.id,'--quota',a.quota,'--difficulty',a.difficulty)
# bots-config may rewrite config. Restore join behavior so bots spawn without humans.
setcvar(cfg,'yb_join_after_player',0)
unit=f'hyper-cs16@{a.id}.service'
cp=subprocess.run(['systemctl','restart',unit],capture_output=True,text=True,timeout=90)
if cp.returncode: raise RuntimeError('Game restart failed: '+cp.stderr[-800:])
cp=subprocess.run(['systemctl','is-active','--quiet',unit],timeout=15)
if cp.returncode: raise RuntimeError('Game service is not active after restart')
print(json.dumps({'ok':True,'id':a.id,'bots_enabled':True,'quota':a.quota,'difficulty':a.difficulty,
  'metamod_enabled':True,'service':'active','note':'Bot join count must be checked in game or A2S'},ensure_ascii=False))
PY
chmod 0700 "$BOTHELP"
python3 -m py_compile "$BOTHELP" || fail 'Bots helper compile failed'

# Inject an early dispatch near the start of LIVE controller. Does not remove or
# overwrite a single existing function (including fastdl_clean).
python3 - "$LIVE" <<'PY'
import ast,os,stat,sys,tempfile
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text(encoding='utf-8')
original_ast=ast.parse(s); original_functions={n.name for n in original_ast.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
marker='# HH_V9_SAFE_DISPATCH_2026_11'
if marker not in s:
    tree=ast.parse(s)
    idx=0
    for node in tree.body:
        if isinstance(node,ast.Expr) and isinstance(node.value,(ast.Str,ast.Constant)) and isinstance(getattr(node.value,'value',None),str):
            idx=max(idx,node.end_lineno);continue
        if isinstance(node,ast.ImportFrom) and node.module=='__future__':
            idx=max(idx,node.end_lineno);continue
        break
    block='''# HH_V9_SAFE_DISPATCH_2026_11
if __name__ == '__main__':
    import sys as _hh_v9_sys, os as _hh_v9_os
    if len(_hh_v9_sys.argv) > 1:
        _hh_v9_cmd = _hh_v9_sys.argv[1]
        if _hh_v9_cmd == 'bots-enable':
            _hh_v9_os.execv('/usr/local/sbin/hh-cs16-bots-enable',
                             ['/usr/local/sbin/hh-cs16-bots-enable']+_hh_v9_sys.argv[2:])
        if _hh_v9_cmd in ('sql-provision','sql-status','sql-table','server-create','delete'):
            _hh_v9_os.execv('/opt/hyper-cs16/v9-safe/hyper-cs16-ctl',
                             ['/opt/hyper-cs16/v9-safe/hyper-cs16-ctl']+_hh_v9_sys.argv[1:])
# HH_V9_SAFE_DISPATCH_END
'''
    lines=s.splitlines(keepends=True)
    result=''.join(lines[:idx])+block+''.join(lines[idx:])
else: result=s
after_ast=ast.parse(result);compile(result,str(p),'exec')
after_functions={n.name for n in after_ast.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
if original_functions!=after_functions:
    raise SystemExit('[V9-ERROR] Runtime functions changed unexpectedly; abort')
fd,tmp=tempfile.mkstemp(prefix='.hh-v9-',dir=p.parent)
st=p.stat()
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        f.write(result);f.flush();os.fsync(f.fileno())
    os.chown(tmp,st.st_uid,st.st_gid);os.chmod(tmp,stat.S_IMODE(st.st_mode));os.replace(tmp,p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print('[V9] Runtime dispatcher installed without replacing any functions')
PY
python3 -m py_compile "$LIVE"
"$LIVE" bots-enable --help >/dev/null || fail "bots-enable command dispatch did not register"
log "bots-enable CLI dispatch self-test passed"

# Use verified existing shared SQL provisioning; capture JSON to avoid printing SQL password.
python3 - "$SAFE" "$STATE26" <<'PY'
import subprocess,sys,json,pathlib
safe,state=sys.argv[1:]
for action in ('sql-provision','sql-status'):
    cp=subprocess.run([safe,action,'26'],capture_output=True,text=True,timeout=120)
    if cp.returncode: raise SystemExit('[V9-ERROR] '+action+' failed: '+(cp.stderr or '')[-900:])
    try: res=json.loads(cp.stdout.strip().splitlines()[-1])
    except Exception: raise SystemExit('[V9-ERROR] '+action+' returned non-JSON response')
    if not res.get('ok') or res.get('database')!='cs16_srv_25':
        raise SystemExit('[V9-ERROR] '+action+' returned wrong SQL database')
    if action=='sql-status':
        n=len(res.get('tables') or [])
        if not res.get('connected') or n<1: raise SystemExit('[V9-ERROR] SQL #26 has no access to shared tables')
        print('[V9] CS1.6 #26 SQL VERIFIED: '+res['database']+', tables/views='+str(n))
c=json.loads(pathlib.Path(state).read_text())
if c.get('sql_db')!='cs16_srv_25' or c.get('sql_user')!='cs16_s25':
    raise SystemExit('[V9-ERROR] Server #26 state was not updated')
print('[V9] SQL state for #26 points to cs16_srv_25; old cs16_srv_26 database retained')
PY

log 'Enabling YaPB (#26, quota 10, difficulty 3); game service will restart.'
"$BOTHELP" 26 --quota 10 --difficulty 3
log 'COMPLETE. Refresh panel SQL page; #26 must show cs16_srv_25. Check actual bot count via game console.'
log "Backup: $SNAP"
