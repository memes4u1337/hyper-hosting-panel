#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="https://github.com/memes4u1337/hyper-hosting-panel.git"
TARGET="/root/hyper-hosting-panel"

if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

cd /root
rm -rf "$TARGET"
git clone --depth 1 --branch main "$REPOSITORY" "$TARGET"
cd "$TARGET"
chmod +x setup.sh install.sh install-from-github.sh
exec bash setup.sh
