"""Pre-built current-affairs banks, rebuilt daily from the harvested corpus.

This is where the economics of the feature actually land. Building the banks on
a schedule instead of on demand:

* turns a per-player cost into a fixed daily one — six categories in two
  languages is roughly $0.04/day at gpt-4o-mini rates, about $13/year;
* removes the wait. A player tapping "India This Week" reads from a bank that
  was filled hours ago, so the current-affairs path is the *fastest* content in
  the app rather than the slowest;
* makes the content shared, so it can carry a leaderboard and feed the daily
  challenge — a per-player generated quiz can do neither.

Questions here expire on their own. They are written from `fast`-volatility
sources, so yesterday's bank retires itself while today's is being built; there
is no separate teardown.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.pipeline import run_generation_pipeline
from app.ai.providers import RetrievedContext, get_llm_provider
from app.core.config import get_settings
from app.core.freshness import Temporality
from app.core.languages import ContentLanguage, normalize_language, supported_languages
from app.core.logging import get_logger
from app.core.redis import get_redis
from app.models import DifficultyLabel, Topic
from app.services import news_corpus

logger = get_logger(__name__)
settings = get_settings()


class NewsTopicSpec:
    """A rolling news topic: one per category, shared across languages."""

    __slots__ = ("category", "slug", "name", "name_hi", "icon")

    def __init__(self, category: str, slug: str, name: str, name_hi: str, icon: str) -> None:
        self.category = category
        self.slug = slug
        self.name = name
        self.name_hi = name_hi
        self.icon = icon


NEWS_TOPICS: tuple[NewsTopicSpec, ...] = (
    NewsTopicSpec("india", "news-india", "India This Week", "भारत इस सप्ताह", "🇮🇳"),
    NewsTopicSpec("world", "news-world", "World This Week", "विश्व इस सप्ताह", "🌍"),
    NewsTopicSpec("sport", "news-sport", "Sport This Week", "खेल इस सप्ताह", "🏆"),
    NewsTopicSpec("tech", "news-tech", "Tech This Week", "तकनीक इस सप्ताह", "💻"),
    NewsTopicSpec("business", "news-business", "Business This Week", "कारोबार इस सप्ताह", "📈"),
    NewsTopicSpec(
        "entertainment",
        "news-entertainment",
        "Entertainment This Week",
        "मनोरंजन इस सप्ताह",
        "🎬",
    ),
)

#: How far back a bank draws. A week rather than a day so a quiet Tuesday still
#: has enough distinct stories to build twenty questions from.
_SOURCE_WINDOW_DAYS = 7


async def ensure_news_topic(db: AsyncSession, spec: NewsTopicSpec) -> Topic:
    """Get or create the durable topic row for a category."""
    topic = await db.scalar(select(Topic).where(Topic.slug == spec.slug))
    if topic:
        # Repair a topic created before the flag existed, or one an admin
        # toggled off — the builder is the authority on what these are.
        topic.is_news = True
        topic.is_active = True
        return topic

    topic = Topic(
        id=uuid4(),
        slug=spec.slug,
        name=spec.name,
        description=f"Fresh questions from this week's {spec.category} headlines.",
        icon=spec.icon,
        is_custom=False,
        is_news=True,
        is_active=True,
        # Above the seeded catalog's default so today's news surfaces near the
        # top of the topic list, which is the only place it is worth anything.
        popularity_score=50,
        name_i18n={"en": spec.name, "hi": spec.name_hi},
        description_i18n={},
    )
    db.add(topic)
    await db.flush()
    logger.info("news_topic_created", slug=spec.slug)
    return topic


async def refresh_bank(
    db: AsyncSession,
    spec: NewsTopicSpec,
    *,
    language: ContentLanguage,
    count: Optional[int] = None,
) -> int:
    """Build one category-language bank from the corpus. Returns questions added."""
    language = normalize_language(language)
    wanted = count or settings.daily_news_bank_question_count

    snippets = await news_corpus.recent(
        db,
        category=spec.category,
        language=language,
        # Ask for more sources than questions: the model needs room to pick the
        # stories that actually make good questions, and a 1:1 ratio forces it
        # to write one about every routine headline it was handed.
        limit=max(wanted, settings.grounding_snippet_count) + 4,
        max_age_days=_SOURCE_WINDOW_DAYS,
    )
    if len(snippets) < settings.grounding_min_snippets:
        # A language with thin feed coverage (Hindi outside `india`) reaches
        # here routinely. Generating ungrounded would defeat the point, so the
        # bank simply does not refresh today.
        logger.info(
            "news_bank_skipped_thin_corpus",
            slug=spec.slug,
            language=language.value,
            snippets=len(snippets),
        )
        return 0

    topic = await ensure_news_topic(db, spec)
    context = RetrievedContext(snippets=snippets, query=f"{spec.category} news")

    outcome = await run_generation_pipeline(
        db,
        topic=topic,
        difficulty=DifficultyLabel.MEDIUM,
        count=wanted,
        style="current affairs — factual, anchored to a date, no opinion",
        provider=get_llm_provider(),
        language=language,
        temporality=Temporality.CURRENT,
        context=context,
    )
    logger.info(
        "news_bank_refreshed",
        slug=spec.slug,
        language=language.value,
        approved=len(outcome.approved),
        rejected=len(outcome.rejected),
        sources=len(snippets),
    )
    return len(outcome.approved)


async def refresh_all(db: AsyncSession) -> dict[str, int]:
    """Rebuild every news bank in every supported language."""
    if not settings.daily_news_banks_enabled:
        return {}

    results: dict[str, int] = {}
    for spec in NEWS_TOPICS:
        for profile in supported_languages():
            key = f"{spec.slug}:{profile.code}"
            try:
                results[key] = await refresh_bank(db, spec, language=profile.language)
            except Exception as exc:  # noqa: BLE001 — one bad category must not
                # abandon the other eleven banks.
                logger.exception(
                    "news_bank_failed",
                    slug=spec.slug,
                    language=profile.code,
                    error=str(exc),
                )
                results[key] = 0
    return results


async def claim_daily_build(*, now: Optional[datetime] = None) -> bool:
    """True at most once per UTC day, across every worker process.

    A Redis day-key rather than a tick counter: tick counting restarts with the
    process, so a worker that redeploys twice in a morning would rebuild every
    bank twice and pay for it twice.

    Fails *closed* when Redis is down — skipping a day's rebuild costs one day
    of staleness on a bank that already carries its own expiry, while
    double-building costs money every time.
    """
    moment = now or datetime.now(timezone.utc)
    try:
        redis = await get_redis()
        acquired = await redis.set(
            f"news_banks_built:{moment:%Y-%m-%d}",
            "1",
            nx=True,
            ex=60 * 60 * 36,
        )
        return bool(acquired)
    except Exception as exc:  # noqa: BLE001
        logger.warning("news_bank_claim_unavailable", error=str(exc))
        return False
