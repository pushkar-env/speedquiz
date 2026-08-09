"""Pure unit tests for leaderboard period keys (no Redis/DB)."""

from datetime import date, datetime, timezone

from app.services.leaderboard_keys import daily_period_key, redis_key, weekly_period_key


def test_weekly_period_key_format():
    dt = datetime(2026, 8, 9, tzinfo=timezone.utc)
    key = weekly_period_key(dt)
    assert key.startswith("2026-W")
    assert len(key) == len("2026-W32")


def test_daily_period_key():
    assert daily_period_key(date(2026, 8, 9)) == "2026-08-09"


def test_redis_key():
    assert redis_key("weekly", "2026-W32") == "lb:weekly:2026-W32"
    assert redis_key("daily", "2026-08-09") == "lb:daily:2026-08-09"
