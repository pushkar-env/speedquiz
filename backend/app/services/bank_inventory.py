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

from datetime import datetime, timezone
from typing import Optional
from uuid import UUID, uuid4

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.languages import (
    DEFAULT_LANGUAGE,
    ContentLanguage,
    normalize_language,
    supported_languages,
)
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
from app.services.question_filters import not_expired

logger = get_logger(__name__)
settings = get_settings()


async def count_active_questions(
    db: AsyncSession,
    topic_id: UUID,
    *,
    language: Optional[ContentLanguage] = None,
) -> int:
    """Playable questions for a topic, optionally in one language.

    Every inventory decision is per language: a topic sitting on 900 English
    questions and 4 Hindi ones is *empty* for a Hindi player, and treating its
    total as the stock level is what would leave them staring at a dead topic.
    """
    stmt = (
        select(func.count())
        .select_from(Question)
        .where(
            Question.topic_id == topic_id,
            Question.status == QuestionStatus.ACTIVE,
            # Expired rows are not stock. Counting them would leave a topic
            # whose bank has gone stale looking fully stocked, so it would
            # never queue a top-up and would deal nothing.
            not_expired(),
        )
    )
    if language is not None:
        stmt = stmt.where(Question.language == normalize_language(language).value)
    return int(await db.scalar(stmt) or 0)


async def count_active_by_language(
    db: AsyncSession,
    topic_ids: list[UUID],
) -> dict[UUID, dict[str, int]]:
    """`{topic_id: {"en": 120, "hi": 40}}` for a page of topics, in one query.

    The catalog endpoint needs this for every row it returns; doing it per
    topic would be a query per topic per request.
    """
    if not topic_ids:
        return {}
    rows = await db.execute(
        select(Question.topic_id, Question.language, func.count())
        .where(
            Question.topic_id.in_(topic_ids),
            Question.status == QuestionStatus.ACTIVE,
            not_expired(),
        )
        .group_by(Question.topic_id, Question.language)
    )
    counts: dict[UUID, dict[str, int]] = {}
    for topic_id, language, total in rows:
        code = normalize_language(language).value
        bucket = counts.setdefault(topic_id, {})
        bucket[code] = bucket.get(code, 0) + int(total or 0)
    return counts


async def _has_inflight_topup(
    db: AsyncSession,
    topic_id: UUID,
    language: ContentLanguage,
) -> bool:
    row = await db.scalar(
        select(GenerationJob.id)
        .where(
            GenerationJob.topic_id == topic_id,
            GenerationJob.language == normalize_language(language).value,
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
    language: ContentLanguage = DEFAULT_LANGUAGE,
) -> int:
    """Grow a thin bank before play so the session has unique runway."""
    from app.ai.pipeline import run_generation_pipeline
    from app.ai.providers import get_llm_provider

    language = normalize_language(language)

    # Custom topics are one-shot generated banks — never grow toward curated
    # target. News topics are grown daily by the grounded builder instead; an
    # ungrounded sync-fill here is precisely the stale content this avoids.
    if topic.is_custom or topic.is_news:
        return await count_active_questions(db, topic.id, language=language)

    minimum = minimum or max(settings.topic_bank_session_batch + 10, 30)
    active = await count_active_questions(db, topic.id, language=language)
    if active >= minimum:
        await enqueue_bank_topup(
            db,
            topic,
            difficulty=difficulty,
            reason="session_start",
            user=user,
            language=language,
        )
        return active

    need = min(settings.topic_bank_chunk_size, minimum - active)
    need = max(need, 5)
    logger.info(
        "bank_sync_fill",
        topic=topic.slug,
        language=language.value,
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
            language=language,
        )
        active = await count_active_questions(db, topic.id, language=language)
        topic.question_count = await count_active_questions(db, topic.id)
        logger.info(
            "bank_sync_fill_done",
            topic=topic.slug,
            language=language.value,
            approved=len(outcome.approved),
            active=active,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception(
            "bank_sync_fill_failed",
            topic=topic.slug,
            language=language.value,
            error=str(exc),
        )

    await enqueue_bank_topup(
        db,
        topic,
        difficulty=difficulty,
        reason="session_start",
        user=user,
        force=True,
        language=language,
    )
    return await count_active_questions(db, topic.id, language=language)


async def enqueue_bank_topup(
    db: AsyncSession,
    topic: Topic,
    *,
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM,
    reason: str = "watermark",
    user: Optional[User] = None,
    force: bool = False,
    language: ContentLanguage = DEFAULT_LANGUAGE,
) -> Optional[GenerationJob]:
    """Queue a chunk generation job if the topic bank needs refill."""
    if topic.is_custom or topic.is_news:
        return None

    language = normalize_language(language)
    active = await count_active_questions(db, topic.id, language=language)
    target = settings.topic_bank_target_unique
    low = settings.topic_bank_low_watermark

    if active >= target:
        return None
    if not force and active >= low and reason in {"session_start", "periodic"}:
        return None

    if await _has_inflight_topup(db, topic.id, language):
        return None

    chunk = min(settings.topic_bank_chunk_size, max(0, target - active))
    if chunk < 3:
        return None

    try:
        redis = await get_redis()
        # Per language: an English top-up in flight must not starve the Hindi
        # bank of the job that would make the topic playable at all.
        lock_key = f"bank_topup_lock:{topic.id}:{language.value}"
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
        language=language.value,
        payload={
            "job_type": "bank_topup",
            "subject": topic.name,
            "difficulty": gen_difficulty.value,
            "language": language.value,
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
        language=language.value,
        chunk=chunk,
        active=active,
        reason=reason,
        job_id=str(job.id),
    )
    return job


async def maybe_chain_another_topup(
    db: AsyncSession,
    topic: Topic,
    *,
    language: ContentLanguage = DEFAULT_LANGUAGE,
) -> Optional[GenerationJob]:
    """After a successful chunk, optionally queue another while still thin."""
    language = normalize_language(language)
    active = await count_active_questions(db, topic.id, language=language)
    topic.question_count = await count_active_questions(db, topic.id)
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
        language=language,
    )


async def retire_expired_questions(db: AsyncSession, *, limit: Optional[int] = None) -> int:
    """Move questions past their ``expires_at`` out of the playable pool.

    Bounded per call rather than one blanket UPDATE: a daily news bank can
    expire a few thousand rows in the same second, and this runs on the same
    worker loop that processes generation jobs. A long row-lock here would
    stall those, so the sweep takes a bite per tick and catches up over a few
    minutes — the questions are already excluded from selection by
    ``not_expired``, so lagging behind costs correctness nothing.

    Retiring rather than deleting: ``times_served`` / ``times_correct`` on an
    expired question are still the only record of how it performed, and the
    calibration in ``adaptive`` reads them.
    """
    now = datetime.now(timezone.utc)
    batch = limit if limit is not None else settings.freshness_sweep_batch
    doomed = list(
        (
            await db.execute(
                select(Question.id, Question.topic_id)
                .where(
                    Question.status == QuestionStatus.ACTIVE,
                    Question.expires_at.is_not(None),
                    Question.expires_at <= now,
                )
                .order_by(Question.expires_at.asc())
                .limit(batch)
            )
        ).all()
    )
    if not doomed:
        return 0

    question_ids = [row[0] for row in doomed]
    topic_ids = {row[1] for row in doomed}

    await db.execute(
        update(Question)
        .where(Question.id.in_(question_ids))
        .values(status=QuestionStatus.RETIRED)
    )

    # Topic counters drive the thin-topic scan, so they have to follow the
    # retirement immediately or the topic that just lost its bank is the one
    # topic the scan will not consider refilling.
    for topic_id in topic_ids:
        topic = await db.scalar(select(Topic).where(Topic.id == topic_id))
        if topic:
            topic.question_count = await count_active_questions(db, topic_id)

    logger.info(
        "questions_retired",
        count=len(question_ids),
        topics=len(topic_ids),
    )
    return len(question_ids)


async def scan_and_enqueue_thin_topics(db: AsyncSession, *, limit: int = 5) -> int:
    """Periodic worker helper: top up the thinnest active topic banks.

    Sweeps every supported language, not just the default one. A topic is
    "thin" per language, so a fully stocked English topic still queues work for
    an empty Hindi bank — that is how a newly added language fills at all.
    """
    rows = await db.execute(
        select(Topic)
        .where(
            Topic.is_active.is_(True),
            Topic.is_custom.is_(False),
            Topic.is_news.is_(False),
        )
        .order_by(Topic.question_count.asc())
        .limit(limit * 3)
    )
    topics = list(rows.scalars().all())
    languages = [profile.language for profile in supported_languages()]
    enqueued = 0
    for topic in topics:
        topic.question_count = await count_active_questions(db, topic.id)
        for language in languages:
            active = await count_active_questions(db, topic.id, language=language)
            if active >= settings.topic_bank_low_watermark:
                continue
            job = await enqueue_bank_topup(
                db,
                topic,
                difficulty=DifficultyLabel.MEDIUM,
                reason="periodic",
                language=language,
            )
            if job:
                enqueued += 1
            if enqueued >= limit:
                return enqueued
    return enqueued
