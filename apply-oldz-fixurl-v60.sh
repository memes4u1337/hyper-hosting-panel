#!/usr/bin/env bash
# =============================================================================
# OLD ZOMBIE / HYPER-HOST  -  v60  FastDL URL fix (models/sounds приходят как HTML)
#
# Симптом: "Missing RIFF/WAVE chunks", "Mod_LoadBrushModel: ...mdl has wrong
# version number (1868833084 should be 30)"  -> 1868833084 = "<!do" = HTML.
#
# Гипотеза: sv_downloadurl = "http://IP/fastdl/25" БЕЗ завершающего "/".
# Клиент склеивает URL как строку и просит /fastdl/25models/..., /fastdl/25sound/...
# Такого пути нет -> панель/nginx отдаёт HTML-страницу, клиент сохраняет её
# под именем .mdl/.wav. (Мои пробы раньше шли по ПРАВИЛЬНОМУ пути - потому
# и были зелёными.) Скрипт сначала показывает доказательства из логов,
# потом чинит со стороны nginx (rewrite на правильный путь) + ставит
# sv_downloadurl со слешем. Рестарт игрового сервера не нужен.
#
#   sudo bash apply-oldz-fixurl-v60.sh [SERVER_ID]
#   sudo bash apply-oldz-fixurl-v60.sh [SERVER_ID] --undo
# =============================================================================
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Запусти через sudo/root'; exit 1; }

SID="${1:-25}"
ACTION="${2:-apply}"
[[ "$SID" =~ ^[0-9]+$ ]] || { echo '[ERROR] SERVER_ID должен быть числом'; exit 1; }

PUBLIC_IP="${PUBLIC_IP:-90.189.208.25}"
LAN_IP="${LAN_IP:-192.168.0.215}"
BASE_DIR="/srv/hyper-cs16"
CSTRIKE="$BASE_DIR/servers/$SID/cstrike"
FASTDL="$BASE_DIR/fastdl/$SID"
CTL="/usr/local/sbin/hyper-cs16-ctl"
INC="/etc/nginx/hyper-cs16-fixurl-v60.inc"
GOOD_URL="http://${PUBLIC_IP}/fastdl/${SID}/"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/old-zombie-fixurl-v60-${SID}-${STAMP}"
REPORT="/root/old-zombie-fixurl-v60-${SID}-${STAMP}.txt"
mkdir -p "$BACKUP"
exec > >(tee -a "$REPORT") 2>&1

echo '============================================================'
echo " OLD ZOMBIE FIXURL v60  (server #$SID, action: $ACTION)"
echo " Backup: $BACKUP"
echo '============================================================'

command -v nginx >/dev/null 2>&1 || { echo '[ERROR] nginx не найден'; exit 3; }
command -v curl  >/dev/null 2>&1 || { apt-get update -qq || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null || true; }

reload_nginx() { systemctl reload nginx 2>/dev/null || nginx -s reload; }
rcon() { "$CTL" rcon "$SID" "$1" 2>/dev/null || true; }

if [[ "$ACTION" == "--undo" || "$ACTION" == "undo" ]]; then
  if [[ -f "$INC" ]]; then
    printf '# v60 disabled %s\n' "$STAMP" > "$INC"
    nginx -t && reload_nginx
    echo '[OK] v60 выключен (include-файл очищен).'
  else
    echo '[INFO] v60 не был установлен.'
  fi
  exit 0
fi

# ---------------------------------------------------------------- 1
echo
echo '[1/5] Диагностика: что реально запрашивают клиенты...'
echo '--- текущий sv_downloadurl ---'
rcon sv_downloadurl
echo '--- где он задан в конфигах/панели ---'
grep -RIn --exclude-dir=_build_backups --exclude='*.log' --exclude='*.bz2' 'sv_downloadurl' \
     "$CSTRIKE" /usr/local/sbin/hyper-cs16-ctl /root/hyper-hosting-panel/cs16-panel 2>/dev/null | head -20 || true
echo '--- последние внешние запросы к /fastdl в логах nginx ---'
LOGS=(/var/log/nginx/*access*.log)
grep -hE '"GET /fastdl' "${LOGS[@]}" 2>/dev/null | grep -v '^127\.0\.0\.1' | tail -n 15 || true
MALFORMED="$(grep -hcE "\"GET /fastdl/${SID}[A-Za-z_]" "${LOGS[@]}" 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)"
echo "  Запросов вида /fastdl/${SID}models/... (без слеша) в логах: ${MALFORMED:-0}"
if [[ "${MALFORMED:-0}" -gt 0 ]]; then
  echo '  [!] Гипотеза ПОДТВЕРЖДЕНА: клиенты просят URL без "/" после номера сервера.'
else
  echo '  [i] Таких запросов в логах нет (или логи ротировались) - чиним всё равно, это безопасно.'
fi

# ---------------------------------------------------------------- 2
echo
echo '[2/5] Пробы ДО исправления...'
P_CODE=''; P_SIZE=0; P_HTML=0; P_MAGIC=''
probe() {
  local tmp out
  tmp="$(mktemp)"
  out="$(curl -sS -o "$tmp" --max-time 30 -H "Host: ${PUBLIC_IP}" \
        -w '%{http_code}|%{size_download}' "http://127.0.0.1$1" 2>/dev/null)" || out='000|0'
  IFS='|' read -r P_CODE P_SIZE <<<"$out"
  P_MAGIC="$(head -c3 "$tmp" 2>/dev/null | od -An -tx1 | tr -d ' \n')" || true
  P_HTML=0
  if grep -qiE '<!doctype|<html|<head|<body' <<<"$(head -c 256 "$tmp" 2>/dev/null | tr -d '\000')"; then P_HTML=1; fi
  rm -f "$tmp"
}

SAMPLE="$(find "$FASTDL/models" "$FASTDL/sound" -type f -name '*.bz2' 2>/dev/null | head -n1 || true)"
[[ -n "$SAMPLE" ]] || SAMPLE="$(find "$FASTDL" -type f -name '*.bz2' ! -path '*/maps/*' 2>/dev/null | head -n1 || true)"
if [[ -z "$SAMPLE" ]]; then
  echo '[ERROR] В FastDL нет .bz2 для не-карт. Сначала: sudo hyper-cs16-ctl fastdl-sync '"$SID"
  exit 6
fi
REL="${SAMPLE#$FASTDL/}"
echo "  образец: $REL"

RESULT_OK=0
check_all() {
  RESULT_OK=0
  probe "/fastdl/${SID}/${REL}"
  if [[ "$P_CODE" == "200" && "$P_HTML" == "0" && "$P_MAGIC" == "425a68" ]]; then
    echo "  [OK ] правильный путь   /fastdl/${SID}/${REL} -> 200 bz2"
  else
    RESULT_OK=$((RESULT_OK+1)); echo "  [BAD] правильный путь -> code=$P_CODE html=$P_HTML magic=$P_MAGIC"
  fi
  probe "/fastdl/${SID}${REL}"
  if [[ "$P_CODE" == "200" && "$P_HTML" == "0" && "$P_MAGIC" == "425a68" ]]; then
    echo "  [OK ] путь БЕЗ слеша    /fastdl/${SID}${REL} -> 200 bz2"
  else
    RESULT_OK=$((RESULT_OK+1)); echo "  [BAD] путь БЕЗ слеша (как шлёт клиент) -> code=$P_CODE html=$P_HTML magic=$P_MAGIC"
  fi
  probe "/fastdl/${SID}models/__v60_missing__.mdl.bz2"
  if [[ "$P_CODE" == "404" ]]; then echo "  [OK ] отсутствующий файл -> 404"
  else RESULT_OK=$((RESULT_OK+1)); echo "  [BAD] отсутствующий файл -> code=$P_CODE html=$P_HTML (должен быть 404, не HTML)"; fi
}
check_all
BEFORE_BAD=$RESULT_OK

# ---------------------------------------------------------------- 3
echo
echo '[3/5] nginx: приводим URL к правильному виду...'
nginx -t >/dev/null 2>&1 || { echo '[ERROR] nginx -t падает ДО патча:'; nginx -t; exit 3; }

GUARD=1
if nginx -T 2>/dev/null | grep -q 'hyper-cs16-fastdl-v58'; then GUARD=0; fi

mkdir -p "$BACKUP/nginx-orig"
: > "$BACKUP/nginx-modified.list"
: > "$BACKUP/nginx-created.list"

python3 - "$SID" "$PUBLIC_IP" "$LAN_IP" "$BACKUP" "$BASE_DIR" "$GUARD" <<'PY'
import re, subprocess, sys, shutil
from pathlib import Path

sid, pub, lan, backup, base, guard = sys.argv[1:7]
INC = Path('/etc/nginx/hyper-cs16-fixurl-v60.inc')
DED = Path('/etc/nginx/conf.d/00-hyper-cs16-fixurl-v60.conf')
MARK = 'hyper-cs16-fixurl-v60'
mod_list = Path(backup) / 'nginx-modified.list'
new_list = Path(backup) / 'nginx-created.list'

GUARD_TEXT = f'''location ^~ /fastdl/ {{
    root {base};
    autoindex off;
    types {{ }}
    default_type application/octet-stream;
    error_page 404 @hyper_fastdl_404;
    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    add_header X-Hyper-FastDL "v60" always;
}}
location @hyper_fastdl_404 {{
    default_type text/plain;
    return 404 "not found";
}}
''' if guard == '1' else ''
INC_TEXT = f'''# HYPER-HOST OLD ZOMBIE: FastDL URL fix v60 (managed file)
# sv_downloadurl без завершающего "/" даёт запросы вида /fastdl/{sid}models/...
# Здесь они приводятся к /fastdl/{sid}/models/...
rewrite ^/fastdl/{sid}([A-Za-z_].*)$ /fastdl/{sid}/$1 last;
{GUARD_TEXT}'''

def parse(text):
    root = {'children': [], 'open': -1}
    stack = [root]; cur = root
    buf = []; i = 0; n = len(text)
    while i < n:
        c = text[i]
        if c == '#':
            while i < n and text[i] != '\n': i += 1
            continue
        if c in '"\'':
            q = c; j = i + 1
            while j < n and text[j] != q:
                if text[j] == '\\': j += 1
                j += 1
            buf.append(text[i:j+1]); i = j + 1; continue
        if c == '{' and i > 0 and text[i-1] == '$':      # ${var}
            j = text.find('}', i)
            j = n - 1 if j < 0 else j
            buf.append(text[i:j+1]); i = j + 1; continue
        if c in ' \t\r\n':
            if buf and buf[-1] != ' ': buf.append(' ')
            i += 1; continue
        if c == ';':
            cur['children'].append({'stmt': ''.join(buf).strip(), 'block': None})
            buf = []; i += 1; continue
        if c == '{':
            head = ''.join(buf).strip()
            blk = {'children': [], 'open': i}
            cur['children'].append({'stmt': head, 'block': blk})
            stack.append(blk); cur = blk; buf = []; i += 1; continue
        if c == '}':
            if len(stack) > 1:
                stack.pop(); cur = stack[-1]
            buf = []; i += 1; continue
        buf.append(c); i += 1
    return root

def walk(blk, out):
    for ch in blk['children']:
        b = ch['block']
        if b is not None:
            if ch['stmt'] == 'server': out.append(b)
            walk(b, out)

r = subprocess.run(['nginx', '-T'], capture_output=True, text=True)
dump = r.stdout
paths = []
for line in dump.splitlines():
    m = re.match(r'^# configuration file (.+?):\s*$', line)
    if m and m.group(1) not in paths: paths.append(m.group(1))

servers = []; installed = False
for p in paths:
    fp = Path(p)
    if not fp.is_file(): continue
    text = fp.read_text(errors='replace')
    if MARK in text and fp != INC and fp != DED:
        installed = True
    found = []
    walk(parse(text), found)
    for b in found:
        listens, names, rets = [], [], []
        has_if = has_rw = False
        for ch in b['children']:
            s = ch['stmt']; w = s.split()
            if ch['block'] is None:
                if not w: continue
                if w[0] == 'listen' and len(w) > 1: listens.append(w[1:])
                elif w[0] == 'server_name': names += w[1:]
                elif w[0] == 'return': rets.append(s)
                elif w[0] == 'rewrite': has_rw = True
            elif s.startswith('if'):
                has_if = True
        l80 = any((l[0] == '80' or l[0].endswith(':80')) and 'ssl' not in l for l in listens)
        dflt = any(('default_server' in l) and (l[0] == '80' or l[0].endswith(':80')) for l in listens)
        servers.append(dict(path=fp, text=text, open=b['open'], names=names, l80=l80,
                            default=dflt, rets=rets, has_if=has_if, has_rw=has_rw))

def save_orig(fp):
    dst = Path(backup) / 'nginx-orig' / str(fp).lstrip('/')
    dst.parent.mkdir(parents=True, exist_ok=True)
    if fp.exists() and not dst.exists():
        shutil.copy2(fp, dst)

INC.write_text(INC_TEXT)
new_list.write_text(new_list.read_text() + str(INC) + '\n')
print(f'  [OK] записан {INC}')

if installed or DED.exists():
    print('  [INFO] патч v60 уже встроен в nginx - обновлён только include-файл')
    sys.exit(0)

cands = [s for s in servers if s['l80']]
ips = {pub, lan}
exact = [s for s in cands if ips & set(s['names'])]
chosen = exact[0] if exact else next((s for s in cands if s['default']), None)
if chosen is None and cands: chosen = cands[0]

if chosen is None:
    mode = 'dedicated'; root_stmt = 'return 404;'
    print('  [INFO] server-блок на порту 80 не найден - создаю отдельный')
else:
    print(f"  [INFO] порт 80 / Host={pub} обслуживает: {chosen['path']}  server_name={' '.join(chosen['names']) or '_'}")
    if chosen['rets'] or chosen['has_rw'] or chosen['has_if']:
        mode = 'dedicated'
        root_stmt = ' '.join(r + ';' for r in chosen['rets']) or 'return 404;'
        print('  [INFO] в блоке есть server-level return/rewrite/if (срабатывают раньше location) -> отдельный блок')
    else:
        mode = 'inject'

if mode == 'inject':
    fp = chosen['path']; text = chosen['text']
    save_orig(fp)
    ins = f"\n    include {INC}; # {MARK}\n"
    pos = chosen['open'] + 1
    fp.write_text(text[:pos] + ins + text[pos:])
    mod_list.write_text(mod_list.read_text() + str(fp) + '\n')
    print(f'  [OK] include вставлен в {fp}')
else:
    DED.parent.mkdir(parents=True, exist_ok=True)
    DED.write_text(f'''# HYPER-HOST OLD ZOMBIE FIXURL v60 (managed file)
server {{
    listen 80;
    server_name {pub} {lan};
    server_tokens off;
    include {INC}; # {MARK}
    location / {{
        {root_stmt}
    }}
}}
''')
    new_list.write_text(new_list.read_text() + str(DED) + '\n')
    print(f'  [OK] создан отдельный server-блок {DED}')
PY

rollback_nginx() {
  echo '  [ROLLBACK] возвращаю nginx как было...'
  while IFS= read -r f; do
    [[ -n "$f" && -f "$BACKUP/nginx-orig$f" ]] && cp -a "$BACKUP/nginx-orig$f" "$f"
  done < "$BACKUP/nginx-modified.list"
  while IFS= read -r f; do
    [[ -n "$f" ]] && rm -f "$f"
  done < "$BACKUP/nginx-created.list"
}

if nginx -t >/tmp/v60-nginx-test.log 2>&1; then
  reload_nginx
  echo '  [OK] nginx -t прошёл, nginx перезагружен'
else
  echo '  [ERROR] nginx -t после патча упал:'
  cat /tmp/v60-nginx-test.log
  rollback_nginx
  nginx -t >/dev/null 2>&1 && reload_nginx || true
  echo '  Конфиг возвращён как был. Пришли вывод выше - подгоню под твой nginx.'
  exit 4
fi
sleep 1

# ---------------------------------------------------------------- 4
echo
echo '[4/5] sv_downloadurl со слешем...'
# постоянные определения в *.cfg сервера: дописываем "/" в конец URL
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  Q='^([[:space:]]*sv_downloadurl[[:space:]]+")([^"]*[^/"])(".*)$'
  U='^([[:space:]]*sv_downloadurl[[:space:]]+)([^" ]*[^/" ])([[:space:]]+//.*|[[:space:]]*)$'
  if grep -qE "$Q" "$f" || grep -qE "$U" "$f"; then
    mkdir -p "$BACKUP/cfg$(dirname "$f")"; cp -a "$f" "$BACKUP/cfg$f"
    sed -Ei "s#$Q#\\1\\2/\\3#; s#$U#\\1\\2/\\3#" "$f"
    echo "  [CFG] слеш добавлен: $f"
  fi
done < <(grep -RIl --include='*.cfg' 'sv_downloadurl' "$CSTRIKE" 2>/dev/null || true)
if [[ -x "$CTL" || -f "$CTL" ]]; then
  rcon "sv_downloadurl \"$GOOD_URL\""
  echo '  после установки:'; rcon sv_downloadurl
fi

# ---------------------------------------------------------------- 5
echo
echo '[5/5] Пробы ПОСЛЕ исправления...'
check_all
AFTER_BAD=$RESULT_OK

echo
echo '============================================================'
if [[ $AFTER_BAD -eq 0 ]]; then
  echo ' [DONE] FastDL отдаёт файлы и по правильному пути, и без слеша; пропавшие -> 404.'
else
  echo " [ВНИМАНИЕ] После патча плохих проб: $AFTER_BAD. Пришли весь вывод."
fi
echo " Было плохих проб: $BEFORE_BAD"
echo
echo ' ВАЖНО: у игроков, которые уже получили HTML вместо моделей/звуков, эти'
echo ' битые файлы лежат на диске. Им нужен OLDZ-FIX-FILES.bat (удаляет только'
echo ' файлы, внутри которых HTML), потом зайти заново.'
echo " Выключить патч: sudo bash apply-oldz-fixurl-v60.sh $SID --undo"
echo " Отчёт: $REPORT"
echo '============================================================'
[[ $AFTER_BAD -eq 0 ]] || exit 5
exit 0
