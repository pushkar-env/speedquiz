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
from app.core.languages import DEFAULT_LANGUAGE, ContentLanguage, normalize_language
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
    UserProfile,
)
from app.schemas.custom_topics import CreateCustomTopicRequest, CustomTopicResponse
from app.schemas.quiz import CreateQuizSessionRequest
from app.services import quiz_service

logger = get_logger(__name__)
settings = get_settings()


def cache_key_for(
    prompt: str,
    difficulty: DifficultyLabel,
    style: Optional[str],
    language: ContentLanguage = DEFAULT_LANGUAGE,
) -> str:
    """Reuse key for an already-generated custom bank.

    Language is part of the key: "quiz me on the Mughals" in Hindi must not be
    answered with the English bank someone generated an hour earlier.
    """
    raw = (
        f"{prompt.strip().lower()}|{difficulty.value}|"
        f"{(style or '').strip().lower()}|{normalize_language(language).value}"
    )
    return sha256(raw.encode("utf-8")).hexdigest()


async def _enforce_daily_quota(db: AsyncSession, user: User) -> None:
    """Limit fresh generations per UTC day for free users (cache hits exempt)."""
    if user.is_premium:
        return
    start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    # Count completed fresh generations only (payload.cache_hit != true).
    rows = (
        await db.execute(
            select(GenerationJob.payload).where(
                GenerationJob.requested_by_user_id == user.id,
                GenerationJob.created_at >= start,
                GenerationJob.status == GenerationJobStatus.COMPLETED,
            )
        )
    ).scalars().all()
    used = sum(1 for payload in rows if not (payload or {}).get("cache_hit"))
    if used >= settings.custom_topic_daily_limit_free:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Daily custom quiz limit reached. Upgrade for unlimited custom topics.",
        )


async def _find_cached_topic(
    db: AsyncSession,
    key: str,
    language: ContentLanguage,
) -> Optional[Topic]:
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
    # Belt and braces: the cache key already encodes the language, but a bank
    # reused across a key-format change must still be playable in it.
    active = await db.scalar(
        select(func.count())
        .select_from(Question)
        .where(
            Question.topic_id == topic.id,
            Question.status == QuestionStatus.ACTIVE,
            Question.language == language.value,
        )
    )
    if (active or 0) < 5:
        return None
    return topic


async def _start_session_for_topic(
    db: AsyncSession,
    user: User,
    topic: Topic,
    payload: CreateCustomTopicRequest,
    language: ContentLanguage,
) -> object:
    return await quiz_service.create_session(
        db,
        user,
        CreateQuizSessionRequest(
            topic_id=topic.id,
            mode=payload.mode,
            difficulty=payload.difficulty,
            language=language,
        ),
    )


async def _resolve_language(
    db: AsyncSession,
    user: User,
    payload: CreateCustomTopicRequest,
) -> ContentLanguage:
    """Requested language, else the one this player last played in."""
    if payload.language is not None:
        return normalize_language(payload.language)
    profile = user.profile or await db.scalar(
        select(UserProfile).where(UserProfile.user_id == user.id)
    )
    return normalize_language(profile.quiz_language if profile else None)


async def create_custom_topic_quiz(
    db: AsyncSession,
    user: User,
    payload: CreateCustomTopicRequest,
) -> CustomTopicResponse:
    sanitized = sanitize_topic_prompt(payload.prompt)
    if len(sanitized) < 3:
        raise HTTPException(status_code=400, detail="Please describe what you want to be quizzed on")

    language = await _resolve_language(db, user, payload)
    llm = get_llm_provider()
    classification = await llm.classify_topic(sanitized, language=language)
    subject = str(classification.get("subject") or sanitized)[:120]
    key = cache_key_for(sanitized, payload.difficulty, payload.style, language)

    # Cache reuse first — does not burn the daily free quota.
    cached_topic = await _find_cached_topic(db, key, language)
    if cached_topic:
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
            status="ready",
            topic_id=cached_topic.id,
            language=language.value,
        )
        db.add(custom)
        job = GenerationJob(
            id=uuid4(),
            custom_topic_id=custom.id,
            requested_by_user_id=user.id,
            status=GenerationJobStatus.COMPLETED,
            requested_count=payload.requested_count,
            approved_count=cached_topic.question_count,
            language=language.value,
            payload={
                "prompt": sanitized,
                "subject": subject,
                "difficulty": payload.difficulty.value,
                "language": language.value,
                "style": payload.style,
                "cache_hit": True,
                "reused_topic_id": str(cached_topic.id),
                # Mark so quota accounting can ignore pure cache replays if needed later.
                "quota_exempt": True,
            },
        )
        db.add(job)
        await db.flush()
        session = await _start_session_for_topic(db, user, cached_topic, payload, language)
        return CustomTopicResponse(
            id=custom.id,
            status=custom.status,
            classified_subject=subject,
            topic_id=cached_topic.id,
            topic_name=cached_topic.name,
            language=language.value,
            cache_hit=True,
            job_id=job.id,
            approved_count=cached_topic.question_count,
            rejected_count=0,
            session=session,
        )

    # Fresh generation burns a daily slot for free users.
    await _enforce_daily_quota(db, user)

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
        language=language.value,
    )
    db.add(custom)
    await db.flush()

    job = GenerationJob(
        id=uuid4(),
        custom_topic_id=custom.id,
        requested_by_user_id=user.id,
        status=GenerationJobStatus.QUEUED,
        requested_count=payload.requested_count,
        language=language.value,
        payload={
            "prompt": sanitized,
            "subject": subject,
            "difficulty": payload.difficulty.value,
            "language": language.value,
            "style": payload.style,
            "cache_hit": False,
            "quota_exempt": False,
        },
    )
    db.add(job)
    await db.flush()

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
            language=language,
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

        topic.question_count = len(outcome.approved)
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

        session = await _start_session_for_topic(db, user, topic, payload, language)
        return CustomTopicResponse(
            id=custom.id,
            status=custom.status,
            classified_subject=subject,
            topic_id=topic.id,
            topic_name=topic.name,
            language=language.value,
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
