#!/usr/bin/env bash
# HYPER-HOST STORAGE v1: safe installation. No disks are modified during installation.
set -Eeuo pipefail
REPO="${1:-/root/hyper-hosting-panel}"
BACKUP="/root/hyper-host-storage-backup-$(date +%Y%m%d-%H%M%S)-$$"
HELPER=/usr/local/sbin/hyper-host-storage
[[ "${EUID}" -eq 0 ]] || { echo '[ERROR] Run with sudo/root' >&2; exit 1; }
for f in "$REPO/scripts/hhctl" "$REPO/scripts/hyper" "$REPO/src/public/index.php"; do
  [[ -f "$f" ]] || { echo "[ERROR] Required source not found: $f" >&2; exit 2; }
done
command -v python3 >/dev/null || { echo '[ERROR] python3 required' >&2; exit 2; }
command -v php >/dev/null || { echo '[ERROR] php CLI required to validate UI' >&2; exit 2; }
command -v rsync >/dev/null || { echo '[ERROR] rsync required for future migration' >&2; exit 2; }
mkdir -p "$BACKUP"
backup() {
  local path="$1" out="$BACKUP${1}"
  [[ -f "$path" ]] || return 0
  mkdir -p "$(dirname "$out")"
  cp -a "$path" "$out"
}
for f in "$REPO/scripts/hhctl" "$REPO/scripts/hyper" "$REPO/src/public/index.php" \
    /usr/local/sbin/hyper-host-ctl /usr/local/bin/hyper /var/www/hyper-host/public/index.php \
    "$HELPER"; do backup "$f"; done
TMP="$(mktemp -d /tmp/hyper-host-storage-patch.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/src/public"
cp -a "$REPO/scripts/hhctl" "$TMP/scripts/hhctl"
cp -a "$REPO/scripts/hyper" "$TMP/scripts/hyper"
cp -a "$REPO/src/public/index.php" "$TMP/src/public/index.php"
# Patch live files independently: running installations often differ from GitHub sources.
if [[ -f /usr/local/sbin/hyper-host-ctl || -f /usr/local/bin/hyper || -f /var/www/hyper-host/public/index.php ]]; then
  mkdir -p "$TMP/live/scripts" "$TMP/live/src/public"
  cp -a "${LIVE_CTL:-/usr/local/sbin/hyper-host-ctl}" "$TMP/live/scripts/hhctl" 2>/dev/null || cp -a "$REPO/scripts/hhctl" "$TMP/live/scripts/hhctl"
  cp -a /usr/local/bin/hyper "$TMP/live/scripts/hyper" 2>/dev/null || cp -a "$REPO/scripts/hyper" "$TMP/live/scripts/hyper"
  cp -a /var/www/hyper-host/public/index.php "$TMP/live/src/public/index.php" 2>/dev/null || cp -a "$REPO/src/public/index.php" "$TMP/live/src/public/index.php"
fi

# Helper handles disk discovery + explicit, guarded disk operations.
cat > "$TMP/hyper-host-storage" <<'PYHELPER'
#!/usr/bin/env python3
"""HYPER-HOST STORAGE v1. Non-destructive by default."""
import json, os, pathlib, shutil, subprocess, sys, tempfile, re, datetime

STORE = pathlib.Path('/srv/hyper-host-storage')
FSTAB = pathlib.Path('/etc/fstab')
MARKER = '# HYPER-HOST-STORAGE-v1'
KINDS = ('sites', 'bots', 'ftp', 'cs16', 'deploy', 'backups')

def run(*args, check=False, capture=True):
    try:
        p = subprocess.run(list(map(str, args)), text=True, stdout=subprocess.PIPE if capture else None,
                           stderr=subprocess.PIPE if capture else None)
    except FileNotFoundError:
        p = subprocess.CompletedProcess(args, 127, '', f'Command not found: {args[0]}')
    if check and p.returncode:
        raise RuntimeError(f"{' '.join(map(str,args))}: {(p.stderr or p.stdout or '').strip()}")
    return p

def out(*args):
    p = run(*args)
    return p.stdout.strip() if p.returncode == 0 else ''

def die(message):
    raise RuntimeError(message)

def require_root():
    if os.geteuid():
        die('Запусти через sudo.')

def lsblk():
    try:
        return json.loads(run('lsblk', '-J', '-b', '-o', 'NAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINT,UUID,RO,RM,MODEL,PKNAME', check=True).stdout)['blockdevices']
    except Exception as e:
        die('Не удалось получить lsblk JSON: ' + str(e))

def flatten(items):
    result=[]
    for it in items:
        result.append(it)
        result.extend(flatten(it.get('children') or []))
    return result

def fmt(n):
    n=float(n or 0)
    for unit in ('B','KB','MB','GB','TB','PB'):
        if n<1024 or unit=='PB': return f'{n:.1f} {unit}'
        n/=1024
    return '0'

def usage(path):
    try:
        s=shutil.disk_usage(path)
        return dict(total=s.total, used=s.used, free=s.free)
    except OSError:
        return dict(total=0, used=0, free=0)

def active_mount(path):
    return run('mountpoint', '-q', str(path)).returncode == 0

def backup_fstab():
    name='/root/fstab.hyper-host-storage-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')+'.bak'
    shutil.copy2(FSTAB,name)
    print('[BACKUP]',name)

def configured():
    cfg={}
    file=pathlib.Path('/etc/hyper-host/hyper-host.conf')
    if file.exists():
        for line in file.read_text(errors='replace').splitlines():
            m=re.match(r'^([A-Z_]+)="([^"\\]*)"$',line)
            if m: cfg[m[1]]=m[2]
    return dict(sites=cfg.get('SITES_DIR','/var/www/hyper-host-sites'),
                bots=cfg.get('BOTS_DIR','/var/www/hyper-host-bots'),
                ftp=cfg.get('FTP_DIR','/var/www/hyper-host-ftp'),
                cs16='/srv/hyper-cs16', deploy='/var/www/hyper-host-deploy',
                backups=cfg.get('BACKUP_DIR','/opt/hyper-host/backups'))

def system_paths():
    # Root, /boot, /boot/efi and swap descendants are never eligible.
    sources=[]
    for mount in ('/','/boot','/boot/efi'):
        s=out('findmnt','-n','-o','SOURCE','--target',mount).split('[')[0]
        if s and s.startswith('/dev/') and s not in sources: sources.append(s)
    for line in out('swapon','--noheadings','--raw','--output=NAME').splitlines():
        if line.startswith('/dev/'): sources.append(line.strip())
    related=set()
    for src in sources:
        real=os.path.realpath(src)
        for a in (src,real):
            related.add(a)
            p=run('lsblk','-s','-n','-o','PATH',a)
            if p.returncode==0:
                related.update(x.strip() for x in p.stdout.splitlines())
    return related

def mount_set():
    found=set()
    for item in flatten(lsblk()):
        mp=item.get('mountpoint')
        if mp: found.add(item.get('path',''))
    return found

def device_info(dev):
    if not dev.startswith('/dev/') or not os.path.exists(dev): die('Укажи существующий /dev/..., например /dev/sdb1')
    real=os.path.realpath(dev)
    entries=flatten(lsblk())
    matches=[i for i in entries if os.path.realpath(i.get('path') or '/not-found')==real]
    if len(matches)!=1: die('Устройство не найдено в lsblk (или неоднозначно).')
    return matches[0],real

def guard_device(dev, expected):
    root_source=out('findmnt','-n','-o','SOURCE','/').split('[')[0]
    if not root_source.startswith('/dev/'):
        die('Корневая система не на прямом блочном устройстве. Дисковые операции из контейнера/overlay запрещены.')
    info, real=device_info(dev)
    if info.get('type')!=expected: die(f'Нужен тип {expected}; обнаружен {info.get("type")}.')
    if info.get('ro') in ('1',1,True) or info.get('rm') in ('1',1,True): die('Read-only/removable диск не подходит.')
    if real in {os.path.realpath(x) for x in system_paths()}:
        die('Системный диск/раздел. Операция запрещена.')
    if info.get('mountpoint') or run('findmnt','-rn','--source',real).returncode==0:
        die('Устройство уже смонтировано. Дублирующее подключение запрещено.')
    return info,real

def is_blank_disk(dev):
    info,_=guard_device(dev,'disk')
    if info.get('fstype') or info.get('uuid'): die('Обнаружена файловая система/UUID. Не форматирую.')
    nodes=flatten(lsblk())
    if any(x.get('pkname')==info.get('name') for x in nodes):
        die('На диске уже есть разделы. Разметку не трогаю.')
    sig=run('wipefs','--no-act',dev,check=True)
    if sig.stdout.strip(): die('Обнаружены сигнатуры/разметка. Форматирование запрещено.')
    if run('blkid','-p',dev).returncode==0: die('blkid обнаружил данные. Форматирование запрещено.')
    # Refuse disks which are currently part of md/RAID/LVM or held by kernel device-mapper.
    basename=os.path.basename(os.path.realpath(dev))
    holders=pathlib.Path('/sys/class/block')/basename/'holders'
    if holders.exists() and any(holders.iterdir()): die('Диск используется другим блочным устройством.')

def initialize(dev):
    require_root()
    for program in ('parted','partprobe','mkfs.ext4','wipefs','udevadm'):
        if not shutil.which(program): die(f'Не найден {program}. Установи необходимые дисковые утилиты.')
    dev=os.path.realpath(dev)
    is_blank_disk(dev)
    print('ВНИМАНИЕ: создание GPT и ext4 на НОВОМ ПУСТОМ диске:',dev)
    print(out('lsblk','-o','NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL',dev))
    value=input(f'Для продолжения введи в точности: ERASE {dev}\n> ')
    if value!=f'ERASE {dev}': die('Отменено пользователем. Диск не изменён.')
    is_blank_disk(dev)
    run('parted','-s',dev,'mklabel','gpt','mkpart','primary','ext4','1MiB','100%',check=True)
    run('partprobe',dev)
    run('udevadm','settle')
    parts=[x['path'] for x in flatten(lsblk()) if x.get('pkname')==os.path.basename(dev) and x.get('type')=='part']
    if len(parts)!=1: die('Раздел создан, но не удалось определить его имя; проверь lsblk вручную.')
    part=parts[0]
    run('mkfs.ext4','-m','0','-L','HYPERHOSTDATA',part,check=True,capture=False)
    print('Готово. Для подключения выполни: sudo hyper disk attach',part)

def attach(dev):
    require_root()
    if active_mount(STORE): die(f'{STORE} уже является точкой монтирования.')
    info,real=guard_device(dev,'part') if device_info(dev)[0].get('type')=='part' else guard_device(dev,'disk')
    fs=info.get('fstype') or out('blkid','-s','TYPE','-o','value',real)
    if fs not in ('ext4','xfs','btrfs'):
        die('Требуется существующая файловая система ext4, xfs или btrfs. Пустой диск: sudo hyper disk initialize /dev/sdX')
    uuid=out('blkid','-s','UUID','-o','value',real)
    if not re.fullmatch(r'[a-zA-Z0-9-]{8,80}',uuid): die('Не удалось получить корректный UUID.')
    if f'UUID={uuid}' in FSTAB.read_text(errors='replace'):
        die('Этот UUID уже присутствует в /etc/fstab. Проверь существующие подключения.')
    if STORE.exists() and (STORE.is_symlink() or any(STORE.iterdir())):
        die(f'{STORE} не пуст или является ссылкой. Не буду скрывать существующие данные.')
    STORE.mkdir(parents=True,exist_ok=True)
    # Attach only truly empty filesystems, not existing HDDs holding user files.
    with tempfile.TemporaryDirectory(prefix='hyper-hdd-ro-') as tmp:
        run('mount','-o','ro',real,tmp,check=True)
        try:
            names=[p.name for p in pathlib.Path(tmp).iterdir() if p.name!='lost+found']
            if names: die('На HDD уже имеются данные. Автоматическое подключение как нового хранилища запрещено.')
        finally:
            run('umount',tmp,check=True)
    original=FSTAB.read_text()
    backup_fstab()
    passno=2 if fs=='ext4' else 0
    entry=f'{MARKER} main\nUUID={uuid} {STORE} {fs} defaults,x-systemd.device-timeout=30s 0 {passno}\n'
    FSTAB.write_text(original.rstrip('\n')+'\n'+entry)
    try:
        run('mount',str(STORE),check=True)
        if not active_mount(STORE): die('Mount command did not create a mountpoint.')
        run('systemctl','daemon-reload')
        print(f'[OK] {real} ({fmt(info.get("size"))}) подключен в {STORE}.')
        print('Следующий шаг (при остановленных сервисах): sudo hyper disk migrate sites --maintenance-ok')
    except Exception:
        FSTAB.write_text(original)
        raise

def migrate(kind, confirmed):
    require_root()
    if kind == 'all':
        if not confirmed: die('Для массового переноса сначала останови службы и передай --maintenance-ok.')
        for key in KINDS:
            if pathlib.Path(configured()[key]).is_dir():
                migrate(key, True)
            else: print('[SKIP] Нет категории:', key)
        return
    if not confirmed: die('Сначала останови сервисы и повтори с --maintenance-ok. Переносит данные, требует окно обслуживания.')
    if kind not in KINDS: die('Категории: all, '+', '.join(KINDS))
    if not active_mount(STORE): die(f'{STORE} не смонтирован. Сперва: sudo hyper disk attach /dev/sdX1')
    src=pathlib.Path(configured()[kind])
    if src.is_symlink(): die('Источник — символическая ссылка, перенос запрещён.')
    if not src.exists() or not src.is_dir(): die(f'Исходный каталог не найден: {src}')
    if active_mount(src):
        target=STORE/kind
        if target.exists() and (os.stat(src).st_dev,os.stat(src).st_ino)==(os.stat(target).st_dev,os.stat(target).st_ino):
            print('[OK] Уже перенесено:',src); return
        die('Путь уже смонтирован, не буду заменять его.')
    # Nested mounts and bind mounts must not be copied or hidden.
    nested=out('findmnt','-rn','-o','TARGET','-R',str(src)).splitlines()
    if nested: die('В каталоге имеются вложенные mountpoints: '+str(nested))
    dest=STORE/kind
    if dest.exists() and any(dest.iterdir()):
        die(f'Каталог {dest} уже содержит данные. Не буду перезаписывать или смешивать их.')
    dest.mkdir(mode=0o755,parents=True,exist_ok=True)
    print('[INFO] Копирование данных:',src,'->',dest)
    # No --delete. On error the original stays at its original path.
    run('rsync','-aHAX','--numeric-ids','--one-file-system',str(src)+'/',str(dest)+'/',check=True,capture=False)
    # Verify checksums of content before making the new location visible.
    check=run('rsync','-aHAXnci','--numeric-ids','--one-file-system',str(src)+'/',str(dest)+'/',check=True)
    if check.stdout.strip():
        die('Проверка rsync обнаружила изменения. Перенос не включён. Проверь остановку всех пишущих процессов.')
    run('mount','--bind',str(dest),str(src),check=True)
    try:
        if not active_mount(src): die('Bind mount не активен.')
        entry=f'{MARKER} {kind}\n{dest} {src} none bind,x-systemd.requires={STORE} 0 0\n'
        backup_fstab()
        with FSTAB.open('a') as f: f.write(entry)
        run('systemctl','daemon-reload')
        print('[OK] Перенос завершён:',src)
        print('[INFO] Исходные файлы остались под bind mount как резервная копия. Не удаляй их без сверки и внешнего бэкапа.')
    except Exception:
        run('umount',str(src))
        raise

def doctor():
    devices=flatten(lsblk())
    sysdev={os.path.realpath(x) for x in system_paths()}
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
        path=d.get('path') or ''
        d['system']=bool(path and os.path.realpath(path) in sysdev)
        d['rotation']='HDD' if d.get('type')=='disk' and out('cat',f'/sys/class/block/{d.get("name")}/queue/rotational')=='1' else ('SSD/NVMe' if d.get('type')=='disk' else '')
        d['size_human']=fmt(d.get('size',0))
        d['eligible']=bool(d.get('type') in ('disk','part') and not d['system'] and not d.get('mountpoint')
                           and not d.get('ro') and not d.get('rm'))
    projects=[{'key':k,'path':v,'on_hdd':store_ok and active_mount(v) and os.stat(v).st_dev==os.stat(STORE).st_dev,
               'total_bytes':usage(v)['total']} for k,v in configured().items()]
    data=dict(version='storage-v1',root_source=root_src,root_fstype=root_fs,
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

def main():
    if len(sys.argv)<2 or sys.argv[1] in ('help','--help'):
        print('HYPER-HOST STORAGE v1: doctor-json | initialize /dev/sdX | attach /dev/sdX1 | migrate all|sites|bots|ftp|cs16|deploy|backups --maintenance-ok | verify')
        return
    cmd=sys.argv[1]
    if cmd in ('doctor-json','verify'):
        doctor() if cmd=='doctor-json' else (print(out('lsblk','-o','NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT')),print(out('df','-hT','/',str(STORE))))
    elif cmd in ('initialize','attach') and len(sys.argv)==3:
        (initialize if cmd=='initialize' else attach)(sys.argv[2])
    elif cmd=='migrate' and len(sys.argv)>=3:
        migrate(sys.argv[2],'--maintenance-ok' in sys.argv[3:])
    else: die('Неизвестная команда или неверные аргументы. Используй: sudo hyper disk guide')

if __name__=='__main__':
    try: main()
    except (RuntimeError, OSError, KeyboardInterrupt) as e:
        print('[hyper-host-storage ERROR]', str(e), file=sys.stderr); sys.exit(1)
PYHELPER
chmod 0755 "$TMP/hyper-host-storage"
python3 -m py_compile "$TMP/hyper-host-storage"

cat > "$TMP/patch.py" <<'PYPATCH'
import pathlib,sys,re
root=pathlib.Path(sys.argv[1])
p=root/'scripts/hhctl'
s=p.read_text()
marker='HYPER-HOST-STORAGE-v1-GUARD'
if marker not in s:
    needle='cmd_disk_doctor_json() {\n'
    assert s.count(needle)==1,'hhctl: disk doctor function not found'
    s=s.replace(needle,needle+'  # '+marker+'\n  if [[ -x /usr/local/sbin/hyper-host-storage ]]; then\n    /usr/local/sbin/hyper-host-storage doctor-json\n    return\n  fi\n',1)
if '  disk-storage) shift;' not in s:
    needle='  disk-doctor-json) shift;'
    assert s.count(needle)==1,'hhctl: dispatch anchor not found'
    s=s.replace(needle,'  disk-storage) shift; /usr/local/sbin/hyper-host-storage "$@" ;;\n'+needle,1)
s=s.replace('[[ -n "$vg" ]] || err "Root раздел не похож на LVM. Пришли вывод: lsblk; pvs; vgs; lvs"',
'''[[ -n "$vg" ]] || err "Root не LVM. Для отдельного HDD используй: sudo hyper disk doctor; sudo hyper disk attach /dev/sdX1 (или initialize для нового пустого диска)"''')
p.write_text(s)

p=root/'scripts/hyper';s=p.read_text()
marker='HYPER-HOST-STORAGE-v1-COMMANDS'
if marker not in s:
    needle='    expand|resize) $CTL disk-expand ;;'
    assert s.count(needle)==1,'hyper: disk dispatch not found'
    s=s.replace(needle,needle+'''\n    # HYPER-HOST-STORAGE-v1-COMMANDS
    initialize|attach|migrate|verify) $CTL disk-storage "$sub" "$@" ;;''',1)
    s=s.replace('Disk команды: sudo hyper disk guide | doctor | expand',
                'Disk: doctor | expand (LVM) | initialize /dev/sdX | attach /dev/sdX1 | migrate sites --maintenance-ok | verify')
p.write_text(s)

p=root/'src/public/index.php';s=p.read_text()
marker='HYPER-HOST-STORAGE-v1-UI'
if marker not in s:
    m=re.search(r'function view_disk\(\): void\s*\{.*?\}\s*(?=function view_settings\(\): void)',s,flags=re.S)
    assert m,'index.php: view_disk() anchors not found'
    view='''function view_disk(): void
{ // HYPER-HOST-STORAGE-v1-UI
  $j=run_ctl_json_cached(['disk-doctor-json'],3,30);
  $disks=(array)($j['disks']??[]);
  $projects=(array)($j['projects']??[]);
?>
<div class="row g-4">
  <div class="col-xl-5"><div class="panel-card h-100">
    <h2><i class="fa-solid fa-hard-drive me-2"></i>Накопители HYPER-HOST</h2>
    <div class="network-check-grid mb-3">
      <div class="network-check"><span>Системный раздел</span><b><?= e((string)($j['root_total']??'—')) ?></b></div>
      <div class="network-check"><span>Свободно на root</span><b><?= e((string)($j['root_free']??'—')) ?></b></div>
      <div class="network-check"><span>Диск проектов</span><b><?= e(!empty($j['storage_mounted'])?(string)($j['storage_total']??'—'):'Не подключён') ?></b></div>
      <div class="network-check"><span>Свободно на HDD</span><b><?= e(!empty($j['storage_mounted'])?(string)($j['storage_free']??'—'):'—') ?></b></div>
    </div>
    <p class="text-muted small">SSD и HDD — отдельные файловые системы. Дополнительное место появится для проектов после подключения и переноса их каталогов.</p>
    <?php if (!empty($j['lvm_detected'])): ?>
    <form method="post" onsubmit="return confirm('Расширить ТОЛЬКО корневой том LVM? Не использовать для отдельного HDD.')">
      <?= csrf_field() ?><input type="hidden" name="action" value="disk_expand">
      <button class="btn btn-primary w-100">Расширить корневой LVM</button>
    </form>
    <?php endif; ?>
    <div class="mt-3 vstack gap-2">
      <button class="cmd-copy" type="button" data-copy="sudo hyper disk doctor"><code>sudo hyper disk doctor</code></button>
      <button class="cmd-copy" type="button" data-copy="sudo hyper disk verify"><code>sudo hyper disk verify</code></button>
    </div>
  </div></div>
  <div class="col-xl-7"><div class="panel-card h-100">
    <h2>Физические диски и разделы</h2>
    <div class="table-responsive"><table class="table table-sm align-middle"><thead><tr><th>Устройство</th><th>Объём</th><th>Тип / ФС</th><th>Состояние</th></tr></thead><tbody>
    <?php foreach ($disks as $d): $path=(string)($d['path']??''); ?>
      <tr><td><code><?= e($path) ?></code></td><td><?= e((string)($d['size_human']??'')) ?></td>
      <td><?= e((string)($d['rotation']??$d['type']??'')) ?> <?= e((string)($d['fstype']??'')) ?></td>
      <td><?= !empty($d['system'])?'Системный':(!empty($d['mountpoint'])?'Смонтирован':(!empty($d['eligible'])?'Доступен для проверки':'Требует проверки')) ?></td></tr>
    <?php endforeach; ?>
    </tbody></table></div>
    <h3 class="h6 mt-3">Каталоги проектов</h3>
    <div class="table-responsive"><table class="table table-sm"><thead><tr><th>Категория</th><th>Путь</th><th>HDD</th></tr></thead><tbody>
    <?php foreach ($projects as $p): ?><tr><td><?= e((string)($p['key']??'')) ?></td><td><code><?= e((string)($p['path']??'')) ?></code></td><td><?= !empty($p['on_hdd'])?'Подключён':'Нет' ?></td></tr><?php endforeach; ?>
    </tbody></table></div>
    <p class="text-muted small mb-0">Инициализацию HDD и перенос данных выполняй только по SSH. Веб-панель ничего не форматирует автоматически.</p>
  </div></div>
</div>
<?php }
'''
    s=s[:m.start()]+view+s[m.end():]
p.write_text(s)
PYPATCH
python3 "$TMP/patch.py" "$TMP"
if [[ -d "$TMP/live" ]]; then
  python3 "$TMP/patch.py" "$TMP/live"
  bash -n "$TMP/live/scripts/hhctl" "$TMP/live/scripts/hyper"
  php -l "$TMP/live/src/public/index.php" >/dev/null
fi
bash -n "$TMP/scripts/hhctl" "$TMP/scripts/hyper"
php -l "$TMP/src/public/index.php" >/dev/null

# Publish only validated sources. They are also patched inside repository, so normal updates retain them.
install -m 0755 "$TMP/hyper-host-storage" "$HELPER"
install -m 0755 "$TMP/scripts/hhctl" "$REPO/scripts/hhctl"
install -m 0755 "$TMP/scripts/hyper" "$REPO/scripts/hyper"
install -m 0644 "$TMP/src/public/index.php" "$REPO/src/public/index.php"
# Live installation. Preserve existing owner/group/mode and unrelated hotfixes.
replace_live() {
  local src="$1" dst="$2" mode uid gid
  [[ -f "$dst" ]] || return 0
  mode="$(stat -c %a "$dst")"; uid="$(stat -c %u "$dst")"; gid="$(stat -c %g "$dst")"
  install -m "$mode" -o "$uid" -g "$gid" "$src" "$dst"
}
if [[ -d "$TMP/live" ]]; then
  replace_live "$TMP/live/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
  replace_live "$TMP/live/scripts/hyper" /usr/local/bin/hyper
  replace_live "$TMP/live/src/public/index.php" /var/www/hyper-host/public/index.php
fi

printf '\n========================================================\n'
printf ' HYPER-HOST STORAGE v1: INSTALLED (safe mode)\n'
printf ' No formatting, repartitioning or migrations performed.\n'
printf ' Backup: %s\n' "$BACKUP"
printf '========================================================\n'
echo '[INFO] Attached disks and free space:'
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL || true
printf '\n[INFO] ROOT: '\ndf -hT / | tail -n1 || true
printf '\n[INFO] Next command: sudo hyper disk doctor\n'
printf '[INFO] If HDD is blank: sudo hyper disk initialize /dev/sdX\n'
printf '[INFO] If HDD has an empty ext4 partition: sudo hyper disk attach /dev/sdX1\n'
printf '[INFO] Move data in maintenance window: sudo hyper disk migrate all --maintenance-ok\n'
