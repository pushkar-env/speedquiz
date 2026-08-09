"""XP / daily-streak helpers (no LLM)."""

from __future__ import annotations

from datetime import date, timedelta
from typing import Optional


def xp_threshold_for_level(level: int) -> int:
    """XP needed to advance from `level` to level+1 (matches finalize curve)."""
    return max(level, 1) * 500


def apply_xp(level: int, xp: int, earned: int) -> tuple[int, int]:
    """Apply earned XP and level-ups. Returns (new_level, new_xp)."""
    level = max(level, 1)
    xp = max(xp, 0) + max(earned, 0)
    while xp >= xp_threshold_for_level(level):
        xp -= xp_threshold_for_level(level)
        level += 1
    return level, xp


def update_daily_streak(
    *,
    daily_streak: int,
    last_played_date: Optional[date],
    today: date,
) -> tuple[int, date]:
    """
    Calendar play streak.

    - Same day: keep streak
    - Yesterday: increment
    - Gap / first play: reset to 1
    """
    if last_played_date == today:
        return max(daily_streak, 1) if daily_streak > 0 else 1, today
    if last_played_date == today - timedelta(days=1):
        return max(daily_streak, 0) + 1, today
    return 1, today
