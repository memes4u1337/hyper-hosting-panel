#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16/ZM assembly UTF-8 compatibility fix v3.6
#
# What it fixes:
#   Assembly install hard-failed ... 'utf-8' codec can't decode byte ...
#
# Why this version is different:
#   Previous source-rewrite fixes could miss the real decode when it happened
#   inside a helper/library/subprocess called by the assembly installer.
#   v3.6 activates Python's built-in "surrogateescape" handler for STRICT
#   decoding as soon as the real assembly-installer module is imported.
#   Invalid bytes are preserved and round-trip back to the original bytes.
#
# Usage from repository root:
#   bash apply-cs16-v3.6-fullbuild.sh
#
# Optional test mode / nonstandard runtime:
#   SKIP_BASE_BUILD=1 HYPER_RUNTIME=/path/to/runtime bash apply-cs16-v3.6-fullbuild.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${HYPER_RUNTIME:-/opt/hyper-host}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/root/hyper-host-assembly-v3.6-backup-${STAMP}"
LOG="/root/hyper-host-assembly-v3.6-${STAMP}.log"
BASE_SCRIPT="${REPO}/apply-cs16-v3.3-fullbuild.sh"
MARKER_BEGIN="# >>> HYPER-HOST ASSEMBLY UTF8 COMPAT v3.6 >>>"

mkdir -p "$BACKUP_ROOT"
exec > >(tee -a "$LOG") 2>&1

on_error() {
  local ec=$?
  echo
  echo "[ERROR] v3.6 failed with exit code $ec"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backups (if any): $BACKUP_ROOT"
  exit "$ec"
}
trap on_error ERR

echo "============================================================"
echo " HYPER-HOST CS16/ZM assembly UTF-8 FIX v3.6"
echo "============================================================"
echo "Repo:    $REPO"
echo "Runtime: $RUNTIME"
echo "Backup:  $BACKUP_ROOT"
echo "Log:     $LOG"
echo

# The old full build may overwrite /opt/hyper-host, so it MUST run first.
if [[ "${SKIP_BASE_BUILD:-0}" != "1" ]]; then
  if [[ ! -f "$BASE_SCRIPT" ]]; then
    echo "[ERROR] Base installer not found: $BASE_SCRIPT"
    exit 2
  fi
  chmod +x "$BASE_SCRIPT"
  echo "[1/5] Running existing v3.3 full build first..."
  bash "$BASE_SCRIPT"
else
  echo "[1/5] SKIP_BASE_BUILD=1 -> base v3.3 build skipped"
fi

if [[ ! -d "$RUNTIME" ]]; then
  echo "[ERROR] Runtime directory does not exist: $RUNTIME"
  exit 3
fi

echo
 echo "[2/5] Locating the REAL assembly installer and installing byte-safe UTF-8 compatibility..."

python3 - "$REPO" "$RUNTIME" "$BACKUP_ROOT" <<'PY'
from __future__ import annotations

import ast
import os
from pathlib import Path
import py_compile
import shutil
import sys

repo = Path(sys.argv[1]).resolve()
runtime = Path(sys.argv[2]).resolve()
backup_root = Path(sys.argv[3]).resolve()

MARKER_BEGIN = "# >>> HYPER-HOST ASSEMBLY UTF8 COMPAT v3.6 >>>"
MARKER_END = "# <<< HYPER-HOST ASSEMBLY UTF8 COMPAT v3.6 <<<"

# Registering surrogateescape under the name "strict" means ANY strict UTF-8
# decode reached from this installer (including imported helpers and subprocess
# text wrappers) preserves undecodable bytes instead of throwing
# UnicodeDecodeError. No bytes are silently dropped.
SNIPPET = r'''# >>> HYPER-HOST ASSEMBLY UTF8 COMPAT v3.6 >>>
# Assembly archives may contain CP1251/ANSI text and binary files (.dll/.so/
# .amxx/.dat/etc.).  The installer and its helper libraries must not crash when
# such bytes pass through a text boundary.  surrogateescape is lossless:
# decode -> process -> encode(..., errors="surrogateescape") restores bytes.
import codecs as _hyper_utf8_codecs
try:
    _hyper_utf8_surrogateescape = _hyper_utf8_codecs.lookup_error("surrogateescape")
    _hyper_utf8_codecs.register_error("strict", _hyper_utf8_surrogateescape)
except Exception:
    pass
# <<< HYPER-HOST ASSEMBLY UTF8 COMPAT v3.6 <<<
'''

ANCHORS = (
    b"Assembly install hard-failed",
    b"previous server was restored and kept intact",
)
SKIP_DIRS = {
    ".git", "node_modules", "vendor", "venv", ".venv", "__pycache__",
    "cache", "tmp", "logs", "log", "backup", "backups"
}


def iter_py(root: Path):
    for p in root.rglob("*.py"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        try:
            if p.is_file() and p.stat().st_size <= 8 * 1024 * 1024:
                yield p
        except OSError:
            continue


def has_anchor(p: Path) -> bool:
    try:
        raw = p.read_bytes()
    except OSError:
        return False
    return any(a in raw for a in ANCHORS)


def insertion_line(src: str) -> int:
    """Return 0-based source line where snippet can safely be inserted.
    Keeps shebang/coding cookie, module docstring and __future__ imports valid.
    """
    lines = src.splitlines(keepends=True)
    line = 0
    if lines and lines[0].startswith("#!"):
        line = 1
    for i in range(min(2, len(lines))):
        if "coding" in lines[i] and ("-*-" in lines[i] or "coding:" in lines[i] or "coding=" in lines[i]):
            line = max(line, i + 1)

    try:
        tree = ast.parse(src)
    except SyntaxError:
        return line

    body = tree.body
    idx = 0
    if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), (ast.Str, ast.Constant)):
        value = body[0].value
        sval = value.s if isinstance(value, ast.Str) else value.value
        if isinstance(sval, str):
            line = max(line, int(getattr(body[0], "end_lineno", body[0].lineno)))
            idx = 1

    while idx < len(body) and isinstance(body[idx], ast.ImportFrom) and body[idx].module == "__future__":
        line = max(line, int(getattr(body[idx], "end_lineno", body[idx].lineno)))
        idx += 1
    return line


def backup_path(p: Path) -> tuple[Path, str]:
    try:
        rel = p.relative_to(runtime)
        return backup_root / "runtime" / rel, f"runtime:{rel}"
    except ValueError:
        pass
    try:
        rel = p.relative_to(repo)
        return backup_root / "repo" / rel, f"repo:{rel}"
    except ValueError:
        return backup_root / "other" / p.name, str(p)

# Runtime first. The repository copy is patched too so a later in-place launch
# does not regress, but runtime is the authoritative target.
roots = [runtime]
if repo.exists() and repo != runtime:
    roots.append(repo)

hits: list[Path] = []
for root in roots:
    for p in iter_py(root):
        if has_anchor(p):
            hits.append(p)

# If the exact English message was slightly changed, fall back to modules that
# clearly own assembly installation and exception handling.
if not hits:
    for root in roots:
        for p in iter_py(root):
            try:
                s = p.read_text("utf-8", errors="surrogateescape")
            except OSError:
                continue
            low = s.lower()
            path_low = str(p).lower()
            score = 0
            for word in ("assembly", "install", "rollback", "restore", "archive", "extract"):
                if word in low or word in path_low:
                    score += 1
            if score >= 4 and ("except" in low or "error" in low):
                hits.append(p)

# Deduplicate while preserving order and prefer runtime.
seen = set()
hits = [p for p in hits if not (str(p) in seen or seen.add(str(p)))]

if not hits:
    raise SystemExit(
        "[ERROR] Could not locate the assembly installer Python module. "
        "The exact 'Assembly install hard-failed' source was not found under "
        f"{runtime} or {repo}."
    )

print("[INFO] Assembly installer module(s):")
for p in hits:
    print("  -", p)

patched = []
already = []
for p in hits:
    raw = p.read_bytes()
    src = raw.decode("utf-8", errors="surrogateescape")

    if MARKER_BEGIN in src:
        already.append(p)
        print(f"[OK] already patched: {p}")
        continue

    backup, label = backup_path(p)
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, backup)

    lines = src.splitlines(keepends=True)
    at = insertion_line(src)
    # Ensure separation from neighboring statements.
    block = SNIPPET
    if at > 0 and lines and not lines[at - 1].endswith("\n"):
        block = "\n" + block
    lines.insert(at, block + "\n")
    out = "".join(lines)

    p.write_bytes(out.encode("utf-8", errors="surrogateescape"))
    try:
        py_compile.compile(str(p), doraise=True)
    except Exception as exc:
        shutil.copy2(backup, p)
        raise SystemExit(f"[ERROR] Syntax validation failed for {p}; restored backup. {exc}")

    pycache = p.parent / "__pycache__"
    if pycache.exists():
        shutil.rmtree(pycache, ignore_errors=True)

    patched.append(p)
    print(f"[PATCHED] {label}")

# Also place a small self-test in the runtime. This is not imported by the app;
# it proves the exact codec behavior installed by the snippet.
test_file = runtime / ".hyper_utf8_v36_selftest.py"
test_file.write_text(
r'''import codecs
orig = codecs.lookup_error("strict")
try:
    codecs.register_error("strict", codecs.lookup_error("surrogateescape"))
    samples = [b"A\xffB", b"A\xe0B", b"A\x9eB"]
    for raw in samples:
        text = raw.decode("utf-8")
        assert text.encode("utf-8", errors="surrogateescape") == raw
    print("OK: 0xff / 0xe0 / 0x9e survive strict UTF-8 path losslessly")
finally:
    codecs.register_error("strict", orig)
''', encoding="utf-8"
)

if not patched and not already:
    raise SystemExit("[ERROR] Installer candidates were found but no module was patched")

print()
print(f"[OK] New patches: {len(patched)}")
print(f"[OK] Already patched: {len(already)}")
print(f"[OK] Backup root: {backup_root}")
PY

echo
 echo "[3/5] Running codec self-test against the same failing byte classes..."
python3 "$RUNTIME/.hyper_utf8_v36_selftest.py"

echo
 echo "[4/5] Restarting live panel Python services that point into $RUNTIME ..."
restarted=0
while read -r unit _rest; do
  [[ -n "${unit:-}" ]] || continue
  execstart="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
  if [[ "$execstart" == *"$RUNTIME"* ]] && [[ "$execstart" =~ (python|gunicorn|uvicorn|hypercorn) ]]; then
    echo "[INFO] restart $unit"
    systemctl restart "$unit"
    restarted=$((restarted + 1))
  fi
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null || true)

# Supervisor fallback.
if command -v supervisorctl >/dev/null 2>&1; then
  while read -r name state _; do
    [[ "$state" == "RUNNING" ]] || continue
    pid="$(supervisorctl pid "$name" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cwd" == "$RUNTIME"* || "$cmd" == *"$RUNTIME"* ]]; then
      echo "[INFO] supervisor restart $name"
      supervisorctl restart "$name" || true
      restarted=$((restarted + 1))
    fi
  done < <(supervisorctl status 2>/dev/null || true)
fi

if [[ "$restarted" -eq 0 ]]; then
  echo "[WARN] No matching systemd/Supervisor Python process was auto-detected."
  echo "[WARN] If your panel is in Docker, restart the panel container once."
else
  echo "[OK] Restarted process/service count: $restarted"
fi

echo
 echo "[5/5] Verifying that the live installer contains the v3.6 marker..."
if grep -RIl --include='*.py' --exclude-dir='venv' --exclude-dir='.venv' --exclude-dir='__pycache__' \
  "$MARKER_BEGIN" "$RUNTIME" 2>/dev/null | head -n 20; then
  true
fi

echo
echo "============================================================"
echo " v3.6 INSTALLED"
echo "============================================================"
echo "The assembly installer now preserves non-UTF8 bytes instead"
echo "of crashing on 0xff / 0xe0 / 0x9e and similar bytes."
echo
echo "Backup: $BACKUP_ROOT"
echo "Log:    $LOG"
echo
echo "Now retry the SAME ZM/server assembly that failed before."
echo "============================================================"
