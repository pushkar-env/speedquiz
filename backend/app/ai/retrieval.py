"""Decide what grounding a generation call gets, and what it costs.

The order here is the whole cost story:

1. Settled topic → no grounding at all. Most requests land here, and they cost
   exactly what they cost before any of this existed.
2. Time-sensitive topic → the harvested corpus. Free, already local, and shared
   across every player asking about the same week.
3. Corpus miss on a long-tail topic → a paid search, if one is configured and
   the caller is allowed one. This is the only path that spends money per
   request, which is why it is last and why it is gated three ways.

A live search costs roughly $0.007, against roughly $0.0015 for the whole
generation-plus-validation batch it feeds. Reaching step 3 routinely would
invert the economics of the feature, so the corpus is not an optimisation —
it is the design.
"""

from __future__ import annotations

from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers import RetrievedContext
from app.core.config import get_settings
from app.core.freshness import Temporality
from app.core.languages import DEFAULT_LANGUAGE, ContentLanguage
from app.core.logging import get_logger
from app.models import User
from app.services import news_corpus

logger = get_logger(__name__)
settings = get_settings()


def _fallback_queries(subject: str, queries: Optional[list[str]]) -> list[str]:
    """Whatever the classifier proposed, else the subject itself."""
    cleaned = [q.strip() for q in (queries or []) if q and q.strip()]
    if cleaned:
        return cleaned[:3]
    subject = (subject or "").strip()
    return [subject] if subject else []


async def build_context(
    db: AsyncSession,
    *,
    subject: str,
    temporality: Temporality,
    queries: Optional[list[str]] = None,
    language: ContentLanguage = DEFAULT_LANGUAGE,
    category: Optional[str] = None,
    recency_window_days: Optional[int] = None,
    user: Optional[User] = None,
    allow_paid_search: bool = True,
) -> RetrievedContext:
    """Grounding for one generation call, cheapest source first."""
    if temporality is Temporality.STATIC:
        return RetrievedContext()
    if not settings.news_corpus_enabled:
        return RetrievedContext()

    search_terms = _fallback_queries(subject, queries)
    if not search_terms:
        return RetrievedContext()

    context = await news_corpus.context_for(
        db,
        queries=search_terms,
        language=language,
        category=category,
        max_age_days=recency_window_days,
    )
    if len(context.snippets) >= settings.grounding_min_snippets:
        logger.info(
            "grounding_corpus_hit",
            subject=subject[:60],
            snippets=len(context.snippets),
            language=language.value,
        )
        return context

    # Corpus miss. Either the topic is long-tail ("the Artemis IV crew") or the
    # harvest has not covered it. Fall through to paid search when allowed.
    from app.ai.web_search import search_provider_context, search_is_available

    if not (allow_paid_search and search_is_available()):
        if context.snippets:
            # Thin, but real. Better than ungrounded for a current topic: the
            # citation gate still forces every question back to these sources.
            logger.info(
                "grounding_thin",
                subject=subject[:60],
                snippets=len(context.snippets),
            )
        else:
            logger.info("grounding_missing", subject=subject[:60], language=language.value)
        return context

    paid = await search_provider_context(
        db,
        queries=search_terms,
        language=language,
        user=user,
    )
    if paid.snippets:
        logger.info(
            "grounding_search_hit",
            subject=subject[:60],
            snippets=len(paid.snippets),
        )
        return paid
    return context
