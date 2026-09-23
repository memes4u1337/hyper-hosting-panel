#!/usr/bin/env bash
set -Eeuo pipefail

# OLD ZOMBIE / HYPER-HOST - FASTJOIN v1
# Safe first-join optimizer for CS 1.6 server #25.
# It keeps custom V models/gameplay, removes avoidable client resources,
# fixes broken M82 paths, and improves FastDL .bz2 packing.

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run with sudo/root'; exit 1; }

SID="${1:-25}"
REPO="${2:-/root/hyper-hosting-panel}"
SERVER="/srv/hyper-cs16/servers/${SID}"
CSTRIKE="$SERVER/cstrike"
AMXX="$CSTRIKE/addons/amxmodx"
CFG="$AMXX/configs"
SCRIPTING="$AMXX/scripting"
PLUGINS="$AMXX/plugins"
CTL="/usr/local/sbin/hyper-cs16-ctl"
SRC_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
BASE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$BASE/payload"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/old-zombie-fastjoin-v1-backup-${SID}-${STAMP}"
REPORT="/root/old-zombie-fastjoin-v1-${SID}-${STAMP}.txt"

exec > >(tee -a "$REPORT") 2>&1

echo '============================================================'
echo ' OLD ZOMBIE FASTJOIN v1'
echo " Server: #$SID"
echo " Root:   $CSTRIKE"
echo " Backup: $BACKUP"
echo " Report: $REPORT"
echo '============================================================'

[[ -d "$CSTRIKE" ]] || { echo "[ERROR] Missing server root: $CSTRIKE"; exit 2; }
[[ -x "$CTL" || -f "$CTL" ]] || { echo "[ERROR] Missing $CTL"; exit 2; }
mkdir -p "$BACKUP"

backup_one() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local rel="${f#/}"
  mkdir -p "$BACKUP/$(dirname "$rel")"
  cp -a "$f" "$BACKUP/$rel"
}

active_plugin() {
  local plugin="$1"
  grep -RhsE --include='plugins*.ini' '^[[:space:]]*[^;].*' "$CFG" 2>/dev/null \
    | sed -E 's/[[:space:]]*[;#].*$//' \
    | awk '{print $1}' \
    | grep -Fxiq "$plugin"
}

find_live_source() {
  local stem="$1"
  local exact="$SCRIPTING/${stem}.sma"
  if [[ -f "$exact" ]]; then printf '%s\n' "$exact"; return 0; fi
  find "$SCRIPTING" -maxdepth 1 -type f -iname "${stem}*.sma" -print 2>/dev/null | head -n1
}

apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bzip2 ffmpeg curl python3 binutils >/dev/null || true

# -----------------------------------------------------------------------------
# 1. Fix the broken M82 resource layout from the original build.
# The original archive stores these files under cstrike/sounds/, while the
# plugin asks clients for sound/weapons/m82*.wav.
# -----------------------------------------------------------------------------
echo
echo '[1/9] Fixing M82 resources...'
mkdir -p "$CSTRIKE/sound/weapons" "$CSTRIKE/models" "$CSTRIKE/sprites/cso"

for f in m82-1.wav m82_clipin1.wav m82_clipin2.wav m82_clipout1.wav m82_clipout2.wav; do
  dst="$CSTRIKE/sound/weapons/$f"
  backup_one "$dst"
  if [[ -f "$PAYLOAD/m82/sound/weapons/$f" ]]; then
    install -m 0644 "$PAYLOAD/m82/sound/weapons/$f" "$dst"
    echo "  [OK] sound/weapons/$f"
  else
    echo "  [WARN] payload missing $f"
  fi
done

for f in v_m82.mdl p_m82.mdl w_m82.mdl; do
  dst="$CSTRIKE/models/$f"
  if [[ ! -f "$dst" && -f "$PAYLOAD/m82/models/$f" ]]; then
    install -m 0644 "$PAYLOAD/m82/models/$f" "$dst"
    echo "  [RESTORED] models/$f"
  fi
done

if [[ ! -f "$CSTRIKE/sprites/weapon_m82cso.txt" && -f "$PAYLOAD/m82/sprites/weapon_m82cso.txt" ]]; then
  install -m 0644 "$PAYLOAD/m82/sprites/weapon_m82cso.txt" "$CSTRIKE/sprites/weapon_m82cso.txt"
fi
if [[ ! -f "$CSTRIKE/sprites/cso/sniper_m82.spr" && -f "$PAYLOAD/m82/sprites/cso/sniper_m82.spr" ]]; then
  install -m 0644 "$PAYLOAD/m82/sprites/cso/sniper_m82.spr" "$CSTRIKE/sprites/cso/sniper_m82.spr"
fi

# -----------------------------------------------------------------------------
# 2. Slim Zombie Plague sound precache while keeping one sound for each event.
# This removes 20+ avoidable custom files from a clean client's first join.
# -----------------------------------------------------------------------------
echo
echo '[2/9] Slimming Zombie Plague custom sound precache...'
ZPINI="$CFG/zombieplague.ini"
if [[ -f "$ZPINI" ]]; then
  backup_one "$ZPINI"
  python3 - "$ZPINI" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='surrogateescape')
repl={
'WIN HUMANS':'zombie_plague/win_humans1.wav',
'ZOMBIE INFECT':'zombie_plague/zombie_infec1.wav , scientist/c1a0_sci_catscream.wav , scientist/scream01.wav',
'ZOMBIE PAIN':'zombie_plague/zombie_pain1.wav',
'NEMESIS PAIN':'zombie_plague/nemesis_pain1.wav',
'ZOMBIE DIE':'zombie_plague/zombie_die1.wav',
'ZOMBIE IDLE':'nihilanth/nil_now_die.wav , nihilanth/nil_slaves.wav , nihilanth/nil_alone.wav',
'ROUND NEMESIS':'zombie_plague/nemesis1.wav',
'ROUND SURVIVOR':'zombie_plague/survivor1.wav',
'ROUND PLAGUE':'zombie_plague/nemesis1.wav',
'GRENADE FIRE PLAYER':'zombie_plague/zombie_burn3.wav',
'THUNDER':'zombie_plague/thunder1.wav',
}
changed=[]
for key,val in repl.items():
    pat=re.compile(r'(?m)^'+re.escape(key)+r'\s*=.*$')
    ns,n=pat.subn(f'{key} = {val}',s,count=1)
    if n:
        s=ns; changed.append(key)
p.write_text(s,encoding='utf-8',errors='surrogateescape')
print('[OK] lean sound keys:', ', '.join(changed))
PY
else
  echo '  [WARN] zombieplague.ini not found'
fi

# Standard AMXX timeleft voice can create bogus *_period.wav lookups on this build.
AMXXCFG="$CFG/amxx.cfg"
if [[ -f "$AMXXCFG" ]]; then
  backup_one "$AMXXCFG"
  if grep -qE '^[[:space:]]*amx_time_voice[[:space:]]+' "$AMXXCFG"; then
    sed -Ei 's/^[[:space:]]*amx_time_voice[[:space:]]+.*/amx_time_voice 0/' "$AMXXCFG"
  else
    printf '\n// HYPER FASTJOIN: avoid broken *_period.wav voice sentence lookups\namx_time_voice 0\n' >> "$AMXXCFG"
  fi
  echo '  [OK] amx_time_voice 0'
fi

# -----------------------------------------------------------------------------
# 3. Compile lean variants of known plugins only when they are active.
# Custom first-person V models remain. Avoidable third-person/world models are
# changed to stock CS models where the plugin logic safely permits it.
# -----------------------------------------------------------------------------
echo
echo '[3/9] Optimizing active weapon/knife precache...'
COMPILER="$SCRIPTING/amxxpc"
if [[ -f "$COMPILER" ]]; then chmod +x "$COMPILER" 2>/dev/null || true; fi

patch_source() {
  local kind="$1" src="$2" out="$3"
  python3 - "$kind" "$src" "$out" <<'PY'
from pathlib import Path
import re,sys
kind,src,out=sys.argv[1:]
s=Path(src).read_text(encoding='latin1')
orig=s
if kind=='combo':
    pairs=[
      ('client_cmd(attacker,"spk misc/zombie/damage_1000")','// HYPER FASTJOIN: duplicate custom combo sound disabled'),
      ('client_cmd(infector,"spk misc/zombie/invader")','// HYPER FASTJOIN: duplicate custom combo sound disabled'),
      ('client_cmd(killer,"spk misc/zombie/ghost_shot")','// HYPER FASTJOIN: duplicate custom combo sound disabled'),
      ('client_cmd(0,"spk misc/zombie/Ghost_Count_%i", ghost_count)','// HYPER FASTJOIN: Ghost_Count custom countdown audio disabled'),
    ]
    for a,b in pairs: s=s.replace(a,b)
elif kind=='asimov':
    s=re.sub(r'(?m)^(\s*new\s+AWP_P_MODEL[^=]*=\s*\{?\s*")[^"]+("\s*\}?\s*;?)',r'\1models/p_awp.mdl\2',s)
elif kind=='sprifle':
    s=re.sub(r'(?m)^(\s*new\s+sprifle_P_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/p_scout.mdl\2',s)
    s=re.sub(r'(?m)^(\s*new\s+sprifle_W_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/w_scout.mdl\2',s)
elif kind=='balrog':
    s=re.sub(r'(?m)^(\s*new\s+CrossBow_P_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/p_sg550.mdl\2',s)
    s=re.sub(r'(?m)^(\s*new\s+CrossBow_W_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/w_sg550.mdl\2',s)
elif kind=='akblood':
    s=re.sub(r'(?m)^(\s*new\s+aklong_P_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/p_ak47.mdl\2',s)
    s=re.sub(r'(?m)^(\s*new\s+aklong_W_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/w_ak47.mdl\2',s)
elif kind=='goldm4':
    s=re.sub(r'(?m)^(\s*new\s+M4_P_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/p_m4a1.mdl\2',s)
elif kind=='goldenak':
    s=re.sub(r'(?m)^(\s*new\s+AK_P_MODEL[^=]*=\s*")[^"]+(".*)$',r'\1models/p_ak47.mdl\2',s)
elif kind=='knife':
    s=re.sub(r'(?m)^(\s*new\s+const\s+KNIFE[1-5]_P_MODEL\[\][^=]*=\s*")[^"]+(".*)$',r'\1models/p_knife.mdl\2',s)
else:
    raise SystemExit('unknown patch kind '+kind)
if s==orig:
    print('[WARN] no source changes for',kind)
Path(out).write_text(s,encoding='latin1')
PY
}

compile_target() {
  local plugin="$1" stem="$2" kind="$3" fallback="$4"
  if ! active_plugin "$plugin"; then
    echo "  [SKIP] $plugin is not active"
    return 0
  fi
  if [[ ! -x "$COMPILER" ]]; then
    echo "  [WARN] compiler unavailable, cannot optimize $plugin"
    return 0
  fi
  local src
  src="$(find_live_source "$stem" || true)"
  if [[ -z "$src" || ! -f "$src" ]]; then
    src="$fallback"
  fi
  if [[ ! -f "$src" ]]; then
    echo "  [WARN] source missing for active $plugin"
    return 0
  fi
  backup_one "$PLUGINS/$plugin"
  [[ "$src" == "$SCRIPTING/"* ]] && backup_one "$src" || true
  local work="$SCRIPTING/.fastjoin_${stem}.sma"
  local out="/tmp/.fastjoin_${plugin}.${STAMP}.amxx"
  patch_source "$kind" "$src" "$work"
  echo "  [COMPILE] $plugin <- $(basename "$src") ($kind)"
  if (cd "$SCRIPTING" && "$COMPILER" "$work" -o"$out") >"/tmp/fastjoin-compile-${stem}.log" 2>&1; then
    if [[ -s "$out" ]]; then
      install -m 0644 "$out" "$PLUGINS/$plugin"
      cp -a "$work" "$SCRIPTING/${stem}_fastjoin.sma"
      echo "  [OK] $plugin optimized"
    else
      echo "  [WARN] compiler produced empty output for $plugin"
    fi
  else
    echo "  [WARN] compile failed for $plugin; old binary kept"
    tail -n 25 "/tmp/fastjoin-compile-${stem}.log" || true
  fi
  rm -f "$out" "$work"
}

compile_target 'combo_zombie.amxx' 'combo_zombie_1.0' 'combo' "$PAYLOAD/sources/combo_zombie_1.0.sma"
compile_target 'oldz_asimov_admin.amxx' 'oldz_asimov_admin' 'asimov' "$PAYLOAD/sources/oldz_asimov_admin.sma"
compile_target 'oldz_sprifle_vip.amxx' 'oldz_sprifle_vip' 'sprifle' "$PAYLOAD/sources/oldz_sprifle_vip.sma"
compile_target 'oldz_balrog_vip.amxx' 'oldz_balrog_vip' 'balrog' "$PAYLOAD/sources/oldz_balrog_vip.sma"
compile_target 'oldz_akblood_vip.amxx' 'oldz_akblood_vip' 'akblood' "$PAYLOAD/sources/oldz_akblood_vip.sma"
compile_target 'oldz_goldm4_vip.amxx' 'oldz_goldm4_vip' 'goldm4' "$PAYLOAD/sources/oldz_goldm4_vip.sma"
compile_target 'zp_extra_goldenak.amxx' 'zp_extra_goldenak' 'goldenak' "$PAYLOAD/sources/zp_extra_goldenak.sma"

# Knife filename differs between old/current R8 installs. Patch whichever is active.
for kp in zm_addon_knife_r8.amxx zm_addon_knife.amxx; do
  if active_plugin "$kp"; then
    stem="${kp%.amxx}"
    fallback=''
    [[ "$kp" == 'zm_addon_knife_r8.amxx' ]] && fallback="$PAYLOAD/sources/zm_addon_knife_r8.sma"
    compile_target "$kp" "$stem" 'knife' "$fallback"
  fi
done

# -----------------------------------------------------------------------------
# 4. Safe WAV downsampling: only known custom directories/files, and only when
# the new PCM file is at least 15% smaller. Never makes a WAV larger.
# -----------------------------------------------------------------------------
echo
echo '[4/9] Optimizing large custom WAV files when safe...'
WAV_BEFORE=0
WAV_AFTER=0
WAV_COUNT=0
if command -v ffmpeg >/dev/null 2>&1; then
  mapfile -d '' WAVS < <(
    {
      for d in zombie_plague oldz_w3 oldz_classes_r8 oldz_knife_r8 oldz_knife_v4 MG_grab; do
        [[ -d "$CSTRIKE/sound/$d" ]] && find "$CSTRIKE/sound/$d" -type f -iname '*.wav' -print0
      done
      find "$CSTRIKE/sound/weapons" -maxdepth 1 -type f \( \
        -iname 'm1887craft*.wav' -o -iname 'm79*.wav' -o -iname 'plasmagun*.wav' -o \
        -iname 'kriss*.wav' -o -iname 'm82*.wav' \) -print0 2>/dev/null || true
      find "$CSTRIKE/sound/fvox" -maxdepth 1 -type f -iname 'Announcer*.wav' -print0 2>/dev/null || true
      for f in "$CSTRIKE/sound/jetpack.wav" "$CSTRIKE/sound/jp_blow.wav"; do [[ -f "$f" ]] && printf '%s\0' "$f"; done
    } | sort -zu
  )
  for f in "${WAVS[@]:-}"; do
    [[ -f "$f" ]] || continue
    sz="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    [[ "$sz" -gt 65536 ]] || continue
    tmp="${f}.fastjoin.tmp.wav"
    rm -f "$tmp"
    if ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" -ac 1 -ar 22050 -c:a pcm_s16le "$tmp"; then
      nsz="$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)"
      # Replace only with a meaningful saving; otherwise preserve original quality.
      if [[ "$nsz" -gt 44 && $((nsz*100)) -lt $((sz*85)) ]]; then
        backup_one "$f"
        WAVE_BEFORE=$((WAV_BEFORE+sz)); WAV_AFTER=$((WAV_AFTER+nsz)); WAV_COUNT=$((WAV_COUNT+1))
        chmod 0644 "$tmp"; mv -f "$tmp" "$f"
        echo "  [WAV] ${f#$CSTRIKE/}: $sz -> $nsz"
      else
        rm -f "$tmp"
      fi
    else
      rm -f "$tmp"
    fi
  done
fi
echo "  [WAV SUMMARY] changed=$WAV_COUNT saved=$((WAV_BEFORE-WAV_AFTER)) bytes"

# -----------------------------------------------------------------------------
# 5. Quarantine only confirmed stale R6/R7 OLD ZOMBIE resource directories when
# there are no text/binary references left. No generic destructive pruning.
# -----------------------------------------------------------------------------
echo
echo '[5/9] Quarantining confirmed stale R6/R7 resources...'
Q="$BACKUP/quarantine-stale-r6-r7"
mkdir -p "$Q"
for rel in \
  models/player/oldz_admin_r6 models/player/oldz_admin_r7 \
  models/player/oldz_vip_r6 models/player/oldz_vip_r7 \
  models/player/oldz_tp_r6 models/player/oldz_tp_r7 \
  models/player/oldz_holfi_r6 models/player/oldz_holfi_r7 \
  models/oldz_knife_r6 models/oldz_knife_r7 \
  sound/oldz_knife_r6 sound/oldz_knife_r7 \
  sound/oldz_classes_r6 sound/oldz_classes_r7
 do
  p="$CSTRIKE/$rel"
  [[ -e "$p" ]] || continue
  needle="$(basename "$p")"
  if grep -Raq --exclude='*.log' --exclude-dir='_build_backups' --exclude-dir='_fastjoin_quarantine' "$needle" "$CFG" "$SCRIPTING" "$PLUGINS" 2>/dev/null; then
    echo "  [KEEP] $rel still referenced"
  else
    mkdir -p "$Q/$(dirname "$rel")"
    mv "$p" "$Q/$rel"
    echo "  [QUARANTINE] $rel"
  fi
done

# -----------------------------------------------------------------------------
# 6. Patch FastDL packer: for files >=256 KiB build bzip2 level 1 and level 9,
# keep whichever is smaller. Some GoldSrc MDLs are smaller with -1 than -9.
# This never modifies the game file, only the downloadable .bz2 sibling.
# -----------------------------------------------------------------------------
echo
echo '[6/9] Installing best-of-bzip2 FastDL packer...'
patch_ctl() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  backup_one "$f"
  python3 - "$f" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
start=s.find('def _fastdl_bzip_tree(dest:Path)->dict:')
end=s.find('\ndef fastdl_clean(sid:int):',start)
if start < 0 or end < 0:
    print('[WARN] FastDL bzip function not found in',p)
    raise SystemExit(0)
new=r'''def _fastdl_bzip_tree(dest:Path)->dict:
    """GoldSrc FastDL: build .bz2 and keep the smaller of bzip2 -1/-9 for large files."""
    bzip=shutil.which('bzip2')
    if not bzip: return {'compressed':0,'saved_bytes':0,'warning':'bzip2 is not installed'}
    allowed={'.bsp','.nav','.res','.wad','.mdl','.spr','.wav','.mp3','.tga','.bmp','.pcx','.txt','.vmt','.vtf'}
    made=0; saved=0; level1_wins=0
    for fp in sorted(dest.rglob('*')):
        try:
            if not fp.is_file() or fp.is_symlink() or fp.suffix.lower()=='.bz2': continue
            if fp.suffix.lower() not in allowed: continue
            bz=Path(str(fp)+'.bz2')
            candidates=[]
            levels=['-9'] if fp.stat().st_size < 262144 else ['-1','-9']
            for level in levels:
                tmp=bz.with_name('.'+bz.name+'.'+level[1:]+'-'+secrets.token_hex(4)+'.tmp')
                with open(tmp,'wb') as outfh:
                    raw=subprocess.run([bzip,level,'-c',str(fp)],stdout=outfh,stderr=subprocess.PIPE,check=False,timeout=300)
                if raw.returncode==0 and tmp.is_file() and tmp.stat().st_size>0:
                    candidates.append((tmp.stat().st_size,level,tmp))
                else:
                    try: tmp.unlink()
                    except OSError: pass
            if not candidates: continue
            candidates.sort(key=lambda x:x[0])
            best_size,best_level,best=candidates[0]
            for _,_,other in candidates[1:]:
                try: other.unlink()
                except OSError: pass
            os.chmod(best,0o644); os.replace(best,bz)
            try:
                os.utime(bz,ns=(fp.stat().st_atime_ns,fp.stat().st_mtime_ns))
                saved += max(0,fp.stat().st_size-bz.stat().st_size)
            except OSError: pass
            if best_level=='-1': level1_wins+=1
            made+=1
        except (OSError,subprocess.SubprocessError):
            continue
    return {'compressed':made,'saved_bytes':saved,'bzip1_wins':level1_wins}

'''
s=s[:start]+new+s[end+1:]
p.write_text(s,encoding='utf-8')
print('[OK] patched',p)
PY
  python3 -m py_compile "$f"
}
patch_ctl "$SRC_CTL"
patch_ctl "$CTL"
chmod 0755 "$CTL" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 7. Install exact FastDL join report command.
# -----------------------------------------------------------------------------
echo
echo '[7/9] Installing fastjoin traffic report...'
cat > /usr/local/sbin/hyper-cs16-fastjoin-report <<'PY'
#!/usr/bin/env python3
import re,sys,collections
from pathlib import Path
sid=str(int(sys.argv[1])) if len(sys.argv)>1 else '25'
log=Path('/var/log/nginx/hyper-cs16-fastdl-access.log')
if not log.exists():
    print('FastDL access log not found:',log); raise SystemExit(1)
rx=re.compile(r'^(\S+) .*?"GET (/fastdl/'+re.escape(sid)+r'/\S*) HTTP/[^\"]+" (\d+) (\d+)')
byip=collections.defaultdict(list)
for line in log.read_text(errors='replace').splitlines():
    m=rx.search(line)
    if not m: continue
    ip,path,status,size=m.groups()
    if status!='200': continue
    byip[ip].append((path,int(size)))
if not byip:
    print('No HTTP 200 FastDL requests for server #'+sid)
    raise SystemExit(0)
for ip,rows in sorted(byip.items(), key=lambda kv:sum(x[1] for x in kv[1]), reverse=True):
    unique={}
    for path,size in rows: unique[path]=max(size,unique.get(path,0))
    total=sum(size for _,size in rows); utotal=sum(unique.values())
    print(f'CLIENT {ip}: requests={len(rows)} unique={len(unique)} transferred={total/1048576:.2f} MiB unique_payload={utotal/1048576:.2f} MiB')
    for path,size in sorted(unique.items(), key=lambda x:x[1], reverse=True)[:15]:
        print(f'  {size/1048576:7.2f} MiB  {path}')
PY
chmod 0755 /usr/local/sbin/hyper-cs16-fastjoin-report

# -----------------------------------------------------------------------------
# 8. Rebuild FastDL using the new packer, then restart server.
# -----------------------------------------------------------------------------
echo
echo '[8/9] Rebuilding FastDL and restarting server...'
SYNC_JSON="$($CTL fastdl-sync "$SID")"
echo "$SYNC_JSON"
systemctl restart "hyper-cs16@${SID}.service"
sleep 3

# -----------------------------------------------------------------------------
# 9. Validation / audit.
# -----------------------------------------------------------------------------
echo
echo '[9/9] Validation...'
$CTL fastdl-status "$SID" || true

echo '--- active FASTDL cvars ---'
$CTL rcon "$SID" 'sv_downloadurl' || true
$CTL rcon "$SID" 'sv_allowdownload' || true
$CTL rcon "$SID" 'sv_allow_dlfile' || true

echo '--- M82 resources ---'
for f in m82-1.wav m82_clipin1.wav m82_clipin2.wav m82_clipout1.wav m82_clipout2.wav; do
  [[ -f "$CSTRIKE/sound/weapons/$f" ]] && echo "OK sound/weapons/$f" || echo "MISSING sound/weapons/$f"
done

echo '--- remaining obvious broken client sound refs from known sources ---'
grep -RIn --include='*.sma' -E 'Ghost_Count_|spk misc/zombie/(damage_1000|invader|ghost_shot)' "$SCRIPTING" 2>/dev/null | grep -v '_fastjoin.sma' | head -30 || true

echo '--- precache calls (source audit count) ---'
PRECACHE_COUNT="$(grep -RIEh --include='*.sma' 'precache_(model|sound|generic)|EngFunc_Precache(Model|Sound|Generic)' "$SCRIPTING" 2>/dev/null | wc -l || true)"
echo "source precache call lines: $PRECACHE_COUNT"

echo '--- largest FastDL .bz2 files ---'
find "/srv/hyper-cs16/fastdl/$SID" -type f -name '*.bz2' -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -20 | awk '{printf "%.2f MiB  %s\n",$1/1048576,$2}' || true

echo '--- HTTP FastDL sample ---'
SAMPLE="$(find "/srv/hyper-cs16/fastdl/$SID" -type f -name '*.mdl.bz2' 2>/dev/null | head -n1 || true)"
if [[ -n "$SAMPLE" ]]; then
  REL="${SAMPLE#/srv/hyper-cs16/fastdl/$SID/}"
  curl -sSI --max-time 10 "http://90.189.208.25/fastdl/$SID/$REL" | grep -Ei 'HTTP/|Content-Length|X-Hyper-FastDL|Content-Type' || true
fi

echo
echo '============================================================'
echo '[DONE] OLD ZOMBIE FASTJOIN v1 installed.'
echo "Backup: $BACKUP"
echo "Report: $REPORT"
echo
echo 'What changed:'
echo '  - fixed sound/weapons/m82*.wav'
echo '  - fewer Zombie Plague custom sound files are precached'
echo '  - duplicate Combo Zombie custom audio lookups disabled when source compiled'
echo '  - custom V weapon models kept; avoidable P/W models use stock CS where safe'
echo '  - custom WAVs are downsampled only when the result is materially smaller'
echo '  - stale R6/R7 resources quarantined only if no references remain'
echo '  - FastDL .bz2 uses the smaller of bzip2 -1/-9 for large resources'
echo
echo 'After ONE clean-client join run:'
echo "  sudo hyper-cs16-fastjoin-report $SID"
echo
echo 'Live HTTP proof:'
echo '  sudo tail -F /var/log/nginx/hyper-cs16-fastdl-access.log'
echo '============================================================'
