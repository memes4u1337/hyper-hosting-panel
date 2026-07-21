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
  chmod +x apply-v1.2-network-ssl-repair.sh setup.sh install.sh
  ./apply-v1.2-network-ssl-repair.sh "$TARGET"
  exec hyper-host-installer
else
  rm -rf "$TARGET"
  mv "$TMP" "$TARGET"
  cd "$TARGET"
  chmod +x setup.sh install.sh
  exec bash setup.sh
fi
