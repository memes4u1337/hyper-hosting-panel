#!/usr/bin/env bash
# CommendHub | последняя гипотеза: wineserver/SetupAPI виснет без dbus-сессии.
# Ставит обычный dbus (безопасный системный пакет, не трогает PHP/libgd3),
# прогоняет wineboot внутри одноразовой dbus-сессии через dbus-run-session.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "[ERROR] Нужен root (sudo bash $0)"; exit 1; }

ROOT=/srv/cs2-client-test
command -v dbus-run-session >/dev/null 2>&1 || { echo "[INFO] ставлю dbus-user-session"; apt-get update -qq; apt-get install -y -qq dbus-user-session dbus-x11 >/dev/null; }
command -v dbus-run-session >/dev/null 2>&1 || { echo "[ERROR] dbus-run-session всё равно не появился после установки"; exit 1; }

pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f wineserver 2>/dev/null || true
pkill -9 -f rundll32 2>/dev/null || true
sleep 1
rm -f /tmp/.X97-lock /tmp/.X11-unix/X97
rm -rf "$ROOT/wineprefix"
mkdir -p "$ROOT/wineprefix"

export WINEPREFIX="$ROOT/wineprefix" WINEARCH=win64 DISPLAY=:97 PATH="$ROOT/wine/bin:$PATH"
export WINEDLLOVERRIDES="mscoree,mshtml="

Xvfb :97 -screen 0 1024x768x24 &
sleep 2

echo "--- wineboot внутри dbus-run-session ---"
time dbus-run-session -- wineboot --init
echo "--- код выхода: $? ---"
