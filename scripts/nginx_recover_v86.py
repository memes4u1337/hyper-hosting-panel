#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import os
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
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def split_names(raw: str) -> list[str]:
    return uniq(re.split(r"[\s,;]+", raw or ""))


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def server_names(text: str) -> list[str]:
    names: list[str] = []
    for match in re.finditer(r"\bserver_name\s+([^;]+);", text, re.I):
        names.extend(match.group(1).split())
    return uniq(names)


def roots(text: str) -> list[str]:
    return uniq(re.findall(r"^[ \t]*root[ \t]+([^;]+);", text, re.I | re.M))


def php_socket(text: str) -> str:
    match = re.search(r"fastcgi_pass\s+unix:([^;]+);", text, re.I)
    return match.group(1).strip() if match else ""


def live_php_socket(version: str, existing: str, fallback: str) -> str:
    candidates: list[Path] = []
    if version:
        candidates.append(Path(f"/run/php/php{version.strip()}-fpm.sock"))
    if existing:
        candidates.append(Path(existing.strip()))
    if fallback:
        candidates.append(Path(fallback.strip()))
    candidates.extend(sorted(Path("/run/php").glob("php*-fpm.sock")))
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return fallback or "/run/php/php8.2-fpm.sock"


def all_certificates() -> list[Path]:
    result: list[Path] = []
    for base in (Path("/etc/letsencrypt/live"), Path("/opt/hyper-host/letsencrypt/live")):
        if not base.is_dir():
            continue
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
    for command in commands:
        try:
            if subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                return False
        except Exception:
            return False
    return True


def choose_cert(host: str, certificates: list[Path]) -> tuple[str, str] | None:
    for cert in certificates:
        if cert_matches(cert, host):
            return str(cert), str(cert.parent / "privkey.pem")
    return None


def load_db_sites(db_path: Path) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    if not db_path.is_file():
        return result
    con: sqlite3.Connection | None = None
    try:
        con = sqlite3.connect(str(db_path))
        con.row_factory = sqlite3.Row
        columns = {row[1] for row in con.execute("PRAGMA table_info(sites)")}
        if "domain" not in columns:
            return result
        selected = ["domain"]
        for name in ("aliases", "root_path", "php_version"):
            if name in columns:
                selected.append(name)
        for row in con.execute(f"SELECT {','.join(selected)} FROM sites"):
            domain = str(row["domain"] or "").strip().lower().rstrip(".")
            if not valid_domain(domain):
                continue
            result[domain] = {
                "aliases": str(row["aliases"] or "") if "aliases" in row.keys() else "",
                "root_path": str(row["root_path"] or "") if "root_path" in row.keys() else "",
                "php_version": str(row["php_version"] or "") if "php_version" in row.keys() else "",
            }
    except Exception:
        return result
    finally:
        if con is not None:
            con.close()
    return result


def clean_panel_from_db(db_path: Path, panel_domain: str) -> None:
    if not db_path.is_file():
        return
    con: sqlite3.Connection | None = None
    try:
        con = sqlite3.connect(str(db_path))
        columns = {row[1] for row in con.execute("PRAGMA table_info(sites)")}
        if "domain" in columns:
            con.execute("DELETE FROM sites WHERE lower(rtrim(domain,'.'))=?", (panel_domain,))
        if "aliases" in columns:
            rows = con.execute("SELECT rowid, aliases FROM sites").fetchall()
            for rowid, raw in rows:
                aliases = [x for x in split_names(str(raw or "")) if x != panel_domain]
                con.execute("UPDATE sites SET aliases=? WHERE rowid=?", (",".join(aliases), rowid))
        if {row[1] for row in con.execute("PRAGMA table_info(settings)")} >= {"key", "value"}:
            row = con.execute("SELECT 1 FROM settings WHERE key='panel_domain_override' LIMIT 1").fetchone()
            if row:
                con.execute("UPDATE settings SET value=? WHERE key='panel_domain_override'", (panel_domain,))
            else:
                con.execute("INSERT INTO settings(key,value) VALUES('panel_domain_override',?)", (panel_domain,))
        con.commit()
    except Exception:
        if con is not None:
            con.rollback()
    finally:
        if con is not None:
            con.close()


def config_candidates() -> list[Path]:
    found: list[Path] = []
    seen: set[str] = set()
    for pattern in (
        "/etc/nginx/sites-available/*.conf",
        "/etc/nginx/sites-enabled/*",
        "/etc/nginx/conf.d/*.conf",
    ):
        for path in sorted(Path("/").glob(pattern.lstrip("/"))):
            try:
                real = path.resolve(strict=False)
            except Exception:
                real = path
            key = str(real)
            if key in seen or not real.is_file():
                continue
            seen.add(key)
            found.append(real)
    return found


def collect_old_data(site_domains: list[str], sites_root: Path) -> tuple[dict[str, list[str]], dict[str, str]]:
    aliases: dict[str, list[str]] = {domain: [] for domain in site_domains}
    sockets: dict[str, str] = {domain: "" for domain in site_domains}
    files = config_candidates()
    for domain in site_domains:
        expected = str((sites_root / domain / "public_html").resolve())
        for path in files:
            text = read_text(path)
            if not text:
                continue
            file_roots = []
            for root in roots(text):
                try:
                    file_roots.append(str(Path(root).resolve(strict=False)))
                except Exception:
                    file_roots.append(root)
            if expected not in file_roots:
                continue
            aliases[domain].extend(server_names(text))
            if not sockets[domain]:
                sockets[domain] = php_socket(text)
        aliases[domain] = uniq(aliases[domain])
    return aliases, sockets


def disable_active_configs(managed_hosts: set[str], backup_dir: Path) -> list[str]:
    disabled: list[str] = []
    enabled = Path("/etc/nginx/sites-enabled")
    if enabled.is_dir():
        for entry in sorted(enabled.iterdir()):
            text = read_text(entry)
            names = set(server_names(text))
            is_managed = (
                entry.name.startswith("hyper-host")
                or entry.name[:3] in {"00-", "01-", "10-", "20-"} and "hyper-host" in entry.name
                or "/var/www/hyper-host" in text
                or bool(names.intersection(managed_hosts))
                or "default_server" in text
                or re.search(r"\bserver_name\s+_\s*;", text) is not None
            )
            if not is_managed:
                continue
            target = backup_dir / "disabled-sites-enabled" / entry.name
            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                if entry.is_symlink():
                    target.write_text(f"SYMLINK -> {os.readlink(entry)}\n", encoding="utf-8")
                    entry.unlink()
                else:
                    shutil.move(str(entry), str(target))
                disabled.append(str(entry))
            except FileNotFoundError:
                pass

    confd = Path("/etc/nginx/conf.d")
    if confd.is_dir():
        for path in sorted(confd.glob("*.conf")):
            text = read_text(path)
            names = set(server_names(text))
            is_managed = "/var/www/hyper-host" in text or bool(names.intersection(managed_hosts)) or "hyper-host" in path.name.lower()
            if not is_managed:
                continue
            target = backup_dir / "disabled-conf.d" / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(path), str(target))
            disabled.append(str(path))
    return disabled


def write_default_conf(path: Path, root: Path, cert: str, key: str) -> None:
    root.mkdir(parents=True, exist_ok=True)
    index = root / "index.html"
    if not index.exists():
        index.write_text(
            '<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Домен не настроен</title></head>'
            '<body style="font-family:Arial;background:#07101f;color:#fff;display:grid;place-items:center;min-height:100vh">'
            '<main><h1>Домен не настроен</h1><p>Создай сайт в HYPER-HOST или проверь DNS.</p></main></body></html>',
            encoding="utf-8",
        )
    path.write_text(
        f"""server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root {root};
    index index.html;
    location / {{ try_files $uri /index.html =404; }}
}}
server {{
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    root {root};
    index index.html;
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {{ try_files $uri /index.html =404; }}
}}
""",
        encoding="utf-8",
    )


def common_php_locations(sock: str) -> str:
    return f"""
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location ~ \\.php$ {{
        include snippets/fastcgi-php.conf;
        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 600;
        fastcgi_read_timeout 600;
        fastcgi_pass unix:{sock};
    }}
    location ~ /\\. {{ deny all; }}
"""


def panel_block(names: list[str], root: str, sock: str, ssl_pair: tuple[str, str] | None = None) -> str:
    listen = "listen 80;\n    listen [::]:80;"
    ssl = ""
    if ssl_pair:
        listen = "listen 443 ssl http2;\n    listen [::]:443 ssl http2;"
        ssl = f"\n    ssl_certificate {ssl_pair[0]};\n    ssl_certificate_key {ssl_pair[1]};\n    ssl_protocols TLSv1.2 TLSv1.3;"
    joined = " ".join(names)
    return f"""server {{
    {listen}
    server_name {joined};
    root {root};
    index index.php index.html;
    client_max_body_size 1024M;{ssl}

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
        fastcgi_pass unix:{sock};
    }}
    location ~ ^/phpmyadmin/(.+)$ {{ alias /usr/share/phpmyadmin/$1; }}
{common_php_locations(sock)}}}
"""


def site_block(names: list[str], root: str, sock: str, log_dir: str, ssl_pair: tuple[str, str] | None = None) -> str:
    listen = "listen 80;\n    listen [::]:80;"
    suffix = ""
    ssl = ""
    if ssl_pair:
        listen = "listen 443 ssl http2;\n    listen [::]:443 ssl http2;"
        suffix = "-ssl"
        ssl = f"\n    ssl_certificate {ssl_pair[0]};\n    ssl_certificate_key {ssl_pair[1]};\n    ssl_protocols TLSv1.2 TLSv1.3;"
    joined = " ".join(names)
    return f"""server {{
    {listen}
    server_name {joined};
    root {root};
    index index.html index.htm index.php;
    client_max_body_size 1024M;
    access_log {log_dir}/access{suffix}.log;
    error_log {log_dir}/error{suffix}.log;{ssl}

    location ^~ /.well-known/acme-challenge/ {{
        root /opt/hyper-host/acme-webroot;
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
{common_php_locations(sock)}}}
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--panel-domain", default="panel.hyper-host.pw")
    parser.add_argument("--lan-ip", required=True)
    parser.add_argument("--public-ip", default="")
    parser.add_argument("--beta-domain", default="beta.mystockbot.xyz")
    parser.add_argument("--panel-root", default="/var/www/hyper-host/public")
    parser.add_argument("--sites-root", default="/var/www/hyper-host-sites")
    parser.add_argument("--db", default="/opt/hyper-host/data/hyperhost.sqlite")
    parser.add_argument("--panel-php-sock", default="/run/php/php8.2-fpm.sock")
    parser.add_argument("--default-cert", required=True)
    parser.add_argument("--default-key", required=True)
    parser.add_argument("--backup-dir", required=True)
    parser.add_argument("--map", default="/opt/hyper-host/data/v86-routing.tsv")
    parser.add_argument("--cleanup-report", default="/opt/hyper-host/data/v86-nginx-cleanup.txt")
    args = parser.parse_args()

    panel_domain = args.panel_domain.strip().lower().rstrip(".")
    beta_domain = args.beta_domain.strip().lower().rstrip(".")
    if not valid_domain(panel_domain) or not valid_domain(beta_domain):
        raise SystemExit("invalid panel or beta domain")
    if panel_domain == beta_domain:
        raise SystemExit("panel domain and beta domain must differ")

    sites_root = Path(args.sites_root)
    panel_root = Path(args.panel_root)
    available = Path("/etc/nginx/sites-available")
    enabled = Path("/etc/nginx/sites-enabled")
    backup_dir = Path(args.backup_dir)
    for path in (sites_root, panel_root, available, enabled, backup_dir, Path("/opt/hyper-host/acme-webroot/.well-known/acme-challenge")):
        path.mkdir(parents=True, exist_ok=True)

    # beta is the only site folder we create if it is missing; no placeholder files are created.
    (sites_root / beta_domain / "public_html").mkdir(parents=True, exist_ok=True)
    (sites_root / beta_domain / "logs").mkdir(parents=True, exist_ok=True)

    canonical: list[str] = []
    for folder in sorted(sites_root.iterdir()):
        domain = folder.name.strip().lower().rstrip(".")
        if not valid_domain(domain) or domain == panel_domain:
            continue
        if (folder / ".hyper-host-disabled").exists():
            continue
        if (folder / "public_html").is_dir():
            canonical.append(domain)
    canonical = sorted(set(canonical))
    canonical_set = set(canonical)

    db_path = Path(args.db)
    clean_panel_from_db(db_path, panel_domain)
    db_sites = load_db_sites(db_path)
    old_aliases, old_sockets = collect_old_data(canonical, sites_root)

    host_owner: dict[str, str] = {domain: domain for domain in canonical}
    plans: list[dict[str, object]] = []
    for domain in canonical:
        root = sites_root / domain / "public_html"
        log_dir = sites_root / domain / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        db_row = db_sites.get(domain, {})
        candidates = split_names(db_row.get("aliases", "")) + old_aliases.get(domain, [])
        aliases: list[str] = []
        for alias in uniq(candidates):
            if not valid_domain(alias) or alias == domain:
                continue
            if alias in canonical_set or alias == panel_domain:
                continue
            if alias in host_owner and host_owner[alias] != domain:
                continue
            host_owner[alias] = domain
            aliases.append(alias)
        # beta must never inherit a stale alias that points somewhere unexpected.
        if domain == beta_domain:
            aliases = [alias for alias in aliases if alias in split_names(db_row.get("aliases", ""))]
        names = [domain] + aliases
        sock = live_php_socket(db_row.get("php_version", ""), old_sockets.get(domain, ""), args.panel_php_sock)
        plans.append({"domain": domain, "names": names, "root": str(root), "log": str(log_dir), "sock": sock})

    panel_names = uniq([panel_domain, args.lan_ip, args.public_ip, "localhost"])
    panel_names = [x for x in panel_names if valid_domain(x) or valid_ip(x) or x == "localhost"]
    managed_hosts = set(panel_names)
    for plan in plans:
        managed_hosts.update(plan["names"])  # type: ignore[arg-type]

    disabled = disable_active_configs(managed_hosts, backup_dir)

    # Remove stale generated available files. Website data is never touched.
    for pattern in (
        "hyper-host-panel.conf",
        "hyper-host-default.conf",
        "hyper-host-sites-managed.conf",
        "20-hyper-host-sites-managed.conf",
        "hyper-host-site-*.conf",
    ):
        for path in available.glob(pattern):
            path.unlink(missing_ok=True)

    default_conf = available / "hyper-host-default.conf"
    write_default_conf(default_conf, Path("/opt/hyper-host/default-site"), args.default_cert, args.default_key)
    (enabled / "00-hyper-host-default.conf").symlink_to(default_conf)

    certificates = all_certificates()
    panel_pair = choose_cert(panel_domain, certificates)
    panel_conf = available / "hyper-host-panel.conf"
    panel_text = panel_block(panel_names, str(panel_root), args.panel_php_sock)
    if panel_pair:
        panel_text += "\n" + panel_block([panel_domain], str(panel_root), args.panel_php_sock, panel_pair)
    panel_conf.write_text(panel_text, encoding="utf-8")
    (enabled / "01-hyper-host-panel.conf").symlink_to(panel_conf)

    routing_rows: list[str] = []
    for plan in plans:
        domain = str(plan["domain"])
        names = list(plan["names"])  # type: ignore[arg-type]
        root = str(plan["root"])
        log_dir = str(plan["log"])
        sock = str(plan["sock"])
        text = site_block(names, root, sock, log_dir)
        groups: "OrderedDict[tuple[str, str], list[str]]" = OrderedDict()
        for host in names:
            pair = choose_cert(host, certificates)
            if pair:
                groups.setdefault(pair, []).append(host)
        for pair, ssl_names in groups.items():
            text += "\n" + site_block(ssl_names, root, sock, log_dir, pair)
        conf = available / f"hyper-host-site-{domain}.conf"
        conf.write_text(text, encoding="utf-8")
        (enabled / f"20-hyper-host-site-{domain}.conf").symlink_to(conf)
        for host in names:
            routing_rows.append(f"{host}\t{domain}\t{root}\t{conf}\n")

    Path(args.map).parent.mkdir(parents=True, exist_ok=True)
    Path(args.map).write_text("".join(routing_rows), encoding="utf-8")
    Path(args.cleanup_report).write_text(
        "Disabled old active configs:\n" + ("\n".join(disabled) if disabled else "none") +
        f"\n\nPanel domain: {panel_domain}\nPanel root: {panel_root}\nSites: {len(plans)}\nHosts: {len(routing_rows)}\n",
        encoding="utf-8",
    )
    print(f"panel={panel_domain} panel_root={panel_root} sites={len(plans)} hosts={len(routing_rows)} disabled={len(disabled)} panel_ssl={'yes' if panel_pair else 'no'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
