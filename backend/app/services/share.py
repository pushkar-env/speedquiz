"""Public share payloads — no auth, no private user data."""

from __future__ import annotations

from typing import Optional
from uuid import UUID

from fastapi import HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models import QuizResult, QuizSession, QuizSessionStatus, Score, Topic

settings = get_settings()


class SharedResultOut(BaseModel):
    session_id: UUID
    topic_name: str
    mode: str
    difficulty: str
    final_score: int
    accuracy: float
    best_streak: int
    questions_answered: int
    deep_link: str = Field(description="Custom-scheme deep link for the app")
    web_url: Optional[str] = Field(
        default=None, description="Public HTTPS (or HTTP) landing URL when configured"
    )


def deep_link_for(session_id: UUID) -> str:
    return f"speedquiz://results/{session_id}"


def web_url_for(session_id: UUID) -> Optional[str]:
    base = (settings.share_public_base_url or "").strip().rstrip("/")
    if not base:
        return None
    return f"{base}/r/{session_id}"


def build_share_payload(
    *,
    session_id: UUID,
    topic_name: str,
    difficulty: str,
    mode: str,
    score: int,
    accuracy: float,
    best_streak: int,
    questions_answered: int,
) -> dict:
    deep = deep_link_for(session_id)
    web = web_url_for(session_id)
    link_line = web or deep
    text = (
        f"SPEEDQUIZ\n\n{topic_name} — {difficulty.upper()} · "
        f"{mode.replace('_', ' ')}\n\n"
        f"Score: {score:,}\n"
        f"Accuracy: {accuracy:.0f}%\n"
        f"Best Streak: {best_streak}\n\n"
        f"Can you beat me?\n"
        f"{link_line}"
    )
    payload: dict = {
        "text": text,
        "deep_link": deep,
        "stats": {
            "score": score,
            "accuracy": accuracy,
            "best_streak": best_streak,
            "topic": topic_name,
            "mode": mode,
            "difficulty": difficulty,
            "questions_answered": questions_answered,
        },
    }
    if web:
        payload["web_url"] = web
    return payload


async def get_shared_result(db: AsyncSession, session_id: UUID) -> SharedResultOut:
    session = await db.scalar(select(QuizSession).where(QuizSession.id == session_id))
    if session is None or session.status != QuizSessionStatus.COMPLETED:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shared result not found")

    result = await db.scalar(select(QuizResult).where(QuizResult.session_id == session.id))
    if result is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shared result not found")

    score = await db.scalar(select(Score).where(Score.session_id == session.id))
    topic = await db.scalar(select(Topic).where(Topic.id == session.topic_id))
    summary = (result.summary if result else {}) or {}
    share = (result.share_payload if result else {}) or {}
    stats = share.get("stats") if isinstance(share.get("stats"), dict) else {}

    topic_name = (
        str(stats.get("topic"))
        if stats.get("topic")
        else str(summary.get("topic_name") or (topic.name if topic else "SpeedQuiz"))
    )
    deep_link = str(share.get("deep_link") or deep_link_for(session.id))
    web_url = share.get("web_url")
    if not web_url:
        web_url = web_url_for(session.id)

    return SharedResultOut(
        session_id=session.id,
        topic_name=topic_name,
        mode=str(stats.get("mode") or session.mode.value),
        difficulty=str(stats.get("difficulty") or session.difficulty.value),
        final_score=int(
            stats.get("score")
            if stats.get("score") is not None
            else (score.final_score if score else session.score)
        ),
        accuracy=float(
            stats.get("accuracy")
            if stats.get("accuracy") is not None
            else summary.get("accuracy", 0)
        ),
        best_streak=int(
            stats.get("best_streak")
            if stats.get("best_streak") is not None
            else (score.best_streak if score else session.best_streak)
        ),
        questions_answered=int(
            stats.get("questions_answered")
            if stats.get("questions_answered") is not None
            else (
                score.questions_answered
                if score
                else session.correct_count + session.incorrect_count
            )
        ),
        deep_link=deep_link,
        web_url=str(web_url) if web_url else None,
    )
