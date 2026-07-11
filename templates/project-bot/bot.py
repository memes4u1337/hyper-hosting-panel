# =========================
# bot.py (FULL REWRITE: no .env required, auto DB + token detect, stable bootstrap)
# =========================
from __future__ import annotations

import os
import asyncio
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import aiomysql
from pymysql.err import OperationalError as PyMySQLOperationalError

from aiogram import Bot, Dispatcher, F
from aiogram.enums import ParseMode, ChatMemberStatus
from aiogram.filters import CommandStart
from aiogram.types import (
    Message, CallbackQuery, ChatMemberUpdated,
    InlineKeyboardMarkup, InlineKeyboardButton, WebAppInfo
)
from aiogram.dispatcher.middlewares.base import BaseMiddleware
from aiogram.client.default import DefaultBotProperties


# =========================
# OPTIONAL .env (NEVER CRASH)
# =========================
def safe_load_dotenv() -> None:
    """
    .env НЕ ОБЯЗАТЕЛЕН.
    Загружаем только если файл существует рядом с bot.py.
    Никаких поисков по cwd (они и ломались у тебя).
    """
    try:
        from dotenv import load_dotenv  # type: ignore
    except Exception:
        return

    try:
        env_path = Path(__file__).resolve().parent / ".env"
        if env_path.exists():
            load_dotenv(dotenv_path=str(env_path), override=False)
    except Exception:
        # вообще игнорируем любые ошибки dotenv
        return


safe_load_dotenv()


# =========================
# CONFIG
# =========================
DEFAULT_TEXT = (
    "🛍 Новый бот-магазин\n"
    "Создан на mystockbot.ru (https://mystockbot.ru/).\n\n"
    "Добро пожаловать! Нажмите кнопки ниже, чтобы начать.\n\n"
    "Чтобы поменять текст и изображение - зайдите в Личный Кабинет⟶Настройки⟶Настройки бота"
)
DEFAULT_IMAGE_URL = None
BASE_URL = "https://mystockbot.ru"  # нормализация относительных путей к картинкам

# DB defaults (если вообще ничего не задано)
DB_HOST = os.getenv("DB_HOST", "127.0.0.1")
DB_USER = os.getenv("DB_USER", "root")
DB_PASS = os.getenv("DB_PASS", "")
DB_NAME = os.getenv("DB_NAME")  # можем авто-определить, если пусто

# project hints (не обязательны)
PROJECT_ID = os.getenv("PROJECT_ID")
PROJECT_NAME = os.getenv("PROJECT_NAME")

# token hint (не обязателен, если есть в DB)
BOT_TOKEN_ENV = os.getenv("BOT_TOKEN")


# =========================
# UTILS
# =========================
def html_escape(s: str) -> str:
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def safe_name(first_name: str | None, last_name: str | None) -> str:
    full = " ".join([x for x in [first_name, last_name] if x])
    return full if full else "—"


def resolve_url(path_or_url: str | None) -> str | None:
    """Превращает относительный путь /... в абсолютный URL, абсолютные http(s) оставляет как есть."""
    if not path_or_url:
        return None
    s = str(path_or_url).strip()
    if not s:
        return None
    if s.startswith("http://") or s.startswith("https://"):
        return s
    if s.startswith("/"):
        return f"{BASE_URL}{s}"
    return f"{BASE_URL}/{s}"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def is_expired(expires_at: Any) -> bool:
    if not expires_at:
        return True
    if isinstance(expires_at, str):
        try:
            expires_at = datetime.fromisoformat(expires_at)
        except Exception:
            return False
    if isinstance(expires_at, datetime):
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        return expires_at < utc_now()
    return False


# =========================
# DB
# =========================
REQUIRED_TABLES = {
    "projects",
    "users",
    "bot_subscribers",
}

OPTIONAL_TABLES = {
    "bot_start_message",
    "bot_start_message_all_user",
    "bot_settings",
    "subscription_plan_limits",
    "v_owner_plan_usage",
}

class DB:
    def __init__(self):
        self.pool: aiomysql.Pool | None = None
        self.db_name: str | None = None

    async def _create_pool(self, db: str | None) -> aiomysql.Pool:
        return await aiomysql.create_pool(
            host=DB_HOST,
            user=DB_USER,
            password=DB_PASS,
            db=db,  # может быть None -> подключение без выбора схемы
            autocommit=True,
            charset="utf8mb4",
            # Выравниваем кодировку строковых параметров соединения.
            # Основное исправление конфликта колонок находится в get_owner_usage().
            init_command="SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci",
            minsize=1,
            maxsize=10,
        )

    async def connect(self):
        """
        1) если DB_NAME задан -> подключаемся к нему
        2) если DB_NAME НЕ задан -> подключаемся без схемы, ищем подходящую по таблицам
        """
        if self.pool:
            return

        try:
            if DB_NAME:
                self.pool = await self._create_pool(DB_NAME)
                self.db_name = DB_NAME
                return

            # подключаемся без db, чтобы найти нужную схему
            tmp_pool = await self._create_pool(None)
            try:
                async with tmp_pool.acquire() as conn:
                    async with conn.cursor(aiomysql.DictCursor) as cur:
                        # ищем схемы, где есть ВСЕ required таблицы
                        placeholders = ",".join(["%s"] * len(REQUIRED_TABLES))
                        await cur.execute(
                            f"""
                            SELECT table_schema,
                                   SUM(table_name IN ({placeholders})) AS hit
                            FROM information_schema.tables
                            WHERE table_type='BASE TABLE'
                            GROUP BY table_schema
                            HAVING hit = %s
                            """,
                            (*REQUIRED_TABLES, len(REQUIRED_TABLES)),
                        )
                        candidates = await cur.fetchall()

                        if not candidates:
                            raise RuntimeError(
                                "Не смог авто-определить DB_NAME: не нашёл схему с таблицами "
                                f"{sorted(REQUIRED_TABLES)}. Задай DB_NAME переменной окружения."
                            )

                        # если несколько — ранжируем по количеству optional таблиц
                        best_schema = None
                        best_score = -1

                        for row in candidates:
                            schema = row["table_schema"]
                            await cur.execute(
                                f"""
                                SELECT SUM(table_name IN ({",".join(["%s"]*len(OPTIONAL_TABLES))})) AS opt
                                FROM information_schema.tables
                                WHERE table_schema=%s
                                """,
                                (*OPTIONAL_TABLES, schema),
                            )
                            opt_row = await cur.fetchone()
                            score = int((opt_row or {}).get("opt") or 0)
                            if score > best_score:
                                best_score = score
                                best_schema = schema

                        if not best_schema:
                            best_schema = candidates[0]["table_schema"]

                        self.pool = await self._create_pool(best_schema)
                        self.db_name = best_schema
            finally:
                tmp_pool.close()
                await tmp_pool.wait_closed()

        except PyMySQLOperationalError as e:
            raise RuntimeError(f"Не удалось подключиться к MySQL: {e}")

    async def close(self):
        if self.pool:
            self.pool.close()
            await self.pool.wait_closed()
            self.pool = None

    async def fetchone(self, sql: str, args=None) -> dict | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(sql, args or ())
                return await cur.fetchone()

    async def fetchall(self, sql: str, args=None) -> list[dict]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(sql, args or ())
                return await cur.fetchall()

    async def execute(self, sql: str, args=None) -> int:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(sql, args or ())
                return cur.rowcount

    # ---- project resolution ----
    async def get_project_and_owner_by_token(self, token: str) -> dict | None:
        return await self.fetchone("""
            SELECT
                pr.id AS project_id,
                pr.project_name,
                pr.bot_token,
                u.id        AS owner_user_id,
                u.username  AS owner_username,
                u.tg_id     AS owner_tg_id,
                u.subscription_status,
                u.subscription_expires_at AS expires_at,
                u.webapp_url AS owner_webapp_url
            FROM projects pr
            JOIN users u ON u.id = pr.user_id
            WHERE TRIM(pr.bot_token)=TRIM(%s)
            LIMIT 1
        """, (token,))

    async def get_project_and_owner_by_id(self, pid: int) -> dict | None:
        return await self.fetchone("""
            SELECT
                pr.id AS project_id,
                pr.project_name,
                pr.bot_token,
                u.id        AS owner_user_id,
                u.username  AS owner_username,
                u.tg_id     AS owner_tg_id,
                u.subscription_status,
                u.subscription_expires_at AS expires_at,
                u.webapp_url AS owner_webapp_url
            FROM projects pr
            JOIN users u ON u.id = pr.user_id
            WHERE pr.id=%s
            LIMIT 1
        """, (pid,))

    async def get_project_and_owner_by_name(self, name: str) -> dict | None:
        return await self.fetchone("""
            SELECT
                pr.id AS project_id,
                pr.project_name,
                pr.bot_token,
                u.id        AS owner_user_id,
                u.username  AS owner_username,
                u.tg_id     AS owner_tg_id,
                u.subscription_status,
                u.subscription_expires_at AS expires_at,
                u.webapp_url AS owner_webapp_url
            FROM projects pr
            JOIN users u ON u.id = pr.user_id
            WHERE pr.project_name=%s
            LIMIT 1
        """, (name,))

    async def auto_pick_project(self) -> dict | None:
        """
        Если не задан BOT_TOKEN/PROJECT_ID/PROJECT_NAME:
        - если в projects ровно один непустой bot_token -> берём его
        - иначе берём самый свежий проект с непустым bot_token
        """
        row = await self.fetchone("""
            SELECT COUNT(*) AS cnt
            FROM projects
            WHERE bot_token IS NOT NULL AND TRIM(bot_token) <> ''
        """)
        cnt = int((row or {}).get("cnt") or 0)

        if cnt == 1:
            return await self.fetchone("""
                SELECT
                    pr.id AS project_id,
                    pr.project_name,
                    pr.bot_token,
                    u.id        AS owner_user_id,
                    u.username  AS owner_username,
                    u.tg_id     AS owner_tg_id,
                    u.subscription_status,
                    u.subscription_expires_at AS expires_at,
                    u.webapp_url AS owner_webapp_url
                FROM projects pr
                JOIN users u ON u.id = pr.user_id
                WHERE pr.bot_token IS NOT NULL AND TRIM(pr.bot_token) <> ''
                LIMIT 1
            """)

        return await self.fetchone("""
            SELECT
                pr.id AS project_id,
                pr.project_name,
                pr.bot_token,
                u.id        AS owner_user_id,
                u.username  AS owner_username,
                u.tg_id     AS owner_tg_id,
                u.subscription_status,
                u.subscription_expires_at AS expires_at,
                u.webapp_url AS owner_webapp_url
            FROM projects pr
            JOIN users u ON u.id = pr.user_id
            WHERE pr.bot_token IS NOT NULL AND TRIM(pr.bot_token) <> ''
            ORDER BY pr.updated_at DESC, pr.id DESC
            LIMIT 1
        """)

    async def get_owner_usage(self, owner_user_id: int) -> dict:
        """
        Не используем v_owner_plan_usage: внутри старого VIEW сравниваются
        строки с utf8mb4_unicode_ci и utf8mb4_general_ci, из-за чего MariaDB
        возвращает ошибку 1267.

        Явно приводим обе стороны строкового JOIN к одной кодировке/collation.
        Это исправляет запрос без изменения таблиц, внешних ключей и данных.
        """
        row = await self.fetchone("""
            SELECT
              u.subscription_status,
              u.subscription_expires_at AS expires_at,
              COALESCE(l.bot_users, 0) AS limit_bot_users,
              (
                SELECT COUNT(DISTINCT s.tg_id)
                FROM bot_subscribers s
                JOIN projects p2 ON p2.id = s.project_id
                WHERE p2.user_id = u.id
                  AND s.is_active = 1
              ) AS used_bot_users_distinct
            FROM users u
            LEFT JOIN subscription_plan_limits l
              ON CONVERT(l.slug USING utf8mb4) COLLATE utf8mb4_unicode_ci
               = CONVERT(u.subscription_status USING utf8mb4) COLLATE utf8mb4_unicode_ci
            WHERE u.id = %s
            LIMIT 1
        """, (owner_user_id,))

        return row or {
            "subscription_status": "free",
            "expires_at": None,
            "limit_bot_users": 0,
            "used_bot_users_distinct": 0,
        }

    # ---- subscribers ----
    async def get_existing_subscriber_id(self, project_id: int, tg_id: int) -> int | None:
        row = await self.fetchone(
            "SELECT id FROM bot_subscribers WHERE project_id=%s AND tg_id=%s AND is_active=1 LIMIT 1",
            (project_id, tg_id),
        )
        return (row or {}).get("id")

    async def insert_subscriber(self, project_id, tg_id, username, first_name, last_name, lang, chat_type):
        await self.execute("""
            INSERT INTO bot_subscribers
              (project_id, tg_id, username, first_name, last_name, language_code, chat_type, is_active, created_at, last_seen_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,1,NOW(),NOW())
        """, (project_id, tg_id, username, first_name, last_name, lang, chat_type))

    async def update_subscriber(self, sid: int, username, first_name, last_name, lang, chat_type):
        await self.execute("""
            UPDATE bot_subscribers
               SET username=%s, first_name=%s, last_name=%s,
                   language_code=%s, chat_type=%s, is_active=1, last_seen_at=NOW()
             WHERE id=%s
        """, (username, first_name, last_name, lang, chat_type, sid))

    async def deactivate_subscriber(self, project_id: int, tg_id: int):
        await self.execute("""
            UPDATE bot_subscribers
               SET is_active=0, last_seen_at=NOW()
             WHERE project_id=%s AND tg_id=%s
        """, (project_id, tg_id))

    async def purge_user_if_orphan(self, tg_id: int):
        try:
            await self.execute("CALL purge_orphan_user(%s)", (tg_id,))
        except Exception:
            await self.execute("""
                UPDATE users SET avatar_url=NULL, avatar_file_id=NULL, updated_at=NOW()
                WHERE tg_id=%s
            """, (tg_id,))

    async def update_user_avatar_row(self, tg_id, username, first_name, last_name, lang, avatar_url=None, avatar_file_id=None):
        await self.execute("""
            INSERT INTO users (tg_id, username, first_name, last_name, language_code, avatar_url, avatar_file_id, updated_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,NOW())
            ON DUPLICATE KEY UPDATE
              username=VALUES(username),
              first_name=VALUES(first_name),
              last_name=VALUES(last_name),
              language_code=VALUES(language_code),
              avatar_url=VALUES(avatar_url),
              avatar_file_id=VALUES(avatar_file_id),
              updated_at=NOW()
        """, (tg_id, username, first_name, last_name, lang, avatar_url, avatar_file_id))

    async def get_start_message(self, project_id: int):
        # 1) project-specific
        p = await self.fetchone("""
            SELECT start_text, image_path
            FROM bot_start_message
            WHERE project_id=%s
            LIMIT 1
        """, (project_id,))
        if p and (p.get("start_text") or p.get("image_path")):
            return {
                "start_text": p.get("start_text") or DEFAULT_TEXT,
                "image_path": resolve_url(p.get("image_path")),
            }

        # 2) all-user
        r = await self.fetchone("""
            SELECT start_text, start_image_url AS image_path
            FROM bot_start_message_all_user
            WHERE id=1
            LIMIT 1
        """)
        if r and (r.get("start_text") or r.get("image_path")):
            return {
                "start_text": r.get("start_text") or DEFAULT_TEXT,
                "image_path": resolve_url(r.get("image_path")),
            }

        # 3) global
        s = await self.fetchone("""
            SELECT start_text, start_image_url AS image_path
            FROM bot_settings WHERE id=1 LIMIT 1
        """)
        if s and (s.get("start_text") or s.get("image_path")):
            return {
                "start_text": s.get("start_text") or DEFAULT_TEXT,
                "image_path": resolve_url(s.get("image_path")),
            }

        # 4) default
        return {"start_text": DEFAULT_TEXT, "image_path": DEFAULT_IMAGE_URL}


# =========================
# UI
# =========================
def main_menu(
    webapp_url: str | None,
    subscription_status: str,
    catalog_enabled: bool,
    user_id: int | None = None,
    project_id: int | None = None,
) -> InlineKeyboardMarkup:
    rows = []
    if catalog_enabled and webapp_url:
        url = webapp_url
        params = []
        if project_id:
            params.append(f"project={project_id}")
        if user_id:
            params.append(f"tg_id={user_id}")
        if params:
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}{'&'.join(params)}"
        rows.append([InlineKeyboardButton(text="📦 Каталог", web_app=WebAppInfo(url=url))])
    else:
        rows.append([InlineKeyboardButton(text="⛔ Каталог недоступен", callback_data="catalog_blocked")])

    rows.append([InlineKeyboardButton(text="👤 Мой профиль", callback_data="profile")])
    if subscription_status == "free":
        rows.append([InlineKeyboardButton(text="🌐 Бот создан на mystockbot.ru", url="https://mystockbot.ru/")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


# =========================
# STATE
# =========================
dp = Dispatcher()
db = DB()

# Эти объекты заполняются bootstrap-ом
PROJECT: dict[str, Any] = {}
OWNER: dict[str, Any] = {}
START: dict[str, Any] = {}
WEBAPP: dict[str, Any] = {"url": None}
LAST_MENU: dict[int, int] = {}  # chat_id -> message_id

bot: Bot | None = None

# bootstrap cache
_BOOTSTRAP_LOCK = asyncio.Lock()
_BOOTSTRAP_READY = False
_BOOTSTRAP_AT: float = 0.0
_BOOTSTRAP_TTL_SEC = 15.0  # чтобы не дергать БД на каждый апдейт


# =========================
# CORE
# =========================
async def ensure_bootstrap(force: bool = False) -> None:
    global _BOOTSTRAP_READY, _BOOTSTRAP_AT, bot

    now = asyncio.get_running_loop().time()
    if _BOOTSTRAP_READY and not force and (now - _BOOTSTRAP_AT) < _BOOTSTRAP_TTL_SEC:
        return

    async with _BOOTSTRAP_LOCK:
        now = asyncio.get_running_loop().time()
        if _BOOTSTRAP_READY and not force and (now - _BOOTSTRAP_AT) < _BOOTSTRAP_TTL_SEC:
            return

        await db.connect()

        info: dict | None = None

        # 1) если дали токен окружением — основной путь
        if BOT_TOKEN_ENV:
            info = await db.get_project_and_owner_by_token(BOT_TOKEN_ENV)

        # 2) если не нашли — пробуем project hints
        if not info and PROJECT_ID:
            try:
                info = await db.get_project_and_owner_by_id(int(PROJECT_ID))
            except Exception:
                info = None

        if not info and PROJECT_NAME:
            info = await db.get_project_and_owner_by_name(PROJECT_NAME)

        # 3) полный автоподбор
        if not info:
            info = await db.auto_pick_project()

        if not info:
            raise RuntimeError(
                "Не смог определить проект.\n"
                "Нужно хотя бы одно:\n"
                "- BOT_TOKEN (если хочешь жёстко привязать)\n"
                "- или PROJECT_ID/PROJECT_NAME\n"
                "- или чтобы в projects был хотя бы один bot_token"
            )

        token = (info.get("bot_token") or "").strip()
        if not token:
            raise RuntimeError(f"У проекта id={info.get('project_id')} пустой bot_token в БД.")

        PROJECT.clear()
        PROJECT.update({
            "project_id": info["project_id"],
            "project_name": info["project_name"],
            "bot_token": token,
            "subscription_status": info.get("subscription_status", "free"),
            "owner_user_id": info["owner_user_id"],
            "expires_at": info.get("expires_at"),
        })

        OWNER.clear()
        OWNER.update({
            "user_id": info["owner_user_id"],
            "username": info.get("owner_username"),
            "tg_id": info.get("owner_tg_id"),
            "webapp_url": info.get("owner_webapp_url"),  # только из БД
        })

        START.clear()
        START.update(await db.get_start_message(PROJECT["project_id"]) or {})

        WEBAPP["url"] = OWNER.get("webapp_url")

        # создаём bot только сейчас (когда токен точно есть)
        if bot is None or getattr(bot, "token", None) != token:
            bot = Bot(
                token,
                default=DefaultBotProperties(parse_mode=ParseMode.HTML),
            )

        _BOOTSTRAP_READY = True
        _BOOTSTRAP_AT = asyncio.get_running_loop().time()


async def get_owner_usage_and_limits() -> dict:
    st = await db.get_owner_usage(PROJECT["owner_user_id"])
    return {
        "status": st.get("subscription_status", "free"),
        "limit": int(st.get("limit_bot_users") or 0),
        "used": int(st.get("used_bot_users_distinct") or 0),
        "expired": is_expired(st.get("expires_at")),
    }


async def can_add_new_user() -> tuple[bool, str]:
    st = await get_owner_usage_and_limits()
    ok = st["used"] < st["limit"]
    reason = "" if ok else f"Достигнут лимит пользователей: {st['used']} из {st['limit']}."
    return ok, reason


async def menu_enabled_for_user(user_id: int) -> bool:
    sid = await db.get_existing_subscriber_id(PROJECT["project_id"], user_id)
    if sid:
        return True
    ok, _ = await can_add_new_user()
    return ok


async def sync_menu(chat_id: int, user_id: int):
    if bot is None:
        return
    enabled = await menu_enabled_for_user(user_id)
    kb = main_menu(
        WEBAPP["url"],
        PROJECT.get("subscription_status", "free"),
        enabled,
        user_id=user_id,
        project_id=PROJECT.get("project_id"),
    )
    mid = LAST_MENU.get(chat_id)
    if not mid:
        return
    try:
        await bot.edit_message_reply_markup(chat_id=chat_id, message_id=mid, reply_markup=kb)
    except Exception:
        pass


# =========================
# MIDDLEWARE
# =========================
class LiveStateMiddleware(BaseMiddleware):
    async def __call__(self, handler, event, data):
        try:
            await ensure_bootstrap()
            chat_id, user_id = None, None
            if isinstance(event, Message):
                chat_id = event.chat.id
                user_id = event.from_user.id if event.from_user else None
            elif isinstance(event, CallbackQuery):
                chat_id = event.message.chat.id if event.message else None
                user_id = event.from_user.id if event.from_user else None
            if chat_id and user_id:
                await sync_menu(chat_id, user_id)
        except Exception as e:
            print(f"[middleware] {e}")
        return await handler(event, data)


dp.message.middleware(LiveStateMiddleware())
dp.callback_query.middleware(LiveStateMiddleware())


# =========================
# HANDLERS
# =========================
@dp.message(CommandStart())
async def handle_start(m: Message):
    await ensure_bootstrap()
    assert bot is not None

    u = m.from_user
    chat_id = m.chat.id

    # users: аватар/инфо
    try:
        photos = await bot.get_user_profile_photos(u.id, limit=1)
        avatar_url, file_id = None, None
        if photos.total_count > 0:
            photo = photos.photos[0][-1]
            file_id = photo.file_id
            f = await bot.get_file(file_id)
            avatar_url = f"https://api.telegram.org/file/bot{PROJECT['bot_token']}/{f.file_path}"
        await db.update_user_avatar_row(
            u.id, u.username, u.first_name, u.last_name, u.language_code, avatar_url, file_id
        )
    except Exception as e:
        print(f"[avatar] {e}")

    # 1) если уже есть — апдейт
    sid = await db.get_existing_subscriber_id(PROJECT["project_id"], u.id)
    if sid:
        await db.update_subscriber(sid, u.username, u.first_name, u.last_name, u.language_code, m.chat.type)
    else:
        # 2) новый пользователь — проверяем лимит
        ok, reason = await can_add_new_user()
        if ok:
            try:
                await db.insert_subscriber(
                    PROJECT["project_id"], u.id, u.username, u.first_name, u.last_name, u.language_code, m.chat.type
                )
            except PyMySQLOperationalError as e:
                # на случай гонки/триггера
                if getattr(e, "args", None) and len(e.args) >= 1 and e.args[0] == 1644:
                    await m.answer(
                        f"⚠️ <b>Каталог недоступен</b>\n{html_escape('Достигнут лимит пользователей тарифного плана.')}\n"
                        "Свяжитесь с администратором проекта."
                    )
                else:
                    raise
        else:
            await m.answer(
                "⚠️ <b>Каталог недоступен</b>\n"
                f"{html_escape(reason)}\n"
                "Свяжитесь с администратором проекта, чтобы увеличить лимиты."
            )

    # перечитываем стартовый контент перед отправкой (мгновенные обновления из панели)
    START.clear()
    START.update(await db.get_start_message(PROJECT["project_id"]) or {})

    text = (START.get("start_text") or DEFAULT_TEXT)
    img_u = resolve_url(START.get("image_path") or DEFAULT_IMAGE_URL)

    enabled = await menu_enabled_for_user(u.id)
    kb = main_menu(
        WEBAPP["url"],
        PROJECT.get("subscription_status", "free"),
        enabled,
        user_id=u.id,
        project_id=PROJECT.get("project_id"),
    )

    sent = None
    if img_u:
        try:
            sent = await m.answer_photo(img_u, caption=text, reply_markup=kb)
        except Exception:
            sent = await m.answer(text, reply_markup=kb)
    else:
        sent = await m.answer(text, reply_markup=kb)

    if sent:
        LAST_MENU[chat_id] = sent.message_id


@dp.callback_query(F.data == "catalog_blocked")
async def catalog_blocked(cq: CallbackQuery):
    await ensure_bootstrap()
    ok, reason = await can_add_new_user()
    msg = (
        "⛔ <b>Каталог недоступен</b>\n"
        f"{html_escape(reason)}\n"
        "Попросите администратора проекта увеличить лимиты."
    )
    try:
        await cq.answer(msg, show_alert=True)
    except Exception:
        if cq.message:
            await cq.message.answer(msg)


@dp.callback_query(F.data == "profile")
async def show_profile(cq: CallbackQuery):
    await ensure_bootstrap()
    u = cq.from_user
    chat_type = cq.message.chat.type if cq.message else "private"

    sid = await db.get_existing_subscriber_id(PROJECT["project_id"], u.id)
    if sid:
        await db.update_subscriber(sid, u.username, u.first_name, u.last_name, u.language_code, chat_type)

    row = await db.fetchone("""
        SELECT bs.tg_id, COALESCE(bs.username, u.username) AS username,
               COALESCE(bs.first_name, u.first_name) AS first_name,
               COALESCE(bs.last_name,  u.last_name)  AS last_name,
               COALESCE(bs.language_code, u.language_code) AS language_code,
               bs.chat_type, bs.created_at, bs.last_seen_at
        FROM users u
        LEFT JOIN bot_subscribers bs
               ON bs.tg_id=u.tg_id AND bs.project_id=%s
        WHERE u.tg_id=%s
        LIMIT 1
    """, (PROJECT["project_id"], u.id))

    tg_id = str(row.get("tg_id") if row else u.id)
    username = f"@{(row or {}).get('username')}" if (row and row.get("username")) else (
        "@" + (u.username or "")
    ) if u.username else "—"
    full_name = safe_name(
        (row or {}).get("first_name") or u.first_name,
        (row or {}).get("last_name") or u.last_name,
    )

    created_at = row.get("created_at") if row else None
    last_seen = row.get("last_seen_at") if row else None
    if isinstance(created_at, datetime):
        created_at = created_at.strftime("%d.%m.%Y %H:%M")
    if isinstance(last_seen, datetime):
        last_seen = last_seen.strftime("%d.%m.%Y %H:%M")
    created_at = created_at or "—"
    last_seen = last_seen or "—"

    text = (
        "👤 <b>Мой аккаунт</b>\n"
        "— — — — — — — — — — —\n"
        f"🆔 <b>Telegram ID:</b> {html_escape(tg_id)}\n"
        f"🔗 <b>Username:</b> {html_escape(username)}\n"
        f"👤 <b>Имя:</b> {html_escape(full_name)}\n"
        f"📅 <b>Создан:</b> {html_escape(created_at)}\n"
        f"🕒 <b>Последняя активность:</b> {html_escape(last_seen)}"
    )
    if cq.message:
        await cq.message.answer(text)
    try:
        await cq.answer()
    except Exception:
        pass


@dp.my_chat_member()
async def on_my_chat_member(update: ChatMemberUpdated):
    # интересны приватные чаты
    if not update.chat or update.chat.type != "private":
        return
    user = update.from_user
    if not user:
        return

    new = update.new_chat_member.status
    became_inactive = (new in {ChatMemberStatus.KICKED, ChatMemberStatus.LEFT})
    if became_inactive:
        try:
            await ensure_bootstrap()
            await db.deactivate_subscriber(PROJECT["project_id"], user.id)
            await db.purge_user_if_orphan(user.id)
            print(f"[cleanup] user {user.id} deactivated for project {PROJECT['project_id']}")
        except Exception as e:
            print(f"[cleanup error] {e}")


@dp.message()
async def handle_unknown(m: Message):
    if m.text and m.text.startswith("/start"):
        return

    await ensure_bootstrap()
    enabled = await menu_enabled_for_user(m.from_user.id) if m.from_user else False

    kb = main_menu(
        WEBAPP["url"],
        PROJECT.get("subscription_status", "free"),
        enabled,
        user_id=m.from_user.id if m.from_user else None,
        project_id=PROJECT.get("project_id"),
    )

    text = (
        "❓ <b>Я не знаю такой команды</b>\n"
        "Пожалуйста, используйте меню ниже 👇"
    )
    sent = await m.answer(text, reply_markup=kb)
    LAST_MENU[m.chat.id] = sent.message_id


# =========================
# ENTRY
# =========================
async def main():
    await db.connect()
    try:
        await ensure_bootstrap(force=True)

        print(
            f"✅ DB: {db.db_name} | "
            f"Проект: {PROJECT.get('project_name')} (id={PROJECT.get('project_id')}) | "
            f"Владелец TG: {OWNER.get('tg_id')} | WebApp: {WEBAPP['url']} | "
            f"Тариф: {PROJECT.get('subscription_status', 'free')}"
        )

        assert bot is not None
        await dp.start_polling(bot)
    finally:
        await db.close()


if __name__ == "__main__":
    asyncio.run(main())
