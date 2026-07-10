#!/usr/bin/env python3
# HYPER-HOST built-in FTP server for FileZilla.
# v43: virtual users without /etc/passwd, /etc/fstab, PAM or vsftpd.
from __future__ import annotations

import argparse
import ipaddress
import os
import posixpath
import signal
import socket
import stat
import sys
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

BASE_DIR = Path(os.environ.get("BASE_DIR", "/opt/hyper-host"))
CONF = Path(os.environ.get("HYPER_HOST_CONF", "/etc/hyper-host/hyper-host.conf"))


def load_shell_conf(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k and k.replace("_", "").isalnum() and k not in os.environ:
            os.environ[k] = v


load_shell_conf(CONF)
BASE_DIR = Path(os.environ.get("BASE_DIR", "/opt/hyper-host"))
FTP_DIR = Path(os.environ.get("FTP_DIR", "/var/www/hyper-host-ftp"))
AUTH_TXT = Path(os.environ.get("FTP_AUTH_TXT", str(BASE_DIR / "data" / "vsftpd_virtual_users.txt")))
USER_CONF_DIR = Path(os.environ.get("FTP_USER_CONF_DIR", str(BASE_DIR / "ftp" / "user_conf")))
LOG_FILE = Path(os.environ.get("HYPER_FTP_LOG", "/var/log/hyper-host-ftp.log"))
PUBLIC_IP_FILE = Path(os.environ.get("HYPER_HOST_PUBLIC_IP_FILE", "/etc/hyper-host/public_ip"))


def is_private_ipv4(ip: str) -> bool:
    if not ip:
        return True
    parts = ip.split(".")
    if len(parts) != 4 or not all(p.isdigit() for p in parts):
        return True
    a, b = int(parts[0]), int(parts[1])
    if a == 10:
        return True
    if a == 192 and b == 168:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 127:
        return True
    if a == 169 and b == 254:
        return True
    return False


def configured_public_ip() -> str:
    # Файл /etc/hyper-host/public_ip обновляется panel'ю "на лету" (hyper public-ip set),
    # а переменные окружения читаются один раз при старте процесса. Поэтому сначала
    # смотрим файл (даёт эффект без перезапуска FTP), и только потом - окружение.
    try:
        ip = PUBLIC_IP_FILE.read_text(encoding="utf-8", errors="ignore").strip()
        if ip and not is_private_ipv4(ip):
            return ip
    except Exception:
        pass
    for key in ("PUBLIC_IP", "SERVER_PUBLIC_IP"):
        ip = (os.environ.get(key) or "").strip()
        if ip and not is_private_ipv4(ip):
            return ip
    return ""




def valid_ipv4(ip: str) -> bool:
    try:
        return ipaddress.ip_address(ip).version == 4
    except ValueError:
        return False


def server_internal_ip() -> str:
    for key in ("SERVER_IP", "DETECTED_INTERNAL_IP"):
        ip = (os.environ.get(key) or "").strip()
        if valid_ipv4(ip) and not ip.startswith("127."):
            return ip
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("1.1.1.1", 53))
            ip = sock.getsockname()[0]
            if valid_ipv4(ip):
                return ip
    except OSError:
        pass
    return ""


def passive_advertised_ip(peer_ip: str, control_local_ip: str) -> str:
    # LAN-клиенту отдаём LAN-IP сервера, интернет-клиенту — реальный внешний IP.
    # Это устраняет зависание LIST/STOR в FileZilla при отсутствии NAT loopback.
    try:
        peer = ipaddress.ip_address(peer_ip)
        peer_is_lan = peer.is_private or peer.is_loopback or peer.is_link_local
    except ValueError:
        peer_is_lan = False
    if peer_is_lan:
        if valid_ipv4(control_local_ip) and control_local_ip not in ("0.0.0.0", "127.0.0.1"):
            return control_local_ip
        return server_internal_ip() or control_local_ip or "127.0.0.1"
    return configured_public_ip() or server_internal_ip() or control_local_ip or "127.0.0.1"

def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass
    try:
        sys.stderr.write(line)
        sys.stderr.flush()
    except Exception:
        pass


class UserStore:
    def __init__(self, auth_txt: Path, conf_dir: Path):
        self.auth_txt = auth_txt
        self.conf_dir = conf_dir
        self._mtime = 0.0
        self._users: Dict[str, str] = {}
        self._lock = threading.Lock()

    def _reload(self) -> None:
        try:
            mtime = self.auth_txt.stat().st_mtime
        except FileNotFoundError:
            mtime = 0.0
        if mtime == self._mtime:
            return
        users: Dict[str, str] = {}
        try:
            lines = self.auth_txt.read_text(encoding="utf-8", errors="ignore").splitlines()
        except FileNotFoundError:
            lines = []
        i = 0
        while i < len(lines):
            u = lines[i].strip()
            p = lines[i + 1] if i + 1 < len(lines) else ""
            if u:
                users[u] = p
            i += 2
        with self._lock:
            self._users = users
            self._mtime = mtime

    def check(self, username: str, password: str) -> bool:
        self._reload()
        with self._lock:
            return self._users.get(username) == password

    def local_root(self, username: str) -> Path:
        cfg = self.conf_dir / username
        root = ""
        if cfg.exists():
            for line in cfg.read_text(encoding="utf-8", errors="ignore").splitlines():
                if line.strip().startswith("local_root="):
                    root = line.split("=", 1)[1].strip()
                    break
        if not root:
            root = str(FTP_DIR / username)
        return Path(root)


class PassiveListener:
    def __init__(self, host: str, min_port: int, max_port: int):
        self.host = host
        self.min_port = min_port
        self.max_port = max_port
        self.sock: Optional[socket.socket] = None
        self.port: Optional[int] = None

    def open(self) -> int:
        self.close()
        last_err: Optional[Exception] = None
        for port in range(self.min_port, self.max_port + 1):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind((self.host, port))
                s.listen(1)
                s.settimeout(20)
                self.sock = s
                self.port = port
                return port
            except Exception as e:
                last_err = e
                try:
                    s.close()
                except Exception:
                    pass
        raise OSError(f"No free passive FTP ports {self.min_port}-{self.max_port}: {last_err}")

    def accept(self) -> socket.socket:
        if not self.sock:
            raise OSError("Passive connection is not opened")
        try:
            conn, _ = self.sock.accept()
            conn.settimeout(60)
            return conn
        finally:
            self.close()

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
        self.sock = None
        self.port = None


class FTPSession(threading.Thread):
    def __init__(self, ctrl: socket.socket, addr: Tuple[str, int], store: UserStore, passive_min: int, passive_max: int):
        super().__init__(daemon=True)
        self.ctrl = ctrl
        self.addr = addr
        self.store = store
        self.passive_min = passive_min
        self.passive_max = passive_max
        self.user: Optional[str] = None
        self.authed = False
        self.root: Optional[Path] = None
        self.cwd = "/"
        self.rename_from: Optional[Path] = None
        self.pasv: Optional[PassiveListener] = None
        self.active_target: Optional[Tuple[str, int]] = None
        self.restart_offset = 0
        self.ctrl_file = self.ctrl.makefile("rwb", buffering=0)

    def send(self, code: int, text: str) -> None:
        line = f"{code} {text}\r\n".encode("utf-8", errors="replace")
        self.ctrl_file.write(line)

    def send_raw(self, text: str) -> None:
        self.ctrl_file.write(text.encode("utf-8", errors="replace"))

    def run(self) -> None:
        try:
            self.ctrl.settimeout(900)
            self.send(220, "HYPER-HOST FTP ready")
            while True:
                raw = self.ctrl_file.readline(8192)
                if not raw:
                    break
                line = raw.decode("utf-8", errors="ignore").rstrip("\r\n")
                if not line:
                    continue
                if " " in line:
                    cmd, arg = line.split(" ", 1)
                    arg = arg.strip()
                else:
                    cmd, arg = line, ""
                cmd = cmd.upper()
                try:
                    if not self.handle(cmd, arg):
                        break
                except Exception as e:
                    log(f"{self.addr[0]} {self.user or '-'} {cmd} error: {e}")
                    self.send(550, f"Operation failed: {e}")
        except Exception as e:
            log(f"session error {self.addr}: {e}")
        finally:
            try:
                if self.pasv:
                    self.pasv.close()
                self.active_target = None
                self.ctrl_file.close()
                self.ctrl.close()
            except Exception:
                pass

    def need_auth(self) -> bool:
        if not self.authed:
            self.send(530, "Login with USER and PASS")
            return False
        return True

    def handle(self, cmd: str, arg: str) -> bool:
        if cmd == "USER":
            self.user = arg
            self.send(331, "Password required")
            return True
        if cmd == "PASS":
            if not self.user:
                self.send(503, "Login with USER first")
                return True
            if self.store.check(self.user, arg):
                self.authed = True
                self.root = self.store.local_root(self.user)
                self.root.mkdir(parents=True, exist_ok=True)
                self.cwd = "/"
                log(f"login ok user={self.user} host={self.addr[0]} root={self.root}")
                self.send(230, "Login successful")
            else:
                log(f"login failed user={self.user} host={self.addr[0]}")
                self.send(530, "Login incorrect")
            return True
        if cmd in {"QUIT", "BYE"}:
            self.send(221, "Bye")
            return False
        if cmd == "AUTH":
            self.send(502, "TLS is disabled. Use plain FTP")
            return True
        if cmd == "FEAT":
            self.send_raw("211-Features:\r\n UTF8\r\n EPSV\r\n PASV\r\n MLST type*;size*;modify*;\r\n MLSD\r\n REST STREAM\r\n211 End\r\n")
            return True
        if cmd == "OPTS":
            self.send(200, "OK")
            return True
        if cmd == "SYST":
            self.send(215, "UNIX Type: L8")
            return True
        if cmd in {"NOOP", "ALLO"}:
            self.send(200, "OK")
            return True
        if cmd in {"TYPE", "MODE", "STRU"}:
            self.send(200, "OK")
            return True
        if not self.need_auth():
            return True
        if cmd == "PWD" or cmd == "XPWD":
            self.send(257, f'"{self.cwd}" is current directory')
        elif cmd == "CWD":
            p = self.vpath(arg or "/")
            rp = self.real(p)
            if rp.is_dir():
                self.cwd = p
                self.send(250, "Directory changed")
            else:
                self.send(550, "Not a directory")
        elif cmd == "CDUP":
            self.cwd = self.vpath("..")
            self.send(250, "Directory changed")
        elif cmd == "PASV":
            self.open_pasv(False)
        elif cmd == "EPSV":
            self.open_pasv(True)
        elif cmd == "PORT":
            self.open_active_port(arg)
        elif cmd == "EPRT":
            self.open_active_eprt(arg)
        elif cmd in {"LIST", "NLST", "MLSD"}:
            self.listing(cmd, arg)
        elif cmd == "SIZE":
            rp = self.real(self.vpath(arg))
            if rp.is_file():
                self.send(213, str(rp.stat().st_size))
            else:
                self.send(550, "File not found")
        elif cmd == "MDTM":
            rp = self.real(self.vpath(arg))
            if rp.exists():
                self.send(213, time.strftime("%Y%m%d%H%M%S", time.gmtime(rp.stat().st_mtime)))
            else:
                self.send(550, "File not found")
        elif cmd == "RETR":
            self.retr(arg)
        elif cmd in {"STOR", "APPE"}:
            self.stor(arg, append=(cmd == "APPE"))
        elif cmd == "DELE":
            rp = self.real(self.vpath(arg))
            if rp.is_file():
                rp.unlink()
                self.send(250, "Deleted")
            else:
                self.send(550, "File not found")
        elif cmd in {"MKD", "XMKD"}:
            rp = self.real_for_create(self.vpath(arg))
            rp.mkdir(parents=True, exist_ok=True)
            self.send(257, f'"{arg}" created')
        elif cmd in {"RMD", "XRMD"}:
            rp = self.real(self.vpath(arg))
            rp.rmdir()
            self.send(250, "Removed")
        elif cmd == "RNFR":
            rp = self.real(self.vpath(arg))
            if rp.exists():
                self.rename_from = rp
                self.send(350, "Ready for RNTO")
            else:
                self.send(550, "File not found")
        elif cmd == "RNTO":
            if not self.rename_from:
                self.send(503, "Use RNFR first")
            else:
                dst = self.real_for_create(self.vpath(arg))
                self.rename_from.rename(dst)
                self.rename_from = None
                self.send(250, "Renamed")
        elif cmd == "REST":
            try:
                self.restart_offset = max(0, int(arg))
                self.send(350, f"Restart position accepted ({self.restart_offset})")
            except ValueError:
                self.send(501, "Invalid restart position")
        else:
            self.send(502, "Command not implemented")
        return True

    def open_pasv(self, epsv: bool) -> None:
        if self.pasv:
            self.pasv.close()
        self.active_target = None
        advertised_ip = passive_advertised_ip(self.addr[0], self.ctrl.getsockname()[0])
        self.pasv = PassiveListener("0.0.0.0", self.passive_min, self.passive_max)
        port = self.pasv.open()
        if epsv:
            self.send(229, f"Entering Extended Passive Mode (|||{port}|)")
        else:
            nums = advertised_ip.split(".")
            if len(nums) != 4:
                nums = ["127", "0", "0", "1"]
            p1, p2 = port // 256, port % 256
            self.send(227, "Entering Passive Mode (%s,%s,%s)" % (",".join(nums), p1, p2))

    def _validate_active_target(self, host: str, port: int) -> None:
        if not valid_ipv4(host) or not 1 <= port <= 65535:
            raise ValueError("Invalid active FTP endpoint")
        # Защита от FTP bounce: data-host обязан совпадать с control-клиентом.
        if host != self.addr[0]:
            raise PermissionError("Active FTP host must match control connection")

    def open_active_port(self, arg: str) -> None:
        parts = arg.split(",")
        if len(parts) != 6 or not all(x.isdigit() for x in parts):
            self.send(501, "Invalid PORT")
            return
        host = ".".join(parts[:4])
        port = int(parts[4]) * 256 + int(parts[5])
        try:
            self._validate_active_target(host, port)
        except Exception as exc:
            self.send(501, str(exc))
            return
        if self.pasv:
            self.pasv.close()
        self.pasv = None
        self.active_target = (host, port)
        self.send(200, "PORT command successful")

    def open_active_eprt(self, arg: str) -> None:
        try:
            delim = arg[0]
            fields = arg.split(delim)
            af, host, port_s = fields[1], fields[2], fields[3]
            if af != "1":
                raise ValueError("Only IPv4 EPRT is supported")
            port = int(port_s)
            self._validate_active_target(host, port)
        except Exception as exc:
            self.send(501, f"Invalid EPRT: {exc}")
            return
        if self.pasv:
            self.pasv.close()
        self.pasv = None
        self.active_target = (host, port)
        self.send(200, "EPRT command successful")

    def data_conn(self) -> socket.socket:
        self.send(150, "Opening data connection")
        if self.pasv:
            return self.pasv.accept()
        if self.active_target:
            host, port = self.active_target
            self.active_target = None
            conn = socket.create_connection((host, port), timeout=20)
            conn.settimeout(60)
            return conn
        raise OSError("Use PASV/EPSV or PORT/EPRT first")

    def vpath(self, arg: str) -> str:
        arg = (arg or "").strip()
        if not arg:
            arg = self.cwd
        if arg.startswith("/"):
            base = arg
        else:
            base = posixpath.join(self.cwd, arg)
        norm = posixpath.normpath(base)
        if norm == ".":
            norm = "/"
        if not norm.startswith("/"):
            norm = "/" + norm
        return norm

    def allowed_roots(self) -> List[Path]:
        assert self.root is not None
        roots: List[Path] = []
        try:
            roots.append(self.root.resolve())
        except Exception:
            roots.append(self.root.absolute())
        try:
            for child in self.root.iterdir():
                if child.is_symlink():
                    try:
                        roots.append(child.resolve())
                    except Exception:
                        pass
        except Exception:
            pass
        return roots

    def _is_allowed(self, path: Path) -> bool:
        try:
            rp = path.resolve(strict=False)
        except Exception:
            rp = path.absolute()
        for root in self.allowed_roots():
            try:
                rp.relative_to(root)
                return True
            except Exception:
                continue
        return False

    def real(self, vpath: str) -> Path:
        assert self.root is not None
        p = self.root / vpath.lstrip("/")
        if not self._is_allowed(p):
            raise PermissionError("Path is outside FTP access")
        return p.resolve(strict=False)

    def real_for_create(self, vpath: str) -> Path:
        assert self.root is not None
        parent_v = posixpath.dirname(vpath) or "/"
        name = posixpath.basename(vpath)
        parent = self.real(parent_v)
        p = parent / name
        if not self._is_allowed(p):
            raise PermissionError("Path is outside FTP access")
        return p

    def format_list(self, p: Path, name: str) -> str:
        try:
            st = p.stat()
            is_dir = stat.S_ISDIR(st.st_mode)
            mode = "d" if is_dir else "-"
            perms = "rwxrwxr-x" if is_dir else "rw-rw-r--"
            dt = time.strftime("%b %d %H:%M", time.localtime(st.st_mtime))
            size = st.st_size
        except Exception:
            mode, perms, dt, size = "d", "rwxrwxr-x", time.strftime("%b %d %H:%M"), 0
        return f"{mode}{perms} 1 owner group {size:>12} {dt} {name}\r\n"

    def format_mlsd(self, p: Path, name: str) -> str:
        try:
            st = p.stat()
            typ = "dir" if p.is_dir() else "file"
            mod = time.strftime("%Y%m%d%H%M%S", time.gmtime(st.st_mtime))
            size = st.st_size
        except Exception:
            typ, mod, size = "dir", time.strftime("%Y%m%d%H%M%S", time.gmtime()), 0
        return f"type={typ};size={size};modify={mod}; {name}\r\n"

    def listing(self, cmd: str, arg: str) -> None:
        p = self.real(self.vpath(arg or self.cwd))
        if p.is_file():
            entries = [(p, p.name)]
        else:
            entries = []
            for child in sorted(p.iterdir(), key=lambda x: x.name.lower()):
                entries.append((child, child.name))
        conn = self.data_conn()
        with conn:
            if cmd == "NLST":
                data = "".join(name + "\r\n" for _, name in entries)
            elif cmd == "MLSD":
                data = "".join(self.format_mlsd(ep, name) for ep, name in entries)
            else:
                data = "".join(self.format_list(ep, name) for ep, name in entries)
            conn.sendall(data.encode("utf-8", errors="replace"))
        self.send(226, "Transfer complete")

    def retr(self, arg: str) -> None:
        rp = self.real(self.vpath(arg))
        if not rp.is_file():
            self.send(550, "File not found")
            return
        conn = self.data_conn()
        with conn, rp.open("rb") as f:
            if self.restart_offset:
                f.seek(self.restart_offset)
            self.restart_offset = 0
            while True:
                chunk = f.read(1024 * 128)
                if not chunk:
                    break
                conn.sendall(chunk)
        self.send(226, "Transfer complete")

    def stor(self, arg: str, append: bool = False) -> None:
        rp = self.real_for_create(self.vpath(arg))
        rp.parent.mkdir(parents=True, exist_ok=True)
        conn = self.data_conn()
        if append:
            mode = "ab"
        elif self.restart_offset and rp.exists():
            mode = "r+b"
        else:
            mode = "wb"
        with conn, rp.open(mode) as f:
            if self.restart_offset and mode == "r+b":
                f.seek(self.restart_offset)
            self.restart_offset = 0
            while True:
                data = conn.recv(1024 * 128)
                if not data:
                    break
                f.write(data)
        try:
            os.chmod(rp, 0o664)
        except Exception:
            pass
        self.send(226, "Transfer complete")


class FTPServer:
    def __init__(self, host: str, port: int, passive_min: int, passive_max: int):
        self.host = host
        self.port = port
        self.passive_min = passive_min
        self.passive_max = passive_max
        self.store = UserStore(AUTH_TXT, USER_CONF_DIR)
        self.stop_event = threading.Event()
        self.sock: Optional[socket.socket] = None

    def serve(self) -> None:
        AUTH_TXT.parent.mkdir(parents=True, exist_ok=True)
        USER_CONF_DIR.mkdir(parents=True, exist_ok=True)
        FTP_DIR.mkdir(parents=True, exist_ok=True)
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.host, self.port))
        s.listen(100)
        s.settimeout(1)
        self.sock = s
        log(f"HYPER-HOST FTP listening on {self.host}:{self.port}, passive {self.passive_min}-{self.passive_max}")
        while not self.stop_event.is_set():
            try:
                conn, addr = s.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            FTPSession(conn, addr, self.store, self.passive_min, self.passive_max).start()
        try:
            s.close()
        except Exception:
            pass

    def stop(self, *_args) -> None:
        self.stop_event.set()
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=21)
    ap.add_argument("--passive-min", type=int, default=40000)
    ap.add_argument("--passive-max", type=int, default=40100)
    args = ap.parse_args()
    server = FTPServer(args.host, args.port, args.passive_min, args.passive_max)
    signal.signal(signal.SIGTERM, server.stop)
    signal.signal(signal.SIGINT, server.stop)
    try:
        server.serve()
        return 0
    except Exception as e:
        log(f"fatal: {e}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
