#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-/root/hyper-hosting-panel}"
if [[ ! -d "$REPO" ]]; then
  echo "[ERR] Repo not found: $REPO" >&2
  exit 2
fi

python3 - "$REPO" <<'PY'
from __future__ import annotations
import pathlib, re, shutil, sys, time, py_compile

root = pathlib.Path(sys.argv[1]).resolve()
needle = "Assembly install hard-failed; previous server was restored and kept intact"

py_files = [p for p in root.rglob('*.py') if '.git' not in p.parts and '__pycache__' not in p.parts]
if not py_files:
    raise SystemExit('[ERR] No Python files found in repository')

hits = []
for p in py_files:
    try:
        s = p.read_text('utf-8', errors='surrogateescape')
    except OSError:
        continue
    if needle in s:
        hits.append(p)

# Fallback: target assembly/install/rollback implementation files if the exact user-facing
# string changed between revisions.
if not hits:
    ranked = []
    for p in py_files:
        try:
            s = p.read_text('utf-8', errors='surrogateescape')
        except OSError:
            continue
        low = s.lower()
        score = 0
        for kw, pts in [('assembly', 4), ('install', 3), ('restore', 3), ('rollback', 3), ('hard-fail', 5), ('backup', 1)]:
            if kw in low:
                score += pts
        if score >= 7 and ('utf-8' in low or 'decode(' in low or 'read_text(' in low):
            ranked.append((score, p))
    ranked.sort(reverse=True, key=lambda x: x[0])
    hits = [p for _, p in ranked[:8]]

if not hits:
    raise SystemExit('[ERR] Could not locate assembly installer Python implementation. Nothing changed.')

stamp = time.strftime('%Y%m%d-%H%M%S')
backup_root = root / f'.assembly-encoding-backup-{stamp}'
backup_root.mkdir(parents=True, exist_ok=True)

# Byte-preserving strategy: surrogateescape is explicitly intended for round-tripping
# arbitrary bytes through text APIs. Invalid bytes 0x80..0xFF do not disappear and are
# emitted unchanged when written back with surrogateescape.
patterns = [
    # pathlib reads
    (re.compile(r"\.read_text\(\s*encoding\s*=\s*(['\"])utf-8\1\s*\)"),
     ".read_text(encoding='utf-8', errors='surrogateescape')"),
    (re.compile(r"\.read_text\(\s*(['\"])utf-8\1\s*\)"),
     ".read_text('utf-8', errors='surrogateescape')"),
    # byte decoding
    (re.compile(r"\.decode\(\s*(['\"])utf-8\1\s*\)"),
     ".decode('utf-8', errors='surrogateescape')"),
    (re.compile(r"\.decode\(\s*(['\"])utf8\1\s*\)"),
     ".decode('utf-8', errors='surrogateescape')"),
    # byte encoding: required to round-trip surrogateescaped bytes
    (re.compile(r"\.encode\(\s*(['\"])utf-8\1\s*\)"),
     ".encode('utf-8', errors='surrogateescape')"),
    (re.compile(r"\.encode\(\s*(['\"])utf8\1\s*\)"),
     ".encode('utf-8', errors='surrogateescape')"),
]

# Single-line open(... encoding='utf-8' ...) calls. Add errors only if not already present.
open_re = re.compile(r"open\(([^\n]*?encoding\s*=\s*(['\"])utf-8\2[^\n]*?)\)")

def patch_text(src: str):
    out = src
    changes = 0
    for rx, repl in patterns:
        out, n = rx.subn(repl, out)
        changes += n

    def open_sub(m):
        nonlocal changes
        inside = m.group(1)
        if re.search(r"\berrors\s*=", inside):
            return m.group(0)
        changes += 1
        return "open(" + inside + ", errors='surrogateescape')"
    out = open_re.sub(open_sub, out)

    # pathlib write_text single-line common forms: inject errors= only where explicit UTF-8 is present.
    wt_re = re.compile(r"\.write_text\(([^\n]*?encoding\s*=\s*(['\"])utf-8\2[^\n]*?)\)")
    def wt_sub(m):
        nonlocal changes
        inside = m.group(1)
        if re.search(r"\berrors\s*=", inside):
            return m.group(0)
        changes += 1
        return ".write_text(" + inside + ", errors='surrogateescape')"
    out = wt_re.sub(wt_sub, out)
    return out, changes

changed = []
for p in hits:
    raw = p.read_bytes()
    src = raw.decode('utf-8', errors='surrogateescape')
    patched, count = patch_text(src)
    if count == 0:
        print(f'[WARN] Located installer but no strict UTF-8 operation matched: {p.relative_to(root)}')
        continue

    rel = p.relative_to(root)
    bkp = backup_root / rel
    bkp.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, bkp)
    p.write_bytes(patched.encode('utf-8', errors='surrogateescape'))
    try:
        py_compile.compile(str(p), doraise=True)
    except Exception as e:
        shutil.copy2(bkp, p)
        raise SystemExit(f'[ERR] Syntax check failed for {rel}; restored original: {e}')
    changed.append((p, count))
    print(f'[OK] Patched {rel}: {count} strict UTF-8 operation(s)')

if not changed:
    shutil.rmtree(backup_root, ignore_errors=True)
    raise SystemExit('[ERR] Installer located, but no applicable strict UTF-8 operations were found. Nothing changed.')

marker = root / 'ASSEMBLY_ENCODING_FIX_APPLIED.txt'
marker.write_text(
    'Assembly encoding fix applied\n'
    f'Backup: {backup_root}\n'
    'Mode: UTF-8 + surrogateescape (byte-preserving)\n'
    + '\n'.join(f'{p.relative_to(root)}: {n} changes' for p,n in changed) + '\n',
    encoding='utf-8'
)
print(f'[OK] Backup saved to: {backup_root}')
print('[OK] Python syntax check passed for all modified files.')
print('[OK] Invalid non-UTF8 bytes will now round-trip instead of crashing the assembly install.')
PY

echo "[DONE] Assembly encoding patch applied to $REPO"
