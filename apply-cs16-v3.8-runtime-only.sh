#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 UTF-8 FIX v3.8 — RUNTIME ONLY
#
# IMPORTANT:
# - DOES NOT run apply-cs16-v3.3-fullbuild.sh
# - DOES NOT touch nginx / PHP / SQL / bootstrap.php / site document roots
# - Patches only hyper-cs16-ctl subprocess text decoding
#
# Root cause:
#   def run(...):
#       subprocess.run(..., text=True, ...)
#
# With text=True and no encoding/errors Python decodes command output strictly.
# If 7z/rsync/systemctl/journalctl/ldd/etc. emits any non-UTF8 byte, assembly
# installation aborts with:
#   'utf-8' codec can't decode byte 0x.. ...
#
# Correct behavior for command/log output:
#   text=True, encoding='utf-8', errors='replace'
#
# Game files themselves are NOT decoded or modified by this patch.

LIVE="/usr/local/sbin/hyper-cs16-ctl"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.8-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.8-${STAMP}.log"

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

die() {
  echo
  echo "[ERROR] $*"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backup: $BACKUP"
  exit 1
}

echo "============================================================"
echo " HYPER-HOST CS16 UTF-8 FIX v3.8 — RUNTIME ONLY"
echo "============================================================"
echo "Repo:   $REPO"
echo "Live:   $LIVE"
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo

[[ -f "$LIVE" ]] || die "Live controller not found: $LIVE"

echo "[1/5] Locating controller copies..."

TARGETS=("$LIVE")

while IFS= read -r -d '' f; do
  [[ "$f" == "$LIVE" ]] && continue
  TARGETS+=("$f")
done < <(
  find "$REPO" -type f -name 'hyper-cs16-ctl' \
    -not -path '*/.git/*' \
    -print0 2>/dev/null
)

printf '  - %s\n' "${TARGETS[@]}"

echo
echo "[2/5] Patching the exact subprocess decoding bug..."

python3 - "$BACKUP" "${TARGETS[@]}" <<'PY'
from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

backup_root = Path(sys.argv[1])
targets = [Path(x) for x in sys.argv[2:]]

FUNC_RE = re.compile(
    r"(?ms)^def\s+run\s*\(\s*cmd\s*,\s*check\s*=\s*True\s*,"
    r"\s*capture\s*=\s*True\s*,\s*timeout\s*=\s*None\s*,"
    r"\s*cwd\s*=\s*None\s*,\s*env\s*=\s*None\s*\)\s*:\s*\n"
    r".*?(?=^def\s+|\Z)"
)

TEXT_TRUE_RE = re.compile(r"text\s*=\s*True\s*,")
ENCODING_RE = re.compile(r"encoding\s*=")
ERRORS_RE = re.compile(r"errors\s*=")

patched = []
already = []

for target in targets:
    if not target.is_file():
        continue

    raw = target.read_bytes()
    try:
        src = raw.decode("utf-8")
    except UnicodeDecodeError:
        # Controller source itself should be UTF-8/ASCII. Preserve odd bytes if present.
        src = raw.decode("utf-8", errors="surrogateescape")

    match = FUNC_RE.search(src)
    if not match:
        raise SystemExit(
            f"[ERROR] Could not find the common def run(...) helper in {target}"
        )

    block = match.group(0)

    if "subprocess.run" not in block:
        raise SystemExit(
            f"[ERROR] def run(...) in {target} does not contain subprocess.run"
        )

    if ENCODING_RE.search(block) and ERRORS_RE.search(block):
        print(f"[OK] already fixed: {target}")
        already.append(target)
        continue

    if not TEXT_TRUE_RE.search(block):
        raise SystemExit(
            f"[ERROR] Expected text=True in common run() helper, but it was not found: {target}"
        )

    new_block, count = TEXT_TRUE_RE.subn(
        "text=True,encoding='utf-8',errors='replace',",
        block,
        count=1,
    )

    if count != 1:
        raise SystemExit(
            f"[ERROR] Expected exactly one text=True replacement in {target}; got {count}"
        )

    new_src = src[:match.start()] + new_block + src[match.end():]

    # backup preserving a readable name
    safe_name = str(target).lstrip("/").replace("/", "__")
    backup = backup_root / safe_name
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(target, backup)

    # Atomic write
    tmp = target.with_name(target.name + ".v38tmp")
    tmp.write_bytes(new_src.encode("utf-8", errors="surrogateescape"))
    os.chmod(tmp, target.stat().st_mode)
    os.replace(tmp, target)

    # Verify actual function after write
    check_src = target.read_bytes().decode("utf-8", errors="surrogateescape")
    check_match = FUNC_RE.search(check_src)
    if not check_match:
        shutil.copy2(backup, target)
        raise SystemExit(f"[ERROR] Verification failed; restored {target}")

    check_block = check_match.group(0)
    if "encoding='utf-8'" not in check_block or "errors='replace'" not in check_block:
        shutil.copy2(backup, target)
        raise SystemExit(f"[ERROR] Patch verification failed; restored {target}")

    patched.append(target)
    print(f"[PATCHED] {target}")

if not patched and not already:
    raise SystemExit("[ERROR] No controller was patched or already fixed")

print()
print(f"[OK] patched: {len(patched)}")
print(f"[OK] already fixed: {len(already)}")
PY

echo
echo "[3/5] Python syntax validation..."

for f in "${TARGETS[@]}"; do
  [[ -f "$f" ]] || continue
  python3 -m py_compile "$f" || die "Python syntax check failed: $f"
  echo "[OK] syntax: $f"
done

echo
echo "[4/5] Showing the REAL patched run() helper..."

python3 - "$LIVE" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8", errors="surrogateescape")

m = re.search(
    r"(?ms)^def\s+run\s*\(.*?\)\s*:\s*\n.*?(?=^def\s+|\Z)",
    s,
)
if not m:
    raise SystemExit("[ERROR] run() helper missing after patch")

block = m.group(0)
print(block.rstrip())

if "encoding='utf-8'" not in block or "errors='replace'" not in block:
    raise SystemExit("[ERROR] live run() helper is NOT fixed")
PY

echo
echo "[5/5] Reproducing the exact failure class (0xFF/0xE0/0x9E/0xD6)..."

python3 - <<'PY'
import subprocess
import sys

bad = [0xFF, 0xE0, 0x9E, 0xD6]

for b in bad:
    code = f"import os; os.write(1, b'BEGIN'+bytes([{b}])+b'END')"
    cp = subprocess.run(
        [sys.executable, "-c", code],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    assert cp.returncode == 0
    assert cp.stdout.startswith("BEGIN")
    assert cp.stdout.endswith("END")
    print(f"[OK] byte 0x{b:02X}: no UnicodeDecodeError")

print("[OK] strict subprocess UTF-8 crash reproduced and eliminated")
PY

# Remove stale bytecode if any.
find "$(dirname "$LIVE")" -maxdepth 1 -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

echo
echo "============================================================"
echo " v3.8 RUNTIME FIX INSTALLED"
echo "============================================================"
echo "Nothing else was reinstalled."
echo "No bootstrap.php was touched."
echo "No nginx/PHP/SQL changes were made."
echo
echo "Now retry the SAME CS 1.6 / ZM assembly upload."
echo
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
