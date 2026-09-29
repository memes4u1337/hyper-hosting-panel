#!/usr/bin/env bash
# =============================================================================
# HYPER-HOST / OLD ZOMBIE - FASTDL-FIX v2
#
# Usage:   sudo bash apply-fastdl-fix-v2.sh [SERVER_ID|auto] [REPO_DIR]
# Example: sudo bash apply-fastdl-fix-v2.sh 25
#
# Root cause of the client error
#   "Map [maps/zm_2day.bsp] has incorrect BSP version (1868833084 should be 30)"
#   1868833084 = 0x6F64213C -> bytes 3C 21 64 6F = the text "<!do".
#   The client saved an HTML page ("<!doctype html>...") as zm_2day.bsp: the
#   FastDL URL answered with the panel's HTML page (HTTP 200) instead of the
#   map, and GoldSrc stored it as a BSP. Intermittent because it only happens
#   while a file is missing / being rebuilt / nginx or the panel is busy.
#
# What this patch does (nothing is deleted, every changed file is backed up):
#   1. nginx: /fastdl/ becomes a strict static, BROWSABLE location
#      (http://IP/fastdl/25/ shows every file). A missing file is a plain-text
#      404 and can never fall through to the panel HTML page.
#   2. hyper-cs16-ctl: adds the missing "fastdl-clean" command, so the panel's
#      "delete everything from FastDL" button works (error: invalid choice
#      'fastdl-clean').
#   3. FastDL: quarantines HTML/empty/corrupt files, runs the panel's
#      fastdl-sync, then creates a .bz2 next to every file (much faster join).
#   4. php-fpm: raises pm.max_children 5 -> 40 (log showed "reached
#      pm.max_children" = panel errors under load). Config is tested first.
#   5. systemd auto-restart drop-ins + a guard timer (every 2 min) that
#      re-checks routing, HTML files, .bz2 files and the ctl fix and self-heals.
#   6. Read-only diagnosis of crashes / kicks (printed into the report).
# It does NOT restart the game server, so players are not kicked.
# =============================================================================
set -Eu -o pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Run with sudo/root'; exit 1; }

SID_ARG="${1:-auto}"
REPO="${2:-/root/hyper-hosting-panel}"
GAME_PORT="${HYPER_GAME_PORT:-27018}"      # port from the client error log
DEFAULT_HOST="${HYPER_PUBLIC_IP:-90.189.208.25}"
FASTDL_BASE="/srv/hyper-cs16/fastdl"
SERVERS_BASE="/srv/hyper-cs16/servers"
CTL="/usr/local/sbin/hyper-cs16-ctl"
HELPER="/usr/local/sbin/hyper-cs16-fastdl-nginx"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-fastdl-fix-v2-backup-${STAMP}"
REPORT="/root/hyper-fastdl-fix-v2-${STAMP}.txt"

exec > >(tee -a "$REPORT") 2>&1
mkdir -p "$BACKUP"

echo '============================================================'
echo ' HYPER-HOST CS 1.6  FASTDL-FIX v2'
echo " Backup: $BACKUP"
echo " Report: $REPORT"
echo '============================================================'

# ---------------------------------------------------------------------------
# 0. Which server(s)?
# ---------------------------------------------------------------------------
detect_sid_by_port() {
python3 - "$GAME_PORT" <<'PY'
import json, glob, os, sys
port = str(sys.argv[1])
def walk(x):
    if isinstance(x, dict):
        for k, v in x.items():
            if 'port' in str(k).lower() and isinstance(v, (int, str)) and str(v) == port:
                return True
            if walk(v):
                return True
    elif isinstance(x, list):
        return any(walk(i) for i in x)
    return False
for f in sorted(glob.glob('/etc/hyper-cs16/servers/*.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if walk(d):
        print(os.path.basename(f)[:-5])
        break
PY
}

SIDS=()
add_sid() {
  local x="$1" y
  [[ "$x" =~ ^[0-9]+$ ]] || return 0
  for y in "${SIDS[@]:-}"; do [[ "$y" == "$x" ]] && return 0; done
  SIDS+=("$x")
}
DETECTED="$(detect_sid_by_port 2>/dev/null || true)"
add_sid "$SID_ARG"
add_sid "$DETECTED"
for x in ${HYPER_EXTRA_SIDS:-}; do add_sid "$x"; done
[[ ${#SIDS[@]} -gt 0 ]] || add_sid 25

echo "[0] Servers to fix: ${SIDS[*]}  (game port $GAME_PORT belongs to: ${DETECTED:-unknown})"
if [[ -n "$DETECTED" && "$SID_ARG" =~ ^[0-9]+$ && "$DETECTED" != "$SID_ARG" ]]; then
  echo "    [NOTE] you passed #$SID_ARG but port $GAME_PORT is server #$DETECTED - both will be fixed"
fi
for sid in "${SIDS[@]}"; do
  [[ -d "$SERVERS_BASE/$sid/cstrike" ]] || echo "    [WARN] $SERVERS_BASE/$sid/cstrike not found"
done
[[ -x "$CTL" || -f "$CTL" ]] || echo "    [WARN] $CTL not found - fastdl-sync will be skipped"

# FastDL host as clients see it (from sv_downloadurl)
HOST="${HYPER_PUBLIC_IP:-}"
if [[ -z "$HOST" ]]; then
  for sid in "${SIDS[@]}"; do
    url="$(cat "$SERVERS_BASE/$sid/cstrike/"*.cfg 2>/dev/null | grep -iE '^[[:space:]]*sv_downloadurl' | tail -n1 | grep -oE 'https?://[^/" ]+' | head -n1 || true)"
    if [[ -n "$url" ]]; then HOST="${url#*://}"; break; fi
  done
fi
HOST="${HOST:-$DEFAULT_HOST}"
HOST="${HOST%:80}"
echo "    FastDL host used for tests: $HOST"
SIDS_CSV="$(IFS=,; echo "${SIDS[*]}")"

# ---------------------------------------------------------------------------
# 1. Diagnosis of the "server goes down / panel errors" problem (read-only)
# ---------------------------------------------------------------------------
echo
echo '[1/8] Diagnosis (read-only)...'
echo '--- memory / swap / load ---'
free -h 2>/dev/null || true
uptime 2>/dev/null || true
echo '--- disk ---'
df -h / /srv /var 2>/dev/null | awk '!seen[$0]++' || true
USED="$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
if [[ -n "${USED:-}" && "$USED" -ge 90 ]]; then
  echo "    [WARN] root disk is ${USED}% full - a full disk kills nginx/php/mariadb/HLDS."
  echo "           old patch backups are usually the cause:"
  du -sch /root/old-zombie-*backup* /root/hyper-fastdl-*backup* 2>/dev/null | tail -n1 || true
fi
echo '--- kernel OOM kills (last) ---'
dmesg -T 2>/dev/null | grep -iE 'out of memory|killed process' | tail -n 5 || true
for sid in "${SIDS[@]}"; do
  echo "--- hyper-cs16@$sid problems, last 3 days ---"
  journalctl -u "hyper-cs16@$sid" --since '3 days ago' --no-pager 2>/dev/null \
    | grep -v ' killed "' | grep -iE 'segmentation|core dumped|Killed process|failed|Host_Error|SIGSEGV|timeout|oom' | tail -n 12 || true
  echo "--- why players get dropped/kicked, last 24h (count  reason) ---"
  journalctl -u "hyper-cs16@$sid" --since '24 hours ago' --no-pager 2>/dev/null \
    | grep -v ' killed "' \
    | grep -ioE 'dropped by server|timed out|reliable channel overflow|overflow[a-z ]*|Bad file[^"]{0,40}|Host_Error[^"]{0,50}|precache[^"]{0,40}|kicked[^"]{0,40}|Disconnect[^"]{0,40}' \
    | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -n 12 || true
done
echo '--- MariaDB exposed to the internet? ---'
if ss -ltn 2>/dev/null | grep -E '(0\.0\.0\.0|\[::\]|\*):3306' >/dev/null; then
  echo '    [WARN] MariaDB listens on ALL interfaces (port 3306) - scanners hit it every few minutes.'
  echo '           if you do not need remote SQL: bind-address = 127.0.0.1 in /etc/mysql/mariadb.conf.d/50-server.cnf, then systemctl restart mariadb'
else
  echo '    ok (local only)'
fi
echo '--- nginx error log (limits / upstream / workers) ---'
tail -n 400 /var/log/nginx/error.log 2>/dev/null \
  | grep -iE 'limiting|upstream|no live|too many|worker_connections|emerg|crit|Permission denied' | tail -n 8 || true
echo '--- php-fpm (pm.max_children reached = panel errors under load) ---'
{ journalctl -u 'php*-fpm*' --since '3 days ago' --no-pager 2>/dev/null; cat /var/log/php*-fpm.log 2>/dev/null; } \
  | grep -iE 'max_children|Cannot allocate|child .* exited on signal' | tail -n 5 || true
echo '--- mariadb ---'
journalctl -u mariadb -u mysql --since '3 days ago' --no-pager 2>/dev/null \
  | grep -iE 'too many connections|crashed|out of memory|Aborted' | tail -n 5 || true

# optional swap (only if you asked for it: HYPER_ADD_SWAP_GB=2)
if [[ -n "${HYPER_ADD_SWAP_GB:-}" ]]; then
  if swapon --show 2>/dev/null | grep -q .; then
    echo '    swap already present, not touching it'
  elif [[ ! -e /swapfile ]]; then
    echo "    creating /swapfile ${HYPER_ADD_SWAP_GB}G"
    fallocate -l "${HYPER_ADD_SWAP_GB}G" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null \
      && swapon /swapfile && { grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; } \
      && echo '    [OK] swap enabled' || echo '    [WARN] could not create swap'
  fi
fi

# ---------------------------------------------------------------------------
# 2. Install the helper (nginx patcher + verifier + guard)
# ---------------------------------------------------------------------------
echo
echo '[2/8] Installing helper...'
if ! command -v python3 >/dev/null 2>&1 || ! command -v bzip2 >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 bzip2 curl >/dev/null 2>&1 || true
fi
cat > "$HELPER" <<'HYPER_PY'
#!/usr/bin/env python3
# HYPER-HOST CS 1.6 - FastDL nginx patcher / guard  (fastdl-fix v1)
#
# Why this exists:
#   A client saved the bytes "<!do" (0x6F64213C little-endian = 1868833084) as
#   maps/zm_2day.bsp. That means the FastDL URL answered with an HTML page
#   (panel 404 / login / error page) instead of the map, and the GoldSrc client
#   stored it as a BSP. This tool makes /fastdl/ a pure static location that can
#   never fall through to the panel, and verifies it over HTTP.
#
# Sub-commands:
#   apply  [--host H] [--sids 25,2] [--backup DIR]   patch nginx + verify
#   probe  [--host H] [--sids 25,2]                   HTTP verification only
#   scan   [--sids 25,2] [--all]                      quarantine HTML/corrupt files
#   guard                                             periodic self-heal (systemd timer)
#   bzip   [--sids 25]                                create/refresh .bz2 next to every FastDL file
#   ctl-ensure                                        add the missing "fastdl-clean" ctl command
import argparse
import http.client
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

FASTDL_ROOT = '/srv/hyper-cs16/fastdl'
QUAR_ROOT = '/var/lib/hyper-cs16/fastdl-quarantine'
CTL = '/usr/local/sbin/hyper-cs16-ctl'
GUARD_CFG = '/etc/hyper-cs16/fastdl-guard.json'
GUARD_STATE = '/var/lib/hyper-cs16/fastdl-guard.state.json'
MARK = '# HYPER-FASTDL-STRICT v1'
STANDALONE_NAME = 'hyper-cs16-fastdl-standalone.conf'
ACCESS_LOG = '/var/log/nginx/hyper-cs16-fastdl-access.log'
ERROR_LOG = '/var/log/nginx/hyper-cs16-fastdl-error.log'


def log(msg):
    print(msg, flush=True)


def sh(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True, errors='replace')
        return p.returncode, p.stdout
    except Exception as e:  # noqa
        return 127, str(e)


# --------------------------------------------------------------------------
# nginx discovery
# --------------------------------------------------------------------------
def find_nginx():
    cands = []
    _, out = sh(['ps', '-eo', 'pid=,args='])
    for line in out.splitlines():
        m = re.match(r'\s*(\d+)\s+nginx: master process\s*(.*)$', line)
        if not m:
            continue
        pid = int(m.group(1))
        cmd = m.group(2)
        parts = cmd.split()
        binp = parts[0] if parts else 'nginx'
        if not os.path.exists(binp):
            binp = shutil.which('nginx') or binp
        args = []
        mm = re.search(r'(?:^|\s)-c\s+(\S+)', cmd)
        if mm:
            args = ['-c', mm.group(1)]
        cands.append({'pid': pid, 'bin': binp, 'args': args})
    if not cands:
        b = shutil.which('nginx')
        if b:
            cands.append({'pid': None, 'bin': b, 'args': []})
    best = None
    for c in cands:
        _, dump = sh([c['bin']] + c['args'] + ['-T'])
        c['dump'] = dump
        if 'hyper-cs16-fastdl' in dump or '/fastdl' in dump:
            best = c
            break
    return best or (cands[0] if cands else None)


def nginx_test(ngx):
    return sh([ngx['bin']] + ngx['args'] + ['-t'])


def nginx_reload(ngx):
    if ngx.get('pid'):
        try:
            os.kill(ngx['pid'], 1)  # SIGHUP
            time.sleep(1.5)
            return True
        except OSError:
            pass
    rc, _ = sh([ngx['bin']] + ngx['args'] + ['-s', 'reload'])
    time.sleep(1.5)
    return rc == 0


def dump_sections(dump):
    """[(path, text)] from `nginx -T` output."""
    secs = []
    cur = None
    buf = []
    for line in dump.splitlines():
        m = re.match(r'# configuration file (.+?):\s*$', line)
        if m:
            if cur is not None:
                secs.append((cur, '\n'.join(buf)))
            cur = m.group(1)
            buf = []
        else:
            buf.append(line)
    if cur is not None:
        secs.append((cur, '\n'.join(buf)))
    return secs


# --------------------------------------------------------------------------
# safe file write (handles chattr +i that some "read-only nginx" patches use)
# --------------------------------------------------------------------------
def _immutable(path):
    rc, out = sh(['lsattr', '-d', path])
    return rc == 0 and bool(out.split()) and 'i' in out.split()[0]


def write_file(path, text):
    exists = os.path.exists(path)
    locked = exists and _immutable(path)
    if locked:
        sh(['chattr', '-i', path])
    try:
        tmp = path + '.hyperfd.tmp'
        with open(tmp, 'w', encoding='utf-8', errors='surrogateescape') as f:
            f.write(text)
        if exists:
            st = os.stat(path)
            os.chmod(tmp, st.st_mode & 0o7777)
            try:
                os.chown(tmp, st.st_uid, st.st_gid)
            except OSError:
                pass
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if locked:
            sh(['chattr', '+i', path])


def read_file(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', errors='surrogateescape')


# --------------------------------------------------------------------------
# nginx config block patcher
# --------------------------------------------------------------------------
def mask(s):
    """Same-length copy of s where comments and quoted text cannot fake braces."""
    out = list(s)
    n = len(s)
    i = 0
    while i < n:
        c = s[i]
        if c == '#':
            j = s.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                if s[j] == '\\':
                    j += 1
                j += 1
            for k in range(i + 1, min(j, n)):
                if s[k] != '\n':
                    out[k] = 'x'
            i = j + 1
        else:
            i += 1
    m = ''.join(out)
    return re.sub(r'\$\{[^}\n]*\}', lambda mo: 'x' * len(mo.group(0)), m)


def find_blocks(m):
    stack = []
    res = []
    for i, c in enumerate(m):
        if c == '{':
            hs = max(m.rfind(';', 0, i), m.rfind('{', 0, i), m.rfind('}', 0, i)) + 1
            parent = stack[-1] if stack else None
            res.append({'hs': hs, 'open': i, 'close': None,
                        'hdr': m[hs:i].strip(), 'parent': parent})
            stack.append(len(res) - 1)
        elif c == '}':
            if stack:
                res[stack.pop()]['close'] = i
    return [b for b in res if b['close'] is not None]


def build_locations(indent, access_line):
    i = indent
    j = indent + '    '
    lines = [
        'location ^~ /fastdl/ {',
        j + MARK + ' - static only, browsable; a missing file is a plain 404, never the panel page',
        j + 'alias /srv/hyper-cs16/fastdl/;',
        j + 'autoindex on;',
        j + 'autoindex_exact_size off;',
        j + 'autoindex_localtime on;',
        j + 'rewrite ^/fastdl/([0-9]+)(maps|models|sound|sprites|gfx|resource|overviews|events)/(.*)$ /fastdl/$1/$2/$3 last;',
        j + 'default_type application/octet-stream;',
        j + 'types { }',
        j + 'gzip off;',
        j + 'sendfile on;',
        j + 'tcp_nopush on;',
        j + 'tcp_nodelay on;',
        j + 'keepalive_timeout 30s;',
        j + 'send_timeout 120s;',
        j + 'reset_timedout_connection on;',
        j + 'open_file_cache max=4096 inactive=30s;',
        j + 'open_file_cache_valid 10s;',
        j + 'open_file_cache_min_uses 1;',
        j + 'open_file_cache_errors off;',
        j + 'if ($request_method !~ ^(GET|HEAD)$) { return 405; }',
        j + 'add_header X-Hyper-FastDL "strict-v1" always;',
        j + 'add_header X-Content-Type-Options "nosniff" always;',
    ]
    if access_line:
        lines.append(j + access_line)
    lines += [
        j + 'error_page 403 404 = @hyper_fastdl_missing;',
        i + '}',
        i + 'location @hyper_fastdl_missing {',
        j + 'internal;',
        j + 'default_type text/plain;',
        j + 'add_header X-Hyper-FastDL "missing" always;',
        j + 'return 404 "not found\\n";',
        i + '}',
    ]
    return '\n'.join(lines)


def patch_text(text):
    """Returns (new_text, replaced_count) or (text, 0)."""
    m = mask(text)
    blocks = find_blocks(m)
    matched = set()
    for idx, b in enumerate(blocks):
        h = b['hdr']
        if re.match(r'location\b', h) and ('/fastdl' in h or '@hyper_fastdl_missing' in h):
            matched.add(idx)

    raw_parent = {}
    for k, b in enumerate(blocks):
        best = None
        for kk, bb in enumerate(blocks):
            if bb['open'] < b['open'] < bb['close']:
                if best is None or bb['open'] > blocks[best]['open']:
                    best = kk
        raw_parent[k] = best

    def anc(k):
        p = raw_parent[k]
        while p is not None:
            yield p
            p = raw_parent[p]

    top = [k for k in matched if not any(a in matched for a in anc(k))]
    groups = {}
    for k in top:
        srv = None
        for a in anc(k):
            if re.match(r'server\b', blocks[a]['hdr']):
                srv = a
                break
        if srv is None:
            continue
        groups.setdefault(srv, []).append(k)

    edits = []
    for srv, ks in groups.items():
        ks.sort(key=lambda k: blocks[k]['open'])
        main = [k for k in ks if '/fastdl' in blocks[k]['hdr']]
        if not main:
            continue
        first = main[0]
        for k in ks:
            b = blocks[k]
            loc_pos = m.find('location', b['hs'], b['open'])
            if loc_pos < 0:
                continue
            end = b['close'] + 1
            if k == first:
                ls = text.rfind('\n', 0, loc_pos) + 1
                indent = text[ls:loc_pos]
                if indent.strip():
                    indent = '    '
                old = text[b['open']:b['close']]
                am = re.search(r'^\s*(access_log\b[^;]*;)', old, re.M)
                access_line = am.group(1) if am else 'access_log %s;' % ACCESS_LOG
                edits.append((loc_pos, end, build_locations(indent, access_line)))
            else:
                ls = text.rfind('\n', 0, loc_pos) + 1
                if not text[ls:loc_pos].strip():
                    loc_pos = ls
                    if text[end:end + 1] == '\n':
                        end += 1
                edits.append((loc_pos, end, ''))
    if not edits:
        return text, 0
    edits.sort(key=lambda e: e[0], reverse=True)
    out = text
    for s, e, rep in edits:
        out = out[:s] + rep + out[e:]
    return out, len(groups)


def patch_locations(dump, backup_dir):
    changed = []
    for path, _ in dump_sections(dump):
        if os.path.basename(path) == STANDALONE_NAME or not os.path.isfile(path):
            continue
        try:
            text = read_file(path)
        except OSError:
            continue
        if '/fastdl' not in text and '@hyper_fastdl_missing' not in text:
            continue
        new, n = patch_text(text)
        if n and new != text:
            dst = os.path.join(backup_dir, path.lstrip('/'))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(path, dst)
            write_file(path, new)
            changed.append((path, n))
    return changed


def restore_backup(backup_dir, changed):
    for path, _ in changed:
        src = os.path.join(backup_dir, path.lstrip('/'))
        if os.path.exists(src):
            write_file(path, read_file(src))


# --------------------------------------------------------------------------
# standalone server block (only when the IP host has no fastdl location at all
# or the location patch could not fix routing)
# --------------------------------------------------------------------------
def listen_tokens(dump):
    toks = []
    for mo in re.finditer(r'^\s*listen\s+([^;]+);', dump, re.M):
        parts = mo.group(1).split()
        if not parts:
            continue
        t, opts = parts[0], parts[1:]
        if any(o in ('ssl', 'http2', 'quic') for o in opts):
            continue
        if re.fullmatch(r'(\d+\.\d+\.\d+\.\d+:)?80|\[::\]:80|\*:80', t) and t not in toks:
            toks.append(t)
    return toks or ['80']


def install_standalone(ngx, host, backup_dir):
    if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', host):
        log('  [SKIP] standalone: host "%s" is not an IPv4 literal; refusing to take over a domain' % host)
        return False
    dump = ngx['dump']
    for path, text in dump_sections(dump):
        if os.path.basename(path) == STANDALONE_NAME:
            continue
        if re.search(r'server_name[^;]*(?<![\w.])%s(?![\w.])' % re.escape(host), text):
            log('  [SKIP] standalone: server_name %s already exists in %s' % (host, path))
            return False
    os.makedirs('/var/log/nginx', exist_ok=True)
    listens = ''.join('    listen %s;\n' % t for t in listen_tokens(dump))
    locs = '    ' + build_locations('    ', None)
    body = (
        MARK + ' standalone server (auto-generated)\n'
        'server {\n' + listens +
        '    server_name ' + host + ';\n'
        '    server_tokens off;\n'
        '    access_log ' + ACCESS_LOG + ';\n'
        '    error_log ' + ERROR_LOG + ' warn;\n'
        + locs + '\n'
        '    location / {\n'
        '        default_type text/plain;\n'
        '        return 404 "not found\\n";\n'
        '    }\n'
        '}\n'
    )

    dirs = []
    for path, text in dump_sections(dump):
        if 'hyper-cs16-fastdl' in text and os.path.basename(path) != STANDALONE_NAME:
            dirs.append(os.path.dirname(path))
    for path, _ in dump_sections(dump):
        d = os.path.dirname(path)
        if os.path.basename(d) in ('conf.d', 'sites-enabled', 'vhosts', 'servers') and d not in dirs:
            dirs.append(d)
    for mo in re.finditer(r'^\s*include\s+([^;]+);', dump, re.M):
        pat = mo.group(1).strip().strip('"\'')
        if not os.path.isabs(pat) or not pat.endswith('*') and not pat.endswith('*.conf'):
            continue
        d = os.path.dirname(pat)
        if '*' not in d and os.path.isdir(d) and d not in dirs:
            dirs.append(d)
    if '/etc/nginx/conf.d' not in dirs:
        dirs.append('/etc/nginx/conf.d')
    for d in dirs:
        if not os.path.isdir(d):
            continue
        target = os.path.join(d, STANDALONE_NAME)
        prev = read_file(target) if os.path.exists(target) else None
        write_file(target, body)
        rc, out = nginx_test(ngx)
        _, dump2 = sh([ngx['bin']] + ngx['args'] + ['-T'])
        if rc == 0 and target in dump2:
            log('  [OK] standalone server block written: %s' % target)
            return True
        if prev is None:
            try:
                os.unlink(target)
            except OSError:
                pass
        else:
            write_file(target, prev)
    log('  [WARN] could not place a standalone block in an included directory')
    return False


# --------------------------------------------------------------------------
# HTTP verification
# --------------------------------------------------------------------------
def http_get(addr, port, host, path, rng='bytes=0-4095'):
    conn = http.client.HTTPConnection(addr, port, timeout=10)
    try:
        hdr = {'Host': host, 'Connection': 'close'}
        if rng:
            hdr['Range'] = rng
        conn.request('GET', path, headers=hdr)
        r = conn.getresponse()
        body = r.read(4096)
        return r.status, (r.getheader('Content-Type') or ''), (r.getheader('Content-Range') or ''), \
            (r.getheader('Content-Length') or ''), body
    finally:
        conn.close()


def http_bases(dump):
    bases = []
    for t in listen_tokens(dump) if dump else ['80']:
        mo = re.fullmatch(r'(?:(\d+\.\d+\.\d+\.\d+):)?(\d+)', t)
        if mo:
            if mo.group(1) and mo.group(1) not in ('0.0.0.0',):
                bases.append((mo.group(1), int(mo.group(2))))
            bases.append(('127.0.0.1', int(mo.group(2))))
    if not bases:
        bases = [('127.0.0.1', 80)]
    out = []
    for b in bases:
        if b not in out:
            out.append(b)
    return out


def looks_html(body):
    h = body.lstrip(b'\xef\xbb\xbf \t\r\n')[:40].lower()
    return h.startswith((b'<!doctype', b'<html', b'<head', b'<body', b'<?php', b'<meta'))


def probe(sids, host, dump=None, verbose=True):
    """Returns list of (kind, message). kind: route | data | net."""
    fails = []
    reach = None
    for addr, port in http_bases(dump):
        try:
            http_get(addr, port, host, '/fastdl/__probe__')
            reach = (addr, port)
            break
        except Exception:
            continue
    if not reach:
        return [('net', 'nginx does not answer on any local HTTP address')]
    addr, port = reach
    for sid in sids:
        root = Path(FASTDL_ROOT) / str(sid)
        if not root.is_dir():
            fails.append(('data', 'sid %s: %s is missing' % (sid, root)))
            continue
        # 1) a missing file must be a clean 404, never HTML/200
        miss = '/fastdl/%s/maps/zz_hyper_missing_%d.bsp.bz2' % (sid, random.randint(1000, 999999))
        try:
            st, ct, _, _, body = http_get(addr, port, host, miss)
            ok = (st == 404 and not looks_html(body))
            if verbose:
                log('  [%s] sid %s missing-file probe -> HTTP %s %s' % ('PASS' if ok else 'FAIL', sid, st, ct))
            if not ok:
                fails.append(('route', 'sid %s: missing file answered HTTP %s (%s) instead of a plain 404' % (sid, st, ct)))
        except Exception as e:
            fails.append(('net', 'sid %s: %s' % (sid, e)))
            continue
        # 1b) http://HOST/fastdl/<sid>/ must be a browsable listing
        try:
            st, ct, _, _, body = http_get(addr, port, host, '/fastdl/%s/' % sid, rng=None)
            ok = (st == 200 and b'Index of' in body)
            if verbose:
                log('  [%s] sid %s directory listing /fastdl/%s/ -> HTTP %s' % ('PASS' if ok else 'FAIL', sid, sid, st))
            if not ok:
                fails.append(('listing', 'sid %s: /fastdl/%s/ is not a directory listing (HTTP %s)' % (sid, sid, st)))
        except Exception as e:
            fails.append(('listing', 'sid %s: listing request failed: %s' % (sid, e)))
        # 2) real files must come back byte-exact, not as HTML
        samples = []
        for name in ('zm_2day.bsp.bz2', 'zm_2day.bsp'):
            p = root / 'maps' / name
            if p.is_file():
                samples.append(p)
        if not samples:
            bz = [p for p in root.rglob('*.bz2') if p.is_file() and 1024 < p.stat().st_size < 60 * 1048576]
            bz.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            samples = bz[:1]
        for p in samples:
            rel = p.relative_to(root).as_posix()
            try:
                st, ct, cr, cl, body = http_get(addr, port, host, '/fastdl/%s/%s' % (sid, rel))
            except Exception as e:
                fails.append(('net', '%s: %s' % (rel, e)))
                continue
            size = p.stat().st_size
            good_magic = (body[:3] == b'BZh') if p.suffix == '.bz2' else (body[:4] == b'\x1e\x00\x00\x00')
            total = None
            if cr and '/' in cr:
                try:
                    total = int(cr.rsplit('/', 1)[1])
                except ValueError:
                    pass
            if total is None and cl.isdigit():
                total = int(cl)
            ok = st in (200, 206) and not looks_html(body) and good_magic and (total in (None, size))
            if verbose:
                log('  [%s] sid %s %s -> HTTP %s %s bytes=%s' % ('PASS' if ok else 'FAIL', sid, rel, st, ct, total))
            if not ok:
                kind = 'route' if looks_html(body) else 'data'
                fails.append((kind, 'sid %s: %s answered HTTP %s, html=%s, magic_ok=%s, size=%s/%s' %
                              (sid, rel, st, looks_html(body), good_magic, total, size)))
    return fails


# --------------------------------------------------------------------------
# scan / quarantine
# --------------------------------------------------------------------------
BIN_EXT = {'.bsp', '.mdl', '.spr', '.wav', '.wad', '.tga', '.bmp', '.nav', '.mp3', '.pcx', '.bz2'}


def file_problem(fp, test_bz2):
    try:
        size = fp.stat().st_size
        with open(fp, 'rb') as f:
            head = f.read(64)
    except OSError:
        return None
    ext = fp.suffix.lower()
    if size == 0:
        return 'empty'
    if looks_html(head):
        return 'html'
    if ext == '.bz2':
        if not head.startswith(b'BZh'):
            return 'not-bzip2'
        if test_bz2 and size < 300 * 1048576:
            rc, _ = sh(['bzip2', '-tq', str(fp)], timeout=180)
            if rc != 0:
                return 'bzip2-corrupt'
    return None


def scan(sids, quarantine=True, since=0.0, test_bz2=True):
    bad = []
    now = time.time()
    for sid in sids:
        root = Path(FASTDL_ROOT) / str(sid)
        if not root.is_dir():
            continue
        for fp in root.rglob('*'):
            try:
                if not fp.is_file() or fp.is_symlink() or fp.name.startswith('.'):
                    continue
                if fp.suffix.lower() not in BIN_EXT:
                    continue
                mt = fp.stat().st_mtime
                if now - mt < 5:
                    continue  # still being written
                reason = file_problem(fp, test_bz2 and mt >= since)
                if not reason:
                    continue
                rel = fp.relative_to(root).as_posix()
                bad.append((sid, rel, reason))
                if quarantine:
                    dst = Path(QUAR_ROOT) / str(sid) / (rel + '.' + str(int(now)))
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(fp), str(dst))
            except OSError:
                continue
    return bad


def game_map_check(sids):
    """Report server-side maps that are not valid GoldSrc BSPs (version 30)."""
    for sid in sids:
        maps = Path('/srv/hyper-cs16/servers/%s/cstrike/maps' % sid)
        if not maps.is_dir():
            continue
        for bsp in sorted(maps.glob('*.bsp')):
            try:
                with open(bsp, 'rb') as f:
                    head = f.read(64)
            except OSError:
                continue
            if looks_html(head):
                log('  [BAD MAP] sid %s maps/%s is an HTML page, not a BSP - re-upload the map' % (sid, bsp.name))
            elif head[:4] != b'\x1e\x00\x00\x00':
                ver = int.from_bytes(head[:4], 'little') if len(head) >= 4 else -1
                log('  [WARN] sid %s maps/%s has BSP version %s (GoldSrc needs 30)' % (sid, bsp.name, ver))



# --------------------------------------------------------------------------
# .bz2 generation (FastDL clients download much less and much faster)
# --------------------------------------------------------------------------
BZ_ALLOWED = {'.bsp', '.nav', '.res', '.wad', '.mdl', '.spr', '.wav', '.mp3', '.tga', '.bmp', '.pcx', '.txt', '.vmt', '.vtf'}


def _bzip_one(fp):
    try:
        st = fp.stat()
    except OSError:
        return (0, 0)
    bz = Path(str(fp) + '.bz2')
    try:
        bs = bz.stat()
        if bs.st_size > 0 and bs.st_mtime_ns >= st.st_mtime_ns:
            return (0, 0)
    except OSError:
        pass
    tmp = bz.with_name('.' + bz.name + '.%08x.tmp' % random.getrandbits(32))
    try:
        with open(tmp, 'wb') as out:
            r = subprocess.run(['bzip2', '-9', '-c', str(fp)], stdout=out, stderr=subprocess.PIPE, timeout=900)
        if r.returncode == 0 and tmp.stat().st_size > 0:
            os.chmod(tmp, 0o644)
            os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
            os.replace(tmp, bz)
            return (1, max(0, st.st_size - bz.stat().st_size))
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        tmp.unlink()
    except OSError:
        pass
    return (0, 0)


def bzip_tree(sids):
    from concurrent.futures import ThreadPoolExecutor
    if not shutil.which('bzip2'):
        log('  [WARN] bzip2 is not installed (apt-get install bzip2)')
        return 0, 0
    now = time.time()
    files = []
    for sid in sids:
        root = Path(FASTDL_ROOT) / str(sid)
        if not root.is_dir():
            continue
        for fp in root.rglob('*'):
            try:
                if (fp.is_file() and not fp.is_symlink() and not fp.name.startswith('.')
                        and fp.suffix.lower() in BZ_ALLOWED and now - fp.stat().st_mtime > 5):
                    files.append(fp)
            except OSError:
                continue
    made = saved = 0
    workers = max(1, min(8, (os.cpu_count() or 2)))
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for m, sv in ex.map(_bzip_one, files):
            made += m
            saved += sv
    return made, saved


# --------------------------------------------------------------------------
# hyper-cs16-ctl: the panel calls "fastdl-clean" but the installed ctl does not
# know that sub-command (argparse rejects it). Add it through a thin wrapper.
# --------------------------------------------------------------------------
CTL_REAL = CTL + '.real'
WRAPPER_MARK = 'HYPER-CTL-WRAPPER v1'
WRAPPER = r"""#!/usr/bin/env python3
# HYPER-CTL-WRAPPER v1: adds the missing "fastdl-clean" sub-command,
# everything else is forwarded unchanged to hyper-cs16-ctl.real
import json
import os
import shutil
import sys

BASE = '/srv/hyper-cs16/fastdl'
REAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hyper-cs16-ctl.real')


def out(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def fastdl_clean(arg):
    if not str(arg).isdigit():
        out({'ok': False, 'error': 'invalid server id'}, 1)
    sid = str(int(arg))
    root = os.path.join(BASE, sid)
    if os.path.islink(root) or os.path.dirname(os.path.realpath(root)) != os.path.realpath(BASE):
        out({'ok': False, 'error': 'refusing unsafe path'}, 1)
    removed = 0
    freed = 0
    if os.path.isdir(root):
        for name in os.listdir(root):
            p = os.path.join(root, name)
            try:
                if os.path.islink(p) or os.path.isfile(p):
                    freed += os.lstat(p).st_size
                    os.unlink(p)
                    removed += 1
                else:
                    for r, _ds, fs in os.walk(p):
                        for f in fs:
                            try:
                                freed += os.lstat(os.path.join(r, f)).st_size
                                removed += 1
                            except OSError:
                                pass
                    shutil.rmtree(p)
            except OSError as e:
                out({'ok': False, 'error': str(e), 'removed_files': removed}, 1)
    else:
        os.makedirs(root, mode=0o755, exist_ok=True)
    os.chmod(root, 0o755)
    out({'ok': True, 'id': int(sid), 'root': root, 'removed_files': removed, 'freed_bytes': freed})


if len(sys.argv) >= 2 and sys.argv[1] == 'fastdl-clean':
    if len(sys.argv) < 3:
        out({'ok': False, 'error': 'server id required'}, 1)
    fastdl_clean(sys.argv[2])
if not os.path.exists(REAL):
    out({'ok': False, 'error': 'hyper-cs16-ctl.real is missing'}, 2)
os.execv(REAL, [REAL] + sys.argv[1:])
"""


def ctl_ensure():
    if not os.path.exists(CTL):
        log('  [SKIP] %s not found' % CTL)
        return 1
    with open(CTL, 'rb') as f:
        head = f.read(400)
    if WRAPPER_MARK.encode() in head:
        if not os.path.exists(CTL_REAL):
            log('  [ERROR] wrapper installed but %s is missing' % CTL_REAL)
            return 2
        return 0
    _, helptxt = sh([CTL, '-h'])
    if 'fastdl-clean' in helptxt:
        log('  [OK] installed ctl already knows fastdl-clean')
        return 0
    shutil.copy2(CTL, CTL_REAL)
    os.chmod(CTL_REAL, 0o755)
    write_file(CTL, WRAPPER)
    os.chmod(CTL, 0o755)
    rc, out = sh([CTL, 'fastdl-clean', 'x'])
    if '"ok": false' in out and 'invalid server id' in out:
        log('  [OK] fastdl-clean added (original kept as %s)' % CTL_REAL)
        return 0
    log('  [ERROR] wrapper self-test failed, restoring original:\n' + out)
    write_file(CTL, read_file(CTL_REAL))
    os.chmod(CTL, 0o755)
    return 3


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
def parse_sids(s):
    return [x for x in re.split(r'[,\s]+', s or '') if x.isdigit()]


def cmd_apply(a):
    sids = parse_sids(a.sids)
    host = a.host
    backup = a.backup or ('/root/hyper-fastdl-nginx-backup-%d' % int(time.time()))
    os.makedirs(backup, exist_ok=True)
    ngx = find_nginx()
    if not ngx:
        log('[ERROR] nginx was not found on this machine')
        return 2
    log('  nginx: %s %s (master pid %s)' % (ngx['bin'], ' '.join(ngx['args']), ngx.get('pid')))
    dump = ngx['dump']
    for pat in ('limit_req ', 'limit_conn '):
        n = len(re.findall(r'^\s*' + pat, dump, re.M))
        if n:
            log('  [NOTE] config contains %d "%s" directive(s); make sure none of them applies to /fastdl/' % (n, pat.strip()))
    changed = patch_locations(dump, backup)
    for p, n in changed:
        log('  [PATCHED] %s (%d server block(s))' % (p, n))
    rc, out = nginx_test(ngx)
    if rc != 0:
        log('[ERROR] nginx -t failed after patch, rolling back:\n' + out)
        restore_backup(backup, changed)
        nginx_test(ngx)
        return 3
    if changed:
        nginx_reload(ngx)
    _, dump_now = sh([ngx['bin']] + ngx['args'] + ['-T'])
    ngx['dump'] = dump_now
    fails = probe(sids, host, dump_now) if sids else []
    route_bad = any(k == 'route' for k, _ in fails)
    used_standalone = False
    if (not changed) or route_bad:
        log('  no working /fastdl/ location for host %s -> trying dedicated server block' % host)
        if install_standalone(ngx, host, backup):
            nginx_reload(ngx)
            used_standalone = True
            _, ngx['dump'] = sh([ngx['bin']] + ngx['args'] + ['-T'])
            fails = probe(sids, host, ngx['dump']) if sids else []
    for k, msg in fails:
        log('  [FAIL/%s] %s' % (k, msg))
    log('  mode: %s' % ('standalone server block' if used_standalone else ('patched existing location' if changed else 'unchanged')))
    return 0 if not any(k in ('route', 'net') for k, _ in fails) else 4


def cmd_bzip(a):
    made, saved = bzip_tree(parse_sids(a.sids))
    log('  [OK] .bz2 created/updated: %d file(s), %.1f MiB less to download' % (made, saved / 1048576.0))
    return 0


def cmd_ctl(a):
    return ctl_ensure()


def cmd_probe(a):
    sids = parse_sids(a.sids)
    ngx = find_nginx()
    fails = probe(sids, a.host, ngx['dump'] if ngx else None)
    return 0 if not fails else 4


def cmd_scan(a):
    sids = parse_sids(a.sids)
    bad = scan(sids, quarantine=True, since=0.0, test_bz2=True)
    if not bad:
        log('  [OK] no HTML / empty / corrupt files inside FastDL')
    for sid, rel, why in bad:
        log('  [QUARANTINED] sid %s %s (%s)' % (sid, rel, why))
    game_map_check(sids)
    return 0


def _load_state():
    try:
        return json.load(open(GUARD_STATE))
    except Exception:
        return {}


def _save_state(st):
    os.makedirs(os.path.dirname(GUARD_STATE), exist_ok=True)
    json.dump(st, open(GUARD_STATE, 'w'))


def cmd_guard(a):
    try:
        cfg = json.load(open(GUARD_CFG))
    except Exception as e:
        log('guard: cannot read %s: %s' % (GUARD_CFG, e))
        return 0
    sids = [str(x) for x in cfg.get('sids', [])]
    host = cfg.get('host', '127.0.0.1')
    st = _load_state()
    now = time.time()
    last = float(st.get('last_run', 0))
    st['last_run'] = now

    try:
        ctl_ensure()
    except Exception as e:  # noqa
        log('guard: ctl_ensure failed: %s' % e)
    bad = scan(sids, quarantine=True, since=last, test_bz2=True)
    need_sync = bool(bad)
    for sid, rel, why in bad:
        log('guard: quarantined sid %s %s (%s)' % (sid, rel, why))

    ngx = find_nginx()
    if not ngx:
        sh(['systemctl', 'start', 'nginx'])
        log('guard: nginx was not running, start requested')
        _save_state(st)
        return 0
    fails = probe(sids, host, ngx['dump'], verbose=False)
    route = [m for k, m in fails if k == 'route']
    data = [m for k, m in fails if k == 'data']
    net = [m for k, m in fails if k == 'net']
    if route and now - float(st.get('last_repair', 0)) > 600:
        log('guard: routing problem (%s) -> re-applying nginx patch' % route[0])
        st['last_repair'] = now
        ns = argparse.Namespace(sids=','.join(sids), host=host, backup=None)
        cmd_apply(ns)
    if net:
        st['net_fail'] = int(st.get('net_fail', 0)) + 1
        if st['net_fail'] >= 3:
            log('guard: nginx unresponsive %d times -> restarting nginx' % st['net_fail'])
            sh(['systemctl', 'restart', 'nginx'])
            st['net_fail'] = 0
    else:
        st['net_fail'] = 0
    if data:
        need_sync = True
    if need_sync and os.path.exists(CTL) and now - float(st.get('last_sync', 0)) > 600:
        st['last_sync'] = now
        for sid in sids:
            log('guard: running fastdl-sync for sid %s' % sid)
            sh([CTL, 'fastdl-sync', sid], timeout=900)
    try:
        made, _ = bzip_tree(sids)
        if made:
            log('guard: created/updated %d .bz2 file(s)' % made)
    except Exception as e:  # noqa
        log('guard: bzip failed: %s' % e)
    _save_state(st)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd', required=True)
    for name in ('apply', 'probe', 'scan', 'guard', 'bzip', 'ctl-ensure'):
        p = sp.add_parser(name)
        p.add_argument('--host', default='127.0.0.1')
        p.add_argument('--sids', default='')
        p.add_argument('--backup', default=None)
    a = ap.parse_args()
    return {'apply': cmd_apply, 'probe': cmd_probe, 'scan': cmd_scan, 'guard': cmd_guard,
            'bzip': cmd_bzip, 'ctl-ensure': cmd_ctl}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
HYPER_PY
chmod 0755 "$HELPER"
python3 -m py_compile "$HELPER" && echo "    [OK] $HELPER" || { echo '[ERROR] helper is broken'; exit 2; }
rm -rf /usr/local/sbin/__pycache__ 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. hyper-cs16-ctl: add the missing "fastdl-clean" command
# ---------------------------------------------------------------------------
echo
echo '[3/9] Fixing panel error: hyper-cs16-ctl has no "fastdl-clean"...'
if [[ -f "$CTL" ]]; then
  mkdir -p "$BACKUP/ctl" && cp -a "$CTL" "$BACKUP/ctl/hyper-cs16-ctl.orig"
  "$HELPER" ctl-ensure
  CTL_RC=$?
  echo "    self-test (must print ok:false / invalid server id, NOT an argparse error):"
  "$CTL" fastdl-clean x 2>&1 | tail -n 2 | sed 's/^/      /'
else
  echo "    [SKIP] $CTL not found"
  CTL_RC=1
fi

# ---------------------------------------------------------------------------
# 4. Quarantine HTML / empty / corrupt files inside FastDL
# ---------------------------------------------------------------------------
echo
echo '[4/9] Scanning FastDL for HTML/empty/corrupt files (moved, not deleted)...'
"$HELPER" scan --sids "$SIDS_CSV" || true

# ---------------------------------------------------------------------------
# 5. nginx: strict, browsable /fastdl/  (this is the actual client fix)
# ---------------------------------------------------------------------------
echo
echo '[5/9] Patching nginx /fastdl/ (static, browsable, never HTML for a missing file)...'
"$HELPER" apply --host "$HOST" --sids "$SIDS_CSV" --backup "$BACKUP/nginx"
NGX_RC=$?
if [[ $NGX_RC -eq 0 ]]; then echo '    [OK] nginx FastDL routing verified'; else echo "    [WARN] helper exit code $NGX_RC (see lines above)"; fi

# ---------------------------------------------------------------------------
# 6. Rebuild FastDL + .bz2
# ---------------------------------------------------------------------------
echo
echo '[6/9] Rebuilding FastDL (fastdl-sync) and creating .bz2 files...'
if [[ -f "$CTL" ]]; then
  for sid in "${SIDS[@]}"; do
    [[ -d "$SERVERS_BASE/$sid/cstrike" ]] || continue
    echo "  -- server #$sid"
    "$CTL" fastdl-sync "$sid" 2>&1 | tail -n 3 | cut -c1-400 || true
  done
fi
"$HELPER" bzip --sids "$SIDS_CSV" || true
"$HELPER" scan --sids "$SIDS_CSV" || true
echo
echo '    map files that clients receive:'
for sid in "${SIDS[@]}"; do
  for f in "$FASTDL_BASE/$sid/maps/zm_2day.bsp" "$FASTDL_BASE/$sid/maps/zm_2day.bsp.bz2" "$SERVERS_BASE/$sid/cstrike/maps/zm_2day.bsp"; do
    if [[ -f "$f" ]]; then
      printf '      %-66s %10s bytes  head=%s\n' "$f" "$(stat -c %s "$f")" "$(head -c 4 "$f" | od -An -tx1 | tr -d ' ')"
    else
      echo "      MISSING $f"
    fi
  done
done
echo '      (valid BSP = 1e000000, valid .bz2 = 425a68..)'
for sid in "${SIDS[@]}"; do
  echo "    server #$sid: $(find "$FASTDL_BASE/$sid" -type f ! -name '*.bz2' ! -name '.*' 2>/dev/null | wc -l) files, $(find "$FASTDL_BASE/$sid" -type f -name '*.bz2' 2>/dev/null | wc -l) .bz2"
done

# ---------------------------------------------------------------------------
# 7. Game-server cvars
# ---------------------------------------------------------------------------
echo
echo '[7/9] Checking server cvars...'
for sid in "${SIDS[@]}"; do
  [[ -d "$SERVERS_BASE/$sid/cstrike" ]] || continue
  echo "  -- server #$sid"
  out="$("$CTL" rcon "$sid" 'sv_downloadurl' 2>&1 || true)"; echo "    $out" | cut -c1-200 | head -n 2
  if ! echo "$out" | grep -qE 'is \\"https?://'; then echo '    [WARN] sv_downloadurl looks empty'; fi
  echo "$out" | grep -qE '/\\"' || echo '    [NOTE] no trailing slash in sv_downloadurl - nginx now accepts both /fastdl/25/maps/.. and /fastdl/25maps/..'
  out2="$("$CTL" rcon "$sid" 'sv_allowdownload' 2>&1 || true)"; echo "    $out2" | cut -c1-200 | head -n 2
  echo "$out2" | grep -qE 'is \\"0\\"' && echo '    [WARN] sv_allowdownload is 0 - UDP fallback for clients is disabled'
done

# ---------------------------------------------------------------------------
# 8. php-fpm: pm.max_children 5 -> 40 (log: "server reached pm.max_children setting (5)")
# ---------------------------------------------------------------------------
echo
echo '[8/9] php-fpm capacity (panel errors under load)...'
for u in $(systemctl list-units 'php*-fpm.service' --state=active --no-legend 2>/dev/null | awk '{print $1}'); do
  v="${u#php}"; v="${v%-fpm.service}"
  f="/etc/php/$v/fpm/pool.d/www.conf"
  [[ -f "$f" ]] || { echo "    [SKIP] $u: $f not found"; continue; }
  if ! grep -qE '^pm[[:space:]]*=[[:space:]]*dynamic' "$f"; then echo "    [SKIP] $u: pool is not 'dynamic'"; continue; fi
  cur="$(grep -E '^pm\.max_children' "$f" | head -n1 | tr -dc '0-9')"
  if [[ -n "$cur" && "$cur" -ge 30 ]]; then echo "    [OK] $u already max_children=$cur"; continue; fi
  mkdir -p "$BACKUP/php" && cp -a "$f" "$BACKUP/php/php$v-www.conf"
  sed -i -E 's/^;?pm\.max_children[[:space:]]*=.*/pm.max_children = 40/;
             s/^;?pm\.start_servers[[:space:]]*=.*/pm.start_servers = 8/;
             s/^;?pm\.min_spare_servers[[:space:]]*=.*/pm.min_spare_servers = 4/;
             s/^;?pm\.max_spare_servers[[:space:]]*=.*/pm.max_spare_servers = 16/' "$f"
  if "php-fpm$v" -t >/dev/null 2>&1; then
    systemctl reload "$u" 2>/dev/null && echo "    [OK] $u: max_children ${cur:-?} -> 40"
  else
    cp -a "$BACKUP/php/php$v-www.conf" "$f"
    echo "    [WARN] $u: config test failed, original restored"
  fi
done

# ---------------------------------------------------------------------------
# 9. Stability: auto-restart drop-ins + guard timer
# ---------------------------------------------------------------------------
echo
echo '[9/9] Stability (systemd auto-restart + FastDL guard)...'
write_dropin() {  # unit_for_query dropin_dir
  local q="$1" dir="$2" cur body
  systemctl cat "$q" >/dev/null 2>&1 || return 0
  cur="$(systemctl show -p Restart --value "$q" 2>/dev/null || true)"
  body='[Unit]
StartLimitIntervalSec=0
[Service]'
  if [[ -z "$cur" || "$cur" == "no" || "$cur" == "on-success" || "$cur" == "on-abort" ]]; then
    body="$body
Restart=on-failure
RestartSec=3"
  else
    body="$body
RestartSec=3"
  fi
  mkdir -p "/etc/systemd/system/$dir"
  printf '%s\n' "$body" > "/etc/systemd/system/$dir/zz-hyper-stability.conf"
  echo "    [OK] $dir (Restart was: ${cur:-unset})"
}
write_dropin "hyper-cs16@${SIDS[0]}.service" 'hyper-cs16@.service.d'
for u in nginx.service mariadb.service mysql.service hyper-cs16-monitor.service; do
  write_dropin "$u" "$u.d"
done
for u in $(systemctl list-unit-files --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}'); do
  write_dropin "$u" "$u.d"
done
systemctl daemon-reload 2>/dev/null || true
systemctl is-active --quiet hyper-cs16-monitor.service 2>/dev/null || systemctl start hyper-cs16-monitor.service 2>/dev/null || true

mkdir -p /etc/hyper-cs16 /var/lib/hyper-cs16
python3 - "$HOST" "${SIDS[@]}" > /etc/hyper-cs16/fastdl-guard.json <<'PY'
import json, sys
print(json.dumps({'host': sys.argv[1], 'sids': [int(x) for x in sys.argv[2:]]}))
PY
cat > /etc/systemd/system/hyper-cs16-fastdl-guard.service <<'UNIT'
[Unit]
Description=HYPER CS16 FastDL guard (routing, HTML/corrupt files, .bz2, ctl fix)

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/hyper-cs16-fastdl-nginx guard
UNIT
cat > /etc/systemd/system/hyper-cs16-fastdl-guard.timer <<'UNIT'
[Unit]
Description=HYPER CS16 FastDL guard timer

[Timer]
OnBootSec=90
OnUnitActiveSec=120
AccuracySec=15

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now hyper-cs16-fastdl-guard.timer 2>/dev/null && echo '    [OK] guard timer enabled (every 2 min)' \
  || echo '    [WARN] could not enable guard timer'

# ---------------------------------------------------------------------------
# Final verification exactly as a client / browser would do it
# ---------------------------------------------------------------------------
echo
echo '[CHECK] Final HTTP verification...'
"$HELPER" probe --host "$HOST" --sids "$SIDS_CSV"
FINAL_RC=$?
for sid in "${SIDS[@]}"; do
  echo "--- http://$HOST/fastdl/$sid  (no trailing slash, like the panel link) ---"
  curl -sS -m 10 -o /dev/null -D - -H "Host: $HOST" "http://127.0.0.1/fastdl/$sid" 2>/dev/null \
    | grep -iE '^HTTP/|^location' || true
done

echo
echo '============================================================'
if [[ $FINAL_RC -eq 0 && $NGX_RC -eq 0 && ${CTL_RC:-1} -eq 0 ]]; then
  echo '[DONE] FASTDL-FIX v2 applied and verified.'
else
  echo '[DONE WITH WARNINGS] read the [FAIL]/[WARN]/[ERROR] lines above and send me this report.'
fi
echo "Open in browser : http://$HOST/fastdl/${SIDS[0]}/"
echo "Backup          : $BACKUP"
echo "Report          : $REPORT"
echo
echo 'Test as a real player:'
echo '  1) on your PC delete cstrike/maps/zm_2day.bsp, reconnect'
echo '  2) on the server:  sudo tail -F /var/log/nginx/hyper-cs16-fastdl-access.log'
echo '     you must see  "GET /fastdl/<id>/maps/zm_2day.bsp.bz2 ..." 200'
echo
echo 'Rollback:'
echo '  nginx : sudo find /etc/nginx -name hyper-cs16-fastdl-standalone.conf -delete && sudo nginx -t && sudo systemctl reload nginx'
echo "  ctl   : sudo cp -a $BACKUP/ctl/hyper-cs16-ctl.orig $CTL && sudo rm -f $CTL.real"
echo '  guard : sudo systemctl disable --now hyper-cs16-fastdl-guard.timer'
echo '============================================================'
exit 0
