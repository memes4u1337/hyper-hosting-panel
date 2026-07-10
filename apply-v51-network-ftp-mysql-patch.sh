#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[HYPER-HOST] v51 заменён исправлением v52 с фиксированными IP."
exec bash "$PROJECT_DIR/apply-v52-fixed-ip.sh"
