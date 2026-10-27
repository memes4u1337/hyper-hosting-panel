#!/usr/bin/env bash
# CommendHub | ловит зависший rundll32 (InstallHinfSection) под strace, чтобы
# увидеть на каком системном вызове он реально встаёт. Диагностика, ничего не чинит.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "[ERROR] Нужен root (sudo bash $0)"; exit 1; }

ROOT=/srv/cs2-client-test
WINE_DIR="$ROOT/wine"
[[ -x "$WINE_DIR/bin/wine" ]] || { echo "[ERROR] $WINE_DIR/bin/wine не найден — setup ещё не ставил Wine"; exit 1; }

command -v strace >/dev/null 2>&1 || { echo "[INFO] ставлю strace (обычный пакет, ни на что не влияет)"; apt-get install -y -qq strace >/dev/null; }

echo "[1] Чистим всё от прошлых попыток"
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f rundll32 2>/dev/null || true
sleep 1
rm -f /tmp/.X97-lock /tmp/.X11-unix/X97
rm -rf "$ROOT/wineprefix"
mkdir -p "$ROOT/wineprefix"

export WINEPREFIX="$ROOT/wineprefix" WINEARCH=win64 DISPLAY=:97 PATH="$WINE_DIR/bin:$PATH"
export WINEDLLOVERRIDES="mscoree,mshtml="

echo "[2] Поднимаю Xvfb"
Xvfb :97 -screen 0 1024x768x24 &
sleep 2

echo "[3] Запускаю wineboot в фоне, жду появления зависающего rundll32.exe"
wineboot --init &
WINEBOOT_PID=$!

RUNDLL_PID=""
for i in $(seq 1 60); do
  RUNDLL_PID="$(pgrep -f 'rundll32.exe setupapi,InstallHinfSection' | head -1 || true)"
  [[ -n "$RUNDLL_PID" ]] && break
  sleep 1
done

if [[ -z "$RUNDLL_PID" ]]; then
  echo "[ERROR] rundll32 с InstallHinfSection так и не появился за 60с — подождал, но не нашёл процесс. ps aux ниже:"
  ps aux | grep -i wine | grep -v grep
  exit 1
fi

echo "[4] Нашёл PID $RUNDLL_PID — цепляю strace на 25 секунд, пишу в /tmp/rundll32-strace.log"
timeout 25 strace -f -tt -p "$RUNDLL_PID" -o /tmp/rundll32-strace.log 2>&1 || true

echo "[5] Последние строки strace (где именно встал):"
tail -n 60 /tmp/rundll32-strace.log

echo
echo "=== Полный файл лежит на сервере: /tmp/rundll32-strace.log ==="
echo "Пришли мне хвост вывода выше — этого обычно достаточно."
