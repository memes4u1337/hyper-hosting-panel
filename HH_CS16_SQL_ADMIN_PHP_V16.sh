#!/usr/bin/env bash
# HYPER-HOST V16: match ACTUAL PHP sql_admin_grant payload and sql_admin_delete call.
# Does not replace the CS 1.6 controller or modify game SQL during installation.
set -Eeuo pipefail
umask 077
MODE="${1:-check}"
case "$MODE" in check|apply|verify) ;; *) echo 'Usage: sudo bash HH_CS16_SQL_ADMIN_PHP_V16.sh check|apply|verify' >&2; exit 2;; esac
if (( EUID != 0 )); then echo '[HH-ADMIN16-ERROR] Use sudo' >&2; exit 2; fi
PHP=/var/www/hyper-host-sites/www.avito.hyper-host.pw/public_html/index.php
HELPER=/usr/local/libexec/hyper-cs16/sql-admin-alias-v14.py
WORKER=/usr/local/libexec/hyper-cs16/sql-admin-expiry-v16.py
CONTROLLER=/usr/local/sbin/hyper-cs16-ctl
SERVICE=/etc/systemd/system/hh-cs16-admin-expiry.service
TIMER=/etc/systemd/system/hh-cs16-admin-expiry.timer
STATE_DIR=/var/lib/hyper-cs16/sql-admin-expirations
BACKUPS=/opt/hyper-cs16/backups
TMPDIR=$(mktemp -d /tmp/hh-admin16.XXXXXXXX)
APPLIED=0
SUCCESS=0
on_exit(){
    code=$?
    trap - EXIT ERR
    if (( APPLIED == 1 && SUCCESS == 0 )); then rollback || true; fi
    rm -rf "$TMPDIR"
    exit "$code"
}
trap on_exit EXIT
say(){ echo "[HH-ADMIN16] $*"; }
die(){ echo "[HH-ADMIN16-ERROR] $*" >&2; exit 1; }

[[ -f "$PHP" && ! -L "$PHP" ]] || die 'Installed PHP index.php not found or symlink'
[[ -f "$HELPER" && ! -L "$HELPER" ]] || die 'V15 SQL admin helper not found'
[[ -f "$CONTROLLER" && ! -L "$CONTROLLER" ]] || die 'CS 1.6 controller not found'
if ! grep -Eq 'HH_CS16_SQL_ADMIN_ALIAS_V15|HYPER-HOST SQL Admin V16' "$HELPER"; then die 'Expected V15/V16 helper not present; refusing unknown adapter'; fi
grep -q 'HH_CS16_SQL_ADMIN_ALIAS_V14' "$CONTROLLER" || die 'SQL admin dispatch hook not found; refusing unknown launcher'
# Existing SQL V5 commands are required; do not overwrite controllers.
python3 "$CONTROLLER" --help > "$TMPDIR/cli-help" 2> "$TMPDIR/cli-stderr" || die 'Installed controller --help failed; no files changed'
grep -q 'sql-admins-save' "$TMPDIR/cli-help" || die 'sql-admins-save missing in controller'
grep -q 'sql-admins-delete' "$TMPDIR/cli-help" || die 'sql-admins-delete missing in controller'
php -l "$PHP" >/dev/null || die 'PHP syntax already invalid before installation'
python3 - "$PHP" <<'PY_CHECK'
from pathlib import Path
import sys
p=Path(sys.argv[1]).read_text()
for key in ("'auth_type'=>", "'identity'=>", "'nickname'=>", "'generate_password'=>", "'full_access'=>", "'custom_flags'=>", "'forever'=>", "'duration_count'=>", "'duration_unit'=>"):
    if key not in p: raise SystemExit('Unsupported PHP payload; missing '+key)
if "ctl(['sql-admin-grant',$id]" not in p: raise SystemExit('Panel grant handler changed; no changes')
if p.count("ctl(['sql-admin-delete',$id,$adminId]")>1: raise SystemExit('Multiple deletion sites; refusing')
if "ctl(['sql-admin-delete',$id,$adminId]" not in p and "ctl(['sql-admin-revoke',$id,$adminId]" not in p:
    raise SystemExit('Panel delete handler unknown; refusing')
print('[HH-ADMIN16] Exact installed PHP grant/delete signatures confirmed')
PY_CHECK
python3 -c 'import pymysql' || die 'PyMySQL unavailable; required by the installed controller'
command -v systemctl >/dev/null || die 'systemd is unavailable; cannot enforce temporary admin expiration'
if [[ -L "$WORKER" ]]; then die 'Existing worker is symlink'; fi
if [[ -e "$WORKER" ]] && ! grep -q 'Expire limited AMX SQL admins' "$WORKER"; then die 'Unrelated expiry worker exists'; fi
for f in "$SERVICE" "$TIMER"; do
    if [[ -L "$f" ]]; then die "Unit path is symlink: $f"; fi
    if [[ -f "$f" ]] && ! grep -q 'HH-CS16 SQL Admin V16' "$f"; then die "Unrelated systemd unit already exists: $f"; fi
done

cat > "$TMPDIR/helper.py" <<'PY_HELPER'
#!/usr/bin/env python3
"""HYPER-HOST SQL Admin V16: exact panel payload bridge. No SQL writes in selftest."""
import calendar
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

CONTROLLER=Path('/usr/local/sbin/hyper-cs16-ctl')
STATE_DIR=Path('/var/lib/hyper-cs16/sql-admin-expirations')
REGISTRY=STATE_DIR/'registry.json'
LOCK=STATE_DIR/'registry.lock'
SERVER_DIR=Path('/var/lib/hyper-cs16/servers')
STEAM=re.compile(r'^(?:STEAM|VALVE)_[0-9]+:[0-9]+:[0-9]+$', re.I)
ACCESS=re.compile(r'^[a-u]{1,21}$')
GRANT_KEYS={'auth_type','identity','nickname','password','generate_password','full_access','access_flags','custom_flags','forever','duration_count','duration_unit'}
FULL_ACCESS='abcdefghijklmnopqrstu'
UNITS={'day':'days','days':'days','week':'weeks','weeks':'weeks','month':'months','months':'months','year':'years','years':'years','hour':'hours','hours':'hours'}

class UserError(Exception): pass

def exit_json(error, code=2):
    print(json.dumps({'ok':False,'error':'SQL admin: '+str(error)},ensure_ascii=False))
    raise SystemExit(code)

def boolean(value):
    return value is True or str(value).lower() in ('1','true','on','yes')

def datetime_expiry(count, unit, now=None):
    if isinstance(count,bool): raise UserError('Invalid duration count')
    try: count=int(count)
    except (TypeError,ValueError): raise UserError('Invalid duration count')
    if count<1 or count>365: raise UserError('Duration count must be between 1 and 365')
    unit=UNITS.get(str(unit).lower())
    if unit is None: raise UserError('Invalid duration unit')
    now=now or dt.datetime.now(dt.timezone.utc)
    if unit in ('hours','days','weeks'):
        result=now+dt.timedelta(**{unit:count})
    else:
        add_months=count * (12 if unit=='years' else 1)
        year=now.year+(now.month-1+add_months)//12
        month=(now.month-1+add_months)%12+1
        if year>9999: raise UserError('Duration exceeds valid date range')
        day=min(now.day,calendar.monthrange(year,month)[1])
        result=now.replace(year=year,month=month,day=day)
    return result

def normalize(payload, now=None):
    if not isinstance(payload,dict): raise UserError('Invalid JSON object')
    unknown=set(payload)-GRANT_KEYS
    if unknown: raise UserError('Unsupported JSON keys: '+', '.join(sorted(str(x) for x in unknown)[:12]))
    auth_type=str(payload.get('auth_type','steamid')).strip().lower()
    auth_type={'nick':'name','nickname':'name'}.get(auth_type,auth_type)
    if auth_type not in ('steamid','name','ip'): raise UserError('Invalid auth_type')
    identity=str(payload.get('identity') or (payload.get('nickname') if auth_type=='name' else '') or '').strip()
    if not identity or len(identity.encode('utf8'))>32 or any(x in identity for x in '\n\r\x00"\\\''):
        raise UserError('Invalid admin identity')
    if auth_type=='steamid':
        if not STEAM.fullmatch(identity): raise UserError('Invalid SteamID')
        identity=identity.upper()
    elif auth_type=='ip':
        import ipaddress
        try: identity=str(ipaddress.ip_address(identity))
        except ValueError: raise UserError('Invalid IP address')
    full=boolean(payload.get('full_access'))
    raw=FULL_ACCESS if full else str(payload.get('custom_flags') or payload.get('access_flags') or '').lower().strip()
    if not ACCESS.fullmatch(raw): raise UserError('Invalid access flags (a-u)')
    access=''.join(c for c in FULL_ACCESS if c in raw)
    password=str(payload.get('password') or '')
    if len(password.encode('utf8'))>32 or any(x in password for x in '\r\n\x00'):
        raise UserError('Invalid password')
    generate=boolean(payload.get('generate_password'))
    permanent=boolean(payload.get('forever'))
    expiry=None if permanent else datetime_expiry(payload.get('duration_count',1),payload.get('duration_unit','days'),now)
    return {'identity':identity,'auth_type':auth_type,'access_flags':access,'password':password,
            'generate_password':generate}, expiry

def load_config(sid):
    if sid not in (25,26): raise UserError('Only shared SQL servers #25 and #26 are supported')
    p=SERVER_DIR/f'{sid}.json'
    if not p.is_file(): raise UserError(f'Server #{sid} config missing')
    cfg=json.loads(p.read_text())
    if cfg.get('sql_db')!='cs16_srv_25': raise UserError(f'Server #{sid} is not using cs16_srv_25')
    return cfg

def sql_connect(cfg):
    import pymysql
    return pymysql.connect(host=cfg.get('sql_host') or '127.0.0.1',port=int(cfg.get('sql_port') or 3306),
                           user=cfg['sql_user'],password=cfg['sql_password'],database='cs16_srv_25',
                           charset='utf8mb4',autocommit=False,cursorclass=pymysql.cursors.DictCursor,
                           connect_timeout=6,read_timeout=8,write_timeout=8)

def table_for(cfg):
    p=Path(cfg['path'])/'cstrike/addons/amxmodx/configs/sql.cfg'
    table='admins'
    if p.is_file():
        for line in p.read_text(errors='replace').splitlines():
            m=re.match(r'^\s*amx_sql_table\s+"?([A-Za-z0-9_]{1,64})"?',line,re.I)
            if m: table=m.group(1)
    return table

def get_row(cfg,identity):
    table=table_for(cfg)
    db=sql_connect(cfg)
    try:
        with db.cursor() as cur:
            cur.execute('SELECT `auth`,`password`,`access`,`flags` FROM `'+table+'` WHERE `auth`=%s',(identity,))
            rows=cur.fetchall()
        if len(rows)!=1: raise UserError('Expected one SQL admin row after save, found '+str(len(rows)))
        return rows[0]
    finally: db.close()

def row_fingerprint(row):
    raw='\0'.join(str(row.get(k) or '') for k in ('auth','password','access','flags'))
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()

def ensure_state():
    STATE_DIR.mkdir(parents=True,exist_ok=True,mode=0o700)
    if STATE_DIR.is_symlink(): raise UserError('State path is a symlink')
    os.chmod(STATE_DIR,0o700)
    if REGISTRY.is_symlink() or LOCK.is_symlink(): raise UserError('State file is a symlink')

def read_registry():
    if REGISTRY.exists():
        obj=json.loads(REGISTRY.read_text())
        if not isinstance(obj,dict) or obj.get('version')!=1 or not isinstance(obj.get('entries'),dict):
            raise UserError('Expiration registry has unsupported format')
        return obj
    return {'version':1,'entries':{}}

def write_registry(obj):
    fd,name=tempfile.mkstemp(prefix='.registry-',dir=STATE_DIR)
    try:
        with os.fdopen(fd,'w') as f:
            json.dump(obj,f,ensure_ascii=False,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        os.chmod(name,0o600)
        os.replace(name,REGISTRY)
    finally:
        if os.path.exists(name): os.unlink(name)

def subprocess_cli(args,stdin=b''):
    r=subprocess.run([sys.executable,str(CONTROLLER),*args],input=stdin,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=55)
    try: result=json.loads(r.stdout.decode('utf-8'))
    except (ValueError,UnicodeError):
        raise UserError('SQL controller returned an invalid response (exit '+str(r.returncode)+')')
    if r.returncode!=0 or not isinstance(result,dict) or not result.get('ok'):
        raise UserError(str(result.get('error') or 'SQL controller failed') if isinstance(result,dict) else 'SQL controller failed')
    return result

def resolve_row_id(cfg,numeric_id):
    # PHP form submits admin_id, which is a DB primary key, not the V5 0-based list index.
    if not numeric_id.isdecimal() or int(numeric_id)<=0: raise UserError('Invalid admin_id')
    db=sql_connect(cfg)
    try:
        table=table_for(cfg)
        with db.cursor() as cur:
            cur.execute('SHOW COLUMNS FROM `'+table+'`')
            columns={x['Field'] for x in cur.fetchall()}
            if 'id' not in columns: raise UserError('Admin table has no id column; unsafe deletion refused')
            cur.execute('SELECT `auth` FROM `'+table+'` WHERE `id`=%s',(int(numeric_id),))
            rows=cur.fetchall()
        if len(rows)!=1: raise UserError('Admin record not found for that admin_id')
        auth=str(rows[0]['auth'])
        if auth.isdecimal(): raise UserError('Numeric nickname deletion needs direct SQL handler; refused')
        return auth
    finally: db.close()

def reload_other_server(sid):
    other=26 if sid==25 else 25
    try:
        cfg=load_config(other)
        sys.path.insert(0,'/opt/hyper-cs16/lib')
        from csquery import rcon
        answer=rcon('127.0.0.1',int(cfg['port']),cfg['rcon_password'],'amx_reloadadmins',3.0)
        return {'server':other,'attempted':True,'response_received':answer is not None}
    except Exception:
        return {'server':other,'attempted':False,'warning':'RCON reload unavailable; reload on next map/restart'}

def main():
    args=sys.argv[1:]
    if args==['--self-test']:
        data={'auth_type':'steamid','identity':'STEAM_0:1:12','nickname':'','password':'','generate_password':False,
              'full_access':True,'access_flags':'','custom_flags':'','forever':False,'duration_count':1,'duration_unit':'days'}
        out,when=normalize(data,dt.datetime(2026,11,18,tzinfo=dt.timezone.utc))
        assert out['access_flags']==FULL_ACCESS and when.day==19
        data.update(full_access=False,custom_flags='abc',forever=True)
        out,when=normalize(data);assert out['access_flags']=='abc' and when is None
        print('SELFTEST PASSED');return
    if args and args[0] in ('sql-admin-grant','sql-admin-revoke') and ('--help' in args or '-h' in args):
        print('Usage: '+args[0]+' SERVER_ID (JSON stdin for grant; ADMIN_ID for revoke)');return
    if len(args)<2 or args[0] not in ('sql-admin-grant','sql-admin-revoke') or not args[1].isdecimal():
        raise UserError('Usage: sql-admin-grant ID (JSON stdin) | sql-admin-revoke ID ADMIN_ID')
    op,sid=args[0],int(args[1]);cfg=load_config(sid)
    ensure_state()
    with LOCK.open('a+') as lf:
        fcntl.flock(lf,fcntl.LOCK_EX)
        state=read_registry()
        if op=='sql-admin-grant':
            raw=sys.stdin.buffer.read(65537)
            if len(raw)>65536: raise UserError('JSON input too large')
            try: payload=json.loads(raw.decode('utf-8'))
            except (ValueError,UnicodeError): raise UserError('Invalid JSON input')
            norm,expires=normalize(payload)
            res=subprocess_cli(['sql-admins-save',str(sid)],json.dumps(norm,ensure_ascii=False).encode('utf8'))
            ident=norm['identity']; key=ident.casefold()
            if expires is not None:
                row=get_row(cfg,ident)
                state['entries'][key]={'server_id':sid,'identity':ident,'expires_at':expires.isoformat(),
                                       'fingerprint':row_fingerprint(row)}
            else: state['entries'].pop(key,None)
            write_registry(state)
            res['duration_label']=('Навсегда' if expires is None else 'До '+expires.strftime('%d.%m.%Y %H:%M UTC'))
            res['expires_at']=None if expires is None else expires.isoformat()
        else:
            if len(args)!=3: raise UserError('Expected admin_id for deletion')
            ident=resolve_row_id(cfg,args[2])
            res=subprocess_cli(['sql-admins-delete',str(sid),ident])
            state['entries'].pop(ident.casefold(),None)
            write_registry(state)
    res['shared_reload']=reload_other_server(sid)
    print(json.dumps(res,ensure_ascii=False,separators=(',',':')))

if __name__=='__main__':
    try: main()
    except UserError as exc: exit_json(str(exc))
    except subprocess.TimeoutExpired: exit_json('SQL controller timed out')
    except Exception as exc:
        # Never include credentials or arbitrary SQL exception in responses.
        exit_json('Internal handler error ('+type(exc).__name__+')')
PY_HELPER
cat > "$TMPDIR/expiry.py" <<'PY_EXPIRY'
#!/usr/bin/env python3
"""Expire limited AMX SQL admins from cs16_srv_25. Scheduled by HH timer."""
import datetime as dt
import fcntl
import json
from pathlib import Path
import sys

sys.path.insert(0,'/usr/local/libexec/hyper-cs16')
from importlib.machinery import SourceFileLoader
bridge=SourceFileLoader('hh_admin_bridge','/usr/local/libexec/hyper-cs16/sql-admin-alias-v14.py').load_module()


def reload_both():
    sys.path.insert(0, '/opt/hyper-cs16/lib')
    try:
        from csquery import rcon
    except Exception:
        print('[EXPIRY] Warning: csquery unavailable; AMXX will reload on game restart');return
    for sid in (25,26):
        try:
            cfg=bridge.load_config(sid)
            result=rcon('127.0.0.1',int(cfg['port']),cfg['rcon_password'],'amx_reloadadmins',3.0)
            print('[EXPIRY] Reload admins #'+str(sid)+': '+('OK' if result is not None else 'no reply'))
        except Exception as exc:
            print('[EXPIRY] Reload admins #'+str(sid)+': '+type(exc).__name__)


def main():
    bridge.ensure_state()
    expired=0
    with bridge.LOCK.open('a+') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        state=bridge.read_registry()
        now=dt.datetime.now(dt.timezone.utc)
        changed=False
        for key,data in list(state['entries'].items()):
            try:
                expires=dt.datetime.fromisoformat(data['expires_at'])
                if expires.tzinfo is None: raise ValueError('Missing timezone')
                if expires>now: continue
                sid=int(data['server_id']); cfg=bridge.load_config(sid)
                ident=data['identity']; fp=data['fingerprint']
                table=bridge.table_for(cfg)
                con=bridge.sql_connect(cfg)
                try:
                    with con.cursor() as cur:
                        cur.execute('SELECT `auth`,`password`,`access`,`flags` FROM `'+table+'` WHERE `auth`=%s FOR UPDATE',(ident,))
                        rows=cur.fetchall()
                        if len(rows)==1 and bridge.row_fingerprint(rows[0])==fp:
                            cur.execute('DELETE FROM `'+table+'` WHERE `auth`=%s',(ident,))
                            if cur.rowcount!=1: raise RuntimeError('Unexpected row count')
                            expired+=1
                        elif len(rows)>1: raise RuntimeError('Multiple matching rows; refusing deletion')
                        else:
                            print('[EXPIRY] Admin entry changed/removed; not deleting newer credentials')
                    con.commit()
                except Exception:
                    con.rollback();raise
                finally: con.close()
                del state['entries'][key];changed=True
            except Exception as exc:
                print('[EXPIRY] Error on one scheduled entry: '+type(exc).__name__)
        if changed: bridge.write_registry(state)
    if expired: reload_both()
    print('[EXPIRY] Expired admins removed:',expired)

if __name__=='__main__':
    try: main()
    except Exception as exc:
        print('[EXPIRY] Fatal: '+type(exc).__name__,file=sys.stderr);raise SystemExit(1)
PY_EXPIRY
cat > "$TMPDIR/service" <<'UNIT_SERVICE'
# HH-CS16 SQL Admin V16 expiry service
[Unit]
Description=Expire limited CS 1.6 SQL administrators
After=network.target mariadb.service

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/python3 /usr/local/libexec/hyper-cs16/sql-admin-expiry-v16.py
TimeoutStartSec=65
UNIT_SERVICE
cat > "$TMPDIR/timer" <<'UNIT_TIMER'
# HH-CS16 SQL Admin V16 expiry timer
[Unit]
Description=Check timed CS 1.6 SQL administrators

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true
Unit=hh-cs16-admin-expiry.service

[Install]
WantedBy=timers.target
UNIT_TIMER
python3 -m py_compile "$TMPDIR/helper.py" "$TMPDIR/expiry.py"
python3 "$TMPDIR/helper.py" --self-test | grep -q 'SELFTEST PASSED' || die 'Payload unit test failed'
if [[ "$MODE" == check ]]; then
    say 'CHECK PASSED: exact 11-field PHP JSON accepted; permanent and timed access supported'
    say 'No SQL data or files changed'
    exit 0
fi
if [[ "$MODE" == verify ]]; then
    grep -q 'HYPER-HOST SQL Admin V16' "$HELPER" || die 'V16 helper not installed'
    grep -q 'HH-CS16 SQL Admin V16' "$SERVICE" || die 'Expiry service missing'
    grep -q 'HH-CS16 SQL Admin V16' "$TIMER" || die 'Expiry timer missing'
    python3 "$HELPER" --self-test
    php -l "$PHP"
    systemctl is-enabled --quiet hh-cs16-admin-expiry.timer || die 'Expiry timer is not enabled'
    systemctl is-active --quiet hh-cs16-admin-expiry.timer || die 'Expiry timer is not active'
    say 'VERIFY PASSED: PHP bridge + timed expiration scheduler installed; no admin rows modified by this test'
    exit 0
fi

mkdir -p "$BACKUPS"
BACKUP="$BACKUPS/sql-admin-v16-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 "$BACKUP"
cp -a "$PHP" "$BACKUP/index.php.before"
cp -a "$HELPER" "$BACKUP/helper.before"
for target in "$WORKER" "$SERVICE" "$TIMER"; do
    name=$(basename "$target")
    if [[ -e "$target" ]]; then cp -a "$target" "$BACKUP/$name.before"; else touch "$BACKUP/$name.absent"; fi
done
say "Backup: $BACKUP"
rollback(){
    say 'ROLLBACK: restoring PHP, helper and timer files'
    cp -a "$BACKUP/index.php.before" "$PHP"
    cp -a "$BACKUP/helper.before" "$HELPER"
    for target in "$WORKER" "$SERVICE" "$TIMER"; do
        name=$(basename "$target")
        if [[ -e "$BACKUP/$name.before" ]]; then cp -a "$BACKUP/$name.before" "$target"; else rm -f "$target"; fi
    done
    if [[ ! -f "$TIMER" ]]; then systemctl disable --now hh-cs16-admin-expiry.timer >/dev/null 2>&1 || true; fi
    systemctl daemon-reload || true
    if [[ -e "$SERVICE" && -e "$TIMER" ]]; then systemctl try-restart hh-cs16-admin-expiry.timer || true; fi
}
APPLIED=1

# Never change the existing AMXX or MySQL controller. Replace only V15 helper.
install -o root -g root -m 0750 "$TMPDIR/helper.py" "$HELPER"
install -o root -g root -m 0750 "$TMPDIR/expiry.py" "$WORKER"
python3 - "$PHP" <<'PY_PHP'
from pathlib import Path
import os,stat,sys,tempfile
p=Path(sys.argv[1]);s=p.read_text()
old="ctl(['sql-admin-delete',$id,$adminId]"
new="ctl(['sql-admin-revoke',$id,$adminId]"
if old in s:
    if s.count(old)!=1: raise SystemExit('Unexpected PHP delete call count')
    s=s.replace(old,new,1)
elif new not in s: raise SystemExit('Deletion call missing')
st=p.stat()
fd,tmp=tempfile.mkstemp(prefix='.hh-admin-v16-',dir=p.parent)
try:
    with os.fdopen(fd,'w') as f:
        f.write(s);f.flush();os.fsync(f.fileno())
    os.chmod(tmp,stat.S_IMODE(st.st_mode));os.chown(tmp,st.st_uid,st.st_gid)
    os.replace(tmp,p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY_PHP
php -l "$PHP" >/dev/null || die 'PHP syntax invalid after installation'
install -o root -g root -m 0644 "$TMPDIR/service" "$SERVICE"
install -o root -g root -m 0644 "$TMPDIR/timer" "$TIMER"
mkdir -p -m 0700 "$STATE_DIR"
chmod 0700 "$STATE_DIR"
systemctl daemon-reload
systemctl enable --now hh-cs16-admin-expiry.timer
python3 "$HELPER" --self-test | grep -q 'SELFTEST PASSED' || die 'Installed adapter test failed'
python3 "$HELPER" sql-admin-grant --help | grep -q 'Usage:' || die 'Grant help failed'
python3 "$HELPER" sql-admin-revoke --help | grep -q 'Usage:' || die 'Revoke help failed'
systemctl is-active --quiet hh-cs16-admin-expiry.timer || die 'Expiry timer did not start'
SUCCESS=1
say 'APPLY SUCCESS: exact PHP grant JSON supported; delete routed to revoke; expiry timer active'
say 'SQL cs16_srv_25, game servers, FTP, FastDL and bots were not modified by installation'
say 'Run: sudo bash HH_CS16_SQL_ADMIN_PHP_V16.sh verify'
