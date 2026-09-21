#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f ./apply-cs16-v3.3-fullbuild.sh ]]; then
  echo "[ERR] apply-cs16-v3.3-fullbuild.sh not found in repository root" >&2
  exit 2
fi
if [[ ! -f ./apply-assembly-encoding-runtime-fix.sh ]]; then
  echo "[ERR] apply-assembly-encoding-runtime-fix.sh not found in repository root" >&2
  exit 2
fi

chmod +x ./apply-cs16-v3.3-fullbuild.sh ./apply-assembly-encoding-runtime-fix.sh

# Existing build first. It may overwrite /opt/hyper-host, so the runtime encoding fix MUST run after it.
bash ./apply-cs16-v3.3-fullbuild.sh
bash ./apply-assembly-encoding-runtime-fix.sh "$(pwd)"

echo "[DONE] CS16 v3.3 full build + live /opt/hyper-host assembly encoding fix installed."
