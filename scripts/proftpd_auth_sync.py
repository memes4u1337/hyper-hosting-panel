#!/usr/bin/env python3
"""Build ProFTPD AuthUserFile/AuthGroupFile from HYPER-HOST virtual users."""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import tempfile
from pathlib import Path

USER_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{1,63}$")


def normalize_pairs(raw: str) -> list[tuple[str, str]]:
    if "\\n" in raw and raw.count("\n") <= 1:
        raw = raw.replace("\\r\\n", "\n").replace("\\n", "\n")
    lines = raw.splitlines()
    result: list[tuple[str, str]] = []
    seen: set[str] = set()
    for i in range(0, len(lines) - 1, 2):
        username = lines[i].strip()
        password = lines[i + 1]
        if not USER_RE.fullmatch(username) or not password or username in seen:
            continue
        seen.add(username)
        result.append((username, password))
    return result


def local_root(conf_dir: Path, ftp_dir: Path, username: str) -> Path:
    candidate: Path | None = None
    conf = conf_dir / username
    try:
        for line in conf.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("local_root="):
                candidate = Path(line.split("=", 1)[1].strip())
                break
    except FileNotFoundError:
        pass
    if candidate is None:
        candidate = ftp_dir / username
    candidate.mkdir(parents=True, exist_ok=True)
    # Не разворачиваем bind-mount/symlink через resolve(): FTP-root должен
    # оставаться путём внутри /var/www/hyper-host-ftp для безопасного chroot.
    absolute = Path(os.path.abspath(candidate))
    allowed = Path(os.path.abspath(ftp_dir))
    try:
        absolute.relative_to(allowed)
    except ValueError as exc:
        raise SystemExit(f"unsafe FTP home for {username}: {absolute}") from exc
    return absolute


def atomic_write(path: Path, data: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--auth-text", required=True)
    parser.add_argument("--user-conf-dir", required=True)
    parser.add_argument("--ftp-dir", required=True)
    parser.add_argument("--passwd-file", required=True)
    parser.add_argument("--group-file", required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--group-name", default="www-data")
    args = parser.parse_args()

    auth_text = Path(args.auth_text)
    conf_dir = Path(args.user_conf_dir)
    ftp_dir = Path(args.ftp_dir)
    passwd_file = Path(args.passwd_file)
    group_file = Path(args.group_file)

    try:
        raw = auth_text.read_text(encoding="utf-8", errors="surrogateescape")
    except FileNotFoundError:
        raw = ""

    pairs = normalize_pairs(raw)
    passwd_lines: list[str] = []
    members: list[str] = []
    for username, password in pairs:
        home = local_root(conf_dir, ftp_dir, username)
        proc = subprocess.run(
            ["openssl", "passwd", "-6", "-stdin"],
            input=password + "\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        hashed = proc.stdout.strip()
        if proc.returncode != 0 or not hashed.startswith("$6$"):
            raise SystemExit(
                f"cannot hash FTP password for {username}: {proc.stderr.strip()}"
            )
        passwd_lines.append(
            f"{username}:{hashed}:{args.uid}:{args.gid}:HYPER-HOST FTP:{home}:/usr/sbin/nologin"
        )
        members.append(username)

    passwd_data = "\n".join(passwd_lines) + ("\n" if passwd_lines else "")
    group_data = f"{args.group_name}:x:{args.gid}:{','.join(members)}\n"
    atomic_write(passwd_file, passwd_data, 0o600)
    atomic_write(group_file, group_data, 0o600)
    print(f"users={len(passwd_lines)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
