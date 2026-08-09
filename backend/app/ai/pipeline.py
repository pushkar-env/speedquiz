"""Question generation pipeline: validate → score → dedupe → approve/store.

Gameplay never calls this path — only workers / custom-topic preparation.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from hashlib import sha256
from typing import Optional
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.ai.providers import GeneratedQuestionDraft, LLMProvider, ValidationResult, get_llm_provider
from app.core.config import get_settings
from app.core.logging import get_logger
from app.models import (
    DifficultyLabel,
    Question,
    QuestionOption,
    QuestionStatus,
    Topic,
)

logger = get_logger(__name__)
settings = get_settings()


@dataclass
class PipelineOutcome:
    approved: list[Question] = field(default_factory=list)
    rejected: list[dict] = field(default_factory=list)
    drafts_seen: int = 0


def sanitize_topic_prompt(raw: str) -> str:
    cleaned = re.sub(r"\s+", " ", raw or "").strip()
    cleaned = re.sub(r"[<>{}]", "", cleaned)
    return cleaned[:200]


def slugify(text: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return (base or "custom")[:80]


def content_hash(prompt: str, options: list[str]) -> str:
    raw = "|".join([prompt.strip().lower(), *[o.strip().lower() for o in options]])
    return sha256(raw.encode("utf-8")).hexdigest()


def fingerprint(prompt: str) -> str:
    tokens = re.findall(r"[a-z0-9]+", prompt.lower())
    return sha256(" ".join(sorted(set(tokens))).encode("utf-8")).hexdigest()[:32]


def schema_validate(draft: GeneratedQuestionDraft) -> list[str]:
    reasons: list[str] = []
    if not draft.question or len(draft.question.strip()) < 8:
        reasons.append("malformed_question")
    if len(draft.options) != 4:
        reasons.append("must_have_four_options")
    else:
        normalized = [o.strip().lower() for o in draft.options]
        if any(not o for o in normalized):
            reasons.append("empty_option")
        if len(set(normalized)) < 4:
            reasons.append("duplicate_options")
    if draft.correct_option < 0 or draft.correct_option > 3:
        reasons.append("invalid_correct_option")
    if not draft.explanation or len(draft.explanation.strip()) < 8:
        reasons.append("malformed_explanation")
    if draft.difficulty < 0 or draft.difficulty > 1:
        reasons.append("invalid_difficulty")
    return reasons


def difficulty_label_for(value: float) -> DifficultyLabel:
    if value < 0.4:
        return DifficultyLabel.EASY
    if value < 0.65:
        return DifficultyLabel.MEDIUM
    if value < 0.85:
        return DifficultyLabel.HARD
    return DifficultyLabel.EXPERT


async def _is_duplicate(
    db: AsyncSession,
    *,
    topic_id: UUID,
    prompt: str,
    options: list[str],
) -> bool:
    h = content_hash(prompt, options)
    existing = await db.scalar(select(Question.id).where(Question.content_hash == h))
    if existing:
        return True

    fp = fingerprint(prompt)
    similar = await db.scalar(
        select(Question.id).where(
            Question.topic_id == topic_id,
            Question.embedding_fingerprint == fp,
            Question.status == QuestionStatus.ACTIVE,
        )
    )
    return similar is not None


async def run_generation_pipeline(
    db: AsyncSession,
    *,
    topic: Topic,
    difficulty: DifficultyLabel,
    count: int,
    style: Optional[str] = None,
    subcategory: Optional[str] = None,
    provider: Optional[LLMProvider] = None,
    max_attempts: int = 2,
) -> PipelineOutcome:
    """Generate, validate, dedupe, and persist questions for a topic."""
    llm = provider or get_llm_provider()
    outcome = PipelineOutcome()
    remaining = max(1, count)
    attempts = 0

    while remaining > 0 and attempts < max_attempts:
        attempts += 1
        batch = min(remaining + 2, settings.generation_batch_size)
        try:
            drafts = await llm.generate_questions(
                topic=topic.name,
                difficulty=difficulty.value,
                count=batch,
                style=style,
                subcategory=subcategory,
            )
        except Exception as exc:  # noqa: BLE001 — never crash workers on bad LLM output
            logger.exception("generation_failed", error=str(exc), attempt=attempts)
            outcome.rejected.append({"reason": "generation_error", "error": str(exc)})
            continue

        try:
            validations = await llm.validate_questions(drafts)
        except Exception as exc:  # noqa: BLE001
            logger.exception("validation_failed", error=str(exc))
            validations = [
                ValidationResult(approved=False, quality_score=0, reasons=["ai_validation_error"])
                for _ in drafts
            ]

        for draft, ai_result in zip(drafts, validations):
            outcome.drafts_seen += 1
            schema_reasons = schema_validate(draft)
            reasons = list(schema_reasons)
            quality = ai_result.quality_score if not schema_reasons else min(ai_result.quality_score, 40)
            approved = (
                not schema_reasons
                and ai_result.approved
                and quality >= settings.question_quality_threshold
            )

            if schema_reasons:
                reasons.extend(ai_result.reasons)
            elif not ai_result.approved:
                reasons.extend(ai_result.reasons or ["ai_rejected"])
            elif quality < settings.question_quality_threshold:
                reasons.append("quality_below_threshold")

            if approved:
                dup = await _is_duplicate(
                    db, topic_id=topic.id, prompt=draft.question, options=draft.options
                )
                if dup:
                    approved = False
                    reasons.append("duplicate")

            if not approved:
                outcome.rejected.append(
                    {
                        "question": draft.question[:120],
                        "reasons": reasons,
                        "quality_score": quality,
                    }
                )
                continue

            difficulty_value = ai_result.difficulty or draft.difficulty
            question = Question(
                id=uuid4(),
                topic_id=topic.id,
                prompt=draft.question.strip(),
                explanation=draft.explanation.strip(),
                source=draft.source or "ai_pipeline",
                difficulty=difficulty_value,
                difficulty_label=difficulty_label_for(difficulty_value),
                correct_option_index=draft.correct_option,
                quality_score=quality,
                status=QuestionStatus.ACTIVE,
                content_hash=content_hash(draft.question, draft.options),
                embedding_fingerprint=fingerprint(draft.question),
                generation_meta={
                    "style": style,
                    "subcategory": subcategory or draft.subcategory,
                    "pipeline": "phase4",
                    "provider": settings.llm_provider,
                },
            )
            db.add(question)
            await db.flush()
            for i, text in enumerate(draft.options):
                db.add(QuestionOption(question_id=question.id, position=i, text=text.strip()))
            topic.question_count = (topic.question_count or 0) + 1
            outcome.approved.append(question)
            remaining -= 1
            if remaining <= 0:
                break

    await db.flush()
    logger.info(
        "pipeline_complete",
        topic=topic.slug,
        approved=len(outcome.approved),
        rejected=len(outcome.rejected),
        attempts=attempts,
    )
    return outcome
