"""Share landing + share_payload helpers."""

from uuid import uuid4
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient

from app.main import create_app
from app.services.share import build_share_payload, web_url_for


def test_build_share_payload_without_base_url():
    with patch("app.services.share.settings") as settings:
        settings.share_public_base_url = ""
        sid = uuid4()
        payload = build_share_payload(
            session_id=sid,
            topic_name="Space",
            difficulty="medium",
            mode="casual",
            score=1200,
            accuracy=80.0,
            best_streak=4,
            questions_answered=10,
        )
    assert payload["deep_link"] == f"quizverse://results/{sid}"
    assert "web_url" not in payload
    assert f"quizverse://results/{sid}" in payload["text"]
    assert set(payload["stats"].keys()) >= {
        "score",
        "accuracy",
        "best_streak",
        "topic",
        "mode",
        "difficulty",
        "questions_answered",
    }


def test_build_share_payload_with_web_url():
    with patch("app.services.share.settings") as settings:
        settings.share_public_base_url = "https://quizverse.app/"
        sid = uuid4()
        payload = build_share_payload(
            session_id=sid,
            topic_name="Space",
            difficulty="hard",
            mode="speedrun",
            score=900,
            accuracy=70.0,
            best_streak=3,
            questions_answered=8,
        )
    assert payload["web_url"] == f"https://quizverse.app/r/{sid}"
    assert payload["web_url"] in payload["text"]
    assert payload["deep_link"].startswith("quizverse://")


def test_web_url_for_strips_slash():
    with patch("app.services.share.settings") as settings:
        settings.share_public_base_url = "http://localhost:8000/"
        sid = uuid4()
        assert web_url_for(sid) == f"http://localhost:8000/r/{sid}"


@pytest.mark.asyncio
async def test_landing_404_html():
    app = create_app()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch(
            "app.api.share_landing.get_shared_result",
            new=AsyncMock(side_effect=HTTPException(status_code=404, detail="missing")),
        ):
            response = await client.get(f"/r/{uuid4()}")
    assert response.status_code == 404
    assert "text/html" in response.headers.get("content-type", "")
    assert "not found" in response.text.lower()


@pytest.mark.asyncio
async def test_landing_200_html():
    app = create_app()
    sid = uuid4()
    fake = MagicMock(
        topic_name="Astronomy",
        final_score=1500,
        accuracy=90.0,
        best_streak=7,
        questions_answered=12,
        difficulty="hard",
        mode="casual",
        deep_link=f"quizverse://results/{sid}",
        web_url=f"http://localhost:8000/r/{sid}",
    )
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch(
            "app.api.share_landing.get_shared_result",
            new=AsyncMock(return_value=fake),
        ):
            response = await client.get(f"/r/{sid}")
    assert response.status_code == 200
    assert "text/html" in response.headers.get("content-type", "")
    assert "Astronomy" in response.text
    assert "Open in QuizVerse" in response.text
    assert f"quizverse://results/{sid}" in response.text
