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

log "Портативный Wine (без apt-get install winehq-stable — на сервере конфликт"
log "libgd3:i386 из PPA ondrej/php с версией, нужной winehq-stable; трогать эту"
log "библиотеку нельзя — на ней держится PHP/GD в твоей панели). Ставим только"
log "рантайм-зависимости из обычных репозиториев, сам Wine — готовым тарболом."
apt-get update -qq
apt-get install -y -qq wget ca-certificates xvfb x11-utils mesa-vulkan-drivers mesa-utils libvulkan1 cabextract xz-utils >/dev/null

WINE_DIR="$ROOT/wine"
if [[ ! -x "$WINE_DIR/bin/wine" ]]; then
  log "Качаем портативную сборку Wine (Kron4ek/Wine-Builds 11.14, чистый amd64 —"
  log "CS2 сам по себе 64-битный, 32-битный Wine/i386 ему не нужен, без apt)"
  mkdir -p "$WINE_DIR"
  WINE_TARBALL_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/11.14/wine-11.14-amd64.tar.xz"
  WINE_TARBALL_SHA256="0c1082b9c1b2ab0a85645ed3c83191dd60b557b28169733546d81fe599ad88b3"
  curl -fLSs --retry 4 "$WINE_TARBALL_URL" -o "$ROOT/wine.tar.xz" \
    || { echo "[ERROR] не скачалось — проверь актуальную ссылку на https://github.com/Kron4ek/Wine-Builds/releases и поправь WINE_TARBALL_URL в этом скрипте"; exit 1; }
  echo "${WINE_TARBALL_SHA256}  $ROOT/wine.tar.xz" | sha256sum -c - \
    || { echo "[ERROR] сумма не сошлась — файл скачался битым или URL/хэш устарели, не распаковываю"; exit 1; }
  tar -xJf "$ROOT/wine.tar.xz" -C "$WINE_DIR" --strip-components=1
  rm -f "$ROOT/wine.tar.xz"
fi
export PATH="$WINE_DIR/bin:$PATH"
wine --version || { echo "[ERROR] портативный Wine не запустился — скорее всего не хватает системной библиотеки, смотри вывод ошибки выше"; exit 1; }
log "✓ Wine готов (портативный, apt/системные пакеты не трогали)"

if ! command -v winetricks >/dev/null 2>&1; then
  wget -q https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -O /usr/local/bin/winetricks
  chmod +x /usr/local/bin/winetricks
fi

log "Готовим изолированный WINEPREFIX с нуля: $WINEPREFIX"
export WINEPREFIX WINEARCH=win64 DISPLAY=:97
pkill -f "Xvfb :97" 2>/dev/null || true
rm -rf "$WINEPREFIX"
mkdir -p "$WINEPREFIX"
Xvfb :97 -screen 0 1024x768x24 &
XVFB_PID=$!
sleep 2
wineboot --init
wineserver --wait
log "wineboot реально завершился (wineserver --wait дождался), префикс готов"
winetricks -q corefonts vcrun2019 || log "[WARN] winetricks частично не отработал — может быть не критично, смотри по логу ниже"
wineserver --wait
wineserver -k 2>/dev/null || true
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
