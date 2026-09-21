#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Keep the existing full build flow exactly as before.
if [[ ! -f ./apply-cs16-v3.3-fullbuild.sh ]]; then
  echo "[ERR] apply-cs16-v3.3-fullbuild.sh not found in repository root" >&2
  exit 2
fi

chmod +x ./apply-cs16-v3.3-fullbuild.sh ./apply-assembly-encoding-fix.sh

bash ./apply-cs16-v3.3-fullbuild.sh
bash ./apply-assembly-encoding-fix.sh "$(pwd)"

echo "[DONE] CS16 v3.3 full build + assembly encoding fix installed."
