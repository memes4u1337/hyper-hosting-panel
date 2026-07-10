#!/usr/bin/env python3
"""HYPER-HOST single-process FTP runtime based on pyftpdlib.

The server listens once on TCP 21 and selects the PASV address per client:
LAN clients receive 192.168.0.179, internet clients receive 90.189.208.25.
Virtual users are reloaded from the HYPER-HOST auth file without PAM,
/etc/passwd, /etc/fstab or persistent writes under /etc.
"""
from __future__ import annotations

import argparse
import ipaddress
import logging
import signal
import sys
from pathlib import Path
from typing import Dict, Tuple

try:
    from pyftpdlib.authorizers import AuthenticationFailed, DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler
    from pyftpdlib.servers import FTPServer
except Exception as exc:  # pragma: no cover
    print(f"pyftpdlib import failed: {exc}", file=sys.stderr)
    raise

FULL_PERMS = "elradfmwMT"
RFC1918 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


def normalize_auth_text(raw: str) -> str:
    """Return canonical USER\nPASSWORD\n pairs and repair old literal \\n data."""
    if "\\n" in raw and raw.count("\n") <= 1:
        raw = raw.replace("\\r\\n", "\n").replace("\\n", "\n")
    lines = raw.splitlines()
    pairs: list[tuple[str, str]] = []
    seen: set[str] = set()
    for index in range(0, len(lines) - 1, 2):
        username = lines[index].strip()
        password = lines[index + 1]
        if not username or not password or username in seen:
            continue
        seen.add(username)
        pairs.append((username, password))
    return "".join(f"{username}\n{password}\n" for username, password in pairs)


def is_lan_client(value: str) -> bool:
    value = value.removeprefix("::ffff:")
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    if address.is_loopback or address.is_link_local:
        return True
    if isinstance(address, ipaddress.IPv4Address):
        return any(address in network for network in RFC1918)
    return address.is_private


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
            stat = path.stat()
            return stat.st_mtime_ns, stat.st_size
        except FileNotFoundError:
            return 0, 0

    def _current_signature(self) -> Tuple[int, int, int, int]:
        auth_mtime, auth_size = self._stat_signature(self.auth_file)
        try:
            conf_mtime = self.user_conf_dir.stat().st_mtime_ns
            conf_count = sum(1 for item in self.user_conf_dir.iterdir() if item.is_file())
        except FileNotFoundError:
            conf_mtime, conf_count = 0, 0
        return auth_mtime, auth_size, conf_mtime, conf_count

    def _read_pairs(self) -> Dict[str, str]:
        try:
            raw = self.auth_file.read_text(encoding="utf-8", errors="surrogateescape")
        except FileNotFoundError:
            return {}
        normalized = normalize_auth_text(raw)
        if normalized != raw:
            self.auth_file.write_text(normalized, encoding="utf-8", errors="surrogateescape")
        lines = normalized.splitlines()
        return {
            lines[index].strip(): lines[index + 1]
            for index in range(0, len(lines) - 1, 2)
            if lines[index].strip() and lines[index + 1]
        }

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
            self._signature = self._current_signature()
            logging.info("Reloaded FTP users: %d", len(self.user_table))
        finally:
            self._reloading = False

    def validate_authentication(self, username, password, handler):
        self._reload()
        try:
            return super().validate_authentication(username, password, handler)
        except AuthenticationFailed:
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
    permit_foreign_addresses = False
    permit_privileged_ports = False
    use_sendfile = True
    lan_ip = "192.168.0.179"
    wan_ip = "90.189.208.25"

    def on_connect(self):
        selected = self.lan_ip if is_lan_client(self.remote_ip) else self.wan_ip
        # PassiveDTP reads the command-channel instance attribute at PASV time.
        self.masquerade_address = selected
        local_ip, local_port = self.socket.getsockname()[:2]
        logging.info(
            "connect remote=%s:%s local=%s:%s pasv_address=%s",
            self.remote_ip,
            self.remote_port,
            local_ip,
            local_port,
            selected,
        )

    def on_login(self, username):
        logging.info("login ok user=%s remote=%s", username, self.remote_ip)

    def on_login_failed(self, username, password):
        logging.warning("login failed user=%s remote=%s", username, self.remote_ip)

    def on_disconnect(self):
        logging.info("disconnect remote=%s", self.remote_ip)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=21)
    parser.add_argument("--lan-ip", required=True)
    parser.add_argument("--wan-ip", required=True)
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
    if not 1 <= args.port <= 65535:
        raise SystemExit("invalid FTP port")
    if not 1 <= args.passive_min <= args.passive_max <= 65535:
        raise SystemExit("invalid passive port range")
    ipaddress.ip_address(args.lan_ip)
    ipaddress.ip_address(args.wan_ip)

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
    handler.lan_ip = args.lan_ip
    handler.wan_ip = args.wan_ip
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
        "starting HYPER-HOST FTP listen=%s:%d lan_ip=%s wan_ip=%s passive=%d-%d",
        args.listen,
        args.port,
        args.lan_ip,
        args.wan_ip,
        args.passive_min,
        args.passive_max,
    )
    server.serve_forever(timeout=1, blocking=True, handle_exit=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
