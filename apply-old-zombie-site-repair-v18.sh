#!/usr/bin/env bash
set -Eeuo pipefail
DOMAIN="${1:-old-zombie.ru}"
PUBLIC_IP="${2:-90.189.208.25}"
TARGET="/etc/nginx/hyper-host-managed/20-site-${DOMAIN}.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-site-repair-v18-${STAMP}"
mkdir -p "$BACKUP"
fail(){ echo "[ERROR] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"

echo "[1/8] Capture nginx..."
nginx -T >"$BACKUP/nginx-T-before.txt" 2>&1
[[ -f "$TARGET" ]] && cp -a "$TARGET" "$BACKUP/current.conf" || true

echo "[2/8] Find best historical old-zombie vhost..."
BEST="$(python3 - "$DOMAIN" "$BACKUP" <<'PY'
from pathlib import Path
import re,sys
domain=sys.argv[1]; backup=Path(sys.argv[2])
cands=[]; seen=set()
patterns=["/root/*fastdl*/**/*","/root/*oldz*/**/*","/root/*nginx*/**/*","/etc/nginx/**/*.conf*"]
for pat in patterns:
    for p in Path("/").glob(pat.lstrip("/")):
        try:
            if not p.is_file() or p.stat().st_size>2_000_000: continue
            rp=str(p.resolve())
            if rp in seen: continue
            seen.add(rp)
            txt=p.read_text(encoding="utf-8",errors="ignore")
        except Exception:
            continue
        if domain not in txt or "server_name" not in txt: continue
        score=0
        if re.search(r'(?m)^\s*root\s+/var/www/hyper-host-sites/',txt): score+=40
        if "fastcgi_pass" in txt: score+=35
        if "try_files" in txt: score+=15
        if "listen 443" in txt or "ssl_certificate" in txt: score+=20
        if re.search(r'(?m)^\s*index\s+',txt): score+=10
        if "SCRIPT_FILENAME" in txt: score+=15
        for marker in ["OLDZ V9 BEGIN","HYPER-HOST FASTDL IP FINAL","HYPER-HOST FASTDL ROUTE FIX","HYPER-HOST CS 1.6 FastDL"]:
            if marker in txt: score-=25
        if "old-zombie" in p.name.lower(): score+=15
        if any(x in p.name.lower() for x in ["before","bak","backup","pre-"]): score+=12
        cands.append((score,p.stat().st_mtime,str(p)))
if not cands: raise SystemExit("no candidate")
cands.sort(key=lambda x:(x[0],x[1]),reverse=True)
(backup/"candidate-ranking.txt").write_text("\n".join(f"{s}\t{m:.0f}\t{p}" for s,m,p in cands[:30])+"\n",encoding="utf-8")
print(cands[0][2])
PY
)"
echo "candidate: $BEST"
cp -a "$BEST" "$BACKUP/selected-source.conf"

echo "[3/8] Restore clean domain vhost only..."
python3 - "$BEST" "$TARGET" "$DOMAIN" "$PUBLIC_IP" <<'PY'
from pathlib import Path
import re,sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2]); domain=sys.argv[3]; ip=sys.argv[4]
s=src.read_text(encoding="utf-8",errors="ignore")
s=re.sub(r'(?ms)\n?\s*# OLDZ V9 BEGIN.*?# OLDZ V9 END\s*\n?','\n',s)
s=re.sub(r'(?ms)\n?\s*# HYPER-HOST FASTDL IP FINAL v10 BEGIN.*?# HYPER-HOST FASTDL IP FINAL v10 END\s*\n?','\n',s)
def fix(m):
    toks=[t for t in m.group(2).split() if t!=ip]
    if not toks: toks=[domain,"www."+domain]
    return m.group(1)+" ".join(toks)+";"
s=re.sub(r'(?m)^(\s*server_name\s+)([^;]+);',fix,s)
if domain not in s: raise SystemExit("domain missing after cleanup")
if not re.search(r'(?m)^\s*root\s+[^;]+;',s): raise SystemExit("site root missing")
tmp=dst.with_name("."+dst.name+".v18.tmp")
tmp.write_text(s,encoding="utf-8"); tmp.replace(dst)
print("restored:",dst)
PY

echo "[4/8] Ensure FastDL IP vhost still exists..."
FASTDL_CONF=""
for f in /etc/nginx/hyper-host-managed/00-hyper-cs16-fastdl-ip80.conf /etc/nginx/hyper-host-managed/00-cs16-fastdl-ip80.conf /etc/nginx/conf.d/00-hyper-cs16-fastdl-ip80.conf; do
  if [[ -f "$f" ]] && grep -q "$PUBLIC_IP" "$f"; then FASTDL_CONF="$f"; break; fi
done
[[ -n "$FASTDL_CONF" ]] || fail "FastDL IP vhost not found"
echo "FastDL kept: $FASTDL_CONF"

echo "[5/8] Validate + reload nginx..."
nginx -t
systemctl reload nginx
sleep 1
nginx -T >"$BACKUP/nginx-T-after.txt" 2>&1

echo "[6/8] Check separation..."
python3 - "$BACKUP/nginx-T-after.txt" "$DOMAIN" "$PUBLIC_IP" <<'PY'
from pathlib import Path
import re,sys
txt=Path(sys.argv[1]).read_text(encoding="utf-8",errors="ignore"); domain=sys.argv[2]; ip=sys.argv[3]
lines=re.findall(r'(?m)^\s*server_name\s+[^;]+;',txt)
dl=[x.strip() for x in lines if domain in x]; il=[x.strip() for x in lines if ip in x]
print("domain entries:",len(dl)); [print(" DOMAIN:",x) for x in dl]
print("IP entries:",len(il)); [print(" IP:",x) for x in il]
if not dl: raise SystemExit("domain vhost not loaded")
if len(il)!=1: raise SystemExit(f"expected 1 IP vhost, got {len(il)}")
PY

echo "[7/8] Local site checks..."
HTTP="$(curl -sS -o "$BACKUP/http.body" -D "$BACKUP/http.headers" -H "Host: $DOMAIN" -w '%{http_code}' http://127.0.0.1/ || true)"
HTTPS="$(curl -k -sS -o "$BACKUP/https.body" -D "$BACKUP/https.headers" --resolve "$DOMAIN:443:127.0.0.1" -w '%{http_code}' "https://$DOMAIN/" || true)"
echo "HTTP=$HTTP HTTPS=$HTTPS"
head -n 12 "$BACKUP/https.headers" || true

echo "[8/8] Confirm site files untouched + FastDL alive..."
SITE_ROOT="$(grep -m1 -E '^[[:space:]]*root[[:space:]]+' "$TARGET" | sed -E 's/^[[:space:]]*root[[:space:]]+([^;]+);/\1/' | tr -d "\"'")"
echo "site root: $SITE_ROOT"
[[ -d "$SITE_ROOT" ]] || fail "site root missing: $SITE_ROOT"
curl -sS -H "Host: $PUBLIC_IP" -I "http://127.0.0.1/fastdl/25/" | head -n 12 || true

echo "================================================================"
echo "[SUCCESS] OLD-ZOMBIE SITE REPAIR v18"
echo "Site: https://$DOMAIN/"
echo "FastDL: http://$PUBLIC_IP/fastdl/25/"
echo "Site cfg: $TARGET"
echo "Backup: $BACKUP"
echo "No PHP/JS/CSS files changed."
echo "================================================================"
