#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any

BASE = Path('/opt/hyper-host/deploy-center')
CONFIG_PATH = BASE / 'config.json'
CACHE_PATH = BASE / 'telegram-cache.json'
MASTER_DIR = Path('/var/www/hyper-host-deploy/master')
TEMPLATE_DIR = Path('/var/www/hyper-host-deploy/template')
MANAGED_DIR = Path('/var/www/hyper-host-managed-bots')
BOT_HOME = Path('/var/www/hyper-host-bots')
PM2_HOME = BOT_HOME / '.pm2'
BOT_USER = 'hyperbot'

DEFAULT_CONFIG = {
    'db_host': '90.189.208.25',
    'db_port': 3306,
    'db_user': 'mystock',
    'db_pass': '',
    'db_name': 'mystock',
    'master_project_id': 0,
    'poll_sec': 3,
    'gc_sec': 15,
}


def out(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=None))


def fail(message: str, code: int = 1) -> None:
    out({'ok': False, 'error': message})
    raise SystemExit(code)


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text('utf-8'))
    except Exception:
        return default


def load_config() -> dict[str, Any]:
    cfg = DEFAULT_CONFIG.copy()
    cfg.update(load_json(CONFIG_PATH, {}))
    cfg['db_port'] = int(cfg.get('db_port') or 3306)
    cfg['master_project_id'] = int(cfg.get('master_project_id') or 0)
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    BASE.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_PATH.with_suffix('.tmp')
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), 'utf-8')
    os.chmod(tmp, 0o600)
    tmp.replace(CONFIG_PATH)


def ensure_dirs() -> None:
    for p in (BASE, MASTER_DIR, TEMPLATE_DIR, MANAGED_DIR, BOT_HOME, PM2_HOME):
        p.mkdir(parents=True, exist_ok=True)
    subprocess.run(['chown', '-R', f'{BOT_USER}:www-data', str(MASTER_DIR.parent), str(MANAGED_DIR), str(BOT_HOME)], check=False)
    subprocess.run(['chmod', '2775', str(MASTER_DIR.parent), str(TEMPLATE_DIR), str(MANAGED_DIR), str(BOT_HOME), str(PM2_HOME)], check=False)


def connect_db():
    cfg = load_config()
    if not cfg.get('db_pass'):
        raise RuntimeError('Пароль MySQL не задан в настройках Deploy Center')
    try:
        import pymysql
    except Exception as exc:
        raise RuntimeError('PyMySQL не установлен в Deploy Center venv') from exc
    return pymysql.connect(
        host=str(cfg['db_host']), port=int(cfg['db_port']), user=str(cfg['db_user']),
        password=str(cfg['db_pass']), database=str(cfg['db_name']), charset='utf8mb4',
        autocommit=True, cursorclass=pymysql.cursors.DictCursor, connect_timeout=8,
        read_timeout=15, write_timeout=15,
    )


def slugify(value: str) -> str:
    value = (value or '').strip().lower()
    value = re.sub(r'[^a-z0-9а-яё._-]+', '-', value, flags=re.I)
    value = re.sub(r'-+', '-', value).strip('-._')
    return (value[:64] or 'project')


def token_fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()[:16]


def telegram_getme(token: str) -> dict[str, Any]:
    if not re.match(r'^\d+:[A-Za-z0-9_-]{20,}$', token or ''):
        return {'ok': False, 'error': 'invalid token'}
    cache = load_json(CACHE_PATH, {})
    fp = token_fingerprint(token)
    cached = cache.get(fp)
    if isinstance(cached, dict) and time.time() - float(cached.get('_at', 0)) < 86400:
        return cached
    try:
        with urllib.request.urlopen(f'https://api.telegram.org/bot{token}/getMe', timeout=8) as r:
            data = json.loads(r.read().decode('utf-8', 'ignore'))
        result = data.get('result') or {}
        item = {
            'ok': bool(data.get('ok')),
            'id': result.get('id'),
            'username': result.get('username') or '',
            'first_name': result.get('first_name') or '',
            '_at': time.time(),
        }
    except Exception as exc:
        item = {'ok': False, 'error': str(exc), '_at': time.time()}
    cache[fp] = item
    BASE.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.write_text(json.dumps(cache, ensure_ascii=False, indent=2), 'utf-8')
    os.chmod(CACHE_PATH, 0o600)
    return item


def query_projects() -> list[dict[str, Any]]:
    sql = """
        SELECT
          p.id AS project_id,
          p.user_id AS owner_user_id,
          p.project_name,
          p.bot_token,
          p.updated_at AS project_updated_at,
          u.tg_id AS owner_tg_id,
          u.username AS owner_username,
          u.first_name AS owner_first_name,
          u.last_name AS owner_last_name,
          u.subscription_status,
          u.bot_active,
          d.pm2_name AS sql_pm2_name,
          d.deploy_path AS sql_deploy_path,
          d.status AS sql_status,
          d.last_error AS sql_last_error,
          d.updated_at AS deployment_updated_at
        FROM projects p
        JOIN users u ON u.id = p.user_id
        LEFT JOIN bot_deployments d ON d.project_id = p.id
        WHERE p.bot_token IS NOT NULL AND TRIM(p.bot_token) <> ''
        ORDER BY p.id DESC
    """
    with connect_db() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return list(cur.fetchall())


def pm2_env() -> dict[str, str]:
    env = os.environ.copy()
    env.update({'HOME': str(BOT_HOME), 'PM2_HOME': str(PM2_HOME), 'PATH': '/usr/local/bin:/usr/bin:/bin'})
    return env


def run_as_bot(args: list[str], cwd: Path | None = None, timeout: int = 600, check: bool = False) -> subprocess.CompletedProcess[str]:
    cmd = ['sudo', '-u', BOT_USER, '-H', 'env', f'HOME={BOT_HOME}', f'PM2_HOME={PM2_HOME}', 'PATH=/usr/local/bin:/usr/bin:/bin', *args]
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, check=check)


def pm2_map() -> dict[str, dict[str, Any]]:
    try:
        cp = run_as_bot(['pm2', 'jlist'], timeout=20)
        data = json.loads(cp.stdout or '[]') if cp.returncode == 0 else []
    except Exception:
        data = []
    result = {}
    for item in data:
        env = item.get('pm2_env') or {}
        result[str(item.get('name') or '')] = {
            'status': env.get('status') or 'unknown',
            'pid': item.get('pid') or 0,
            'memory': (item.get('monit') or {}).get('memory') or 0,
            'cpu': (item.get('monit') or {}).get('cpu') or 0,
            'restarts': env.get('restart_time') or 0,
        }
    return result


def project_identity(row: dict[str, Any]) -> tuple[str, Path]:
    project_id = int(row['project_id'])
    slug = slugify(str(row.get('project_name') or f'project-{project_id}'))
    return f'shop_{project_id}_{slug}', MANAGED_DIR / f'{project_id}-{slug}'


def project_env(row: dict[str, Any]) -> str:
    cfg = load_config()
    lines = [
        f"BOT_TOKEN={row['bot_token']}",
        f"DB_HOST={cfg['db_host']}",
        f"DB_PORT={cfg['db_port']}",
        f"DB_USER={cfg['db_user']}",
        f"DB_PASS={cfg['db_pass']}",
        f"DB_NAME={cfg['db_name']}",
        f"PROJECT_ID={row['project_id']}",
        f"PROJECT_NAME={row.get('project_name') or ''}",
        f"OWNER_USER_ID={row.get('owner_user_id') or ''}",
        f"OWNER_TG_ID={row.get('owner_tg_id') or ''}",
        f"OWNER_USERNAME={row.get('owner_username') or ''}",
    ]
    return '\n'.join(lines) + '\n'


def ensure_venv(path: Path, requirements: Path | None = None) -> None:
    venv = path / 'venv'
    if not (venv / 'bin/python').exists():
        cp = run_as_bot(['python3', '-m', 'venv', str(venv)], timeout=180)
        if cp.returncode != 0:
            raise RuntimeError(cp.stdout[-4000:])
    cp = run_as_bot([str(venv / 'bin/python'), '-m', 'pip', 'install', '--upgrade', 'pip', 'wheel', 'setuptools'], cwd=path, timeout=300)
    if cp.returncode != 0:
        raise RuntimeError(cp.stdout[-4000:])
    if requirements and requirements.exists() and requirements.stat().st_size:
        cp = run_as_bot([str(venv / 'bin/pip'), 'install', '-r', str(requirements)], cwd=path, timeout=900)
        if cp.returncode != 0:
            raise RuntimeError(cp.stdout[-8000:])


def db_deployment_update(row: dict[str, Any], pm2_name: str, path: Path, status: str, error: str | None = None) -> None:
    sql = """
      INSERT INTO bot_deployments(user_id, project_id, pm2_name, deploy_path, status, last_error)
      VALUES(%s,%s,%s,%s,%s,%s)
      ON DUPLICATE KEY UPDATE project_id=VALUES(project_id), pm2_name=VALUES(pm2_name),
        deploy_path=VALUES(deploy_path), status=VALUES(status), last_error=VALUES(last_error), updated_at=NOW()
    """
    with connect_db() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, (int(row['owner_user_id']), int(row['project_id']), pm2_name, str(path), status, error))
            cur.execute('UPDATE users SET bot_active=%s, updated_at=NOW() WHERE id=%s', ('active' if status == 'active' else 'pending', int(row['owner_user_id'])))


def get_project(project_id: int) -> dict[str, Any]:
    for row in query_projects():
        if int(row['project_id']) == int(project_id):
            return row
    raise RuntimeError(f'Проект id={project_id} не найден или у него пустой bot_token')


def deploy_project(project_id: int) -> dict[str, Any]:
    ensure_dirs()
    row = get_project(project_id)
    pm2_name, path = project_identity(row)
    try:
        if not (TEMPLATE_DIR / 'bot.py').exists():
            raise RuntimeError(f'Не загружен шаблон дочернего бота: {TEMPLATE_DIR}/bot.py')
        path.mkdir(parents=True, exist_ok=True)
        for child in TEMPLATE_DIR.iterdir():
            target = path / child.name
            if child.is_dir():
                shutil.copytree(child, target, dirs_exist_ok=True)
            else:
                shutil.copy2(child, target)
        (path / '.env').write_text(project_env(row), 'utf-8')
        os.chmod(path / '.env', 0o600)
        subprocess.run(['chown', '-R', f'{BOT_USER}:www-data', str(path)], check=False)
        ensure_venv(path, path / 'requirements.txt')
        run_as_bot(['pm2', 'delete', pm2_name], timeout=60)
        cp = run_as_bot(['pm2', 'start', 'bot.py', '--name', pm2_name, '--interpreter', str(path / 'venv/bin/python'), '--cwd', str(path)], cwd=path, timeout=120)
        if cp.returncode != 0:
            raise RuntimeError(cp.stdout[-8000:])
        run_as_bot(['pm2', 'save', '--force'], timeout=60)
        db_deployment_update(row, pm2_name, path, 'active', None)
        tg = telegram_getme(str(row['bot_token']))
        return {'ok': True, 'project_id': project_id, 'pm2_name': pm2_name, 'path': str(path), 'telegram': tg}
    except Exception as exc:
        try:
            db_deployment_update(row, pm2_name, path, 'failed', str(exc)[:4000])
        except Exception:
            pass
        raise


def action_project(project_id: int, action: str, delete_files: bool = False) -> dict[str, Any]:
    row = get_project(project_id)
    pm2_name, path = project_identity(row)
    if action == 'deploy':
        return deploy_project(project_id)
    if action in {'start', 'restart'}:
        if not (path / 'bot.py').exists():
            raise RuntimeError('Файлы проекта отсутствуют — сначала нажми Развернуть')
        cp = run_as_bot(['pm2', action, pm2_name], timeout=120)
    elif action == 'stop':
        cp = run_as_bot(['pm2', 'stop', pm2_name], timeout=120)
    elif action == 'delete':
        cp = run_as_bot(['pm2', 'delete', pm2_name], timeout=120)
        if delete_files and path.exists():
            shutil.rmtree(path)
        db_deployment_update(row, pm2_name, path, 'stopped', 'Удалён из панели')
    elif action == 'logs':
        cp = run_as_bot(['pm2', 'logs', pm2_name, '--lines', '200', '--nostream'], timeout=30)
        return {'ok': cp.returncode == 0, 'output': cp.stdout[-20000:], 'pm2_name': pm2_name}
    else:
        raise RuntimeError('Неизвестное действие')
    run_as_bot(['pm2', 'save', '--force'], timeout=60)
    return {'ok': cp.returncode == 0, 'output': cp.stdout[-5000:], 'pm2_name': pm2_name, 'path': str(path)}


def sync_payload() -> dict[str, Any]:
    ensure_dirs()
    rows = query_projects()
    pmap = pm2_map()
    projects = []
    for row in rows:
        pm2_name, path = project_identity(row)
        tg = telegram_getme(str(row.get('bot_token') or ''))
        projects.append({
            'project_id': int(row['project_id']),
            'owner_user_id': int(row['owner_user_id']),
            'project_name': row.get('project_name') or '',
            'owner_tg_id': row.get('owner_tg_id'),
            'owner_username': row.get('owner_username') or '',
            'owner_name': ' '.join(filter(None, [row.get('owner_first_name'), row.get('owner_last_name')])).strip(),
            'subscription_status': row.get('subscription_status') or '',
            'bot_active': row.get('bot_active') or '',
            'bot_username': tg.get('username') or '',
            'bot_link': f"https://t.me/{tg.get('username')}" if tg.get('username') else '',
            'pm2_name': pm2_name,
            'deploy_path': str(path),
            'pm2': pmap.get(pm2_name, {'status': 'not_found'}),
            'sql_status': row.get('sql_status') or '',
            'last_error': row.get('sql_last_error') or '',
            'token_fingerprint': token_fingerprint(str(row.get('bot_token') or '')),
        })
    return {'ok': True, 'count': len(projects), 'projects': projects, 'config': public_config()}


def public_config() -> dict[str, Any]:
    cfg = load_config()
    return {
        'db_host': cfg['db_host'], 'db_port': cfg['db_port'], 'db_user': cfg['db_user'],
        'db_name': cfg['db_name'], 'db_pass_set': bool(cfg.get('db_pass')),
        'master_project_id': cfg.get('master_project_id', 0),
        'master_dir': str(MASTER_DIR), 'template_dir': str(TEMPLATE_DIR), 'managed_dir': str(MANAGED_DIR),
        'master_bot_exists': (MASTER_DIR / 'bot.py').exists(),
        'master_requirements_exists': (MASTER_DIR / 'requirements.txt').exists(),
        'template_bot_exists': (TEMPLATE_DIR / 'bot.py').exists(),
        'template_requirements_exists': (TEMPLATE_DIR / 'requirements.txt').exists(),
        'master_pm2': pm2_map().get('mystock_deploy_worker', {'status': 'not_found'}),
    }


def save_uploaded(src: str, dst: Path) -> None:
    source = Path(src)
    if not source.is_file():
        raise RuntimeError(f'Загруженный файл не найден: {src}')
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dst)
    subprocess.run(['chown', f'{BOT_USER}:www-data', str(dst)], check=False)
    os.chmod(dst, 0o640)


def install_master(bot_file: str, req_file: str, project_id: int) -> dict[str, Any]:
    ensure_dirs()
    row = get_project(project_id)
    if bot_file:
        save_uploaded(bot_file, MASTER_DIR / 'bot.py')
    if req_file:
        save_uploaded(req_file, MASTER_DIR / 'requirements.txt')
    if not (MASTER_DIR / 'bot.py').exists():
        raise RuntimeError('Загрузи bot.py главного deploy-бота')
    cfg = load_config()
    cfg['master_project_id'] = int(project_id)
    save_config(cfg)
    env = project_env(row) + '\n'.join([
        f'DEPLOY_TEMPLATE_DIR={TEMPLATE_DIR}',
        f'DEPLOY_BOTS_BASE_DIR={MANAGED_DIR}',
        f'PYTHON_BIN={BASE}/bin/project-python',
        f'PIP_BIN={BASE}/bin/project-pip',
        f'PM2_BIN={BASE}/bin/project-pm2',
        f"DEPLOY_POLL_SEC={cfg.get('poll_sec', 3)}",
        f"DEPLOY_GC_SEC={cfg.get('gc_sec', 15)}",
    ]) + '\n'
    (MASTER_DIR / '.env').write_text(env, 'utf-8')
    os.chmod(MASTER_DIR / '.env', 0o600)
    subprocess.run(['chown', '-R', f'{BOT_USER}:www-data', str(MASTER_DIR)], check=False)
    ensure_venv(MASTER_DIR, MASTER_DIR / 'requirements.txt')
    name = 'mystock_deploy_worker'
    run_as_bot(['pm2', 'delete', name], timeout=60)
    cp = run_as_bot(['pm2', 'start', 'bot.py', '--name', name, '--interpreter', str(MASTER_DIR / 'venv/bin/python'), '--cwd', str(MASTER_DIR)], cwd=MASTER_DIR, timeout=120)
    if cp.returncode != 0:
        raise RuntimeError(cp.stdout[-8000:])
    run_as_bot(['pm2', 'save', '--force'], timeout=60)
    return {'ok': True, 'pm2_name': name, 'path': str(MASTER_DIR), 'project_id': project_id, 'telegram': telegram_getme(str(row['bot_token']))}


def master_action(action: str) -> dict[str, Any]:
    name = 'mystock_deploy_worker'
    if action == 'logs':
        cp = run_as_bot(['pm2', 'logs', name, '--lines', '250', '--nostream'], timeout=30)
    elif action in {'start', 'stop', 'restart'}:
        cp = run_as_bot(['pm2', action, name], timeout=120)
        run_as_bot(['pm2', 'save', '--force'], timeout=60)
    else:
        raise RuntimeError('Неизвестное действие master')
    return {'ok': cp.returncode == 0, 'output': cp.stdout[-25000:], 'status': pm2_map().get(name, {'status': 'not_found'})}


def install_template(bot_file: str, req_file: str) -> dict[str, Any]:
    ensure_dirs()
    if bot_file:
        save_uploaded(bot_file, TEMPLATE_DIR / 'bot.py')
    if req_file:
        save_uploaded(req_file, TEMPLATE_DIR / 'requirements.txt')
    if not (TEMPLATE_DIR / 'bot.py').exists():
        raise RuntimeError('Загрузи bot.py шаблона магазина')
    return {'ok': True, 'bot_py': str(TEMPLATE_DIR / 'bot.py'), 'requirements': str(TEMPLATE_DIR / 'requirements.txt')}


def write_wrappers() -> None:
    bindir = BASE / 'bin'
    bindir.mkdir(parents=True, exist_ok=True)
    (bindir / 'project-python').write_text(f'''#!/usr/bin/env bash\nset -Eeuo pipefail\nif [[ -x ./venv/bin/python ]]; then exec ./venv/bin/python "$@"; fi\nexec python3 "$@"\n''', 'utf-8')
    (bindir / 'project-pip').write_text('''#!/usr/bin/env bash\nset -Eeuo pipefail\nif [[ ! -x ./venv/bin/pip ]]; then python3 -m venv ./venv; ./venv/bin/python -m pip install --upgrade pip wheel setuptools; fi\nexec ./venv/bin/pip "$@"\n''', 'utf-8')
    (bindir / 'project-pm2').write_text(f'''#!/usr/bin/env bash\nset -Eeuo pipefail\nexport HOME={BOT_HOME}\nexport PM2_HOME={PM2_HOME}\nexec pm2 "$@"\n''', 'utf-8')
    for p in bindir.iterdir():
        os.chmod(p, 0o755)


def cmd_install() -> None:
    ensure_dirs()
    write_wrappers()
    cfg = load_config()
    if not CONFIG_PATH.exists():
        save_config(cfg)
    out({'ok': True, 'config': public_config()})


def cmd_config(args) -> None:
    cfg = load_config()
    if args.save:
        for key in ('db_host', 'db_user', 'db_name'):
            val = getattr(args, key)
            if val is not None:
                cfg[key] = val.strip()
        if args.db_port is not None:
            cfg['db_port'] = int(args.db_port)
        if args.db_pass is not None and args.db_pass != '':
            cfg['db_pass'] = args.db_pass
        save_config(cfg)
    out({'ok': True, 'config': public_config()})


def doctor() -> dict[str, Any]:
    ensure_dirs()
    checks = {}
    for name in ('python3','node','npm','pm2','curl'):
        checks[name] = bool(shutil.which(name))
    checks['python_venv'] = bool(shutil.which('python3'))
    checks['master_dir_writable'] = os.access(MASTER_DIR, os.W_OK)
    checks['template_dir_writable'] = os.access(TEMPLATE_DIR, os.W_OK)
    checks['managed_dir_writable'] = os.access(MANAGED_DIR, os.W_OK)
    checks['template_bot'] = (TEMPLATE_DIR / 'bot.py').exists()
    checks['template_requirements'] = (TEMPLATE_DIR / 'requirements.txt').exists()
    db_error = ''
    project_count = 0
    try:
        rows = query_projects(); project_count = len(rows); checks['mysql_connection'] = True
    except Exception as exc:
        checks['mysql_connection'] = False; db_error = str(exc)
    required = ['python3','pm2','python_venv','master_dir_writable','template_dir_writable','managed_dir_writable','mysql_connection']
    missing = [k for k in required if not checks.get(k)]
    return {'ok': not missing, 'checks': checks, 'missing': missing, 'db_error': db_error, 'project_count': project_count, 'config': public_config()}


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='cmd', required=True)
    sub.add_parser('install')
    c = sub.add_parser('config')
    c.add_argument('--save', action='store_true')
    c.add_argument('--db-host'); c.add_argument('--db-port', type=int); c.add_argument('--db-user'); c.add_argument('--db-pass'); c.add_argument('--db-name')
    sub.add_parser('sync')
    sub.add_parser('doctor')
    t = sub.add_parser('template-install'); t.add_argument('--bot-file', default=''); t.add_argument('--requirements-file', default='')
    m = sub.add_parser('master-install'); m.add_argument('--bot-file', default=''); m.add_argument('--requirements-file', default=''); m.add_argument('--project-id', type=int, required=True)
    ma = sub.add_parser('master-action'); ma.add_argument('action', choices=['start','stop','restart','logs'])
    pa = sub.add_parser('project-action'); pa.add_argument('project_id', type=int); pa.add_argument('action', choices=['deploy','start','stop','restart','logs','delete']); pa.add_argument('--delete-files', action='store_true')
    args = parser.parse_args()
    try:
        if args.cmd == 'install': cmd_install()
        elif args.cmd == 'config': cmd_config(args)
        elif args.cmd == 'sync': out(sync_payload())
        elif args.cmd == 'doctor': out(doctor())
        elif args.cmd == 'template-install': out(install_template(args.bot_file, args.requirements_file))
        elif args.cmd == 'master-install': out(install_master(args.bot_file, args.requirements_file, args.project_id))
        elif args.cmd == 'master-action': out(master_action(args.action))
        elif args.cmd == 'project-action': out(action_project(args.project_id, args.action, args.delete_files))
    except Exception as exc:
        fail(str(exc))


if __name__ == '__main__':
    main()
