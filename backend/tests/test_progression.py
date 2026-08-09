"""Unit tests for XP curve, daily streak, and achievement criteria (no DB)."""

from datetime import date, timedelta

from app.services.achievements import AchievementContext, criteria_met
from app.services.progression import apply_xp, update_daily_streak, xp_threshold_for_level


def test_xp_threshold_matches_level_curve():
    assert xp_threshold_for_level(1) == 500
    assert xp_threshold_for_level(2) == 1000
    assert xp_threshold_for_level(10) == 5000


def test_apply_xp_levels_up():
    level, xp = apply_xp(1, 480, 50)
    assert level == 2
    assert xp == 30


def test_apply_xp_multi_level():
    level, xp = apply_xp(1, 0, 1500)
    assert level == 3
    assert xp == 0


def test_daily_streak_same_day_keeps_count():
    today = date(2026, 8, 9)
    streak, played = update_daily_streak(
        daily_streak=4,
        last_played_date=today,
        today=today,
    )
    assert streak == 4
    assert played == today


def test_daily_streak_yesterday_increments():
    today = date(2026, 8, 9)
    streak, played = update_daily_streak(
        daily_streak=4,
        last_played_date=today - timedelta(days=1),
        today=today,
    )
    assert streak == 5
    assert played == today


def test_daily_streak_gap_resets():
    today = date(2026, 8, 9)
    streak, played = update_daily_streak(
        daily_streak=12,
        last_played_date=today - timedelta(days=3),
        today=today,
    )
    assert streak == 1
    assert played == today


def test_daily_streak_first_play():
    today = date(2026, 8, 9)
    streak, played = update_daily_streak(
        daily_streak=0,
        last_played_date=None,
        today=today,
    )
    assert streak == 1
    assert played == today


def _ctx(**overrides) -> AchievementContext:
    base = AchievementContext(
        quizzes_completed=0,
        correct_answers=0,
        best_streak=0,
        level=1,
        daily_streak=0,
        topic_mastery_by_slug={},
        min_answer_ms=None,
        perfect_run=False,
    )
    for k, v in overrides.items():
        setattr(base, k, v)
    return base


def test_criteria_first_quiz():
    assert criteria_met({"type": "quizzes_completed", "value": 1}, _ctx(quizzes_completed=1))
    assert not criteria_met({"type": "quizzes_completed", "value": 1}, _ctx(quizzes_completed=0))


def test_criteria_daily_completed():
    assert criteria_met(
        {"type": "daily_completed", "value": 1},
        _ctx(daily_completed=True),
    )
    assert not criteria_met(
        {"type": "daily_completed", "value": 1},
        _ctx(daily_completed=False),
    )


def test_criteria_topic_mastery():
    ctx = _ctx(topic_mastery_by_slug={"astronomy": 91.0})
    assert criteria_met(
        {"type": "topic_mastery", "topic": "astronomy", "value": 90},
        ctx,
    )
    assert not criteria_met(
        {"type": "topic_mastery", "topic": "astronomy", "value": 95},
        ctx,
    )


def test_criteria_fast_answer():
    assert criteria_met(
        {"type": "fast_answer_ms", "value": 2000},
        _ctx(min_answer_ms=1500),
    )
    assert not criteria_met(
        {"type": "fast_answer_ms", "value": 2000},
        _ctx(min_answer_ms=2500),
    )


def test_criteria_perfect_run():
    assert criteria_met({"type": "perfect_run", "value": 1}, _ctx(perfect_run=True))
    assert not criteria_met({"type": "perfect_run", "value": 1}, _ctx(perfect_run=False))


def test_criteria_level_uses_current_level_override():
    ctx = _ctx(level=5)
    assert not criteria_met({"type": "level", "value": 10}, ctx)
    assert criteria_met({"type": "level", "value": 10}, ctx, current_level=10)
