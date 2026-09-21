#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.21 — OPTIONAL FILE SKIP / BAD PLUGIN QUARANTINE
#
# Requires the current v3.20 adaptive runtime controller.
#
# Future assembly install behavior:
# - missing AMXX plugin files referenced by plugins*.ini are commented out;
# - case-only filename mismatches are repaired for Linux;
# - missing optional third-party Metamod .so references are commented out;
# - a non-core AMXX plugin reported as Invalid Plugin is quarantined once and
#   the server is restarted; if that restart fails, the config is restored;
# - Zombie Plague core plugins are never auto-quarantined;
# - harmless "stock AMXX module already loaded" Metamod noise is not reported
#   as an assembly error;
# - stale +managed-runtime-v316 text is removed from future import labels;
# - AMXX summary no longer prints impossible X/Y counts.
#
# Usage:
#   bash apply-cs16-v3.21-skip-missing-files.sh 17

SID="${1:-17}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
REPO_INDEX="$REPO/cs16-panel/public/index.php"
PATCH_ONLY="${PATCH_ONLY:-0}"
DOMAIN="www.avito.hyper-host.pw"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.21-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.21-${STAMP}.log"
PATCHER="$(mktemp /tmp/hh-v321.XXXXXX.py)"
ROOTS="$(mktemp /tmp/hh-v321-roots.XXXXXX)"
NGTMP="$(mktemp /tmp/hh-v321-nginx.XXXXXX)"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

cleanup() { rm -f "$PATCHER" "$ROOTS" "$NGTMP" 2>/dev/null || true; }
trap cleanup EXIT

die() {
  echo
  echo "[ERROR] $*"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backup: $BACKUP"
  exit 1
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local safe
  safe="$(printf '%s' "$f" | sed 's#^/##;s#/#__#g')"
  cp -a "$f" "$BACKUP/$safe"
}

echo "============================================================"
echo " HYPER-HOST CS16 v3.21 — SKIP MISSING FILES"
echo "============================================================"
echo "Server:     $SID"
echo "Live ctl:   $LIVE_CTL"
echo "Repo:       $REPO"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"
[[ -f "$REPO_INDEX" ]] || die "Repository index.php not found: $REPO_INDEX"
grep -q "def _v320_prepare_runtime" "$LIVE_CTL" || die "v3.20 adaptive runtime is not installed in live controller"

cat >"$PATCHER" <<'PY_V321'
from __future__ import annotations
import os, re, sys, py_compile
from pathlib import Path

MARKER = '# >>> HYPER-HOST v3.21 OPTIONAL FILE SANITIZER >>>'

HELPER = r'''
# >>> HYPER-HOST v3.21 OPTIONAL FILE SANITIZER >>>
def _v321_plugin_config_files(cstrike:Path)->list[Path]:
    cfg=cstrike/'addons/amxmodx/configs'
    if not cfg.is_dir(): return []
    out=[]
    main=cfg/'plugins.ini'
    if main.is_file(): out.append(main)
    out += sorted(
        (p for p in cfg.glob('plugins-*.ini') if p.is_file() and not p.name.startswith('disabled-')),
        key=lambda p:p.name.lower()
    )
    return out


def _v321_is_critical_plugin(name:str)->bool:
    n=Path(str(name)).name.lower().strip()
    return bool(
        re.fullmatch(r'zombie_plague(?:40|4[._-]?3)?[.]amxx',n) or
        n in {'zp_core.amxx','zp50_core.amxx','zombie_plague.amxx'}
    )


def _v321_skip_missing_optional_refs(server_root:Path)->dict:
    cstrike=server_root/'cstrike'
    plugdir=cstrike/'addons/amxmodx/plugins'
    missing_plugins=[]; case_fixed=[]; missing_meta=[]; changed_files=[]; actions=[]

    actual={}
    if plugdir.is_dir():
        for p in plugdir.iterdir():
            if p.is_file() and p.suffix.lower()=='.amxx':
                actual.setdefault(p.name.lower(),p.name)

    for cfg in _v321_plugin_config_files(cstrike):
        raw=cfg.read_bytes().replace(b'\r\n',b'\n').replace(b'\r',b'\n').decode('latin1','ignore')
        out=[]; changed=False
        for line in raw.splitlines():
            st=line.strip()
            if not st or st.startswith((';','//','#')):
                out.append(line); continue
            body=re.split(r'\s*(?:;|//)',st,maxsplit=1)[0].strip()
            parts=body.split()
            token=(parts[0].strip('"') if parts else '')
            if not token.lower().endswith('.amxx'):
                out.append(line); continue
            # Only a filename under addons/amxmodx/plugins is accepted here.
            name=Path(token.replace('\\','/')).name
            exact=plugdir/name
            if exact.is_file():
                out.append(line); continue
            alt=actual.get(name.lower())
            if alt:
                # Linux is case-sensitive. Repair only the token, preserving flags/comments.
                idx=line.find(token)
                if idx>=0:
                    line=line[:idx]+alt+line[idx+len(token):]
                    changed=True; case_fixed.append({'config':cfg.name,'from':token,'to':alt})
                out.append(line); continue
            out.append('; HYPER-HOST v3.21 skipped missing plugin: '+line)
            changed=True
            missing_plugins.append({'config':cfg.name,'plugin':name,'critical':_v321_is_critical_plugin(name)})
        if changed:
            cfg.write_bytes(('\n'.join(out).rstrip()+'\n').encode('latin1','replace'))
            changed_files.append(str(cfg.relative_to(cstrike)))

    # Optional third-party Metamod references: if the referenced .so does not
    # exist, comment the line instead of making preflight/runtime noisy. AMXX
    # itself is not optional and is intentionally left for adaptive repair.
    mp=cstrike/'addons/metamod/plugins.ini'
    if mp.is_file():
        raw=mp.read_bytes().replace(b'\r\n',b'\n').replace(b'\r',b'\n').decode('latin1','ignore')
        out=[]; changed=False
        for line in raw.splitlines():
            st=line.strip()
            if not st or st.startswith((';','//','#')):
                out.append(line); continue
            m=re.search(r'(?i)^linux(?:32)?\s+([^\s]+[.]so)\b',st)
            if not m:
                out.append(line); continue
            rel=m.group(1).replace('\\','/').lstrip('/')
            if '..' in Path(rel).parts:
                out.append(line); continue
            if (cstrike/rel).is_file() or 'amxmodx' in rel.lower():
                out.append(line); continue
            out.append('; HYPER-HOST v3.21 skipped missing Metamod plugin: '+line)
            changed=True; missing_meta.append(rel)
        if changed:
            mp.write_bytes(('\n'.join(out).rstrip()+'\n').encode('latin1','replace'))
            changed_files.append(str(mp.relative_to(cstrike)))

    if missing_plugins:
        actions.append('skipped '+str(len(missing_plugins))+' missing AMXX plugin reference(s)')
    if case_fixed:
        actions.append('fixed '+str(len(case_fixed))+' case-sensitive AMXX plugin filename(s)')
    if missing_meta:
        actions.append('skipped '+str(len(missing_meta))+' missing optional Metamod plugin reference(s)')

    return {
        'ok':True,
        'missing_plugins':missing_plugins,
        'case_fixed_plugins':case_fixed,
        'missing_metamod_plugins':missing_meta,
        'changed_files':list(dict.fromkeys(changed_files)),
        'actions':actions,
    }


def _v321_invalid_plugin_names(report:dict)->list[str]:
    names=[]
    for line in list(report.get('plugin_errors') or []):
        for pat in (
            r'Invalid Plugin\s*\(plugin\s+"([^"]+[.]amxx)"\)',
            r'Plugin file open error\s*\(plugin\s+"([^"]+[.]amxx)"\)',
        ):
            m=re.search(pat,str(line),re.I)
            if m:
                name=Path(m.group(1)).name
                if not _v321_is_critical_plugin(name): names.append(name)
    return list(dict.fromkeys(names))


def _v321_quarantine_plugins(server_root:Path,names:list[str],reason:str='invalid plugin')->dict:
    cstrike=server_root/'cstrike'; wanted={Path(x).name.lower() for x in names if x}
    if not wanted: return {'ok':True,'plugins':[],'changed_files':[]}
    changed_files=[]; disabled=[]
    for cfg in _v321_plugin_config_files(cstrike):
        raw=cfg.read_bytes().replace(b'\r\n',b'\n').replace(b'\r',b'\n').decode('latin1','ignore')
        out=[]; changed=False
        for line in raw.splitlines():
            st=line.strip()
            if not st or st.startswith((';','//','#')):
                out.append(line); continue
            body=re.split(r'\s*(?:;|//)',st,maxsplit=1)[0].strip()
            parts=body.split(); token=(parts[0].strip('"') if parts else '')
            name=Path(token.replace('\\','/')).name.lower()
            if name in wanted:
                out.append('; HYPER-HOST v3.21 quarantined '+reason+': '+line)
                changed=True; disabled.append(Path(token).name)
            else:
                out.append(line)
        if changed:
            cfg.write_bytes(('\n'.join(out).rstrip()+'\n').encode('latin1','replace'))
            changed_files.append(str(cfg.relative_to(cstrike)))
    return {'ok':True,'plugins':list(dict.fromkeys(disabled)),'changed_files':changed_files}


def _v321_quarantine_runtime_bad_plugins(sid:int,c:dict,path:Path,report:dict)->dict:
    names=_v321_invalid_plugin_names(report)
    if not names:
        return {'ok':True,'changed':False,'plugins':[],'report':report,'start_mark':None}

    cfgs=_v321_plugin_config_files(path/'cstrike')
    snapshots={str(p):p.read_bytes() for p in cfgs if p.is_file()}
    q=_v321_quarantine_plugins(path,names,'invalid optional plugin')
    if not q.get('plugins'):
        return {'ok':True,'changed':False,'plugins':[],'report':report,'start_mark':None}

    mark=time.time()
    run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
    run(['systemctl','restart',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
    ok,detail=wait_server_ready(load_server(sid),45.0)
    if not ok:
        for name,data in snapshots.items():
            try: Path(name).write_bytes(data)
            except Exception: pass
        run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
        run(['systemctl','restart',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
        wait_server_ready(load_server(sid),35.0)
        return {'ok':False,'changed':False,'plugins':[], 'error':'quarantine restart failed: '+str(detail), 'report':report,'start_mark':None}

    time.sleep(1.5)
    det=_detect_mod_profile_at(path)
    new_report=_runtime_mod_report(load_server(sid),bool(det.get('zp_active')),int(det.get('active_plugin_count') or 0))
    return {
        'ok':True,'changed':True,'plugins':q.get('plugins') or [],
        'report':new_report,'detected':det,'start_mark':mark,
    }


def build_sanitize_optional(sid:int):
    require_root(); c=load_server(sid); path=safe_server_path(sid)
    if not path.is_dir(): raise RuntimeError('Current server directory is missing')
    backup_root=path.parent/BUILD_BACKUP_DIR_NAME; backup_root.mkdir(parents=True,exist_ok=True)
    token=secrets.token_hex(5)
    backup=backup_root/f'{sid}-before-optional-sanitize-{time.strftime("%Y%m%d-%H%M%S")}-{token}'
    # Only configuration files are modified by this action, but a small full
    # backup makes the manual repair reversible exactly like build installs.
    run(['rsync','-a',str(path)+'/',str(backup)+'/'],timeout=1800)

    refs=_v321_skip_missing_optional_refs(path)
    normalize_permissions(path)
    mark=time.time()
    run(['systemctl','reset-failed',f'hyper-cs16@{sid}.service'],check=False)
    run(['systemctl','restart',f'hyper-cs16@{sid}.service'],check=False,timeout=60)
    ok,detail=wait_server_ready(load_server(sid),45.0)
    if not ok:
        return {'ok':False,'id':sid,'backup':str(backup),'references':refs,'error':'server did not return after optional-file sanitize: '+str(detail)}
    time.sleep(1.5)
    det=_detect_mod_profile_at(path)
    report=_runtime_mod_report(load_server(sid),bool(det.get('zp_active')),int(det.get('active_plugin_count') or 0))
    quarantine=_v321_quarantine_runtime_bad_plugins(sid,load_server(sid),path,report)
    if quarantine.get('changed'):
        report=quarantine.get('report') or report
        det=quarantine.get('detected') or _detect_mod_profile_at(path)
        mark=float(quarantine.get('start_mark') or mark)
    errors=_runtime_error_lines(sid,260,mark)
    c=load_server(sid)
    configured=int(det.get('active_plugin_count') or 0)
    runtime_total=int(report.get('runtime_plugin_total') or 0)
    runtime_running=int(report.get('runtime_plugin_running') or 0)
    c['custom_build_expected_plugins']=configured
    c['custom_build_runtime_plugins']=runtime_total
    c['custom_build_runtime_running']=runtime_running
    old_mode=str(c.get('custom_build_import_mode') or '')
    if old_mode:
        old_mode=old_mode.replace('+managed-runtime-v316','')
        if '+skip-missing-v321' not in old_mode:
            old_mode += '+skip-missing-v321'
        c['custom_build_import_mode']=old_mode
    save_server(c)
    return {
        'ok':True,'id':sid,'backup':str(backup),'references':refs,
        'quarantined_plugins':quarantine.get('plugins') or [],
        'runtime_mod':report,'runtime_errors':errors,
        'configured_plugins':configured,
        'runtime_plugins':runtime_total,
        'runtime_running':runtime_running,
        'import_mode':old_mode,
    }
# <<< HYPER-HOST v3.21 OPTIONAL FILE SANITIZER <<<
'''


def fn_slice(src:str,name:str):
    st=src.find('def '+name+'(')
    if st<0: return -1,-1,''
    en=src.find('\ndef ',st+10)
    if en<0: en=len(src)
    return st,en,src[st:en]


def patch_ctl(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src
    if 'def _v320_prepare_runtime(' not in src:
        raise RuntimeError('v3.21 requires the installed v3.20 adaptive runtime controller')

    if MARKER not in src:
        pos=src.find('\ndef install_custom_build(')
        if pos<0: raise RuntimeError('install_custom_build not found')
        src=src[:pos]+'\n'+HELPER+src[pos:]

    st,en,fn=fn_slice(src,'install_custom_build')
    if st<0: raise RuntimeError('install_custom_build not found after helper insert')

    if 'optional_refs=_v321_skip_missing_optional_refs(stage)' not in fn:
        anchor='        plugin_comment_fix=_normalize_plugin_comment_syntax(stage)\n'
        if anchor not in fn: raise RuntimeError('plugin_comment_fix anchor missing')
        fn=fn.replace(anchor,anchor+'        optional_refs=_v321_skip_missing_optional_refs(stage)\n',1)

    fn=fn.replace('        plugin_repairs=[]; module_repairs={}; metamod_repairs={}\n',
                  "        plugin_repairs=list(optional_refs.get('actions') or []); module_repairs={}; metamod_repairs={}\n",1)

    # The old v3.16 suffix is stale and misleading under adaptive runtime.
    fn=fn.replace("        import_mode=import_mode+'+managed-runtime-v316'\n",'')
    if '+skip-missing-v321' not in fn:
        anchor="        import_mode=import_mode+'+runtime-v320-'+str(platform_runtime.get('policy',{}).get('engine','auto'))+'-'+str(platform_runtime.get('policy',{}).get('metamod','auto'))+'-'+str(platform_runtime.get('policy',{}).get('amxx','auto'))\n"
        if anchor not in fn: raise RuntimeError('runtime-v320 import_mode anchor missing')
        fn=fn.replace(anchor,anchor+"        import_mode=import_mode+'+skip-missing-v321'\n",1)

    # Quarantine non-core Invalid Plugin entries once, with rollback if restart fails.
    report_anchor="        runtime_report=_runtime_mod_report(c,bool(detected.get('zp_active')),int(detected.get('active_plugin_count') or 0))\n"
    if 'quarantine_optional=_v321_quarantine_runtime_bad_plugins' not in fn:
        if report_anchor not in fn: raise RuntimeError('runtime_report anchor missing')
        insert=(
            report_anchor+
            "        quarantine_optional=_v321_quarantine_runtime_bad_plugins(sid,c,path,runtime_report)\n"
            "        quarantined_plugins=list(quarantine_optional.get('plugins') or [])\n"
            "        if quarantine_optional.get('changed'):\n"
            "            runtime_report=quarantine_optional.get('report') or runtime_report\n"
            "            detected=quarantine_optional.get('detected') or _detect_mod_profile_at(path)\n"
            "            if quarantine_optional.get('start_mark'): start_mark=float(quarantine_optional.get('start_mark'))\n"
        )
        fn=fn.replace(report_anchor,insert,1)

    # Surface sanitize results in successful install payload.
    if "'optional_refs':optional_refs" not in fn:
        anchor="                'plugin_comment_fix':plugin_comment_fix,'zp_repairs':zp_repairs,'text_normalization':text_normalization,\n"
        if anchor not in fn: raise RuntimeError('result payload anchor missing')
        repl=(
            "                'plugin_comment_fix':plugin_comment_fix,'optional_refs':optional_refs,"\
            "'skipped_missing_files':[x.get('plugin','') for x in optional_refs.get('missing_plugins',[]) if x.get('plugin')],"\
            "'skipped_missing_metamod':optional_refs.get('missing_metamod_plugins',[]),"\
            "'quarantined_plugins':quarantined_plugins,'zp_repairs':zp_repairs,'text_normalization':text_normalization,\n"
        )
        fn=fn.replace(anchor,repl,1)

    src=src[:st]+fn+src[en:]

    # Filter known-benign stock AMXX module duplicate messages from the warning summary.
    st,en,fn=fn_slice(src,'_runtime_error_lines')
    if st<0: raise RuntimeError('_runtime_error_lines not found')
    old="""    for ln in text.splitlines():\n        low=ln.lower()\n        if any(x in low for x in pats): out.append(ln.strip())\n"""
    if 'benign_stock_duplicates' not in fn:
        if old not in fn: raise RuntimeError('_runtime_error_lines loop anchor missing')
        new="""    benign_stock_duplicates={\n        'fun':'fun_amxx_i386.so','engine':'engine_amxx_i386.so','fakemeta':'fakemeta_amxx_i386.so',\n        'geoip':'geoip_amxx_i386.so','cstrike':'cstrike_amxx_i386.so','csx':'csx_amxx_i386.so',\n        'ham sandwich':'hamsandwich_amxx_i386.so','mysql':'mysql_amxx_i386.so',\n    }\n    lowtext=text.lower()\n    for ln in text.splitlines():\n        low=ln.lower()\n        if '[meta] error:' in low and 'already loaded (status=running)' in low:\n            continue\n        if '[meta] error:' in low and 'failed to load plugin' in low:\n            matched=False\n            for mod,so in benign_stock_duplicates.items():\n                if so in low and (\"not loading plugin '\"+mod+\"'; already loaded (status=running)\") in lowtext:\n                    matched=True; break\n            if matched: continue\n        if any(x in low for x in pats): out.append(ln.strip())\n"""
        fn=fn.replace(old,new,1)
        src=src[:st]+fn+src[en:]

    # CLI current-server sanitizer.
    list_old="'build-repair-current','mods-status','runtime-status'"
    if "'build-sanitize-optional'" not in src:
        if list_old not in src: raise RuntimeError('CLI list anchor missing')
        src=src.replace(list_old,"'build-repair-current','build-sanitize-optional','mods-status','runtime-status'",1)
    branch="        elif args.cmd=='build-repair-current': result=build_repair_current(args.id)\n"
    if "args.cmd=='build-sanitize-optional'" not in src:
        if branch not in src: raise RuntimeError('CLI branch anchor missing')
        src=src.replace(branch,branch+"        elif args.cmd=='build-sanitize-optional': result=build_sanitize_optional(args.id)\n",1)

    required=[
        MARKER,
        'optional_refs=_v321_skip_missing_optional_refs(stage)',
        'quarantine_optional=_v321_quarantine_runtime_bad_plugins',
        '+skip-missing-v321',
        "'skipped_missing_files'",
        "'build-sanitize-optional'",
        'benign_stock_duplicates',
    ]
    missing=[x for x in required if x not in src]
    if missing: raise RuntimeError('v3.21 controller verification failed: '+repr(missing))

    tmp=path.with_name(path.name+'.v321tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    py_compile.compile(str(tmp),doraise=True)
    os.replace(tmp,path)
    print('[PATCHED]',path)


def patch_index(path:Path):
    src=path.read_text(encoding='utf-8',errors='surrogateescape')
    original=src
    # Replace impossible runp/cfgp fraction with explicit runtime/config counts.
    src=src.replace(
        "($cfgp>0?' AMXX: '.$runp.'/'.$cfgp.' загружено, '.$running.' running.':'')",
        "(($runp>0||$cfgp>0)?' AMXX: '.$running.' running из '.$runp.' записей; активных файлов в конфиге: '.$cfgp.'.':'')"
    )
    # Append informational, non-warning notes for skipped/quarantined optional files.
    marker="$warn=trim((string)($r['warning']??''));"
    info=(
        "$skipMissing=is_array($r['skipped_missing_files']??null)?array_values(array_filter($r['skipped_missing_files'])):[];"
        "$skipMeta=is_array($r['skipped_missing_metamod']??null)?array_values(array_filter($r['skipped_missing_metamod'])):[];"
        "$quarantine=is_array($r['quarantined_plugins']??null)?array_values(array_filter($r['quarantined_plugins'])):[];"
    )
    if '$skipMissing=' not in src:
        src=src.replace(marker,marker+info)
    # Add info to both upload and URL messages before critical/warn handling.
    needle="if(!$healthy)$msg.=' Сборка оставлена установленной, но runtime требует внимания'"
    inject=(
        "if($skipMissing)$msg.=' Пропущены отсутствующие AMXX-файлы: '.implode(', ',array_slice($skipMissing,0,12)).'.';"
        "if($skipMeta)$msg.=' Пропущены отсутствующие Metamod-файлы: '.implode(', ',array_slice($skipMeta,0,8)).'.';"
        "if($quarantine)$msg.=' Автоматически отключены повреждённые необязательные плагины: '.implode(', ',array_slice($quarantine,0,12)).'.';"
    )
    if 'Пропущены отсутствующие AMXX-файлы' not in src:
        src=src.replace(needle,inject+needle)
    # If one occurrence got injected and the second remains, replace it too.
    if src.count('Пропущены отсутствующие AMXX-файлы')==1 and src.count(needle)>=1:
        src=src.replace(needle,inject+needle,1)

    tmp=path.with_name(path.name+'.v321tmp')
    tmp.write_text(src,encoding='utf-8',errors='surrogateescape')
    os.chmod(tmp,path.stat().st_mode)
    os.replace(tmp,path)
    print('[PATCHED]',path)


def main():
    if len(sys.argv)!=3:
        raise SystemExit('usage: patch_v321.py ctl|index PATH')
    mode=sys.argv[1]; path=Path(sys.argv[2])
    if mode=='ctl': patch_ctl(path)
    elif mode=='index': patch_index(path)
    else: raise SystemExit('unknown mode')

if __name__=='__main__': main()

PY_V321

python3 -m py_compile "$PATCHER" || die "Internal v3.21 patcher syntax error"

echo "[1/7] Backing up controller and repository panel..."
backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"
backup_file "$REPO_INDEX"

echo
echo "[2/7] Patching LIVE controller..."
python3 "$PATCHER" ctl "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller Python syntax failed"

echo "[OK] live controller patched"

echo
echo "[3/7] Synchronizing verified controller to repository..."
install -m 0755 "$LIVE_CTL" "$REPO_CTL"
python3 -m py_compile "$REPO_CTL" || die "Repository controller Python syntax failed"
python3 "$PATCHER" index "$REPO_INDEX" || die "Repository index patch failed"
php -l "$REPO_INDEX" >/dev/null || die "Repository index.php syntax failed"

echo "[OK] repository controller + panel patched"

if [[ "$PATCH_ONLY" == "1" ]]; then
  echo
  echo "============================================================"
  echo " v3.21 PATCH-ONLY VALIDATION OK"
  echo "============================================================"
  exit 0
fi

echo
echo "[4/7] Discovering active CS16 panel roots..."
for root in   "/var/www/hyper-host-sites/$DOMAIN/public_html"   "/var/www/$DOMAIN/public_html"   "/var/www/$DOMAIN"
do
  [[ -f "$root/index.php" ]] && echo "$root" >>"$ROOTS"
done

if command -v nginx >/dev/null 2>&1; then
  nginx -T >"$NGTMP" 2>&1 || true
  python3 - "$NGTMP" "$DOMAIN" >>"$ROOTS" <<'PY_ROOTS'
import re,sys
text=open(sys.argv[1],encoding='utf-8',errors='ignore').read(); domain=sys.argv[2]
for block in re.findall(r'server\s*\{.*?\n\}',text,re.S):
    if domain not in block: continue
    for root in re.findall(r'(?m)^\s*root\s+([^;]+);',block):
        root=root.strip()
        if root.startswith('/'): print(root)
PY_ROOTS
fi

while IFS= read -r idx; do
  grep -q "serverTabs" "$idx" 2>/dev/null || continue
  grep -q "page==='server'" "$idx" 2>/dev/null || continue
  echo "$(dirname "$idx")" >>"$ROOTS"
done < <(find /var/www -xdev -type f -name index.php 2>/dev/null || true)

sort -u "$ROOTS" -o "$ROOTS"
COUNT=0
while IFS= read -r DOCROOT; do
  [[ -n "$DOCROOT" ]] || continue
  [[ -f "$DOCROOT/index.php" ]] || continue
  grep -q "serverTabs" "$DOCROOT/index.php" || continue
  COUNT=$((COUNT+1))
  backup_file "$DOCROOT/index.php"
  python3 "$PATCHER" index "$DOCROOT/index.php" || die "Panel patch failed: $DOCROOT"
  php -l "$DOCROOT/index.php" >/dev/null || die "PHP syntax failed: $DOCROOT/index.php"
  echo "[PATCHED PANEL] $DOCROOT"
done <"$ROOTS"
[[ "$COUNT" -gt 0 ]] || die "No active CS16 panel root found"

echo "[OK] patched $COUNT active panel root(s)"

echo
echo "[5/7] Reloading PHP-FPM..."
while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*fpm/ {print $1}')

echo
echo "[6/7] Sanitizing already-installed server #$SID..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  set +e
  SAN_OUT="$("$LIVE_CTL" build-sanitize-optional "$SID" 2>&1)"
  SAN_RC=$?
  set -e
  echo "$SAN_OUT"
  if [[ "$SAN_RC" -ne 0 ]]; then
    echo "[WARN] v3.21 is installed, but current-server sanitize returned an error."
  else
    echo "[OK] current server optional files sanitized"
  fi
else
  echo "[INFO] Server #$SID does not exist; future uploads are already covered."
fi

echo
echo "[7/7] Current AMXX/mod status..."
if [[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]]; then
  "$LIVE_CTL" mods-status "$SID" || true
fi

echo
cat <<'EOF_SUMMARY'
============================================================
 v3.21 INSTALLED SUCCESSFULLY
============================================================
Future assembly uploads now treat missing OPTIONAL references like this:
 - missing plugins*.ini .amxx -> comment/skip, not a bad-load error
 - filename differs only by case -> repair the filename for Linux
 - missing optional Metamod .so -> comment/skip
 - non-core Invalid Plugin -> quarantine once; rollback quarantine if restart fails
 - Zombie Plague core -> NEVER auto-disabled

Critical engine/GameDLL/Metamod/AMXX core files are NOT silently skipped.
EOF_SUMMARY
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
