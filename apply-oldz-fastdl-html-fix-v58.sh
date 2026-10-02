#!/usr/bin/env bash
# =============================================================================
# OLD ZOMBIE / HYPER-HOST  -  v58  FastDL "HTML instead of BSP" fix
#
# Симптом у клиентов:
#   Map [maps/xxx.bsp] has incorrect BSP version (1868833084 should be 30)
# 1868833084 = 0x6F64213C = байты "<!do" -> клиент сохранил как .bsp
# HTML-страницу ("<!doctype html>") вместо карты.
#
# Что делает патч (игровые файлы и конфиги сервера НЕ меняет, рестарт не нужен):
#   1. Проверяет карты сервера и FastDL (версия BSP = 30, валидность .bz2)
#      и выносит "битые" файлы в карантин.
#   2. Пересобирает FastDL штатной командой hyper-cs16-ctl fastdl-sync
#      и добавляет недостающие карты из mapcycle.
#   3. Делает HTTP-пробы FastDL (как это делает клиент: Host = внешний IP).
#   4. Если FastDL отдаёт HTML / редирект / 200 на несуществующий файл -
#      вставляет в nginx защищённый блок  location ^~ /fastdl/  (отдаёт только
#      файлы, любой отсутствующий файл = честный 404, чтобы клиент скачал
#      карту напрямую с игрового сервера). nginx -t, при ошибке - откат.
#   5. Повторные пробы и итоговый вердикт.
#
# Использование:  sudo bash apply-oldz-fastdl-html-fix-v58.sh [SERVER_ID]
# По умолчанию SERVER_ID=25. Внешний IP: PUBLIC_IP=... (по умолчанию 90.189.208.25)
# =============================================================================
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Запусти через sudo/root'; exit 1; }

SID="${1:-25}"
[[ "$SID" =~ ^[0-9]+$ ]] || { echo '[ERROR] SERVER_ID должен быть числом'; exit 1; }

PUBLIC_IP="${PUBLIC_IP:-90.189.208.25}"
LAN_IP="${LAN_IP:-192.168.0.215}"

BASE_DIR="/srv/hyper-cs16"
SERVER="$BASE_DIR/servers/$SID"
CSTRIKE="$SERVER/cstrike"
MAPS="$CSTRIKE/maps"
FASTDL="$BASE_DIR/fastdl/$SID"
CTL="/usr/local/sbin/hyper-cs16-ctl"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/old-zombie-fastdl-fix-v58-${SID}-${STAMP}"
REPORT="/root/old-zombie-fastdl-fix-v58-${SID}-${STAMP}.txt"

mkdir -p "$BACKUP"
exec > >(tee -a "$REPORT") 2>&1

echo '============================================================'
echo ' OLD ZOMBIE FASTDL FIX v58'
echo " Server : #$SID"
echo " Maps   : $MAPS"
echo " FastDL : $FASTDL"
echo " Host   : $PUBLIC_IP"
echo " Backup : $BACKUP"
echo " Report : $REPORT"
echo '============================================================'

[[ -d "$CSTRIKE" ]] || { echo "[ERROR] Нет папки сервера: $CSTRIKE"; exit 2; }

for tool in curl bzip2 od python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[INFO] Устанавливаю недостающий пакет для: $tool"
    apt-get update -qq || true
    case "$tool" in
      od) pkg=coreutils ;;
      *)  pkg="$tool" ;;
    esac
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null || true
  fi
done

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
bsp_ver() {            # версия BSP из первых 4 байт файла
  od -An -tu4 -N4 "$1" 2>/dev/null | tr -d ' \n' || true
}

bsp_ver_bz2() {        # версия BSP внутри .bsp.bz2
  { bzip2 -dc "$1" 2>/dev/null | head -c4 | od -An -tu4 | tr -d ' \n'; } || true
}

bz2_magic_ok() {       # "BZh" = 42 5a 68
  local m
  m="$(head -c3 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" || true
  [[ "$m" == "425a68" ]]
}

looks_html() {         # начало файла похоже на HTML?
  local h
  h="$(head -c 256 "$1" 2>/dev/null | tr -d '\000')" || true
  grep -qiE '<!doctype|<html|<head|<body' <<<"$h"
}

QUARANTINED=0
quarantine() {
  local f="$1" why="$2"
  local dst="$BACKUP/quarantine-fastdl/${f#/}"
  mkdir -p "$(dirname "$dst")"
  mv -f "$f" "$dst"
  QUARANTINED=$((QUARANTINED+1))
  echo "  [QUARANTINE] ${f#$FASTDL/}  ($why)"
}

# ----------------------------------------------------------------------------
# 1. Проверка карт сервера
# ----------------------------------------------------------------------------
echo
echo '[1/6] Проверка карт сервера (BSP version должна быть 30)...'
SERVER_BAD=0
shopt -s nullglob
for m in "$MAPS"/*.bsp; do
  v="$(bsp_ver "$m")"
  if [[ "$v" != "30" ]]; then
    SERVER_BAD=$((SERVER_BAD+1))
    echo "  [ERROR] $(basename "$m"): версия '$v' (ожидалось 30) - файл на самом СЕРВЕРЕ битый!"
  fi
done
shopt -u nullglob
[[ $SERVER_BAD -eq 0 ]] && echo '  [OK] все карты сервера - валидные BSP v30'

# ----------------------------------------------------------------------------
# 2. Чистка и пересборка FastDL
# ----------------------------------------------------------------------------
echo
echo '[2/6] Проверка FastDL и пересборка...'
if [[ -d "$FASTDL" ]]; then
  while IFS= read -r -d '' f; do
    case "$f" in
      *.bz2)
        if ! bz2_magic_ok "$f"; then
          quarantine "$f" 'не bzip2-архив'
          continue
        fi
        if [[ "$f" == */maps/*.bsp.bz2 ]]; then
          v="$(bsp_ver_bz2 "$f")"
          [[ "$v" == "30" ]] || quarantine "$f" "внутри BSP версии '$v'"
        fi
        ;;
      *.bsp)
        v="$(bsp_ver "$f")"
        [[ "$v" == "30" ]] || quarantine "$f" "BSP версии '$v'"
        ;;
      *.html|*.htm|*.php|*.txt|*.cfg|*.res|*.inf|*.ini) ;;
      *)
        if looks_html "$f"; then quarantine "$f" 'внутри HTML'; fi
        ;;
    esac
  done < <(find "$FASTDL" -type f -print0 2>/dev/null)
  echo "  Карантин FastDL: $QUARANTINED файл(ов)"
else
  echo "  [WARN] Папки FastDL нет: $FASTDL (будет создана штатной синхронизацией)"
fi

if [[ -x "$CTL" || -f "$CTL" ]]; then
  echo '  [SYNC] hyper-cs16-ctl fastdl-sync...'
  "$CTL" fastdl-sync "$SID" || echo '  [WARN] fastdl-sync вернул ошибку (идём дальше)'
else
  echo "  [WARN] Нет $CTL - штатную синхронизацию пропускаю"
fi

# Недостающие карты из mapcycle (.bsp и .bsp.bz2)
mkdir -p "$FASTDL/maps"
if [[ -f "$CSTRIKE/mapcycle.txt" ]]; then
  while IFS= read -r line; do
    name="$(sed -E 's/[[:space:]]*(\/\/|;|#).*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$line")"
    [[ -n "$name" ]] || continue
    src="$MAPS/$name.bsp"
    [[ -f "$src" ]] || { echo "  [WARN] mapcycle: нет $name.bsp на сервере"; continue; }
    [[ "$(bsp_ver "$src")" == "30" ]] || continue
    if [[ ! -f "$FASTDL/maps/$name.bsp" ]]; then
      install -m 0644 "$src" "$FASTDL/maps/$name.bsp"
      echo "  [ADD] maps/$name.bsp"
    fi
    if [[ ! -f "$FASTDL/maps/$name.bsp.bz2" ]]; then
      bzip2 -9 -c "$src" > "$FASTDL/maps/$name.bsp.bz2.tmp" && \
        mv -f "$FASTDL/maps/$name.bsp.bz2.tmp" "$FASTDL/maps/$name.bsp.bz2"
      chmod 0644 "$FASTDL/maps/$name.bsp.bz2"
      echo "  [ADD] maps/$name.bsp.bz2"
    fi
  done < "$CSTRIKE/mapcycle.txt"
fi

# nginx должен читать файлы
chmod a+x /srv "$BASE_DIR" "$BASE_DIR/fastdl" 2>/dev/null || true
chmod -R a+rX "$FASTDL" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 3. HTTP-пробы (как клиент: Host = внешний IP)
# ----------------------------------------------------------------------------
P_CODE=''; P_CT=''; P_SIZE=0; P_REDIR=''; P_HTML=0; P_MAGIC=''
probe_url() {
  local path="$1" tmp out
  tmp="$(mktemp)"
  out="$(curl -sS -o "$tmp" --max-time 30 -H "Host: ${PUBLIC_IP}" \
        -w '%{http_code}|%{content_type}|%{size_download}|%{redirect_url}' \
        "http://127.0.0.1${path}" 2>/dev/null)" || out='000|||'
  IFS='|' read -r P_CODE P_CT P_SIZE P_REDIR <<<"$out"
  P_MAGIC="$(head -c3 "$tmp" 2>/dev/null | od -An -tx1 | tr -d ' \n')" || true
  P_HTML=0
  if looks_html "$tmp"; then P_HTML=1; fi
  rm -f "$tmp"
}

PROBE_BAD=0
run_probes() {
  PROBE_BAD=0
  local samples=() p
  if [[ -f "$FASTDL/maps/zm_dust_world.bsp.bz2" ]]; then
    samples+=("/fastdl/$SID/maps/zm_dust_world.bsp.bz2")
  fi
  while IFS= read -r p; do
    [[ -n "$p" ]] && samples+=("/fastdl/$SID/maps/$(basename "$p")")
  done < <(find "$FASTDL/maps" -maxdepth 1 -type f -name '*.bsp.bz2' 2>/dev/null | sort | head -n 3)
  if [[ ${#samples[@]} -eq 0 ]]; then
    p="$(find "$FASTDL" -type f ! -name '*.txt' 2>/dev/null | head -n1 || true)"
    [[ -n "$p" ]] && samples+=("/fastdl/$SID/${p#$FASTDL/}")
  fi

  local seen=' ' s
  for s in "${samples[@]}"; do
    [[ "$seen" == *" $s "* ]] && continue
    seen+="$s "
    probe_url "$s"
    if [[ "$P_CODE" == "200" && "$P_HTML" == "0" && "${P_SIZE:-0}" -gt 0 ]]; then
      echo "  [OK ] $P_CODE  ${P_SIZE}b  magic=$P_MAGIC  $s"
    else
      PROBE_BAD=$((PROBE_BAD+1))
      echo "  [BAD] code=$P_CODE type='$P_CT' size=${P_SIZE}b html=$P_HTML redirect='$P_REDIR'  $s"
    fi
  done

  # несуществующий файл ОБЯЗАН давать 404 (а не 200 с HTML-страницей панели)
  s="/fastdl/$SID/maps/__v58_missing_probe__.bsp.bz2"
  probe_url "$s"
  if [[ "$P_CODE" == "404" ]]; then
    echo "  [OK ] отсутствующий файл -> 404 (правильно)"
  else
    PROBE_BAD=$((PROBE_BAD+1))
    echo "  [BAD] отсутствующий файл -> code=$P_CODE html=$P_HTML redirect='$P_REDIR' (должен быть 404!)"
  fi
}

echo
echo '[3/6] Проба FastDL по HTTP (до исправления)...'
echo '--- nginx: ключевые директивы ---'
nginx -T 2>/dev/null | grep -nE 'default_server|error_page|try_files|return 30[12]|fastdl' | head -40 || true
echo '--- пробы ---'
run_probes
BEFORE_BAD=$PROBE_BAD

# ----------------------------------------------------------------------------
# 4. Исправление nginx (только если пробы плохие)
# ----------------------------------------------------------------------------
echo
echo '[4/6] Исправление nginx...'
NGINX_CHANGED=0
if [[ $BEFORE_BAD -eq 0 ]]; then
  echo '  FastDL по HTTP уже отдаёт правильные файлы - nginx не трогаю.'
else
  command -v nginx >/dev/null 2>&1 || { echo '[ERROR] nginx не найден'; exit 3; }
  nginx -t >/dev/null 2>&1 || { echo '[ERROR] nginx -t падает ДО патча. Исправь конфиг:'; nginx -t; exit 3; }

  mkdir -p "$BACKUP/nginx-orig"
  : > "$BACKUP/nginx-modified.list"
  : > "$BACKUP/nginx-created.list"

  python3 - "$SID" "$PUBLIC_IP" "$LAN_IP" "$BACKUP" "$BASE_DIR" <<'PY'
import re, subprocess, sys, shutil
from pathlib import Path

sid, pub, lan, backup, base = sys.argv[1:6]
INC = Path('/etc/nginx/hyper-cs16-fastdl-v58.inc')
DED = Path('/etc/nginx/conf.d/00-hyper-cs16-fastdl-v58.conf')
MARK = 'hyper-cs16-fastdl-v58'
mod_list = Path(backup) / 'nginx-modified.list'
new_list = Path(backup) / 'nginx-created.list'

INC_TEXT = f'''# HYPER-HOST OLD ZOMBIE FastDL guard v58 (managed file)
location ^~ /fastdl/ {{
    root {base};
    autoindex off;
    types {{ }}
    default_type application/octet-stream;
    error_page 404 @hyper_fastdl_404;
    access_log /var/log/nginx/hyper-cs16-fastdl-access.log;
    add_header X-Hyper-FastDL "v58" always;
}}
location @hyper_fastdl_404 {{
    default_type text/plain;
    return 404 "not found\\n";
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
    print('  [INFO] патч v58 уже встроен в nginx - обновлён только include-файл')
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
    DED.write_text(f'''# HYPER-HOST OLD ZOMBIE FastDL v58 (managed file)
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
      [[ -n "$f" ]] || continue
      [[ -f "$BACKUP/nginx-orig$f" ]] && cp -a "$BACKUP/nginx-orig$f" "$f"
    done < "$BACKUP/nginx-modified.list"
    while IFS= read -r f; do
      [[ -n "$f" ]] && rm -f "$f"
    done < "$BACKUP/nginx-created.list"
  }

  if nginx -t >/tmp/v58-nginx-test.log 2>&1; then
    if systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null; then
      NGINX_CHANGED=1
      echo '  [OK] nginx -t прошёл, nginx перезагружен'
    else
      echo '  [ERROR] reload nginx не удался'
      rollback_nginx; nginx -t >/dev/null 2>&1 && (systemctl reload nginx 2>/dev/null || true)
      exit 4
    fi
  else
    echo '  [ERROR] nginx -t после патча упал:'
    cat /tmp/v58-nginx-test.log
    rollback_nginx
    nginx -t >/dev/null 2>&1 && (systemctl reload nginx 2>/dev/null || true)
    echo '  Конфиг возвращён как был. Пришли вывод выше - подгоню патч под твой nginx.'
    exit 4
  fi
  sleep 1
fi

# ----------------------------------------------------------------------------
# 5. Повторные пробы
# ----------------------------------------------------------------------------
echo
echo '[5/6] Проба FastDL по HTTP (после исправления)...'
run_probes
AFTER_BAD=$PROBE_BAD

# ----------------------------------------------------------------------------
# 6. Параметры сервера и вердикт
# ----------------------------------------------------------------------------
echo
echo '[6/6] Параметры скачивания на сервере...'
if [[ -x "$CTL" || -f "$CTL" ]]; then
  for cv in sv_downloadurl sv_allowdownload sv_allow_dlfile; do
    "$CTL" rcon "$SID" "$cv" 2>/dev/null || true
  done
  echo "  Ожидается: sv_downloadurl = http://${PUBLIC_IP}/fastdl/${SID}/"
fi

EXT="$(curl -s -o /dev/null --max-time 8 -w '%{http_code}' "http://${PUBLIC_IP}/fastdl/${SID}/maps/__v58_missing_probe__.bsp.bz2" 2>/dev/null || true)"
echo "  Проба через внешний IP (может не работать из-за NAT-hairpin): HTTP ${EXT:-000}"

echo
echo '============================================================'
if [[ $AFTER_BAD -eq 0 ]]; then
  echo ' [DONE] FastDL отдаёт корректные файлы, отсутствующие -> 404.'
else
  echo " [ВНИМАНИЕ] После патча плохих проб: $AFTER_BAD. Пришли весь вывод этого скрипта."
fi
echo " Было плохих проб: $BEFORE_BAD | nginx изменён: $NGINX_CHANGED | карантин FastDL: $QUARANTINED"
echo " Бэкап/карантин: $BACKUP"
echo " Отчёт: $REPORT"
echo
echo ' ВАЖНО для игроков: уже скачанные "карты-HTML" остаются у них на диске.'
echo ' Им нужно удалить cstrike\maps\*.bsp (и cstrike_downloads\maps), которые'
echo ' скачались с твоего сервера, - затем зайти заново, карта скачается правильно.'
echo '============================================================'
[[ $AFTER_BAD -eq 0 ]] || exit 5
exit 0
