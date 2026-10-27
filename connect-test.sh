#!/usr/bin/env bash
# CommendHub | разовый тест: заходит ли headless-клиент реально на сервер.
# Ничего не шлёт в похвалы, ничего не трогает в боевой выдаче.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "[ERROR] Нужен root (sudo bash $0)"; exit 1; }

ROOT=/srv/cs2-client-test
[[ -f "$ROOT/.env" ]] || { echo "[ERROR] Сначала setup-headless-client.sh"; exit 1; }
# shellcheck disable=SC1091
source "$ROOT/.env"
[[ "$SERVER_IP" != "1.2.3.4" ]] || { echo "[ERROR] Впиши реальный SERVER_IP в $ROOT/.env"; exit 1; }

EXE="$ROOT/game/game/bin/win64/cs2.exe"
[[ -f "$EXE" ]] || { echo "[ERROR] $EXE не найден — setup не завершился или путь Valve изменился"; exit 1; }

RUNLOG="$ROOT/connect-test-$(date +%Y%m%d-%H%M%S).log"
export WINEPREFIX="$ROOT/wineprefix" DISPLAY=:97

echo "=== Статус сервера ДО захода (сверь с тем, что будет после) ==="
echo "Запусти вручную на сервере: hyper-cs2-ctl status <id_сервера>" | tee -a "$RUNLOG"

pkill -f "Xvfb :97" 2>/dev/null || true
Xvfb :97 -screen 0 1024x768x24 &
XVFB_PID=$!
sleep 2

echo "Запускаю клиент, подключаюсь к ${SERVER_IP}:${SERVER_PORT}, лог: $RUNLOG"
echo "Это может занять 1-3 минуты на загрузку даже без GPU — не прерывай раньше времени."

timeout 300 wine "$EXE" -windowed -w 1024 -h 768 -novid -nojoy +connect "${SERVER_IP}:${SERVER_PORT}" \
  >> "$RUNLOG" 2>&1 &
WINE_PID=$!

echo "Клиент запущен (pid $WINE_PID). Жду 90 секунд, потом сам всё закрою."
echo "ПОКА ЖДЁШЬ: в другом терминале прогони 'hyper-cs2-ctl status <id>' — если бот реально зашёл,"
echo "он появится в списке игроков на сервере (players вырастет с 0)."
sleep 90

kill "$WINE_PID" 2>/dev/null || true
sleep 3
pkill -f "cs2.exe" 2>/dev/null || true
kill "$XVFB_PID" 2>/dev/null || true

echo
echo "=== Готово. Проверь: ==="
echo "1) $RUNLOG — есть ли там ошибки, или строки про успешный коннект/карту"
echo "2) hyper-cs2-ctl status <id> СЕЙЧАС (после выхода бота — players должен был на 90с вырасти, потом снова упасть)"
echo "3) через 24ч: https://steamcommunity.com/my/edit/history (вкладка VAC) — не прилетел ли бан этому аккаунту"
echo
echo "Пришли мне содержимое $RUNLOG целиком + что показал status."
