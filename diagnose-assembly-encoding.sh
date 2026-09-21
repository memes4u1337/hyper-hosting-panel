#!/usr/bin/env bash
set -euo pipefail
REPO="${1:-/root/hyper-hosting-panel}"
echo "== exact hard-fail source =="
grep -RIn --include='*.py' --exclude-dir=.git "Assembly install hard-failed" "$REPO" || true
echo
echo "== strict UTF-8 operations near installer-related code =="
grep -RInE --include='*.py' --exclude-dir=.git "read_text\(|decode\(|encoding=.*utf-8|encoding=.*utf8" "$REPO" | grep -Ei 'assembly|install|server|deploy|archive|restore|backup' || true
