#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16/ZM runtime stability fix v3.9
#
# Fixes:
#   1) Common subprocess UTF-8 decoding crash (0xFF/0xE0/0x9E/0xD6...)
#   2) Heavy ZM builds being auto-recovered while they are still STARTING
#   3) systemd restart thrashing on a genuinely broken runtime
#   4) false "AMXX 0/N, 0 running" caused by querying RCON too early
#   5) non-fatal AMXX callback errors being promoted to whole-runtime CRITICAL
#
# This patch DOES NOT run apply-cs16-v3.3-fullbuild.sh.
# It DOES NOT touch PHP sites, bootstrap.php, nginx or SQL.

CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
MON="${HYPER_MON:-/usr/local/sbin/hyper-cs16-monitor}"
UNIT="${HYPER_UNIT:-/etc/systemd/system/hyper-cs16@.service}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.9-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.9-${STAMP}.log"
SKIP_SYSTEMD="${SKIP_SYSTEMD:-0}"

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
echo " HYPER-HOST CS16/ZM STABILITY FIX v3.9"
echo "============================================================"
echo "Controller: $CTL"
echo "Monitor:    $MON"
echo "Unit:       $UNIT"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ -f "$CTL" ]] || die "Controller not found: $CTL"
[[ -f "$MON" ]] || die "Monitor not found: $MON"
[[ -f "$UNIT" ]] || die "systemd unit not found: $UNIT"

cp -a "$CTL" "$BACKUP/hyper-cs16-ctl"
cp -a "$MON" "$BACKUP/hyper-cs16-monitor"
cp -a "$UNIT" "$BACKUP/hyper-cs16@.service"

if [[ "$SKIP_SYSTEMD" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet hyper-cs16-monitor.service; then
    echo "[1/7] Stopping monitor while patching..."
    systemctl stop hyper-cs16-monitor.service || true
  else
    echo "[1/7] Monitor is not active; patching directly..."
  fi
else
  echo "[1/7] SKIP_SYSTEMD=1 -> systemd actions disabled"
fi

echo
echo "[2/7] Patching controller runtime checks..."

python3 - "$CTL" <<'PY'
from __future__ import annotations
import re
import sys
from pathlib import Path

path=Path(sys.argv[1])
src=path.read_text(encoding='utf-8',errors='surrogateescape')
original=src

old_run=(
    "cp=subprocess.run(cmd,stdout=subprocess.PIPE if capture else None,"
    "stderr=subprocess.STDOUT if capture else None,text=True,check=False,"
    "timeout=timeout,cwd=cwd,env=env)"
)
new_run=(
    "cp=subprocess.run(cmd,stdout=subprocess.PIPE if capture else None,"
    "stderr=subprocess.STDOUT if capture else None,text=True,"
    "encoding='utf-8',errors='replace',check=False,"
    "timeout=timeout,cwd=cwd,env=env)"
)
if old_run in src:
    src=src.replace(old_run,new_run,1)

run_match=re.search(
    r"(?ms)^def run\(cmd, check=True, capture=True, timeout=None, cwd=None, env=None\):\n"
    r".*?(?=^def )",
    src
)
if not run_match:
    raise SystemExit("[ERROR] common run() helper was not found")
run_block=run_match.group(0)
if "encoding='utf-8'" not in run_block or "errors='replace'" not in run_block:
    raise SystemExit("[ERROR] failed to make common run() UTF-8 safe")

crit_re=re.compile(
    r"(?ms)^def _critical_runtime_errors\(lines:list\[str\]\)->list\[str\]:\n"
    r".*?(?=^def )"
)
crit=crit_re.search(src)
if not crit:
    raise SystemExit(
        "[ERROR] _critical_runtime_errors() not found. "
        "Expected the exact-build controller currently installed on this host."
    )

crit_func='''def _critical_runtime_errors(lines:list[str])->list[str]:
    # Only faults proving the runtime itself is unusable are CRITICAL.
    # Loaded/running legacy ZP plugins may emit RegisterHam/get_pcvar_* errors;
    # those remain visible as warnings but must not restart the whole server.
    critical=[]
    hard_markers=(
        '0 plugins, 0 running',
        'modules list not found',
        'you need rehlds or regamedll',
        'segmentation fault',
        'fatal error',
    )
    for ln in lines:
        low=ln.lower()
        if any(x in low for x in hard_markers):
            critical.append(ln)
            continue
        if ('metamod' in low or 'amxmodx_mm' in low) and any(
            x in low for x in ('failed','error','bad load','cannot load','could not load')
        ):
            critical.append(ln)
    return list(dict.fromkeys(critical))[-40:]


'''
src=src[:crit.start()]+crit_func+src[crit.end():]

if "def _runtime_mod_report_stable(" not in src:
    marker="\ndef _restart_strict(sid:int,c:dict,timeout:float=35.0):"
    pos=src.find(marker)
    if pos<0:
        raise SystemExit("[ERROR] _restart_strict() marker not found")

    stable_helper=r'''

def _runtime_mod_report_stable(c:dict, expect_zp:bool=False, expected_plugins:int=0, timeout:float=30.0):
    # Heavy 50-100 plugin ZM packs can open UDP before AMXX/RCON is fully ready.
    # Retry the runtime probe instead of permanently recording a false 0/N result.
    deadline=time.time()+max(3.0,float(timeout))
    best=None
    sid=int(c.get('id') or 0)
    port=int(c.get('port') or 0)

    while True:
        report=_runtime_mod_report(c,expect_zp,expected_plugins)
        best=report
        total=int(report.get('runtime_plugin_total') or 0)

        if total>0:
            if not expect_zp:
                return report
            if report.get('zp_runtime') or report.get('zp_plugin_lines'):
                return report
            if time.time()+2.0>=deadline:
                return report

        if time.time()>=deadline:
            return best or report

        try:
            if sid and service_status(sid)!='active':
                return best or report
            if port and not udp_listening(port):
                time.sleep(1.5)
                continue
        except Exception:
            pass

        time.sleep(2.0)


'''
    src=src[:pos]+stable_helper+src[pos:]

old_call=(
    "runtime_report=_runtime_mod_report(c,bool(detected.get('zp_active')),"
    "int(detected.get('active_plugin_count') or 0))"
)
new_call=(
    "runtime_report=_runtime_mod_report_stable(c,bool(detected.get('zp_active')),"
    "int(detected.get('active_plugin_count') or 0),30.0)"
)
if old_call in src:
    src=src.replace(old_call,new_call)

if new_call not in src:
    raise SystemExit("[ERROR] install_custom_build() runtime probe was not patched")

if src==original:
    print("[OK] controller was already fully patched")
else:
    path.write_text(src,encoding='utf-8',errors='surrogateescape')
    print("[PATCHED]",path)
PY

echo
echo "[3/7] Patching monitor so STARTING is never treated as a crash..."

python3 - "$MON" <<'PY'
from __future__ import annotations
import re
import sys
from pathlib import Path

path=Path(sys.argv[1])
src=path.read_text(encoding='utf-8',errors='surrogateescape')
original=src

src=re.sub(
    r"text=True(?!\s*,\s*encoding=)",
    "text=True,encoding='utf-8',errors='replace'",
    src
)

start=src.find(
    "    # Self-heal only after three consecutive 10s checks without a real UDP socket."
)
if start<0:
    start=src.find("    # Recovery guard:")
    if start<0:
        raise SystemExit("[ERROR] monitor recovery block was not found")

end=src.find("\n    d=disk(c['path']) if c else 0.0",start)
if end<0:
    raise SystemExit("[ERROR] end of monitor recovery block was not found")

guard='''    # Recovery guard:
    # Heavy ZM packs may need well over 30 seconds to initialise 50-100 plugins.
    # STARTING is not a failure. Uploaded assemblies are never auto-recovered
    # behind the owner's back.
    now=time.time()
    custom_build=bool(c and str(c.get('custom_build_source') or '').strip())

    hard_failed=bool(
        c and not udp and (
            svc=='failed' or
            (svc=='active' and p>0 and uptime>=90 and status=='failed')
        )
    )

    if hard_failed and not custom_build and svc not in {'inactive','deactivating'}:
        FAIL_COUNTS[sid]=FAIL_COUNTS.get(sid,0)+1

        # Six genuine failed checks ~= one minute.
        if FAIL_COUNTS[sid]>=6 and now-LAST_RECOVER.get(sid,0)>=RECOVER_COOLDOWN:
            LAST_RECOVER[sid]=now
            FAIL_COUNTS[sid]=0
            try:
                cp=subprocess.run(
                    ['/usr/local/sbin/hyper-cs16-ctl','recover',str(sid),'--auto'],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding='utf-8',
                    errors='replace',
                    timeout=95
                )
                print(
                    f'auto-recover server {sid}: {(cp.stdout or "").strip()[-2000:]}',
                    file=sys.stderr
                )
                if cp.returncode==0:
                    recovered=True
                    try:
                        rr=json.loads((cp.stdout or '').strip().splitlines()[-1])
                        actions=rr.get('actions') or []
                        quarantined=rr.get('quarantined') or []
                        if quarantined or any(
                            'disabled' in str(a).lower() or
                            'quarantined' in str(a).lower()
                            for a in actions
                        ):
                            msg='Автовосстановление отключило проблемный контент'
                            if quarantined:
                                msg+=': '+', '.join(map(str,quarantined[:8]))
                            queue_event(
                                db,settings,'plugin_disabled',msg,sid,'warning',
                                {'actions':actions,'quarantined':quarantined},5
                            )
                        for a in actions:
                            if (
                                'map' in str(a).lower() and
                                (
                                    'fallback' in str(a).lower() or
                                    'bad startup map' in str(a).lower()
                                )
                            ):
                                queue_event(
                                    db,settings,'map_failed',
                                    'Проблемная карта была автоматически заменена: '+str(a),
                                    sid,'warning',{'action':a},5
                                )
                                break
                    except Exception:
                        pass

                    svc=service(sid)
                    p=actual_hlds_pid(sid)
                    cpu,mem,uptime=proc_metrics(p)
                    udp=bool(port and udp_listening(port))
                    status='online' if udp else 'starting'
            except Exception as exc:
                print(f'auto-recover server {sid} failed: {exc}',file=sys.stderr)
    else:
        FAIL_COUNTS[sid]=0
'''

src=src[:start]+guard+src[end:]

path.write_text(src,encoding='utf-8',errors='surrogateescape')
print("[PATCHED]" if src!=original else "[OK already patched]",path)
PY

echo
echo "[4/7] Limiting systemd restart loops..."

python3 - "$UNIT" <<'PY'
from pathlib import Path
import re
import sys

path=Path(sys.argv[1])
src=path.read_text(encoding='utf-8')
original=src

def set_line(text,key,value):
    rx=re.compile(rf"(?m)^{re.escape(key)}=.*$")
    line=f"{key}={value}"
    if rx.search(text):
        return rx.sub(line,text,count=1)
    return text

src=set_line(src,'StartLimitIntervalSec','300')
src=set_line(src,'StartLimitBurst','3')
src=set_line(src,'RestartSec','10')

if 'RestartPreventExitStatus=2' not in src:
    if 'Restart=on-failure\n' not in src:
        raise SystemExit("[ERROR] Restart=on-failure not found in unit")
    src=src.replace(
        'Restart=on-failure\n',
        'Restart=on-failure\nRestartPreventExitStatus=2\n',
        1
    )

path.write_text(src,encoding='utf-8')
print("[PATCHED]" if src!=original else "[OK already patched]",path)
PY

echo
echo "[5/7] Syntax validation..."

python3 -m py_compile "$CTL" || {
  cp -a "$BACKUP/hyper-cs16-ctl" "$CTL"
  die "Controller syntax failed; original restored"
}

python3 -m py_compile "$MON" || {
  cp -a "$BACKUP/hyper-cs16-monitor" "$MON"
  die "Monitor syntax failed; original restored"
}

echo "[OK] controller syntax"
echo "[OK] monitor syntax"

echo
echo "[6/7] Verifying installed logic..."

python3 - "$CTL" "$MON" "$UNIT" <<'PY'
from pathlib import Path
import sys

ctl=Path(sys.argv[1]).read_text(encoding='utf-8',errors='surrogateescape')
mon=Path(sys.argv[2]).read_text(encoding='utf-8',errors='surrogateescape')
unit=Path(sys.argv[3]).read_text(encoding='utf-8',errors='surrogateescape')

checks={
    "controller UTF-8 safe":
        "encoding='utf-8',errors='replace'" in ctl,
    "stable AMXX probe":
        "def _runtime_mod_report_stable(" in ctl,
    "runtime probe uses retry":
        "runtime_report=_runtime_mod_report_stable(" in ctl,
    "legacy ZP callback errors are warnings":
        "RegisterHam/get_pcvar_*" in ctl,
    "monitor custom-build guard":
        "custom_build=bool(c and str(c.get('custom_build_source')" in mon,
    "monitor requires genuine failure":
        "FAIL_COUNTS[sid]>=6" in mon,
    "restart delay":
        "RestartSec=10" in unit,
    "restart burst":
        "StartLimitBurst=3" in unit,
    "config failure does not loop":
        "RestartPreventExitStatus=2" in unit,
}

bad=[]
for name,ok in checks.items():
    print(("[OK] " if ok else "[FAIL] ")+name)
    if not ok:
        bad.append(name)

if bad:
    raise SystemExit("[ERROR] verification failed: "+", ".join(bad))
PY

if [[ "$SKIP_SYSTEMD" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
  echo
  echo "[7/7] Reloading services and releasing failed instances from the OLD loop..."

  systemctl daemon-reload
  systemctl restart hyper-cs16-monitor.service || die "Could not restart hyper-cs16-monitor.service"

  mapfile -t FAILED_UNITS < <(
    systemctl list-units --all 'hyper-cs16@*.service' --no-legend --no-pager 2>/dev/null |
    awk '$4=="failed" {print $1}'
  )

  if ((${#FAILED_UNITS[@]})); then
    for u in "${FAILED_UNITS[@]}"; do
      echo "[INFO] reset old failed state -> $u"
      systemctl reset-failed "$u" || true
      systemctl start "$u" || true
    done
  else
    echo "[INFO] no failed CS16 instances need reset"
  fi

  sleep 5

  echo
  echo "Current CS16 service states:"
  systemctl list-units --all 'hyper-cs16@*.service' --no-legend --no-pager 2>/dev/null || true

  echo
  echo "Monitor:"
  systemctl --no-pager --full status hyper-cs16-monitor.service 2>/dev/null | sed -n '1,14p' || true
else
  echo
  echo "[7/7] SKIP_SYSTEMD=1 -> service reload/start skipped"
fi

echo
echo "============================================================"
echo " v3.9 INSTALLED"
echo "============================================================"
echo " - ZM STARTING is no longer counted as a crash"
echo " - uploaded custom builds are not auto-recovered/re-written"
echo " - false early AMXX 0/N probes are retried for up to 30s"
echo " - systemd restart storms are bounded (3 starts / 300s)"
echo " - exit code 2 config errors do not restart forever"
echo " - non-fatal legacy plugin callback errors remain warnings"
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo
echo "Retry the same server/build now. Do NOT run v3.3 again."
echo "============================================================"
