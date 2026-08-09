"""Leaderboard key helpers (no Redis/DB)."""

from __future__ import annotations

from datetime import date, datetime, timezone
from typing import Optional


def weekly_period_key(when: Optional[datetime] = None) -> str:
    dt = when or datetime.now(timezone.utc)
    iso = dt.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def daily_period_key(day: Optional[date] = None) -> str:
    d = day or datetime.now(timezone.utc).date()
    return d.isoformat()


def redis_key(scope: str, period_key: str) -> str:
    return f"lb:{scope}:{period_key}"
