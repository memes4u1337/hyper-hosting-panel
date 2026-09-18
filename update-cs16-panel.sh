#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
export CS16_SKIP_GAME_DOWNLOAD=1
export CS16_CREATE_DEFAULT=0
exec bash ./install-cs16-panel.sh
