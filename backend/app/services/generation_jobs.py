"""Background processing for generation jobs (custom + bank top-up)."""

from __future__ import annotations

from sqlalchemy import select

from app.ai.pipeline import run_generation_pipeline, sanitize_topic_prompt, slugify
from app.ai.providers import get_llm_provider
from app.ai.retrieval import build_context
from app.core.database import session_scope
from app.core.freshness import Temporality, normalize_temporality
from app.core.languages import ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.models import (
    CustomTopic,
    DifficultyLabel,
    GenerationJob,
    GenerationJobStatus,
    Topic,
)
from app.services.bank_inventory import maybe_chain_another_topup, scan_and_enqueue_thin_topics

logger = get_logger(__name__)


async def _difficulty_from_payload(payload: dict) -> DifficultyLabel:
    raw = str(payload.get("difficulty") or "medium")
    try:
        return DifficultyLabel(raw)
    except ValueError:
        return DifficultyLabel.MEDIUM


def _language_for(job: GenerationJob) -> ContentLanguage:
    """Job column first, payload second — jobs queued before the column
    existed only carry the language in their payload (and older ones not at
    all, which normalizes to English, which is what they were)."""
    return normalize_language(
        job.language or (job.payload or {}).get("language"),
    )


def _temporality_for(payload: dict) -> Temporality:
    """Jobs queued before freshness existed have no temporality key, which
    normalizes to static — the behaviour they were queued expecting."""
    return normalize_temporality(payload.get("temporality"))


async def _context_for(db, job: GenerationJob, payload: dict, language: ContentLanguage):
    """Grounding for a queued job, if its topic needs any.

    Paid search is refused on this path regardless of configuration: a worker
    job is not a player waiting on a response, and a retry loop that can spend
    money per attempt is a bill with a feedback loop in it. Long-tail topics
    get their one paid search on the inline request path or not at all.
    """
    return await build_context(
        db,
        subject=str(payload.get("subject") or ""),
        temporality=_temporality_for(payload),
        queries=payload.get("search_queries"),
        language=language,
        category=payload.get("category"),
        recency_window_days=payload.get("recency_window_days"),
        allow_paid_search=False,
    )


async def _process_bank_topup(db, job: GenerationJob, llm) -> None:
    if not job.topic_id:
        job.status = GenerationJobStatus.FAILED
        job.error_message = "Missing topic_id for bank_topup"
        return

    topic = await db.scalar(select(Topic).where(Topic.id == job.topic_id))
    if not topic or not topic.is_active:
        job.status = GenerationJobStatus.FAILED
        job.error_message = "Topic not found or inactive"
        return

    payload = job.payload or {}
    difficulty = await _difficulty_from_payload(payload)
    style = payload.get("style")
    language = _language_for(job)

    outcome = await run_generation_pipeline(
        db,
        topic=topic,
        difficulty=difficulty,
        count=job.requested_count,
        style=style,
        provider=llm,
        language=language,
        temporality=_temporality_for(payload),
        context=await _context_for(db, job, payload, language),
    )
    job.approved_count = len(outcome.approved)
    job.rejected_count = len(outcome.rejected)

    if len(outcome.approved) == 0:
        job.status = GenerationJobStatus.FAILED
        job.error_message = "No questions approved in top-up chunk"
        return

    job.status = GenerationJobStatus.COMPLETED
    await maybe_chain_another_topup(db, topic, language=language)


async def _process_legacy_custom(db, job: GenerationJob, llm) -> None:
    """Fallback for older queued custom jobs that never got an inline topic."""
    custom: CustomTopic | None = None
    if job.custom_topic_id:
        custom = await db.scalar(select(CustomTopic).where(CustomTopic.id == job.custom_topic_id))

    payload = job.payload or {}
    subject = str(payload.get("subject") or (custom.classified_subject if custom else "Custom"))
    difficulty = await _difficulty_from_payload(payload)
    style = payload.get("style")
    language = normalize_language(
        job.language or payload.get("language") or (custom.language if custom else None)
    )
    prompt = sanitize_topic_prompt(
        str(payload.get("prompt") or (custom.sanitized_prompt if custom else subject))
    )

    topic = Topic(
        slug=f"custom-{slugify(subject)}-{str(job.id)[:8]}",
        name=subject[:120],
        description=f"Custom quiz: {prompt}",
        icon="✨",
        is_custom=True,
        is_active=True,
        created_by_user_id=job.requested_by_user_id,
        popularity_score=10,
    )
    db.add(topic)
    await db.flush()
    job.topic_id = topic.id

    outcome = await run_generation_pipeline(
        db,
        topic=topic,
        difficulty=difficulty,
        count=job.requested_count,
        style=style,
        provider=llm,
        language=language,
        temporality=_temporality_for(payload),
        context=await _context_for(db, job, payload, language),
    )
    job.approved_count = len(outcome.approved)
    job.rejected_count = len(outcome.rejected)
    if len(outcome.approved) < 3:
        job.status = GenerationJobStatus.FAILED
        job.error_message = "Not enough approved questions"
        if custom:
            custom.status = "failed"
        return

    job.status = GenerationJobStatus.COMPLETED
    if custom:
        custom.topic_id = topic.id
        custom.status = "ready"
    await maybe_chain_another_topup(db, topic, language=language)


async def process_queued_jobs(limit: int = 3) -> int:
    """Claim and complete a small batch of queued generation jobs."""
    processed = 0
    async with session_scope() as db:
        result = await db.execute(
            select(GenerationJob)
            .where(GenerationJob.status == GenerationJobStatus.QUEUED)
            .order_by(GenerationJob.created_at.asc())
            .limit(limit)
            .with_for_update(skip_locked=True)
        )
        jobs = list(result.scalars().all())
        if not jobs:
            return 0

        llm = get_llm_provider()
        for job in jobs:
            job.status = GenerationJobStatus.RUNNING
            job.attempts = (job.attempts or 0) + 1
            await db.flush()

            payload = job.payload or {}
            job_type = str(payload.get("job_type") or "")

            try:
                if job_type == "bank_topup" or (job.topic_id and not job.custom_topic_id):
                    await _process_bank_topup(db, job, llm)
                else:
                    await _process_legacy_custom(db, job, llm)
                processed += 1
            except Exception as exc:  # noqa: BLE001
                logger.exception("job_failed", job_id=str(job.id), error=str(exc))
                job.status = GenerationJobStatus.FAILED
                job.error_message = str(exc)[:500]
                processed += 1

    return processed


async def process_inventory_maintenance() -> int:
    """Enqueue top-ups for thin topics (non-blocking; generation happens via jobs)."""
    async with session_scope() as db:
        return await scan_and_enqueue_thin_topics(db, limit=5)
