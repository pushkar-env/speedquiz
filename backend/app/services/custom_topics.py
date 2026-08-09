"""Custom topic creation with caching and generation quotas."""

from __future__ import annotations

from datetime import datetime, timezone
from hashlib import sha256
from typing import Optional
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.pipeline import run_generation_pipeline, sanitize_topic_prompt, slugify
from app.ai.providers import get_llm_provider
from app.core.config import get_settings
from app.core.logging import get_logger
from app.core.redis import get_redis
from app.models import (
    CustomTopic,
    DifficultyLabel,
    GenerationJob,
    GenerationJobStatus,
    Question,
    QuestionStatus,
    Topic,
    User,
)
from app.schemas.custom_topics import CreateCustomTopicRequest, CustomTopicResponse
from app.schemas.quiz import CreateQuizSessionRequest
from app.services import quiz_service

logger = get_logger(__name__)
settings = get_settings()


def cache_key_for(prompt: str, difficulty: DifficultyLabel, style: Optional[str]) -> str:
    raw = f"{prompt.strip().lower()}|{difficulty.value}|{(style or '').strip().lower()}"
    return sha256(raw.encode("utf-8")).hexdigest()


async def _enforce_daily_quota(db: AsyncSession, user: User) -> None:
    if user.is_premium:
        return
    start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    used = await db.scalar(
        select(func.count())
        .select_from(CustomTopic)
        .where(CustomTopic.user_id == user.id, CustomTopic.created_at >= start)
    )
    if (used or 0) >= settings.custom_topic_daily_limit_free:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Daily custom quiz limit reached. Upgrade for unlimited custom topics.",
        )


async def _find_cached_topic(db: AsyncSession, key: str) -> Optional[Topic]:
    # Prefer a reusable custom topic bank for the same cache key.
    row = await db.scalar(
        select(CustomTopic)
        .where(
            CustomTopic.cache_key == key,
            CustomTopic.status == "ready",
            CustomTopic.topic_id.is_not(None),
        )
        .order_by(CustomTopic.created_at.desc())
        .limit(1)
    )
    if not row or not row.topic_id:
        return None
    topic = await db.scalar(select(Topic).where(Topic.id == row.topic_id, Topic.is_active.is_(True)))
    if not topic:
        return None
    active = await db.scalar(
        select(func.count())
        .select_from(Question)
        .where(Question.topic_id == topic.id, Question.status == QuestionStatus.ACTIVE)
    )
    if (active or 0) < 5:
        return None
    return topic


async def create_custom_topic_quiz(
    db: AsyncSession,
    user: User,
    payload: CreateCustomTopicRequest,
) -> CustomTopicResponse:
    await _enforce_daily_quota(db, user)

    sanitized = sanitize_topic_prompt(payload.prompt)
    if len(sanitized) < 3:
        raise HTTPException(status_code=400, detail="Please describe what you want to be quizzed on")

    llm = get_llm_provider()
    classification = await llm.classify_topic(sanitized)
    subject = str(classification.get("subject") or sanitized)[:120]
    key = cache_key_for(sanitized, payload.difficulty, payload.style)

    custom = CustomTopic(
        id=uuid4(),
        user_id=user.id,
        prompt=payload.prompt.strip(),
        sanitized_prompt=sanitized,
        classified_subject=subject,
        difficulty=payload.difficulty,
        style=payload.style,
        requested_count=payload.requested_count,
        cache_key=key,
        status="preparing",
    )
    db.add(custom)
    await db.flush()

    cached_topic = await _find_cached_topic(db, key)
    job = GenerationJob(
        id=uuid4(),
        custom_topic_id=custom.id,
        requested_by_user_id=user.id,
        status=GenerationJobStatus.QUEUED,
        requested_count=payload.requested_count,
        payload={
            "prompt": sanitized,
            "subject": subject,
            "difficulty": payload.difficulty.value,
            "style": payload.style,
            "cache_hit": cached_topic is not None,
        },
    )
    db.add(job)
    await db.flush()

    if cached_topic:
        custom.topic_id = cached_topic.id
        custom.status = "ready"
        job.status = GenerationJobStatus.COMPLETED
        job.approved_count = cached_topic.question_count
        job.payload = {**job.payload, "reused_topic_id": str(cached_topic.id)}
        await db.flush()
        session = await quiz_service.create_session(
            db,
            user,
            CreateQuizSessionRequest(
                topic_id=cached_topic.id,
                mode=payload.mode,
                difficulty=payload.difficulty,
            ),
        )
        return CustomTopicResponse(
            id=custom.id,
            status=custom.status,
            classified_subject=subject,
            topic_id=cached_topic.id,
            topic_name=cached_topic.name,
            cache_hit=True,
            job_id=job.id,
            approved_count=cached_topic.question_count,
            rejected_count=0,
            session=session,
        )

    # Fresh generation — run pipeline inline for mock/dev; jobs keep the async contract.
    job.status = GenerationJobStatus.RUNNING
    job.attempts = 1
    topic = Topic(
        id=uuid4(),
        slug=f"custom-{slugify(subject)}-{str(custom.id)[:8]}",
        name=subject,
        description=f"Custom quiz: {sanitized}",
        icon="✨",
        is_custom=True,
        is_active=True,
        created_by_user_id=user.id,
        popularity_score=10,
    )
    db.add(topic)
    await db.flush()

    try:
        outcome = await run_generation_pipeline(
            db,
            topic=topic,
            difficulty=payload.difficulty,
            count=payload.requested_count,
            style=payload.style,
            provider=llm,
        )
        job.approved_count = len(outcome.approved)
        job.rejected_count = len(outcome.rejected)
        if len(outcome.approved) < 3:
            job.status = GenerationJobStatus.FAILED
            job.error_message = "Could not prepare enough high-quality questions"
            custom.status = "failed"
            await db.flush()
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Couldn't prepare enough good questions. Try a clearer topic.",
            )

        custom.topic_id = topic.id
        custom.status = "ready"
        job.status = GenerationJobStatus.COMPLETED
        job.topic_id = topic.id
        await db.flush()

        # Cache pointer in Redis for popular repeats
        try:
            redis = await get_redis()
            await redis.setex(f"custom_topic_cache:{key}", 60 * 60 * 24 * 7, str(topic.id))
        except Exception:  # noqa: BLE001
            pass

        session = await quiz_service.create_session(
            db,
            user,
            CreateQuizSessionRequest(
                topic_id=topic.id,
                mode=payload.mode,
                difficulty=payload.difficulty,
            ),
        )
        return CustomTopicResponse(
            id=custom.id,
            status=custom.status,
            classified_subject=subject,
            topic_id=topic.id,
            topic_name=topic.name,
            cache_hit=False,
            job_id=job.id,
            approved_count=job.approved_count,
            rejected_count=job.rejected_count,
            session=session,
        )
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001
        logger.exception("custom_topic_failed", error=str(exc))
        job.status = GenerationJobStatus.FAILED
        job.error_message = str(exc)[:500]
        custom.status = "failed"
        await db.flush()
        raise HTTPException(
            status_code=500,
            detail="Something went wrong preparing your challenge. Please try again.",
        ) from exc
