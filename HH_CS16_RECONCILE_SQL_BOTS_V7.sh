#!/usr/bin/env bash
# HYPER-HOST CS 1.6 -- reconcile diverged controller and apply V5(SQL admins)+V6(YaPB).
# Usage: sudo bash HH_CS16_RECONCILE_SQL_BOTS_V7.sh check|apply
# Only game-controller files are changed; no games, SQL data, FTP files or Nginx files are modified.
set -Eeuo pipefail
umask 077

MODE="${1:-check}"
[[ "$MODE" == "check" || "$MODE" == "apply" ]] || { echo '[V7-ERROR] Usage: sudo bash HH_CS16_RECONCILE_SQL_BOTS_V7.sh check|apply' >&2; exit 2; }
(( EUID == 0 )) || { echo '[V7-ERROR] Run as root with sudo' >&2; exit 2; }

SRC="${HH_CS16_SRC:-/root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl}"
LIVE="${HH_CS16_LIVE:-/usr/local/sbin/hyper-cs16-ctl}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
V5="${HH_V5_SCRIPT:-$SCRIPT_DIR/HH_CS16_SQL_ADMINS_V5.sh}"
V6="${HH_V6_SCRIPT:-$SCRIPT_DIR/HH_CS16_BOTS_ENABLE_V6.sh}"
BACKUP_ROOT="${HH_CS16_BACKUP_ROOT:-/opt/hyper-cs16/backups}"

log(){ printf '[V7] %s\n' "$*"; }
fail(){ printf '[V7-ERROR] %s\n' "$*" >&2; exit 1; }

for p in "$SRC" "$LIVE" "$V5" "$V6"; do
  [[ -f "$p" && ! -L "$p" ]] || fail "Missing regular file (or unexpected symlink): $p"
done
[[ "$SRC" != "$LIVE" ]] || fail 'Repository and runtime controllers must be separate files'
bash -n "$V5" "$V6" || fail 'Existing V5/V6 shell script syntax is invalid'

# Read-only AST inspection. Never restore a runtime from unverified/truncated source.
python3 - "$SRC" "$LIVE" <<'PY'
import ast, sys
from pathlib import Path
src, live = map(Path, sys.argv[1:])
source, runtime = (p.read_text(encoding='utf-8') for p in (src, live))
def funcs(code, label):
    t = ast.parse(code, filename=label)
    compile(t, label, 'exec')
    return {n.name:n for n in t.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
sf=funcs(source,str(src)); lf=funcs(runtime,str(live))
need={'main','require_root','load_server','save_server','sql_provision','server_create','server_delete',
      '_write_amxx_sql_cfg','_sql_meta_update','_reload_amxx_admins','sql_status',
      'normalize_permissions','service_status','service_action',
      'db_update_mode','_set_cfg_cvar','install_yapb','configure_yapb','disable_yapb'}
missing=sorted(need - sf.keys())
if missing:
    raise SystemExit('[V7-ERROR] Repository controller incomplete: '+', '.join(missing))
provision=ast.get_source_segment(source,sf['sql_provision']) or ''
if not any(k in provision for k in ('HH_SQL25_SHARED_V4_1','HH_SHARED_SQL_PATCH_2026_11')):
    raise SystemExit('[V7-ERROR] Repository controller lacks V4.1 shared-SQL marker. Do not replace runtime.')
forbidden=('CREATE DATABASE','DROP DATABASE','DROP USER','ALTER USER')
# Check executable literals, not comments.
strings=' '.join(n.value.upper() for n in ast.walk(sf['sql_provision'])
                 if isinstance(n,ast.Constant) and isinstance(n.value,str))
if any(k in strings for k in forbidden):
    raise SystemExit('[V7-ERROR] Repository SQL provisioning contains database/user DDL; refusing')
deleter=ast.get_source_segment(source,sf['server_delete']) or ''
if 'DROP DATABASE' in deleter or 'DROP USER' in deleter:
    raise SystemExit('[V7-ERROR] Repository controller does not protect SQL from server deletion')
# Refuse to drop any independently-added live functions by a full-file restore.
extra=sorted(set(lf)-set(sf))
if extra and (len(lf)>8 or len(runtime)>10000):
    raise SystemExit('[V7-ERROR] Runtime has substantial custom functions absent from repository: '+', '.join(extra)+
                     '. Manual merge required; no files modified')
if extra:
    print('[V7] Small runtime shim with additional helper(s): '+', '.join(extra))
    print('[V7] It will be backed up before replacing with verified full controller')
print('[V7] Repository controller verified: shared SQL, SQL-delete protection, admin and YaPB dependencies')
print('[V7] Repository functions:',len(sf),' runtime functions:',len(lf))
print('[V7] Runtime missing:',', '.join(sorted(need-lf.keys())) or 'none')
print('[V7] Source/runtime identical:',source==runtime)
PY

if [[ "$MODE" == check ]]; then
  log 'CHECK PASSED. No files modified. APPLY will back up both controllers and run V5 then V6.'
  log 'If runtime was replaced by a minimal wrapper, APPLY restores it from the verified repository copy.'
  log 'SQL game data, FTP files, Nginx config and game files will remain unchanged.'
  exit 0
fi

mkdir -p -- "$BACKUP_ROOT"
BACKUP="$BACKUP_ROOT/reconcile-v7-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 -- "$BACKUP"
cp -a -- "$SRC" "$BACKUP/source.before"
cp -a -- "$LIVE" "$BACKUP/runtime.before"
log "Backups: $BACKUP"

rollback(){
  local rc=$?
  trap - ERR INT TERM
  set +e
  cp -a -- "$BACKUP/source.before" "$SRC"
  cp -a -- "$BACKUP/runtime.before" "$LIVE"
  echo "[V7-ERROR] Patch stopped (exit $rc). Original controller files restored from $BACKUP" >&2
  exit "$rc"
}
trap rollback ERR
trap 'false' INT TERM

# Only restore missing runtime functions after the complete AST preflight above.
NEED_SYNC="$(python3 - "$SRC" "$LIVE" <<'PY'
import ast,sys
from pathlib import Path
src, live = (Path(p).read_text(encoding='utf-8') for p in sys.argv[1:])
def names(s): return {n.name for n in ast.parse(s).body if isinstance(n,ast.FunctionDef)}
required={'main','_reload_amxx_admins','load_server','require_root','_set_cfg_cvar',
          'configure_yapb','db_update_mode','disable_yapb','install_yapb','normalize_permissions',
          'save_server','service_action','service_status'}
print('yes' if required-names(live) else 'no')
PY
)"
if [[ "$NEED_SYNC" == yes ]]; then
  log 'Runtime is incomplete: restoring it from the locally verified repository controller.'
  # Keep original UID/GID/mode of executable; use atomic replacement.
  python3 - "$SRC" "$LIVE" <<'PY'
from pathlib import Path
import os,stat,sys,tempfile
src,dst=map(Path,sys.argv[1:])
s=dst.stat()
fd,tmp=tempfile.mkstemp(prefix='.hyper-cs16-v7-',dir=str(dst.parent))
try:
    with os.fdopen(fd,'wb') as f:
        f.write(src.read_bytes());f.flush();os.fsync(f.fileno())
    os.chmod(tmp,stat.S_IMODE(s.st_mode));os.chown(tmp,s.st_uid,s.st_gid)
    os.replace(tmp,dst)
finally:
    if os.path.exists(tmp):os.unlink(tmp)
PY
fi

log 'Preflight V5 (SQL admins)' 
bash "$V5" check
log 'Preflight V6 (YaPB bots)' 
bash "$V6" check
log 'Applying V5 (SQL admins)' 
bash "$V5" apply
log 'Applying V6 (YaPB bots)' 
bash "$V6" apply

python3 - "$SRC" "$LIVE" <<'PY'
import ast,sys
from pathlib import Path
for filename in sys.argv[1:]:
    code=Path(filename).read_text(encoding='utf-8')
    t=ast.parse(code,filename=filename)
    compile(t,filename,'exec')
    names={n.name for n in t.body if isinstance(n,ast.FunctionDef)}
    required={'sql_provision','server_delete','sql_admins_list','sql_admins_save','sql_admins_delete','enable_yapb'}
    assert required<=names, f'{filename}: missing {sorted(required-names)}'
    p=next(n for n in t.body if isinstance(n,ast.FunctionDef) and n.name=='sql_provision')
    assert 'HH_SQL25_SHARED_V4_1' in (ast.get_source_segment(code,p) or '') or 'HH_SHARED_SQL_PATCH_2026_11' in (ast.get_source_segment(code,p) or '')
    d=next(n for n in t.body if isinstance(n,ast.FunctionDef) and n.name=='server_delete')
    assert 'DROP DATABASE' not in (ast.get_source_segment(code,d) or '')
    assert 'DROP USER' not in (ast.get_source_segment(code,d) or '')
    for command in ('sql-admins-list','sql-admins-save','sql-admins-delete','bots-enable'):
        assert "'"+command+"'" in code, f'{filename}: {command} not registered'
    print('[V7] Verified:',filename)
PY

# Import/argparse test; --help must NOT touch game data or start/stop a server.
HELP="$($LIVE --help)"
for cmd in sql-admins-list sql-admins-save sql-admins-delete bots-enable; do
  grep -Fq -- "$cmd" <<< "$HELP" || { echo "[V7-ERROR] CLI --help missing $cmd" >&2; false; }
done

trap - ERR INT TERM
log 'COMPLETE. Both controllers now support SQL admins and bots-enable; database unchanged.'
log 'SQL-admin rights in game still require admin_sql.amxx to be active and correctly configured.'
log 'Existing SQL admin table rows were only read during preflight/post-install.'
log 'IMPORTANT: the controller inside /root/hyper-hosting-panel has local modifications. Commit it before running git reset --hard.'
