from app.models import GameMode
from app.services.scoring import ScoringService


def test_streak_multipliers():
    svc = ScoringService()
    assert float(svc.streak_multiplier(0)) == 1.0
    assert float(svc.streak_multiplier(4)) == 1.0
    assert float(svc.streak_multiplier(5)) == 1.1
    assert float(svc.streak_multiplier(10)) == 1.25
    assert float(svc.streak_multiplier(20)) == 1.5


def test_speed_bonus_scales_with_remaining_time():
    svc = ScoringService()
    assert svc.speed_bonus(15000, 15000) == 50
    assert svc.speed_bonus(7500, 15000) == 25
    assert svc.speed_bonus(0, 15000) == 0


def test_correct_answer_awards_points_with_streak():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=True,
        current_streak=9,
        remaining_ms=7500,
        total_ms=15000,
        mode=GameMode.CASUAL,
    )
    assert result.new_streak == 10
    assert float(result.streak_multiplier) == 1.25
    assert result.base_points == 100
    assert result.speed_bonus == 25
    assert result.points_awarded == int(round((100 + 25) * 1.25))


def test_wrong_answer_resets_streak_casual():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=False,
        current_streak=8,
        remaining_ms=1000,
        total_ms=15000,
        mode=GameMode.CASUAL,
    )
    assert result.new_streak == 0
    assert result.points_awarded == 0


def test_negative_mode_penalty():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=False,
        current_streak=3,
        remaining_ms=1000,
        total_ms=15000,
        mode=GameMode.NEGATIVE,
    )
    assert result.points_awarded == -150


def test_survival_life_loss_and_restore():
    svc = ScoringService()
    miss = svc.score_answer(
        is_correct=False,
        current_streak=2,
        remaining_ms=1000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
    )
    assert miss.lives_delta == -1

    restore = svc.score_answer(
        is_correct=True,
        current_streak=9,
        remaining_ms=10000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
    )
    assert restore.new_streak == 10
    assert restore.lives_delta == 1
