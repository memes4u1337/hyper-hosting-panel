#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
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
MASTER_PM2_NAME = 'mystock_deploy_worker'

DEFAULT_CONFIG = {
    'db_host': '90.189.208.25',
    'db_port': 3306,
    'db_user': 'mystock',
    'db_pass': '',
    'db_name': 'mystock',
    'poll_sec': 3,
    'gc_sec': 15,
}


def out(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, separators=(',', ':')))


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
    subprocess.run(
        ['chown', '-R', f'{BOT_USER}:www-data', str(MASTER_DIR.parent), str(MANAGED_DIR), str(BOT_HOME)],
        check=False,
    )
    for p in (MASTER_DIR.parent, MASTER_DIR, TEMPLATE_DIR, MANAGED_DIR, BOT_HOME, PM2_HOME):
        try:
            os.chmod(p, 0o2775)
        except OSError:
            pass


def connect_db():
    cfg = load_config()
    if not cfg.get('db_pass'):
        raise RuntimeError('Пароль MySQL не задан в настройках Deploy Manager')
    try:
        import pymysql
    except Exception as exc:
        raise RuntimeError('PyMySQL не установлен в Deploy Manager venv') from exc
    return pymysql.connect(
        host=str(cfg['db_host']),
        port=int(cfg['db_port']),
        user=str(cfg['db_user']),
        password=str(cfg['db_pass']),
        database=str(cfg['db_name']),
        charset='utf8mb4',
        autocommit=True,
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=8,
        read_timeout=20,
        write_timeout=20,
    )


def slugify(value: str) -> str:
    value = (value or '').strip().lower()
    value = re.sub(r'[^a-z0-9а-яё._-]+', '-', value, flags=re.I)
    value = re.sub(r'-+', '-', value).strip('-._')
    return value[:72] or 'project'


def token_fingerprint(token: str) -> str:
    return hashlib.sha256((token or '').encode()).hexdigest()[:16]


def read_dotenv(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for raw in path.read_text('utf-8', errors='ignore').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = key.strip()
        value = value.strip()
        if value and value[0:1] == value[-1:] and value[0] in {'"', "'"}:
            value = value[1:-1]
        result[key] = value
    return result


def telegram_getme(token: str) -> dict[str, Any]:
    if not re.match(r'^\d+:[A-Za-z0-9_-]{20,}$', token or ''):
        return {'ok': False, 'error': 'invalid token'}
    cache = load_json(CACHE_PATH, {})
    fp = token_fingerprint(token)
    cached = cache.get(fp)
    if isinstance(cached, dict) and time.time() - float(cached.get('_at', 0)) < 1800:
        return cached
    try:
        with urllib.request.urlopen(f'https://api.telegram.org/bot{token}/getMe', timeout=8) as response:
            data = json.loads(response.read().decode('utf-8', 'ignore'))
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
    env.update({
        'HOME': str(BOT_HOME),
        'PM2_HOME': str(PM2_HOME),
        'PATH': '/usr/local/bin:/usr/bin:/bin',
    })
    return env


def run_as_bot(
    args: list[str],
    cwd: Path | None = None,
    timeout: int = 600,
) -> subprocess.CompletedProcess[str]:
    cmd = [
        'sudo', '-u', BOT_USER, '-H', 'env',
        f'HOME={BOT_HOME}', f'PM2_HOME={PM2_HOME}',
        'PATH=/usr/local/bin:/usr/bin:/bin',
        *args,
    ]
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )


def pm2_map() -> dict[str, dict[str, Any]]:
    try:
        cp = run_as_bot(['pm2', 'jlist'], timeout=20)
        data = json.loads(cp.stdout or '[]') if cp.returncode == 0 else []
    except Exception:
        data = []
    result: dict[str, dict[str, Any]] = {}
    for item in data:
        env = item.get('pm2_env') or {}
        result[str(item.get('name') or '')] = {
            'status': env.get('status') or 'unknown',
            'pid': item.get('pid') or 0,
            'memory': (item.get('monit') or {}).get('memory') or 0,
            'cpu': (item.get('monit') or {}).get('cpu') or 0,
            'restarts': env.get('restart_time') or 0,
            'uptime': env.get('pm_uptime') or 0,
        }
    return result


def project_identity(row: dict[str, Any]) -> tuple[str, Path]:
    project_id = int(row['project_id'])
    slug = slugify(str(row.get('project_name') or f'project-{project_id}'))
    return f'shop_{project_id}_{slug}', MANAGED_DIR / f'{project_id}-{slug}'


def env_plain(value: Any) -> str:
    text = '' if value is None else str(value)
    return text.replace('\r', '').replace('\n', ' ')


def project_env(row: dict[str, Any]) -> str:
    cfg = load_config()
    # Первые пять строк — ровно те параметры, которые нужны дочернему bot.py.
    lines = [
        f"BOT_TOKEN={env_plain(row['bot_token'])}",
        f"DB_HOST={env_plain(cfg['db_host'])}",
        f"DB_USER={env_plain(cfg['db_user'])}",
        f"DB_PASS={env_plain(cfg['db_pass'])}",
        f"DB_NAME={env_plain(cfg['db_name'])}",
        f"DB_PORT={int(cfg['db_port'])}",
        f"PROJECT_ID={int(row['project_id'])}",
        f"PROJECT_NAME={json.dumps(str(row.get('project_name') or ''), ensure_ascii=False)}",
        f"OWNER_USER_ID={int(row.get('owner_user_id') or 0)}",
        f"OWNER_TG_ID={env_plain(row.get('owner_tg_id') or '')}",
        f"OWNER_USERNAME={json.dumps(str(row.get('owner_username') or ''), ensure_ascii=False)}",
    ]
    return '\n'.join(lines) + '\n'


def ensure_venv(path: Path, requirements: Path | None = None) -> None:
    venv = path / 'venv'
    if not (venv / 'bin/python').exists():
        cp = run_as_bot(['python3', '-m', 'venv', str(venv)], cwd=path, timeout=240)
        if cp.returncode != 0:
            raise RuntimeError(cp.stdout[-5000:])
    cp = run_as_bot(
        [str(venv / 'bin/python'), '-m', 'pip', 'install', '--upgrade', 'pip', 'wheel', 'setuptools'],
        cwd=path,
        timeout=360,
    )
    if cp.returncode != 0:
        raise RuntimeError(cp.stdout[-5000:])
    if requirements and requirements.is_file() and requirements.stat().st_size:
        cp = run_as_bot(
            [str(venv / 'bin/python'), '-m', 'pip', 'install', '-r', str(requirements)],
            cwd=path,
            timeout=1200,
        )
        if cp.returncode != 0:
            raise RuntimeError(cp.stdout[-10000:])


def db_deployment_update(
    row: dict[str, Any],
    pm2_name: str,
    path: Path,
    status: str,
    error: str | None = None,
) -> None:
    sql = """
      INSERT INTO bot_deployments(user_id, project_id, pm2_name, deploy_path, status, last_error)
      VALUES(%s,%s,%s,%s,%s,%s)
      ON DUPLICATE KEY UPDATE
        project_id=VALUES(project_id), pm2_name=VALUES(pm2_name),
        deploy_path=VALUES(deploy_path), status=VALUES(status),
        last_error=VALUES(last_error), updated_at=NOW()
    """
    with connect_db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                sql,
                (
                    int(row['owner_user_id']), int(row['project_id']), pm2_name,
                    str(path), status, error,
                ),
            )
            user_state = 'active' if status == 'active' else 'pending'
            cur.execute(
                'UPDATE users SET bot_active=%s, updated_at=NOW() WHERE id=%s',
                (user_state, int(row['owner_user_id'])),
            )


def db_deployment_delete(row: dict[str, Any]) -> None:
    """Удаляет только запись развёрнутого бота. Сам project/user/token не трогаем."""
    with connect_db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                'DELETE FROM bot_deployments WHERE project_id=%s',
                (int(row['project_id']),),
            )


def get_project(project_id: int) -> dict[str, Any]:
    for row in query_projects():
        if int(row['project_id']) == int(project_id):
            return row
    raise RuntimeError(f'Проект id={project_id} не найден или у него пустой bot_token')


def copy_template(path: Path) -> None:
    if not (TEMPLATE_DIR / 'bot.py').is_file():
        raise RuntimeError('Не загружен bot.py для новых магазинов')
    path.mkdir(parents=True, exist_ok=True)
    ignored = {'.env', 'venv', '.venv', '__pycache__', '.git', 'logs'}
    for child in TEMPLATE_DIR.iterdir():
        if child.name in ignored:
            continue
        target = path / child.name
        if child.is_dir():
            shutil.copytree(child, target, dirs_exist_ok=True)
        else:
            shutil.copy2(child, target)
    (path / 'logs').mkdir(exist_ok=True)


def start_project_process(pm2_name: str, path: Path) -> subprocess.CompletedProcess[str]:
    return run_as_bot(
        [
            'pm2', 'start', 'bot.py', '--name', pm2_name,
            '--interpreter', str(path / 'venv/bin/python'), '--cwd', str(path),
            '--time', '--update-env',
        ],
        cwd=path,
        timeout=180,
    )


def deploy_project(project_id: int) -> dict[str, Any]:
    ensure_dirs()
    row = get_project(project_id)
    pm2_name, path = project_identity(row)
    try:
        db_deployment_update(row, pm2_name, path, 'deploying', None)
        copy_template(path)
        (path / '.env').write_text(project_env(row), 'utf-8')
        os.chmod(path / '.env', 0o600)
        subprocess.run(['chown', '-R', f'{BOT_USER}:www-data', str(path)], check=False)
        ensure_venv(path, path / 'requirements.txt')
        run_as_bot(['pm2', 'delete', pm2_name], timeout=60)
        cp = start_project_process(pm2_name, path)
        if cp.returncode != 0:
            raise RuntimeError(cp.stdout[-10000:])
        run_as_bot(['pm2', 'save', '--force'], timeout=60)
        db_deployment_update(row, pm2_name, path, 'active', None)
        tg = telegram_getme(str(row['bot_token']))
        return {
            'ok': True,
            'project_id': project_id,
            'project_name': row.get('project_name') or '',
            'owner_username': row.get('owner_username') or '',
            'owner_tg_id': row.get('owner_tg_id'),
            'pm2_name': pm2_name,
            'path': str(path),
            'telegram': tg,
        }
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
        if not (path / 'bot.py').is_file():
            raise RuntimeError('Файлы магазина отсутствуют — сначала нажми «Развернуть»')
        current = pm2_map().get(pm2_name)
        if not current:
            cp = start_project_process(pm2_name, path)
        else:
            cp = run_as_bot(['pm2', action, pm2_name, '--update-env'], cwd=path, timeout=180)
        if cp.returncode == 0:
            db_deployment_update(row, pm2_name, path, 'active', None)
    elif action == 'stop':
        cp = run_as_bot(['pm2', 'stop', pm2_name], timeout=120)
        if cp.returncode == 0:
            db_deployment_update(row, pm2_name, path, 'stopped', None)
    elif action == 'delete':
        # Удаление идемпотентно: даже если PM2-процесса уже нет,
        # папка и запись развёртывания всё равно очищаются.
        cp = run_as_bot(['pm2', 'delete', pm2_name], timeout=120)

        if delete_files and path.exists():
            managed_root = MANAGED_DIR.resolve()
            resolved = path.resolve()
            if resolved == managed_root or managed_root not in resolved.parents:
                raise RuntimeError(f'Отказано в удалении небезопасного пути: {resolved}')
            shutil.rmtree(resolved)

        # PM2 может оставлять старые stdout/stderr логи после delete.
        log_dir = PM2_HOME / 'logs'
        if log_dir.is_dir():
            for log_file in log_dir.glob(f'{pm2_name}-*.log'):
                try:
                    log_file.unlink()
                except FileNotFoundError:
                    pass

        db_deployment_delete(row)
        cp = subprocess.CompletedProcess(
            args=['delete', pm2_name],
            returncode=0,
            stdout=(cp.stdout or '') + '\nБот, папка и запись развёртывания удалены.',
        )
    elif action == 'logs':
        cp = run_as_bot(['pm2', 'logs', pm2_name, '--lines', '250', '--nostream'], timeout=35)
        return {'ok': cp.returncode == 0, 'output': cp.stdout[-30000:], 'pm2_name': pm2_name}
    else:
        raise RuntimeError('Неизвестное действие')
    run_as_bot(['pm2', 'save', '--force'], timeout=60)
    return {
        'ok': cp.returncode == 0,
        'output': cp.stdout[-8000:],
        'pm2_name': pm2_name,
        'path': str(path),
    }


def master_telegram() -> dict[str, Any]:
    env = read_dotenv(MASTER_DIR / '.env')
    token = env.get('BOT_TOKEN', '')
    return telegram_getme(token) if token else {'ok': False, 'error': 'BOT_TOKEN отсутствует в .env'}


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
            'owner_name': ' '.join(
                filter(None, [row.get('owner_first_name'), row.get('owner_last_name')])
            ).strip(),
            'subscription_status': row.get('subscription_status') or '',
            'bot_active': row.get('bot_active') or '',
            'bot_username': tg.get('username') or '',
            'bot_link': f"https://t.me/{tg.get('username')}" if tg.get('username') else '',
            'pm2_name': pm2_name,
            'deploy_path': str(path),
            'files_ready': (path / 'bot.py').is_file() and (path / '.env').is_file(),
            'pm2': pmap.get(pm2_name, {'status': 'not_found'}),
            'sql_status': row.get('sql_status') or '',
            'last_error': row.get('sql_last_error') or '',
            'token_fingerprint': token_fingerprint(str(row.get('bot_token') or '')),
        })
    return {
        'ok': True,
        'count': len(projects),
        'projects': projects,
        'config': public_config(),
    }


def file_info(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {'exists': False, 'size': 0, 'mtime': 0}
    stat = path.stat()
    return {'exists': True, 'size': stat.st_size, 'mtime': int(stat.st_mtime)}


def public_config() -> dict[str, Any]:
    cfg = load_config()
    pm2 = pm2_map()
    mtg = master_telegram()
    return {
        'db_host': cfg['db_host'],
        'db_port': cfg['db_port'],
        'db_user': cfg['db_user'],
        'db_name': cfg['db_name'],
        'db_pass_set': bool(cfg.get('db_pass')),
        'master_dir': str(MASTER_DIR),
        'template_dir': str(TEMPLATE_DIR),
        'managed_dir': str(MANAGED_DIR),
        'master_files': {
            'bot_py': file_info(MASTER_DIR / 'bot.py'),
            'env': file_info(MASTER_DIR / '.env'),
            'requirements': file_info(MASTER_DIR / 'requirements.txt'),
        },
        'template_files': {
            'bot_py': file_info(TEMPLATE_DIR / 'bot.py'),
            'requirements': file_info(TEMPLATE_DIR / 'requirements.txt'),
        },
        'master_telegram': {
            'ok': bool(mtg.get('ok')),
            'username': mtg.get('username') or '',
            'first_name': mtg.get('first_name') or '',
            'link': f"https://t.me/{mtg.get('username')}" if mtg.get('username') else '',
            'error': mtg.get('error') or '',
        },
        'master_pm2': pm2.get(MASTER_PM2_NAME, {'status': 'not_found'}),
    }


def save_uploaded(src: str, dst: Path, mode: int = 0o640) -> None:
    source = Path(src)
    if not source.is_file():
        raise RuntimeError(f'Загруженный файл не найден: {src}')
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dst)
    subprocess.run(['chown', f'{BOT_USER}:www-data', str(dst)], check=False)
    os.chmod(dst, mode)


def start_master() -> subprocess.CompletedProcess[str]:
    return run_as_bot(
        [
            'pm2', 'start', 'bot.py', '--name', MASTER_PM2_NAME,
            '--interpreter', str(MASTER_DIR / 'venv/bin/python'),
            '--cwd', str(MASTER_DIR), '--time', '--update-env',
        ],
        cwd=MASTER_DIR,
        timeout=180,
    )


def install_master(bot_file: str, env_file: str, req_file: str) -> dict[str, Any]:
    ensure_dirs()
    if bot_file:
        save_uploaded(bot_file, MASTER_DIR / 'bot.py')
    if env_file:
        save_uploaded(env_file, MASTER_DIR / '.env', 0o600)
    if req_file:
        save_uploaded(req_file, MASTER_DIR / 'requirements.txt')
    if not (MASTER_DIR / 'bot.py').is_file():
        raise RuntimeError('Загрузи bot.py главного deploy-бота')
    if not (MASTER_DIR / '.env').is_file():
        raise RuntimeError('Загрузи .env главного deploy-бота')
    subprocess.run(['chown', '-R', f'{BOT_USER}:www-data', str(MASTER_DIR)], check=False)
    ensure_venv(MASTER_DIR, MASTER_DIR / 'requirements.txt')
    run_as_bot(['pm2', 'delete', MASTER_PM2_NAME], timeout=60)
    cp = start_master()
    if cp.returncode != 0:
        raise RuntimeError(cp.stdout[-10000:])
    run_as_bot(['pm2', 'save', '--force'], timeout=60)
    return {
        'ok': True,
        'pm2_name': MASTER_PM2_NAME,
        'path': str(MASTER_DIR),
        'telegram': master_telegram(),
    }


def master_action(action: str) -> dict[str, Any]:
    current = pm2_map().get(MASTER_PM2_NAME)
    if action == 'logs':
        cp = run_as_bot(
            ['pm2', 'logs', MASTER_PM2_NAME, '--lines', '300', '--nostream'],
            timeout=35,
        )
    elif action in {'start', 'restart'}:
        if not (MASTER_DIR / 'bot.py').is_file() or not (MASTER_DIR / '.env').is_file():
            raise RuntimeError('Сначала загрузи bot.py и .env главного бота')
        if not (MASTER_DIR / 'venv/bin/python').exists():
            ensure_venv(MASTER_DIR, MASTER_DIR / 'requirements.txt')
        if not current:
            cp = start_master()
        else:
            cp = run_as_bot(['pm2', action, MASTER_PM2_NAME, '--update-env'], cwd=MASTER_DIR, timeout=180)
        run_as_bot(['pm2', 'save', '--force'], timeout=60)
    elif action == 'stop':
        cp = run_as_bot(['pm2', 'stop', MASTER_PM2_NAME], timeout=120)
        run_as_bot(['pm2', 'save', '--force'], timeout=60)
    else:
        raise RuntimeError('Неизвестное действие главного бота')
    return {
        'ok': cp.returncode == 0,
        'output': cp.stdout[-30000:],
        'status': pm2_map().get(MASTER_PM2_NAME, {'status': 'not_found'}),
    }


def install_template(bot_file: str, req_file: str) -> dict[str, Any]:
    ensure_dirs()
    if bot_file:
        save_uploaded(bot_file, TEMPLATE_DIR / 'bot.py')
    if req_file:
        save_uploaded(req_file, TEMPLATE_DIR / 'requirements.txt')
    if not (TEMPLATE_DIR / 'bot.py').is_file():
        raise RuntimeError('Загрузи bot.py, который будет копироваться в новые магазины')
    return {
        'ok': True,
        'bot_py': file_info(TEMPLATE_DIR / 'bot.py'),
        'requirements': file_info(TEMPLATE_DIR / 'requirements.txt'),
        'path': str(TEMPLATE_DIR),
    }


def write_wrappers() -> None:
    bindir = BASE / 'bin'
    bindir.mkdir(parents=True, exist_ok=True)
    (bindir / 'project-python').write_text(
        '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        'if [[ -x ./venv/bin/python ]]; then exec ./venv/bin/python "$@"; fi\n'
        'exec python3 "$@"\n',
        'utf-8',
    )
    (bindir / 'project-pip').write_text(
        '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        'if [[ ! -x ./venv/bin/pip ]]; then python3 -m venv ./venv; '
        './venv/bin/python -m pip install --upgrade pip wheel setuptools; fi\n'
        'exec ./venv/bin/pip "$@"\n',
        'utf-8',
    )
    (bindir / 'project-pm2').write_text(
        f'#!/usr/bin/env bash\nset -Eeuo pipefail\nexport HOME={BOT_HOME}\n'
        f'export PM2_HOME={PM2_HOME}\nexec pm2 "$@"\n',
        'utf-8',
    )
    for path in bindir.iterdir():
        os.chmod(path, 0o755)


def cmd_install() -> None:
    ensure_dirs()
    write_wrappers()
    if not CONFIG_PATH.exists():
        save_config(load_config())
    out({'ok': True, 'config': public_config()})


def cmd_config(args: argparse.Namespace) -> None:
    cfg = load_config()
    if args.save:
        for key in ('db_host', 'db_user', 'db_name'):
            value = getattr(args, key)
            if value is not None:
                cfg[key] = value.strip()
        if args.db_port is not None:
            cfg['db_port'] = int(args.db_port)
        if args.db_pass is not None and args.db_pass != '':
            cfg['db_pass'] = args.db_pass
        save_config(cfg)
    out({'ok': True, 'config': public_config()})


def doctor() -> dict[str, Any]:
    ensure_dirs()
    checks: dict[str, Any] = {}
    for name in ('python3', 'node', 'npm', 'pm2', 'curl'):
        checks[name] = bool(shutil.which(name))
    checks['python_venv'] = bool(shutil.which('python3'))
    checks['master_dir_writable'] = os.access(MASTER_DIR, os.W_OK)
    checks['template_dir_writable'] = os.access(TEMPLATE_DIR, os.W_OK)
    checks['managed_dir_writable'] = os.access(MANAGED_DIR, os.W_OK)
    checks['master_bot'] = (MASTER_DIR / 'bot.py').is_file()
    checks['master_env'] = (MASTER_DIR / '.env').is_file()
    checks['master_requirements'] = (MASTER_DIR / 'requirements.txt').is_file()
    checks['template_bot'] = (TEMPLATE_DIR / 'bot.py').is_file()
    checks['template_requirements'] = (TEMPLATE_DIR / 'requirements.txt').is_file()
    db_error = ''
    project_count = 0
    try:
        rows = query_projects()
        project_count = len(rows)
        checks['mysql_connection'] = True
    except Exception as exc:
        checks['mysql_connection'] = False
        db_error = str(exc)
    required = [
        'python3', 'pm2', 'python_venv', 'master_dir_writable',
        'template_dir_writable', 'managed_dir_writable', 'mysql_connection',
    ]
    missing = [key for key in required if not checks.get(key)]
    upload_missing = [
        key for key in ('master_bot', 'master_env', 'template_bot') if not checks.get(key)
    ]
    return {
        'ok': not missing,
        'checks': checks,
        'missing': missing,
        'upload_missing': upload_missing,
        'db_error': db_error,
        'project_count': project_count,
        'config': public_config(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='cmd', required=True)
    sub.add_parser('install')
    config = sub.add_parser('config')
    config.add_argument('--save', action='store_true')
    config.add_argument('--db-host')
    config.add_argument('--db-port', type=int)
    config.add_argument('--db-user')
    config.add_argument('--db-pass')
    config.add_argument('--db-name')
    sub.add_parser('sync')
    sub.add_parser('doctor')
    template = sub.add_parser('template-install')
    template.add_argument('--bot-file', default='')
    template.add_argument('--requirements-file', default='')
    master = sub.add_parser('master-install')
    master.add_argument('--bot-file', default='')
    master.add_argument('--env-file', default='')
    master.add_argument('--requirements-file', default='')
    master_action_parser = sub.add_parser('master-action')
    master_action_parser.add_argument('action', choices=['start', 'stop', 'restart', 'logs'])
    project = sub.add_parser('project-action')
    project.add_argument('project_id', type=int)
    project.add_argument('action', choices=['deploy', 'start', 'stop', 'restart', 'logs', 'delete'])
    project.add_argument('--delete-files', action='store_true')
    args = parser.parse_args()
    try:
        if args.cmd == 'install':
            cmd_install()
        elif args.cmd == 'config':
            cmd_config(args)
        elif args.cmd == 'sync':
            out(sync_payload())
        elif args.cmd == 'doctor':
            out(doctor())
        elif args.cmd == 'template-install':
            out(install_template(args.bot_file, args.requirements_file))
        elif args.cmd == 'master-install':
            out(install_master(args.bot_file, args.env_file, args.requirements_file))
        elif args.cmd == 'master-action':
            out(master_action(args.action))
        elif args.cmd == 'project-action':
            out(action_project(args.project_id, args.action, args.delete_files))
    except Exception as exc:
        fail(str(exc))


if __name__ == '__main__':
    main()
