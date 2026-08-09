"""Pure helpers for daily challenge seeding."""

from datetime import date

from app.services.daily_constants import DAILY_MIN_COUNT, DAILY_TARGET_COUNT, seed_for_date


def test_seed_stable_for_date():
    assert seed_for_date(date(2026, 8, 9)) == seed_for_date(date(2026, 8, 9))
    assert seed_for_date(date(2026, 8, 9)) != seed_for_date(date(2026, 8, 10))


def test_daily_counts():
    assert DAILY_TARGET_COUNT == 10
    assert DAILY_MIN_COUNT == 5
