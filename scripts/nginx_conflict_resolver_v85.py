#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
from pathlib import Path


def active_configs() -> list[Path]:
    proc = subprocess.run(
        ["nginx", "-T"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="ignore",
        check=False,
    )
    result: list[Path] = []
    seen: set[str] = set()
    for line in (proc.stdout or "").splitlines():
        match = re.match(r"^# configuration file (.+):$", line.strip())
        if not match:
            continue
        raw = match.group(1).strip()
        if not raw.startswith("/etc/nginx/") or raw in seen:
            continue
        seen.add(raw)
        result.append(Path(raw))
    return result


def strip_host(path: Path, host: str) -> bool:
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return False
    changed = False
    counter = 0

    def repl(match: re.Match[str]) -> str:
        nonlocal changed, counter
        prefix, raw, suffix = match.group(1), match.group(2), match.group(3)
        tokens = raw.split()
        kept = [token for token in tokens if token.lower().rstrip(".") != host]
        if len(kept) == len(tokens):
            return match.group(0)
        changed = True
        counter += 1
        if not kept:
            digest = hashlib.sha1(f"{path}:{counter}:{host}".encode()).hexdigest()[:12]
            kept = [f"v85-resolved-{digest}.invalid"]
        return prefix + " ".join(kept) + suffix

    updated = re.sub(r"(^[ \t]*server_name[ \t]+)([^;]+)(;)", repl, text, flags=re.I | re.M)
    if not changed:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--keep", required=True)
    args = parser.parse_args()
    host = args.host.strip().lower().rstrip(".")
    keep = Path(args.keep)
    try:
        keep_real = keep.resolve(strict=False)
    except Exception:
        keep_real = keep

    changed: list[str] = []
    for path in active_configs():
        try:
            path_real = path.resolve(strict=False)
        except Exception:
            path_real = path
        if path == keep or path_real == keep_real:
            continue
        # Only files that can actually contain server blocks are touched.
        if path.name in {
            "mime.types", "fastcgi_params", "fastcgi.conf", "uwsgi_params", "scgi_params", "proxy_params"
        }:
            continue
        if strip_host(path, host):
            changed.append(str(path))

    print(f"host={host} keep={keep} changed={len(changed)}")
    for item in changed:
        print(item)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
