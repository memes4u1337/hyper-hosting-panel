# bot.py — HYPER-HOST Deploy Worker (SQL projects → isolated PM2 bots)
from __future__ import annotations

import os
import re
import shutil
import asyncio
import traceback
from pathlib import Path
from typing import Optional

import aiomysql
from aiogram import Bot, Dispatcher, F
from aiogram.enums import ParseMode
from aiogram.filters import CommandStart, Command
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton, WebAppInfo
from aiogram.client.default import DefaultBotProperties


# =========================
# SAFE .env LOADER
# =========================
def safe_load_dotenv() -> None:
    try:
        from dotenv import load_dotenv  # type: ignore
    except Exception:
        return
    try:
        env_path = Path(__file__).resolve().parent / ".env"
        if env_path.exists():
            load_dotenv(dotenv_path=str(env_path), override=False)
    except Exception:
        return


safe_load_dotenv()


# =========================
# ENV
# =========================
BOT_TOKEN = (os.getenv("BOT_TOKEN") or "").strip()

DB_HOST = (os.getenv("DB_HOST") or "127.0.0.1").strip()
DB_PORT = int((os.getenv("DB_PORT") or "3306").strip())
DB_USER = (os.getenv("DB_USER") or "root").strip()
DB_PASS = (os.getenv("DB_PASS") or "").strip()
DB_NAME = (os.getenv("DB_NAME") or "").strip()

SITE_BASE_URL = (os.getenv("SITE_BASE_URL") or "https://mystockbot.ru/").strip()
PUBLIC_ROOT = (os.getenv("PUBLIC_ROOT") or "/var/www/html").strip()

DEPLOY_TEMPLATE_DIR = (os.getenv("DEPLOY_TEMPLATE_DIR") or "/var/www/hyper-host-deploy/template").strip()
DEPLOY_BOTS_BASE_DIR = (os.getenv("DEPLOY_BOTS_BASE_DIR") or "/var/www/hyper-host-managed-bots").strip()

PYTHON_BIN = (os.getenv("PYTHON_BIN") or "python3").strip()
PIP_BIN = (os.getenv("PIP_BIN") or os.getenv("DEPLOY_PIP") or "pip3").strip()
PM2_BIN = (os.getenv("PM2_BIN") or os.getenv("DEPLOY_PM2") or "pm2").strip()

POLL_SEC = int((os.getenv("DEPLOY_POLL_SEC") or "3").strip())
GC_SEC = int((os.getenv("DEPLOY_GC_SEC") or "15").strip())  # убийца зомби каждые 15 сек

MAX_OUTPUT_SNIP = 1800

# WebApp URL для пользователей
WEBAPP_URL = "https://mystockbot.ru/panel/new_panel/webapp"


# =========================
# UTILS
# =========================
def html_escape(s: str) -> str:
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def slugify(name: str) -> str:
    s = (name or "").strip().lower()
    s = re.sub(r"[^a-z0-9а-яё\-_ ]+", "", s, flags=re.I)
    s = s.replace(" ", "_")
    s = re.sub(r"_+", "_", s)
    return (s[:48] or "project").strip("_") or "project"


def token_looks_valid(token: str) -> bool:
    return bool(re.match(r"^\d+:[A-Za-z0-9_-]{20,}$", token or ""))


def bin_exists(path_or_name: str) -> bool:
    p = Path(path_or_name)
    if p.is_absolute():
        return p.exists()
    import shutil as _shutil
    return _shutil.which(path_or_name) is not None


async def run_cmd(*args: str, cwd: Optional[str] = None) -> tuple[int, str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        out = await proc.stdout.read() if proc.stdout else b""
        return int(proc.returncode or 0), out.decode("utf-8", "ignore")
    except FileNotFoundError:
        return 127, f"Binary not found: {args[0]}"
    except Exception as e:
        return 1, f"run_cmd error: {e}"


def wow_menu_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🧠 Панель", callback_data="dash"),
         InlineKeyboardButton(text="🔄 Обновить", callback_data="dash_refresh")],
        [InlineKeyboardButton(text="🤖 Активные", callback_data="bots_active"),
         InlineKeyboardButton(text="⏳ Очередь", callback_data="queue")],
        [InlineKeyboardButton(text="⚠️ Ошибки", callback_data="bots_failed"),
         InlineKeyboardButton(text="📦 Все", callback_data="bots_all")],
        [InlineKeyboardButton(text="🧹 GC: зомби-контроль", callback_data="gc_run"),
         InlineKeyboardButton(text="📋 pm2 list", callback_data="pm2_list")],
    ])


def user_webapp_kb() -> InlineKeyboardMarkup:
    """Клавиатура с кнопкой WebApp для обычных пользователей"""
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="🚀 Открыть WebApp",
            web_app=WebAppInfo(url=WEBAPP_URL)
        )],
    ])


def upgrade_plan_kb() -> InlineKeyboardMarkup:
    """Клавиатура с кнопкой для обновления тарифа"""
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="💎 Обновить тариф",
            url=SITE_BASE_URL
        )],
    ])


# =========================
# DB
# =========================
class DB:
    def __init__(self) -> None:
        self.pool: aiomysql.Pool | None = None

    async def connect(self) -> None:
        if self.pool:
            return
        if not DB_NAME:
            raise RuntimeError("DB_NAME пустой. Заполни DB_NAME в .env")
        self.pool = await aiomysql.create_pool(
            host=DB_HOST,
            port=DB_PORT,
            user=DB_USER,
            password=DB_PASS,
            db=DB_NAME,
            autocommit=True,
            charset="utf8mb4",
            init_command="SET NAMES utf8mb4 COLLATE utf8mb4_general_ci",
            minsize=1,
            maxsize=10,
        )

    async def close(self) -> None:
        if self.pool:
            self.pool.close()
            await self.pool.wait_closed()
            self.pool = None

    async def fetchone(self, sql: str, args: tuple = ()) -> Optional[dict]:
        assert self.pool
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(sql, args)
                return await cur.fetchone()

    async def fetchall(self, sql: str, args: tuple = ()) -> list[dict]:
        assert self.pool
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(sql, args)
                return await cur.fetchall()

    async def execute(self, sql: str, args: tuple = ()) -> int:
        assert self.pool
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(sql, args)
                return int(cur.rowcount or 0)

    async def ensure_deployments_table(self) -> None:
        await self.execute("""
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
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        """)

    # admins
    async def is_admin(self, tg_id: int) -> bool:
        row = await self.fetchone("SELECT 1 FROM users WHERE tg_id=%s AND role='admin' LIMIT 1", (tg_id,))
        return bool(row)

    async def get_admin_tg_ids(self) -> list[int]:
        rows = await self.fetchall("SELECT tg_id FROM users WHERE role='admin'")
        return [int(r["tg_id"]) for r in rows if r.get("tg_id")]

    # users
    async def get_user_by_tg_id(self, tg_id: int) -> Optional[dict]:
        """Получить пользователя по tg_id"""
        return await self.fetchone(
            "SELECT id, tg_id, username, first_name, role, subscription_status FROM users WHERE tg_id=%s LIMIT 1",
            (tg_id,)
        )

    # queue
    async def get_next_pending_request(self) -> Optional[dict]:
        return await self.fetchone("""
            SELECT
                u.id AS id,
                u.tg_id,
                u.username,
                p.id AS project_id,
                p.project_name,
                p.bot_token
            FROM projects p
            JOIN users u ON u.id = p.user_id
            WHERE u.role IN ('user','admin')
              AND u.bot_active='pending'
              AND p.bot_token IS NOT NULL AND TRIM(p.bot_token) <> ''
              AND p.project_name IS NOT NULL AND TRIM(p.project_name) <> ''
            ORDER BY p.updated_at ASC, p.id ASC
            LIMIT 1
        """)

    async def mark_user_status(self, user_id: int, status: str) -> None:
        await self.execute("UPDATE users SET bot_active=%s, updated_at=NOW() WHERE id=%s", (status, user_id))

    async def count_queue(self) -> dict:
        p = await self.fetchone("SELECT COUNT(*) AS c FROM users WHERE role='user' AND bot_active='pending'")
        w = await self.fetchone("SELECT COUNT(*) AS c FROM users WHERE role='user' AND bot_active='in_work'")
        a = await self.fetchone("SELECT COUNT(*) AS c FROM users WHERE role='user' AND bot_active='active'")
        return {"pending": int((p or {}).get("c") or 0), "in_work": int((w or {}).get("c") or 0), "active_users": int((a or {}).get("c") or 0)}

    # projects
    async def get_project_by_user(self, user_id: int) -> Optional[dict]:
        return await self.fetchone("SELECT * FROM projects WHERE user_id=%s LIMIT 1", (user_id,))

    async def get_project_by_id(self, proj_id: int) -> Optional[dict]:
        return await self.fetchone("SELECT * FROM projects WHERE id=%s LIMIT 1", (proj_id,))

    async def get_user_by_id(self, user_id: int) -> Optional[dict]:
        return await self.fetchone("SELECT * FROM users WHERE id=%s LIMIT 1", (user_id,))

    # deployments
    async def get_deployment_by_user(self, user_id: int) -> Optional[dict]:
        return await self.fetchone("SELECT * FROM bot_deployments WHERE user_id=%s LIMIT 1", (user_id,))

    async def upsert_deployment(self, user_id: int, project_id: Optional[int], pm2_name: str, deploy_path: str, status: str, last_error: Optional[str] = None) -> None:
        ex = await self.get_deployment_by_user(user_id)
        if not ex:
            await self.execute("""
                INSERT INTO bot_deployments (user_id, project_id, pm2_name, deploy_path, status, last_error)
                VALUES (%s, %s, %s, %s, %s, %s)
            """, (user_id, project_id, pm2_name, deploy_path, status, last_error))
        else:
            await self.execute("""
                UPDATE bot_deployments
                   SET project_id=%s, pm2_name=%s, deploy_path=%s, status=%s, last_error=%s, updated_at=NOW()
                 WHERE user_id=%s
            """, (project_id, pm2_name, deploy_path, status, last_error, user_id))

    async def list_deployments(self, limit: int = 50, status: Optional[str] = None) -> list[dict]:
        if status:
            return await self.fetchall("""
                SELECT d.*, u.username, p.project_name
                  FROM bot_deployments d
                  LEFT JOIN users u ON d.user_id=u.id
                  LEFT JOIN projects p ON d.project_id=p.id
                 WHERE d.status=%s
                 ORDER BY d.updated_at DESC
                 LIMIT %s
            """, (status, limit))
        else:
            return await self.fetchall("""
                SELECT d.*, u.username, p.project_name
                  FROM bot_deployments d
                  LEFT JOIN users u ON d.user_id=u.id
                  LEFT JOIN projects p ON d.project_id=p.id
                 ORDER BY d.updated_at DESC
                 LIMIT %s
            """, (limit,))


db = DB()
bot: Optional[Bot] = None
dp = Dispatcher()


# =========================
# DEPLOY WORKER
# =========================
def short_status_emoji(status: str) -> str:
    return {"deploying": "⏳", "active": "🟢", "failed": "🔴", "stopped": "⏸"}.get(status, "❓")


async def render_dashboard(db: DB) -> str:
    q = await db.count_queue()
    deploys = await db.list_deployments(limit=10)
    active = [x for x in deploys if x.get("status") == "active"]
    failed = [x for x in deploys if x.get("status") == "failed"]

    lines = [
        "🤖 <b>MyStock Deploy Bot</b>",
        "━━━━━━━━━━━━━━━━━━",
        f"📊 Pending: <b>{q['pending']}</b> | In work: <b>{q['in_work']}</b> | Active users: <b>{q['active_users']}</b>",
        f"🟢 Active bots: <b>{len(active)}</b>",
        f"🔴 Failed: <b>{len(failed)}</b>",
        "━━━━━━━━━━━━━━━━━━",
    ]
    return "\n".join(lines)


async def notify_admins(text: str) -> None:
    if not bot:
        return
    admin_ids = await db.get_admin_tg_ids()
    for aid in admin_ids:
        try:
            await bot.send_message(aid, text, parse_mode=ParseMode.HTML)
        except Exception:
            pass


async def kill_pm2_process(pm2_name: str) -> str:
    if not bin_exists(PM2_BIN):
        return "pm2 not found"
    code, out = await run_cmd(PM2_BIN, "delete", pm2_name)
    return out


async def deploy_bot(user_id: int, proj_id: int, proj_name: str, bot_token: str) -> tuple[bool, str]:
    try:
        slug = slugify(proj_name)
        pm2_name = f"shop_{proj_id}_{slug}"
        dest = Path(DEPLOY_BOTS_BASE_DIR) / f"{proj_id}-{slug}"

        if dest.exists():
            shutil.rmtree(dest, ignore_errors=True)
        dest.mkdir(parents=True, exist_ok=True)

        src = Path(DEPLOY_TEMPLATE_DIR)
        if not src.exists():
            return False, f"Template dir not found: {src}"

        for item in src.iterdir():
            if item.is_file():
                shutil.copy2(item, dest / item.name)
            elif item.is_dir():
                shutil.copytree(item, dest / item.name, dirs_exist_ok=True)

        env_file = dest / ".env"
        env_content = (
            f"BOT_TOKEN={bot_token}\n"
            f"DB_HOST={DB_HOST}\n"
            f"DB_PORT={DB_PORT}\n"
            f"DB_USER={DB_USER}\n"
            f"DB_PASS={DB_PASS}\n"
            f"DB_NAME={DB_NAME}\n"
            f"PROJECT_ID={proj_id}\n"
            f"PROJECT_NAME={proj_name}\n"
            f"OWNER_USER_ID={user_id}\n"
        )
        env_file.write_text(env_content, encoding="utf-8")
        try:
            env_file.chmod(0o600)
        except Exception:
            pass

        if not bin_exists(PIP_BIN):
            return False, "pip not found"

        code, out = await run_cmd(PIP_BIN, "install", "-r", "requirements.txt", cwd=str(dest))
        if code != 0:
            return False, f"pip install failed:\n{out}"

        if not bin_exists(PM2_BIN):
            return False, "pm2 not found"

        code, out = await run_cmd(PM2_BIN, "delete", pm2_name)
        code, out = await run_cmd(PM2_BIN, "start", "bot.py", "--name", pm2_name, "--interpreter", PYTHON_BIN, cwd=str(dest))
        if code != 0:
            return False, f"pm2 start failed:\n{out}"

        return True, "Deploy OK"
    except Exception as e:
        return False, f"Deploy exception: {e}\n{traceback.format_exc()}"


async def deploy_worker() -> None:
    while True:
        try:
            req = await db.get_next_pending_request()
            if not req:
                await asyncio.sleep(POLL_SEC)
                continue

            user_id = int(req["id"])
            tg_id = int(req["tg_id"])
            username = req.get("username") or f"user_{tg_id}"
            proj_name = req["project_name"]
            bot_token = req["bot_token"]

            if not token_looks_valid(bot_token):
                await db.mark_user_status(user_id, "pending")
                await notify_admins(f"⚠️ Invalid token for {username}")
                await asyncio.sleep(POLL_SEC)
                continue

            await db.mark_user_status(user_id, "in_work")
            await notify_admins(f"⏳ Deploying bot for {username} ({proj_name})…")

            proj_id = int(req.get("project_id") or 0)
            proj = await db.get_project_by_id(proj_id) if proj_id else await db.get_project_by_user(user_id)
            proj_id = int(proj["id"]) if proj else proj_id

            slug = slugify(proj_name)
            pm2_name = f"shop_{proj_id}_{slug}"
            dest = Path(DEPLOY_BOTS_BASE_DIR) / f"{proj_id}-{slug}"

            await db.upsert_deployment(user_id, proj_id, pm2_name, str(dest), "deploying", None)

            success, msg = await deploy_bot(user_id, proj_id, proj_name, bot_token)
            if success:
                await db.mark_user_status(user_id, "active")
                await db.upsert_deployment(user_id, proj_id, pm2_name, str(dest), "active", None)
                await notify_admins(f"✅ Bot deployed: {username} ({proj_name})")
            else:
                await db.mark_user_status(user_id, "pending")
                await db.upsert_deployment(user_id, proj_id, pm2_name, str(dest), "failed", msg[:4000])
                await notify_admins(f"🔴 Deploy failed: {username}\n{msg[:500]}")

        except Exception as e:
            print(f"[deploy_worker error] {e}")
            await asyncio.sleep(POLL_SEC)


async def gc_worker(force_once: bool = False) -> None:
    while True:
        try:
            if not bin_exists(PM2_BIN):
                if force_once:
                    return
                await asyncio.sleep(max(5, GC_SEC))
                continue

            code, out = await run_cmd(PM2_BIN, "jlist")
            if code != 0:
                if force_once:
                    return
                await asyncio.sleep(max(5, GC_SEC))
                continue

            try:
                import json
                processes = json.loads(out)
            except Exception:
                processes = []

            for proc in processes:
                if not isinstance(proc, dict):
                    continue
                pm2_name = proc.get("name", "")
                if not (pm2_name.startswith("bot_") or pm2_name.startswith("shop_")):
                    continue

                try:
                    deploy_path = proc.get("pm_cwd") or ""
                    match = re.match(r"(?:bot_(\d+)|shop_(\d+))_", pm2_name)
                    if not match:
                        continue
                    user_id = int(match.group(1) or 0)
                    if pm2_name.startswith('shop_'):
                        project_id_from_name = int(match.group(2) or 0)
                        p_by_name = await db.get_project_by_id(project_id_from_name)
                        if p_by_name:
                            user_id = int(p_by_name.get('user_id') or 0)

                    dep = await db.get_deployment_by_user(user_id)
                    project_id = int(dep.get("project_id") or 0) if dep else None

                    u = await db.get_user_by_id(user_id)
                    p = await db.get_project_by_id(project_id) if project_id else None

                    should_kill = False
                    reason = ""

                    if not u:
                        should_kill = True
                        reason = "user deleted"
                    else:
                        if (u.get("bot_active") or "") != "active":
                            should_kill = True
                            reason = f"user.bot_active={u.get('bot_active')}"

                    if not p:
                        should_kill = True
                        reason = reason or "project deleted"

                    if deploy_path and not Path(deploy_path).exists():
                        should_kill = True
                        reason = reason or "deploy_path missing"

                    if should_kill:
                        out = await kill_pm2_process(pm2_name)
                        await db.upsert_deployment(user_id, project_id, pm2_name, deploy_path, "stopped", f"GC: {reason} | {out}"[:4000])
                except Exception:
                    continue
        except Exception:
            pass

        if force_once:
            return
        await asyncio.sleep(max(5, GC_SEC))


# =========================
# HANDLERS
# =========================
async def guard_admin(user_id: int) -> bool:
    try:
        return await db.is_admin(user_id)
    except Exception:
        return False


@dp.message(CommandStart())
async def start(m: Message):
    """
    Команда /start теперь работает для всех пользователей:
    - Админы получают панель управления
    - Обычные пользователи проверяются на подписку и получают доступ к webapp
    """
    if not m.from_user:
        return

    tg_id = m.from_user.id
    
    # Проверяем, является ли пользователь админом
    is_admin = await guard_admin(tg_id)
    
    if is_admin:
        # Админ - показываем панель управления
        text = await render_dashboard(db)
        await m.answer(text, reply_markup=wow_menu_kb())
    else:
        # Обычный пользователь - проверяем подписку
        user = await db.get_user_by_tg_id(tg_id)
        
        if not user:
            # Пользователь не найден в базе
            await m.answer(
                "❌ Вы не зарегистрированы в системе MyStockBot.\n\n"
                "Для начала работы зарегистрируйтесь на нашем сайте:",
                reply_markup=upgrade_plan_kb()
            )
            return
        
        subscription_status = user.get("subscription_status", "free")
        
        if subscription_status == "free":
            # У пользователя бесплатный тариф - предлагаем обновить
            await m.answer(
                "⚠️ <b>Ограничение тарифа</b>\n\n"
                "На вашей подписке нельзя управлять магазином из WebApp.\n\n"
                "Пожалуйста, обновите тариф для получения полного доступа ко всем возможностям MyStockBot! 🚀\n\n"
                "После обновления тарифа вы сможете:\n"
                "• Управлять ботом и магазином прямо из WebApp\n"
                "• Получить доступ к расширенным функциям\n"
                "• Использовать профессиональные инструменты продаж",
                reply_markup=upgrade_plan_kb()
            )
        else:
            # У пользователя платный тариф - даем доступ к webapp
            first_name = user.get("first_name") or user.get("username") or "Пользователь"
            await m.answer(
                f"🎉 <b>Добро пожаловать, {html_escape(first_name)}!</b>\n\n"
                "✨ <b>Управление ботом и магазином прямо из WebApp</b>\n\n"
                "Вы используете <b>MyStockBot</b> — современную платформу для создания "
                "и управления Telegram-магазинами.\n\n"
                "🚀 Нажмите кнопку ниже, чтобы открыть панель управления вашим магазином!\n\n"
                f"📊 Ваш тариф: <b>{html_escape(subscription_status)}</b>",
                reply_markup=user_webapp_kb()
            )


@dp.message(Command("menu"))
async def menu(m: Message):
    """Команда /menu только для админов"""
    if not m.from_user or not await guard_admin(m.from_user.id):
        await m.answer("⛔️ Эта команда доступна только администраторам.")
        return
    text = await render_dashboard(db)
    await m.answer(text, reply_markup=wow_menu_kb())


@dp.callback_query(F.data.in_({"dash", "dash_refresh"}))
async def cb_dash(cq: CallbackQuery):
    if not cq.from_user or not await guard_admin(cq.from_user.id):
        await cq.answer("⛔️ Доступ запрещен", show_alert=True)
        return
    text = await render_dashboard(db)
    if cq.message:
        try:
            await cq.message.edit_text(text, reply_markup=wow_menu_kb())
        except Exception:
            await cq.message.answer(text, reply_markup=wow_menu_kb())
    await cq.answer("Обновлено ✅" if cq.data == "dash_refresh" else "")


@dp.callback_query(F.data == "queue")
async def cb_queue(cq: CallbackQuery):
    if not cq.from_user or not await guard_admin(cq.from_user.id):
        await cq.answer("⛔️ Доступ запрещен", show_alert=True)
        return
    q = await db.count_queue()
    text = (
        "⏳ <b>Очередь</b>\n"
        "━━━━━━━━━━━━━━━━━━\n"
        f"pending: <b>{q['pending']}</b>\n"
        f"in_work: <b>{q['in_work']}</b>\n"
        f"active(users): <b>{q['active_users']}</b>\n"
    )
    if cq.message:
        await cq.message.answer(text, reply_markup=wow_menu_kb())
    await cq.answer()


@dp.callback_query(F.data == "bots_active")
async def cb_bots_active(cq: CallbackQuery):
    if not cq.from_user or not await guard_admin(cq.from_user.id):
        await cq.answer("⛔️ Доступ запрещен", show_alert=True)
        return
    items = await db.list_deployments(limit=25, status="active")
    if not items:
        if cq.message:
            await cq.message.answer("🟢 Активных деплоев пока нет.", reply_markup=wow_menu_kb())
        await cq.answer()
        return
    lines = ["🟢 <b>Активные боты</b>", "━━━━━━━━━━━━━━━━━━"]
    for it in items:
        pid = int(it.get("project_id") or 0)
        name = it.get("project_name") or "-"
        pm2n = it.get("pm2_name") or "-"
        lines.append(f"🟢 <b>{html_escape(name)}</b> • <code>{pid}</code>\n<code>{html_escape(pm2n)}</code>")
    if cq.message:
        await cq.message.answer("\n".join(lines), reply_markup=wow_menu_kb())
    await cq.answer()


@dp.callback_query(F.data == "bots_failed")
async def cb_bots_failed(cq: CallbackQuery):
    if not cq.from_user or not await guard_admin(cq.from_user.id):
        await cq.answer("⛔️ Доступ запрещен", show_alert=True)
        return
    items = await db.list_deployments(limit=25, status="failed")
    if not items:
        if cq.message:
            await cq.message.answer("⚠️ Ошибок нет 😎", reply_markup=wow_menu_kb())
        await cq.answer()
        return
    lines = ["🔴 <b>Ошибки</b>", "━━━━━━━━━━━━━━━━━━"]
    for it in items:
        pid = int(it.get("project_id") or 0)
        name = it.get("project_name") or "-"
        pm2n = it.get("pm2_name") or "-"
        lines.append(f"🔴 <b>{html_escape(name)}</b> • <code>{pid}</code>\n<code>{html_escape(pm2n)}</code>")
    if cq.message:
        await cq.message.answer("\n".join(lines), reply_markup=wow_menu_kb())
    await cq.answer()


@dp.callback_query(F.data == "bots_all")
async def cb_bots_all(cq: CallbackQuery):
    if not cq.from_user or not await guard_admin(cq.from_user.id):
        await cq.answer("⛔️ Доступ запрещен", show_alert=True)
        return
    items = await db.list_deployments(limit=40)
    if not items:
        if cq.message:
            await cq.message.answer("Деплоев нет.", reply_markup=wow_menu_kb())
        await cq.answer()
        return
    lines = ["📦 <b>Все деплои</b>", "━━━━━━━━━━━━━━━━━━"]
    for it in items:
        st = it.get("status") or "-"
        pid = int(it.get("project_id") or 0)
        name = it.get("project_name") or "-"
        pm2n = it.get("pm2_name") or "-"
        lines.append(f"{short_status_emoji(st)} <b>{html_escape(name)}</b> • <code>{pid}</code> • <b>{html_escape(st)}</b>\n<code>{html_escape(pm2n)}</code>")
    if cq.message:
        await cq.message.answer("\n".join(lines), reply_markup=wow_menu_kb())
    await cq.answer()


@dp.callback_query(F.data == "gc_run")
async def cb_gc_run(cq: CallbackQuery):
    if not cq.from_user or not await guard_admin(cq.from_user.id):
        await cq.answer("⛔️ Доступ запрещен", show_alert=True)
        return
    await cq.answer("GC запущен…", show_alert=False)
    await gc_worker(force_once=True)
    if cq.message:
        await cq.message.answer("🧹 GC выполнен. Зомби-процессы прибиты (если были).", reply_markup=wow_menu_kb())


@dp.callback_query(F.data == "pm2_list")
async def cb_pm2_list(cq: CallbackQuery):
    if not cq.from_user or not await guard_admin(cq.from_user.id):
        await cq.answer("⛔️ Доступ запрещен", show_alert=True)
        return
    if not bin_exists(PM2_BIN):
        await cq.answer("pm2 не найден", show_alert=True)
        return
    code, out = await run_cmd(PM2_BIN, "ls")
    text = f"📋 <b>pm2 ls</b>\n<pre>{html_escape(out[-MAX_OUTPUT_SNIP:])}</pre>"
    if cq.message:
        await cq.message.answer(text, reply_markup=wow_menu_kb())
    await cq.answer()


# =========================
# ENTRY
# =========================
async def main() -> None:
    try:
        await db.connect()
        await db.ensure_deployments_table()
    except Exception as e:
        print(f"[fatal] DB error: {e}")
        return

    global bot
    if not BOT_TOKEN:
        print("[fatal] BOT_TOKEN пустой. Заполни BOT_TOKEN в .env рядом с bot.py.")
        await db.close()
        return

    bot = Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))

    # стартовое уведомление
    try:
        await notify_admins("✅ <b>Deploy Bot запущен</b>\n" + await render_dashboard(db))
    except Exception:
        pass

    asyncio.create_task(deploy_worker())
    asyncio.create_task(gc_worker(force_once=False))

    try:
        await dp.start_polling(bot)
    finally:
        await db.close()


if __name__ == "__main__":
    asyncio.run(main())
