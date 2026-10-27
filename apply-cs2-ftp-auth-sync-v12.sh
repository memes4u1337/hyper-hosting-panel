#!/usr/bin/env bash
# HYPER-HOST CS2 FTP v12: exact fix for ProFTPD auth sync rejecting cs2_ID.
# Uses the installed CS1.6 FTP backend. Never touches CS2 game files or /etc/passwd.
set -Eeuo pipefail
umask 077
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] Используй sudo bash' >&2; exit 1; }
for binary in python3 systemctl; do command -v "$binary" >/dev/null || { echo "[ERROR] Нет $binary" >&2; exit 1; }; done
HOSTCTL=/usr/local/sbin/hyper-host-ctl
CS2FTP=/usr/local/sbin/hyper-cs2-ftp
[[ -x "$HOSTCTL" && -x "$CS2FTP" ]] || { echo '[ERROR] FTP v10 не найден: нужен hyper-host-ctl и hyper-cs2-ftp' >&2; exit 1; }
LIVE=/opt/hyper-host/bin/proftpd_auth_sync.py
[[ -f "$LIVE" && ! -L "$LIVE" ]] || { echo "[ERROR] Не обнаружен штатный скрипт авторизации: $LIVE. Ничего не изменено." >&2; exit 1; }
TMP=$(mktemp -d /tmp/hyper-cs2-ftp-v12.XXXXXXXX)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/patch.py" <<'PY'
from pathlib import Path
import ast, sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2]); s=src.read_text(encoding='utf-8')
needle='    match = re.fullmatch(r"(?:hhftp_)?cs16_(\\d+)", username)'
marker='# HYPER-HOST: CS2 virtual FTP home, scoped to own server (v12)'
if marker not in s:
    if s.count(needle)!=1:
        raise SystemExit('[ERROR] Структура proftpd_auth_sync.py отличается: не найдена уникальная точка для CS2. Ничего не меняем.')
    addition='''    # HYPER-HOST: CS2 virtual FTP home, scoped to own server (v12)
    cs2_match = re.fullmatch(r"(?:hhftp_)?cs2_([1-9][0-9]{0,3})", username)
    if cs2_match:
        server_id = int(cs2_match.group(1))
        cs2_root = Path(f"/srv/hyper-cs2/servers/{server_id}")
        expected = cs2_root / "gamefiles/game/csgo"
        if absolute != expected:
            raise SystemExit(f"unsafe CS2 FTP home for {username}: {absolute} (expected {expected})")
        if not expected.is_dir():
            raise SystemExit(f"CS2 FTP home missing for {username}: {expected}")
        # Reject symlinked FTP root/ancestors, including links into shared game data.
        for component in (cs2_root, cs2_root / "gamefiles", cs2_root / "gamefiles/game", expected):
            if component.is_symlink() or Path(os.path.realpath(component)) != component:
                raise SystemExit(f"unsafe symlinked CS2 FTP home for {username}: {component}")
        return expected
'''
    s=s.replace(needle,addition+needle,1)
ast.parse(s)
dst.write_text(s,encoding='utf-8')
print('[OK] Принят только FTP-каталог game/csgo своего CS2 ID; проверки CS1.6 сохранены')
PY

printf '[1/6] Предпроверка штатного генератора ProFTPD...\n'
python3 "$TMP/patch.py" "$LIVE" "$TMP/proftpd_auth_sync.py"
python3 -m py_compile "$TMP/proftpd_auth_sync.py"
# Run a strict unit test for the new scope, without changing system FTP data.
python3 - "$TMP/proftpd_auth_sync.py" <<'PY'
from pathlib import Path
import importlib.util, tempfile, sys
p=Path(sys.argv[1]); spec=importlib.util.spec_from_file_location('cs2_sync_test',p)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as d:
    conf=Path(d)/'conf'; conf.mkdir(); ftp=Path(d)/'ftp'; ftp.mkdir()
    (conf/'cs2_2').write_text('local_root=/srv/hyper-cs2/servers/3/gamefiles/game/csgo\n')
    try:m.local_root(conf,ftp,'cs2_2')
    except SystemExit as e:
        assert 'unsafe CS2 FTP home' in str(e),str(e)
    else:raise AssertionError('Проверка ID CS2 не сработала')
    (conf/'invalid_user').write_text('local_root=/etc\n')
    try:m.local_root(conf,ftp,'invalid_user')
    except SystemExit as e:
        assert 'unsafe FTP home' in str(e),str(e)
    else:raise AssertionError('Чужой FTP-каталог разрешён')
print('[OK] Тесты: чужой ID и произвольный FTP-каталог запрещены')
PY

printf '[2/6] Проверка серверной папки #2...\n'
SERVER=/srv/hyper-cs2/servers/2/gamefiles/game/csgo
[[ -d "$SERVER" && ! -L "$SERVER" ]] || { echo "[ERROR] Папка отсутствует или является ссылкой: $SERVER" >&2; exit 1; }
# Path components may not be symlinked: ProFTPD must not chroot into shared base.
for segment in /srv/hyper-cs2/servers/2 /srv/hyper-cs2/servers/2/gamefiles /srv/hyper-cs2/servers/2/gamefiles/game "$SERVER"; do
  [[ -d "$segment" && ! -L "$segment" ]] || { echo "[ERROR] Небезопасный компонент пути: $segment" >&2; exit 1; }
done

printf '[3/6] Резервная копия и атомарное обновление авторизатора...\n'
BACKUP="/root/hyper-cs2-ftp-v12-$(date -u +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$BACKUP"
cp -a "$LIVE" "$BACKUP/proftpd_auth_sync.py"
install -m 0700 -o root -g root "$TMP/proftpd_auth_sync.py" "$LIVE.new-v12"
# Keep original permissions and ownership as much as possible.
chmod --reference="$LIVE" "$LIVE.new-v12"
chown --reference="$LIVE" "$LIVE.new-v12"
mv -f "$LIVE.new-v12" "$LIVE"
python3 -m py_compile "$LIVE"
echo "[OK] Backup: $BACKUP"

printf '[4/6] Восстановление FTP #2 через тот же hyper-host-ctl, что CS1.6...\n'
# Reuse the existing backend, config paths and native password database rebuild.
# Never guess FTP_DIR/auth-file locations: installations may customize them.
CREDS=/var/lib/hyper-cs2/ftp-v10/2.json
DISABLED=/var/lib/hyper-cs2/ftp-v10/2.disabled
if [[ -f "$DISABLED" ]]; then
  echo '[INFO] FTP #2 отключён в панели. Пароль и учётная запись не меняются.'
elif [[ -f "$CREDS" ]]; then
  if python3 - "$CREDS" "$HOSTCTL" <<'PYFTP_REPAIR'
import json,subprocess,sys
from pathlib import Path
p=Path(sys.argv[1]); ctl=sys.argv[2]
if p.is_symlink() or (p.stat().st_mode & 0o077):
    raise SystemExit('[ERROR] Небезопасные права на файл реквизитов FTP')
data=json.loads(p.read_text())
if data.get('username')!='cs2_2' or not data.get('password'):
    raise SystemExit('[ERROR] Неверные данные FTP #2')
# Same operation as CS1.6; password is never printed to logs.
proc=subprocess.run([ctl,'create-ftp','cs2_2',data['password'],'cs2','2'], capture_output=True,text=True,timeout=90)
if proc.returncode:
    raise SystemExit('[ERROR] Штатный create-ftp: '+(proc.stderr or proc.stdout).strip()[-700:])
print('[OK] CS2 FTP #2 пересоздан через штатный контроллер, пароль сохранён')
PYFTP_REPAIR
  then :; else echo '[WARN] Пересоздание FTP #2 не удалось. Исправление авторизатора осталось установленным.'; fi
else
  echo '[INFO] У CS2 #2 ещё нет сохранённого FTP-пароля. Помощник попробует создать его при проверке.'
fi

printf '[5/6] Применение к запущенным ProFTPD-службам...\n'
ACTIVE=0
for unit in hyper-host-proftpd-lan.service hyper-host-proftpd-wan.service; do
  if systemctl is-active --quiet "$unit"; then
    if systemctl reload "$unit"; then echo "[OK] Reload $unit"; else echo "[WARN] Не удалось reload $unit"; fi
    ACTIVE=$((ACTIVE+1))
  else
    echo "[INFO] $unit не активен (не запускаем его принудительно)"
  fi
done
if [[ $ACTIVE -eq 0 ]]; then
  echo '[WARN] Ни одна ProFTPD-служба не активна. Проверь, кто слушает порт 21: ss -ltnp'
fi

printf '[6/6] Проверка FTP CS2 #2...\n'
# The existing helper will create the account automatically if it has not been created yet.
if ! "$CS2FTP" status 2 > "$TMP/status.json"; then
  echo '[WARN] FTP-логин ещё не готов:'
  python3 - "$TMP/status.json" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); print(d.get('error','Unknown FTP error'))
except Exception:print('Не удалось прочитать ответ FTP-контроллера')
PY
else
  python3 - "$TMP/status.json" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); print('[OK] Логин:',d.get('username','?'),'Порт:',d.get('port',21),'Доступ:',d.get('enabled',False))
except Exception:print('[WARN] Ответ FTP-контроллера не разобран')
PY
fi
# End-to-end localhost FTP authentication check. Never echo the password.
if [[ -f "$CREDS" && ! -f "$DISABLED" ]]; then
  python3 - "$CREDS" <<'PYFTP_TEST'
import ftplib,json,sys
try:
    c=json.load(open(sys.argv[1]))
    f=ftplib.FTP()
    f.connect('127.0.0.1',21,timeout=6)
    try:
        f.login(c['username'],c['password'])
        print('[OK] Реальный вход FTP CS2 принят на 127.0.0.1:21')
    finally:
        try:f.quit()
        except Exception:pass
except Exception as e:
    print('[WARN] Не удалось проверить FTP-вход на 127.0.0.1:21:',e)
PYFTP_TEST
fi
printf '\nHYPER-HOST CS2 FTP v12: изменение установлено.\n'
printf 'Backups: %s\n' "$BACKUP"
echo 'CS1.6 game files, CS2 game files and /etc/passwd not modified.'
echo 'Проверь FTP в панели CS2 и фактическое подключение через FileZilla.'
