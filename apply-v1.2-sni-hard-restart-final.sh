#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-/root/hyper-hosting-panel}"
EMAIL="${2:-}"
BASE=/opt/hyper-host
BACKUP="$BASE/backups/v1.2-sni-hard-restart-$(date +%Y%m%d-%H%M%S)"

say(){ printf '\033[1;36m[HYPER-HOST]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[HYPER-HOST WARNING]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[1;31m[HYPER-HOST ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ [[ -f "$1" ]] || fail "Не найден файл: $1"; }
install_if_different(){
  local mode="$1" src="$2" dst="$3"
  need "$src"
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" ]] && [[ "$(readlink -f "$src")" == "$(readlink -f "$dst")" ]]; then
    chmod "$mode" "$dst" 2>/dev/null || true
    return 0
  fi
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
    return 0
  fi
  install -m "$mode" "$src" "$dst"
}
backup_one(){
  local src="$1" rel="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$BACKUP/$(dirname "$rel")"
  cp -a "$src" "$BACKUP/$rel"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти патч через sudo"
for f in scripts/hhctl scripts/hyper scripts/ssl_truth.py scripts/nginx_recover_v89.py scripts/nginx-reconcile-v89.sh; do
  need "$ROOT_DIR/$f"
done
bash -n "$ROOT_DIR/scripts/hhctl" "$ROOT_DIR/scripts/hyper" "$ROOT_DIR/scripts/nginx-reconcile-v89.sh"
python3 -m py_compile "$ROOT_DIR/scripts/ssl_truth.py" "$ROOT_DIR/scripts/nginx_recover_v89.py"

say "Создаю резервную копию: $BACKUP"
mkdir -p "$BACKUP"
backup_one /usr/local/sbin/hyper-host-ctl usr/local/sbin/hyper-host-ctl
backup_one /usr/local/bin/hyper usr/local/bin/hyper
backup_one "$BASE/ssl-truth.py" opt/hyper-host/ssl-truth.py
backup_one "$BASE/nginx_recover_v89.py" opt/hyper-host/nginx_recover_v89.py
backup_one /usr/local/sbin/hyper-host-nginx-reconcile usr/local/sbin/hyper-host-nginx-reconcile
backup_one /etc/nginx/hyper-host-managed etc/nginx/hyper-host-managed
backup_one /etc/nginx/nginx.conf etc/nginx/nginx.conf

say "Устанавливаю детерминированную SNI-привязку и жёсткий перезапуск Nginx."
install_if_different 0755 "$ROOT_DIR/scripts/hhctl" /usr/local/sbin/hyper-host-ctl
install_if_different 0755 "$ROOT_DIR/scripts/hyper" /usr/local/bin/hyper
install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$BASE/ssl-truth.py"
install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$BASE/nginx_recover_v89.py"
install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" /usr/local/sbin/hyper-host-nginx-reconcile
ln -sfn /usr/local/sbin/hyper-host-ctl /usr/bin/hyper-host-ctl
ln -sfn /usr/local/bin/hyper /usr/bin/hyper

if [[ -d "$PROJECT_DIR" && "$(readlink -f "$PROJECT_DIR")" != "$(readlink -f "$ROOT_DIR")" ]]; then
  install_if_different 0755 "$ROOT_DIR/scripts/hhctl" "$PROJECT_DIR/scripts/hhctl"
  install_if_different 0755 "$ROOT_DIR/scripts/hyper" "$PROJECT_DIR/scripts/hyper"
  install_if_different 0755 "$ROOT_DIR/scripts/ssl_truth.py" "$PROJECT_DIR/scripts/ssl_truth.py"
  install_if_different 0755 "$ROOT_DIR/scripts/nginx_recover_v89.py" "$PROJECT_DIR/scripts/nginx_recover_v89.py"
  install_if_different 0755 "$ROOT_DIR/scripts/nginx-reconcile-v89.sh" "$PROJECT_DIR/scripts/nginx-reconcile-v89.sh"
fi

# Old truth builds wrote extra vhosts into sites-enabled, while nginx.conf now
# includes only hyper-host-managed. Remove only HYPER-HOST-generated legacy
# links so they cannot become a second TLS source after future config changes.
rm -f /etc/nginx/sites-enabled/hyper-host-site-*.conf \
      /etc/nginx/sites-enabled/00-hyper-host-panel.conf \
      /etc/nginx/sites-enabled/hyper-host-panel.conf 2>/dev/null || true

# Disable test folders left by old patches; real sites are untouched.
for d in /var/www/hyper-host-sites/v59-nginx-test-*.local /var/www/hyper-host-sites/v60-acme-test-*.local; do
  [[ -d "$d" ]] || continue
  touch "$d/.hyper-host-disabled"
done

say "Пересобираю HTTPS-vhost: каждый основной домен получает свой сертификат."
/usr/local/sbin/hyper-host-nginx-reconcile
nginx -t

say "Проверяю, что в активном конфиге есть отдельный HTTPS-блок для каждого сертификата."
python3 - <<'PYCONF'
from __future__ import annotations
import re, sqlite3, subprocess
from pathlib import Path

PANEL='panel.hyper-host.pw'
for cfg in ('/var/www/hyper-host/app/config.php','/opt/hyper-host/app/config.php'):
    p=Path(cfg)
    if p.exists():
        m=re.search(r"['\"]panel_domain['\"]\s*=>\s*['\"]([^'\"]+)",p.read_text('utf-8',errors='ignore'))
        if m and m.group(1) not in ('','_'): PANEL=m.group(1).strip().lower().rstrip('.')

def public(d:str)->bool:
    return bool(re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}',d)) and not d.endswith(('.local','.invalid','.test','.example'))

def blocks(text:str):
    out=[]; pos=0
    while True:
        m=re.search(r'\bserver\s*\{',text[pos:])
        if not m: break
        start=pos+m.start(); i=pos+m.end()-1; depth=0
        while i<len(text):
            if text[i]=='{': depth+=1
            elif text[i]=='}':
                depth-=1
                if depth==0:
                    out.append(text[start:i+1]); pos=i+1; break
            i+=1
        else: break
    return out

domains=[]
db=Path('/opt/hyper-host/data/hyperhost.sqlite')
if db.exists():
    try:
        con=sqlite3.connect(f'file:{db}?mode=ro',uri=True,timeout=1)
        for row in con.execute('SELECT domain FROM sites'):
            d=str(row[0] or '').strip().lower().rstrip('.')
            if d!=PANEL and public(d): domains.append(d)
        con.close()
    except Exception: pass
for p in Path('/var/www/hyper-host-sites').glob('*'):
    d=p.name.lower().rstrip('.')
    if p.is_dir() and (p/'public_html').is_dir() and d!=PANEL and public(d) and not (p/'.hyper-host-disabled').exists(): domains.append(d)
domains=sorted(set(domains))
text=subprocess.check_output(['nginx','-T'],text=True,stderr=subprocess.STDOUT)
server_blocks=blocks(text)
missing=[]
for domain in domains:
    cert=Path('/opt/hyper-host/letsencrypt/live')/domain/'fullchain.pem'
    if not cert.exists():
        continue
    valid=[]
    for b in server_blocks:
        if not re.search(r'listen\s+[^;]*443[^;]*ssl',b): continue
        names=[]
        for m in re.finditer(r'\bserver_name\s+([^;]+);',b): names += m.group(1).split()
        if domain in names:
            valid.append(b)
    if not valid or not any(str(cert) in b for b in valid):
        missing.append(f'{domain}: expected {cert}')
if missing:
    print('\n'.join(missing))
    raise SystemExit(1)
print(f'config_sni_ok={len(domains)} domains')
PYCONF

if [[ -n "$EMAIL" ]]; then
  say "Выпускаю отсутствующий сертификат панели и переподключаю существующие сертификаты."
  set +e
  REPAIR_JSON="$(SERVER_IP=192.168.0.179 PUBLIC_IP=90.189.208.25 python3 "$BASE/ssl-truth.py" repair-all --email "$EMAIL")"
  RC=$?
  set -e
  printf '%s\n' "$REPAIR_JSON" > "$BASE/ssl-last-repair.json"
  printf '%s\n' "$REPAIR_JSON" | python3 -m json.tool || printf '%s\n' "$REPAIR_JSON"
  [[ $RC -eq 0 ]] || fail "SSL repair-all завершился ошибкой. Смотри $BASE/ssl-last-repair.json"
else
  warn "Email не передан: исправлена SNI-привязка существующих сертификатов, но SSL панели не выпускался."
fi

# One last hard restart after Certbot and final reconcile.
/usr/local/sbin/hyper-host-ctl nginx-hard-restart

say "Финально проверяю сертификаты через реальный SNI на 127.0.0.1:443."
AUDIT_JSON="$(SERVER_IP=192.168.0.179 PUBLIC_IP=90.189.208.25 python3 "$BASE/ssl-truth.py" audit)"
printf '%s\n' "$AUDIT_JSON" > "$BASE/ssl-last-audit.json"
printf '%s\n' "$AUDIT_JSON" | python3 -m json.tool
OK="$(printf '%s' "$AUDIT_JSON" | python3 -c 'import json,sys; print(1 if json.load(sys.stdin).get("ok") else 0)' 2>/dev/null || echo 0)"
if [[ "$OK" != 1 ]]; then
  say "Активные процессы и слушатель 443:"
  ps -ef | grep '[n]ginx' >&2 || true
  ss -ltnp 'sport = :443' >&2 || true
  fail "Не все основные домены отдают свой сертификат. Диагностика: $BASE/ssl-last-audit.json"
fi

cat <<EOFOUT

============================================================
 HYPER-HOST v1.2 — SNI/SSL ИСПРАВЛЕН
============================================================
 Каждый домен: отдельный HTTPS-vhost и точный Certbot lineage
 Nginx: старые master/worker остановлены, запущен один systemd instance
 SNI: проверено через реальное соединение 127.0.0.1:443
 Backup: $BACKUP

 Проверка: sudo hyper ssl repair-all ${EMAIL:-EMAIL}
 Аудит:    cat $BASE/ssl-last-audit.json | python3 -m json.tool
 Restart:  sudo hyper nginx hard-restart
============================================================
EOFOUT
