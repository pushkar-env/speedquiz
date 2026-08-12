"""Teach Me + question report endpoints (rate-limited, async-friendly)."""

from __future__ import annotations

from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.ai.providers import get_llm_provider
from app.core.languages import ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.core.redis import get_redis
from app.models import Question, QuestionReport, QuestionStatus, User
from app.schemas.questions import QuestionReportRequest, TeachMeResponse

logger = get_logger(__name__)

TEACH_LIMIT_PER_HOUR = 20
REPORT_LIMIT_PER_DAY = 30


async def _rate_limit(key: str, limit: int, window_seconds: int) -> None:
    redis = await get_redis()
    count = await redis.incr(key)
    if count == 1:
        await redis.expire(key, window_seconds)
    if count > limit:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Slow down — try again later",
        )


async def teach_question(
    db: AsyncSession,
    user: User,
    question_id: UUID,
    *,
    user_option_text: str | None = None,
) -> TeachMeResponse:
    await _rate_limit(f"teach:{user.id}", TEACH_LIMIT_PER_HOUR, 3600)

    question = await db.scalar(
        select(Question)
        .options(selectinload(Question.options))
        .where(Question.id == question_id, Question.status == QuestionStatus.ACTIVE)
    )
    if not question:
        raise HTTPException(status_code=404, detail="Question not found")

    correct = next(
        (o.text for o in question.options if o.position == question.correct_option_index),
        "",
    )
    # The tutor answers in the language the question is written in — anything
    # else would explain a Hindi question in English mid-run.
    language = normalize_language(question.language)
    user_option = user_option_text or (
        "आपका उत्तर" if language is ContentLanguage.HINDI else "your answer"
    )

    llm = get_llm_provider()
    try:
        payload = await llm.teach(
            question=question.prompt,
            correct_option=correct,
            user_option=user_option,
            explanation=question.explanation,
            language=language,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("teach_failed", error=str(exc))
        # Fall back to stored explanation — never break the client
        if language is ContentLanguage.HINDI:
            payload = {
                "why_correct": question.explanation,
                "why_wrong": f'"{user_option}" सही उत्तर से मेल नहीं खाता।',
                "key_concept": "स्पष्टीकरण दोबारा पढ़ें और मिलता-जुलता प्रश्न आज़माएँ।",
                "memorable_fact": f"याद रखें: {correct}।",
            }
        else:
            payload = {
                "why_correct": question.explanation,
                "why_wrong": f'"{user_option}" does not match the correct answer.',
                "key_concept": "Re-read the explanation and try a similar question.",
                "memorable_fact": f"Remember: {correct}.",
            }

    return TeachMeResponse(
        question_id=question.id,
        why_correct=payload.get("why_correct", question.explanation),
        why_wrong=payload.get("why_wrong", ""),
        key_concept=payload.get("key_concept", ""),
        memorable_fact=payload.get("memorable_fact", ""),
    )


async def report_question(
    db: AsyncSession,
    user: User,
    question_id: UUID,
    payload: QuestionReportRequest,
) -> dict:
    await _rate_limit(f"report:{user.id}", REPORT_LIMIT_PER_DAY, 86400)

    question = await db.scalar(select(Question).where(Question.id == question_id))
    if not question:
        raise HTTPException(status_code=404, detail="Question not found")

    report = QuestionReport(
        question_id=question.id,
        user_id=user.id,
        reason=payload.reason,
        details=payload.details,
        status="open",
    )
    db.add(report)
    question.times_reported += 1
    if question.times_reported >= 5 and question.status == QuestionStatus.ACTIVE:
        question.status = QuestionStatus.REPORTED
    await db.flush()
    return {"status": "received", "report_id": str(report.id)}
