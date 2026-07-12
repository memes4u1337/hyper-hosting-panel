#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import os
import re
import sqlite3
import subprocess
from collections import OrderedDict
from pathlib import Path
from typing import Iterable

DOMAIN_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")


def valid_domain(value: str) -> bool:
    return bool(DOMAIN_RE.fullmatch((value or "").strip().rstrip(".")))


def valid_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except Exception:
        return False


def uniq(values: Iterable[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        item = (value or "").strip().lower().rstrip(".")
        if not item or item in seen:
            continue
        seen.add(item)
        result.append(item)
    return result


def parse_aliases(raw: str) -> list[str]:
    return uniq(re.split(r"[\s,;]+", raw or ""))


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def server_names_from_conf(path: Path) -> list[str]:
    text = read_text(path)
    names: list[str] = []
    for match in re.finditer(r"\bserver_name\s+([^;]+);", text, re.I):
        names.extend(match.group(1).split())
    return uniq(names)


def php_socket_from_conf(path: Path) -> str:
    text = read_text(path)
    match = re.search(r"fastcgi_pass\s+unix:([^;]+);", text, re.I)
    return match.group(1).strip() if match else ""


def live_php_socket(version: str, existing: str) -> str:
    candidates: list[Path] = []
    version = (version or "").strip()
    if version:
        candidates.append(Path(f"/run/php/php{version}-fpm.sock"))
    if existing:
        candidates.append(Path(existing))
    candidates.extend(sorted(Path("/run/php").glob("php*-fpm.sock")))
    for candidate in reversed(candidates):
        if candidate.exists():
            return str(candidate)
    return "/run/php/php8.2-fpm.sock"


def cert_matches(cert: Path, host: str) -> bool:
    if not cert.is_file():
        return False
    key = cert.parent / "privkey.pem"
    if not key.is_file():
        return False
    checks = [
        ["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "0"],
        ["openssl", "x509", "-in", str(cert), "-noout", "-checkhost", host],
    ]
    for command in checks:
        try:
            if subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                return False
        except Exception:
            return False
    return True


def all_certificates() -> list[Path]:
    found: list[Path] = []
    for base in (Path("/opt/hyper-host/letsencrypt/live"), Path("/etc/letsencrypt/live")):
        if not base.is_dir():
            continue
        found.extend(sorted(base.glob("*/fullchain.pem")))
    return found


def choose_cert(host: str, certificates: list[Path]) -> tuple[str, str] | None:
    for cert in certificates:
        if cert_matches(cert, host):
            return str(cert), str(cert.parent / "privkey.pem")
    return None


def load_db_sites(db_path: Path) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    if not db_path.is_file():
        return result
    try:
        con = sqlite3.connect(str(db_path))
        con.row_factory = sqlite3.Row
        cols = {row[1] for row in con.execute("PRAGMA table_info(sites)")}
        if not {"domain", "aliases"}.issubset(cols):
            return result
        select = ["domain", "aliases"]
        for optional in ("root_path", "php_version"):
            if optional in cols:
                select.append(optional)
        for row in con.execute(f"SELECT {','.join(select)} FROM sites"):
            domain = str(row["domain"] or "").strip().lower().rstrip(".")
            if not valid_domain(domain):
                continue
            result[domain] = {
                "aliases": str(row["aliases"] or ""),
                "root_path": str(row["root_path"] or "") if "root_path" in row.keys() else "",
                "php_version": str(row["php_version"] or "") if "php_version" in row.keys() else "",
            }
    except Exception:
        pass
    finally:
        try:
            con.close()
        except Exception:
            pass
    return result


def http_server(names: list[str], root: str, php_sock: str, log_base: str) -> str:
    joined = " ".join(names)
    return f"""server {{
    listen 80;
    listen [::]:80;
    server_name {joined};
    root {root};
    index index.html index.htm index.php;
    client_max_body_size 1024M;
    access_log {log_base}/access.log;
    error_log {log_base}/error.log;

    location ^~ /.well-known/acme-challenge/ {{
        root /opt/hyper-host/acme-webroot;
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location ~ \\.php$ {{
        include snippets/fastcgi-php.conf;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:{php_sock};
    }}
    location ~ /\\. {{ deny all; }}
}}
"""


def https_server(names: list[str], root: str, php_sock: str, log_base: str, cert: str, key: str) -> str:
    joined = " ".join(names)
    return f"""server {{
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {joined};
    root {root};
    index index.html index.htm index.php;
    client_max_body_size 1024M;
    access_log {log_base}/ssl-access.log;
    error_log {log_base}/ssl-error.log;
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /.well-known/acme-challenge/ {{
        root /opt/hyper-host/acme-webroot;
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location ~ \\.php$ {{
        include snippets/fastcgi-php.conf;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:{php_sock};
    }}
    location ~ /\\. {{ deny all; }}
}}
"""


def panel_http(names: list[str], root: str, php_sock: str) -> str:
    joined = " ".join(names)
    return f"""server {{
    listen 80;
    listen [::]:80;
    server_name {joined};
    root {root};
    index index.php index.html;
    client_max_body_size 1024M;
    access_log /var/log/nginx/hyper-host-panel.access.log;
    error_log /var/log/nginx/hyper-host-panel.error.log;

    location ^~ /.well-known/acme-challenge/ {{
        root {root};
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location /phpmyadmin {{ alias /usr/share/phpmyadmin/; index index.php index.html; }}
    location ~ ^/phpmyadmin/(.+\\.php)$ {{
        alias /usr/share/phpmyadmin/$1;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:{php_sock};
    }}
    location ~ ^/phpmyadmin/(.+)$ {{ alias /usr/share/phpmyadmin/$1; }}
    location ~ \\.php$ {{
        include snippets/fastcgi-php.conf;
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_connect_timeout 60;
        fastcgi_pass unix:{php_sock};
    }}
    location ~ /\\. {{ deny all; }}
}}
"""


def panel_https(domain: str, root: str, php_sock: str, cert: str, key: str) -> str:
    return f"""server {{
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {domain};
    root {root};
    index index.php index.html;
    client_max_body_size 1024M;
    access_log /var/log/nginx/hyper-host-panel-ssl.access.log;
    error_log /var/log/nginx/hyper-host-panel-ssl.error.log;
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /.well-known/acme-challenge/ {{
        root {root};
        default_type text/plain;
        try_files $uri =404;
        allow all;
    }}
    location / {{ try_files $uri $uri/ /index.php?$query_string; }}
    location /phpmyadmin {{ alias /usr/share/phpmyadmin/; index index.php index.html; }}
    location ~ ^/phpmyadmin/(.+\\.php)$ {{
        alias /usr/share/phpmyadmin/$1;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
        fastcgi_pass unix:{php_sock};
    }}
    location ~ \\.php$ {{ include snippets/fastcgi-php.conf; fastcgi_pass unix:{php_sock}; }}
    location ~ /\\. {{ deny all; }}
}}
"""



def active_config_paths() -> list[Path]:
    """Return concrete config files printed by nginx -T.

    Warnings are intentionally accepted here: v84 is the repair that removes
    duplicate server_name entries before the final nginx -t.
    """
    try:
        proc = subprocess.run(
            ["nginx", "-T"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="ignore",
            check=False,
        )
        output = proc.stdout or ""
    except Exception:
        return []
    result: list[Path] = []
    seen: set[str] = set()
    for line in output.splitlines():
        match = re.match(r"^# configuration file (.+):$", line.strip())
        if not match:
            continue
        raw = match.group(1).strip()
        if not raw.startswith("/etc/nginx/"):
            continue
        if raw in seen:
            continue
        seen.add(raw)
        result.append(Path(raw))
    return result


def normalized_names(path: Path) -> set[str]:
    return {name.lower().rstrip(".") for name in server_names_from_conf(path)}


def strip_managed_names_from_file(path: Path, managed_hosts: set[str]) -> bool:
    """Remove only v84-owned host tokens from an active non-sites config.

    This is used for old panel snippets in conf.d. If a server_name would become
    empty, it receives an impossible .invalid name so the old server block can no
    longer intercept a real domain.
    """
    text = read_text(path)
    if not text:
        return False
    changed = False
    counter = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal changed, counter
        prefix, raw, suffix = match.group(1), match.group(2), match.group(3)
        tokens = raw.split()
        kept = [token for token in tokens if token.lower().rstrip(".") not in managed_hosts]
        if len(kept) == len(tokens):
            return match.group(0)
        changed = True
        counter += 1
        if not kept:
            safe = re.sub(r"[^a-z0-9]+", "-", path.name.lower()).strip("-")[:36] or "config"
            kept = [f"v84-disabled-{safe}-{counter}.invalid"]
        return prefix + " ".join(kept) + suffix

    updated = re.sub(r"(^[ \t]*server_name[ \t]+)([^;]+)(;)", replace, text, flags=re.I | re.M)
    if changed:
        path.write_text(updated, encoding="utf-8")
    return changed


def disable_old_active_routes(enabled: Path, managed_hosts: set[str]) -> list[str]:
    """Disable old active vhosts that own hosts rebuilt by v84.

    We remove only entries from sites-enabled. Their source files and all website
    data remain untouched. The complete /etc/nginx tree is already backed up by
    the installer and can be restored atomically on any failure.
    """
    disabled: list[str] = []
    for entry in sorted(enabled.iterdir() if enabled.is_dir() else []):
        try:
            text_names = normalized_names(entry)
        except Exception:
            text_names = set()
        broken_generated = bool(re.search(
            r"(?:hyper-host-sites-managed|hyper-host-panel|hyper-host-ip-|hyper-host-default|hyper-host-site-)",
            entry.name,
            re.I,
        ))
        if broken_generated or text_names.intersection(managed_hosts):
            try:
                entry.unlink()
                disabled.append(str(entry))
            except FileNotFoundError:
                pass
    return disabled


def sanitize_non_site_active_routes(managed_hosts: set[str]) -> list[str]:
    """Neutralize duplicate managed hosts included outside sites-enabled.

    Old releases could also place a HYPER-HOST default server in conf.d. Such a
    block would collide with the single v84 default_server even when it owns no
    real hostname, so it is made non-default and receives an impossible name.
    """
    changed: list[str] = []
    for path in active_config_paths():
        raw = str(path)
        if raw.startswith("/etc/nginx/sites-enabled/"):
            continue
        if not raw.startswith("/etc/nginx/conf.d/"):
            # Do not rewrite nginx.conf, modules, snippets or package files.
            continue
        touched = False
        if normalized_names(path).intersection(managed_hosts):
            touched = strip_managed_names_from_file(path, managed_hosts) or touched
        text = read_text(path)
        if "hyper-host" in path.name.lower() and ("default_server" in text or re.search(r"\bserver_name\s+_\s*;", text)):
            updated = re.sub(r"\s+default_server\b", "", text)
            updated = re.sub(
                r"(^[ \t]*server_name[ \t]+)_(;)",
                r"\1v84-old-default-disabled.invalid\2",
                updated,
                flags=re.I | re.M,
            )
            if updated != text:
                path.write_text(updated, encoding="utf-8")
                touched = True
        if touched:
            changed.append(raw)
    return changed


def collect_old_route_data(
    canonical: list[str], available: Path, sites_root: Path
) -> tuple[dict[str, list[str]], dict[str, str]]:
    """Collect aliases and PHP sockets from every old config matching a root."""
    names: dict[str, list[str]] = {domain: [] for domain in canonical}
    sockets: dict[str, str] = {domain: "" for domain in canonical}
    candidates = list(available.glob("*.conf")) if available.is_dir() else []
    for domain in canonical:
        expected_root = str(sites_root / domain / "public_html")
        exact = available / f"hyper-host-site-{domain}.conf"
        ordered = ([exact] if exact.exists() else []) + [p for p in candidates if p != exact]
        for conf in ordered:
            text = read_text(conf)
            if not text or not re.search(rf"\broot\s+{re.escape(expected_root)}\s*;", text):
                continue
            for item in server_names_from_conf(conf):
                if item not in names[domain]:
                    names[domain].append(item)
            if not sockets[domain]:
                sockets[domain] = php_socket_from_conf(conf)
    return names, sockets


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--panel-domain", required=True)
    parser.add_argument("--lan-ip", required=True)
    parser.add_argument("--public-ip", default="")
    parser.add_argument("--beta-domain", default="beta.mystockbot.xyz")
    parser.add_argument("--panel-root", default="/var/www/hyper-host/public")
    parser.add_argument("--sites-root", default="/var/www/hyper-host-sites")
    parser.add_argument("--db", default="/opt/hyper-host/data/hyperhost.sqlite")
    parser.add_argument("--panel-php-sock", required=True)
    parser.add_argument("--default-cert", required=True)
    parser.add_argument("--default-key", required=True)
    parser.add_argument("--map", default="/opt/hyper-host/data/v84-routing.tsv")
    parser.add_argument("--cleanup-report", default="/opt/hyper-host/data/v84-nginx-cleanup.txt")
    args = parser.parse_args()

    panel_domain = args.panel_domain.strip().lower().rstrip(".")
    beta_domain = args.beta_domain.strip().lower().rstrip(".")
    sites_root = Path(args.sites_root)
    available = Path("/etc/nginx/sites-available")
    enabled = Path("/etc/nginx/sites-enabled")
    available.mkdir(parents=True, exist_ok=True)
    enabled.mkdir(parents=True, exist_ok=True)
    Path("/opt/hyper-host/acme-webroot/.well-known/acme-challenge").mkdir(parents=True, exist_ok=True)
    Path(args.map).parent.mkdir(parents=True, exist_ok=True)
    Path(args.cleanup_report).parent.mkdir(parents=True, exist_ok=True)

    certificates = all_certificates()
    db_sites = load_db_sites(Path(args.db))

    # Real public_html folders are the source of truth. No website files are created,
    # replaced or removed by this script.
    canonical: list[str] = []
    if sites_root.is_dir():
        for folder in sorted(sites_root.iterdir()):
            if folder.is_dir() and (folder / "public_html").is_dir() and valid_domain(folder.name.lower()):
                canonical.append(folder.name.lower())
    canonical_set = set(canonical)
    if beta_domain not in canonical_set:
        (sites_root / beta_domain / "public_html").mkdir(parents=True, exist_ok=True)
        (sites_root / beta_domain / "logs").mkdir(parents=True, exist_ok=True)
        canonical.append(beta_domain)
        canonical = sorted(set(canonical))
        canonical_set = set(canonical)

    old_names, old_sock = collect_old_route_data(canonical, available, sites_root)

    panel_names = uniq([args.lan_ip, args.public_ip, "localhost", panel_domain])
    panel_names = [name for name in panel_names if valid_domain(name) or valid_ip(name) or name == "localhost"]

    # Build complete plans before touching active links so cleanup knows every host
    # that v84 will own.
    host_owner: dict[str, str] = {domain: domain for domain in canonical}
    site_plans: list[tuple[str, list[str], str, str]] = []
    for domain in canonical:
        root = str(sites_root / domain / "public_html")
        db_row = db_sites.get(domain, {})
        db_aliases = parse_aliases(db_row.get("aliases", ""))
        existing_aliases = [name for name in old_names.get(domain, []) if name != domain]
        aliases = db_aliases if db_aliases else existing_aliases

        cleaned: list[str] = []
        for alias in aliases:
            if not valid_domain(alias):
                continue
            if alias == domain or alias in canonical_set:
                continue
            if alias in {panel_domain, beta_domain}:
                continue
            if alias not in cleaned:
                cleaned.append(alias)

        # beta must serve exactly the files uploaded into its own public_html.
        if domain == beta_domain:
            cleaned = []

        names = [domain]
        for alias in cleaned:
            if alias not in host_owner:
                host_owner[alias] = domain
                names.append(alias)

        php_sock = live_php_socket(db_row.get("php_version", ""), old_sock.get(domain, ""))
        site_plans.append((domain, names, root, php_sock))

    managed_hosts = {
        value.lower().rstrip(".")
        for value in panel_names + [name for _, names, _, _ in site_plans for name in names]
        if value
    }

    # Remove every old active route owning one of our managed hosts, regardless of
    # filename. This is the v83 bug fix: panel.hyper-host.pw could remain in an old
    # site alias config whose filename did not match the previous cleanup patterns.
    disabled = disable_old_active_routes(enabled, managed_hosts)
    sanitized = sanitize_non_site_active_routes(managed_hosts)

    for name in (
        "20-hyper-host-sites-managed.conf",
        "hyper-host-sites-managed.conf",
        "01-hyper-host-panel.conf",
        "10-hyper-host-panel.conf",
    ):
        (available / name).unlink(missing_ok=True)

    # One neutral catch-all. It never serves panel or website content.
    default_root = Path("/opt/hyper-host/default-site")
    default_root.mkdir(parents=True, exist_ok=True)
    (default_root / "index.html").write_text(
        '<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Домен не настроен</title></head>'
        '<body style="font-family:Arial;background:#07101f;color:#fff;display:grid;place-items:center;min-height:100vh">'
        '<main><h1>Домен не настроен</h1><p>Создай сайт в HYPER-HOST или проверь DNS и имя домена.</p></main></body></html>',
        encoding="utf-8",
    )
    default_conf = available / "hyper-host-default.conf"
    default_conf.write_text(
        f"""server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root {default_root};
    index index.html;
    location / {{ try_files $uri /index.html =404; }}
}}
server {{
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    root {default_root};
    index index.html;
    ssl_certificate {args.default_cert};
    ssl_certificate_key {args.default_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {{ try_files $uri /index.html =404; }}
}}
""",
        encoding="utf-8",
    )
    (enabled / "00-hyper-host-default.conf").symlink_to(default_conf)

    # Exactly one panel config owns panel IP/domain names.
    panel_conf_text = panel_http(panel_names, args.panel_root, args.panel_php_sock)
    if valid_domain(panel_domain):
        pair = choose_cert(panel_domain, certificates)
        if pair:
            panel_conf_text += "\n" + panel_https(panel_domain, args.panel_root, args.panel_php_sock, pair[0], pair[1])
    panel_conf = available / "hyper-host-panel.conf"
    panel_conf.write_text(panel_conf_text, encoding="utf-8")
    (enabled / "01-hyper-host-panel.conf").symlink_to(panel_conf)

    routing_rows: list[str] = []
    for domain, names, root, php_sock in site_plans:
        log_base = str(sites_root / domain / "logs")
        Path(log_base).mkdir(parents=True, exist_ok=True)
        Path(root).mkdir(parents=True, exist_ok=True)
        conf_text = http_server(names, root, php_sock, log_base)

        groups: "OrderedDict[tuple[str, str], list[str]]" = OrderedDict()
        for host in names:
            pair = choose_cert(host, certificates)
            if pair:
                groups.setdefault(pair, []).append(host)
        for (cert, key), ssl_names in groups.items():
            conf_text += "\n" + https_server(ssl_names, root, php_sock, log_base, cert, key)

        conf = available / f"hyper-host-site-{domain}.conf"
        conf.write_text(conf_text, encoding="utf-8")
        (enabled / f"20-hyper-host-site-{domain}.conf").symlink_to(conf)
        for host in names:
            routing_rows.append(f"{host}\t{domain}\t{root}\t{conf}\n")

    Path(args.map).write_text("".join(routing_rows), encoding="utf-8")
    Path(args.cleanup_report).write_text(
        "Disabled active routes:\n"
        + ("\n".join(disabled) if disabled else "none")
        + "\n\nSanitized conf.d routes:\n"
        + ("\n".join(sanitized) if sanitized else "none")
        + "\n",
        encoding="utf-8",
    )
    print(
        f"panel={panel_domain} panel_names={','.join(panel_names)} "
        f"sites={len(site_plans)} hosts={len(routing_rows)} disabled={len(disabled)} sanitized={len(sanitized)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
