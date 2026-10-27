#!/usr/bin/env bash
# CommendHub | эксперимент: headless CS2-клиент через Wine для РЕАЛЬНОГО захода
# бота на сервер (см. README.md рядом). НЕ ПОДКЛЮЧЕНО к боевой выдаче заказов.
#
# Статус: proof-of-concept. Запускать ТОЛЬКО на тестовом Steam-аккаунте.
# Первый прогон, скорее всего, вскроет что-то, что придётся донастраивать —
# это ожидаемо, пришли мне полный вывод, поправим.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERROR] Нужен root (sudo bash $0)"; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo "[ERROR] Нужен x86_64 Linux"; exit 1; }

ROOT=/srv/cs2-client-test
WINEPREFIX="$ROOT/wineprefix"
STEAMCMD_DIR="$ROOT/steamcmd"
LOG="$ROOT/setup.log"

mkdir -p "$ROOT"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) setup-headless-client.sh start ==="

log(){ printf '\n[SETUP] %s\n' "$*"; }

log "Ставим Wine (WineHQ stable) + Xvfb + зависимости"
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq wget gpg ca-certificates software-properties-common >/dev/null

if ! command -v wine >/dev/null 2>&1; then
  mkdir -pm755 /etc/apt/keyrings
  wget -qO- https://dl.winehq.org/wine-builds/winehq.key | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  wget -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/${CODENAME}/winehq-${CODENAME}.sources" \
    || log "[WARN] не нашёл winehq-репозиторий под кодовое имя ${CODENAME} — поставь Wine вручную и перезапусти скрипт"
  apt-get update -qq
  apt-get install -y -qq --install-recommends winehq-stable >/dev/null
fi
wine --version || { echo "[ERROR] Wine не установился — смотри вывод выше"; exit 1; }

apt-get install -y -qq xvfb x11-utils mesa-vulkan-drivers mesa-utils libvulkan1 winbind cabextract >/dev/null
log "Xvfb + Mesa (программный Vulkan/OpenGL — без GPU будет МЕДЛЕННО, это ожидаемо для теста)"

if ! command -v winetricks >/dev/null 2>&1; then
  wget -q https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -O /usr/local/bin/winetricks
  chmod +x /usr/local/bin/winetricks
fi

log "Готовим изолированный WINEPREFIX: $WINEPREFIX"
mkdir -p "$WINEPREFIX"
export WINEPREFIX WINEARCH=win64 DISPLAY=:97
pkill -f "Xvfb :97" 2>/dev/null || true
Xvfb :97 -screen 0 1024x768x24 &
XVFB_PID=$!
sleep 2
wineboot --init
winetricks -q corefonts vcrun2019 || log "[WARN] winetricks частично не отработал — может быть не критично, смотри по логу ниже"
kill "$XVFB_PID" 2>/dev/null || true

log "Ставим steamcmd (отдельно от твоего dedicated-сервера, НЕ трогаем /opt/hyper-cs2)"
mkdir -p "$STEAMCMD_DIR"
if [[ ! -f "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  curl -fLSs --retry 4 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' -o "$STEAMCMD_DIR/steamcmd.tar.gz"
  tar -xzf "$STEAMCMD_DIR/steamcmd.tar.gz" -C "$STEAMCMD_DIR"
  rm -f "$STEAMCMD_DIR/steamcmd.tar.gz"
fi

echo
echo "=== Теперь нужен логин тестового Steam-аккаунта ==="
read -rp "Steam login (тестового бота, НЕ боевого): " STEAM_USER
read -rsp "Steam password: " STEAM_PASS; echo

log "Качаем КЛИЕНТСКУЮ (Windows) ветку App 730 — это не dedicated-сервер, это сам игровой клиент"
log "Если Steam Guard спросит код — он придёт на почту бота, введи его когда попросит steamcmd"
"$STEAMCMD_DIR/steamcmd.sh" \
  +@sSteamCmdForcePlatformType windows \
  +force_install_dir "$ROOT/game" \
  +login "$STEAM_USER" "$STEAM_PASS" \
  +app_update 730 validate \
  +quit

[[ -f "$ROOT/game/game/bin/win64/cs2.exe" ]] && log "✓ cs2.exe на месте: $ROOT/game/game/bin/win64/cs2.exe" \
  || log "[WARN] cs2.exe не нашёлся по ожидаемому пути — проверь вывод steamcmd выше, путь мог измениться у Valve"

cat > "$ROOT/.env" << ENVEOF
# Заполни перед connect-test.sh
STEAM_USER=$STEAM_USER
SERVER_IP=1.2.3.4
SERVER_PORT=27101
ENVEOF
log "Отредактируй $ROOT/.env — впиши реальный IP:порт своего CS2-сервера (из hyper-cs2-ctl status)"
log "Готово. Дальше: sudo bash connect-test.sh"
