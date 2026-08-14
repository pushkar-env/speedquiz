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

from app.ai.providers import (
    GeneratedQuestionDraft,
    LLMProvider,
    RetrievedContext,
    ValidationResult,
    get_llm_provider,
)
from app.core.config import get_settings
from app.core.freshness import (
    DEFAULT_TEMPORALITY,
    Temporality,
    clamp_volatility,
    expires_at_for,
    normalize_volatility,
    volatility_for_temporality,
)
from app.core.languages import DEFAULT_LANGUAGE, ContentLanguage, normalize_language
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
    """ASCII slug for a topic. Non-Latin input degrades to a stable digest.

    Slugs are URL and log identifiers, so they stay ASCII. A Hindi subject
    strips to nothing under that rule, which would collapse every Hindi custom
    topic onto the same slug stem — hence the content-derived suffix rather
    than a bare "custom".
    """
    base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if base:
        return base[:80]
    digest = sha256(text.strip().encode("utf-8")).hexdigest()[:10]
    return f"custom-{digest}"


def content_hash(
    prompt: str,
    options: list[str],
    language: ContentLanguage = DEFAULT_LANGUAGE,
) -> str:
    """Exact-duplicate key. Globally unique across the questions table.

    Language is part of the key because some strings are identical in both
    languages — "NATO?", "Wi-Fi?", a bare formula — and the English row must
    not block the Hindi bank from ever storing its own copy.
    """
    raw = "|".join(
        [
            normalize_language(language).value,
            prompt.strip().lower(),
            *[o.strip().lower() for o in options],
        ]
    )
    return sha256(raw.encode("utf-8")).hexdigest()


def fingerprint(prompt: str) -> str:
    """Near-duplicate key: the prompt's word bag, order-insensitive.

    ``\\w`` with Unicode semantics rather than ``[a-z0-9]``. The ASCII class
    matched nothing in Devanagari, so every Hindi prompt hashed the empty
    string — meaning the second Hindi question ever generated for a topic, and
    every one after it, was rejected as a duplicate of the first.
    """
    tokens = re.findall(r"\w+", prompt.lower(), flags=re.UNICODE)
    return sha256(" ".join(sorted(set(tokens))).encode("utf-8")).hexdigest()[:32]


def citation_reasons(
    draft: GeneratedQuestionDraft,
    context: Optional[RetrievedContext],
) -> list[str]:
    """Reject a grounded draft that does not cite the grounding it was given.

    This is the whole safety story for live content. A stale question is a
    question a player might already know is old; a *confidently wrong* one
    invented on top of a news article is worse, because it reads as current and
    the player can check it in ten seconds.

    Only enforced when grounding was actually supplied — ungrounded generation
    over settled subjects has nothing to cite and is unaffected.
    """
    if not context:
        return []
    cited = [str(s).strip() for s in (draft.source_ids or []) if str(s).strip()]
    if not cited:
        return ["uncited"]
    unknown = [s for s in cited if s not in context.valid_ids]
    if unknown:
        # A fabricated citation is a stronger signal than no citation: the
        # model invented a source label to satisfy the format.
        return ["unknown_source"]
    return []


#: Phrasing that makes a question's answer depend on when it is *read* rather
#: than on a fact. "What did X recently announce?" has no stable answer: it was
#: true the day it was written and is misleading a month later.
#:
#: Deliberately NOT shared with ``freshness._CURRENT_TERMS`` despite the
#: overlap. That list detects a time-sensitive *request*, where "current
#: affairs" is a good thing to say and means "go and fetch sources". This one
#: rejects a rotting *answer*. Same words, opposite verdicts — merging them
#: would make one of the two behaviours wrong.
_TIME_RELATIVE = re.compile(
    r"(?:^|\W)(?:"
    r"recent(?:ly)?|currently|reportedly|of late|nowadays|"
    r"just (?:announced?|revealed?|reported?|unveiled?)|"
    r"this (?:week|month)|these days|"
    r"हाल ही|हाल में|अभी हाल|इन दिनों"
    r")(?:\W|$)",
    re.IGNORECASE | re.UNICODE,
)


def time_anchor_reasons(
    draft: GeneratedQuestionDraft,
    temporality: Temporality,
) -> list[str]:
    """Reject a question whose answer depends on when the player reads it.

    Only applied to time-sensitive batches, where it is a real failure: a
    settled-subject question saying "recently" is loose writing, but a news
    question saying it is *wrong* within weeks and the expiry machinery cannot
    save it — the question was never anchored to anything to begin with.

    This exists because asking the model nicely did not work. The generation
    prompt spells out "not 'who is the current champion' but 'who won the title
    on 12 August 2026'", and the first production batch still came back 27%
    time-relative and only 26% date-anchored. An instruction the model follows a
    quarter of the time is a suggestion; this is the rule.
    """
    if temporality is Temporality.STATIC:
        return []
    if _TIME_RELATIVE.search(draft.question or ""):
        return ["time_relative_phrasing"]
    return []


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
    language: ContentLanguage = DEFAULT_LANGUAGE,
) -> bool:
    h = content_hash(prompt, options, language)
    existing = await db.scalar(select(Question.id).where(Question.content_hash == h))
    if existing:
        return True

    # Near-duplicate check is per (topic, language): the Hindi translation of an
    # existing English question is a *new* question for a Hindi run, and the
    # bank has to be able to hold both.
    fp = fingerprint(prompt)
    similar = await db.scalar(
        select(Question.id).where(
            Question.topic_id == topic_id,
            Question.language == normalize_language(language).value,
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
    language: ContentLanguage = DEFAULT_LANGUAGE,
    temporality: Temporality = DEFAULT_TEMPORALITY,
    context: Optional[RetrievedContext] = None,
) -> PipelineOutcome:
    """Generate, validate, dedupe, and persist questions for a topic.

    ``temporality`` decides the fallback volatility for any draft the model
    does not label, and ``context`` carries grounding snippets for topics that
    need live facts. Both default to the settled case, so every existing caller
    keeps the exact behaviour it had.
    """
    llm = provider or get_llm_provider()
    language = normalize_language(language)
    # A topic's display name is stored in English; ask for questions *about*
    # that subject rather than passing the localized name through, so the model
    # never has to guess which part of the prompt is the subject.
    topic_name = topic.name
    outcome = PipelineOutcome()
    remaining = max(1, count)
    attempts = 0

    while remaining > 0 and attempts < max_attempts:
        attempts += 1
        batch = min(remaining + 2, settings.generation_batch_size)
        try:
            drafts = await llm.generate_questions(
                topic=topic_name,
                difficulty=difficulty.value,
                count=batch,
                style=style,
                subcategory=subcategory,
                language=language,
                context=context,
            )
        except Exception as exc:  # noqa: BLE001 — never crash workers on bad LLM output
            logger.exception("generation_failed", error=str(exc), attempt=attempts)
            outcome.rejected.append({"reason": "generation_error", "error": str(exc)})
            continue

        try:
            validations = await llm.validate_questions(drafts, language=language)
        except Exception as exc:  # noqa: BLE001
            logger.exception("validation_failed", error=str(exc))
            validations = [
                ValidationResult(approved=False, quality_score=0, reasons=["ai_validation_error"])
                for _ in drafts
            ]

        for draft, ai_result in zip(drafts, validations):
            outcome.drafts_seen += 1
            schema_reasons = (
                schema_validate(draft)
                + citation_reasons(draft, context)
                + time_anchor_reasons(draft, temporality)
            )
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
                    db,
                    topic_id=topic.id,
                    prompt=draft.question,
                    options=draft.options,
                    language=language,
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
            volatility = clamp_volatility(
                normalize_volatility(
                    draft.volatility,
                    default=volatility_for_temporality(temporality),
                ),
                temporality,
            )
            # Prefer the model's own as-of date, then the newest source it was
            # shown. A batch built from a three-week-old article must not get a
            # fresh 30 days just because generation ran today.
            valid_as_of = draft.valid_as_of or (context.newest_published_at if context else None)
            question = Question(
                id=uuid4(),
                topic_id=topic.id,
                prompt=draft.question.strip(),
                explanation=draft.explanation.strip(),
                language=language.value,
                source=draft.source or "ai_pipeline",
                difficulty=difficulty_value,
                difficulty_label=difficulty_label_for(difficulty_value),
                correct_option_index=draft.correct_option,
                quality_score=quality,
                status=QuestionStatus.ACTIVE,
                content_hash=content_hash(draft.question, draft.options, language),
                embedding_fingerprint=fingerprint(draft.question),
                volatility=volatility.value,
                valid_as_of=valid_as_of,
                expires_at=expires_at_for(volatility, valid_as_of=valid_as_of),
                generation_meta={
                    "style": style,
                    "subcategory": subcategory or draft.subcategory,
                    "pipeline": "phase4",
                    "provider": settings.llm_provider,
                    "language": language.value,
                    "temporality": temporality.value,
                    "source_ids": draft.source_ids,
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
        language=language.value,
        approved=len(outcome.approved),
        rejected=len(outcome.rejected),
        attempts=attempts,
    )
    return outcome
