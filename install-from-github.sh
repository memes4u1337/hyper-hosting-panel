#!/usr/bin/env bash
set -euo pipefail
cd /root
rm -rf /root/hyper-hosting-panel
git clone --depth=1 https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel
cd /root/hyper-hosting-panel

# Apply the repository's normal CS 1.6 build first if it exists.
if [[ -f apply-cs16-v3.3-fullbuild.sh ]]; then
  bash apply-cs16-v3.3-fullbuild.sh
fi

# Then apply the encoding fix. Put this patch folder into the cloned repository,
# or run apply-assembly-encoding-fix.sh from wherever you downloaded it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/apply-assembly-encoding-fix.sh" /root/hyper-hosting-panel
