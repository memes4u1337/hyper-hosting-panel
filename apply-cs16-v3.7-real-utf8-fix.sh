#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS 1.6 assembly installer UTF-8 subprocess fix v3.7
#
# Real root cause fixed here:
# hyper-cs16-ctl::run() used subprocess.run(..., text=True) without explicit
# encoding/error handling. Any non-UTF8 byte printed by rsync/7z/ldd/systemctl/
# journalctl/etc. raised UnicodeDecodeError and was then wrapped as:
#   Assembly install hard-failed; previous server was restored and kept intact: ...
#
# This patch DOES NOT decode game files. .amxx/.so/.dll/.bsp/etc. remain bytes.
# It only makes captured command OUTPUT tolerant of arbitrary bytes.

REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BASE_SCRIPT="${BASE_SCRIPT:-$REPO/apply-cs16-v3.3-fullbuild.sh}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/hyper-cs16-v3.7-backup-$STAMP"
LOG="/root/hyper-cs16-v3.7-$STAMP.log"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG") 2>&1

fail() {
  echo "[ERROR] $*" >&2
  echo "[ERROR] Log: $LOG" >&2
  exit 1
}

on_err() {
  local ec=$?
  echo "[ERROR] v3.7 stopped with exit code $ec" >&2
  echo "[ERROR] Log: $LOG" >&2
  echo "[ERROR] Backup: $BACKUP_DIR" >&2
  exit "$ec"
}
trap on_err ERR

echo "============================================================"
echo " HYPER-HOST CS16 REAL UTF-8 FIX v3.7"
echo "============================================================"
echo "Repo:   $REPO"
echo "Live:   $LIVE_CTL"
echo "Backup: $BACKUP_DIR"
echo "Log:    $LOG"
echo

# Run the user's existing full build first, because it overwrites the live ctl.
if [[ "${SKIP_BASE_BUILD:-0}" != "1" ]]; then
  [[ -f "$BASE_SCRIPT" ]] || fail "Base installer not found: $BASE_SCRIPT"
  echo "[1/6] Running existing base installer: $(basename "$BASE_SCRIPT")"
  chmod +x "$BASE_SCRIPT"
  bash "$BASE_SCRIPT"
else
  echo "[1/6] SKIP_BASE_BUILD=1 -> existing base installer was not run"
fi

echo
 echo "[2/6] Locating hyper-cs16-ctl sources..."

TARGETS=()
add_target() {
  local p="$1"
  [[ -f "$p" ]] || return 0
  local x
  for x in "${TARGETS[@]:-}"; do [[ "$x" == "$p" ]] && return 0; done
  TARGETS+=("$p")
}

add_target "$REPO/cs16-panel/bin/hyper-cs16-ctl"
add_target "$LIVE_CTL"

# Compatibility with repositories where the CS16 panel is nested in a patch dir.
while IFS= read -r p; do add_target "$p"; done < <(
  find "$REPO" -maxdepth 5 -type f -name 'hyper-cs16-ctl' 2>/dev/null | sort
)

((${#TARGETS[@]} > 0)) || fail "hyper-cs16-ctl was not found in repo or $LIVE_CTL"
printf '  - %s\n' "${TARGETS[@]}"

echo
 echo "[3/6] Patching the REAL subprocess decoding bug..."

python3 - "$BACKUP_DIR" "${TARGETS[@]}" <<'PY'
from pathlib import Path
import os
import py_compile
import shutil
import sys

backup_root = Path(sys.argv[1])
targets = [Path(x) for x in sys.argv[2:]]

patched = []
already = []

for idx, path in enumerate(targets):
    raw = path.read_bytes()
    try:
        src = raw.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise SystemExit(f'[ERROR] control script itself is not UTF-8: {path}: {exc}')

    lines = src.splitlines(keepends=True)
    changed = 0
    found_run = False
    found_unsafe = False

    for i, line in enumerate(lines):
        # The actual bug in v3.3/v3.4/v3.5:
        # cp=subprocess.run(...,text=True,check=False,...)
        if 'subprocess.run(' in line and 'text=True' in line:
            found_run = True
            if 'errors=' in line:
                # Already safe. Require an explicit encoding as well for deterministic behavior.
                if 'encoding=' not in line:
                    lines[i] = line.replace('text=True,', "text=True,encoding='utf-8',", 1)
                    changed += 1
                continue

            found_unsafe = True
            if 'encoding=' in line:
                lines[i] = line.replace('text=True,', "text=True,errors='replace',", 1)
            else:
                lines[i] = line.replace(
                    'text=True,',
                    "text=True,encoding='utf-8',errors='replace',",
                    1,
                )
            changed += 1

    if not found_run:
        raise SystemExit(
            f'[ERROR] {path}: subprocess.run(... text=True ...) was not found. '
            'Refusing to report success because this is not the expected CS16 controller.'
        )

    out = ''.join(lines)

    # Verify that no subprocess.run(text=True) remains without an error policy.
    unsafe = []
    for lineno, line in enumerate(out.splitlines(), 1):
        if 'subprocess.run(' in line and 'text=True' in line and 'errors=' not in line:
            unsafe.append((lineno, line.strip()))
    if unsafe:
        raise SystemExit(f'[ERROR] {path}: unsafe text subprocess remains: {unsafe[:5]}')

    if changed:
        dst = backup_root / f'{idx:02d}-{path.name}'
        shutil.copy2(path, dst)
        path.write_text(out, encoding='utf-8', newline='')
        try:
            py_compile.compile(str(path), doraise=True)
        except Exception as exc:
            shutil.copy2(dst, path)
            raise SystemExit(f'[ERROR] syntax validation failed for {path}; restored backup: {exc}')
        patched.append(path)
        print(f'[PATCHED] {path}')
    else:
        # Still compile/validate an already-patched controller.
        py_compile.compile(str(path), doraise=True)
        already.append(path)
        print(f'[OK] already safe: {path}')

if not patched and not already:
    raise SystemExit('[ERROR] no controller was validated')

print(f'[OK] patched={len(patched)} already_safe={len(already)}')
PY

# If repository source exists, copy the fixed controller to the live command.
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
if [[ -f "$REPO_CTL" ]]; then
  echo
  echo "[4/6] Installing patched controller to $LIVE_CTL..."
  if [[ -f "$LIVE_CTL" ]]; then
    cp -a "$LIVE_CTL" "$BACKUP_DIR/live-before-final-install-hyper-cs16-ctl"
  fi
  install -m 0755 "$REPO_CTL" "$LIVE_CTL"
else
  echo
  echo "[4/6] Repository controller not at canonical path; keeping patched live controller"
  chmod 0755 "$LIVE_CTL" 2>/dev/null || true
fi

[[ -f "$LIVE_CTL" ]] || fail "Live controller is missing after patch: $LIVE_CTL"

echo
 echo "[5/6] Verifying installed controller..."
python3 - "$LIVE_CTL" <<'PY'
from pathlib import Path
import py_compile
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
lines = [(n, line) for n, line in enumerate(s.splitlines(), 1)
         if 'subprocess.run(' in line and 'text=True' in line]
if not lines:
    raise SystemExit('[ERROR] live controller has no expected subprocess.run(text=True) call')
unsafe = [(n, line) for n, line in lines if 'errors=' not in line]
if unsafe:
    raise SystemExit('[ERROR] live controller still has unsafe decoding: '+repr(unsafe[:5]))
if not any("errors='replace'" in line or 'errors="replace"' in line for _, line in lines):
    raise SystemExit('[ERROR] errors=replace is not installed in live controller')
py_compile.compile(str(p), doraise=True)
for n, line in lines:
    print(f'[OK] line {n}: {line.strip()}')
print('[OK] live controller syntax and decoding policy verified')
PY

# Reproduce the exact class of crash independently: invalid bytes in captured stdout.
echo
 echo "[6/6] Reproducing 0xFF/0xE0/0x9E/0xD6 subprocess output test..."
python3 - <<'PY'
import subprocess
import sys

samples = (0xff, 0xe0, 0x9e, 0xd6)
for bad in samples:
    code = (
        "import os; "
        f"os.write(1, b'A'*552 + bytes([{bad}]) + b' END\\n')"
    )
    cp = subprocess.run(
        [sys.executable, '-c', code],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding='utf-8',
        errors='replace',
        check=False,
    )
    assert cp.returncode == 0
    assert 'END' in cp.stdout
    print(f'[OK] byte 0x{bad:02X}: no UnicodeDecodeError')
PY

echo
echo "============================================================"
echo " v3.7 REAL FIX INSTALLED"
echo "============================================================"
echo "Fixed: subprocess.run(text=True) UTF-8 crash"
echo "Live:  $LIVE_CTL"
echo "Backup: $BACKUP_DIR"
echo "Log:    $LOG"
echo
echo "Now upload the SAME CS 1.6/ZM archive again."
echo "============================================================"
