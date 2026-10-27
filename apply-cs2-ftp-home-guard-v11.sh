#!/usr/bin/env bash
# HYPER-HOST CS2 FTP home compatibility hotfix v11.
# Narrowly extends the existing FTP home check for one per-instance CS2 directory.
set -Eeuo pipefail
umask 077
[[ ${EUID:-$(id -u)} == 0 ]] || { echo '[ERROR] Требуется sudo bash' >&2; exit 1; }
FTP=/usr/local/sbin/hyper-host-ftp-server
HOSTCTL=/usr/local/sbin/hyper-host-ctl
CS2FTP=/usr/local/sbin/hyper-cs2-ftp
SERVICE=hyper-host-ftp.service
[[ -f "$FTP" && ! -L "$FTP" ]] || { echo "[ERROR] FTP-файл отсутствует или является ссылкой: $FTP" >&2; exit 1; }
[[ -x "$HOSTCTL" && -x "$CS2FTP" ]] || { echo '[ERROR] Сначала установите действующий модуль CS2 FTP v10' >&2; exit 1; }
command -v python3 >/dev/null || exit 1
systemctl is-active --quiet "$SERVICE" || { echo "[ERROR] $SERVICE не работает. Автоматическая правка остановлена." >&2; exit 1; }
TMP=$(mktemp -d /tmp/hyper-cs2-ftp11.XXXXXXXX)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/prepare.py" <<'PY'
import ast, pathlib, sys, re
source=pathlib.Path(sys.argv[1]); destination=pathlib.Path(sys.argv[2]); dry=sys.argv[3]=='check'
s=source.read_text(encoding='utf-8')
if '_hyper_cs2_ftp_home_allowed_v11' in s:
    print('[INFO] FTP guard v11 already installed')
    destination.write_text(s)
    raise SystemExit(0)
if 'unsafe FTP home' not in s:
    raise SystemExit('[ERROR] Текущий FTP-сервер не содержит ожидаемой проверки unsafe FTP home. Ничего не изменено.')
try: tree=ast.parse(s)
except SyntaxError:
    raise SystemExit('[ERROR] FTP-сервер не является поддерживаемым Python-скриптом. Ничего не изменено.')
# Guard must be a conditional branch which actually produces the FTP error.
found=[]
for node in ast.walk(tree):
    if isinstance(node, ast.If):
        matches=[c for c in ast.walk(node) if isinstance(c,ast.Constant) and isinstance(c.value,str) and 'unsafe FTP home' in c.value]
        if matches:
            found.append(node)
if not found:
    raise SystemExit('[ERROR] Не определено условие, которое блокирует FTP home. Ничего не изменено.')
# The narrowest branch enclosing the error is the only condition we modify.
node=min(found,key=lambda n:(n.end_lineno-n.lineno,n.end_col_offset if n.end_lineno==n.lineno else 100000))
if len([n for n in found if n.lineno==node.lineno and n.col_offset==node.col_offset])!=1:
    raise SystemExit('[ERROR] Неоднозначное FTP-условие. Ничего не изменено.')
text=ast.get_source_segment(s,node.test)
if not text or '_hyper_cs2_ftp_home_allowed_v11' in text:
    raise SystemExit('[ERROR] Не найдено исходное условие FTP. Ничего не изменено.')
# Python AST byte offsets are byte offsets within each UTF-8 line.
lines=s.splitlines(keepends=True)
def off(lineno, byte_col):
    return sum(map(len,lines[:lineno-1])) + len(lines[lineno-1].encode('utf-8')[:byte_col].decode('utf-8'))
a=off(node.test.lineno,node.test.col_offset); b=off(node.test.end_lineno,node.test.end_col_offset)
if s[a:b]!=text:
    raise SystemExit('[ERROR] FTP исходный код отличается от ожидаемого. Ничего не изменено.')
newtest='('+text+') and not _hyper_cs2_ftp_home_allowed_v11(locals())'
s=s[:a]+newtest+s[b:]
function='''\n# HYPER-HOST CS2 FTP scoped-home allowance v11. Other FTP accounts unchanged.\ndef _hyper_cs2_ftp_home_allowed_v11(_scope):\n    try:\n        import pathlib as _p, re as _re, json as _json, stat as _stat\n        _users=[]\n        for _key in ('username','user','login','ftp_user','user_name','ftp_username','name','account'):\n            _value=_scope.get(_key)\n            if isinstance(_value,str) and _re.fullmatch(r'cs2_[1-9][0-9]{0,3}',_value):\n                _users.append(_value)\n        _users=set(_users)\n        if len(_users)!=1: return False\n        _id=next(iter(_users)).split('_')[1]\n        _expected=_p.Path('/srv/hyper-cs2/servers')/_id/'gamefiles/game/csgo'\n        _homes=[]\n        for _key in ('home','root','local_root','ftp_home','home_dir','home_path','user_home','ftp_root','directory','folder'):\n            _value=_scope.get(_key)\n            if isinstance(_value,(str,_p.Path)) and str(_value).rstrip('/')==str(_expected):\n                _homes.append(_value)\n        if not _homes:return False\n        _server=_p.Path('/srv/hyper-cs2/servers')/_id\n        if not _server.is_dir() or _server.is_symlink():return False\n        _state=_p.Path('/var/lib/hyper-cs2/servers')/(_id+'.json')\n        if not _state.is_file() or _state.is_symlink():return False\n        _entry=_json.loads(_state.read_text())\n        if int(_entry.get('id',-1))!=int(_id) or _entry.get('state')!='ready':return False\n        if not _expected.is_dir():return False\n        for _parent in (_server,_server/'gamefiles',_server/'gamefiles/game',_expected):\n            if _parent.is_symlink() or (_parent.stat().st_mode & 0o002):return False\n        if _expected.resolve()!=_expected:return False\n        for _sub in ('cfg','addons'):\n            _dir=_expected/_sub\n            if not _dir.is_dir() or _dir.is_symlink() or _dir.resolve()!=_dir:return False\n        return True\n    except Exception:\n        return False\n\n'''
# Inject at module level after shebang, docstring and future imports.
body=tree.body
n=0
if body and isinstance(body[0],ast.Expr) and isinstance(body[0].value,(ast.Str,ast.Constant)) and isinstance(getattr(body[0].value,'value',None),str):n=1
while n<len(body) and isinstance(body[n],ast.ImportFrom) and body[n].module=='__future__':n+=1
position=off(body[n].lineno,0) if n<len(body) else len(s)
s=s[:position]+function+s[position:]
try: ast.parse(s)
except SyntaxError as e:raise SystemExit(f'[ERROR] Ошибка итогового Python: {e}')
destination.write_text(s)
print('[OK] Проверка CS2 FTP внесена только в ветку, формирующую unsafe FTP home')
PY

printf '[1/5] Проверка встроенного FTP и создание патча без изменения сервера...\n'
python3 "$TMP/prepare.py" "$FTP" "$TMP/ftp.new" check
python3 -m py_compile "$TMP/ftp.new"

printf '[2/5] Проверка записи сервера CS2 и сохранение резервной копии...\n'
python3 - <<'PY'
from pathlib import Path
import json
p=Path('/var/lib/hyper-cs2/servers/2.json')
if not p.is_file() or json.loads(p.read_text()).get('state')!='ready':
    raise SystemExit('[ERROR] Сервер CS2 №2 не ready. Ничего не изменено.')
print('[OK] CS2 #2 готов')
PY
BACKUP="/root/hyper-cs2-ftp-guard-v11-$(date -u +%Y%m%d-%H%M%S)"
mkdir -m 0700 "$BACKUP"
cp -a "$FTP" "$BACKUP/hyper-host-ftp-server"
if [[ -f /usr/local/sbin/hyper-cs2-ftp ]]; then cp -a /usr/local/sbin/hyper-cs2-ftp "$BACKUP/hyper-cs2-ftp";fi
printf '[3/5] Обновление только FTP-сервера...\n'
rollback() {
  echo '[ERROR] Восстановление предыдущего FTP-сервера...' >&2
  cp -a "$BACKUP/hyper-host-ftp-server" "$FTP" || true
  systemctl restart "$SERVICE" || true
}
trap rollback ERR
chown --reference="$FTP" "$TMP/ftp.new"
chmod --reference="$FTP" "$TMP/ftp.new"
cp -a "$TMP/ftp.new" "$FTP"
python3 -m py_compile "$FTP"
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE"

printf '[4/5] Проверка FTP авторизации CS2 #2 без вывода пароля...\n'
python3 - <<'PY'
import ftplib,json,pathlib
p=pathlib.Path('/var/lib/hyper-cs2/ftp-v10/2.json')
if not p.is_file():
    print('[WARN] Реквизиты FTP #2 отсутствуют. Проверьте вкладку FTP в панели.')
else:
    c=json.loads(p.read_text())
    f=ftplib.FTP()
    f.connect('127.0.0.1',21,timeout=8)
    try:
        f.login(c['username'],c['password'])
        print('[OK] CS2 FTP login accepted on 127.0.0.1:21')
        try:
            f.pwd()
            print('[OK] FTP home accessible')
        except Exception as ex:
            print('[WARN] FTP login accepted, but PWD failed:',str(ex))
    finally:
        try:f.quit()
        except Exception:pass
PY
printf '[5/5] FTP исправление завершено. Резервная копия: %s\n' "$BACKUP"
echo 'CS1.6 / CS2 игровые сервисы не изменены.'
