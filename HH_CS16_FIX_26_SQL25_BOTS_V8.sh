#!/usr/bin/env bash
# HYPER-HOST V8: attach existing CS1.6 #26 to SQL of #25, enable YaPB safely.
# Usage: sudo bash HH_CS16_FIX_26_SQL25_BOTS_V8.sh check|apply
# Never copies/removes/creates MySQL databases. Never deletes cs16_srv_26.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
[[ "$MODE" == check || "$MODE" == apply ]] || { echo 'Usage: sudo bash HH_CS16_FIX_26_SQL25_BOTS_V8.sh check|apply' >&2; exit 2; }
(( EUID == 0 )) || { echo '[V8-ERROR] Run with sudo/root' >&2; exit 2; }
SRC=/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl
LIVE=/usr/local/sbin/hyper-cs16-ctl
SERVER_STATE=/var/lib/hyper-cs16/servers/26.json
SOURCE_STATE=/var/lib/hyper-cs16/servers/25.json
SHARED=/etc/hyper-cs16/shared-sql.json
BACKUP_DIR=/opt/hyper-cs16/backups
log(){ printf '[V8] %s\n' "$*"; }
fail(){ printf '[V8-ERROR] %s\n' "$*" >&2; exit 1; }
for f in "$SRC" "$LIVE" "$SERVER_STATE" "$SOURCE_STATE" "$SHARED"; do
    [[ -f "$f" && ! -L "$f" ]] || fail "Missing or symlinked required file: $f"
done
command -v python3 >/dev/null || fail 'python3 is missing'
command -v systemctl >/dev/null || fail 'systemctl is missing'
WORK="$(mktemp -d /tmp/hh-v8.XXXXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

# A copy of V6 stored inside this one-file installer; no remote patch dependency.
cat > "$WORK/enable-bots.sh" <<'EMBEDDED_BOTS_V6'
#!/usr/bin/env bash
# HYPER-HOST CS 1.6 YaPB enable CLI compatibility patch.
# Usage: sudo bash HH_CS16_BOTS_ENABLE_V6.sh check|apply
set -Eeuo pipefail
MODE="${1:-check}"
if [[ "$MODE" != "check" && "$MODE" != "apply" ]]; then
  echo 'Usage: sudo bash HH_CS16_BOTS_ENABLE_V6.sh check|apply' >&2
  exit 2
fi
if [[ "$EUID" -ne 0 ]]; then
  echo '[BOTS-V6] Run with sudo/root' >&2
  exit 1
fi
python3 - "$MODE" <<'PY'
import ast
import os
import re
import sys
import time
import stat
import shutil
import tempfile
from pathlib import Path

mode = sys.argv[1]
paths = [Path('/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl'), Path('/usr/local/sbin/hyper-cs16-ctl')]
backup_dir = Path('/opt/hyper-cs16/backups') / ('bots-v6-' + time.strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()))

BOT_FUNCTION = '''
def enable_yapb(sid:int, quota=None, difficulty=None):
    """Enable an ALREADY installed YaPB without replacing downloaded or game files."""
    require_root()
    c = load_server(sid)
    path = Path(c['path'])
    cstrike = path / 'cstrike'
    yapb_lib = cstrike / 'addons/yapb/bin/yapb.so'
    ycfg = cstrike / 'addons/yapb/conf/yapb.cfg'
    plugin_ini = cstrike / 'addons/metamod/plugins.ini'
    if not yapb_lib.is_file() or not ycfg.is_file():
        raise RuntimeError('YaPB is not installed on this server. Use bots-install first.')
    if not plugin_ini.is_file():
        raise RuntimeError('Metamod plugins.ini is missing; cannot safely enable YaPB')
    quota = max(0, min(31, int(c.get('bots_quota', 9) if quota is None else quota)))
    difficulty = max(0, min(4, int(c.get('bots_difficulty', 3) if difficulty is None else difficulty)))
    old_lines = plugin_ini.read_text(encoding='utf-8', errors='replace').splitlines()
    new_lines = []
    found = False
    for line in old_lines:
        if 'addons/yapb/bin/yapb.so' in line.lower():
            if not found:
                new_lines.append('linux addons/yapb/bin/yapb.so')
                found = True
            else:
                new_lines.append(line if line.lstrip().startswith(';') else ';' + line)
        else:
            new_lines.append(line)
    if not found:
        new_lines.append('linux addons/yapb/bin/yapb.so')
    new_ini = '\\n'.join(new_lines).rstrip() + '\\n'
    # Preserve a recoverable local copy of the Metamod list before changing it.
    if new_ini != plugin_ini.read_text(encoding='utf-8', errors='replace'):
        backup_ini = plugin_ini.with_name(plugin_ini.name + '.before-bots-v6-' + str(int(time.time())))
        shutil.copy2(plugin_ini, backup_ini)
        plugin_ini.write_text(new_ini, encoding='utf-8')
    _set_cfg_cvar(ycfg, 'yb_quota', str(quota))
    _set_cfg_cvar(ycfg, 'yb_quota_mode', 'fill')
    _set_cfg_cvar(ycfg, 'yb_difficulty', str(difficulty))
    normalize_permissions(path)
    c['bots_enabled'] = 1
    c['bots_quota'] = quota
    c['bots_difficulty'] = difficulty
    save_server(c)
    db_update_mode(sid, str(c.get('game_mode', 'classic')), 1, quota, difficulty)
    was_active = service_status(sid) == 'active'
    restarted = service_action(sid, 'restart') if was_active else {'ok': True, 'skipped': 'Server stopped; takes effect on next start'}
    return {'ok': bool(restarted.get('ok', False)), 'id': sid, 'bots': 'YaPB', 'bots_enabled': True,
            'quota': quota, 'difficulty': difficulty, 'restart': restarted,
            'warning': restarted.get('warning', '')}
'''
# String has literal escaped newlines above; correct source inserted requires one escaped newline sequence inside quoted Python source.
BOT_FUNCTION = BOT_FUNCTION.replace("new_ini = '\\\\n'", "new_ini = '\\n'")

parser_pattern = re.compile(r"\bsp\.add_parser\(\s*['\"]bots-enable['\"]\s*\)")
dispatch_pattern = re.compile(r"elif\s+args\.cmd\s*==\s*['\"]bots-enable['\"]")
required = {'main','require_root','load_server','save_server','service_status','service_action',
            'db_update_mode','_set_cfg_cvar','normalize_permissions','install_yapb','configure_yapb','disable_yapb'}

def modify(original, p):
    tree = ast.parse(original, filename=str(p))
    names = {x.name for x in tree.body if isinstance(x, (ast.FunctionDef,ast.AsyncFunctionDef))}
    missing = sorted(required - names)
    if missing:
        raise RuntimeError(f'{p} missing required functions: {", ".join(missing)}; stopped to avoid overwriting existing code')
    output = original
    if 'enable_yapb' not in names:
        m = re.search(r'^def main\(\):', output, re.M)
        if not m:
            raise RuntimeError(f'{p}: main() anchor missing')
        output = output[:m.start()] + BOT_FUNCTION.rstrip() + '\n\n' + output[m.start():]
    if not parser_pattern.search(output):
        lines=output.splitlines(keepends=True)
        indices=[i for i, l in enumerate(lines) if re.search(r"sp\.add_parser\(\s*['\"]bots-disable['\"]\s*\)", l)]
        if len(indices)!=1:
            raise RuntimeError(f'{p}: bots-disable parser anchor not unique')
        i=indices[0]
        indent = re.match(r'\s*', lines[i]).group(0)
        lines.insert(i, indent + "q=sp.add_parser('bots-enable'); q.add_argument('id',type=int); q.add_argument('--quota',type=int); q.add_argument('--difficulty',type=int)\n")
        output=''.join(lines)
    if not dispatch_pattern.search(output):
        lines=output.splitlines(keepends=True)
        indices=[i for i,l in enumerate(lines) if re.search(r"elif\s+args\.cmd\s*==\s*['\"]bots-disable['\"]", l)]
        if len(indices)!=1:
            raise RuntimeError(f'{p}: bots-disable dispatch anchor not unique')
        i=indices[0]
        indent=re.match(r'\s*', lines[i]).group(0)
        lines.insert(i, indent + "elif args.cmd=='bots-enable': result=enable_yapb(args.id,args.quota,args.difficulty)\n")
        output=''.join(lines)
    tree=ast.parse(output,filename=str(p))
    compile(tree,str(p),'exec')
    if not parser_pattern.search(output) or not dispatch_pattern.search(output):
        raise RuntimeError(f'{p}: failed to insert command handlers')
    if 'enable_yapb' not in {n.name for n in tree.body if isinstance(n,ast.FunctionDef)}:
        raise RuntimeError(f'{p}: enable_yapb function missing after patch')
    return output

try:
    originals=[]
    builds=[]
    for path in paths:
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f'Controller not found or symlink: {path}')
        raw=path.read_bytes()
        orig=raw.decode('utf-8')
        new=modify(orig, path)
        originals.append(raw)
        builds.append(new.encode('utf-8'))
        print(f'[BOTS-V6] {path}: syntax OK; changes={raw!=builds[-1]}')
    if mode=='check':
        print('[BOTS-V6] CHECK PASSED: no files changed')
        sys.exit(0)
    backup_dir.mkdir(parents=True,exist_ok=False)
    backed=[]
    changed=[]
    try:
        for i, p in enumerate(paths):
            backup=backup_dir/('controller-'+str(i)+'.bak')
            shutil.copy2(p,backup)
            backed.append((p,backup))
        print(f'[BOTS-V6] Backup: {backup_dir}')
        for i,p in enumerate(paths):
            if builds[i] == originals[i]:
                continue
            s=p.stat()
            fd,tmp = tempfile.mkstemp(prefix='.bots-v6-',dir=str(p.parent))
            try:
                with os.fdopen(fd,'wb') as out:
                    out.write(builds[i]); out.flush(); os.fsync(out.fileno())
                os.chmod(tmp,stat.S_IMODE(s.st_mode))
                os.chown(tmp,s.st_uid,s.st_gid)
                os.replace(tmp,p)
                changed.append(p)
            finally:
                if os.path.exists(tmp): os.unlink(tmp)
        for p in paths:
            ast.parse(p.read_text(encoding='utf-8'),filename=str(p))
        print('[BOTS-V6] APPLY PASSED. Command bots-enable now exists; no game files were modified.')
    except Exception:
        for p,backup in reversed(backed):
            if p in changed:
                shutil.copy2(backup,p)
        raise
except Exception as exc:
    print('[BOTS-V6 ERROR] '+str(exc),file=sys.stderr)
    sys.exit(1)
PY

EMBEDDED_BOTS_V6
chmod 0700 "$WORK/enable-bots.sh"

# READ-ONLY validation of database, state and controller versions. No passwords printed.
python3 - "$SRC" "$LIVE" "$SOURCE_STATE" "$SERVER_STATE" "$SHARED" "$WORK/preflight.json" <<'PY'
import ast,sys,json,pathlib,re
src,live,state25,state26,shared,out=map(pathlib.Path,sys.argv[1:])
a=json.loads(state25.read_text(encoding='utf-8'))
b=json.loads(state26.read_text(encoding='utf-8'))
c=json.loads(shared.read_text(encoding='utf-8'))
if a.get('sql_db')!='cs16_srv_25' or c.get('database')!='cs16_srv_25':
    raise SystemExit('[V8-ERROR] Server 25/shared config is not cs16_srv_25; no changes made')
if (a.get('sql_user'),a.get('sql_password'))!=(c.get('user'),c.get('password')):
    raise SystemExit('[V8-ERROR] Source SQL credentials mismatch; no changes made')
if not c.get('password') or c.get('user')!='cs16_s25':
    raise SystemExit('[V8-ERROR] Unexpected shared SQL user; no changes made')
root=pathlib.Path(b.get('path',''))
if root.resolve()!=pathlib.Path('/srv/hyper-cs16/servers/26').resolve() or not root.is_dir():
    raise SystemExit('[V8-ERROR] Server #26 path is missing or unexpected; no changes made')
if not (root/'cstrike/addons/metamod/plugins.ini').is_file():
    raise SystemExit('[V8-ERROR] #26 metamod/plugins.ini is missing; no changes made')
yapb=root/'cstrike/addons/yapb'
if yapb.exists() and not (yapb/'bin/yapb.so').is_file():
    raise SystemExit('[V8-ERROR] Existing YaPB directory lacks bin/yapb.so; refusing to overwrite its custom contents')
if yapb.exists() and not (yapb/'conf/yapb.cfg').is_file():
    raise SystemExit('[V8-ERROR] Existing YaPB config missing; refusing to overwrite custom contents')
try: import pymysql
except ImportError: raise SystemExit('[V8-ERROR] python3-pymysql not installed')
con=pymysql.connect(host='127.0.0.1',port=3306,user=c['user'],password=c['password'],database='cs16_srv_25',connect_timeout=8)
with con.cursor() as cur:
    cur.execute('SELECT DATABASE()')
    assert cur.fetchone()[0]=='cs16_srv_25'
    cur.execute('SHOW FULL TABLES')
    tables=len(cur.fetchall())
con.close()
if tables<1: raise SystemExit('[V8-ERROR] Source SQL has no tables, aborting')
def funcs(path):
    source=path.read_text(encoding='utf-8');tree=ast.parse(source,filename=str(path));compile(tree,str(path),'exec')
    return source,{n.name:n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
s, sf=funcs(src); l, lf=funcs(live)
needed={'main','sql_provision','sql_status','server_create','server_delete','load_server','save_server',
       '_write_amxx_sql_cfg','_sql_meta_update','require_root','configure_yapb','install_yapb',
       'disable_yapb','service_action','service_status','normalize_permissions','_set_cfg_cvar','db_update_mode'}
if needed-set(sf): raise SystemExit('[V8-ERROR] Repository controller incomplete: '+', '.join(sorted(needed-set(sf))))
f=ast.get_source_segment(s,sf['sql_provision']) or ''
if not any(m in f for m in ('HH_SQL25_SHARED_V4_1','HH_SHARED_SQL_PATCH_2026_11')):
    raise SystemExit('[V8-ERROR] Repo controller has no shared-SQL V4 marker; refusing to run sql-provision')
strings=' '.join(n.value.upper() for n in ast.walk(sf['sql_provision']) if isinstance(n,ast.Constant) and isinstance(n.value,str))
if any(x in strings for x in ('CREATE DATABASE','DROP DATABASE','CREATE USER','DROP USER','ALTER USER')):
    raise SystemExit('[V8-ERROR] Unsafe SQL DDL in provisioner; no changes made')
delete=ast.get_source_segment(s,sf['server_delete']) or ''
if 'DROP DATABASE' in delete or 'DROP USER' in delete: raise SystemExit('[V8-ERROR] Shared SQL deletion not protected')
extra=set(lf)-set(sf)
if extra: raise SystemExit('[V8-ERROR] Runtime has independent functions not in repo: '+', '.join(sorted(extra))+'; refuse to replace code')
need_sync = bool(needed-set(lf))
if not need_sync:
    live_fn=ast.get_source_segment(l,lf['sql_provision']) or ''
    need_sync=not any(m in live_fn for m in ('HH_SQL25_SHARED_V4_1','HH_SHARED_SQL_PATCH_2026_11'))
if c.get('host','127.0.0.1') not in ('127.0.0.1','localhost') or int(c.get('port',3306))!=3306:
    raise SystemExit('[V8-ERROR] Unexpected shared SQL host/port')
out.write_text(json.dumps({'sync':need_sync,'tables':tables,'yapb_installed':yapb.exists()}),encoding='utf-8')
out.chmod(0o600)
print('[V8] SOURCE cs16_srv_25 connected, tables/views:',tables)
print('[V8] Server #26 current SQL:',b.get('sql_db','(none)'))
print('[V8] Runtime controller repair required:',need_sync)
print('[V8] YaPB installed in server #26:',yapb.exists())
print('[V8] No SQL database will be created, imported or dropped')
PY

if [[ "$MODE" == check ]]; then
    log 'CHECK PASSED: all preflight checks succeeded. No files changed.'
    log 'APPLY will back up #26 configuration, attach to cs16_srv_25, and enable YaPB.'
    exit 0
fi

mkdir -p "$BACKUP_DIR"
SNAP="$BACKUP_DIR/sql25-yapb-v8-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 "$SNAP"
cp -a "$SRC" "$SNAP/source.ctl.bak"
cp -a "$LIVE" "$SNAP/runtime.ctl.bak"
cp -a "$SERVER_STATE" "$SNAP/26.json.bak"
ROOT=/srv/hyper-cs16/servers/26
for rel in \
    cstrike/addons/amxmodx/configs/sql.cfg \
    cstrike/addons/amxmodx/configs/hyper_sql.cfg \
    cstrike/addons/metamod/plugins.ini \
    cstrike/addons/yapb/conf/yapb.cfg; do
    if [[ -f "$ROOT/$rel" ]]; then
        mkdir -p "$SNAP/$(dirname "$rel")"
        cp -a "$ROOT/$rel" "$SNAP/$rel"
    fi
done
log "Backups saved: $SNAP"

# Synchronize only if installed command is incomplete and source was verified.
if python3 - "$WORK/preflight.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));sys.exit(0 if x['sync'] else 1)
PY
then
    log 'Recovering incomplete runtime CLI from the locally verified source'
    python3 - "$SRC" "$LIVE" <<'PY'
import os,sys,stat,tempfile,pathlib
src,dst=map(pathlib.Path,sys.argv[1:]);p=dst.stat()
fd,tmp=tempfile.mkstemp(prefix='.hh-v8-',dir=str(dst.parent))
try:
    with os.fdopen(fd,'wb') as f:
        f.write(src.read_bytes());f.flush();os.fsync(f.fileno())
    os.chmod(tmp,stat.S_IMODE(p.st_mode));os.chown(tmp,p.st_uid,p.st_gid);os.replace(tmp,dst)
finally:
    if os.path.exists(tmp):os.unlink(tmp)
PY
fi

# Add a real bots-enable CLI command to both control copies, including reactivation in Metamod.
if ! bash "$WORK/enable-bots.sh" check; then
    log 'Bots CLI preflight failed. Restoring both controllers.'
    cp -a "$SNAP/source.ctl.bak" "$SRC"
    cp -a "$SNAP/runtime.ctl.bak" "$LIVE"
    exit 1
fi
if ! bash "$WORK/enable-bots.sh" apply; then
    log 'Bots CLI patch failed. Restoring both controllers.'
    cp -a "$SNAP/source.ctl.bak" "$SRC"
    cp -a "$SNAP/runtime.ctl.bak" "$LIVE"
    exit 1
fi
python3 -m py_compile "$SRC" "$LIVE"
"$LIVE" bots-enable --help >/dev/null
log 'bots-enable command installed and verified'

# SQL provisioning has been verified to use only the existing cs16_srv_25.
python3 - "$LIVE" <<'PY'
import subprocess,sys,json,pathlib
ctl=sys.argv[1]
for args in (['sql-provision','26'],['sql-status','26']):
    cp=subprocess.run([ctl]+args,capture_output=True,text=True,timeout=120)
    if cp.returncode:
        raise SystemExit('[V8-ERROR] '+args[0]+' failed (passwords hidden); consult controller logs')
    try: data=json.loads(cp.stdout.strip().splitlines()[-1])
    except Exception: raise SystemExit('[V8-ERROR] '+args[0]+' did not return valid JSON')
    if not data.get('ok') or data.get('database')!='cs16_srv_25':
        raise SystemExit('[V8-ERROR] '+args[0]+' returned unexpected database')
    if args[0]=='sql-status':
        if not data.get('connected') or len(data.get('tables',[]))<1:
            raise SystemExit('[V8-ERROR] #26 cannot read cs16_srv_25')
        print('[V8] Server #26 SQL CONNECTED:',data['database'],'tables/views:',len(data['tables']))
state=json.loads(pathlib.Path('/var/lib/hyper-cs16/servers/26.json').read_text())
if state.get('sql_db')!='cs16_srv_25' or state.get('sql_user')!='cs16_s25':
    raise SystemExit('[V8-ERROR] State file for #26 did not retain shared SQL')
print('[V8] #26 state and SQL metadata updated. Old cs16_srv_26 DB kept untouched.')
PY

# Install YaPB only if the directory is completely absent. Existing custom addons are never overwritten.
if [[ ! -d "$ROOT/cstrike/addons/yapb" ]]; then
    log 'YaPB absent; running original controller bots-install for #26 (downloads official build)'
    "$LIVE" bots-install 26 --quota 10 --difficulty 3 || fail 'YaPB download/install failed; SQL attachment remains successful'
fi
[[ -f "$ROOT/cstrike/addons/yapb/bin/yapb.so" ]] || fail 'YaPB .so absent after install'
[[ -f "$ROOT/cstrike/addons/yapb/conf/yapb.cfg" ]] || fail 'YaPB config absent after install'
log 'Enabling YaPB with 10 bots, difficulty 3 and reactivating Metamod plugin'
"$LIVE" bots-enable 26 --quota 10 --difficulty 3 || fail 'YaPB activation failed; SQL attachment remains successful'
if ! systemctl is-active --quiet hyper-cs16@26.service; then
    log 'CS1.6 #26 is not running, starting game service'
    "$LIVE" start 26 || fail 'Game server did not start after enabling bots'
fi
systemctl is-active --quiet hyper-cs16@26.service || fail 'Game service #26 is not active'
python3 - "$ROOT" <<'PY'
import pathlib,sys,re
root=pathlib.Path(sys.argv[1]);plugins=(root/'cstrike/addons/metamod/plugins.ini').read_text(errors='replace')
active=[x.strip() for x in plugins.splitlines() if re.search(r'addons/yapb/bin/yapb\.so',x,re.I) and not x.lstrip().startswith(';')]
if len(active)!=1: raise SystemExit('[V8-ERROR] YaPB Metamod entry not uniquely active')
cfg=(root/'cstrike/addons/yapb/conf/yapb.cfg').read_text(errors='replace')
if not re.search(r'(?m)^\s*yb_quota\s+10(?:\s|$)',cfg): raise SystemExit('[V8-ERROR] YaPB quota is not 10')
print('[V8] YaPB Metamod entry active; quota=10; game service active')
PY
log 'COMPLETE: server #26 connected to cs16_srv_25 and YaPB enabled (quota 10).'
log 'Panel: reload SQL page. If it still shows cs16_srv_26, the PHP listing is using stale/other metadata.'
log 'Verify actual bots through A2S or game console; running service does not guarantee bots joined the game.'
