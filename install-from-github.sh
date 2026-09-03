#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="https://github.com/memes4u1337/hyper-hosting-panel.git"
TARGET="/root/hyper-hosting-panel"
TMP="/tmp/hyper-host-v1.2-update"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

cd /root
rm -rf "$TMP"
git clone --depth 1 --branch main "$REPOSITORY" "$TMP"

if [[ -f /etc/hyper-host/hyper-host.conf ]]; then
  rm -rf "$TARGET"
  mv "$TMP" "$TARGET"
  cd "$TARGET"
  chmod +x setup.sh install.sh update.sh
  exec bash update.sh
else
  rm -rf "$TARGET"
  mv "$TMP" "$TARGET"
  cd "$TARGET"
  chmod +x setup.sh install.sh
  exec bash setup.sh
fi
