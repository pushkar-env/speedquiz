from __future__ import annotations

from typing import Optional

import redis.asyncio as redis

from app.core.config import get_settings

_redis: Optional[redis.Redis] = None


async def init_redis() -> redis.Redis:
    global _redis
    if _redis is None:
        settings = get_settings()
        _redis = redis.from_url(
            settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
        )
    return _redis


async def close_redis() -> None:
    global _redis
    if _redis is not None:
        await _redis.aclose()
        _redis = None


async def get_redis() -> redis.Redis:
    if _redis is None:
        return await init_redis()
    return _redis


async def redis_ping() -> bool:
    client = await get_redis()
    return bool(await client.ping())
