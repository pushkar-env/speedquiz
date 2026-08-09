"""Phase 6b unit tests: entitlements, share payload shape, anti-cheat helpers."""

from types import SimpleNamespace
from unittest.mock import patch

from app.payments.entitlements import (
    custom_topics_unlimited,
    entitlements_status,
    unique_question_allowance,
)
from app.services.anticheat import (
    clamp_points_awarded,
    max_points_per_answer,
    resolve_answer_elapsed_ms,
)


def _user(*, premium: bool = False):
    return SimpleNamespace(is_premium=premium)


def test_allowance_none_when_caps_disabled():
    with patch("app.payments.entitlements.settings") as settings:
        settings.entitlements_enforce_question_caps = False
        settings.free_unique_questions_per_topic = 30
        assert unique_question_allowance(_user()) is None
        assert unique_question_allowance(_user(premium=True)) is None


def test_allowance_free_vs_premium_when_caps_on():
    with patch("app.payments.entitlements.settings") as settings:
        settings.entitlements_enforce_question_caps = True
        settings.free_unique_questions_per_topic = 30
        assert unique_question_allowance(_user()) == 30
        assert unique_question_allowance(_user(premium=True)) is None
        assert unique_question_allowance(None) == 30


def test_custom_topics_unlimited():
    with patch("app.payments.entitlements.settings") as settings:
        settings.entitlements_enforce_question_caps = False
        assert custom_topics_unlimited(_user()) is True

        settings.entitlements_enforce_question_caps = True
        assert custom_topics_unlimited(_user()) is False
        assert custom_topics_unlimited(_user(premium=True)) is True


def test_entitlements_status_shape():
    with patch("app.payments.entitlements.settings") as settings:
        settings.entitlements_enforce_question_caps = True
        settings.free_unique_questions_per_topic = 30
        settings.is_production = False
        settings.entitlements_dev_toggle = False
        status = entitlements_status(_user())
        assert status["is_premium"] is False
        assert status["enforce_caps"] is True
        assert status["unique_per_topic_limit"] == 30
        assert status["custom_topics_unlimited"] is False
        assert status["dev_toggle_allowed"] is True

        prem = entitlements_status(_user(premium=True))
        assert prem["unique_per_topic_limit"] is None
        assert prem["custom_topics_unlimited"] is True


def test_share_payload_keys():
    """Document expected finalize share_payload contract."""
    session_id = "11111111-1111-1111-1111-111111111111"
    share_payload = {
        "text": f"QUIZVERSE\n\nSpace — MEDIUM · casual\n\nScore: 1,200\n"
        f"Accuracy: 80%\nBest Streak: 4\n\nCan you beat me?\n"
        f"quizverse://results/{session_id}",
        "deep_link": f"quizverse://results/{session_id}",
        "stats": {
            "score": 1200,
            "accuracy": 80.0,
            "best_streak": 4,
            "topic": "Space",
            "mode": "casual",
            "difficulty": "medium",
            "questions_answered": 10,
        },
    }
    assert set(share_payload.keys()) == {"text", "deep_link", "stats"}
    assert "quizverse://results/" in share_payload["deep_link"]
    assert share_payload["stats"]["score"] == 1200


def test_resolve_elapsed_prefers_wall_on_instant_correct():
    elapsed = resolve_answer_elapsed_ms(
        client_elapsed=50,
        wall_ms=3500,
        limit_ms=15000,
        grace_ms=500,
        is_correct=True,
    )
    assert elapsed == 3500


def test_resolve_elapsed_trusts_client_when_plausible():
    elapsed = resolve_answer_elapsed_ms(
        client_elapsed=1200,
        wall_ms=1300,
        limit_ms=15000,
        grace_ms=500,
        is_correct=True,
    )
    assert elapsed == 1200


def test_resolve_elapsed_none_uses_wall():
    assert (
        resolve_answer_elapsed_ms(
            client_elapsed=None,
            wall_ms=4000,
            limit_ms=15000,
            grace_ms=500,
            is_correct=False,
        )
        == 4000
    )


def test_clamp_points_awarded():
    cap = max_points_per_answer()
    assert clamp_points_awarded(cap + 9999) == cap
    assert clamp_points_awarded(100) == 100
    assert clamp_points_awarded(-999) == -500
