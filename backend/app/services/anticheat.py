"""Anti-cheat helpers for answer timing and rate limits (no LLM)."""

from __future__ import annotations

from typing import Optional
from uuid import UUID

from app.core.config import get_settings
from app.core.logging import get_logger
from app.core.redis import get_redis

logger = get_logger(__name__)

# Max points for one correct answer: base + speed_bonus_max * highest streak tier (~1.5)
def max_points_per_answer() -> int:
    settings = get_settings()
    return int(round((settings.score_base_points + settings.score_speed_bonus_max) * 1.5)) + 50


def resolve_answer_elapsed_ms(
    *,
    client_elapsed: Optional[int],
    wall_ms: int,
    limit_ms: int,
    grace_ms: int,
    is_correct: bool,
) -> int:
    """
    Client elapsed is a hint only. Prefer fairness but reject impossible
    'instant correct' claims when wall clock shows real wait.
    """
    ceiling = limit_ms + grace_ms
    if client_elapsed is None:
        return max(0, min(wall_ms, ceiling))

    elapsed = max(0, min(int(client_elapsed), ceiling))
    # Client claiming far more than wall → clamp to wall + skew
    elapsed = min(elapsed, wall_ms + 2000)

    # Instant-correct exploit: claim <200ms while wall shows >2s → use wall
    if is_correct and client_elapsed < 200 and wall_ms > 2000:
        elapsed = min(wall_ms, ceiling)

    return max(0, min(elapsed, ceiling))


def clamp_points_awarded(points: int) -> int:
    cap = max_points_per_answer()
    # Allow negative mode penalties
    if points < 0:
        return max(points, -500)
    return min(points, cap)


async def check_answer_rate_limit(user_id: UUID) -> bool:
    """
    Return True if allowed, False if rate-limited.
    Fail-open if Redis is unavailable.
    """
    try:
        r = await get_redis()
        key = f"rl:answer:{user_id}"
        count = await r.incr(key)
        if count == 1:
            await r.expire(key, 1)
        # ~3 answers / second
        return int(count) <= 3
    except Exception as exc:
        logger.warning("answer_rate_limit_failed", error=str(exc))
        return True
