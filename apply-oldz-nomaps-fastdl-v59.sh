#!/usr/bin/env bash
# =============================================================================
# OLD ZOMBIE / HYPER-HOST  -  v59  "карты НЕ через FastDL"
#
# Карты (.bsp / .bsp.bz2) больше не отдаются по HTTP: nginx отвечает на них
# честным 404, и клиент докачивает карту напрямую с игрового сервера (UDP).
# Остальные файлы (модели, звуки, спрайты) по-прежнему идут через FastDL.
# Работает независимо от fastdl-sync (он ничего не "вернёт"), перезапуск
# игрового сервера не нужен.
#
#   sudo bash apply-oldz-nomaps-fastdl-v59.sh [SERVER_ID]     # включить
#   sudo bash apply-oldz-nomaps-fastdl-v59.sh [SERVER_ID] --undo   # выключить
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
MAPS="$CSTRIKE/maps"
FASTDL="$BASE_DIR/fastdl/$SID"
CTL="/usr/local/sbin/hyper-cs16-ctl"
INC="/etc/nginx/hyper-cs16-nomaps-v59.inc"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/old-zombie-nomaps-v59-${SID}-${STAMP}"
REPORT="/root/old-zombie-nomaps-v59-${SID}-${STAMP}.txt"
mkdir -p "$BACKUP"
exec > >(tee -a "$REPORT") 2>&1

echo '============================================================'
echo " OLD ZOMBIE NOMAPS v59  (server #$SID, action: $ACTION)"
echo " Backup: $BACKUP"
echo '============================================================'

command -v nginx >/dev/null 2>&1 || { echo '[ERROR] nginx не найден'; exit 3; }
command -v curl  >/dev/null 2>&1 || { apt-get update -qq || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null || true; }

reload_nginx() { systemctl reload nginx 2>/dev/null || nginx -s reload; }

# ---------------------------------------------------------------- undo
if [[ "$ACTION" == "--undo" || "$ACTION" == "undo" ]]; then
  if [[ -f "$INC" ]]; then
    printf '# v59 disabled %s\n' "$STAMP" > "$INC"
    nginx -t && reload_nginx
    echo '[OK] v59 выключен: карты снова отдаются через FastDL как раньше.'
  else
    echo '[INFO] v59 не был установлен - откатывать нечего.'
  fi
  exit 0
fi

bsp_ver() { od -An -tu4 -N4 "$1" 2>/dev/null | tr -d ' \n' || true; }

# ---------------------------------------------------------------- 1
echo
echo '[1/4] Проверка карт на самом сервере (BSP version = 30)...'
BAD=0
shopt -s nullglob
for m in "$MAPS"/*.bsp; do
  v="$(bsp_ver "$m")"
  if [[ "$v" != "30" ]]; then
    BAD=$((BAD+1))
    echo "  [ERROR] $(basename "$m"): версия '$v' - файл на СЕРВЕРЕ битый (HTML?)"
  fi
done
shopt -u nullglob
if [[ $BAD -eq 0 ]]; then
  echo '  [OK] все карты сервера - валидные BSP v30'
else
  echo "  [!] Битых карт на сервере: $BAD. Их надо перезалить из оригинала -"
  echo '      иначе даже прямая загрузка отдаст клиенту мусор. Патч продолжу.'
fi

# ---------------------------------------------------------------- 2
echo
echo '[2/4] nginx: карты -> 404 (клиент докачает их с игрового сервера)...'
nginx -t >/dev/null 2>&1 || { echo '[ERROR] nginx -t падает ДО патча:'; nginx -t; exit 3; }

mkdir -p "$BACKUP/nginx-orig"
: > "$BACKUP/nginx-modified.list"
: > "$BACKUP/nginx-created.list"

python3 - "$SID" "$PUBLIC_IP" "$LAN_IP" "$BACKUP" "$BASE_DIR" <<'PY'
import re, subprocess, sys, shutil
from pathlib import Path

sid, pub, lan, backup, base = sys.argv[1:6]
INC = Path('/etc/nginx/hyper-cs16-nomaps-v59.inc')
DED = Path('/etc/nginx/conf.d/00-hyper-cs16-nomaps-v59.conf')
MARK = 'hyper-cs16-nomaps-v59'
mod_list = Path(backup) / 'nginx-modified.list'
new_list = Path(backup) / 'nginx-created.list'

INC_TEXT = f'''# HYPER-HOST OLD ZOMBIE: карты НЕ через FastDL, v59 (managed file)
location ^~ /fastdl/{sid}/maps/ {{
    access_log /var/log/nginx/hyper-cs16-maps-block.log;
    default_type text/plain;
    return 404 "maps are served by the game server";
}}
location ~* \\.bsp(\\.bz2)?$ {{
    access_log /var/log/nginx/hyper-cs16-maps-block.log;
    default_type text/plain;
    return 404 "maps are served by the game server";
}}
'''

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
    print('  [INFO] патч v59 уже встроен в nginx - обновлён только include-файл')
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
    DED.write_text(f'''# HYPER-HOST OLD ZOMBIE NOMAPS v59 (managed file)
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

if nginx -t >/tmp/v59-nginx-test.log 2>&1; then
  reload_nginx
  echo '  [OK] nginx -t прошёл, nginx перезагружен'
else
  echo '  [ERROR] nginx -t после патча упал:'
  cat /tmp/v59-nginx-test.log
  rollback_nginx
  nginx -t >/dev/null 2>&1 && reload_nginx || true
  echo '  Конфиг возвращён как был. Пришли вывод выше - подгоню под твой nginx.'
  exit 4
fi
sleep 1

# ---------------------------------------------------------------- 3
echo
echo '[3/4] Проверка по HTTP (Host = внешний IP)...'
P_CODE=''; P_CT=''; P_SIZE=0
probe() {
  local tmp out
  tmp="$(mktemp)"
  out="$(curl -sS -o "$tmp" --max-time 20 -H "Host: ${PUBLIC_IP}" \
        -w '%{http_code}|%{content_type}|%{size_download}' "http://127.0.0.1$1" 2>/dev/null)" || out='000||0'
  IFS='|' read -r P_CODE P_CT P_SIZE <<<"$out"
  rm -f "$tmp"
}
FAIL=0
for p in "/fastdl/$SID/maps/zm_zombust.bsp.bz2" "/fastdl/$SID/maps/zm_zombust.bsp" "/maps/zm_zombust.bsp"; do
  probe "$p"
  if [[ "$P_CODE" == "404" ]]; then echo "  [OK ] 404  $p"; else FAIL=$((FAIL+1)); echo "  [BAD] code=$P_CODE  $p (ожидался 404)"; fi
done
OTHER="$(find "$FASTDL" -type f -name '*.mdl.bz2' 2>/dev/null | head -n1 || true)"
if [[ -n "$OTHER" ]]; then
  REL="${OTHER#$FASTDL/}"
  probe "/fastdl/$SID/$REL"
  if [[ "$P_CODE" == "200" ]]; then echo "  [OK ] 200  /fastdl/$SID/$REL (остальной FastDL работает)"
  else FAIL=$((FAIL+1)); echo "  [BAD] code=$P_CODE  /fastdl/$SID/$REL (не-карты должны отдаваться)"; fi
fi

# ---------------------------------------------------------------- 4
echo
echo '[4/4] Параметры скачивания на сервере...'
if [[ -x "$CTL" || -f "$CTL" ]]; then
  for cv in sv_downloadurl sv_allowdownload sv_allow_dlfile; do
    "$CTL" rcon "$SID" "$cv" 2>/dev/null || true
  done
  echo '  Для прямой загрузки карт нужно: sv_allowdownload = 1'
fi

echo
echo '============================================================'
if [[ $FAIL -eq 0 ]]; then
  echo ' [DONE] Карты теперь качаются НЕ с FastDL, а с игрового сервера.'
else
  echo " [ВНИМАНИЕ] Не прошло проверок: $FAIL. Пришли весь вывод."
fi
echo ' Зайди чистым клиентом на карту и проверь.'
echo ' Что запрашивают клиенты (если снова ошибка - пришли это мне):'
echo '   sudo tail -n 30 /var/log/nginx/hyper-cs16-maps-block.log'
echo ' Выключить патч:'
echo "   sudo bash apply-oldz-nomaps-fastdl-v59.sh $SID --undo"
echo " Отчёт: $REPORT"
echo '============================================================'
[[ $FAIL -eq 0 ]] || exit 5
exit 0
