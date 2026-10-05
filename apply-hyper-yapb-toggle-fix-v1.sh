#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-host-bots-toggle-fix-v1-${STAMP}"
mkdir -p "$BACKUP"

echo "================================================================"
echo " HYPER-HOST YaPB TOGGLE FIX v1"
echo " Backup: $BACKUP"
echo "================================================================"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

mapfile -t CTLS < <(
  {
    command -v hyper-cs16-ctl 2>/dev/null || true
    printf '%s\n' \
      /opt/hyper-cs16/bin/hyper-cs16-ctl \
      /usr/local/bin/hyper-cs16-ctl \
      /usr/bin/hyper-cs16-ctl \
      /root/hyper-hosting-panel/cs16-panel/bin/hyper-cs16-ctl
    find /opt /usr/local /root/hyper-hosting-panel -type f -name hyper-cs16-ctl 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
)

FOUND=0
for CTL in "${CTLS[@]}"; do
  [[ -f "$CTL" ]] || continue
  FOUND=1
  echo "[PATCH] $CTL"
  cp -a "$CTL" "$BACKUP/$(echo "$CTL" | sed 's#/#_#g').bak"

  python3 - "$CTL" <<'PY'
from pathlib import Path
import sys, re

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="strict")

compat = "\n".join([
"def _normalize_cli_aliases():",
"    if len(sys.argv) < 2:",
"        return",
"    aliases = {",
"        'боты-включить': 'bots-enable',",
"        'боты-выключить': 'bots-disable',",
"        'боты-настроить': 'bots-config',",
"        'боты-установить': 'bots-install',",
"    }",
"    sys.argv[1] = aliases.get(sys.argv[1], sys.argv[1])",
"",
""
])

if "_normalize_cli_aliases" not in s:
    if "def main():\n" not in s:
        raise SystemExit("main() not found")
    s=s.replace("def main():\n",compat+"def main():\n",1)

if "def main():\n    _normalize_cli_aliases()" not in s:
    s=s.replace(
        "def main():\n    p=argparse.ArgumentParser(",
        "def main():\n    _normalize_cli_aliases()\n    p=argparse.ArgumentParser(",
        1
    )

helper = "\n".join([
"def _set_yapb_metamod_enabled(cstrike:Path, enabled:bool):",
"    p=cstrike/'addons/metamod/plugins.ini'",
"    p.parent.mkdir(parents=True,exist_ok=True)",
"    lines=p.read_text(encoding='utf-8',errors='ignore').splitlines() if p.exists() else []",
"    needle='addons/yapb/bin/yapb.so'",
"    found=False",
"    out_lines=[]",
"    for line in lines:",
"        if needle in line.lower():",
"            if found:",
"                continue",
"            found=True",
"            clean=line.lstrip()",
"            while clean.startswith(';'):",
"                clean=clean[1:].lstrip()",
"            clean=clean or 'linux addons/yapb/bin/yapb.so'",
"            if not clean.lower().startswith('linux '):",
"                clean='linux addons/yapb/bin/yapb.so'",
"            out_lines.append(clean if enabled else ';'+clean)",
"        else:",
"            out_lines.append(line)",
"    if not found:",
"        out_lines.append('linux addons/yapb/bin/yapb.so' if enabled else ';linux addons/yapb/bin/yapb.so')",
"    p.write_text('\\n'.join(out_lines).rstrip()+'\\n',encoding='utf-8')",
"    return str(p)",
"",
""
])

marker="def install_yapb(sid:int,quota:int=9,difficulty:int=3):"
if "_set_yapb_metamod_enabled" not in s:
    if marker not in s:
        raise SystemExit("install_yapb() not found")
    s=s.replace(marker,helper+marker,1)

s=s.replace(
    "_append_unique(cstrike/'addons/metamod/plugins.ini','linux addons/yapb/bin/yapb.so')",
    "_set_yapb_metamod_enabled(cstrike,True)"
)

needle_cfg="quota=max(0,min(31,int(quota))); difficulty=max(0,min(4,int(difficulty)))\n    _set_cfg_cvar(ycfg,'yb_quota'"
if needle_cfg in s and "_set_yapb_metamod_enabled(path/'cstrike',True)" not in s:
    s=s.replace(
        needle_cfg,
        "quota=max(0,min(31,int(quota))); difficulty=max(0,min(4,int(difficulty)))\n    _set_yapb_metamod_enabled(path/'cstrike',True)\n    _set_cfg_cvar(ycfg,'yb_quota'",
        1
    )

# Replace disable function body safely.
start=s.find("def disable_yapb(sid:int):")
end=s.find("\ndef install_zp43(", start)
if start >= 0 and end > start:
    disable = "\n".join([
        "def disable_yapb(sid:int):",
        "    require_root(); c=load_server(sid); cstrike=Path(c['path'])/'cstrike'",
        "    _set_yapb_metamod_enabled(cstrike,False)",
        "    c['bots_enabled']=0; save_server(c)",
        "    db_update_mode(sid,str(c.get('game_mode','classic')),0,int(c.get('bots_quota',9)),int(c.get('bots_difficulty',3)))",
        "    restart=service_action(sid,'restart')",
        "    return {'ok':True,'bots_enabled':False,'restart':restart,'warning':restart.get('warning','')}",
        "",
    ])
    s=s[:start]+disable+s[end:]

enable = "\n".join([
"def enable_yapb(sid:int,quota:int|None=None,difficulty:int|None=None):",
"    require_root(); c=load_server(sid); path=Path(c['path']); cstrike=path/'cstrike'",
"    ycfg=cstrike/'addons/yapb/conf/yapb.cfg'",
"    q=int(c.get('bots_quota',9) if quota is None else quota)",
"    d=int(c.get('bots_difficulty',3) if difficulty is None else difficulty)",
"    q=max(0,min(31,q)); d=max(0,min(4,d))",
"    if not (cstrike/'addons/yapb').is_dir() or not ycfg.exists():",
"        return install_yapb(sid,q,d)",
"    _set_yapb_metamod_enabled(cstrike,True)",
"    _set_cfg_cvar(ycfg,'yb_quota',str(q))",
"    _set_cfg_cvar(ycfg,'yb_quota_mode','fill')",
"    _set_cfg_cvar(ycfg,'yb_difficulty',str(d))",
"    _set_cfg_cvar(ycfg,'yb_autovacate','1')",
"    _set_cfg_cvar(ycfg,'yb_autovacate_keep_slots','1')",
"    _set_cfg_cvar(ycfg,'yb_language','ru')",
"    normalize_permissions(path)",
"    c['bots_enabled']=1; c['bots_quota']=q; c['bots_difficulty']=d; save_server(c)",
"    db_update_mode(sid,str(c.get('game_mode','classic')),1,q,d)",
"    restart=service_action(sid,'restart')",
"    current=load_server(sid)",
"    return {'ok':True,'id':sid,'bots':'YaPB','quota':q,'difficulty':d,'bots_enabled':bool(current.get('bots_enabled',0)),'restart':restart,'warning':restart.get('warning','')}",
"",
""
])

if "def enable_yapb(" not in s:
    pos=s.find("def disable_yapb(sid:int):")
    if pos < 0:
        raise SystemExit("disable_yapb() not found")
    s=s[:pos]+enable+s[pos:]

parser_line="q=sp.add_parser('bots-install'); q.add_argument('id',type=int); q.add_argument('--quota',type=int,default=9); q.add_argument('--difficulty',type=int,default=3)"
if "sp.add_parser('bots-enable')" not in s:
    if parser_line not in s:
        raise SystemExit("bots-install parser not found")
    s=s.replace(
        parser_line,
        parser_line+"\n    q=sp.add_parser('bots-enable'); q.add_argument('id',type=int); q.add_argument('--quota',type=int); q.add_argument('--difficulty',type=int)",
        1
    )

dispatch="elif args.cmd=='bots-install': result=install_yapb(args.id,args.quota,args.difficulty)"
if "args.cmd=='bots-enable'" not in s:
    if dispatch not in s:
        raise SystemExit("bots-install dispatch not found")
    s=s.replace(
        dispatch,
        dispatch+"\n        elif args.cmd=='bots-enable': result=enable_yapb(args.id,args.quota,args.difficulty)",
        1
    )

compile(s,str(p),"exec")
p.write_text(s,encoding="utf-8")
print("[OK] patched and syntax valid")
PY

  chmod 755 "$CTL"
done

if [[ "$FOUND" -eq 0 ]]; then
  echo "[ERROR] hyper-cs16-ctl not found."
  exit 2
fi

echo
echo "================================================================"
echo " [SUCCESS] YaPB toggle fixed"
echo "================================================================"
echo "Now supported:"
echo "  hyper-cs16-ctl bots-enable 25"
echo "  hyper-cs16-ctl bots-disable 25"
echo "  hyper-cs16-ctl боты-включить 25"
echo "  hyper-cs16-ctl боты-выключить 25"
echo
echo "Also bots-config now automatically re-enables YaPB in Metamod."
echo "Backup: $BACKUP"
