#!/usr/bin/env bash
# HYPER-HOST STORAGE v2: fix CLI dispatch and disk safety diagnostics.
# Installer ONLY edits CLI scripts and Python storage helper; NEVER partitions, formats, mounts or migrates data.
set -Eeuo pipefail
[[ "${EUID}" -eq 0 ]] || { echo '[ERROR] Запусти с sudo / от root' >&2; exit 1; }
REPO="${1:-/root/hyper-hosting-panel}"
HELPER='/usr/local/sbin/hyper-host-storage'
[[ -f "$REPO/scripts/hyper" ]] || { echo "[ERROR] Нет $REPO/scripts/hyper" >&2; exit 2; }
[[ -f "$HELPER" ]] || { echo "[ERROR] Нет $HELPER. Сначала установи storage v1." >&2; exit 2; }
command -v python3 >/dev/null && command -v bash >/dev/null || { echo '[ERROR] Нужны python3 и bash' >&2; exit 2; }
BACKUP="/root/hyper-host-storage-v2-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 -p "$BACKUP"
export HH_STORAGE_BACKUP="$BACKUP" HH_STORAGE_REPO="$REPO"
python3 <<'PYINSTALL'
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(os.environ['HH_STORAGE_REPO'])
backup = pathlib.Path(os.environ['HH_STORAGE_BACKUP'])
helper = pathlib.Path('/usr/local/sbin/hyper-host-storage')

# sudo supplies a privileged PATH, exactly like `sudo hyper ...` at the shell prompt.
# Patch the actual resolved CLI, /usr/bin fallback and /usr/local/bin if present,
# preserving symlinks and not overwriting them with standalone files.
found = shutil.which('hyper')
if not found:
    sys.exit('[ERROR] Команда hyper не найдена в PATH root/sudo. Ничего не изменено.')
paths = [repo/'scripts/hyper', pathlib.Path(found), pathlib.Path('/usr/local/bin/hyper'), pathlib.Path('/usr/bin/hyper')]
resolved = []
for p in paths:
    if p.exists():
        actual = p.resolve(strict=True)
        if actual.is_file() and actual not in resolved:
            resolved.append(actual)
actual_cli = pathlib.Path(found).resolve(strict=True)
if actual_cli not in resolved:
    sys.exit('[ERROR] Не удалось определить исполняемый файл hyper.')

# Replace a single small Bash function, leaving every other HYPER-HOST command intact.
new_cmd_disk = '''cmd_disk() { # HYPER-HOST-STORAGE-v2-DISPATCH
  local sub="${1:-guide}"; shift || true
  case "$sub" in
    guide|help) $CTL disk-guide ;;
    doctor|status|check) $CTL disk-doctor-json | json_pretty ;;
    expand|resize) $CTL disk-expand ;;
    initialize|attach|migrate|verify)
      [[ -x /usr/local/sbin/hyper-host-storage ]] || err "Не найден storage helper: /usr/local/sbin/hyper-host-storage"
      /usr/local/sbin/hyper-host-storage "$sub" "$@" ;;
    *) err "Disk команды: sudo hyper disk doctor | expand | initialize /dev/sdX | attach /dev/sdX1 | migrate sites --maintenance-ok | verify" ;;
  esac
}
'''

originals = {}
patched = {}
for p in resolved:
    src = p.read_text(encoding='utf-8')
    pattern = r'(?ms)^cmd_disk\(\) \{[^\n]*\n.*?^\}\s*\n'
    matches = list(re.finditer(pattern, src))
    if len(matches) != 1:
        if p == actual_cli or p == repo/'scripts/hyper':
            sys.exit(f'[ERROR] cmd_disk() не найден или неоднозначен: {p}; изменения не применены.')
        print(f'[SKIP] Другой CLI без cmd_disk(): {p}')
        continue
    out = src[:matches[0].start()] + new_cmd_disk + '\n' + src[matches[0].end():]
    originals[p] = src
    patched[p] = out

assert actual_cli in patched, 'Actual PATH hyper must be patched'

old = helper.read_text(encoding='utf-8')
new = old

def replace_one(pattern, replacement, note):
    global new
    updated, count = re.subn(pattern, lambda m: replacement, new, count=1, flags=re.M | re.S)
    if count != 1:
        sys.exit(f'[ERROR] Storage helper отличается от v1 ({note}); изменений не применено.')
    new = updated

# lsblk may list partitions both as children and at top level when PKNAME is requested.
# Deduplicate by device path, otherwise attach /dev/sdb1 can be rejected as ambiguous.
replace_one(r'^def flatten\(items\):\n.*?(?=^def fmt\(n\):)', '''def flatten(items):
    result=[]
    seen=set()
    def visit(nodes):
        for node in nodes:
            key=node.get('path') or node.get('name')
            if key not in seen:
                seen.add(key)
                result.append(node)
            visit(node.get('children') or [])
    visit(items)
    return result

''', 'flatten')

# Never attach or format ANY partition of a system disk, even unused /dev/sda1.
replace_one(r'^def guard_device\(dev, expected\):\n.*?(?=^def is_blank_disk\(dev\):)', '''def guard_device(dev, expected):
    root_source=out('findmnt','-n','-o','SOURCE','/').split('[')[0]
    if not root_source.startswith('/dev/'):
        die('Корневая система не на прямом блочном устройстве. Дисковые операции из контейнера/overlay запрещены.')
    info, real=device_info(dev)
    if info.get('type')!=expected: die(f'Нужен тип {expected}; обнаружен {info.get("type")}.')
    if info.get('ro') in ('1',1,True) or info.get('rm') in ('1',1,True):
        die('Read-only/removable диск не подходит.')
    sysdev={os.path.realpath(p) for p in system_paths()}
    byname={node.get('name'):node for node in flatten(lsblk())}
    cur=info
    visited=set()
    while cur:
        name=cur.get('name')
        if name in visited: die('Цикл в структуре lsblk, отказ для безопасности.')
        visited.add(name)
        if os.path.realpath(cur.get('path') or '') in sysdev:
            die('Это системный диск или один из его разделов. Операция запрещена.')
        parent=cur.get('pkname')
        if not parent: break
        if parent not in byname:
            die('Не удалось проследить родительский диск, операция запрещена.')
        cur=byname[parent]
    if info.get('mountpoint') or run('findmnt','-rn','--source',real).returncode==0:
        die('Устройство уже смонтировано. Дублирующее подключение запрещено.')
    return info,real

''', 'guard_device')

replace_one(r'^def doctor\(\):\n.*?(?=^def main\(\):)', '''def doctor():
    devices=flatten(lsblk())
    sysdev={os.path.realpath(x) for x in system_paths()}
    byname={node.get('name'):node for node in devices}
    def system_related(node):
        visited=set()
        while node:
            name=node.get('name')
            if name in visited: return True
            visited.add(name)
            if os.path.realpath(node.get('path') or '') in sysdev: return True
            parent=node.get('pkname')
            node=byname.get(parent) if parent else None
        return False
    store_ok=active_mount(STORE)
    root=usage('/')
    store=usage(STORE) if store_ok else dict(total=0,used=0,free=0)
    root_src=out('findmnt','-n','-o','SOURCE','/').split('[')[0]
    root_fs=out('findmnt','-n','-o','FSTYPE','/')
    lvs=out('lvs','--noheadings','-o','lv_path,vg_name')
    root_lv=''; vg=''
    for line in lvs.splitlines():
        vals=line.split()
        if len(vals)==2 and os.path.realpath(vals[0])==os.path.realpath(root_src):
            root_lv,vg=vals
    for d in devices:
        d['system']=system_related(d)
        d['rotation']='HDD' if d.get('type')=='disk' and out('cat',f'/sys/class/block/{d.get("name")}/queue/rotational')=='1' else ('SSD/NVMe' if d.get('type')=='disk' else '')
        d['size_human']=fmt(d.get('size',0))
        d['eligible']=bool(d.get('type') in ('disk','part') and not d['system'] and not d.get('mountpoint')
                           and not d.get('ro') and not d.get('rm'))
    projects=[{'key':k,'path':v,'on_hdd':store_ok and active_mount(v) and os.stat(v).st_dev==os.stat(STORE).st_dev,
               'total_bytes':usage(v)['total']} for k,v in configured().items()]
    data=dict(version='storage-v2',root_source=root_src,root_fstype=root_fs,
              root_total_bytes=root['total'],root_used_bytes=root['used'],root_free_bytes=root['free'],
              root_total=fmt(root['total']),root_used=fmt(root['used']),root_free=fmt(root['free']),
              root_used_percent=round(root['used']*100/root['total'],2) if root['total'] else 0,
              lvm_detected=bool(vg),root_vg=vg,root_lv_path=root_lv,
              storage_mounted=store_ok,storage_path=str(STORE),storage_total=fmt(store['total']),
              storage_used=fmt(store['used']),storage_free=fmt(store['free']),
              storage_total_bytes=store['total'],storage_free_bytes=store['free'],
              disks=devices,projects=projects,
              note='SSD и HDD остаются отдельными томами. Для проектов HDD используется после явного переноса.',
              recommended_command='sudo hyper disk attach /dev/sdX1' if not store_ok else 'sudo hyper disk migrate sites --maintenance-ok')
    print(json.dumps(data,ensure_ascii=False))

''', 'doctor')

# Validate all new files BEFORE touching a single live path.
patched[helper] = new
originals[helper] = old
staged = {}
for p, content in patched.items():
    if not p.exists() or p.is_symlink():
        sys.exit(f'[ERROR] Цель неожиданно отсутствует или является символьной ссылкой: {p}')
    fd, tmpname = tempfile.mkstemp(prefix='.hyper-host-storage-v2-', dir=str(p.parent))
    temp = pathlib.Path(tmpname)
    staged[p] = temp
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(content)
    st = p.stat()
    os.chmod(temp, st.st_mode & 0o7777)
    os.chown(temp, st.st_uid, st.st_gid)
    mode = 'python' if p == helper else 'bash'
    check = [sys.executable, '-c', "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf8').read())", str(temp)] if mode=='python' else ['bash','-n',str(temp)]
    result = subprocess.run(check, text=True, capture_output=True)
    if result.returncode:
        for t in staged.values(): t.unlink(missing_ok=True)
        sys.exit(f'[ERROR] {p}: проверка синтаксиса не пройдена: {result.stderr}')

# Keep explicit original per-target backups (including installed CLI and helper).
for i, p in enumerate(staged):
    dst = backup/f'{i:02d}-{p.name}'
    shutil.copy2(p, dst)
    (backup/f'{i:02d}-SOURCE.txt').write_text(str(p)+'\n',encoding='utf-8')

for p, temp in staged.items():
    os.replace(temp, p)
    print(f'[OK] {p}')

print(f'[BACKUP] {backup}')
print(f'[ROOT CLI] {actual_cli}')
PYINSTALL

echo
echo '======================================================'
echo ' HYPER-HOST STORAGE v2: CLI DISPATCH FIX INSTALLED'
echo ' Никакие HDD/разделы НЕ изменялись.'
echo '======================================================'
echo '[CHECK] New CLI routes are registered:'
# Non-destructive check: no argument -> prints helper usage error (and cannot touch disks).
if /usr/local/sbin/hyper-host-storage --help >/dev/null 2>&1; then echo '[OK] Python helper available'; fi
probe_output="$(hyper disk initialize 2>&1 || true)"
if grep -Fq 'hyper-host-storage ERROR' <<<"$probe_output"; then
  echo '[OK] hyper disk initialize reaches storage helper'
else
  echo '[WARN] CLI check inconclusive: verify `command -v hyper`, `sudo hyper disk verify`.'
fi
echo '[NEXT] sudo hyper disk doctor'
echo '[NEXT] sudo wipefs -n /dev/sdb'
echo '[NOTE] Запуск initialize/attach и перенос файлов НЕ выполнялись.'
