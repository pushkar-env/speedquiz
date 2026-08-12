"""Tests for quiz option ordering and end-condition helpers."""

from app.models import GameMode, QuizSession, QuizSessionStatus
from app.services import survival
from app.services.quiz_service import (
    MODE_DEFAULTS,
    RETIRED_MODES,
    SELECTABLE_MODES,
    _defaults_for,
    _should_end_run,
)
from app.services.scoring import ScoringService


def test_mode_defaults_cover_core_modes():
    assert MODE_DEFAULTS[GameMode.CASUAL]["question_time_limit_ms"] == 15000
    assert MODE_DEFAULTS[GameMode.SURVIVAL]["lives"] == survival.START_LIVES
    assert MODE_DEFAULTS[GameMode.SPEEDRUN]["time_budget_ms"] == 45000


def test_retired_modes_are_not_selectable():
    """Negative and sudden death are gone from the offering."""
    assert GameMode.NEGATIVE in RETIRED_MODES
    assert GameMode.SUDDEN_DEATH in RETIRED_MODES
    assert RETIRED_MODES.isdisjoint(SELECTABLE_MODES)
    assert SELECTABLE_MODES == {
        GameMode.CASUAL,
        GameMode.SPEEDRUN,
        GameMode.SURVIVAL,
    }


def test_retired_modes_still_resolve_defaults():
    """A run started just before the deploy must stay finishable.

    Their enum labels remain in the database because historical sessions and
    scores reference them, so the lookup has to answer rather than KeyError.
    """
    for mode in RETIRED_MODES:
        assert _defaults_for(mode) == MODE_DEFAULTS[GameMode.CASUAL]


def test_retired_mode_no_longer_ends_a_run_early():
    session = QuizSession(
        mode=GameMode.SUDDEN_DEATH,
        status=QuizSessionStatus.ACTIVE,
        score=200,
        streak=3,
        difficulty=__import__("app.models", fromlist=["DifficultyLabel"]).DifficultyLabel.MEDIUM,
        topic_id=__import__("uuid").uuid4(),
        user_id=__import__("uuid").uuid4(),
    )
    assert _should_end_run(session, is_correct=False) is False


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


def test_answer_context_query_fetches_everything_in_one_round_trip():
    """The verdict cannot render until this query returns, and every round trip
    it costs is charged at the player's full network latency."""
    from uuid import uuid4

    from sqlalchemy.dialects import postgresql

    from app.services.quiz_service import answer_context_query

    sql = str(
        answer_context_query(uuid4(), uuid4()).compile(
            dialect=postgresql.dialect(),
            compile_kwargs={"literal_binds": True},
        )
    ).lower()

    # Question and its answer-existence check ride along with the quiz question.
    assert "join questions" in sql
    assert "answers" in sql
    # An inner join here would return no row for a question nobody has answered
    # yet, turning every first answer of a run into a 404.
    assert "left outer join answers" in sql


def test_answer_context_query_scopes_to_the_session():
    """Without the session filter, a quiz_question id from someone else's run
    would resolve and leak a question into the wrong session."""
    from uuid import uuid4

    from sqlalchemy.dialects import postgresql

    from app.services.quiz_service import answer_context_query

    session_id, qq_id = uuid4(), uuid4()
    sql = str(
        answer_context_query(session_id, qq_id).compile(
            dialect=postgresql.dialect(),
            compile_kwargs={"literal_binds": True},
        )
    )
    assert str(session_id) in sql
    assert str(qq_id) in sql
