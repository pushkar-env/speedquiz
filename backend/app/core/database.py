from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from typing import Any

from sqlalchemy import text
from sqlalchemy.engine import URL, make_url
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from app.core.config import Settings, get_settings

settings = get_settings()


def _engine_url(cfg: Settings) -> URL:
    """Database URL, adjusted for transaction-mode poolers when configured."""
    url = make_url(cfg.database_url)
    if cfg.db_disable_prepared_statements and "asyncpg" in (url.drivername or ""):
        # SQLAlchemy's asyncpg dialect keeps its own prepared-statement cache
        # on top of asyncpg's. Both have to be off when connections are
        # multiplexed between transactions, or queries fail with
        # "prepared statement ... already exists" under load.
        url = url.update_query_dict(
            {"prepared_statement_cache_size": "0"}, append=False
        )
    return url


def _engine_kwargs(cfg: Settings) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "echo": cfg.debug and not cfg.is_production,
        "pool_pre_ping": True,
        "pool_size": cfg.db_pool_size,
        "max_overflow": cfg.db_max_overflow,
        "pool_timeout": cfg.db_pool_timeout_seconds,
        "pool_recycle": cfg.db_pool_recycle_seconds,
    }
    if cfg.db_disable_prepared_statements and "asyncpg" in cfg.database_url:
        kwargs["connect_args"] = {"statement_cache_size": 0}
    return kwargs


engine = create_async_engine(_engine_url(settings), **_engine_kwargs(settings))

AsyncSessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autoflush=False,
)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


@asynccontextmanager
async def session_scope() -> AsyncGenerator[AsyncSession, None]:
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


# Namespaced so unrelated advisory locks cannot collide.
class AdvisoryLock:
    """Well-known Postgres advisory lock keys."""

    MIGRATIONS = 727_314_001
    SEED = 727_314_002


@asynccontextmanager
async def advisory_lock(key: int) -> AsyncGenerator[bool, None]:
    """Hold a session-level Postgres advisory lock for the block.

    Yields ``True`` when this process took the lock and ``False`` when another
    process already holds it — used so that concurrent replica boots do not
    run one-shot startup work (seeding) on top of each other.
    """
    async with engine.connect() as conn:
        acquired = bool(
            await conn.scalar(text("SELECT pg_try_advisory_lock(:key)"), {"key": key})
        )
        try:
            yield acquired
        finally:
            if acquired:
                await conn.execute(
                    text("SELECT pg_advisory_unlock(:key)"), {"key": key}
                )
