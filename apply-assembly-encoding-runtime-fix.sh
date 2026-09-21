#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-/root/hyper-hosting-panel}"
RUNTIME="${HYPER_RUNTIME:-/opt/hyper-host}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/root/hyper-host-assembly-backup-${STAMP}"
LOG="/root/hyper-host-assembly-fix-${STAMP}.log"
mkdir -p "$BACKUP_ROOT"

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo " HYPER-HOST Assembly UTF-8 runtime fix"
echo "============================================================"
echo "Repo:    $REPO"
echo "Runtime: $RUNTIME"
echo "Backup:  $BACKUP_ROOT"
echo "Log:     $LOG"
echo

python3 - "$REPO" "$RUNTIME" "$BACKUP_ROOT" <<'PY'
from __future__ import annotations

import os
import pathlib
import py_compile
import re
import shutil
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
runtime = pathlib.Path(sys.argv[2]).resolve()
backup_root = pathlib.Path(sys.argv[3]).resolve()

roots: list[pathlib.Path] = []
for root in (runtime, repo):
    if root.exists() and root.is_dir() and root not in roots:
        roots.append(root)

if not roots:
    raise SystemExit("[ERR] Neither runtime nor repository directory exists")

ANCHORS = (
    b"Assembly install hard-failed",
    b"previous server was restored and kept intact",
)

SKIP_PARTS = {
    ".git", "node_modules", "vendor", "venv", ".venv", "__pycache__",
    "backups", "backup", "logs", "log", "tmp", "cache",
}

RELEVANT_WORDS = (
    "assembly", "install", "installer", "archive", "extract", "restore",
    "rollback", "server", "template", "config", "deploy", "backup",
)


def iter_files(root: pathlib.Path):
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if any(part in SKIP_PARTS for part in p.parts):
            continue
        try:
            if p.stat().st_size > 8 * 1024 * 1024:
                continue
        except OSError:
            continue
        yield p


def safe_source(p: pathlib.Path) -> str | None:
    try:
        return p.read_bytes().decode("utf-8", errors="surrogateescape")
    except OSError:
        return None

# 1) Find the actual code that produces the exact user-facing failure.
anchor_hits: list[pathlib.Path] = []
for root in roots:
    for p in iter_files(root):
        try:
            raw = p.read_bytes()
        except OSError:
            continue
        if any(anchor in raw for anchor in ANCHORS):
            anchor_hits.append(p)

print("[INFO] Anchor files:")
if anchor_hits:
    for p in anchor_hits:
        print(f"  - {p}")
else:
    print("  (exact error string was not found; using assembly/install heuristics)")

# 2) Select Python files to patch. Runtime is authoritative.
targets: set[pathlib.Path] = set()
component_roots: set[pathlib.Path] = set()
for hit in anchor_hits:
    if hit.suffix == ".py":
        targets.add(hit)
    parent = hit.parent
    for root in roots:
        try:
            rel = hit.relative_to(root)
        except ValueError:
            continue
        # Scan the top-level runtime component containing the real handler. This catches
        # generic helpers such as core/files.py imported by routes/assemblies.py.
        if rel.parts:
            component = root / rel.parts[0]
            if component.is_dir():
                component_roots.add(component)
        break
    # Immediate sibling utilities are always included when encoding-sensitive.
    for p in parent.glob("*.py"):
        src = safe_source(p)
        if src is None:
            continue
        low = src.lower()
        if ("decode(" in low or "encode(" in low or "read_text(" in low or "write_text(" in low
                or "encoding=" in low or "text=true" in low or "universal_newlines=true" in low):
            targets.add(p)

for component in component_roots:
    for p in component.rglob("*.py"):
        if any(part in SKIP_PARTS for part in p.parts):
            continue
        src = safe_source(p)
        if src is None:
            continue
        low = src.lower()
        if (".decode(" in low or ".encode(" in low or ".read_text(" in low or ".write_text(" in low
                or "encoding=" in low or "text=true" in low or "universal_newlines=true" in low):
            targets.add(p)

# Relevant encoding-sensitive Python files under runtime/repo.
for root in roots:
    for p in root.rglob("*.py"):
        if any(part in SKIP_PARTS for part in p.parts):
            continue
        src = safe_source(p)
        if src is None:
            continue
        low = src.lower()
        path_low = str(p).lower()
        encoding_sensitive = (
            ".decode(" in low
            or ".encode(" in low
            or ".read_text(" in low
            or ".write_text(" in low
            or "encoding=" in low
            or "text=true" in low
            or "universal_newlines=true" in low
        )
        relevant = any(w in low for w in RELEVANT_WORDS) or any(w in path_low for w in RELEVANT_WORDS)
        if encoding_sensitive and relevant:
            targets.add(p)

if not targets:
    raise SystemExit("[ERR] Could not find any assembly/install Python file with text decoding operations")

# Regexes intentionally only change decoding error handling. We do not use errors='ignore'
# or errors='replace', because both lose bytes. surrogateescape round-trips arbitrary bytes.
DEC_PATTERNS = [
    (re.compile(r"\.decode\(\s*(['\"])utf-8\1\s*\)"), ".decode('utf-8', errors='surrogateescape')"),
    (re.compile(r"\.decode\(\s*(['\"])utf8\1\s*\)"), ".decode('utf-8', errors='surrogateescape')"),
    (re.compile(r"\.decode\(\s*\)"), ".decode('utf-8', errors='surrogateescape')"),
    (re.compile(r"\.read_text\(\s*encoding\s*=\s*(['\"])utf-8\1\s*\)"), ".read_text(encoding='utf-8', errors='surrogateescape')"),
    (re.compile(r"\.read_text\(\s*(['\"])utf-8\1\s*\)"), ".read_text(encoding='utf-8', errors='surrogateescape')"),
    (re.compile(r"\.read_text\(\s*\)"), ".read_text(encoding='utf-8', errors='surrogateescape')"),
    (re.compile(r"\.encode\(\s*(['\"])utf-8\1\s*\)"), ".encode('utf-8', errors='surrogateescape')"),
    (re.compile(r"\.encode\(\s*(['\"])utf8\1\s*\)"), ".encode('utf-8', errors='surrogateescape')"),
]

# Single-line open(...) / write_text(...) / subprocess calls. This covers the common cases in
# deployment code while avoiding unsafe broad source rewriting.
OPEN_UTF8_RE = re.compile(r"open\(([^\n]*?encoding\s*=\s*(['\"])utf-8\2[^\n]*?)\)")
WRITE_UTF8_RE = re.compile(r"\.write_text\(([^\n]*?encoding\s*=\s*(['\"])utf-8\2[^\n]*?)\)")
SUBPROC_RE = re.compile(
    r"(subprocess\.(?:run|Popen|check_output|check_call)\([^\n]*?)(\))"
)


def add_open_errors(m: re.Match[str]) -> str:
    inside = m.group(1)
    if re.search(r"\berrors\s*=", inside):
        return m.group(0)
    return "open(" + inside + ", errors='surrogateescape')"


def add_write_errors(m: re.Match[str]) -> str:
    inside = m.group(1)
    if re.search(r"\berrors\s*=", inside):
        return m.group(0)
    return ".write_text(" + inside + ", errors='surrogateescape')"


def add_subproc_errors(m: re.Match[str]) -> str:
    head, end = m.group(1), m.group(2)
    low = head.lower()
    if "errors=" in low:
        return m.group(0)
    if "text=true" not in low and "universal_newlines=true" not in low and "encoding=" not in low:
        return m.group(0)
    return head + ", errors='surrogateescape'" + end


def patch_source(src: str) -> tuple[str, int]:
    out = src
    changes = 0
    for rx, repl in DEC_PATTERNS:
        out, n = rx.subn(repl, out)
        changes += n

    new = OPEN_UTF8_RE.sub(add_open_errors, out)
    if new != out:
        # Count only actual newly-added occurrences.
        changes += new.count("errors='surrogateescape'") - out.count("errors='surrogateescape'")
        out = new

    new = WRITE_UTF8_RE.sub(add_write_errors, out)
    if new != out:
        changes += new.count("errors='surrogateescape'") - out.count("errors='surrogateescape'")
        out = new

    new = SUBPROC_RE.sub(add_subproc_errors, out)
    if new != out:
        changes += new.count("errors='surrogateescape'") - out.count("errors='surrogateescape'")
        out = new

    return out, changes

changed: list[tuple[pathlib.Path, int]] = []
failed: list[str] = []

# Prefer runtime files first so diagnostics clearly show the live fix.
for p in sorted(targets, key=lambda x: (0 if runtime in x.parents else 1, str(x))):
    src = safe_source(p)
    if src is None:
        continue
    patched, count = patch_source(src)
    if count <= 0 or patched == src:
        continue

    # Stable backup path, including absolute origin root.
    try:
        rel = p.relative_to(runtime)
        backup = backup_root / "runtime" / rel
        label = f"runtime:{rel}"
    except ValueError:
        try:
            rel = p.relative_to(repo)
            backup = backup_root / "repo" / rel
            label = f"repo:{rel}"
        except ValueError:
            rel = pathlib.Path(p.name)
            backup = backup_root / "other" / rel
            label = str(p)

    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, backup)
    p.write_bytes(patched.encode("utf-8", errors="surrogateescape"))

    try:
        py_compile.compile(str(p), doraise=True)
    except Exception as exc:
        shutil.copy2(backup, p)
        failed.append(f"{p}: {exc}")
        print(f"[ROLLBACK] Syntax check failed, restored {p}: {exc}")
        continue

    changed.append((p, count))
    print(f"[PATCHED] {label} ({count} change(s))")

if failed:
    print("[WARN] Some candidate files failed syntax validation and were individually restored")

if not changed:
    raise SystemExit("[ERR] Candidate files found, but no strict/default UTF-8 decoding operation was patchable")

# Remove stale bytecode next to changed runtime files, otherwise a long-lived launcher may keep old code.
for p, _ in changed:
    pycache = p.parent / "__pycache__"
    if pycache.is_dir():
        shutil.rmtree(pycache, ignore_errors=True)

print()
print("[OK] Live assembly encoding patch applied.")
print(f"[OK] Changed files: {len(changed)}")
for p, n in changed:
    print(f"  - {p} ({n})")
print(f"[OK] Backup: {backup_root}")
PY

# Restart only running Python-based systemd services whose ExecStart points into /opt/hyper-host.
echo
echo "[INFO] Checking running panel services..."
restarted=0
while read -r unit _; do
  [[ -n "${unit:-}" ]] || continue
  execstart="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
  if [[ "$execstart" == *"$RUNTIME"* ]] && [[ "$execstart" =~ (python|gunicorn|uvicorn|hypercorn) ]]; then
    echo "[INFO] Restarting $unit"
    systemctl restart "$unit"
    restarted=$((restarted+1))
  fi
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null || true)

if [[ "$restarted" -eq 0 ]]; then
  echo "[INFO] No matching Python systemd service auto-detected."
  echo "[INFO] If the panel runs in Docker/Supervisor, restart that process after this script."
fi

echo
echo "============================================================"
echo " FIX INSTALLED"
echo " Backup: $BACKUP_ROOT"
echo " Log:    $LOG"
echo "============================================================"
