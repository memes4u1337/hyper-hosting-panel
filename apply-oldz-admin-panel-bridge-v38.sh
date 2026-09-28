#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/root/hyper-hosting-panel}"
SID="${2:-25}"
CTL="$ROOT/cs16-panel/bin/hyper-cs16-ctl"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-admin-panel-bridge-v38-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$CTL" ]] || fail "missing $CTL"

mkdir -p "$BACKUP"
cp -a "$CTL" "$BACKUP/hyper-cs16-ctl.before"
cp -a "$LIVE" "$BACKUP/hyper-cs16-ctl.live.before" 2>/dev/null || true

echo "================================================================"
echo " OLD ZOMBIE ADMIN PANEL BRIDGE FINAL v38"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " Game/FastDL/YaPB/AMXX/Unprecacher: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Add sql-admins-* compatibility bridge to working GameCMS backend..."

python3 - "$CTL" <<'PYV38'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8',errors='strict')

begin="# === OLDZ GAMECMS PANEL BRIDGE v38 BEGIN ==="
end="# === OLDZ GAMECMS PANEL BRIDGE v38 END ==="
if begin in s and end in s:
    a=s.index(begin)
    b=s.index(end,a)+len(end)
    s=s[:a]+s[b:]

bridge = '''
# === OLDZ GAMECMS PANEL BRIDGE v38 BEGIN ===
def sql_admins_list(sid:int):
    result=admin_list(sid)
    rows=[]
    for row in result.get('admins',[]):
        r=dict(row)
        r['key']=str(r.get('index',0))
        r['id']=r.get('db_id')
        r['auth']=r.get('identity','')
        r['access']=r.get('access_flags','')
        r['flags']=r.get('auth_flags','')
        rows.append(r)
    out=dict(result)
    out['admins']=rows
    out['rows']=rows
    out['table']='gm_amxadmins + gm_admins_servers'
    return out

def sql_admins_save(sid:int,payload:dict):
    if not isinstance(payload,dict):
        raise RuntimeError('Некорректные данные администратора')
    p=dict(payload)
    key=str(p.get('key') or p.get('edit_key') or '').strip()
    if key:
        try:
            p['index']=int(key)
        except Exception:
            raise RuntimeError('Некорректный ключ администратора')
    else:
        p['index']=-1
    if not p.get('identity'):
        p['identity']=str(p.get('auth') or p.get('steamid') or p.get('name') or '')
    if not p.get('access_flags'):
        p['access_flags']=str(p.get('access') or '')
    result=admin_save(sid,p)
    out=dict(result)
    out['key']=str(out.get('index',-1))
    out['auth']=out.get('identity','')
    out['access']=out.get('access_flags','')
    out['flags']=out.get('auth_flags','')
    out['table']='gm_amxadmins + gm_admins_servers'
    return out

def sql_admins_delete(sid:int,key:str):
    try:
        index=int(str(key).strip())
    except Exception:
        raise RuntimeError('Некорректный ключ администратора')
    result=admin_delete(sid,index)
    out=dict(result)
    out['table']='gm_amxadmins + gm_admins_servers'
    return out
# === OLDZ GAMECMS PANEL BRIDGE v38 END ===
'''

anchor='def server_config_set(args):'
pos=s.find(anchor)
if pos<0:
    raise SystemExit('cannot locate server_config_set()')
s=s[:pos]+bridge.strip()+"\n\n"+s[pos:]

parser_anchor="q=sp.add_parser('admin-delete'); q.add_argument('id',type=int); q.add_argument('index',type=int)"
if parser_anchor not in s:
    raise SystemExit('cannot locate admin-delete parser')
if "sp.add_parser('sql-admins-list')" not in s:
    parser_add=(parser_anchor+"\n"
        "    q=sp.add_parser('sql-admins-list'); q.add_argument('id',type=int)\n"
        "    q=sp.add_parser('sql-admins-save'); q.add_argument('id',type=int)\n"
        "    q=sp.add_parser('sql-admins-delete'); q.add_argument('id',type=int); q.add_argument('key')")
    s=s.replace(parser_anchor,parser_add,1)

dispatch_anchor="elif args.cmd=='admin-delete': result=admin_delete(args.id,args.index)"
if dispatch_anchor not in s:
    raise SystemExit('cannot locate admin-delete dispatcher')
if "elif args.cmd=='sql-admins-list':" not in s:
    dispatch_add=(dispatch_anchor+"\n"
        "        elif args.cmd=='sql-admins-list': result=sql_admins_list(args.id)\n"
        "        elif args.cmd=='sql-admins-save':\n"
        "            raw=sys.stdin.buffer.read(128*1024+1)\n"
        "            if len(raw)>128*1024: raise RuntimeError('Admin payload is too large')\n"
        "            try: payload=json.loads(raw.decode('utf-8','replace') or '{}')\n"
        "            except Exception: raise RuntimeError('Invalid admin payload')\n"
        "            if not isinstance(payload,dict): raise RuntimeError('Invalid admin payload')\n"
        "            result=sql_admins_save(args.id,payload)\n"
        "        elif args.cmd=='sql-admins-delete': result=sql_admins_delete(args.id,args.key)")
    s=s.replace(dispatch_anchor,dispatch_add,1)

p.write_text(s,encoding='utf-8')
print('GameCMS panel bridge patched')
PYV38

echo "[2/5] Validate syntax BEFORE live install..."
python3 -m py_compile "$CTL"

echo "[3/5] Install validated controller live..."
install -m 0755 "$CTL" "$LIVE"
python3 -m py_compile "$LIVE"

echo "[4/5] Verify commands exist..."
HELP="$("$LIVE" --help 2>&1 || true)"
echo "$HELP" | grep -q "sql-admins-list" || fail "sql-admins-list missing"
echo "$HELP" | grep -q "sql-admins-save" || fail "sql-admins-save missing"
echo "$HELP" | grep -q "sql-admins-delete" || fail "sql-admins-delete missing"
echo "sql-admins commands: OK"

echo "[5/5] Read admins through EXACT command used by panel..."
"$LIVE" sql-admins-list "$SID"

echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE ADMIN PANEL BRIDGE v38"
echo "================================================================"
echo " Panel sql-admins-list/save/delete: WORKING"
echo " Backend: gm_amxadmins + gm_admins_servers"
echo " Existing admins should now be visible in panel"
echo " Add/edit/delete use the same GameCMS backend"
echo " Game/FastDL/YaPB/AMXX/Unprecacher: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"
