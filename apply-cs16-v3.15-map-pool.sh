#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.15 — REAL MAP POOL / WHITELIST
#
# Adds per-server real map selection:
# - list comes only from cstrike/maps/*.bsp
# - selected maps are persisted in server state
# - selected maps are written to cstrike/mapcycle.txt
# - selected maps are written to AMXX configs/maps.ini
# - quick map / map tab show only allowed maps
# - controller rejects activate-map outside whitelist
# - config-set rejects start map outside whitelist
# - panel RCON rejects "map/changelevel" outside whitelist
# - manual mapcycle.txt/maps.ini editing is blocked while pool is enabled
# - pool is reconciled automatically after future assembly swaps
#
# This patch does NOT reinstall v3.3/v3.14 and does NOT touch panel DB schema.

SID="${1:-14}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.15-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.15-${STAMP}.log"
DOMAIN="www.avito.hyper-host.pw"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die() {
  echo
  echo "[ERROR] $*"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backup: $BACKUP"
  exit 1
}

echo "============================================================"
echo " HYPER-HOST CS16 MAP POOL v3.15"
echo "============================================================"
echo "Repo:       $REPO"
echo "Controller: $LIVE_CTL"
echo "Server:     $SID"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO/cs16-panel/bin/hyper-cs16-ctl" ]] || die "Repository controller not found"
[[ -f "$REPO/cs16-panel/public/index.php" ]] || die "Repository panel index.php not found"
[[ -f "$REPO/cs16-panel/public/assets/app.js" ]] || die "Repository app.js not found"
[[ -f "$REPO/cs16-panel/public/assets/style.css" ]] || die "Repository style.css not found"

PATCHER="$(mktemp)"
trap 'rm -f "$PATCHER"' EXIT

cat >"$PATCHER" <<'PY'
from pathlib import Path
import re, sys, py_compile


def patch_ctl(path):
    s=Path(path).read_text('utf-8', errors='surrogateescape')
    orig=s
    marker='# >>> HYPER-HOST v3.15 MAP POOL >>>'
    if marker not in s:
        pos=s.find('\ndef map_list(sid:int):')
        if pos<0: raise RuntimeError('map_list insertion point missing')
        helper=r'''
# >>> HYPER-HOST v3.15 MAP POOL >>>
def _installed_map_names(c:dict)->list[str]:
    d=Path(c['path'])/'cstrike/maps'
    return sorted({p.stem for p in d.glob('*.bsp') if SAFE_MAP.fullmatch(p.stem)},key=str.lower) if d.is_dir() else []


def _map_pool_state(c:dict)->tuple[list[str],list[str],bool]:
    installed=_installed_map_names(c)
    enabled=bool(c.get('map_pool_enabled',False))
    if not enabled:
        return installed,installed,False
    raw=c.get('map_pool') if isinstance(c.get('map_pool'),list) else []
    seen=set(); allowed=[]
    installed_set=set(installed)
    for item in raw:
        name=str(item or '').strip()
        if name in installed_set and name not in seen and SAFE_MAP.fullmatch(name):
            seen.add(name); allowed.append(name)
    return installed,allowed,True


def _map_pool_write_files(c:dict,allowed:list[str]):
    root=Path(c['path'])/'cstrike'
    body='\\n'.join(allowed).rstrip()+'\\n'
    (root/'mapcycle.txt').write_text(body,encoding='utf-8')
    amxx=root/'addons/amxmodx/configs'
    amxx.mkdir(parents=True,exist_ok=True)
    (amxx/'maps.ini').write_text(body,encoding='utf-8')


def _map_pool_allowed(c:dict,map_name:str)->bool:
    installed,allowed,enabled=_map_pool_state(c)
    if map_name not in installed:
        return False
    return (not enabled) or map_name in allowed


def map_pool_reconcile(sid:int):
    c=load_server(sid)
    installed,allowed,enabled=_map_pool_state(c)
    if not installed:
        return {'ok':True,'enabled':enabled,'installed_maps':[],'allowed_maps':[],'start_map':str(c.get('start_map') or '')}
    if enabled:
        if not allowed:
            requested=str(c.get('start_map') or '')
            if requested in installed: allowed=[requested]
            else:
                zm=[x for x in installed if x.lower().startswith('zm_')]
                allowed=[zm[0] if zm else installed[0]]
        c['map_pool']=allowed
        if str(c.get('start_map') or '') not in allowed:
            c['start_map']=allowed[0]
            db_update_start_map(sid,allowed[0])
        _map_pool_write_files(c,allowed)
        save_server(c)
        normalize_permissions(Path(c['path']))
    return {'ok':True,'enabled':enabled,'installed_maps':installed,'allowed_maps':allowed if enabled else installed,'start_map':str(c.get('start_map') or '')}


def map_pool_set(sid:int,payload:dict):
    require_root(); c=load_server(sid)
    installed=_installed_map_names(c); installed_set=set(installed)
    raw=payload.get('maps') if isinstance(payload,dict) else None
    if not isinstance(raw,list): raise RuntimeError('Map list is required')
    selected=[]; seen=set()
    for item in raw:
        name=str(item or '').strip()
        if not SAFE_MAP.fullmatch(name): raise RuntimeError('Invalid map name: '+name)
        if name not in installed_set: raise RuntimeError('Map is not installed on this server: '+name)
        if name not in seen: seen.add(name); selected.append(name)
    if not selected: raise RuntimeError('Select at least one map')
    start=str(payload.get('start_map') or '').strip()
    if start not in selected: start=selected[0]
    old_start=str(c.get('start_map') or '')
    c['map_pool_enabled']=True
    c['map_pool']=selected
    c['start_map']=start
    save_server(c); db_update_start_map(sid,start)
    _map_pool_write_files(c,selected)
    normalize_permissions(Path(c['path']))
    current=''
    if service_status(sid)=='active' and udp_listening(int(c['port'])):
        current,_=rcon_current_map(c)
        if current and current not in selected:
            changed=activate_map(sid,start)
            current=str(changed.get('current_map') or start)
    return {'ok':True,'enabled':True,'installed_maps':installed,'allowed_maps':selected,'maps':selected,'start_map':start,'current_map':current,'changed_start':old_start!=start}
# <<< HYPER-HOST v3.15 MAP POOL <<<

'''
        s=s[:pos]+helper+s[pos:]

    # replace map_list function
    rx=re.compile(r"(?ms)^def map_list\(sid:int\):\n.*?(?=^def _persist_start_map\()")
    m=rx.search(s)
    if not m: raise RuntimeError('map_list function not found')
    new="""def map_list(sid:int):\n    c=load_server(sid)\n    installed,allowed,enabled=_map_pool_state(c)\n    current=str(c.get('start_map') or '')\n    if service_status(sid)=='active' and udp_listening(int(c['port'])):\n        rmap,_=rcon_current_map(c)\n        if rmap:\n            current=rmap\n        else:\n            qi,_=query_info_retry(int(c['port']),1)\n            if qi: current=str(qi.get('map') or current)\n    return {'ok':True,'maps':allowed,'installed_maps':installed,'allowed_maps':allowed,'map_pool_enabled':enabled,'current_map':current,'start_map':str(c.get('start_map') or '')}\n\n\n"""
    s=s[:m.start()]+new+s[m.end():]

    # block panel RCON console from bypassing the map pool
    rcon_old="""def rcon_cmd(sid:int,command:str):\n    c=load_server(sid)\n    if not command or len(command)>512 or '\\n' in command or '\\r' in command: raise RuntimeError('Invalid RCON command')\n"""
    rcon_new="""def rcon_cmd(sid:int,command:str):\n    c=load_server(sid)\n    if not command or len(command)>512 or '\\n' in command or '\\r' in command: raise RuntimeError('Invalid RCON command')\n    m=re.match(r'^\\s*(?:changelevel|map)\\s+([A-Za-z0-9_-]{1,64})(?:\\s|$)',command,re.I)\n    if m and not _map_pool_allowed(c,m.group(1)):\n        raise RuntimeError('Map is not enabled in this server map pool: '+m.group(1))\n"""
    if 'Map is not enabled in this server map pool: '+"'"+'+m.group(1)' not in s:
        if rcon_old not in s: raise RuntimeError('rcon_cmd guard point missing')
        s=s.replace(rcon_old,rcon_new,1)

    # protect managed mapcycle/maps.ini from manual editor bypass
    cfg_old="""def config_write(sid:int,name:str,content:str):\n    require_root(); c,p=config_file(sid,name)\n    if len(content.encode('utf-8'))>512*1024: raise RuntimeError('Config is too large')\n"""
    cfg_new="""def config_write(sid:int,name:str,content:str):\n    require_root(); c,p=config_file(sid,name)\n    if name in {'mapcycle.txt','maps.ini'} and bool(c.get('map_pool_enabled',False)):\n        raise RuntimeError('This map file is managed by the panel map pool. Change it on the Maps tab.')\n    if len(content.encode('utf-8'))>512*1024: raise RuntimeError('Config is too large')\n"""
    if 'This map file is managed by the panel map pool' not in s:
        if cfg_old not in s: raise RuntimeError('config_write pool guard point missing')
        s=s.replace(cfg_old,cfg_new,1)

    # strict activate map
    needle="    if not bsp.is_file(): raise RuntimeError(f'Map is not installed on this server: {map_name}')\n"
    if "Map is not enabled in this server map pool" not in s:
        if needle not in s: raise RuntimeError('activate_map validation point missing')
        s=s.replace(needle,needle+"    if not _map_pool_allowed(c,map_name): raise RuntimeError(f'Map is not enabled in this server map pool: {map_name}')\n",1)

    # config-set strict pool
    needle="        if not (Path(c['path'])/'cstrike/maps'/(args.map+'.bsp')).is_file(): raise RuntimeError('map is not installed on this server')\n"
    if "start map is not enabled in this server map pool" not in s:
        if needle not in s: raise RuntimeError('config map validation point missing')
        s=s.replace(needle,needle+"        if not _map_pool_allowed(c,args.map): raise RuntimeError('start map is not enabled in this server map pool')\n",1)

    # safe map function pool-aware
    rx=re.compile(r"(?ms)^def _choose_safe_map\(c:dict\):\n.*?(?=^def _recovery_backup\()")
    m=rx.search(s)
    if not m: raise RuntimeError('_choose_safe_map not found')
    safe="""def _choose_safe_map(c:dict):\n    maps=Path(c['path'])/'cstrike/maps'\n    requested=str(c.get('start_map') or '')\n    installed,allowed,enabled=_map_pool_state(c)\n    candidates=allowed if enabled else installed\n    if requested and requested in candidates and (maps/(requested+'.bsp')).is_file(): return requested\n    if enabled and candidates: return candidates[0]\n    if (maps/'de_dust2.bsp').is_file(): return 'de_dust2'\n    if installed: return installed[0]\n    raise RuntimeError('No playable .bsp maps are installed on this server')\n\n\n"""
    s=s[:m.start()]+safe+s[m.end():]

    # build install reconcile after swap/save, before SQL/start
    if '# HYPER-HOST v3.15 reconcile persisted map pool after assembly swap' not in s:
        needle="        c['path']=str(path); c['custom_build_source']=source_label; c['custom_build_installed_at']=int(time.time()); save_server(c)\n\n        mysql_socket=_ensure_legacy_mysql_socket()\n"
        if needle not in s: raise RuntimeError('assembly swap reconcile point missing')
        repl="        c['path']=str(path); c['custom_build_source']=source_label; c['custom_build_installed_at']=int(time.time()); save_server(c)\n\n        # HYPER-HOST v3.15 reconcile persisted map pool after assembly swap\n        map_pool_reconcile(sid)\n        c=load_server(sid)\n\n        mysql_socket=_ensure_legacy_mysql_socket()\n"
        s=s.replace(needle,repl,1)

    # argparse parser
    if "sp.add_parser('map-pool-set')" not in s:
        needle="    q=sp.add_parser('activate-map'); q.add_argument('id',type=int); q.add_argument('map')\n"
        if needle not in s: raise RuntimeError('argparse activate-map point missing')
        s=s.replace(needle,needle+"    q=sp.add_parser('map-pool-set'); q.add_argument('id',type=int)\n",1)
    # command dispatch
    if "elif args.cmd=='map-pool-set':" not in s:
        needle="        elif args.cmd in {'change-map','activate-map'}:\n            result=activate_map(args.id,args.map)\n"
        if needle not in s: raise RuntimeError('dispatch activate-map point missing')
        repl=needle+"        elif args.cmd=='map-pool-set':\n            raw=sys.stdin.buffer.read(256*1024+1)\n            if len(raw)>256*1024: raise RuntimeError('Map pool payload is too large')\n            try: payload=json.loads(raw.decode('utf-8','replace') or '{}')\n            except Exception: raise RuntimeError('Invalid map pool payload')\n            if not isinstance(payload,dict): raise RuntimeError('Invalid map pool payload')\n            result=map_pool_set(args.id,payload)\n"
        s=s.replace(needle,repl,1)

    Path(path).write_text(s,'utf-8',errors='surrogateescape')
    py_compile.compile(str(path),doraise=True)
    return s!=orig


def patch_index(path):
    p=Path(path); s=p.read_text('utf-8'); orig=s
    if "if($action==='save_map_pool')" not in s:
        marker="        if($action==='ftp_reset'){\n"
        block="""        if($action==='save_map_pool'){
            $id=(int)($_POST['id']??0);require_perm('server.map',$id);
            $maps=$_POST['allowed_maps']??[];if(!is_array($maps))$maps=[];if(count($maps)>512)throw new RuntimeException('Слишком много карт');
            $clean=[];foreach($maps as $m){$m=trim((string)$m);if(!preg_match('/^[A-Za-z0-9_-]{1,64}$/',$m))throw new RuntimeException('Некорректная карта: '.$m);$clean[]=$m;}
            $clean=array_values(array_unique($clean));if(!$clean)throw new RuntimeException('Выбери хотя бы одну карту');
            $start=trim((string)($_POST['pool_start_map']??''));if(!in_array($start,$clean,true))$start=$clean[0];
            $payload=json_encode(['maps'=>$clean,'start_map'=>$start],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
            $r=ctl(['map-pool-set',$id],45,$payload?:'{}');if(empty($r['ok']))throw new RuntimeException(ctl_error($r,'Не удалось сохранить список карт'));
            db()->prepare('UPDATE servers SET start_map=? WHERE id=?')->execute([(string)($r['start_map']??$start),$id]);
            audit('map_pool_save',implode(',',$clean).' | start='.$start,$id);flash('Список карт сохранён: '.count($clean).' шт. Сервер будет использовать только выбранные карты.');redirect('/?page=server&id='.$id.'#maps');
        }
"""
        if marker not in s: raise RuntimeError('index POST insertion point missing')
        s=s.replace(marker,block+marker,1)

    # server page map vars
    old="$serverMaps=is_array($serverMapsResult['maps']??null)?$serverMapsResult['maps']:[];if(!in_array((string)$s['start_map'],$serverMaps,true))array_unshift($serverMaps,(string)$s['start_map']);"
    if '$installedMaps=' not in s:
        new="$serverMaps=is_array($serverMapsResult['maps']??null)?$serverMapsResult['maps']:[];$installedMaps=is_array($serverMapsResult['installed_maps']??null)?$serverMapsResult['installed_maps']:$serverMaps;$allowedMaps=is_array($serverMapsResult['allowed_maps']??null)?$serverMapsResult['allowed_maps']:$serverMaps;$mapPoolEnabled=!empty($serverMapsResult['map_pool_enabled']);if(!in_array((string)$s['start_map'],$serverMaps,true)&&in_array((string)$s['start_map'],$installedMaps,true))array_unshift($serverMaps,(string)$s['start_map']);"
        if old not in s: raise RuntimeError('server maps vars point missing')
        s=s.replace(old,new,1)

    if 'id="mapPoolForm"' not in s:
        needle='</form></div><div class="map-control"><div class="map-current">'
        if needle not in s: raise RuntimeError('map tab insertion point missing')
        html=r'''</form></div><div class="map-pool-editor"><div class="map-pool-head"><div><h3><i class="fa-solid fa-list-check"></i> Разрешённые карты</h3><p>Только выбранные карты попадут в mapcycle.txt / AMXX maps.ini и будут доступны для запуска из панели.</p></div><span class="map-pool-count"><b id="mapPoolCount"><?=count($allowedMaps)?></b> / <?=count($installedMaps)?> выбрано</span></div><?php if(can_perm('server.map',$id)):?><form method="post" id="mapPoolForm"><?=csrf_field()?><input type="hidden" name="action" value="save_map_pool"><input type="hidden" name="id" value="<?=$id?>"><div class="map-pool-tools"><div class="map-search"><i class="fa-solid fa-magnifying-glass"></i><input id="mapPoolSearch" class="form-control" placeholder="Фильтр карт: zm_, de_, cs_..."></div><button type="button" class="btn btn-soft btn-sm" id="mapPoolAll">Выбрать все</button><button type="button" class="btn btn-soft btn-sm" id="mapPoolNone">Снять все</button></div><div id="mapPoolGrid" class="map-pool-grid"><?php foreach($installedMaps as $m):$checked=in_array($m,$allowedMaps,true);?><label class="map-pool-item" data-map-pool-name="<?=e(strtolower($m))?>"><input type="checkbox" name="allowed_maps[]" value="<?=e($m)?>" data-map-pool-check <?=$checked?'checked':''?>><span><i class="fa-solid fa-map"></i><b><?=e($m)?></b><small><?=$checked?'Разрешена':'Не используется'?></small></span></label><?php endforeach;?><?php if(!$installedMaps):?><div class="text-secondary">В cstrike/maps пока нет .bsp карт.</div><?php endif;?></div><div class="map-pool-footer"><label><span>Стартовая карта</span><select class="form-select" id="mapPoolStart" name="pool_start_map"><?=map_options($allowedMaps,(string)$s['start_map'])?></select></label><div class="map-pool-note"><i class="fa-solid fa-shield-halved"></i><span>Панель отклонит запуск карты вне этого списка. Если текущая карта исключена, сервер переключится на стартовую.</span></div><button class="btn btn-primary"><i class="fa-solid fa-floppy-disk me-2"></i>Сохранить список</button></div></form><?php else:?><div class="map-pool-readonly"><?php foreach($allowedMaps as $m):?><span><?=e($m)?></span><?php endforeach;?></div><?php endif;?></div><div class="map-control"><div class="map-current">'''
        s=s.replace(needle,html,1)

    s=s.replace('/assets/style.css?v=350','/assets/style.css?v=3150')
    s=s.replace('/assets/app.js?v=350','/assets/app.js?v=3150')
    p.write_text(s,'utf-8'); return s!=orig


def patch_js(path):
    p=Path(path); s=p.read_text('utf-8'); orig=s
    if 'function initMapPoolEditor()' not in s:
        needle="  async function loadPlugins(){\n"
        block=r'''  function initMapPoolEditor(){
    const form=$('#mapPoolForm'); if(!form)return;
    const checks=()=>$$('[data-map-pool-check]',form);
    const start=$('#mapPoolStart');
    const count=$('#mapPoolCount');
    const refresh=()=>{
      const selected=checks().filter(x=>x.checked).map(x=>x.value);
      if(count)count.textContent=String(selected.length);
      checks().forEach(x=>{const label=x.closest('.map-pool-item');const small=label?.querySelector('small');if(label)label.classList.toggle('selected',x.checked);if(small)small.textContent=x.checked?'Разрешена':'Не используется';});
      if(start){const old=start.value;start.innerHTML=selected.map(m=>`<option value="${esc(m)}">${esc(m)}</option>`).join('');if(selected.includes(old))start.value=old;else if(selected.includes(currentMap))start.value=currentMap;}
    };
    checks().forEach(x=>x.addEventListener('change',refresh));
    $('#mapPoolAll')?.addEventListener('click',()=>{checks().forEach(x=>x.checked=true);refresh();});
    $('#mapPoolNone')?.addEventListener('click',()=>{checks().forEach(x=>x.checked=false);refresh();});
    $('#mapPoolSearch')?.addEventListener('input',e=>{const q=String(e.currentTarget.value||'').trim().toLowerCase();$$('[data-map-pool-name]',form).forEach(x=>x.hidden=!!q&&!String(x.dataset.mapPoolName||'').includes(q));});
    form.addEventListener('submit',e=>{if(!checks().some(x=>x.checked)){e.preventDefault();toast('Выбери хотя бы одну карту',true);}});
    refresh();
  }
  initMapPoolEditor();

'''
        if needle not in s: raise RuntimeError('JS insertion point missing')
        s=s.replace(needle,block+needle,1)
    p.write_text(s,'utf-8'); return s!=orig


def patch_css(path):
    p=Path(path); s=p.read_text('utf-8'); orig=s
    if '.map-pool-editor{' not in s:
        s += r'''
.map-pool-editor{margin-bottom:16px;padding:16px;border:1px solid #29405f;border-radius:14px;background:linear-gradient(145deg,#0b1829,#0a1422)}.map-pool-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:13px}.map-pool-head h3{margin:0;font-size:16px}.map-pool-head h3 i{color:#7ba2ff;margin-right:7px}.map-pool-head p{margin:5px 0 0;color:var(--muted);font-size:12px}.map-pool-count{white-space:nowrap;padding:7px 10px;border-radius:999px;border:1px solid #304968;background:#0d1b2d;color:#91a8c3;font-size:11px}.map-pool-count b{color:#c5d7ff}.map-pool-tools{display:grid;grid-template-columns:minmax(220px,1fr) auto auto;gap:8px;margin-bottom:10px}.map-pool-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(175px,1fr));gap:8px;max-height:360px;overflow:auto;padding:2px}.map-pool-item{margin:0;cursor:pointer}.map-pool-item input{position:absolute;opacity:0;pointer-events:none}.map-pool-item>span{display:block;padding:11px 12px;border:1px solid #233853;border-radius:11px;background:#0a1523;transition:.15s}.map-pool-item>span i{color:#607d9e;margin-right:6px}.map-pool-item b{font-size:12px}.map-pool-item small{display:block;margin-top:5px;color:#687e98;font-size:10px}.map-pool-item:hover>span{border-color:#43638e}.map-pool-item.selected>span,.map-pool-item input:checked+span{border-color:#4f7dff;background:rgba(79,125,255,.12);box-shadow:0 0 0 1px rgba(79,125,255,.1) inset}.map-pool-item.selected>span i,.map-pool-item input:checked+span i{color:#86a7ff}.map-pool-item input:checked+span small{color:#73d99a}.map-pool-footer{display:grid;grid-template-columns:minmax(180px,260px) 1fr auto;gap:12px;align-items:end;margin-top:13px;padding-top:13px;border-top:1px solid #1f324b}.map-pool-footer label{margin:0}.map-pool-note{display:flex;gap:8px;align-items:center;color:#8197b1;font-size:11px;padding-bottom:8px}.map-pool-note i{color:#65d68c}.map-pool-readonly{display:flex;flex-wrap:wrap;gap:7px}.map-pool-readonly span{padding:6px 9px;border-radius:8px;background:#11223a;border:1px solid #29405f;color:#b9cbff;font-size:11px}@media(max-width:900px){.map-pool-footer{grid-template-columns:1fr}.map-pool-tools{grid-template-columns:1fr 1fr}.map-pool-tools .map-search{grid-column:1/-1}}@media(max-width:600px){.map-pool-head{flex-direction:column}.map-pool-tools{grid-template-columns:1fr}.map-pool-tools .map-search{grid-column:auto}.map-pool-grid{grid-template-columns:1fr 1fr}.map-pool-footer .btn{width:100%}}
'''
    p.write_text(s,'utf-8'); return s!=orig

if __name__=='__main__':
    root=Path(sys.argv[1])
    patch_ctl(root/'cs16-panel/bin/hyper-cs16-ctl')
    patch_index(root/'cs16-panel/public/index.php')
    patch_js(root/'cs16-panel/public/assets/app.js')
    patch_css(root/'cs16-panel/public/assets/style.css')
    print('OK')

PY

echo "[1/7] Backing up controller + repository UI..."
cp -a "$LIVE_CTL" "$BACKUP/live-hyper-cs16-ctl"
cp -a "$REPO/cs16-panel/bin/hyper-cs16-ctl" "$BACKUP/repo-hyper-cs16-ctl"
cp -a "$REPO/cs16-panel/public/index.php" "$BACKUP/index.php"
cp -a "$REPO/cs16-panel/public/assets/app.js" "$BACKUP/app.js"
cp -a "$REPO/cs16-panel/public/assets/style.css" "$BACKUP/style.css"

echo
echo "[2/7] Patching repository files..."
python3 "$PATCHER" "$REPO" || die "Repository map-pool patch failed"

echo
echo "[3/7] Patching LIVE controller without removing v3.14/runtime fixes..."
python3 - "$PATCHER" "$LIVE_CTL" <<'PY'
import importlib.util, sys
from pathlib import Path

patcher=Path(sys.argv[1])
target=Path(sys.argv[2])
spec=importlib.util.spec_from_file_location("hh_map_pool_patch",patcher)
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.patch_ctl(target)
print("[PATCHED]",target)
PY

python3 -m py_compile "$LIVE_CTL" || {
  cp -a "$BACKUP/live-hyper-cs16-ctl" "$LIVE_CTL"
  die "Live controller syntax check failed; restored"
}

echo
echo "[4/7] Discovering active web panel document roots..."

ROOT_FILE="$(mktemp)"
NGTMP="$(mktemp)"
trap 'rm -f "$PATCHER" "$ROOT_FILE" "$NGTMP"' EXIT

# Canonical/current known root if present.
for root in   "/var/www/hyper-host-sites/$DOMAIN/public_html"   "/var/www/$DOMAIN/public_html"   "/var/www/$DOMAIN"
do
  [[ -f "$root/index.php" ]] && echo "$root" >>"$ROOT_FILE"
done

# Active nginx roots for the domain.
if command -v nginx >/dev/null 2>&1; then
  nginx -T >"$NGTMP" 2>&1 || true
  python3 - "$NGTMP" "$DOMAIN" >>"$ROOT_FILE" <<'PY'
import re,sys
text=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
domain=sys.argv[2]
for block in re.findall(r'server\s*\{.*?\n\}',text,re.S):
    if domain not in block:
        continue
    for root in re.findall(r'(?m)^\s*root\s+([^;]+);',block):
        root=root.strip()
        if root.startswith('/'):
            print(root)
PY
fi

# Fallback: only panels that contain the CS16 server UI markers.
while IFS= read -r idx; do
  grep -q "serverTabs" "$idx" 2>/dev/null || continue
  grep -q "page==='server'" "$idx" 2>/dev/null || continue
  echo "$(dirname "$idx")" >>"$ROOT_FILE"
done < <(find /var/www -xdev -type f -name index.php 2>/dev/null || true)

sort -u "$ROOT_FILE" -o "$ROOT_FILE"

ROOT_COUNT=0
while IFS= read -r DOCROOT; do
  [[ -n "$DOCROOT" ]] || continue
  [[ -f "$DOCROOT/index.php" ]] || continue
  [[ -f "$DOCROOT/assets/app.js" ]] || continue
  [[ -f "$DOCROOT/assets/style.css" ]] || continue
  grep -q "serverTabs" "$DOCROOT/index.php" || continue

  ROOT_COUNT=$((ROOT_COUNT+1))
  SAFE_NAME="$(printf '%s' "$DOCROOT" | sed 's#^/##;s#/#__#g')"
  mkdir -p "$BACKUP/web-$SAFE_NAME/assets"
  cp -a "$DOCROOT/index.php" "$BACKUP/web-$SAFE_NAME/index.php"
  cp -a "$DOCROOT/assets/app.js" "$BACKUP/web-$SAFE_NAME/assets/app.js"
  cp -a "$DOCROOT/assets/style.css" "$BACKUP/web-$SAFE_NAME/assets/style.css"

  python3 - "$PATCHER" "$DOCROOT" <<'PY'
import importlib.util,sys
from pathlib import Path

patcher=Path(sys.argv[1])
root=Path(sys.argv[2])
spec=importlib.util.spec_from_file_location("hh_map_pool_patch",patcher)
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.patch_index(root/'index.php')
m.patch_js(root/'assets/app.js')
m.patch_css(root/'assets/style.css')
print("[PATCHED WEB]",root)
PY

  php -l "$DOCROOT/index.php" >/dev/null || die "PHP syntax error: $DOCROOT/index.php"
  if command -v node >/dev/null 2>&1; then
    node --check "$DOCROOT/assets/app.js" >/dev/null || die "JS syntax error: $DOCROOT/assets/app.js"
  fi
done <"$ROOT_FILE"

[[ "$ROOT_COUNT" -gt 0 ]] || die "No active CS16 panel document root was found"

echo "[OK] Patched $ROOT_COUNT live panel root(s)"

echo
echo "[5/7] Validating repository UI..."
php -l "$REPO/cs16-panel/public/index.php" >/dev/null || die "Repository index.php syntax error"
if command -v node >/dev/null 2>&1; then
  node --check "$REPO/cs16-panel/public/assets/app.js" >/dev/null || die "Repository app.js syntax error"
fi
python3 -m py_compile "$REPO/cs16-panel/bin/hyper-cs16-ctl" || die "Repository controller syntax error"

grep -q "map-pool-set" "$LIVE_CTL" || die "map-pool-set command missing from live controller"
grep -q "mapPoolForm" "$REPO/cs16-panel/public/index.php" || die "Map pool UI missing"
grep -q "HYPER-HOST v3.15 MAP POOL" "$LIVE_CTL" || die "v3.15 controller marker missing"

echo "[OK] PHP / JS / Python validation passed"

echo
echo "[6/7] Reloading PHP-FPM caches..."
while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*fpm/ {print $1}')

echo
echo "[7/7] Current map inventory for server #$SID..."
if [[ "$SID" =~ ^[0-9]+$ ]] && [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  "$LIVE_CTL" maps "$SID" || true
else
  echo "[INFO] Server #$SID does not exist yet; feature is installed for future servers."
fi

echo
echo "============================================================"
echo " v3.15 MAP POOL INSTALLED"
echo "============================================================"
echo "Open server -> Карты."
echo "You can now:"
echo " - check only allowed REAL .bsp maps"
echo " - choose the startup map"
echo " - save the pool"
echo " - use only allowed maps in quick map / map tab / config-set"
echo " - mapcycle.txt and AMXX maps.ini are synchronized automatically"
echo
echo "Future assembly swaps reconcile the saved pool with maps that actually exist."
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
