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
