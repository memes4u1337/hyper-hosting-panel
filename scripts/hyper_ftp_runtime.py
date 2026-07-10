#!/usr/bin/env python3
"""HYPER-HOST FTP runtime based on pyftpdlib.

This backend intentionally does not depend on /etc/fstab, PAM, /etc/passwd,
or persistent systemd unit files. It reads virtual users from the existing
HYPER-HOST auth text file and per-user local_root configs.
"""
from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import time
from pathlib import Path
from typing import Dict, Tuple

try:
    from pyftpdlib.authorizers import AuthenticationFailed, DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler
    from pyftpdlib.servers import FTPServer
except Exception as exc:  # pragma: no cover - startup diagnostic
    print(f"pyftpdlib import failed: {exc}", file=sys.stderr)
    raise


FULL_PERMS = "elradfmwMT"


class ReloadingAuthorizer(DummyAuthorizer):
    def __init__(self, auth_file: Path, user_conf_dir: Path, default_home: Path):
        super().__init__()
        self.auth_file = auth_file
        self.user_conf_dir = user_conf_dir
        self.default_home = default_home
        self._signature: Tuple[int, int, int, int] | None = None
        self._reloading = False
        self._reload(force=True)

    @staticmethod
    def _stat_signature(path: Path) -> Tuple[int, int]:
        try:
            st = path.stat()
            return st.st_mtime_ns, st.st_size
        except FileNotFoundError:
            return 0, 0

    def _current_signature(self) -> Tuple[int, int, int, int]:
        a_mtime, a_size = self._stat_signature(self.auth_file)
        try:
            c_mtime = self.user_conf_dir.stat().st_mtime_ns
            c_count = sum(1 for p in self.user_conf_dir.iterdir() if p.is_file())
        except FileNotFoundError:
            c_mtime, c_count = 0, 0
        return a_mtime, a_size, c_mtime, c_count

    def _read_pairs(self) -> Dict[str, str]:
        try:
            raw = self.auth_file.read_text(encoding="utf-8", errors="surrogateescape")
        except FileNotFoundError:
            return {}
        # Repair the exact malformed v53 form if it still exists.
        if "\\n" in raw and raw.count("\n") <= 1:
            raw = raw.replace("\\r\\n", "\n").replace("\\n", "\n")
        lines = raw.splitlines()
        result: Dict[str, str] = {}
        for i in range(0, len(lines) - 1, 2):
            username = lines[i].strip()
            password = lines[i + 1]
            if username and password:
                result[username] = password
        return result

    def _local_root(self, username: str) -> Path:
        config = self.user_conf_dir / username
        try:
            for line in config.read_text(encoding="utf-8", errors="ignore").splitlines():
                if line.startswith("local_root="):
                    root = Path(line.split("=", 1)[1].strip()).resolve()
                    if root.exists() and root.is_dir():
                        return root
        except FileNotFoundError:
            pass
        fallback = (self.default_home / username).resolve()
        fallback.mkdir(parents=True, exist_ok=True)
        return fallback

    def _reload(self, force: bool = False) -> None:
        if self._reloading:
            return
        signature = self._current_signature()
        if not force and signature == self._signature:
            return
        self._reloading = True
        try:
            users = self._read_pairs()
            self.user_table.clear()
            for username, password in users.items():
                try:
                    home = self._local_root(username)
                    home.mkdir(parents=True, exist_ok=True)
                    super().add_user(username, password, str(home), perm=FULL_PERMS)
                except Exception as exc:
                    logging.error("Cannot load FTP user %s: %s", username, exc)
            self._signature = signature
            logging.info("Reloaded FTP users: %d", len(self.user_table))
        finally:
            self._reloading = False

    def validate_authentication(self, username, password, handler):
        self._reload()
        try:
            return super().validate_authentication(username, password, handler)
        except AuthenticationFailed:
            # One forced refresh handles a create/password-change that happened
            # within the filesystem timestamp granularity window.
            self._reload(force=True)
            return super().validate_authentication(username, password, handler)

    def has_user(self, username):
        if not self._reloading:
            self._reload()
        return super().has_user(username)

    def get_home_dir(self, username):
        self._reload()
        return super().get_home_dir(username)

    def get_perms(self, username):
        self._reload()
        return super().get_perms(username)

    def get_msg_login(self, username):
        self._reload()
        return super().get_msg_login(username)

    def get_msg_quit(self, username):
        self._reload()
        return super().get_msg_quit(username)


class HyperFTPHandler(FTPHandler):
    permit_foreign_addresses = True
    permit_privileged_ports = False
    use_sendfile = True

    def on_connect(self):
        logging.info("connect remote=%s:%s local=%s:%s", self.remote_ip, self.remote_port, *self.socket.getsockname()[:2])

    def on_login(self, username):
        logging.info("login ok user=%s remote=%s", username, self.remote_ip)

    def on_login_failed(self, username, password):
        logging.warning("login failed user=%s remote=%s", username, self.remote_ip)

    def on_disconnect(self):
        logging.info("disconnect remote=%s", self.remote_ip)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--masquerade", required=True)
    parser.add_argument("--passive-min", type=int, required=True)
    parser.add_argument("--passive-max", type=int, required=True)
    parser.add_argument("--auth-file", required=True)
    parser.add_argument("--user-conf-dir", required=True)
    parser.add_argument("--ftp-dir", required=True)
    parser.add_argument("--banner", default="HYPER-HOST FTP ready")
    parser.add_argument("--log-file", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    log_path = Path(args.log_file)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(log_path, encoding="utf-8"), logging.StreamHandler(sys.stderr)],
    )

    auth_file = Path(args.auth_file)
    user_conf_dir = Path(args.user_conf_dir)
    ftp_dir = Path(args.ftp_dir)
    auth_file.parent.mkdir(parents=True, exist_ok=True)
    user_conf_dir.mkdir(parents=True, exist_ok=True)
    ftp_dir.mkdir(parents=True, exist_ok=True)
    auth_file.touch(exist_ok=True)

    authorizer = ReloadingAuthorizer(auth_file, user_conf_dir, ftp_dir)
    handler = HyperFTPHandler
    handler.authorizer = authorizer
    handler.banner = args.banner
    handler.masquerade_address = args.masquerade
    handler.passive_ports = range(args.passive_min, args.passive_max + 1)
    handler.timeout = 300
    handler.max_login_attempts = 5

    server = FTPServer((args.listen, args.port), handler)
    server.max_cons = 128
    server.max_cons_per_ip = 16

    def stop(_signum, _frame):
        logging.info("shutdown requested")
        server.close_all()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    logging.info(
        "starting HYPER-HOST FTP listen=%s:%d masquerade=%s passive=%d-%d",
        args.listen,
        args.port,
        args.masquerade,
        args.passive_min,
        args.passive_max,
    )
    server.serve_forever(timeout=1, blocking=True, handle_exit=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
