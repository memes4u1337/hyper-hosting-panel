#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT_DIR/apply-v1.2-ftp-final-fix.sh" "$@"
