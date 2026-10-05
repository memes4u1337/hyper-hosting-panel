#!/usr/bin/env bash
# =============================================================================
# OLD ZOMBIE / HYPER-HOST  -  v61  FastDL: отдельный nginx-блок + проверка файлов
#
# По логам nginx: клиенты просят ПРАВИЛЬНЫЕ пути (/fastdl/25/sprites/fire2.spr),
# а nginx на ВСЕ такие запросы отвечает "200, 319 байт" - фиксированная HTML-
# страница. Т.е. /fastdl/ в nginx сейчас никто не обслуживает (панель, судя по
# всему, перегенерировала свой 00-default.conf и стёрла вставки v58/v59).
#
# Что делает v61:
#   1. Диагностика (только чтение): каталог FastDL, что отдаёт nginx, конфиг.
#   2. Если в FastDL мало файлов - штатный hyper-cs16-ctl fastdl-sync.
#   3. Ставит ОТДЕЛЬНЫЙ server-блок (Host = внешний/LAN IP) в каталог, который
#      панель не генерирует: раздаёт /fastdl/, отсутствующие файлы -> 404.
#   4. Пробы по HTTP (размер ответа = размер файла на диске, не HTML).
#   5. sv_downloadurl со слешем. Рестарт игрового сервера не нужен.
#
#   sudo bash apply-oldz-fastdl-v61.sh [SERVER_ID]
#   sudo bash apply-oldz-fastdl-v61.sh [SERVER_ID] --undo
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
GOOD_URL="http://${PUBLIC_IP}/fastdl/${SID}/"
FNAME="00-hyper-cs16-fastdl-v61.conf"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/old-zombie-fastdl-v61-${SID}-${STAMP}"
REPORT="/root/old-zombie-fastdl-v61-${SID}-${STAMP}.txt"
mkdir -p "$BACKUP"
exec > >(tee -a "$REPORT") 2>&1

echo '============================================================'
echo " OLD ZOMBIE FASTDL v61  (server #$SID, action: $ACTION)"
echo " Backup: $BACKUP"
echo '============================================================'

command -v nginx >/dev/null 2>&1 || { echo '[ERROR] nginx не найден'; exit 3; }
command -v curl  >/dev/null 2>&1 || { apt-get update -qq || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null || true; }

reload_nginx() { systemctl reload nginx 2>/dev/null || nginx -s reload; }
rcon() { "$CTL" rcon "$SID" "$1" 2>/dev/null || true; }
count() { tr -d ' \n' <<<"$(wc -l)"; }

if [[ "$ACTION" == "--undo" || "$ACTION" == "undo" ]]; then
  FOUND="$(find /etc/nginx /opt/hyper-host/runtime/nginx -name "$FNAME" 2>/dev/null | sort -u || true)"
  if [[ -n "$FOUND" ]]; then
    while IFS= read -r f; do rm -f "$f"; echo "[OK] удалён $f"; done <<<"$FOUND"
    nginx -t && reload_nginx
  else
    echo '[INFO] v61 не был установлен.'
  fi
  exit 0
fi

# ---------------------------------------------------------------- 1
echo
echo '[1/5] Диагностика (только чтение)...'
echo '--- каталог FastDL ---'
ls -ld "$BASE_DIR/fastdl" "$FASTDL" 2>&1 || true
[[ -L "$FASTDL" ]] && echo "  FastDL - это symlink -> $(readlink -f "$FASTDL")"
FILES_ALL="$(find -L "$FASTDL" -type f 2>/dev/null | count)"
FILES_BZ2="$(find -L "$FASTDL" -type f -name '*.bz2' 2>/dev/null | count)"
echo "  файлов в FastDL: $FILES_ALL (из них .bz2: $FILES_BZ2)"
echo '--- fire2.spr (его просил клиент) ---'
find -L "$FASTDL" -name 'fire2.spr*' 2>/dev/null | head -n3 || true
ls -la "$CSTRIKE/sprites/fire2.spr" 2>&1 || true
echo '--- что nginx отдаёт СЕЙЧАС на /fastdl/'"$SID"'/sprites/fire2.spr ---'
{ curl -s -D - -H "Host: ${PUBLIC_IP}" "http://127.0.0.1/fastdl/${SID}/sprites/fire2.spr" | head -c 700; } || true
echo
echo '--- nginx: упоминания fastdl ---'
nginx -T 2>/dev/null | grep -n 'fastdl' | head -20 || true
echo '--- какой server отвечает на порту 80 ---'
nginx -T 2>/dev/null | grep -nE '^\s*(listen\s+.*80|server_name|include\s)' | head -30 || true
if [[ -f /etc/nginx/hyper-host-managed/00-default.conf ]]; then
  echo '--- /etc/nginx/hyper-host-managed/00-default.conf ---'
  sed -n '1,60p' /etc/nginx/hyper-host-managed/00-default.conf
fi

# ---------------------------------------------------------------- 2
echo
echo '[2/5] Содержимое FastDL...'
if [[ "${FILES_ALL:-0}" -lt 50 ]]; then
  echo "  Файлов мало ($FILES_ALL) - запускаю штатную синхронизацию..."
  if [[ -x "$CTL" || -f "$CTL" ]]; then
    "$CTL" fastdl-sync "$SID" || echo '  [WARN] fastdl-sync вернул ошибку'
  else
    echo "  [WARN] нет $CTL"
  fi
  FILES_ALL="$(find -L "$FASTDL" -type f 2>/dev/null | count)"
  FILES_BZ2="$(find -L "$FASTDL" -type f -name '*.bz2' 2>/dev/null | count)"
  echo "  теперь файлов: $FILES_ALL (.bz2: $FILES_BZ2)"
else
  echo "  [OK] файлов достаточно ($FILES_ALL)"
fi
chmod a+x /srv "$BASE_DIR" "$BASE_DIR/fastdl" 2>/dev/null || true
chmod -R a+rX "$FASTDL" 2>/dev/null || true

# ---------------------------------------------------------------- 3
echo
echo '[3/5] nginx: отдельный блок для FastDL (вне каталога панели)...'
nginx -t >/dev/null 2>&1 || { echo '[ERROR] nginx -t падает ДО патча:'; nginx -t; exit 3; }
mkdir -p "$BACKUP/nginx-orig"
: > "$BACKUP/nginx-modified.list"
: > "$BACKUP/nginx-created.list"

python3 - "$SID" "$PUBLIC_IP" "$LAN_IP" "$BACKUP" "$BASE_DIR" <<'PY'
import re, subprocess, sys, os, shutil, fnmatch
from pathlib import Path

sid, pub, lan, backup, base = sys.argv[1:6]
FNAME = '00-hyper-cs16-fastdl-v61.conf'
MANAGED = 'hyper-host-managed'
mod_list = Path(backup) / 'nginx-modified.list'
new_list = Path(backup) / 'nginx-created.list'

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


dump = subprocess.run(['nginx', '-T'], capture_output=True, text=True).stdout
first = re.search(r'^# configuration file (.+?):\s*$', dump, re.M)
main_conf = Path(first.group(1)) if first else Path('/etc/nginx/nginx.conf')
conf_root = main_conf.parent

# какие каталоги подключаются в http { include ...; }
http_inc = []
tree = parse(main_conf.read_text(errors='replace'))
for ch in tree['children']:
    if ch['block'] is not None and ch['stmt'] == 'http':
        for c2 in ch['block']['children']:
            if c2['block'] is None and c2['stmt'].startswith('include '):
                http_inc.append(c2['stmt'].split(None, 1)[1].strip().strip('"\''))

target_dir = None
for pat in http_inc:
    pp = Path(pat)
    if not pp.is_absolute():
        pp = conf_root / pp
    d, b = pp.parent, pp.name
    if MANAGED in str(d): continue
    if d.is_dir() and fnmatch.fnmatch(FNAME, b) and os.access(d, os.W_OK):
        target_dir = d; break

warn = False
if target_dir is None:
    for pat in http_inc:
        pp = Path(pat)
        if not pp.is_absolute():
            pp = conf_root / pp
        if pp.parent.is_dir() and fnmatch.fnmatch(FNAME, pp.name) and os.access(pp.parent, os.W_OK):
            target_dir = pp.parent; warn = True; break
if target_dir is None:
    print('  [ERROR] не нашёл каталог, который nginx подключает в http{} и куда можно писать')
    print('  include в http{}:', http_inc)
    sys.exit(7)

dest = target_dir / FNAME
if dest.exists():
    o = Path(backup) / 'nginx-orig' / str(dest).lstrip('/')
    o.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dest, o)
    mod_list.write_text(mod_list.read_text() + str(dest) + '\n')
else:
    new_list.write_text(new_list.read_text() + str(dest) + '\n')

dest.write_text(f'''# HYPER-HOST OLD ZOMBIE FastDL v61 (отдельный файл, панель его не генерирует)
server {{
    listen 80;
    server_name {pub} {lan};
    server_tokens off;
    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;

    # sv_downloadurl без "/" -> /fastdl/{sid}models/... : приводим к /fastdl/{sid}/models/...
    rewrite ^/fastdl/{sid}([A-Za-z_].*)$ /fastdl/{sid}/$1 last;

    location ^~ /fastdl/ {{
        root {base};
        autoindex off;
        types {{ }}
        default_type application/octet-stream;
        error_page 404 @hyper_fastdl_404;
        add_header X-Hyper-FastDL "v61" always;
    }}
    location @hyper_fastdl_404 {{
        default_type text/plain;
        return 404 "not found";
    }}
    location / {{
        return 404;
    }}
}}
''')
print(f'  [OK] записан {dest}')
if warn:
    print(f'  [WARN] Файл лежит в каталоге панели ({target_dir}) - панель может его стереть!')
    print('         Если FastDL снова сломается - запусти этот скрипт повторно.')

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

if nginx -t >/tmp/v61-nginx-test.log 2>&1; then
  reload_nginx
  echo '  [OK] nginx -t прошёл, nginx перезагружен'
else
  echo '  [ERROR] nginx -t после патча упал:'
  cat /tmp/v61-nginx-test.log
  rollback_nginx
  nginx -t >/dev/null 2>&1 && reload_nginx || true
  echo '  Конфиг возвращён как был. Пришли вывод выше - подгоню под твой nginx.'
  exit 4
fi
sleep 1

# ---------------------------------------------------------------- 4
echo
echo '[4/5] Пробы по HTTP (Host = внешний IP)...'
P_CODE=''; P_SIZE=0; P_HTML=0
probe() {
  local tmp out
  tmp="$(mktemp)"
  out="$(curl -sS -o "$tmp" --max-time 60 -H "Host: ${PUBLIC_IP}" \
        -w '%{http_code}|%{size_download}' "http://127.0.0.1$1" 2>/dev/null)" || out='000|0'
  IFS='|' read -r P_CODE P_SIZE <<<"$out"
  P_HTML=0
  if grep -qiE '<!doctype|<html|<head|<body' <<<"$(head -c 256 "$tmp" 2>/dev/null | tr -d '\000')"; then P_HTML=1; fi
  rm -f "$tmp"
}
FAIL=0
check_file() {   # $1 = путь относительно FastDL
  local rel="$1" want
  [[ -f "$FASTDL/$rel" ]] || return 0
  want="$(stat -L -c %s "$FASTDL/$rel")"
  probe "/fastdl/${SID}/${rel}"
  if [[ "$P_CODE" == "200" && "$P_HTML" == "0" && "$P_SIZE" == "$want" ]]; then
    echo "  [OK ] 200  ${P_SIZE}b  /fastdl/${SID}/${rel}"
  else
    FAIL=$((FAIL+1)); echo "  [BAD] code=$P_CODE size=${P_SIZE}b (на диске ${want}b) html=$P_HTML  /fastdl/${SID}/${rel}"
  fi
}
pick() { find -L "$FASTDL" -type f "$@" 2>/dev/null | head -n1 | sed "s#^$FASTDL/##" || true; }

R_BZ="$(pick -name '*.bz2' ! -path '*/maps/*')"
R_RAW="$(pick ! -name '*.bz2' ! -path '*/maps/*' -size +2k)"
R_MAP="$(pick -path '*/maps/*' -name '*.bsp')"
R_MAPBZ="$(pick -path '*/maps/*' -name '*.bsp.bz2')"
for r in "$R_BZ" "$R_RAW" "$R_MAP" "$R_MAPBZ" "sprites/fire2.spr"; do
  [[ -n "$r" ]] && check_file "$r"
done
if [[ -z "$R_BZ$R_RAW$R_MAP$R_MAPBZ" ]]; then
  FAIL=$((FAIL+1)); echo '  [BAD] в FastDL нет ни одного файла для проверки (fastdl-sync ничего не создал)'
fi
if [[ -n "$R_RAW" ]]; then
  probe "/fastdl/${SID}${R_RAW}"
  if [[ "$P_CODE" == "200" && "$P_HTML" == "0" ]]; then echo "  [OK ] путь без слеша тоже работает"
  else FAIL=$((FAIL+1)); echo "  [BAD] путь без слеша -> code=$P_CODE html=$P_HTML"; fi
fi
probe "/fastdl/${SID}/models/__v61_missing__.mdl"
if [[ "$P_CODE" == "404" ]]; then echo "  [OK ] отсутствующий файл -> 404 (клиент возьмёт его с игрового сервера)"
else FAIL=$((FAIL+1)); echo "  [BAD] отсутствующий файл -> code=$P_CODE html=$P_HTML (должен быть 404)"; fi

# ---------------------------------------------------------------- 5
echo
echo '[5/5] sv_downloadurl со слешем...'
Q='^([[:space:]]*sv_downloadurl[[:space:]]+")([^"]*[^/"])(".*)$'
U='^([[:space:]]*sv_downloadurl[[:space:]]+)([^" ]*[^/" ])([[:space:]]+//.*|[[:space:]]*)$'
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if grep -qE "$Q" "$f" || grep -qE "$U" "$f"; then
    mkdir -p "$BACKUP/cfg$(dirname "$f")"; cp -a "$f" "$BACKUP/cfg$f"
    sed -Ei "s#$Q#\\1\\2/\\3#; s#$U#\\1\\2/\\3#" "$f"
    echo "  [CFG] слеш добавлен: $f"
  fi
done < <(grep -RIl --include='*.cfg' 'sv_downloadurl' "$CSTRIKE" 2>/dev/null || true)
if [[ -x "$CTL" || -f "$CTL" ]]; then
  rcon "sv_downloadurl \"$GOOD_URL\""
  echo '  сейчас на сервере:'; rcon sv_downloadurl
fi

echo
echo '============================================================'
if [[ $FAIL -eq 0 ]]; then
  echo ' [DONE] FastDL отдаёт реальные файлы, отсутствующие -> 404.'
else
  echo " [ВНИМАНИЕ] Не прошло проверок: $FAIL. Пришли весь вывод (особенно раздел [1/5])."
fi
echo ' Если у игроков уже сохранились файлы-HTML: OLDZ-FIX-FILES.bat, затем зайти заново.'
echo ' Что запрашивают клиенты:  sudo tail -n 30 /var/log/nginx/hyper-cs16-fastdl-access.log'
echo " Выключить патч: sudo bash apply-oldz-fastdl-v61.sh $SID --undo"
echo " Отчёт: $REPORT"
echo '============================================================'
[[ $FAIL -eq 0 ]] || exit 5
exit 0
