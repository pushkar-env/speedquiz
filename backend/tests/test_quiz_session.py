"""Tests for quiz option ordering and end-condition helpers."""

from app.models import GameMode, QuizSession, QuizSessionStatus
from app.services.quiz_service import MODE_DEFAULTS, _should_end_run
from app.services.scoring import ScoringService


def test_mode_defaults_cover_core_modes():
    assert MODE_DEFAULTS[GameMode.CASUAL]["question_time_limit_ms"] == 15000
    assert MODE_DEFAULTS[GameMode.SURVIVAL]["lives"] == 3
    assert MODE_DEFAULTS[GameMode.NEGATIVE]["score"] == 1000
    assert MODE_DEFAULTS[GameMode.SPEEDRUN]["time_budget_ms"] == 60000


def test_sudden_death_ends_on_wrong():
    session = QuizSession(
        mode=GameMode.SUDDEN_DEATH,
        status=QuizSessionStatus.ACTIVE,
        score=200,
        streak=3,
        difficulty=__import__("app.models", fromlist=["DifficultyLabel"]).DifficultyLabel.MEDIUM,
        topic_id=__import__("uuid").uuid4(),
        user_id=__import__("uuid").uuid4(),
    )
    assert _should_end_run(session, is_correct=False) is True
    assert _should_end_run(session, is_correct=True) is False


def test_survival_ends_at_zero_lives():
    session = QuizSession(
        mode=GameMode.SURVIVAL,
        status=QuizSessionStatus.ACTIVE,
        score=100,
        streak=0,
        lives=0,
        difficulty=__import__("app.models", fromlist=["DifficultyLabel"]).DifficultyLabel.MEDIUM,
        topic_id=__import__("uuid").uuid4(),
        user_id=__import__("uuid").uuid4(),
    )
    assert _should_end_run(session, is_correct=False) is True


def test_option_order_maps_correct_index():
    option_order = [2, 0, 3, 1]
    correct_original = 1
    client_index = option_order.index(correct_original)
    assert client_index == 3
    assert option_order[client_index] == correct_original


def test_casual_wrong_answer_zero_points():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=False,
        current_streak=5,
        remaining_ms=5000,
        total_ms=15000,
        mode=GameMode.CASUAL,
    )
    assert result.points_awarded == 0
    assert result.new_streak == 0
