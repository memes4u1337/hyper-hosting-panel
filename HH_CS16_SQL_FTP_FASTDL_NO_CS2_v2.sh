#!/usr/bin/env bash
# HYPER-HOST v2: shared existing game SQL + CS1.6 FTP/FastDL + CS2 retirement
# Targets repository main as inspected 2026-11-17. Does NOT create/drop MySQL databases.
set -Eeuo pipefail
umask 077

REPO="${HYPER_REPO_DIR:-/root/hyper-hosting-panel}"
SRC="$REPO/cs16-panel/bin/hyper-cs16-ctl"
CTL=/usr/local/sbin/hyper-cs16-ctl
HHCTL=/usr/local/sbin/hyper-host-ctl
CFG=/etc/hyper-cs16/shared-sql.json
STATE=/var/lib/hyper-cs16/servers
RUNTIME=/etc/hyper-cs16/runtime.json
FROOT=/srv/hyper-cs16/fastdl
FASTDL_PORT="${CS16_FASTDL_PORT:-8088}"
BACKUP="/opt/hyper-cs16/backups/hh-fix-$(date +%Y%m%d_%H%M%S)-$$"
NGINXCONF=/etc/nginx/hyper-host-managed/99-hyper-cs16-fastdl.conf
NGINX_REGEN_SOURCE="$REPO/scripts/nginx_recover_v89.py"
MODE="${1:-apply}"

log(){ printf '\033[1;36m[HH-CS16]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[HH-WARN]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[HH-ERROR]\033[0m %s\n' "$*" >&2; return 1; }
usage(){ cat <<'EOF'
Usage: sudo bash HH_CS16_SQL_FTP_FASTDL_NO_CS2.sh [apply|check]
Optional environment:
 CS16_SHARED_FROM_ID=25                  # take existing game database/user/pass from server 25
 CS16_SHARED_DB=... CS16_SHARED_USER=... CS16_SHARED_PASSWORD=... # existing account only
 CS16_FASTDL_PORT=8088                   # separate Nginx fastdl listener fallback
 CS16_SKIP_CS2_DELETE=1                  # retain CS2 runtime/data
 CS2_SITE_DOMAIN=cs2.example.com         # explicitly remove this CS2 site (requires 'cs2' in hostname)
Existing game databases are never deleted; old servers retain their previous SQL settings.
EOF
}
[[ $MODE == apply || $MODE == check ]] || { usage; exit 2; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Launch with sudo/root'
for x in python3 nginx php rsync systemctl curl; do command -v "$x" >/dev/null 2>&1 || fail "Missing dependency: $x"; done
[[ -f "$SRC" ]] || fail "Repo source not found: $SRC; first git clone/fetch from GitHub"
[[ -f "$RUNTIME" && -d "$STATE" ]] || fail 'CS1.6 runtime not installed. Refusing to reinstall it automatically.'
[[ -f "$CTL" ]] || fail "CS1.6 controller not found: $CTL"
[[ -f "$REPO/scripts/hhctl" ]] || fail 'Missing source HYPER-HOST controller: scripts/hhctl'
[[ "$FASTDL_PORT" =~ ^[0-9]{2,5}$ ]] || fail 'Invalid FASTDL_PORT'
((FASTDL_PORT >= 1024 && FASTDL_PORT <= 65535)) || fail 'FASTDL_PORT must be 1024..65535'

WORK=$(mktemp -d /tmp/hh-cs16-fix.XXXXXX)
cleanup(){ rm -rf -- "$WORK"; }
trap cleanup EXIT
# Do not expose passwords through logs or process arguments.
log 'Finding an existing GAME SQL account (no database will be created).'
python3 - "$CFG" "$STATE" "$RUNTIME" "$WORK/shared.json" <<'PY'
import os,sys,json,pathlib,re
cfg,state,rt,out=map(pathlib.Path,sys.argv[1:])
try: import pymysql
except ImportError: raise SystemExit('python3-pymysql not installed; install it before running patch')
runtime=json.loads(rt.read_text())
existing_game=[]
source=os.getenv('CS16_SHARED_FROM_ID','').strip()
if os.getenv('CS16_SHARED_DB') or os.getenv('CS16_SHARED_USER') or os.getenv('CS16_SHARED_PASSWORD'):
    if not all(os.getenv(k) for k in ('CS16_SHARED_DB','CS16_SHARED_USER','CS16_SHARED_PASSWORD')):
        raise SystemExit('Specify all three: CS16_SHARED_DB, CS16_SHARED_USER, CS16_SHARED_PASSWORD')
    d={'host':'127.0.0.1','port':3306,'database':os.environ['CS16_SHARED_DB'],'user':os.environ['CS16_SHARED_USER'],'password':os.environ['CS16_SHARED_PASSWORD']}; origin='explicit environment'
elif source:
    f=state/f'{source}.json'
    if not f.is_file(): raise SystemExit('Specified CS16_SHARED_FROM_ID has no runtime JSON: '+str(f))
    c=json.loads(f.read_text())
    if not all(c.get(k) for k in ('sql_db','sql_user','sql_password')):
        raise SystemExit('Specified server has no SQL credentials: '+source)
    d={'host':str(c.get('sql_host') or '127.0.0.1'),'port':int(c.get('sql_port') or 3306),'database':str(c['sql_db']),'user':str(c['sql_user']),'password':str(c['sql_password'])}; origin='server '+source
elif cfg.is_file():
    d=json.loads(cfg.read_text()); origin='previous shared-sql configuration'
else:
    files=sorted(state.glob('*.json'),key=lambda p: int(p.stem) if p.stem.isdigit() else 999999)
    d=None; origin=''
    for f in files:
        if not f.is_file(): continue
        try: c=json.loads(f.read_text())
        except Exception: continue
        if c.get('sql_db') and c.get('sql_user') and c.get('sql_password'):
            d={'host':str(c.get('sql_host') or '127.0.0.1'),'port':int(c.get('sql_port') or 3306),'database':str(c['sql_db']),'user':str(c['sql_user']),'password':str(c['sql_password'])}
            origin='server '+f.stem; break
    if d is None: raise SystemExit('No existing game SQL credentials found. Set CS16_SHARED_FROM_ID or explicit CS16_SHARED_DB/USER/PASSWORD.')
d={'host':str(d.get('host') or '127.0.0.1'),'port':int(d.get('port') or 3306),'database':str(d.get('database') or ''),'user':str(d.get('user') or ''),'password':str(d.get('password') or '')}
if d['host'] not in ('127.0.0.1','localhost') or d['port'] != 3306:
    raise SystemExit('Current patch supports existing local game MySQL on 127.0.0.1:3306 only.')
if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',d['database']) or not re.fullmatch(r'[A-Za-z0-9_]{1,64}',d['user']) or not d['password']:
    raise SystemExit('Invalid or missing existing game SQL credentials')
if d['database']==runtime.get('db_name') and os.getenv('CS16_ALLOW_PANEL_DB')!='1':
    raise SystemExit('Refusing to give game plugins credentials to PANEL database. Use existing dedicated game SQL, e.g. CS16_SHARED_FROM_ID=25.')
try:
    c=pymysql.connect(host='127.0.0.1',port=3306,user=d['user'],password=d['password'],database=d['database'],connect_timeout=5,charset='utf8mb4')
    with c.cursor() as cur: cur.execute('SELECT DATABASE()'); got=cur.fetchone()[0]
    c.close()
except Exception as exc: raise SystemExit('Cannot authenticate to existing game SQL: '+str(exc).split('\n')[0])
if got!=d['database']: raise SystemExit('DB selection mismatch')
out.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n'); out.chmod(0o600)
print('Validated existing SQL:',d['database'],'user:',d['user'],'source:',origin,'(password hidden)')
PY

# Patch only functions checked against the inspected upstream version. Refuse unexpected source changes.
python3 - "$SRC" "$WORK/controller" <<'PY'
import pathlib,sys,re,ast
src,dest=map(pathlib.Path,sys.argv[1:])
s=src.read_text(encoding='utf-8')
if 'HH_SHARED_SQL_PATCH_2026_11' in s:
    dest.write_text(s); ast.parse(s); print('Repository source already patched'); raise SystemExit(0)

def replacement(text,start,end,new):
    a=text.find(start); b=text.find(end,a+len(start))
    if a<0 or b<0 or b<=a: raise SystemExit(f'Cannot find exact block: {start} -> {end}; upstream changed; refusing to patch')
    if text.find(start,a+len(start))!=-1: raise SystemExit(f'Ambiguous block: {start}')
    return text[:a]+new.rstrip()+'\n\n'+text[b:]

new_sql='''def sql_provision(sid:int, rotate:bool=False):
    # HH_SHARED_SQL_PATCH_2026_11: all NEW servers use pre-existing game SQL.
    # No CREATE DATABASE, CREATE USER, GRANT, ALTER USER or password rotation.
    require_root()
    if rotate:
        raise RuntimeError('Shared SQL mode: rotation is disabled (would affect other game servers)')
    c=load_server(sid)
    root=Path(c['path'])
    if not root.is_dir(): raise RuntimeError(f'Server directory missing: {root}')
    shared_file=ETC_ROOT/'shared-sql.json'
    if not shared_file.is_file(): raise RuntimeError('Missing existing shared SQL config: '+str(shared_file))
    credentials=json.loads(shared_file.read_text(encoding='utf-8'))
    host=str(credentials.get('host') or '127.0.0.1')
    port=int(credentials.get('port') or 3306)
    db_name=str(credentials['database']); db_user=str(credentials['user']); password=str(credentials['password'])
    if host not in ('127.0.0.1','localhost') or port!=3306:
        raise RuntimeError('Shared game SQL must be 127.0.0.1:3306 for this version')
    if not re.fullmatch(r'[A-Za-z0-9_]{1,64}',db_name) or not re.fullmatch(r'[A-Za-z0-9_]{1,64}',db_user):
        raise RuntimeError('Invalid shared SQL identity')
    try:
        import pymysql
        con=pymysql.connect(host='127.0.0.1',port=3306,user=db_user,password=password,database=db_name,connect_timeout=5,charset='utf8mb4')
        with con.cursor() as cur: cur.execute('SELECT 1'); cur.fetchone()
        con.close()
        cfg_path_written=_write_amxx_sql_cfg(c,db_name,db_user,password)
        c['sql_enabled']=True; c['sql_host']='127.0.0.1'; c['sql_port']=3306
        c['sql_db']=db_name; c['sql_user']=db_user; c['sql_password']=password
        c['sql_config_path']=cfg_path_written
        save_server(c); normalize_permissions(root)
        _sql_meta_update(sid,db_name,db_user,cfg_path_written,'ready','')
        return {'ok':True,'id':sid,'host':'127.0.0.1','port':3306,'database':db_name,'user':db_user,'password':password,
                'config_path':cfg_path_written,'standard_amxx_sql':True,'shared_existing_database':True,'telemetry':'panel-db'}
    except Exception as exc:
        _sql_meta_update(sid,db_name,db_user,str(root/'cstrike/addons/amxmodx/configs/sql.cfg'),'error',str(exc))
        raise
'''
s=replacement(s,'def sql_provision(sid:int, rotate:bool=False):','def sql_status(sid:int):',new_sql)

new_ftp='''def setup_ftp(c:dict,path:Path,password:str|None=None):
    # HH patch: persist credentials even if the FTP daemon is temporarily broken.
    # Newly created servers can then be repaired without losing the shown password.
    user=c.get('ftp_user') or f'cs16_{c["id"]}'
    password=password or c.get('ftp_password') or secrets.token_urlsafe(12)
    c['ftp_user']=user; c['ftp_password']=password
    ctl=shutil.which('hyper-host-ctl') or '/usr/local/sbin/hyper-host-ctl'
    if not Path(ctl).exists():
        return user,password,'HYPER-HOST FTP controller not found'
    old_home=Path('/var/www/hyper-host-ftp')/user/'uploads'
    run(['umount','-lf',str(old_home)],check=False)
    run(['chown','cs16:www-data',str(path)],check=False)
    run(['chmod','2775',str(path)],check=False)
    cmd=[ctl,'create-ftp',user,password,'cs16',str(int(c['id']))]
    cp=run(cmd,check=False,timeout=180)
    if cp.returncode!=0:
        # Repair the shared ProFTPD stack, then retry with the same password.
        run([ctl,'ftp-fix'],check=False,timeout=180)
        cp=run(cmd,check=False,timeout=180)
    if cp.returncode!=0:
        return user,password,(cp.stdout or 'FTP account creation failed').strip()[-1800:]
    return user,password,''
'''
s=replacement(s,'def setup_ftp(c:dict,path:Path,password:str|None=None):','def ftp_test(sid:int):',new_ftp)

new_fastdl='''def _fastdl_url(c:dict)->str:
    # HH patch: read a verified static FastDL endpoint; preserve per-server URL.
    sid=int(c.get('id') or 0)
    path=ETC_ROOT/'fastdl-base-url'
    if path.is_file():
        base=path.read_text(encoding='utf-8').strip().rstrip('/')
        if re.fullmatch(r'http://[A-Za-z0-9.:-]+/fastdl',base):
            return f'{base}/{sid}'
    public=str(load_runtime().get('public_ip') or c.get('public_ip') or '').strip()
    try:
        ip=ipaddress.ip_address(public)
        if ip.version==4 and not ip.is_unspecified:
            return f'http://{public}:8088/fastdl/{sid}'
    except Exception:
        pass
    return f'http://{FASTDL_DOMAIN}:8088/fastdl/{sid}'
'''
s=replacement(s,'def _fastdl_url(c:dict)->str:','def _fastdl_apply_cfg(c:dict, root:Path|None=None)->dict:',new_fastdl)
ast.parse(s,filename=str(src)); dest.write_text(s,encoding='utf-8')
print('Python AST validated. Shared SQL, resilient FTP and configurable FastDL source patched.')
PY

php -l /dev/null >/dev/null 2>&1 || true
python3 -m py_compile "$WORK/controller"
if [[ $MODE == check ]]; then
    log 'CHECK PASSED. Nothing has been changed.'
    log 'Existing SQL verified, controller transformed and compiled successfully.'
    log 'To install run: sudo bash HH_CS16_SQL_FTP_FASTDL_NO_CS2_v2.sh apply'
    exit 0
fi

mkdir -p "$BACKUP" "$FROOT"
chmod 0755 /srv/hyper-cs16 "$FROOT" || true
log "Backup: $BACKUP"
cp -a "$SRC" "$BACKUP/repo-hyper-cs16-ctl"
cp -a "$CTL" "$BACKUP/runtime-hyper-cs16-ctl"
[[ -f "$CFG" ]] && cp -a "$CFG" "$BACKUP/shared-sql.json" || true
[[ -f "$NGINXCONF" ]] && cp -a "$NGINXCONF" "$BACKUP/nginx-fastdl.conf" || true
[[ -f /etc/hyper-cs16/fastdl-base-url ]] && cp -a /etc/hyper-cs16/fastdl-base-url "$BACKUP/fastdl-base-url" || true
[[ -f "$HHCTL" ]] && cp -a "$HHCTL" "$BACKUP/hyper-host-ctl" || true
# Back up the generator if present. It is modified below to preserve our managed FastDL drop-in.
GENERATOR_FILES=(
  "$NGINX_REGEN_SOURCE"
  /opt/hyper-host/nginx_recover_v89.py
  /opt/hyper-host/bin/nginx_recover_v89.py
  /opt/hyper-host/scripts/nginx_recover_v89.py
  /usr/local/sbin/nginx_recover_v89.py
)
mkdir -p "$BACKUP/generators"
for idx in "${!GENERATOR_FILES[@]}"; do
  file="${GENERATOR_FILES[$idx]}"
  if [[ -f "$file" ]]; then cp -a -- "$file" "$BACKUP/generators/$idx"; fi
done
cp -a "$RUNTIME" "$BACKUP/cs16-runtime.json"
if command -v sqlite3 >/dev/null 2>&1 && [[ -f /opt/hyper-host/data/hyperhost.sqlite ]]; then
    sqlite3 /opt/hyper-host/data/hyperhost.sqlite ".backup '$BACKUP/hyperhost.sqlite'" || warn 'Main SQLite backup skipped'
fi
# Keep existing CS2 settings in the backup, but never copy a 41GB downloaded game assembly.
[[ -d /etc/hyper-cs2 ]] && cp -a /etc/hyper-cs2 "$BACKUP/cs2-etc" || true
[[ -d /var/lib/hyper-cs2 ]] && cp -a /var/lib/hyper-cs2 "$BACKUP/cs2-state" || true
# CS2 own domain, if any (CS1.6 domain is never a cleanup target).
if [[ -z "${CS2_SITE_DOMAIN:-}" && -f /etc/hyper-cs2/runtime.json ]]; then
    CS2_SITE_DOMAIN="$(python3 - /etc/hyper-cs2/runtime.json <<'PYCS2DOMAIN'
import json,sys
try: print(json.load(open(sys.argv[1])).get('domain',''))
except Exception: print('')
PYCS2DOMAIN
)"
fi

rollback(){
    local code=$?
    trap - ERR
    warn "Patch failed (exit $code). Restoring code/config from $BACKUP"
    cp -a "$BACKUP/repo-hyper-cs16-ctl" "$SRC" || true
    cp -a "$BACKUP/runtime-hyper-cs16-ctl" "$CTL" || true
    [[ -f "$BACKUP/shared-sql.json" ]] && cp -a "$BACKUP/shared-sql.json" "$CFG" || rm -f "$CFG"
    [[ -f "$BACKUP/fastdl-base-url" ]] && cp -a "$BACKUP/fastdl-base-url" /etc/hyper-cs16/fastdl-base-url || rm -f /etc/hyper-cs16/fastdl-base-url
    [[ -f "$BACKUP/nginx-fastdl.conf" ]] && cp -a "$BACKUP/nginx-fastdl.conf" "$NGINXCONF" || rm -f "$NGINXCONF"
    [[ -f "$BACKUP/hyper-host-ctl" ]] && cp -a "$BACKUP/hyper-host-ctl" "$HHCTL" || true
    local idx file
    for idx in "${!GENERATOR_FILES[@]}"; do
        file="${GENERATOR_FILES[$idx]}"
        [[ -f "$BACKUP/generators/$idx" ]] && cp -a "$BACKUP/generators/$idx" "$file" || true
    done
    rm -f "$FROOT"/HH_FDL_CHECK_*.txt 2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    exit "$code"
}
trap rollback ERR
install -o root -g root -m 0600 "$WORK/shared.json" "$CFG"
install -o root -g root -m 0755 "$WORK/controller" "$SRC"
install -o root -g root -m 0755 "$WORK/controller" "$CTL"

# Install the upstream controller if the installed variant lacks CS1.6 FTP scope.
if ! grep -Fq 'cs16|game|game-server|counter-strike' "$HHCTL"; then
    log 'Updating main HYPER-HOST controller to version with cs16 FTP scope.'
    bash -n "$REPO/scripts/hhctl"
    install -o root -g root -m 0755 "$REPO/scripts/hhctl" "$HHCTL"
fi

# HYPER-HOST may mount /etc/nginx read-only; activate its writable runtime first.
if [[ ! -w /etc/nginx ]]; then
    log 'Repairing writable Nginx configuration runtime.'
    "$HHCTL" nginx-runtime-fix
fi
# This HYPER-HOST release generates /etc/nginx/nginx.conf with ONLY
# "include /etc/nginx/hyper-host-managed/*.conf;" (not conf.d).
# Preserve the FastDL drop-in if the v89 Nginx reconciler regenerates managed vhosts.
for file in "${GENERATOR_FILES[@]}"; do
    [[ -f "$file" ]] || continue
    python3 - "$file" <<'PY_NGINX_GENERATOR'
from pathlib import Path
import ast,sys
path=Path(sys.argv[1]); text=path.read_text(encoding='utf-8')
old='for old in managed.glob("*.conf"):\n        old.unlink(missing_ok=True)'
new='for old in managed.glob("*.conf"):\n        if old.name == "99-hyper-cs16-fastdl.conf":\n            continue\n        old.unlink(missing_ok=True)'
if new not in text:
    if old not in text:
        print('[HH-WARN] Nginx generator structure unknown; skipping persistence modification:',path)
        raise SystemExit(0)
    text=text.replace(old,new,1)
    ast.parse(text,filename=str(path))
    path.write_text(text,encoding='utf-8')
    print('[HH-CS16] Protected FastDL vhost from generator cleanup:',path)
PY_NGINX_GENERATOR
done
# Static FastDL server must live inside the directory actually included by the
# HYPER-HOST Nginx runtime; config syntax validity alone is not sufficient.
mkdir -p "$(dirname "$NGINXCONF")"
cat > "$NGINXCONF" <<EOF
# HYPER-HOST CS1.6 FastDL — static files only; no scripts are executed
server {
    listen ${FASTDL_PORT};
    server_name _;
    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    location ^~ /fastdl/ {
        root /srv/hyper-cs16;
        autoindex off;
        limit_except GET HEAD { deny all; }
        try_files \$uri =404;
        add_header Cache-Control 'public, max-age=3600' always;
    }
    location / { return 404; }
}
EOF
chmod 0644 "$NGINXCONF"
nginx -t
# Ensure the FastDL server is actually included. HYPER-HOST formerly omitted
# /etc/nginx/conf.d so nginx -t was green although FastDL wasn't loaded.
nginx -T > "$WORK/nginx-active.txt" 2>&1
if ! grep -Fq "# configuration file $NGINXCONF:" "$WORK/nginx-active.txt"; then
    warn 'Nginx config is valid but our FastDL vhost is NOT included!'
    grep -E 'include .*(conf|managed|sites-enabled)' "$WORK/nginx-active.txt" | head -n 12 >&2 || true
    fail "Nginx does not load $NGINXCONF; no changes to the master nginx.conf were attempted."
fi
if ! systemctl is-active --quiet nginx; then
    fail 'Nginx is not active; refusing to restart the entire web stack automatically'
fi
systemctl reload nginx

# Test static FastDL file locally, tolerating the brief worker reload window.
probe="HH_FDL_CHECK_$$_$(date +%s).txt"
printf '%s\n' 'HYPER-CS16-FASTDL-OK' > "$FROOT/$probe"
chmod 0644 "$FROOT/$probe"
GOOD=0
for attempt in 1 2 3 4 5; do
    output="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 "http://127.0.0.1:$FASTDL_PORT/fastdl/$probe" 2>/dev/null || true)"
    if [[ "$output" == 'HYPER-CS16-FASTDL-OK' ]]; then GOOD=1; break; fi
    sleep 1
done
if (( GOOD != 1 )); then
    warn "Expected HTTP listener :$FASTDL_PORT is not serving FastDL"
    ss -lntp 2>/dev/null | grep -E "(:$FASTDL_PORT[[:space:]]|State)" >&2 || true
    systemctl --no-pager --full status nginx 2>&1 | tail -n 18 >&2 || true
    fail 'FastDL Nginx static test failed after 5 attempts'
fi
log "Nginx static FastDL verified locally on port $FASTDL_PORT."

# If the existing game-panel website can serve /fastdl/ on port 80 without redirects,
# use it so no new NAT forwarding is needed. Otherwise use the dedicated port.
DOMAIN="$(python3 - "$RUNTIME" <<'PY'
import json,sys
print(str(json.load(open(sys.argv[1])).get('domain','www.avito.hyper-host.pw')))
PY
)"
PUBLIC="$(python3 - "$RUNTIME" <<'PY'
import json,sys
print(str(json.load(open(sys.argv[1])).get('public_ip','')))
PY
)"
[[ "$PUBLIC" =~ ^[0-9.]+$ ]] || fail "Invalid public IP from CS16 runtime: $PUBLIC"
URL="http://$PUBLIC:$FASTDL_PORT/fastdl"
SITE="/var/www/hyper-host-sites/$DOMAIN/public_html"
if [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ && -d "$SITE" ]]; then
    if [[ ! -e "$SITE/fastdl" && ! -L "$SITE/fastdl" ]]; then
        ln -s "$FROOT" "$SITE/fastdl"
    fi
    if [[ -L "$SITE/fastdl" && "$(readlink -f "$SITE/fastdl")" == "$(readlink -f "$FROOT")" ]]; then
        check_out="$(curl --noproxy '*' -sS --connect-timeout 2 --max-time 7 -H "Host: $DOMAIN" "http://127.0.0.1/fastdl/$probe" || true)"
        if [[ "$check_out" == 'HYPER-CS16-FASTDL-OK' ]]; then
            URL="http://$DOMAIN/fastdl"
            log 'Existing site FastDL works on port 80; using it (no extra NAT port).'
        else
            warn 'Existing site does not serve plain HTTP FastDL on port 80; using dedicated listener.'
        fi
    fi
fi
printf '%s\n' "$URL" > /etc/hyper-cs16/fastdl-base-url
chmod 0644 /etc/hyper-cs16/fastdl-base-url
rm -f "$FROOT/$probe"

# Make sure the FTP engine is actually the one used by HYPER-HOST (ProFTPD,
# NOT another vsftpd process binding the same port 21).
if systemctl is-active --quiet vsftpd 2>/dev/null; then
    warn 'Stopping conflicting legacy vsftpd (HYPER-HOST uses ProFTPD/fallback).'
    systemctl stop vsftpd || warn 'Could not stop vsftpd'
fi
log 'Repairing shared FTP runtime.'
if ! "$HHCTL" ftp-fix; then warn 'hyper-host-ctl ftp-fix returned an error; check service diagnostics below.'; fi
if command -v ufw >/dev/null 2>&1; then
    ufw allow 21/tcp >/dev/null 2>&1 || true
    ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
    ufw allow "$FASTDL_PORT/tcp" >/dev/null 2>&1 || true
fi

# Rebuild FTP accounts and FastDL for each existing CS1.6 server.
FTP_ERRORS=0; FDL_ERRORS=0
shopt -s nullglob
for cfgfile in "$STATE"/*.json; do
    sid="${cfgfile##*/}"; sid="${sid%.json}"
    [[ "$sid" =~ ^[0-9]+$ ]] || continue
    [[ -d "/srv/hyper-cs16/servers/$sid" ]] || { warn "Server $sid missing on disk; skipped"; continue; }
    log "CS1.6 #$sid: repairing FTP ..."
    if ! result="$("$CTL" ftp-repair "$sid" 2>&1)"; then
        warn "FTP #$sid: $(python3 -c 'import sys,json; s=sys.stdin.read();
try:
 d=json.loads(s); d.pop("ftp_password",None); print(json.dumps(d,ensure_ascii=False))
except Exception: print("FTP diagnostic failed; inspect service logs")' <<< "$result")"; FTP_ERRORS=$((FTP_ERRORS+1))
    else
        python3 -c 'import json,sys; x=json.loads(sys.stdin.read()); print("FTP login:",x.get("ftp_user","?"),"self-test:","OK" if x.get("ok") else x.get("test",{}).get("error","FAILED"))' <<< "$result" || true
    fi
    log "CS1.6 #$sid: syncing FastDL ..."
    if ! fresult="$("$CTL" fastdl-sync "$sid" 2>&1)"; then
        warn "FastDL #$sid: $fresult"; FDL_ERRORS=$((FDL_ERRORS+1))
    fi
done
shopt -u nullglob

# Remove ONLY dedicated CS2 units/files, never shared SteamCMD, MySQL or CS1.6 files.
# Deletion is intentionally after CS1.6 validation. Local files cannot be recovered
# from the lightweight backup when 41GB game assembly is deleted.
# Disabling rollback here prevents giving a false impression that a deleted CS2
# assembly can be restored from the lightweight configuration backup.
trap - ERR
if [[ "${CS16_SKIP_CS2_DELETE:-0}" != '1' ]]; then
    log 'Stopping/removing CS2-only services and downloaded CS2 runtime.'
    while IFS= read -r unit; do
        [[ "$unit" =~ ^hyper-cs2[a-zA-Z0-9@_.-]*\.service$ ]] || continue
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
    done < <(systemctl list-units --all --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^hyper-cs2' || true)
    for uf in /etc/systemd/system/hyper-cs2*.service; do
        [[ -e "$uf" || -L "$uf" ]] || continue
        cp -a "$uf" "$BACKUP/$(basename "$uf")" || true
        rm -f -- "$uf"
    done
    systemctl daemon-reload
    # Fixed whitelist ensures user-controlled or symlinked paths cannot turn into arbitrary deletion.
    for path in /srv/hyper-cs2 /opt/hyper-cs2 /etc/hyper-cs2 /var/lib/hyper-cs2 /var/www/hyper-cs2; do
        [[ -e "$path" || -L "$path" ]] || continue
        if mountpoint -q "$path"; then warn "CS2 mount point skipped: $path"; continue; fi
        if [[ -L "$path" ]]; then rm -f -- "$path"; continue; fi
        log "Removing CS2-only path $path"
        rm -rf --one-file-system -- "$path"
    done
    for path in /usr/local/sbin/hyper-cs2-ctl /usr/local/sbin/hyper-cs2-run /usr/local/sbin/hyper-cs2-monitor /usr/local/bin/hyper-cs2-ctl; do
        [[ -e "$path" || -L "$path" ]] && rm -f -- "$path" || true
    done
    # Remove only an explicitly named/detected CS2-specific web site; never the CS1.6 domain.
    CS2_SITE="${CS2_SITE_DOMAIN:-}"
    if [[ -n "$CS2_SITE" && "$CS2_SITE" == *cs2* && "$CS2_SITE" != "$DOMAIN" && "$CS2_SITE" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log "Disabling CS2-only web site: $CS2_SITE"
        "$HHCTL" delete-site "$CS2_SITE" --delete-files || warn 'CS2 site could not be removed automatically'
        if command -v sqlite3 >/dev/null 2>&1 && [[ -f /opt/hyper-host/data/hyperhost.sqlite ]]; then
            sqlite3 /opt/hyper-host/data/hyperhost.sqlite "DELETE FROM sites WHERE domain='$CS2_SITE';" || true
        fi
    fi
else
    warn 'CS2 deletion was skipped by CS16_SKIP_CS2_DELETE=1.'
fi

nginx -t
systemctl reload nginx
python3 -m py_compile "$CTL"
log "COMPLETE: shared existing game SQL is configured; FastDL base URL: $URL"
log "Backup: $BACKUP"
log "FTP repair errors: $FTP_ERRORS; FastDL sync errors: $FDL_ERRORS"
log "Game SQL is NOT recreated; existing servers retain their original connections."
log "Check: sudo hyper-cs16-ctl doctor; sudo hyper ftp doctor"
log "If $URL uses :$FASTDL_PORT, forward TCP $FASTDL_PORT on your router to this Linux host."
if ((FTP_ERRORS>0 || FDL_ERRORS>0)); then warn 'Some diagnostics failed; see output above. Do not claim all existing FTP/FastDL connections are working yet.'; fi
trap - ERR
