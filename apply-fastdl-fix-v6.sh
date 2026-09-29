#!/usr/bin/env bash
# =============================================================================
# HYPER-HOST / OLD ZOMBIE - FASTDL-FIX v6
#
# Usage:   sudo bash apply-fastdl-fix-v6.sh [SERVER_ID|auto] [REPO_DIR]
# Example: sudo bash apply-fastdl-fix-v6.sh 25
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
#   0. NOTE: a real client log showed that the Steam HTTP client requests correct URLs
#      (/fastdl/25/sprites/...), so the missing trailing slash in sv_downloadurl is NOT
#      the cause of the HTML files. Changing it is therefore OFF by default
#      (HYPER_FIX_URL=1 enables it); .bz2 files are OFF by default too (HYPER_BZ2=1):
#      that client asks for the plain file names.
#   1. nginx: /fastdl/ = strict static + browsable (http://IP/fastdl/25/), a missing
#      file is a plain 404, never the panel's HTML page.
#   2. Maps are not served over FastDL (clients get them from the game server).
#      Put them back with:  HYPER_FASTDL_MAPS=allow
#   3. hyper-cs16-ctl: adds the missing "fastdl-clean" command (panel button).
#   4. FastDL: quarantines HTML/empty/corrupt files, fastdl-sync, .bz2 for the rest.
#   5. Game folder: HTML-instead-of-file scan, missing / wrong-case resources
#      (fixes "server failed to transmit file ..."), crash loop on maps that overflow
#      the 512 precache limit.
#   6. OLD players with already-poisoned files: http://IP/fastdl/fix-cs-files.bat
#   7. Join diagnostics: what the clients asked FastDL for, per IP, together with the
#      game server's connect/drop lines for that IP.
#   8. php-fpm max_children 5 -> 40, systemd auto-restart, guard timer.
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
CRASHFIX="/usr/local/sbin/hyper-cs16-crashfix"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-fastdl-fix-v6-backup-${STAMP}"
REPORT="/root/hyper-fastdl-fix-v6-${STAMP}.txt"

exec > >(tee -a "$REPORT") 2>&1
mkdir -p "$BACKUP"

echo '============================================================'
echo ' HYPER-HOST CS 1.6  FASTDL-FIX v6'
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
echo '[1] Diagnosis (read-only)...'
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
echo '[2] Installing tools...'
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
#   nomaps [--sids 25]                                remove maps from FastDL (keeps game maps)
#   client-fix                                        write fix-cs-maps.bat for players
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
CRASHFIX = '/usr/local/sbin/hyper-cs16-crashfix'
BLOCK_MAPS = True   # maps are NOT served over FastDL (clients get them from the game server)
CLIENT_BAT = 'fix-cs-files.bat'


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
        j + 'rewrite ^/fastdl/([0-9]+)(?![0-9/])(.+)$ /fastdl/$1/$2 last;   # sv_downloadurl without trailing slash',
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
    ] + ([j + 'if ($uri ~* "^/fastdl/[0-9]+/maps/") { return 404; }   # maps come from the game server (UDP)'] if BLOCK_MAPS else []) + [
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
        if BLOCK_MAPS:
            try:
                st, ct, _, _, body = http_get(addr, port, host, '/fastdl/%s/maps/zm_2day.bsp' % sid)
                ok = (st == 404 and not looks_html(body))
                if verbose:
                    log('  [%s] sid %s maps are not served by FastDL -> HTTP %s %s' % ('PASS' if ok else 'FAIL', sid, st, ct))
                if not ok:
                    fails.append(('maps', 'sid %s: /maps/ is still served over FastDL (HTTP %s)' % (sid, st)))
            except Exception as e:
                fails.append(('net', 'sid %s: %s' % (sid, e)))
        else:
            for name in ('zm_2day.bsp.bz2', 'zm_2day.bsp'):
                p = root / 'maps' / name
                if p.is_file():
                    samples.append(p)
        if not samples:
            cand = [p for p in root.rglob('*') if p.is_file() and not p.name.startswith('.')
                    and 1024 < p.stat().st_size < 60 * 1048576
                    and not (BLOCK_MAPS and p.relative_to(root).parts[0] == 'maps')]
            bz = [p for p in cand if p.suffix == '.bz2'] or cand
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
            if p.suffix == '.bz2':
                good_magic = body[:3] == b'BZh'
            elif p.suffix == '.bsp':
                good_magic = body[:4] == b'\x1e\x00\x00\x00'
            else:
                good_magic = not looks_html(body)
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
                if BLOCK_MAPS and fp.relative_to(root).parts[0] == 'maps':
                    continue
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
# maps are removed from FastDL (only the FastDL copies; the game's own maps
# folder is never touched)
# --------------------------------------------------------------------------
def purge_maps(sids):
    n = 0
    freed = 0
    for sid in sids:
        d = Path(FASTDL_ROOT) / str(sid) / 'maps'
        if not d.is_dir() or d.is_symlink():
            continue
        for fp in list(d.rglob('*')):
            try:
                if fp.is_file() or fp.is_symlink():
                    freed += fp.lstat().st_size
                    fp.unlink()
                    n += 1
            except OSError:
                continue
    return n, freed


CLIENT_BAT_LINES = [
    '@echo off',
    'setlocal',
    'title Fix broken CS 1.6 files (OLD ZOMBIE)',
    'cd /d "%~dp0"',
    'set "CSDIR="',
    'if exist "cstrike\\maps" set "CSDIR=%cd%\\cstrike"',
    'if not defined CSDIR if exist "%ProgramFiles(x86)%\\Steam\\steamapps\\common\\Half-Life\\cstrike" set "CSDIR=%ProgramFiles(x86)%\\Steam\\steamapps\\common\\Half-Life\\cstrike"',
    'if not defined CSDIR if exist "%ProgramFiles%\\Steam\\steamapps\\common\\Half-Life\\cstrike" set "CSDIR=%ProgramFiles%\\Steam\\steamapps\\common\\Half-Life\\cstrike"',
    'if defined CSDIR goto found',
    'echo Half-Life folder was not found automatically.',
    'echo Drag the Half-Life folder ^(the one that contains "cstrike"^) into this window and press Enter:',
    'set /p "HL="',
    'call set "HL=%%HL:"=%%"',
    'if exist "%HL%\\cstrike" set "CSDIR=%HL%\\cstrike"',
    'if defined CSDIR goto found',
    'echo cstrike folder not found. Put this file into the Half-Life folder and run it again.',
    'pause',
    'exit /b 1',
    ':found',
    'echo Checking %CSDIR% ...',
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText(\'%~f0\'); $i=$s.IndexOf(\'#PS#\'+\'START\'); Invoke-Expression $s.Substring($i)"',
    'echo.',
    'echo Start the game and reconnect. Missing files will be downloaded again.',
    'pause',
    'exit /b 0',
    '#PS#START',
    '$root = $env:CSDIR',
    '$dirs = "maps","models","sound","sprites","gfx","resource","overviews"',
    '$ext = ".bsp",".mdl",".spr",".wav",".mp3",".tga",".bmp",".wad"',
    '$bad = 0; $checked = 0',
    'foreach ($d in $dirs) {',
    '  $p = Join-Path $root $d',
    '  if (-not (Test-Path -LiteralPath $p)) { continue }',
    '  Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $ext -contains $_.Extension.ToLower() } | ForEach-Object {',
    '    $checked++',
    '    $broken = $false',
    '    if ($_.Length -eq 0) { $broken = $true }',
    '    else {',
    '      try {',
    '        $fs = [IO.File]::OpenRead($_.FullName)',
    '        $buf = New-Object byte[] 64',
    '        $n = $fs.Read($buf, 0, 64)',
    '        $fs.Close()',
    '        $t = [Text.Encoding]::ASCII.GetString($buf, 0, $n).TrimStart(@([char]63, [char]32, [char]9, [char]13, [char]10)).ToLower()',
    '        foreach ($m in "<!doctype","<html","<head","<body","<?php","<meta") { if ($t.StartsWith($m)) { $broken = $true } }',
    '      } catch { }',
    '    }',
    '    if ($broken) {',
    '      Write-Host ("Deleting broken file: " + $_.FullName.Substring($root.Length + 1))',
    '      Remove-Item -LiteralPath $_.FullName -Force',
    '      $bad++',
    '    }',
    '  }',
    '}',
    'Write-Host ("Checked " + $checked + " files, removed " + $bad + " broken file(s).")',
]
CLIENT_BAT_TEXT = '\r\n'.join(CLIENT_BAT_LINES) + '\r\n'
CLIENT_BAT_NAMES = ('fix-cs-files.bat', 'fix-cs-maps.bat')   # second name = link from the previous patch


def write_client_bat():
    last = None
    for name in CLIENT_BAT_NAMES:
        p = Path(FASTDL_ROOT) / name
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, 'wb') as f:
            f.write(CLIENT_BAT_TEXT.encode('ascii'))
        os.chmod(p, 0o644)
        last = last or p
    return last


# --------------------------------------------------------------------------
# game-side checks: HTML-instead-of-file inside the server's own resources and
# plugin-referenced files that are missing (typically wrong upper/lower case,
# Linux is case-sensitive: "sprites/YouTuber/x.spr" != "sprites/youtuber/x.spr")
# --------------------------------------------------------------------------
GAME_RES_DIRS = ('maps', 'models', 'sound', 'sprites', 'gfx', 'resource', 'overviews')
SERVERS_BASE = '/srv/hyper-cs16/servers'
EXPLICIT_RES = ['sound/weapons/balrog9_charge_attack2.wav',
                'sprites/YouTuber/640hud60.spr',
                'sprites/YouTuber/640hud128.spr',
                'models/oldz_level/v_lava_axe.mdl']
RES_RE = re.compile(r'"([^"\\\s%]+?\.(?:wav|mp3|mdl|spr|tga|bmp))"', re.I)


def game_scan(sid):
    cs = Path(SERVERS_BASE) / str(sid) / 'cstrike'
    bad = []
    checked = 0
    for d in GAME_RES_DIRS:
        root = cs / d
        if not root.is_dir():
            continue
        for fp in root.rglob('*'):
            try:
                if not fp.is_file() or fp.is_symlink() or fp.suffix.lower() not in BIN_EXT - {'.bz2'}:
                    continue
                checked += 1
                with open(fp, 'rb') as f:
                    head = f.read(64)
                if fp.stat().st_size == 0:
                    bad.append((fp.relative_to(cs).as_posix(), 'empty'))
                elif looks_html(head):
                    bad.append((fp.relative_to(cs).as_posix(), 'HTML page instead of a file'))
            except OSError:
                continue
    return checked, bad


def _ci_resolve(base, rel):
    """Case-insensitive lookup of rel under base; returns the real Path or None."""
    cur = Path(base)
    for part in [x for x in rel.split('/') if x]:
        nxt = cur / part
        if nxt.exists():
            cur = nxt
            continue
        try:
            names = os.listdir(cur)
        except OSError:
            return None
        hit = [n for n in names if n.lower() == part.lower()]
        if not hit:
            return None
        cur = cur / hit[0]
    return cur if cur.exists() else None


def resource_audit(sid, fix_case):
    cs = Path(SERVERS_BASE) / str(sid) / 'cstrike'
    refs = set(EXPLICIT_RES)
    scripting = cs / 'addons' / 'amxmodx' / 'scripting'
    if scripting.is_dir():
        for sma in scripting.glob('*.sma'):
            try:
                text = sma.read_bytes().decode('latin-1')
            except OSError:
                continue
            for m in RES_RE.finditer(text):
                p = m.group(1).replace('\\', '/').lstrip('./')
                if p.lower().endswith(('.wav', '.mp3')) and not p.lower().startswith('sound/'):
                    p = 'sound/' + p
                if '/' in p and not p.lower().startswith(('http', 'cstrike/')):
                    refs.add(p)
    ok = 0
    fixed = []
    missing = []
    for rel in sorted(refs):
        if (cs / rel).exists():
            ok += 1
            continue
        real = _ci_resolve(cs, rel)
        if real is not None and real.is_file():
            if fix_case:
                dst = cs / rel
                try:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(real, dst)
                    fixed.append((rel, real.relative_to(cs).as_posix()))
                except OSError as e:
                    missing.append((rel, 'case mismatch but copy failed: %s' % e))
            else:
                missing.append((rel, 'exists only as %s (case differs)' % real.relative_to(cs).as_posix()))
        else:
            missing.append((rel, 'not found in any case'))
    return len(refs), ok, fixed, missing



# --------------------------------------------------------------------------
# sv_downloadurl MUST end with "/": the engine appends "maps/x.bsp" directly, so
# "http://IP/fastdl/25" + "maps/x.bsp" = "/fastdl/25maps/x.bsp" (404 or, in the
# old setup, the panel's HTML page that the client then saved as the file).
# --------------------------------------------------------------------------
URL_RE = re.compile(r'(?im)^(\s*sv_downloadurl\s+)"([^"]*)"')


def fix_download_url(sids, runtime=True):
    changes = []
    for sid in sids:
        cfg = Path(SERVERS_BASE) / str(sid) / 'cstrike' / 'server.cfg'
        if cfg.is_file():
            try:
                text = read_file(str(cfg))
            except OSError:
                text = ''
            found = []

            def sub(m):
                url = m.group(2)
                if url.lower().startswith('http') and not url.endswith('/'):
                    found.append(url)
                    return '%s"%s/"' % (m.group(1), url)
                return m.group(0)
            new = URL_RE.sub(sub, text)
            if found and new != text:
                bak = str(cfg) + '.hyper-bak'
                if not os.path.exists(bak):
                    shutil.copy2(str(cfg), bak)
                write_file(str(cfg), new)
                changes.append('server.cfg #%s: "%s" -> trailing slash added' % (sid, found[0]))
        if runtime and os.path.exists(CTL):
            rc, out = sh([CTL, 'rcon', str(sid), 'sv_downloadurl'], timeout=25)
            mo = re.search(r'sv_downloadurl\\?"\s+is\s+\\?"([^"\\]*)', out)
            if mo and mo.group(1).lower().startswith('http') and not mo.group(1).endswith('/'):
                val = mo.group(1) + '/'
                rc, out2 = sh([CTL, 'rcon', str(sid), 'sv_downloadurl "%s"' % val], timeout=25)
                changes.append('runtime #%s: sv_downloadurl -> "%s" (%s)' % (sid, val, 'ok' if rc == 0 and 'timed out' not in out2 else 'rcon failed: ' + out2.strip()[:80]))
    return changes


# --------------------------------------------------------------------------
# what did the players' clients ask FastDL for? (join diagnostics)
# --------------------------------------------------------------------------
LOG_RE = re.compile(r'^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d{3}) (\d+|-)')


def joinlog(minutes, ip, sids=None):
    from collections import Counter
    from datetime import datetime
    if not os.path.exists(ACCESS_LOG):
        log('  no FastDL access log yet (%s)' % ACCESS_LOG)
        return
    size = os.path.getsize(ACCESS_LOG)
    with open(ACCESS_LOG, 'rb') as f:
        f.seek(max(0, size - 40 * 1048576))
        lines = f.read().decode('utf-8', errors='replace').splitlines()
    cutoff = time.time() - minutes * 60
    rows = []
    for ln in lines:
        m = LOG_RE.match(ln)
        if not m:
            continue
        try:
            ts = datetime.strptime(m.group(2), '%d/%b/%Y:%H:%M:%S %z').timestamp()
        except ValueError:
            continue
        if ts >= cutoff:
            rows.append((ts, m.group(1), m.group(4).split('?')[0], int(m.group(5)), m.group(6)))
    log('  FastDL requests in the last %d min: %d' % (minutes, len(rows)))
    if not rows:
        log('  (none: clients are NOT using FastDL - they download everything over UDP from the game server, or cannot reach port 80)')
        return
    st = Counter(r[3] for r in rows)
    log('  status codes: ' + ', '.join('%s x%d' % kv for kv in st.most_common()))
    glued = [r for r in rows if re.match(r'^/fastdl/\d+[^/\d]', r[2])]
    if glued:
        log('  requests with a glued URL (/fastdl/25maps/...): %d  (client did not add a "/" itself; nginx rewrites them)' % len(glued))
    miss = Counter(r[2] for r in rows if r[3] == 404)
    if miss:
        log('  most requested files that do NOT exist (404):')
        for p, c in miss.most_common(12):
            log('    %4d  %s' % (c, p))
    ips = Counter(r[1] for r in rows)
    log('  clients: ' + ', '.join('%s x%d' % kv for kv in ips.most_common(8)))
    if ip:
        mine = [r for r in rows if r[1] == ip]
        log('  --- client %s ---' % ip)
        if not mine:
            log('  no FastDL requests from this IP in the period')
        else:
            stc = Counter(r[3] for r in mine)
            fmt = lambda t: time.strftime('%H:%M:%S', time.gmtime(t))
            log('  FastDL: %d requests %s .. %s UTC, status: %s' % (len(mine), fmt(mine[0][0]), fmt(mine[-1][0]),
                ', '.join('%s x%d' % kv for kv in stc.most_common())))
            for p, c in Counter(r[2] for r in mine if r[3] == 404).most_common(15):
                log('    404 x%d  %s' % (c, p))
        for sid in sids or []:
            rc, out = sh(['journalctl', '-u', 'hyper-cs16@%s' % sid, '--since', '%d minutes ago' % minutes,
                          '--no-pager', '-o', 'short-iso'], timeout=60)
            hits = [l for l in out.splitlines() if ip.split('.')[0] + '.' in l and ip in l]
            if hits:
                log('  game server #%s log lines with this IP (connect / drop / reconnect):' % sid)
                for l in hits[-20:]:
                    log('    ' + l[:200])
        log('  (after the last FastDL request the client loads models/sounds; if it drops there, only ITS console says why: launch with -condebug, send cstrike/qconsole.log)')


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


def cmd_nomaps(a):
    n, freed = purge_maps(parse_sids(a.sids))
    log('  [OK] removed %d map file(s) (%.1f MiB) from FastDL; the game server keeps its own maps' % (n, freed / 1048576.0))
    return 0


def cmd_clientfix(a):
    p = write_client_bat()
    log('  [OK] player repair tool written: %s' % p)
    return 0


def cmd_gamescan(a):
    for sid in parse_sids(a.sids):
        checked, bad = game_scan(sid)
        log('  server #%s: checked %d resource files inside the game folder' % (sid, checked))
        if not bad:
            log('  [OK] none of them is an HTML page or empty')
        for rel, why in bad[:40]:
            log('  [BAD] cstrike/%s : %s  -> replace this file, otherwise every new player downloads garbage' % (rel, why))
    return 0


def cmd_audit(a):
    for sid in parse_sids(a.sids):
        total, ok, fixed, missing = resource_audit(sid, a.fix_case)
        log('  server #%s: %d resources referenced by plugin sources, %d present' % (sid, total, ok))
        for rel, real in fixed:
            log('  [CASE FIXED] %s  (copied from %s)' % (rel, real))
        for rel, why in missing[:40]:
            log('  [MISSING] %s : %s' % (rel, why))
        if len(missing) > 40:
            log('  ... and %d more' % (len(missing) - 40))
        if not fixed and not missing:
            log('  [OK] every referenced resource exists')
    return 0


def cmd_fixurl(a):
    ch = fix_download_url(parse_sids(a.sids), runtime=True)
    for c in ch:
        log('  [FIXED] ' + c)
    if not ch:
        log('  [OK] sv_downloadurl already ends with "/"')
    return 0


def cmd_joinlog(a):
    sids = parse_sids(a.sids)
    if not sids:
        try:
            sids = [str(x) for x in json.load(open(GUARD_CFG)).get('sids', [])]
        except Exception:
            sids = []
    joinlog(a.minutes, a.ip, sids)
    return 0


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
    if BLOCK_MAPS:
        n, _ = purge_maps(sids)
        if n:
            log('guard: removed %d map file(s) that the panel copied back into FastDL' % n)
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
        if not cfg.get('fix_url', False):
            raise StopIteration
        do_rt = now - float(st.get('last_url_rcon', 0)) > 600
        if do_rt:
            st['last_url_rcon'] = now
        for c in fix_download_url(sids, runtime=do_rt):
            log('guard: ' + c)
    except StopIteration:
        pass
    except Exception as e:  # noqa
        log('guard: fix_download_url failed: %s' % e)
    if os.path.exists(CRASHFIX) and now - float(st.get('last_crashfix', 0)) > 3600:
        st['last_crashfix'] = now
        for sid in sids:
            rc, out = sh([CRASHFIX, 'analyze', '--sid', sid, '--hours', '6', '--apply'], timeout=120)
            if 'DISABLED' in out or 'startup map' in out:
                log('guard: crashfix acted:\n' + out)
    try:
        made = 0
        if cfg.get('bz2', False):
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
    for name in ('apply', 'probe', 'scan', 'guard', 'bzip', 'ctl-ensure', 'nomaps', 'client-fix', 'game-scan', 'audit', 'fix-url', 'joinlog'):
        p = sp.add_parser(name)
        p.add_argument('--host', default='127.0.0.1')
        p.add_argument('--sids', default='')
        p.add_argument('--backup', default=None)
        p.add_argument('--maps', default=None, choices=['allow', 'block'])
        p.add_argument('--fix-case', action='store_true')
        p.add_argument('--minutes', type=int, default=30)
        p.add_argument('--ip', default=None)
    a = ap.parse_args()
    global BLOCK_MAPS
    if a.maps:
        BLOCK_MAPS = (a.maps == 'block')
    else:
        try:
            BLOCK_MAPS = bool(json.load(open(GUARD_CFG)).get('block_maps', True))
        except Exception:
            BLOCK_MAPS = True
    return {'apply': cmd_apply, 'probe': cmd_probe, 'scan': cmd_scan, 'guard': cmd_guard,
            'bzip': cmd_bzip, 'ctl-ensure': cmd_ctl, 'nomaps': cmd_nomaps, 'client-fix': cmd_clientfix,
            'game-scan': cmd_gamescan, 'audit': cmd_audit,
            'fix-url': cmd_fixurl, 'joinlog': cmd_joinlog}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
HYPER_PY
chmod 0755 "$HELPER"
python3 -m py_compile "$HELPER" && echo "    [OK] $HELPER" || { echo '[ERROR] helper is broken'; exit 2; }

cat > "$CRASHFIX" <<'HYPER_CF'
#!/usr/bin/env python3
# hyper-cs16-crashfix - find maps that kill the server with
#   "Host_Error: PF_precache_sound_I: Sound '...' failed to precache because
#    the item count is over the 512 limit"
# (GoldSrc allows max 512 precached sounds per map; ZP + VIP plugins + the map's
# own ambient sounds overflow it on some maps -> every load of that map crashes
# the server and kicks everybody, in a loop).
#
#   hyper-cs16-crashfix analyze --sid 25 [--hours 24] [--apply]
#
# --apply is reversible and never deletes anything:
#   * such maps are commented out in mapcycle.txt / amxmodx maps.ini
#   * if the server's startup map is one of them, it is switched to a good map
#     (the original file is backed up first)
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter

BASE = '/srv/hyper-cs16/servers'
RE_LOAD = re.compile(r'Loading map "([^"]+)"')
RE_STARTED = re.compile(r'Started map "([^"]+)"')
RE_FAIL = re.compile(r'failed to precache because the item count is over the (\d+)|Host_Error:.*precache', re.I)
RE_SND = re.compile(r"[Ss]ound '([^']+)'")
START_KEYS = ('map', 'default_map', 'startmap', 'start_map', 'map_name', 'startup_map')


def read_lines(sid, hours, jf):
    if jf:
        with open(jf, errors='replace') as f:
            return f.read().splitlines()
    p = subprocess.run(['journalctl', '-u', 'hyper-cs16@%s' % sid, '--since', '%d hours ago' % hours,
                        '--no-pager', '-o', 'cat'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       text=True, errors='replace')
    return p.stdout.splitlines()


def analyze(lines):
    cur = None
    failed = False
    loads, started, fails, snd = Counter(), Counter(), Counter(), Counter()
    unknown = 0
    limit = None
    for ln in lines:
        m = RE_LOAD.search(ln)
        if m:
            cur = m.group(1)
            failed = False
            loads[cur] += 1
            continue
        m = RE_STARTED.search(ln)
        if m:
            cur = m.group(1)
            started[cur] += 1
            failed = False
            continue
        m = RE_FAIL.search(ln)
        if m:
            if m.group(1):
                limit = m.group(1)
            s = RE_SND.search(ln)
            if s:
                snd[s.group(1)] += 1
            if not failed:
                failed = True
                if cur:
                    fails[cur] += 1
                else:
                    unknown += 1
    return loads, started, fails, snd, unknown, limit


def comment_maps(path, bad, prefix, backup):
    if not os.path.isfile(path):
        return []
    with open(path, 'rb') as f:
        raw = f.read().decode('utf-8', errors='surrogateescape')
    out = []
    changed = []
    for l in raw.splitlines(True):
        t = l.strip()
        name = None
        if t and not t.startswith(('//', ';', '#')):
            name = t.split()[0].lower()
            if name.endswith('.bsp'):
                name = name[:-4]
        if name in bad:
            out.append('%s HYPER-DISABLED(precache-limit) %s' % (prefix, l))
            changed.append(name)
        else:
            out.append(l)
    if changed:
        os.makedirs(backup, exist_ok=True)
        shutil.copy2(path, os.path.join(backup, os.path.basename(path)))
        with open(path, 'wb') as f:
            f.write(''.join(out).encode('utf-8', errors='surrogateescape'))
    return changed


def good_maps(path, bad, started):
    res = []
    if os.path.isfile(path):
        for l in open(path, errors='replace'):
            t = l.strip()
            if t and not t.startswith(('//', ';', '#')):
                n = t.split()[0]
                n = n[:-4] if n.lower().endswith('.bsp') else n
                if n.lower() not in bad:
                    res.append(n)
    res.sort(key=lambda m: -started.get(m, 0))
    return res


def fix_json(path, bad, replacement, backup):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return None
    hit = []

    def walk(x):
        if isinstance(x, dict):
            for k, v in list(x.items()):
                if k.lower() in START_KEYS and isinstance(v, str) and v.lower() in bad:
                    hit.append((k, v))
                    x[k] = replacement
                else:
                    walk(v)
        elif isinstance(x, list):
            for i in x:
                walk(i)
    walk(data)
    if not hit:
        return []
    os.makedirs(backup, exist_ok=True)
    shutil.copy2(path, os.path.join(backup, os.path.basename(path)))
    with open(path, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    return hit


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd', required=True)
    a1 = sp.add_parser('analyze')
    a1.add_argument('--sid', required=True)
    a1.add_argument('--hours', type=int, default=24)
    a1.add_argument('--apply', action='store_true')
    a1.add_argument('--journal-file', default=None)
    a1.add_argument('--base', default=BASE)
    a1.add_argument('--json-dir', default='/etc/hyper-cs16/servers')
    a = ap.parse_args()

    sid = a.sid
    lines = read_lines(sid, a.hours, a.journal_file)
    loads, started, fails, snd, unknown, limit = analyze(lines)
    total = sum(fails.values()) + unknown
    print('  precache-limit crashes in the last %dh: %d%s' % (a.hours, total, (' (limit %s sounds)' % limit) if limit else ''))
    if not total:
        print('  [OK] no "over the 512" crash found')
        return 0
    print('  map                          loads  started  crashed')
    for m, c in fails.most_common(12):
        print('  %-28s %5d  %7d  %7d' % (m, loads[m], started[m], c))
    if unknown:
        print('  (%d crash(es) could not be attributed to a map)' % unknown)
    print('  sounds that failed most: ' + ', '.join('%s x%d' % kv for kv in snd.most_common(6)))

    bad = set(m.lower() for m, c in fails.items() if c >= 3 and c > started[m])
    if not bad:
        print('  no single map is clearly responsible (needs >=3 crashes and more crashes than successful starts)')
        return 0
    print('  MAPS THAT CRASH THE SERVER: ' + ', '.join(sorted(bad)))
    if not a.apply:
        print('  (dry run: run with --apply to disable them)')
        return 0

    cs = os.path.join(a.base, sid, 'cstrike')
    backup = '/root/hyper-crashfix-backup-%d' % int(time.time())
    files = [(os.path.join(cs, 'mapcycle.txt'), '//'),
             (os.path.join(cs, 'addons/amxmodx/configs/maps.ini'), ';')]
    cycle = os.path.join(cs, 'mapcycle.txt')
    remaining = good_maps(cycle, bad, started)
    if os.path.isfile(cycle) and not remaining:
        print('  [SKIP] every map in mapcycle.txt would be disabled - not touching anything')
        return 0
    for path, prefix in files:
        ch = comment_maps(path, bad, prefix, backup)
        if ch:
            print('  [DISABLED] %s: %s   (backup in %s)' % (path, ', '.join(sorted(set(ch))), backup))
    repl = remaining[0] if remaining else None
    if repl:
        hit = fix_json(os.path.join(a.json_dir, '%s.json' % sid), bad, repl, backup)
        for k, v in (hit or []):
            print('  [FIXED] startup map "%s" crashed the server on every start -> now "%s" (key %s); applies at next start' % (v, repl, k))
    return 0


if __name__ == '__main__':
    sys.exit(main())
HYPER_CF
chmod 0755 "$CRASHFIX"
python3 -m py_compile "$CRASHFIX" && echo "    [OK] $CRASHFIX" || echo '    [WARN] crashfix is broken'
rm -rf /usr/local/sbin/__pycache__ 2>/dev/null || true

MAPS_MODE="block"
[[ "${HYPER_FASTDL_MAPS:-}" == "allow" ]] && MAPS_MODE="allow"
echo "    maps over FastDL: $MAPS_MODE"

# ---------------------------------------------------------------------------
# 3. hyper-cs16-ctl: add the missing "fastdl-clean" command
# ---------------------------------------------------------------------------
echo
echo '[3] Fixing panel error: hyper-cs16-ctl has no "fastdl-clean"...'
CTL_RC=1
if [[ -f "$CTL" ]]; then
  mkdir -p "$BACKUP/ctl" && cp -a "$CTL" "$BACKUP/ctl/hyper-cs16-ctl.orig"
  "$HELPER" ctl-ensure
  CTL_RC=$?
  echo "    self-test (must print ok:false / invalid server id, NOT an argparse error):"
  "$CTL" fastdl-clean x 2>&1 | tail -n 2 | sed 's/^/      /'
else
  echo "    [SKIP] $CTL not found"
fi

# ---------------------------------------------------------------------------
# 4. Quarantine HTML / empty / corrupt files inside FastDL
# ---------------------------------------------------------------------------
echo
echo '[4] Scanning FastDL for HTML/empty/corrupt files (moved, not deleted)...'
"$HELPER" scan --sids "$SIDS_CSV" || true

# ---------------------------------------------------------------------------
# 5. nginx: strict, browsable /fastdl/, maps not served
# ---------------------------------------------------------------------------
echo
echo '[5] Patching nginx /fastdl/ ...'
mkdir -p /etc/hyper-cs16
python3 - "$HOST" "$MAPS_MODE" "${HYPER_FIX_URL:-0}" "${HYPER_BZ2:-0}" "${SIDS[@]}" > /etc/hyper-cs16/fastdl-guard.json <<'PY'
import json, sys
print(json.dumps({'host': sys.argv[1], 'block_maps': sys.argv[2] == 'block', 'fix_url': sys.argv[3] == '1', 'bz2': sys.argv[4] == '1', 'sids': [int(x) for x in sys.argv[5:]]}))
PY
"$HELPER" apply --host "$HOST" --sids "$SIDS_CSV" --maps "$MAPS_MODE" --backup "$BACKUP/nginx"
NGX_RC=$?
if [[ $NGX_RC -eq 0 ]]; then echo '    [OK] nginx FastDL routing verified'; else echo "    [WARN] helper exit code $NGX_RC (see lines above)"; fi

# ---------------------------------------------------------------------------
# 5a. sv_downloadurl needs a trailing slash (root cause of the HTML files)
# ---------------------------------------------------------------------------
echo
echo '[5a] sv_downloadurl (trailing slash) ...'
if [[ "${HYPER_FIX_URL:-0}" == "1" ]]; then
  "$HELPER" fix-url --sids "$SIDS_CSV" || true
else
  echo '    skipped: the Steam HTTP client in your log requests /fastdl/25/... correctly, so the value stays as the panel sets it'
  echo '    (HYPER_FIX_URL=1 would add the slash if some client builds glue the name on)'
fi

# ---------------------------------------------------------------------------
# 5b. Game files first (so that the FastDL rebuild below already contains the fixes)
# ---------------------------------------------------------------------------
echo
echo '[5b] Game folder: HTML-instead-of-file, missing / wrong-case resources...'
"$HELPER" game-scan --sids "$SIDS_CSV" || true
"$HELPER" audit --sids "$SIDS_CSV" --fix-case || true

# ---------------------------------------------------------------------------
# 6. Rebuild FastDL, remove maps from it, create .bz2
# ---------------------------------------------------------------------------
echo
echo '[6] Rebuilding FastDL (fastdl-sync)...'
if [[ -f "$CTL" ]]; then
  for sid in "${SIDS[@]}"; do
    [[ -d "$SERVERS_BASE/$sid/cstrike" ]] || continue
    echo "  -- server #$sid"
    "$CTL" fastdl-sync "$sid" 2>&1 | tail -n 3 | cut -c1-300 || true
  done
fi
if [[ "$MAPS_MODE" == "block" ]]; then
  "$HELPER" nomaps --sids "$SIDS_CSV" --maps block
fi
if [[ "${HYPER_BZ2:-0}" == "1" ]]; then
  "$HELPER" bzip --sids "$SIDS_CSV" --maps "$MAPS_MODE" || true
else
  echo '    .bz2 creation skipped (your clients request plain files; HYPER_BZ2=1 enables it)'
fi
"$HELPER" scan --sids "$SIDS_CSV" || true
for sid in "${SIDS[@]}"; do
  B1="$(find "$FASTDL_BASE/$sid" -type f -name '*.bz2' 2>/dev/null | wc -l)"
  echo "    server #$sid: $(find "$FASTDL_BASE/$sid" -type f ! -name '*.bz2' ! -name '.*' 2>/dev/null | wc -l) files, $B1 .bz2, maps in FastDL: $(find "$FASTDL_BASE/$sid/maps" -type f 2>/dev/null | wc -l)"
  echo "    (the game server's own maps: $(find "$SERVERS_BASE/$sid/cstrike/maps" -maxdepth 1 -name '*.bsp' 2>/dev/null | wc -l) .bsp - untouched)"
done
echo '    who triggers fastdl-sync on this machine (if .bz2 files keep disappearing):'
grep -rlE 'fastdl-sync' /etc/systemd/system /etc/cron.d /etc/cron.hourly /etc/cron.daily /usr/local/sbin /opt 2>/dev/null | grep -v -e 'hyper-cs16-fastdl-nginx' -e 'hyper-cs16-ctl' | head -n 6 | sed 's/^/      /' || true

# ---------------------------------------------------------------------------
# 7. Game files: HTML-instead-of-file, missing/case-mismatched resources, player tool
# ---------------------------------------------------------------------------
echo
echo '[7] Game files and player repair tool...'
echo '    spot check of the files from your client log (server file / FastDL over HTTP):'
for sid in "${SIDS[@]}"; do
  for rel in models/oldz_level/v_lava_axe.mdl sound/weapons/balrog9_charge_attack2.wav sprites/YouTuber/640hud60.spr; do
    f="$SERVERS_BASE/$sid/cstrike/$rel"
    if [[ -f "$f" ]]; then hd="$(head -c 4 "$f" | od -An -c | tr -s ' ' | head -n1)"; else hd="MISSING ON SERVER"; fi
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $HOST" "http://127.0.0.1/fastdl/$sid/$rel" 2>/dev/null || echo 000)"
    code2="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $HOST" "http://127.0.0.1/fastdl/$sid/$rel.bz2" 2>/dev/null || echo 000)"
    printf '      %-55s head=%-22s FastDL: %s / .bz2: %s\n' "$rel" "$hd" "$code" "$code2"
  done
done
echo '      (head must be: IDST / IDSP / RIFF ; FastDL 200. A "<!do" head = HTML page = replace that file)'
"$HELPER" client-fix
echo "    OLD PLAYERS run once: http://$HOST/fastdl/fix-cs-files.bat"
echo '    (put it into the Half-Life folder; it removes only files that are really HTML/empty)'

# ---------------------------------------------------------------------------
# 8. Crash loop: maps that overflow the 512-sound precache limit
# ---------------------------------------------------------------------------
echo
echo '[8] Crash-loop analysis (Host_Error precache ... over the 512)...'
for sid in "${SIDS[@]}"; do
  [[ -d "$SERVERS_BASE/$sid/cstrike" ]] || continue
  echo "  -- server #$sid"
  "$CRASHFIX" analyze --sid "$sid" --hours 24 --apply || true
done
if [[ "${HYPER_RUN_FASTJOIN:-0}" == "1" && -f "$REPO/INSTALL_SERVER25_FASTJOIN_V1.sh" ]]; then
  echo '  running your FASTJOIN_V1 (fewer precached sounds; restarts the game server):'
  bash "$REPO/INSTALL_SERVER25_FASTJOIN_V1.sh" "${SIDS[0]}" "$REPO" 2>&1 | tail -n 25
fi

# ---------------------------------------------------------------------------
# 9. Server cvars
# ---------------------------------------------------------------------------
echo
echo '[9] Checking server cvars...'
for sid in "${SIDS[@]}"; do
  [[ -d "$SERVERS_BASE/$sid/cstrike" ]] || continue
  echo "  -- server #$sid"
  out="$("$CTL" rcon "$sid" 'sv_downloadurl' 2>&1 || true)"; echo "    $out" | cut -c1-200 | head -n 2
  out2="$("$CTL" rcon "$sid" 'sv_allowdownload' 2>&1 || true)"; echo "    $out2" | cut -c1-200 | head -n 2
  echo "$out2" | grep -qE 'is \\"0\\"' && echo '    [WARN] sv_allowdownload is 0 - clients cannot download maps from the server at all!'
done

# ---------------------------------------------------------------------------
# 10. php-fpm: pm.max_children 5 -> 40
# ---------------------------------------------------------------------------
echo
echo '[10] php-fpm capacity (panel errors under load)...'
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
# 11. Stability: auto-restart drop-ins + guard timer
# ---------------------------------------------------------------------------
echo
echo '[11] Stability (systemd auto-restart + guard)...'
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

mkdir -p /var/lib/hyper-cs16
cat > /etc/systemd/system/hyper-cs16-fastdl-guard.service <<'UNIT'
[Unit]
Description=HYPER CS16 FastDL guard (routing, HTML/corrupt files, maps out of FastDL, .bz2, ctl fix, crash loop)

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
# Join diagnostics: what did the clients ask FastDL for?
# ---------------------------------------------------------------------------
echo
echo '[JOIN] What players requested from FastDL in the last 60 minutes...'
"$HELPER" joinlog --minutes 60 --sids "$SIDS_CSV" || true
echo '    one player (HTTP requests + the game server connect/drop lines):'
echo '      sudo hyper-cs16-fastdl-nginx joinlog --minutes 120 --sids 25 --ip <player IP>'

# ---------------------------------------------------------------------------
# Final verification exactly as a client / browser would do it
# ---------------------------------------------------------------------------
echo
echo '[CHECK] Final HTTP verification...'
"$HELPER" probe --host "$HOST" --sids "$SIDS_CSV" --maps "$MAPS_MODE"
FINAL_RC=$?
echo "--- http://$HOST/fastdl/${SIDS[0]}  (no trailing slash, like the panel link) ---"
curl -sS -m 10 -o /dev/null -D - -H "Host: $HOST" "http://127.0.0.1/fastdl/${SIDS[0]}" 2>/dev/null | grep -iE '^HTTP/|^location' || true
echo '--- player repair tool ---'
curl -sS -m 10 -o /dev/null -D - -H "Host: $HOST" "http://127.0.0.1/fastdl/fix-cs-files.bat" 2>/dev/null | grep -iE '^HTTP/|^content-length' || true

echo
echo '============================================================'
if [[ $FINAL_RC -eq 0 && $NGX_RC -eq 0 && ${CTL_RC:-1} -eq 0 ]]; then
  echo '[DONE] FASTDL-FIX v6 applied and verified.'
else
  echo '[DONE WITH WARNINGS] read the [FAIL]/[WARN]/[ERROR] lines above and send me this report.'
fi
echo "Open in browser : http://$HOST/fastdl/${SIDS[0]}/"
echo "Old players (broken files): http://$HOST/fastdl/fix-cs-files.bat"
echo "Backup          : $BACKUP"
echo "Report          : $REPORT"
echo
echo 'Test as a real player:'
echo '  1) on the PC of an old player: run fix-cs-files.bat once, then reconnect'
echo '  2) the map now comes from the game server itself (a few seconds, no HTTP)'
echo '  3) sounds/models still come from FastDL:  sudo tail -F /var/log/nginx/hyper-cs16-fastdl-access.log'
echo
echo 'Rollback:'
echo '  nginx : sudo find /etc/nginx -name hyper-cs16-fastdl-standalone.conf -delete && sudo nginx -t && sudo systemctl reload nginx'
echo "  ctl   : sudo cp -a $BACKUP/ctl/hyper-cs16-ctl.orig $CTL && sudo rm -f $CTL.real"
echo '  maps  : restore mapcycle.txt/maps.ini/json from /root/hyper-crashfix-backup-*'
echo '  guard : sudo systemctl disable --now hyper-cs16-fastdl-guard.timer'
echo 'Maps back on FastDL: HYPER_FASTDL_MAPS=allow sudo bash apply-fastdl-fix-v6.sh 25'
echo '============================================================'
exit 0
