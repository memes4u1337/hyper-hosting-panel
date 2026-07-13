#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import re
import shutil
import sqlite3
import subprocess
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
    result: list[str] = []
    seen: set[str] = set()
    for raw in values:
        value = (raw or "").strip().lower().rstrip(".")
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


def split_names(raw: str) -> list[str]:
    return uniq(re.split(r"[\s,;]+", raw or ""))


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


def nginx_sections() -> OrderedDict[str, str]:
    proc = subprocess.run(["nginx", "-T"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stdout.strip() or "nginx -T failed")
    result: OrderedDict[str, str] = OrderedDict()
    current: str | None = None
    buffer: list[str] = []
    for line in proc.stdout.splitlines(keepends=True):
        marker = re.match(r"# configuration file (.+):\s*$", line.rstrip("\n"))
        if marker:
            if current is not None:
                result[current] = "".join(buffer)
            current = marker.group(1)
            buffer = []
        elif current is not None:
            buffer.append(line)
    if current is not None:
        result[current] = "".join(buffer)
    return result


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
    commands = (
        ["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "0"],
        ["openssl", "x509", "-in", str(cert), "-noout", "-checkhost", host],
    )
    return all(subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0 for cmd in commands)


def choose_cert(host: str, certificates: list[Path]) -> tuple[str, str] | None:
    for cert in certificates:
        if cert_matches(cert, host):
            return str(cert), str(cert.parent / "privkey.pem")
    return None


def load_db_sites(path: Path) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    if not path.is_file():
        return result
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(str(path))
        connection.row_factory = sqlite3.Row
        columns = {row[1] for row in connection.execute("PRAGMA table_info(sites)")}
        if "domain" not in columns:
            return result
        selected = ["domain"] + [name for name in ("aliases", "php_version") if name in columns]
        for row in connection.execute(f"SELECT {','.join(selected)} FROM sites"):
            domain = str(row["domain"] or "").strip().lower().rstrip(".")
            if not valid_domain(domain):
                continue
            result[domain] = {
                "aliases": str(row["aliases"] or "") if "aliases" in row.keys() else "",
                "php_version": str(row["php_version"] or "") if "php_version" in row.keys() else "",
            }
    except Exception:
        return result
    finally:
        if connection is not None:
            connection.close()
    return result


def clean_panel_from_db(path: Path, panel_domain: str) -> None:
    if not path.is_file():
        return
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(str(path))
        columns = {row[1] for row in connection.execute("PRAGMA table_info(sites)")}
        if "domain" in columns:
            connection.execute("DELETE FROM sites WHERE lower(rtrim(domain,'.'))=?", (panel_domain,))
        if "aliases" in columns:
            for rowid, raw in connection.execute("SELECT rowid, aliases FROM sites").fetchall():
                aliases = [x for x in split_names(str(raw or "")) if x != panel_domain]
                connection.execute("UPDATE sites SET aliases=? WHERE rowid=?", (",".join(aliases), rowid))
        connection.commit()
    except Exception:
        if connection is not None:
            connection.rollback()
    finally:
        if connection is not None:
            connection.close()


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


def collect_old_data(domains: list[str], sites_root: Path, sections: OrderedDict[str, str]) -> tuple[dict[str, list[str]], dict[str, str]]:
    aliases = {domain: [] for domain in domains}
    sockets = {domain: "" for domain in domains}
    expected = {domain: str((sites_root / domain / "public_html").resolve(strict=False)) for domain in domains}
    for text in sections.values():
        for block in extract_server_blocks(text):
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
    return {key: uniq(value) for key, value in aliases.items()}, sockets


def sanitize_active_sources(sections: OrderedDict[str, str], managed_hosts: set[str], backup_dir: Path, report_path: Path) -> None:
    changed: list[str] = []
    processed: set[str] = set()
    for source in sections.keys():
        source_path = Path(source)
        if not str(source_path).startswith("/etc/nginx/"):
            continue
        if source_path.name in {"nginx.conf", "mime.types", "fastcgi_params", "fastcgi.conf"}:
            continue
        try:
            real = source_path.resolve(strict=True)
        except Exception:
            continue
        if str(real) in processed or not real.is_file():
            continue
        processed.add(str(real))
        original = real.read_text(encoding="utf-8", errors="ignore")
        if "server_name" not in original:
            continue
        counter = 0
        did_change = False

        def replace(match: re.Match[str]) -> str:
            nonlocal counter, did_change
            counter += 1
            names = match.group(1).split()
            kept = [name for name in names if name.lower().rstrip(".") not in managed_hosts]
            if len(kept) == len(names):
                return match.group(0)
            did_change = True
            if not kept:
                digest = hashlib.sha1(f"{real}:{counter}".encode()).hexdigest()[:12]
                kept = [f"disabled-{digest}.invalid"]
            return "server_name " + " ".join(kept) + ";"

        updated = re.sub(r"server_name\s+([^;]+);", replace, original, flags=re.I)
        if "default_server" in updated and ("/var/www/hyper-host" in updated or "/opt/hyper-host/default-site" in updated or "hyper-host" in real.name.lower()):
            cleaned = re.sub(r"[ \t]+default_server\b", "", updated)
            if cleaned != updated:
                updated = cleaned
                did_change = True
        if not did_change:
            continue
        backup_name = str(real).lstrip("/").replace("/", "__")
        backup_file = backup_dir / "sanitized" / backup_name
        backup_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(real, backup_file)
        real.write_text(updated, encoding="utf-8")
        changed.append(f"{source} -> {real}")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("Sanitized active sources:\n" + ("\n".join(changed) if changed else "none") + "\n", encoding="utf-8")


def php_locations(socket: str) -> str:
    return f"""
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location ~ \\.php$ {{
        include snippets/fastcgi-php.conf;
        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 600;
        fastcgi_read_timeout 600;
        fastcgi_pass unix:{socket};
    }}
    location ~ /\\. {{ deny all; }}
"""


def listen_lines(ip: str, port: int, ssl: bool = False, default: bool = False) -> str:
    flags: list[str] = []
    if ssl:
        flags.append("ssl")
    if default:
        flags.append("default_server")
    suffix = " " + " ".join(flags) if flags else ""
    return f"listen {ip}:{port}{suffix};\n    listen 127.0.0.1:{port}{suffix};"


def panel_block(names: list[str], root: str, socket: str, lan_ip: str, ssl_pair: tuple[str, str] | None = None) -> str:
    ssl = ssl_pair is not None
    port = 443 if ssl else 80
    certificate = ""
    if ssl_pair:
        certificate = f"\n    ssl_certificate {ssl_pair[0]};\n    ssl_certificate_key {ssl_pair[1]};\n    ssl_protocols TLSv1.2 TLSv1.3;"
    return f"""server {{
    {listen_lines(lan_ip, port, ssl=ssl)}
    server_name {' '.join(names)};
    root {root};
    index index.php index.html;
    client_max_body_size 1024M;{certificate}
    access_log /var/log/nginx/hyper-host-panel.access.log;
    error_log /var/log/nginx/hyper-host-panel.error.log;

    location ^~ /.well-known/acme-challenge/ {{
        root /opt/hyper-host/acme-webroot;
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
    location /phpmyadmin {{ alias /usr/share/phpmyadmin/; index index.php index.html; }}
    location ~ ^/phpmyadmin/(.+\\.php)$ {{
        alias /usr/share/phpmyadmin/$1;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
        fastcgi_pass unix:{socket};
    }}
    location ~ ^/phpmyadmin/(.+)$ {{ alias /usr/share/phpmyadmin/$1; }}
{php_locations(socket)}}}
"""


def site_block(names: list[str], root: str, socket: str, log_dir: str, lan_ip: str, ssl_pair: tuple[str, str] | None = None) -> str:
    ssl = ssl_pair is not None
    port = 443 if ssl else 80
    suffix = "-ssl" if ssl else ""
    certificate = ""
    if ssl_pair:
        certificate = f"\n    ssl_certificate {ssl_pair[0]};\n    ssl_certificate_key {ssl_pair[1]};\n    ssl_protocols TLSv1.2 TLSv1.3;"
    return f"""server {{
    {listen_lines(lan_ip, port, ssl=ssl)}
    server_name {' '.join(names)};
    root {root};
    index index.html index.htm index.php;
    client_max_body_size 1024M;{certificate}
    access_log {log_dir}/access{suffix}.log;
    error_log {log_dir}/error{suffix}.log;

    location ^~ /.well-known/acme-challenge/ {{
        root /opt/hyper-host/acme-webroot;
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
{php_locations(socket)}}}
"""


def default_block(root: str, certificate: str, key: str, lan_ip: str) -> str:
    return f"""server {{
    {listen_lines(lan_ip, 80, default=True)}
    server_name _;
    root {root};
    index index.html;
    location / {{ try_files $uri /index.html =404; }}
}}
server {{
    {listen_lines(lan_ip, 443, ssl=True, default=True)}
    server_name _;
    root {root};
    index index.html;
    ssl_certificate {certificate};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {{ try_files $uri /index.html =404; }}
}}
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--panel-domain", required=True)
    parser.add_argument("--lan-ip", required=True)
    parser.add_argument("--public-ip", default="")
    parser.add_argument("--beta-domain", required=True)
    parser.add_argument("--panel-root", required=True)
    parser.add_argument("--sites-root", default="/var/www/hyper-host-sites")
    parser.add_argument("--db", default="/opt/hyper-host/data/hyperhost.sqlite")
    parser.add_argument("--panel-php-sock", required=True)
    parser.add_argument("--default-cert", required=True)
    parser.add_argument("--default-key", required=True)
    parser.add_argument("--backup-dir", required=True)
    parser.add_argument("--map", required=True)
    parser.add_argument("--cleanup-report", required=True)
    parser.add_argument("--skip-sanitize", action="store_true")
    args = parser.parse_args()

    panel_domain = args.panel_domain.lower().rstrip(".")
    beta_domain = args.beta_domain.lower().rstrip(".")
    if not valid_domain(panel_domain) or not valid_domain(beta_domain) or panel_domain == beta_domain or not valid_ip(args.lan_ip):
        raise SystemExit("invalid domain/ip arguments")

    panel_root = Path(args.panel_root)
    sites_root = Path(args.sites_root)
    db_path = Path(args.db)
    available = Path("/etc/nginx/sites-available")
    enabled = Path("/etc/nginx/sites-enabled")
    backup_dir = Path(args.backup_dir)
    for path in (panel_root, sites_root, available, enabled, backup_dir, Path("/opt/hyper-host/acme-webroot/.well-known/acme-challenge")):
        path.mkdir(parents=True, exist_ok=True)

    (sites_root / beta_domain / "public_html").mkdir(parents=True, exist_ok=True)
    (sites_root / beta_domain / "logs").mkdir(parents=True, exist_ok=True)

    sections = nginx_sections()
    canonical = sorted({
        folder.name.lower().rstrip(".")
        for folder in sites_root.iterdir()
        if folder.is_dir()
        and valid_domain(folder.name)
        and folder.name.lower().rstrip(".") != panel_domain
        and not (folder / ".hyper-host-disabled").exists()
        and (folder / "public_html").is_dir()
    })

    clean_panel_from_db(db_path, panel_domain)
    db_sites = load_db_sites(db_path)
    old_aliases, old_sockets = collect_old_data(canonical, sites_root, sections)

    canonical_set = set(canonical)
    owner: dict[str, str] = {domain: domain for domain in canonical}
    plans: list[dict[str, object]] = []
    for domain in canonical:
        db_row = db_sites.get(domain, {})
        candidates = split_names(db_row.get("aliases", "")) + old_aliases.get(domain, [])
        aliases: list[str] = []
        for alias in uniq(candidates):
            if not valid_domain(alias) or alias == domain or alias == panel_domain or alias in canonical_set:
                continue
            if alias in owner and owner[alias] != domain:
                continue
            owner[alias] = domain
            aliases.append(alias)
        names = [domain] + aliases
        root = sites_root / domain / "public_html"
        log_dir = sites_root / domain / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        socket = live_socket(db_row.get("php_version", ""), old_sockets.get(domain, ""), args.panel_php_sock)
        plans.append({"domain": domain, "names": names, "root": str(root), "log": str(log_dir), "socket": socket})

    panel_names = uniq([panel_domain, args.lan_ip, args.public_ip, "localhost"])
    panel_names = [name for name in panel_names if valid_domain(name) or valid_ip(name) or name == "localhost"]
    managed_hosts = set(panel_names)
    for plan in plans:
        managed_hosts.update(plan["names"])  # type: ignore[arg-type]

    if not args.skip_sanitize:
        sanitize_active_sources(sections, managed_hosts, backup_dir, Path(args.cleanup_report))

    for entry in list(enabled.iterdir()):
        if entry.name.startswith(("00-hyper-host", "01-hyper-host", "10-hyper-host", "20-hyper-host", "hyper-host-site-", "hyper-host-panel", "hyper-host-default", "hyper-host-ip-")):
            entry.unlink(missing_ok=True)
    for path in available.glob("v87-*.conf"):
        path.unlink(missing_ok=True)

    default_root = Path("/opt/hyper-host/default-site")
    default_root.mkdir(parents=True, exist_ok=True)
    default_index = default_root / "index.html"
    if not default_index.exists():
        default_index.write_text('<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Домен не настроен</title></head><body><h1>Домен не настроен</h1></body></html>', encoding="utf-8")

    default_conf = available / "v87-00-default.conf"
    default_conf.write_text(default_block(str(default_root), args.default_cert, args.default_key, args.lan_ip), encoding="utf-8")
    (enabled / "00-hyper-host-v87-default.conf").symlink_to(default_conf)

    certificates = all_certificates()
    panel_pair = choose_cert(panel_domain, certificates)
    panel_conf = available / "v87-10-panel.conf"
    panel_text = panel_block(panel_names, str(panel_root), args.panel_php_sock, args.lan_ip)
    if panel_pair:
        panel_text += "\n" + panel_block([panel_domain], str(panel_root), args.panel_php_sock, args.lan_ip, panel_pair)
    panel_conf.write_text(panel_text, encoding="utf-8")
    (enabled / "10-hyper-host-v87-panel.conf").symlink_to(panel_conf)

    routing_rows: list[str] = []
    for plan in plans:
        domain = str(plan["domain"])
        names = list(plan["names"])  # type: ignore[arg-type]
        root = str(plan["root"])
        log_dir = str(plan["log"])
        socket = str(plan["socket"])
        text = site_block(names, root, socket, log_dir, args.lan_ip)
        certificate_groups: OrderedDict[tuple[str, str], list[str]] = OrderedDict()
        for host in names:
            pair = choose_cert(host, certificates)
            if pair:
                certificate_groups.setdefault(pair, []).append(host)
        for pair, ssl_names in certificate_groups.items():
            text += "\n" + site_block(ssl_names, root, socket, log_dir, args.lan_ip, pair)
        config = available / f"v87-20-site-{domain}.conf"
        config.write_text(text, encoding="utf-8")
        (enabled / f"20-hyper-host-v87-site-{domain}.conf").symlink_to(config)
        for host in names:
            routing_rows.append(f"{host}\t{domain}\t{root}\t{config}\n")

    map_path = Path(args.map)
    map_path.parent.mkdir(parents=True, exist_ok=True)
    map_path.write_text("".join(routing_rows), encoding="utf-8")
    print(f"panel={panel_domain} lan={args.lan_ip} sites={len(plans)} hosts={len(routing_rows)} panel_ssl={'yes' if panel_pair else 'no'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
