"""Topic question-bank inventory: watermark top-ups without blocking gameplay.

Architecture
------------
- Play path reads only from the validated PostgreSQL question bank (low latency).
- When inventory for a topic is critically low, ``ensure_minimum_bank`` can fill
  one chunk synchronously so a run has unique runway.
- Otherwise we enqueue chunk generation jobs for the worker.
- Jobs fill toward ``topic_bank_target_unique`` (default 1000), then stop.
- After the unique ceiling, sessions may reshuffle-reuse.
- Cost control: one in-flight top-up per topic, chunked LLM calls, Redis lock.

Future monetization (not enforced yet — free is unlimited today)
----------------------------------------------------------------
- Soft gate after N unique questions per topic (e.g. 30) for free users.
- Premium / diamonds unlock the full bank toward the unique ceiling.
"""

from __future__ import annotations

from typing import Optional
from uuid import UUID, uuid4

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.logging import get_logger
from app.core.redis import get_redis
from app.models import (
    DifficultyLabel,
    GenerationJob,
    GenerationJobStatus,
    Question,
    QuestionStatus,
    Topic,
    User,
)

logger = get_logger(__name__)
settings = get_settings()


async def count_active_questions(db: AsyncSession, topic_id: UUID) -> int:
    return int(
        await db.scalar(
            select(func.count())
            .select_from(Question)
            .where(Question.topic_id == topic_id, Question.status == QuestionStatus.ACTIVE)
        )
        or 0
    )


async def _has_inflight_topup(db: AsyncSession, topic_id: UUID) -> bool:
    row = await db.scalar(
        select(GenerationJob.id)
        .where(
            GenerationJob.topic_id == topic_id,
            GenerationJob.status.in_(
                [GenerationJobStatus.QUEUED, GenerationJobStatus.RUNNING]
            ),
        )
        .limit(1)
    )
    return row is not None


async def ensure_minimum_bank(
    db: AsyncSession,
    topic: Topic,
    *,
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM,
    minimum: Optional[int] = None,
    user: Optional[User] = None,
) -> int:
    """Grow a thin bank before play so the session has unique runway."""
    from app.ai.pipeline import run_generation_pipeline
    from app.ai.providers import get_llm_provider

    minimum = minimum or max(settings.topic_bank_session_batch + 10, 30)
    active = await count_active_questions(db, topic.id)
    if active >= minimum:
        await enqueue_bank_topup(
            db, topic, difficulty=difficulty, reason="session_start", user=user
        )
        return active

    need = min(settings.topic_bank_chunk_size, minimum - active)
    need = max(need, 5)
    logger.info(
        "bank_sync_fill",
        topic=topic.slug,
        active=active,
        need=need,
        minimum=minimum,
    )
    try:
        outcome = await run_generation_pipeline(
            db,
            topic=topic,
            difficulty=difficulty,
            count=need,
            style="fresh unique trivia — avoid duplicates",
            provider=get_llm_provider(),
            max_attempts=2,
        )
        active = await count_active_questions(db, topic.id)
        topic.question_count = active
        logger.info(
            "bank_sync_fill_done",
            topic=topic.slug,
            approved=len(outcome.approved),
            active=active,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("bank_sync_fill_failed", topic=topic.slug, error=str(exc))

    await enqueue_bank_topup(
        db, topic, difficulty=difficulty, reason="session_start", user=user, force=True
    )
    return await count_active_questions(db, topic.id)


async def enqueue_bank_topup(
    db: AsyncSession,
    topic: Topic,
    *,
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM,
    reason: str = "watermark",
    user: Optional[User] = None,
    force: bool = False,
) -> Optional[GenerationJob]:
    """Queue a chunk generation job if the topic bank needs refill."""
    active = await count_active_questions(db, topic.id)
    target = settings.topic_bank_target_unique
    low = settings.topic_bank_low_watermark

    if active >= target:
        return None
    if not force and active >= low and reason in {"session_start", "periodic"}:
        return None

    if await _has_inflight_topup(db, topic.id):
        return None

    chunk = min(settings.topic_bank_chunk_size, max(0, target - active))
    if chunk < 3:
        return None

    try:
        redis = await get_redis()
        lock_key = f"bank_topup_lock:{topic.id}"
        acquired = await redis.set(lock_key, "1", nx=True, ex=60)
        if not acquired:
            return None
    except Exception:  # noqa: BLE001
        pass

    rotate = {
        DifficultyLabel.EASY: DifficultyLabel.MEDIUM,
        DifficultyLabel.MEDIUM: DifficultyLabel.HARD,
        DifficultyLabel.HARD: DifficultyLabel.EXPERT,
        DifficultyLabel.EXPERT: DifficultyLabel.MEDIUM,
    }
    gen_difficulty = (
        difficulty if reason in {"session_start", "session_consume", "sync"} else rotate.get(difficulty, DifficultyLabel.MEDIUM)
    )

    job = GenerationJob(
        id=uuid4(),
        topic_id=topic.id,
        requested_by_user_id=user.id if user else None,
        status=GenerationJobStatus.QUEUED,
        requested_count=chunk,
        payload={
            "job_type": "bank_topup",
            "subject": topic.name,
            "difficulty": gen_difficulty.value,
            "style": "fresh unique trivia — avoid duplicates of common quiz stock",
            "reason": reason,
            "active_before": active,
            "target": target,
            "is_custom": bool(topic.is_custom),
        },
    )
    db.add(job)
    await db.flush()
    logger.info(
        "bank_topup_enqueued",
        topic=topic.slug,
        chunk=chunk,
        active=active,
        reason=reason,
        job_id=str(job.id),
    )
    return job


async def maybe_chain_another_topup(db: AsyncSession, topic: Topic) -> Optional[GenerationJob]:
    """After a successful chunk, optionally queue another while still thin."""
    active = await count_active_questions(db, topic.id)
    topic.question_count = active
    if active >= settings.topic_bank_target_unique:
        return None
    comfortable = max(settings.topic_bank_low_watermark * 3, 100)
    if active >= comfortable:
        return None
    return await enqueue_bank_topup(
        db,
        topic,
        difficulty=DifficultyLabel.MEDIUM,
        reason="chain",
        force=True,
    )


async def scan_and_enqueue_thin_topics(db: AsyncSession, *, limit: int = 5) -> int:
    """Periodic worker helper: top up the thinnest active topics."""
    rows = await db.execute(
        select(Topic)
        .where(Topic.is_active.is_(True))
        .order_by(Topic.question_count.asc())
        .limit(limit * 3)
    )
    topics = list(rows.scalars().all())
    enqueued = 0
    for topic in topics:
        active = await count_active_questions(db, topic.id)
        topic.question_count = active
        if active >= settings.topic_bank_low_watermark:
            continue
        job = await enqueue_bank_topup(
            db,
            topic,
            difficulty=DifficultyLabel.MEDIUM,
            reason="periodic",
        )
        if job:
            enqueued += 1
        if enqueued >= limit:
            break
    return enqueued
