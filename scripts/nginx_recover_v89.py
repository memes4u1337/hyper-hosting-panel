#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import re
import sqlite3
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path
from typing import Iterable

DOMAIN_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")


def valid_domain(value: str) -> bool:
    return bool(DOMAIN_RE.fullmatch((value or "").strip().lower().rstrip(".")))


def valid_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except Exception:
        return False


def uniq(values: Iterable[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for raw in values:
        value = (raw or "").strip().lower().rstrip(".")
        if value and value not in seen:
            seen.add(value)
            out.append(value)
    return out


def split_names(raw: str) -> list[str]:
    return uniq(re.split(r"[\s,;]+", raw or ""))


def extract_server_blocks(text: str) -> list[str]:
    result: list[str] = []
    cursor = 0
    while True:
        match = re.search(r"\bserver\s*\{", text[cursor:], re.I)
        if not match:
            break
        start = cursor + match.start()
        pos = cursor + match.end() - 1
        depth = 0
        quote = ""
        escaped = False
        while pos < len(text):
            char = text[pos]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = ""
            else:
                if char in ("'", '"'):
                    quote = char
                elif char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        result.append(text[start:pos + 1])
                        cursor = pos + 1
                        break
            pos += 1
        else:
            break
    return result


def server_names(text: str) -> list[str]:
    values: list[str] = []
    for match in re.finditer(r"\bserver_name\s+([^;]+);", text, re.I):
        values.extend(match.group(1).split())
    return uniq(values)


def roots(text: str) -> list[str]:
    return [x.strip().strip("\"'") for x in re.findall(r"^[ \t]*root[ \t]+([^;]+);", text, re.I | re.M)]


def php_socket(text: str) -> str:
    match = re.search(r"fastcgi_pass\s+unix:([^;]+);", text, re.I)
    return match.group(1).strip() if match else ""


def current_nginx_text() -> str:
    chunks: list[str] = []
    proc = subprocess.run(["nginx", "-T"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.returncode == 0:
        chunks.append(proc.stdout)
    # HYPER-HOST CLI writes a candidate vhost before reconcile. Read these
    # inactive files too so new aliases/PHP sockets are not lost.
    for pattern in ("/etc/nginx/sites-available/hyper-host-site-*.conf", "/etc/nginx/sites-available/v8*-*.conf"):
        for path in sorted(Path("/").glob(pattern.lstrip("/"))):
            try:
                chunks.append(path.read_text(encoding="utf-8", errors="ignore"))
            except Exception:
                pass
    return "\n".join(chunks)


def all_certificates() -> list[Path]:
    result: list[Path] = []
    for base in (Path("/etc/letsencrypt/live"), Path("/opt/hyper-host/letsencrypt/live")):
        if base.is_dir():
            result.extend(sorted(base.glob("*/fullchain.pem")))
    return result


def cert_matches(cert: Path, host: str) -> bool:
    key = cert.parent / "privkey.pem"
    if not cert.is_file() or not key.is_file():
        return False
    for cmd in (
        ["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "0"],
        ["openssl", "x509", "-in", str(cert), "-noout", "-checkhost", host],
    ):
        if subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            return False
    return True


def choose_cert(host: str, certs: list[Path]) -> tuple[str, str] | None:
    for cert in certs:
        if cert_matches(cert, host):
            return str(cert), str(cert.parent / "privkey.pem")
    return None


def load_db_sites(path: Path) -> dict[str, dict[str, str]]:
    """Read site metadata without ever writing or waiting on the panel DB.

    Nginx reconciliation must remain available even while PHP has an active
    SQLite transaction. Folder names and old vhosts are sufficient fallback
    sources when the DB is temporarily busy.
    """
    result: dict[str, dict[str, str]] = {}
    if not path.is_file():
        return result
    con: sqlite3.Connection | None = None
    try:
        uri = f"file:{path}?mode=ro"
        con = sqlite3.connect(uri, uri=True, timeout=1.0)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA query_only=ON")
        con.execute("PRAGMA busy_timeout=1000")
        columns = {row[1] for row in con.execute("PRAGMA table_info(sites)")}
        if "domain" not in columns:
            return result
        selected = ["domain"] + [name for name in ("aliases", "php_version") if name in columns]
        for row in con.execute(f"SELECT {','.join(selected)} FROM sites"):
            domain = str(row["domain"] or "").strip().lower().rstrip(".")
            if not valid_domain(domain):
                continue
            result[domain] = {
                "aliases": str(row["aliases"] or "") if "aliases" in row.keys() else "",
                "php_version": str(row["php_version"] or "") if "php_version" in row.keys() else "",
            }
    except sqlite3.Error as exc:
        print(f"warning: panel database unavailable during nginx reconcile: {exc}", file=sys.stderr)
    finally:
        if con is not None:
            con.close()
    return result


def collect_old_data(domains: list[str], sites_root: Path, nginx_text: str) -> tuple[dict[str, list[str]], dict[str, str]]:
    aliases = {domain: [] for domain in domains}
    sockets = {domain: "" for domain in domains}
    expected = {domain: str((sites_root / domain / "public_html").resolve(strict=False)) for domain in domains}
    for block in extract_server_blocks(nginx_text):
        block_roots: list[str] = []
        for root in roots(block):
            try:
                block_roots.append(str(Path(root).resolve(strict=False)))
            except Exception:
                block_roots.append(root)
        for domain in domains:
            if expected[domain] not in block_roots:
                continue
            aliases[domain].extend(server_names(block))
            if not sockets[domain]:
                sockets[domain] = php_socket(block)
    return {k: uniq(v) for k, v in aliases.items()}, sockets


def live_socket(version: str, old_socket: str, fallback: str) -> str:
    candidates: list[Path] = []
    if version:
        candidates.append(Path(f"/run/php/php{version.strip()}-fpm.sock"))
    if old_socket:
        candidates.append(Path(old_socket))
    if fallback:
        candidates.append(Path(fallback))
    candidates.extend(sorted(Path("/run/php").glob("php*-fpm.sock"), reverse=True))
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return fallback or "/run/php/php8.2-fpm.sock"


def q(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def php_locations(socket: str, nginx_dir: Path) -> str:
    return f"""
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location ~ \\.php$ {{
        include {nginx_dir}/snippets/fastcgi-php.conf;
        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 21600;
        fastcgi_read_timeout 21600;
        fastcgi_pass unix:{socket};
    }}
    location ~ /\\. {{ deny all; }}
"""


def http_listen(default: bool = False) -> str:
    suffix = " default_server" if default else ""
    return f"listen 80{suffix};\n    listen [::]:80{suffix};"


def https_listen(default: bool = False) -> str:
    suffix = " default_server" if default else ""
    return f"listen 443 ssl http2{suffix};\n    listen [::]:443 ssl http2{suffix};"


def panel_block(names: list[str], root: str, socket: str, nginx_dir: Path, acme_webroot: str, ssl_pair: tuple[str, str] | None = None) -> str:
    ssl = ssl_pair is not None
    listen = https_listen() if ssl else http_listen()
    cert = ""
    if ssl_pair:
        cert = f"\n    ssl_certificate {ssl_pair[0]};\n    ssl_certificate_key {ssl_pair[1]};\n    ssl_protocols TLSv1.2 TLSv1.3;"
    return f"""server {{
    {listen}
    server_name {' '.join(names)};
    root {root};
    index index.php index.html;
    client_max_body_size 8192M;{cert}
    access_log /var/log/nginx/hyper-host-panel.access.log;
    error_log /var/log/nginx/hyper-host-panel.error.log;

    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "PANEL_V89"; }}
    location ^~ /.well-known/acme-challenge/ {{
        root {acme_webroot};
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
    location /phpmyadmin/ {{ alias /usr/share/phpmyadmin/; index index.php index.html; }}
    location ~ ^/phpmyadmin/(.+\\.php)$ {{
        alias /usr/share/phpmyadmin/$1;
        include {nginx_dir}/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 21600;
        fastcgi_read_timeout 21600;
        fastcgi_pass unix:{socket};
    }}
    location ~ ^/phpmyadmin/(.+)$ {{ alias /usr/share/phpmyadmin/$1; }}
{php_locations(socket, nginx_dir)}}}
"""


def site_block(names: list[str], domain: str, root: str, socket: str, logs: str, nginx_dir: Path, acme_webroot: str, ssl_pair: tuple[str, str] | None = None) -> str:
    ssl = ssl_pair is not None
    listen = https_listen() if ssl else http_listen()
    cert = ""
    suffix = "-ssl" if ssl else ""
    if ssl_pair:
        cert = f"\n    ssl_certificate {ssl_pair[0]};\n    ssl_certificate_key {ssl_pair[1]};\n    ssl_protocols TLSv1.2 TLSv1.3;"
    return f"""server {{
    {listen}
    server_name {' '.join(names)};
    root {root};
    index index.html index.htm index.php;
    client_max_body_size 8192M;{cert}
    access_log {logs}/access{suffix}.log;
    error_log {logs}/error{suffix}.log;

    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "SITE_V89:{q(domain)}"; }}
    location ^~ /.well-known/acme-challenge/ {{
        root {acme_webroot};
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
{php_locations(socket, nginx_dir)}}}
"""


def default_block(root: str, cert: str, key: str) -> str:
    return f"""server {{
    {http_listen(default=True)}
    server_name _;
    root {root};
    index index.html;
    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "DEFAULT_V89"; }}
    location / {{ try_files $uri /index.html =404; }}
}}
server {{
    {https_listen(default=True)}
    server_name _;
    root {root};
    index index.html;
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /__hyper_host_v89_route__ {{ default_type text/plain; return 200 "DEFAULT_V89"; }}
    location / {{ try_files $uri /index.html =404; }}
}}
"""


def main_config(nginx_dir: Path) -> str:
    return f"""user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include {nginx_dir}/modules-enabled/*.conf;

events {{
    worker_connections 2048;
    multi_accept on;
}}

http {{
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 300;
    types_hash_max_size 4096;
    server_names_hash_bucket_size 128;
    server_names_hash_max_size 4096;
    client_max_body_size 8192M;
    client_body_timeout 21600s;
    client_header_timeout 300s;
    send_timeout 21600s;

    include {nginx_dir}/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    gzip on;

    include {nginx_dir}/hyper-host-managed/*.conf;
}}
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--panel-domain", required=True)
    parser.add_argument("--lan-ip", required=True)
    parser.add_argument("--public-ip", default="")
    parser.add_argument("--beta-domain", required=True)
    parser.add_argument("--panel-root", default="/var/www/hyper-host/public")
    parser.add_argument("--sites-root", default="/var/www/hyper-host-sites")
    parser.add_argument("--db", default="/opt/hyper-host/data/hyperhost.sqlite")
    parser.add_argument("--panel-php-sock", required=True)
    parser.add_argument("--default-cert", required=True)
    parser.add_argument("--default-key", required=True)
    parser.add_argument("--nginx-dir", default="/etc/nginx")
    parser.add_argument("--acme-webroot", default="/opt/hyper-host/acme-webroot")
    parser.add_argument("--map", required=True)
    args = parser.parse_args()

    panel_domain = args.panel_domain.lower().rstrip(".")
    beta_domain = args.beta_domain.lower().rstrip(".")
    if not valid_domain(panel_domain) or not valid_domain(beta_domain) or panel_domain == beta_domain:
        raise SystemExit("invalid panel/beta domain")
    if not valid_ip(args.lan_ip) or (args.public_ip and not valid_ip(args.public_ip)):
        raise SystemExit("invalid IP")

    panel_root = Path(args.panel_root)
    sites_root = Path(args.sites_root)
    db_path = Path(args.db)
    nginx_dir = Path(args.nginx_dir)
    managed = nginx_dir / "hyper-host-managed"
    panel_root.mkdir(parents=True, exist_ok=True)
    sites_root.mkdir(parents=True, exist_ok=True)
    managed.mkdir(parents=True, exist_ok=True)
    acme_webroot = Path(args.acme_webroot)
    (acme_webroot / ".well-known/acme-challenge").mkdir(parents=True, exist_ok=True)

    old_text = current_nginx_text()
    canonical = sorted({
        folder.name.lower().rstrip(".")
        for folder in sites_root.iterdir()
        if folder.is_dir()
        and valid_domain(folder.name)
        and folder.name.lower().rstrip(".") != panel_domain
        and not (folder / ".hyper-host-disabled").exists()
        and (folder / "public_html").is_dir()
    })
    beta_root = sites_root / beta_domain / "public_html"
    if beta_root.is_dir() and beta_domain not in canonical:
        canonical.append(beta_domain)
        canonical.sort()

    db_sites = load_db_sites(db_path)
    old_aliases, old_sockets = collect_old_data(canonical, sites_root, old_text)
    canonical_set = set(canonical)
    claimed: dict[str, str] = {domain: domain for domain in canonical}
    plans: list[dict[str, object]] = []
    for domain in canonical:
        row = db_sites.get(domain, {})
        candidates = [x for x in split_names(row.get("aliases", "")) if x != panel_domain] + old_aliases.get(domain, [])
        aliases: list[str] = []
        for alias in uniq(candidates):
            if not valid_domain(alias) or alias in {domain, panel_domain} or alias in canonical_set:
                continue
            if alias in claimed and claimed[alias] != domain:
                continue
            claimed[alias] = domain
            aliases.append(alias)
        names = [domain] + aliases
        root = sites_root / domain / "public_html"
        logs = sites_root / domain / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        socket = live_socket(row.get("php_version", ""), old_sockets.get(domain, ""), args.panel_php_sock)
        plans.append({"domain": domain, "names": names, "root": str(root), "logs": str(logs), "socket": socket})

    for old in managed.glob("*.conf"):
        old.unlink(missing_ok=True)

    default_root = Path("/opt/hyper-host/default-site")
    default_root.mkdir(parents=True, exist_ok=True)
    default_index = default_root / "index.html"
    if not default_index.exists():
        default_index.write_text('<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Домен не настроен</title></head><body><h1>Домен не настроен</h1><p>Создай сайт в HYPER-HOST или проверь DNS и имя домена.</p></body></html>', encoding="utf-8")

    (managed / "00-default.conf").write_text(default_block(str(default_root), args.default_cert, args.default_key), encoding="utf-8")
    certs = all_certificates()
    panel_names = uniq([panel_domain, "192.168.0.179", "localhost"])
    panel_names = [x for x in panel_names if valid_domain(x) or valid_ip(x) or x == "localhost"]
    panel_pair = choose_cert(panel_domain, certs)
    panel_text = panel_block(panel_names, str(panel_root), args.panel_php_sock, nginx_dir, str(acme_webroot))
    if panel_pair:
        panel_text += "\n" + panel_block([panel_domain], str(panel_root), args.panel_php_sock, nginx_dir, str(acme_webroot), panel_pair)
    (managed / "10-panel.conf").write_text(panel_text, encoding="utf-8")

    rows: list[str] = []
    for plan in plans:
        domain = str(plan["domain"])
        names = list(plan["names"])  # type: ignore[arg-type]
        root = str(plan["root"])
        logs = str(plan["logs"])
        socket = str(plan["socket"])
        text = site_block(names, domain, root, socket, logs, nginx_dir, str(acme_webroot))
        groups: OrderedDict[tuple[str, str], list[str]] = OrderedDict()
        for host in names:
            pair = choose_cert(host, certs)
            if pair:
                groups.setdefault(pair, []).append(host)
        for pair, ssl_names in groups.items():
            text += "\n" + site_block(ssl_names, domain, root, socket, logs, nginx_dir, str(acme_webroot), pair)
        (managed / f"20-site-{domain}.conf").write_text(text, encoding="utf-8")
        for host in names:
            rows.append(f"{host}\t{domain}\t{root}\t{managed / f'20-site-{domain}.conf'}\n")

    (nginx_dir / "nginx.conf").write_text(main_config(nginx_dir), encoding="utf-8")
    map_path = Path(args.map)
    map_path.parent.mkdir(parents=True, exist_ok=True)
    map_path.write_text("".join(rows), encoding="utf-8")
    print(f"panel={panel_domain} sites={len(plans)} hosts={len(rows)} panel_ssl={'yes' if panel_pair else 'no'} managed={managed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
