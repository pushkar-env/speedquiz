"""Paid web search — the long-tail fallback when the corpus has no answer.

Off by default (``SEARCH_PROVIDER=none``). Every call here costs real money at
roughly five times the LLM batch it feeds, so it sits behind three independent
gates and each one can shut the path off on its own:

* **configured** — a provider and key must be set;
* **entitled** — premium only, by default, so the long tail is paid for by the
  people using it;
* **budgeted** — a hard global ceiling per UTC day, so a bug or a hostile
  client cannot run up an unbounded bill overnight.

The budget counter lives in Redis and fails *closed*: if Redis is unreachable
we cannot know how much has been spent, and the safe reading of "unknown" is
"stop", not "carry on".
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

import httpx
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers import ContextSnippet, RetrievedContext
from app.core.config import get_settings
from app.core.freshness import as_of_date
from app.core.languages import DEFAULT_LANGUAGE, ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.core.redis import get_redis
from app.models import User

logger = get_logger(__name__)
settings = get_settings()

_EXA_URL = "https://api.exa.ai/search"
_TAVILY_URL = "https://api.tavily.com/search"


def search_is_available() -> bool:
    provider = (settings.search_provider or "none").strip().lower()
    return provider in {"exa", "tavily"} and bool((settings.search_api_key or "").strip())


def _budget_key(now: Optional[datetime] = None) -> str:
    moment = now or datetime.now(timezone.utc)
    return f"search_budget:{moment:%Y-%m-%d}"


async def _claim_budget() -> bool:
    """Take one unit of today's search budget. False means don't search.

    Increment-then-check rather than check-then-increment: two concurrent
    generation jobs would otherwise both read the last remaining unit and both
    spend it.
    """
    if settings.search_daily_budget <= 0:
        return False
    try:
        redis = await get_redis()
        key = _budget_key()
        used = await redis.incr(key)
        if used == 1:
            # First claim of the day: let the counter fall off on its own two
            # days later rather than scheduling a reset.
            await redis.expire(key, 60 * 60 * 48)
        if used > settings.search_daily_budget:
            logger.warning(
                "search_budget_exhausted",
                used=used,
                budget=settings.search_daily_budget,
            )
            return False
        return True
    except Exception as exc:  # noqa: BLE001
        # Fail closed. An unmeasurable budget is not an unlimited one.
        logger.warning("search_budget_unavailable", error=str(exc))
        return False


def _entitled(user: Optional[User]) -> bool:
    if not settings.search_premium_only:
        return True
    return bool(user is not None and user.is_premium)


async def _exa(client: httpx.AsyncClient, query: str, limit: int) -> list[dict]:
    response = await client.post(
        _EXA_URL,
        headers={"x-api-key": settings.search_api_key, "Content-Type": "application/json"},
        json={
            "query": query,
            "numResults": limit,
            "type": "auto",
            # Ask for a summary rather than full text: the prompt only needs
            # enough to write a question from, and full page text would cost
            # more in generation tokens than the search itself did.
            "contents": {"text": {"maxCharacters": 600}},
        },
    )
    response.raise_for_status()
    payload = response.json()
    return [
        {
            "title": item.get("title") or "",
            "url": item.get("url") or "",
            "summary": (item.get("text") or item.get("summary") or "")[:600],
            "published_at": as_of_date(item.get("publishedDate")),
            "source": "exa",
        }
        for item in (payload.get("results") or [])
    ]


async def _tavily(client: httpx.AsyncClient, query: str, limit: int) -> list[dict]:
    response = await client.post(
        _TAVILY_URL,
        headers={"Content-Type": "application/json"},
        json={
            "api_key": settings.search_api_key,
            "query": query,
            "max_results": limit,
            "search_depth": "basic",
            "topic": "news",
        },
    )
    response.raise_for_status()
    payload = response.json()
    return [
        {
            "title": item.get("title") or "",
            "url": item.get("url") or "",
            "summary": (item.get("content") or "")[:600],
            "published_at": as_of_date(item.get("published_date")),
            "source": "tavily",
        }
        for item in (payload.get("results") or [])
    ]


async def search_provider_context(
    db: AsyncSession,
    *,
    queries: list[str],
    language: ContentLanguage = DEFAULT_LANGUAGE,
    user: Optional[User] = None,
) -> RetrievedContext:
    """One paid search, if all three gates allow it.

    ``db`` is unused today but kept in the signature: results are not persisted
    to the corpus yet, and when they are, that write belongs here rather than
    in a second pass over the caller.
    """
    if not search_is_available():
        return RetrievedContext()
    if not _entitled(user):
        logger.info("search_skipped_entitlement", premium_only=settings.search_premium_only)
        return RetrievedContext()

    query = next((q.strip() for q in queries if q and q.strip()), "")
    if not query:
        return RetrievedContext()

    # Only ever one search per generation, however many queries the classifier
    # proposed. Three searches would triple the cost of the most expensive path
    # in the system to marginally broaden a result set the model then has to
    # read anyway.
    if not await _claim_budget():
        return RetrievedContext()

    provider = (settings.search_provider or "").strip().lower()
    limit = settings.grounding_snippet_count
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            if provider == "exa":
                rows = await _exa(client, query, limit)
            else:
                rows = await _tavily(client, query, limit)
    except Exception as exc:  # noqa: BLE001 — a failed search degrades to no grounding
        logger.warning("search_failed", provider=provider, error=str(exc))
        return RetrievedContext()

    normalize_language(language)
    snippets = [
        ContextSnippet(
            id=f"S{i + 1}",
            title=row["title"],
            summary=row["summary"],
            url=row["url"],
            source=row["source"],
            published_at=row["published_at"],
        )
        for i, row in enumerate(rows)
        if row["title"] and row["url"]
    ]
    logger.info("search_completed", provider=provider, results=len(snippets), query=query[:80])
    return RetrievedContext(snippets=snippets, query=query)
