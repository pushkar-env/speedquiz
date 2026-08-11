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
            # Redis is on the answer-submission path (rate limiting), so a
            # stalled socket must raise quickly instead of parking request
            # handlers until the client gives up.
            socket_timeout=settings.redis_socket_timeout_seconds,
            socket_connect_timeout=settings.redis_connect_timeout_seconds,
            socket_keepalive=True,
            retry_on_timeout=True,
            # Detects connections dropped by an idle-timeout on the provider
            # side before we try to use them.
            health_check_interval=30,
            max_connections=settings.redis_max_connections,
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
    """Liveness check. Returns False instead of raising so callers (health
    probes, the worker loop) can report degradation without crashing."""
    try:
        client = await get_redis()
        return bool(await client.ping())
    except Exception:
        return False
