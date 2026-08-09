"""Public share result API — safe fields only, no auth."""

from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.models import DifficultyLabel, GameMode, QuizSessionStatus
from app.services.share import SharedResultOut, get_shared_result


def test_shared_result_out_fields():
    sid = uuid4()
    out = SharedResultOut(
        session_id=sid,
        topic_name="Space",
        mode="casual",
        difficulty="medium",
        final_score=1200,
        accuracy=80.0,
        best_streak=4,
        questions_answered=10,
        deep_link=f"quizverse://results/{sid}",
    )
    data = out.model_dump()
    assert set(data.keys()) == {
        "session_id",
        "topic_name",
        "mode",
        "difficulty",
        "final_score",
        "accuracy",
        "best_streak",
        "questions_answered",
        "deep_link",
        "web_url",
    }
    assert "user_id" not in data
    assert "comparisons" not in data
    assert "explanation" not in data


@pytest.mark.asyncio
async def test_get_shared_result_404_when_missing():
    db = AsyncMock()
    db.scalar = AsyncMock(return_value=None)
    with pytest.raises(HTTPException) as exc:
        await get_shared_result(db, uuid4())
    assert exc.value.status_code == 404


@pytest.mark.asyncio
async def test_get_shared_result_uses_share_payload_stats():
    sid = uuid4()
    session = SimpleNamespace(
        id=sid,
        status=QuizSessionStatus.COMPLETED,
        topic_id=uuid4(),
        mode=GameMode.CASUAL,
        difficulty=DifficultyLabel.MEDIUM,
        score=999,
        best_streak=2,
        correct_count=5,
        incorrect_count=1,
    )
    result = SimpleNamespace(
        summary={"topic_name": "Space", "accuracy": 70.0},
        share_payload={
            "deep_link": f"quizverse://results/{sid}",
            "stats": {
                "topic": "Astronomy",
                "mode": "speedrun",
                "difficulty": "hard",
                "score": 1500,
                "accuracy": 90.0,
                "best_streak": 7,
                "questions_answered": 12,
            },
        },
    )
    topic = SimpleNamespace(name="Fallback Topic")
    score = SimpleNamespace(final_score=100, best_streak=1, questions_answered=3)

    db = MagicMock()

    async def _scalar(stmt):
        # Order: session, result, score, topic
        text = str(stmt)
        if "quiz_sessions" in text or "QuizSession" in text:
            return session
        return None

    # Simpler: side_effect list matching call order in get_shared_result
    db.scalar = AsyncMock(side_effect=[session, result, score, topic])

    out = await get_shared_result(db, sid)
    assert out.topic_name == "Astronomy"
    assert out.mode == "speedrun"
    assert out.difficulty == "hard"
    assert out.final_score == 1500
    assert out.accuracy == 90.0
    assert out.best_streak == 7
    assert out.questions_answered == 12
    assert out.deep_link == f"quizverse://results/{sid}"
