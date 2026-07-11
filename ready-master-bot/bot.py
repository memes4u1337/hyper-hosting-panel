# bot.py — MyStock Deploy Worker for HYPER-HOST
from __future__ import annotations

import asyncio
import html
import json
import os
import re
import shutil
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import aiomysql
from aiogram import Bot, Dispatcher, F
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.filters import Command, CommandStart
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message, WebAppInfo


def safe_load_dotenv() -> None:
    try:
        from dotenv import load_dotenv
    except Exception:
        return
    try:
        env_path = Path(__file__).resolve().parent / '.env'
        if env_path.is_file():
            load_dotenv(env_path, override=False)
    except Exception:
        return


safe_load_dotenv()

BOT_TOKEN = (os.getenv('BOT_TOKEN') or '').strip()
DB_HOST = (os.getenv('DB_HOST') or '90.189.208.25').strip()
DB_PORT = int((os.getenv('DB_PORT') or '3306').strip())
DB_USER = (os.getenv('DB_USER') or 'mystock').strip()
DB_PASS = os.getenv('DB_PASS') or ''
DB_NAME = (os.getenv('DB_NAME') or 'mystock').strip()

SITE_BASE_URL = (os.getenv('SITE_BASE_URL') or 'https://mystockbot.ru/').strip()
WEBAPP_URL = (os.getenv('WEBAPP_URL') or 'https://mystockbot.ru/panel/new_panel/webapp').strip()

DEPLOY_TEMPLATE_DIR = Path(os.getenv('DEPLOY_TEMPLATE_DIR') or '/var/www/hyper-host-deploy/template')
DEPLOY_BOTS_BASE_DIR = Path(os.getenv('DEPLOY_BOTS_BASE_DIR') or '/var/www/hyper-host-managed-bots')
BOT_HOME = Path(os.getenv('BOT_HOME') or '/var/www/hyper-host-bots')
PM2_HOME = Path(os.getenv('PM2_HOME') or str(BOT_HOME / '.pm2'))
PYTHON_BIN = (os.getenv('PYTHON_BIN') or 'python3').strip()
PM2_BIN = (os.getenv('PM2_BIN') or 'pm2').strip()

POLL_SEC = max(2, int(os.getenv('DEPLOY_POLL_SEC') or '3'))
GC_SEC = max(10, int(os.getenv('DEPLOY_GC_SEC') or '30'))
RETRY_SEC = max(30, int(os.getenv('DEPLOY_RETRY_SEC') or '300'))
INCLUDE_ADMIN_PROJECTS = (os.getenv('DEPLOY_INCLUDE_ADMINS') or '0').strip() == '1'
NOTIFY_OWNER = (os.getenv('NOTIFY_OWNER') or '0').strip() == '1'
EXTRA_ADMIN_TG_IDS = {
    int(x.strip()) for x in (os.getenv('ADMIN_TG_IDS') or '').split(',')
    if x.strip().isdigit()
}
MAX_OUTPUT_SNIP = 2800


def esc(value: Any) -> str:
    return html.escape('' if value is None else str(value), quote=False)


def slugify(value: str) -> str:
    value = (value or '').strip().lower()
    value = re.sub(r'[^a-z0-9а-яё._-]+', '-', value, flags=re.I)
    value = re.sub(r'-+', '-', value).strip('-._')
    return value[:72] or 'project'


def token_valid(token: str) -> bool:
    return bool(re.fullmatch(r'\d+:[A-Za-z0-9_-]{20,}', token or ''))


def process_name(project_id: int, project_name: str) -> str:
    return f'shop_{project_id}_{slugify(project_name)}'


def project_path(project_id: int, project_name: str) -> Path:
    return DEPLOY_BOTS_BASE_DIR / f'{project_id}-{slugify(project_name)}'


def command_env() -> dict[str, str]:
    env = os.environ.copy()
    env.update({
        'HOME': str(BOT_HOME),
        'PM2_HOME': str(PM2_HOME),
        'PATH': '/usr/local/bin:/usr/bin:/bin',
    })
    return env


async def run_cmd(*args: str, cwd: Path | None = None, timeout: int = 900) -> tuple[int, str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            cwd=str(cwd) if cwd else None,
            env=command_env(),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        try:
            output, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return 124, f'Timeout after {timeout}s: {args!r}'
        return int(proc.returncode or 0), output.decode('utf-8', 'ignore')
    except FileNotFoundError:
        return 127, f'Binary not found: {args[0]}'
    except Exception as exc:
        return 1, f'run_cmd error: {exc}'


class DB:
    def __init__(self) -> None:
        self.pool: aiomysql.Pool | None = None

    async def connect(self) -> None:
        if self.pool is not None:
            return
        self.pool = await aiomysql.create_pool(
            host=DB_HOST,
            port=DB_PORT,
            user=DB_USER,
            password=DB_PASS,
            db=DB_NAME,
            charset='utf8mb4',
            autocommit=True,
            minsize=1,
            maxsize=8,
            connect_timeout=10,
        )

    async def close(self) -> None:
        if self.pool is not None:
            self.pool.close()
            await self.pool.wait_closed()
            self.pool = None

    async def fetchone(self, sql: str, args: tuple[Any, ...] = ()) -> Optional[dict[str, Any]]:
        assert self.pool is not None
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(sql, args)
                return await cur.fetchone()

    async def fetchall(self, sql: str, args: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        assert self.pool is not None
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(sql, args)
                return list(await cur.fetchall())

    async def execute(self, sql: str, args: tuple[Any, ...] = ()) -> int:
        assert self.pool is not None
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(sql, args)
                return int(cur.rowcount or 0)

    async def ensure_schema(self) -> None:
        await self.execute(
            """
            CREATE TABLE IF NOT EXISTS bot_deployments (
              id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
              user_id INT(11) NOT NULL,
              project_id INT(10) UNSIGNED NULL,
              pm2_name VARCHAR(128) NOT NULL,
              deploy_path VARCHAR(512) NOT NULL,
              status ENUM('deploying','active','failed','stopped') NOT NULL DEFAULT 'deploying',
              last_error TEXT NULL,
              created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
              updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
              UNIQUE KEY uniq_user (user_id),
              KEY idx_project (project_id),
              KEY idx_status (status)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            """
        )

    async def get_admin_tg_ids(self) -> list[int]:
        rows = await self.fetchall(
            "SELECT tg_id FROM users WHERE role='admin' AND tg_id IS NOT NULL"
        )
        result = {int(row['tg_id']) for row in rows if row.get('tg_id')}
        result.update(EXTRA_ADMIN_TG_IDS)
        return sorted(result)

    async def is_admin(self, tg_id: int) -> bool:
        row = await self.fetchone(
            "SELECT 1 FROM users WHERE tg_id=%s AND role='admin' LIMIT 1",
            (tg_id,),
        )
        return bool(row)

    async def get_user(self, tg_id: int) -> Optional[dict[str, Any]]:
        return await self.fetchone(
            """
            SELECT id,tg_id,username,first_name,last_name,role,
                   subscription_status,bot_active
            FROM users WHERE tg_id=%s LIMIT 1
            """,
            (tg_id,),
        )

    async def next_pending_project(self) -> Optional[dict[str, Any]]:
        role_filter = "" if INCLUDE_ADMIN_PROJECTS else "AND u.role='user'"
        return await self.fetchone(
            f"""
            SELECT
              p.id AS project_id,
              p.user_id AS owner_user_id,
              p.project_name,
              p.bot_token,
              u.tg_id AS owner_tg_id,
              u.username AS owner_username,
              u.first_name AS owner_first_name,
              u.last_name AS owner_last_name,
              u.role,
              u.subscription_status,
              u.bot_active
            FROM projects p
            JOIN users u ON u.id=p.user_id
            WHERE u.bot_active='pending'
              {role_filter}
              AND p.bot_token IS NOT NULL
              AND TRIM(p.bot_token)<>''
              AND p.project_name IS NOT NULL
              AND TRIM(p.project_name)<>''
            ORDER BY p.updated_at ASC,p.id ASC
            LIMIT 1
            """
        )

    async def claim_project(self, owner_user_id: int) -> bool:
        changed = await self.execute(
            """
            UPDATE users SET bot_active='in_work',updated_at=NOW()
            WHERE id=%s AND bot_active='pending'
            """,
            (owner_user_id,),
        )
        return changed == 1

    async def mark_user_status(self, owner_user_id: int, status: str) -> None:
        await self.execute(
            'UPDATE users SET bot_active=%s,updated_at=NOW() WHERE id=%s',
            (status, owner_user_id),
        )

    async def deployment(self, project_id: int) -> Optional[dict[str, Any]]:
        return await self.fetchone(
            'SELECT * FROM bot_deployments WHERE project_id=%s LIMIT 1',
            (project_id,),
        )

    async def upsert_deployment(
        self,
        row: dict[str, Any],
        pm2_name: str,
        path: Path,
        status: str,
        error: str | None = None,
    ) -> None:
        await self.execute(
            """
            INSERT INTO bot_deployments
              (user_id,project_id,pm2_name,deploy_path,status,last_error)
            VALUES(%s,%s,%s,%s,%s,%s)
            ON DUPLICATE KEY UPDATE
              project_id=VALUES(project_id),
              pm2_name=VALUES(pm2_name),
              deploy_path=VALUES(deploy_path),
              status=VALUES(status),
              last_error=VALUES(last_error),
              updated_at=NOW()
            """,
            (
                int(row['owner_user_id']),
                int(row['project_id']),
                pm2_name,
                str(path),
                status,
                error,
            ),
        )

    async def count_queue(self) -> dict[str, int]:
        row = await self.fetchone(
            """
            SELECT
              SUM(bot_active='pending') AS pending,
              SUM(bot_active='in_work') AS in_work,
              SUM(bot_active='active') AS active
            FROM users
            """
        )
        return {
            'pending': int((row or {}).get('pending') or 0),
            'in_work': int((row or {}).get('in_work') or 0),
            'active': int((row or {}).get('active') or 0),
        }

    async def list_deployments(self, limit: int = 50, status: str | None = None) -> list[dict[str, Any]]:
        if status:
            return await self.fetchall(
                """
                SELECT d.*,p.project_name,u.username,u.tg_id
                FROM bot_deployments d
                LEFT JOIN projects p ON p.id=d.project_id
                LEFT JOIN users u ON u.id=d.user_id
                WHERE d.status=%s
                ORDER BY d.updated_at DESC LIMIT %s
                """,
                (status, limit),
            )
        return await self.fetchall(
            """
            SELECT d.*,p.project_name,u.username,u.tg_id
            FROM bot_deployments d
            LEFT JOIN projects p ON p.id=d.project_id
            LEFT JOIN users u ON u.id=d.user_id
            ORDER BY d.updated_at DESC LIMIT %s
            """,
            (limit,),
        )

    async def project_exists(self, project_id: int) -> bool:
        row = await self.fetchone('SELECT 1 FROM projects WHERE id=%s LIMIT 1', (project_id,))
        return bool(row)


db = DB()
bot: Bot | None = None
dp = Dispatcher()
_retry_after: dict[int, float] = {}


def owner_label(row: dict[str, Any]) -> str:
    full = ' '.join(
        x for x in [row.get('owner_first_name'), row.get('owner_last_name')] if x
    ).strip()
    username = row.get('owner_username') or ''
    tg_id = row.get('owner_tg_id') or '—'
    if username:
        return f'{full or username} (@{username}, TG {tg_id})'
    return f'{full or "Без username"} (TG {tg_id})'


async def get_child_bot_info(token: str) -> dict[str, Any]:
    if not token_valid(token):
        return {'ok': False, 'error': 'Некорректный токен'}
    child = Bot(token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    try:
        me = await child.get_me()
        return {
            'ok': True,
            'id': me.id,
            'username': me.username or '',
            'first_name': me.first_name or '',
            'link': f'https://t.me/{me.username}' if me.username else '',
        }
    except Exception as exc:
        return {'ok': False, 'error': str(exc)}
    finally:
        await child.session.close()


async def notify_admins(text: str) -> None:
    if bot is None:
        return
    for tg_id in await db.get_admin_tg_ids():
        try:
            await bot.send_message(tg_id, text, disable_web_page_preview=True)
        except Exception as exc:
            print(f'[notify admin {tg_id}] {exc}')


async def notify_owner(row: dict[str, Any], text: str) -> None:
    if not NOTIFY_OWNER or bot is None or not row.get('owner_tg_id'):
        return
    try:
        await bot.send_message(int(row['owner_tg_id']), text, disable_web_page_preview=True)
    except Exception as exc:
        print(f'[notify owner] {exc}')


def child_env(row: dict[str, Any]) -> str:
    return '\n'.join([
        f"BOT_TOKEN={row['bot_token']}",
        f'DB_HOST={DB_HOST}',
        f'DB_USER={DB_USER}',
        f'DB_PASS={DB_PASS}',
        f'DB_NAME={DB_NAME}',
        f'DB_PORT={DB_PORT}',
        f"PROJECT_ID={int(row['project_id'])}",
        f"PROJECT_NAME={json.dumps(str(row.get('project_name') or ''), ensure_ascii=False)}",
        f"OWNER_USER_ID={int(row.get('owner_user_id') or 0)}",
        f"OWNER_TG_ID={row.get('owner_tg_id') or ''}",
        f"OWNER_USERNAME={json.dumps(str(row.get('owner_username') or ''), ensure_ascii=False)}",
        '',
    ])


def copy_template(destination: Path) -> None:
    source = DEPLOY_TEMPLATE_DIR
    if not source.is_dir():
        raise RuntimeError(f'Папка файлов для новых ботов не найдена: {source}')
    if not (source / 'bot.py').is_file():
        raise RuntimeError(f'Не загружен файл {source}/bot.py')
    destination.mkdir(parents=True, exist_ok=True)
    ignored = {'.env', 'venv', '.venv', '__pycache__', '.git', 'logs'}
    for item in source.iterdir():
        if item.name in ignored:
            continue
        target = destination / item.name
        if item.is_dir():
            shutil.copytree(item, target, dirs_exist_ok=True)
        else:
            shutil.copy2(item, target)
    (destination / 'logs').mkdir(exist_ok=True)


async def ensure_project_venv(destination: Path) -> None:
    venv = destination / 'venv'
    if not (venv / 'bin/python').is_file():
        code, output = await run_cmd(PYTHON_BIN, '-m', 'venv', str(venv), cwd=destination, timeout=240)
        if code != 0:
            raise RuntimeError(f'python -m venv failed:\n{output[-5000:]}')
    code, output = await run_cmd(
        str(venv / 'bin/python'), '-m', 'pip', 'install', '--upgrade',
        'pip', 'wheel', 'setuptools', cwd=destination, timeout=360,
    )
    if code != 0:
        raise RuntimeError(f'pip bootstrap failed:\n{output[-5000:]}')
    requirements = destination / 'requirements.txt'
    if requirements.is_file() and requirements.stat().st_size:
        code, output = await run_cmd(
            str(venv / 'bin/python'), '-m', 'pip', 'install', '-r',
            str(requirements), cwd=destination, timeout=1200,
        )
        if code != 0:
            raise RuntimeError(f'pip install failed:\n{output[-9000:]}')


async def pm2_start(row: dict[str, Any], destination: Path, name: str) -> None:
    await run_cmd(PM2_BIN, 'delete', name, timeout=60)
    code, output = await run_cmd(
        PM2_BIN, 'start', 'bot.py', '--name', name,
        '--interpreter', str(destination / 'venv/bin/python'),
        '--cwd', str(destination), '--time', '--update-env',
        cwd=destination, timeout=180,
    )
    if code != 0:
        raise RuntimeError(f'pm2 start failed:\n{output[-9000:]}')
    code, output = await run_cmd(PM2_BIN, 'save', '--force', timeout=60)
    if code != 0:
        raise RuntimeError(f'pm2 save failed:\n{output[-5000:]}')


async def deploy_project(row: dict[str, Any], child_info: dict[str, Any]) -> tuple[Path, str]:
    project_id = int(row['project_id'])
    name = process_name(project_id, str(row['project_name']))
    destination = project_path(project_id, str(row['project_name']))
    await db.upsert_deployment(row, name, destination, 'deploying', None)
    copy_template(destination)
    (destination / '.env').write_text(child_env(row), encoding='utf-8')
    os.chmod(destination / '.env', 0o600)
    await ensure_project_venv(destination)
    await pm2_start(row, destination, name)
    await db.upsert_deployment(row, name, destination, 'active', None)
    await db.mark_user_status(int(row['owner_user_id']), 'active')
    return destination, name


async def deployment_worker() -> None:
    loop = asyncio.get_running_loop()
    while True:
        row: dict[str, Any] | None = None
        try:
            row = await db.next_pending_project()
            if not row:
                await asyncio.sleep(POLL_SEC)
                continue
            project_id = int(row['project_id'])
            if _retry_after.get(project_id, 0) > loop.time():
                await asyncio.sleep(POLL_SEC)
                continue
            if not await db.claim_project(int(row['owner_user_id'])):
                await asyncio.sleep(1)
                continue

            token = str(row.get('bot_token') or '')
            child_info = await get_child_bot_info(token)
            bot_ref = (
                f"<a href=\"{esc(child_info.get('link'))}\">@{esc(child_info.get('username'))}</a>"
                if child_info.get('link') else 'ссылка пока недоступна'
            )
            start_text = (
                '⏳ <b>Начинаю запуск магазина</b>\n\n'
                f"🏪 Магазин: <b>{esc(row['project_name'])}</b>\n"
                f"🆔 Project ID: <code>{project_id}</code>\n"
                f"👤 Создал: <b>{esc(owner_label(row))}</b>\n"
                f"🤖 Бот: {bot_ref}\n"
                f"🔑 Токен: <code>{esc(token)}</code>\n"
                f"📁 Папка: <code>{esc(project_path(project_id, row['project_name']))}</code>"
            )
            await notify_admins(start_text)
            await notify_owner(
                row,
                f"⏳ Начинаю запуск вашего магазина <b>{esc(row['project_name'])}</b>.",
            )

            if not child_info.get('ok'):
                raise RuntimeError(f"Telegram getMe: {child_info.get('error') or 'unknown error'}")

            destination, pm2_name = await deploy_project(row, child_info)
            success_text = (
                '✅ <b>Магазин успешно запущен</b>\n\n'
                f"🏪 Магазин: <b>{esc(row['project_name'])}</b>\n"
                f"👤 Создал: <b>{esc(owner_label(row))}</b>\n"
                f"🤖 Бот: <a href=\"{esc(child_info['link'])}\">@{esc(child_info['username'])}</a>\n"
                f"🔑 Токен: <code>{esc(token)}</code>\n"
                f"⚙️ PM2: <code>{esc(pm2_name)}</code>\n"
                f"📁 Папка: <code>{esc(destination)}</code>"
            )
            await notify_admins(success_text)
            await notify_owner(
                row,
                f"✅ Ваш магазин <b>{esc(row['project_name'])}</b> запущен: "
                f"<a href=\"{esc(child_info['link'])}\">@{esc(child_info['username'])}</a>",
            )
            _retry_after.pop(project_id, None)
        except Exception as exc:
            error = f'{type(exc).__name__}: {exc}'
            print(f'[deployment worker] {error}\n{traceback.format_exc()}')
            try:
                if row:
                    project_id = int(row['project_id'])
                    name = process_name(project_id, str(row['project_name']))
                    destination = project_path(project_id, str(row['project_name']))
                    await db.upsert_deployment(row, name, destination, 'failed', error[:4000])
                    await db.mark_user_status(int(row['owner_user_id']), 'pending')
                    _retry_after[project_id] = loop.time() + RETRY_SEC
                    await notify_admins(
                        '❌ <b>Ошибка запуска магазина</b>\n\n'
                        f"🏪 Магазин: <b>{esc(row.get('project_name'))}</b>\n"
                        f"👤 Создал: <b>{esc(owner_label(row))}</b>\n"
                        f"🔑 Токен: <code>{esc(row.get('bot_token'))}</code>\n"
                        f"⚠️ Ошибка: <code>{esc(error[:1800])}</code>\n"
                        f"🔄 Повтор не раньше чем через {RETRY_SEC} сек."
                    )
            except Exception as nested:
                print(f'[deployment failure handler] {nested}')
            await asyncio.sleep(POLL_SEC)


async def pm2_jlist() -> list[dict[str, Any]]:
    code, output = await run_cmd(PM2_BIN, 'jlist', timeout=30)
    if code != 0:
        return []
    try:
        data = json.loads(output)
        return data if isinstance(data, list) else []
    except Exception:
        return []


async def gc_worker(force_once: bool = False) -> None:
    while True:
        try:
            for proc in await pm2_jlist():
                name = str(proc.get('name') or '')
                match = re.match(r'^shop_(\d+)_', name)
                if not match:
                    continue
                project_id = int(match.group(1))
                env = proc.get('pm2_env') or {}
                cwd = Path(str(env.get('pm_cwd') or ''))
                deployment = await db.deployment(project_id)
                should_stop = False
                reason = ''
                if not await db.project_exists(project_id):
                    should_stop, reason = True, 'project deleted from SQL'
                elif deployment and deployment.get('status') == 'stopped':
                    should_stop, reason = True, 'deployment status stopped'
                elif cwd and not cwd.exists():
                    should_stop, reason = True, 'project folder missing'
                if should_stop:
                    code, output = await run_cmd(PM2_BIN, 'delete', name, timeout=60)
                    print(f'[GC] {name}: {reason}; code={code}; {output[-500:]}')
            if force_once:
                await run_cmd(PM2_BIN, 'save', '--force', timeout=60)
                return
        except Exception as exc:
            print(f'[gc worker] {exc}')
            if force_once:
                return
        await asyncio.sleep(GC_SEC)


def admin_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text='🧠 Состояние', callback_data='deploy_dash'),
            InlineKeyboardButton(text='🔄 Обновить', callback_data='deploy_dash'),
        ],
        [
            InlineKeyboardButton(text='🟢 Активные', callback_data='deploy_active'),
            InlineKeyboardButton(text='⏳ Очередь', callback_data='deploy_queue'),
        ],
        [
            InlineKeyboardButton(text='🔴 Ошибки', callback_data='deploy_failed'),
            InlineKeyboardButton(text='📦 Все', callback_data='deploy_all'),
        ],
        [
            InlineKeyboardButton(text='🧹 Запустить GC', callback_data='deploy_gc'),
            InlineKeyboardButton(text='📋 PM2', callback_data='deploy_pm2'),
        ],
    ])


def webapp_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text='🚀 Открыть WebApp', web_app=WebAppInfo(url=WEBAPP_URL))],
    ])


async def dashboard_text() -> str:
    counts = await db.count_queue()
    deployments = await db.list_deployments(limit=100)
    active = sum(1 for item in deployments if item.get('status') == 'active')
    failed = sum(1 for item in deployments if item.get('status') == 'failed')
    return (
        '🤖 <b>MyStock Deploy Worker</b>\n'
        '━━━━━━━━━━━━━━━━━━\n'
        f"⏳ Pending: <b>{counts['pending']}</b>\n"
        f"🛠 In work: <b>{counts['in_work']}</b>\n"
        f"🟢 Active users: <b>{counts['active']}</b>\n"
        f"⚙️ Active PM2 deployments: <b>{active}</b>\n"
        f"🔴 Failed deployments: <b>{failed}</b>\n"
        '━━━━━━━━━━━━━━━━━━\n'
        f"📁 Template: <code>{esc(DEPLOY_TEMPLATE_DIR)}</code>\n"
        f"📦 Projects: <code>{esc(DEPLOY_BOTS_BASE_DIR)}</code>"
    )


@dp.message(CommandStart())
async def start_handler(message: Message) -> None:
    if not message.from_user:
        return
    if await db.is_admin(message.from_user.id):
        await message.answer(await dashboard_text(), reply_markup=admin_keyboard())
        return
    user = await db.get_user(message.from_user.id)
    if not user:
        await message.answer(
            '❌ Вы не зарегистрированы в MyStockBot.',
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text='🌐 Открыть сайт', url=SITE_BASE_URL)]
            ]),
        )
        return
    if (user.get('subscription_status') or 'free') == 'free':
        await message.answer(
            '⚠️ На бесплатном тарифе WebApp недоступен.',
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text='💎 Обновить тариф', url=SITE_BASE_URL)]
            ]),
        )
        return
    await message.answer(
        f"Добро пожаловать, <b>{esc(user.get('first_name') or user.get('username') or 'пользователь')}</b>!",
        reply_markup=webapp_keyboard(),
    )


@dp.message(Command('menu'))
async def menu_handler(message: Message) -> None:
    if not message.from_user or not await db.is_admin(message.from_user.id):
        await message.answer('⛔ Команда доступна только администраторам.')
        return
    await message.answer(await dashboard_text(), reply_markup=admin_keyboard())


async def require_admin(query: CallbackQuery) -> bool:
    if not query.from_user or not await db.is_admin(query.from_user.id):
        await query.answer('⛔ Доступ запрещён', show_alert=True)
        return False
    return True


@dp.callback_query(F.data == 'deploy_dash')
async def dashboard_callback(query: CallbackQuery) -> None:
    if not await require_admin(query):
        return
    if query.message:
        try:
            await query.message.edit_text(await dashboard_text(), reply_markup=admin_keyboard())
        except Exception:
            await query.message.answer(await dashboard_text(), reply_markup=admin_keyboard())
    await query.answer('Обновлено')


async def deployment_list_text(status: str | None, title: str) -> str:
    rows = await db.list_deployments(limit=40, status=status)
    if not rows:
        return f'{title}\n\nСписок пуст.'
    lines = [title, '━━━━━━━━━━━━━━━━━━']
    for row in rows:
        link = ''
        project_id = int(row.get('project_id') or 0)
        lines.append(
            f"<b>#{project_id} {esc(row.get('project_name') or 'Без названия')}</b>\n"
            f"Статус: <code>{esc(row.get('status'))}</code> · "
            f"PM2: <code>{esc(row.get('pm2_name'))}</code>\n"
            f"Владелец: @{esc(row.get('username') or '—')} · TG {esc(row.get('tg_id') or '—')}"
            f'{link}'
        )
    return '\n'.join(lines)


@dp.callback_query(F.data.in_({'deploy_active', 'deploy_failed', 'deploy_all'}))
async def list_callback(query: CallbackQuery) -> None:
    if not await require_admin(query):
        return
    mapping = {
        'deploy_active': ('active', '🟢 <b>Активные магазины</b>'),
        'deploy_failed': ('failed', '🔴 <b>Ошибки запуска</b>'),
        'deploy_all': (None, '📦 <b>Все деплои</b>'),
    }
    status, title = mapping[query.data]
    if query.message:
        await query.message.answer(await deployment_list_text(status, title), reply_markup=admin_keyboard())
    await query.answer()


@dp.callback_query(F.data == 'deploy_queue')
async def queue_callback(query: CallbackQuery) -> None:
    if not await require_admin(query):
        return
    counts = await db.count_queue()
    text = (
        '⏳ <b>Очередь запуска</b>\n\n'
        f"Pending: <b>{counts['pending']}</b>\n"
        f"In work: <b>{counts['in_work']}</b>\n"
        f"Active: <b>{counts['active']}</b>"
    )
    if query.message:
        await query.message.answer(text, reply_markup=admin_keyboard())
    await query.answer()


@dp.callback_query(F.data == 'deploy_gc')
async def gc_callback(query: CallbackQuery) -> None:
    if not await require_admin(query):
        return
    await query.answer('GC запущен')
    await gc_worker(force_once=True)
    if query.message:
        await query.message.answer('🧹 GC завершён.', reply_markup=admin_keyboard())


@dp.callback_query(F.data == 'deploy_pm2')
async def pm2_callback(query: CallbackQuery) -> None:
    if not await require_admin(query):
        return
    code, output = await run_cmd(PM2_BIN, 'ls', timeout=30)
    if query.message:
        await query.message.answer(
            f"📋 <b>PM2</b> · code {code}\n<pre>{esc(output[-MAX_OUTPUT_SNIP:])}</pre>",
            reply_markup=admin_keyboard(),
        )
    await query.answer()


async def main() -> None:
    if not BOT_TOKEN:
        raise RuntimeError('BOT_TOKEN пустой в .env главного deploy-бота')
    DEPLOY_TEMPLATE_DIR.mkdir(parents=True, exist_ok=True)
    DEPLOY_BOTS_BASE_DIR.mkdir(parents=True, exist_ok=True)
    BOT_HOME.mkdir(parents=True, exist_ok=True)
    PM2_HOME.mkdir(parents=True, exist_ok=True)
    await db.connect()
    await db.ensure_schema()
    global bot
    bot = Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    try:
        me = await bot.get_me()
        await notify_admins(
            '✅ <b>Главный Deploy Worker запущен</b>\n\n'
            f"🤖 Бот: <a href=\"https://t.me/{esc(me.username or '')}\">@{esc(me.username or 'без username')}</a>\n"
            f"📁 Шаблон: <code>{esc(DEPLOY_TEMPLATE_DIR)}</code>\n"
            f"📦 Проекты: <code>{esc(DEPLOY_BOTS_BASE_DIR)}</code>"
        )
        asyncio.create_task(deployment_worker(), name='deployment_worker')
        asyncio.create_task(gc_worker(), name='gc_worker')
        await dp.start_polling(bot)
    finally:
        await bot.session.close()
        await db.close()


if __name__ == '__main__':
    asyncio.run(main())
