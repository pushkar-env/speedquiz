"""Harvest public feeds into a shared grounding corpus, and search it.

Why a harvested corpus rather than a search API per request
-----------------------------------------------------------
Current affairs is a *shared* interest. Ten thousand players asking about this
week's news want the same few hundred facts, so pulling those facts once every
few minutes and serving them to every generation call costs O(feeds × day),
while a search per request costs O(users). At Exa's $7/1000 the second option
costs several times more than the LLM call it feeds; this one costs nothing.

What is stored
--------------
Title, summary, link, publish date — exactly what a feed publishes for
syndication. Never article body. A quiz question about a fact is our own work;
a stored copy of someone's prose is not.

Parsing is stdlib ElementTree rather than a feed library. The subset of RSS 2.0
and Atom that matters here is a dozen tags, feeds are hostile input from
untrusted hosts, and not adding a parser dependency keeps that surface small.
"""

from __future__ import annotations

import asyncio
import html
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from hashlib import sha256
from typing import Iterable, Optional
from urllib.parse import urlparse
from uuid import uuid4
from xml.etree import ElementTree

import httpx
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.providers import ContextSnippet, RetrievedContext
from app.core.config import get_settings
from app.core.languages import DEFAULT_LANGUAGE, ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.models import NewsDocument

logger = get_logger(__name__)
settings = get_settings()

#: Postgres text-search config per language. Hindi has no stemmer shipped with
#: Postgres, so it uses `simple` — tokenization without stemming, which for
#: Devanagari is what `english` would effectively do anyway, minus the wrong
#: stemming rules. Must match the generated column in `NewsDocument`.
_FTS_CONFIG: dict[ContentLanguage, str] = {
    ContentLanguage.ENGLISH: "english",
    ContentLanguage.HINDI: "simple",
}

#: Categories the corpus is bucketed into. Assigned per feed rather than
#: inferred per article: inference would cost an LLM call per document, which
#: is the one cost this whole design exists to avoid.
CATEGORIES = ("india", "world", "sport", "tech", "business", "entertainment")


@dataclass(frozen=True)
class Feed:
    url: str
    category: str
    language: ContentLanguage = DEFAULT_LANGUAGE

    @property
    def source(self) -> str:
        return _canonical_host(urlparse(self.url).netloc)


#: Best-effort defaults, overridable per deployment via `NEWS_FEED_URLS`
#: without a code change — feeds move, get walled, or die, and that should be
#: a config edit at 2am rather than a release.
DEFAULT_FEEDS: tuple[Feed, ...] = (
    # India
    Feed("https://www.thehindu.com/news/national/feeder/default.rss", "india"),
    Feed("https://indianexpress.com/section/india/feed/", "india"),
    Feed("https://feeds.feedburner.com/ndtvnews-india-news", "india"),
    # World
    Feed("https://feeds.bbci.co.uk/news/world/rss.xml", "world"),
    Feed("https://www.aljazeera.com/xml/rss/all.xml", "world"),
    # Sport
    Feed("https://feeds.bbci.co.uk/sport/rss.xml", "sport"),
    Feed("https://www.espncricinfo.com/rss/content/story/feeds/0.xml", "sport"),
    # Tech
    Feed("https://feeds.arstechnica.com/arstechnica/index", "tech"),
    Feed("https://www.theverge.com/rss/index.xml", "tech"),
    # Business
    Feed("https://economictimes.indiatimes.com/rssfeedstopstories.cms", "business"),
    # Entertainment
    Feed("https://variety.com/feed/", "entertainment"),
    # Hindi. Thinner than the English side, which is why the generator is
    # allowed to ground a Hindi batch on English sources — see
    # `OpenAILLMProvider.generate_questions`.
    Feed("https://feeds.bbci.co.uk/hindi/rss.xml", "india", ContentLanguage.HINDI),
    Feed("https://www.aajtak.in/rssfeeds/?id=home", "india", ContentLanguage.HINDI),
    Feed("https://feeds.feedburner.com/ndtvkhabar-latest", "india", ContentLanguage.HINDI),
)

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")
#: Strips the XML namespace ElementTree prefixes onto every tag.
_NS_RE = re.compile(r"^\{[^}]+\}")


def configured_feeds() -> list[Feed]:
    """Feeds from settings, else the built-in list.

    Setting format is one entry per comma: ``url|category|lang``, with category
    and language optional. Matches the delimiter style already used by
    ``streak_multiplier_tiers``.
    """
    raw = (settings.news_feed_urls or "").strip()
    if not raw:
        return list(DEFAULT_FEEDS)

    feeds: list[Feed] = []
    for chunk in raw.split(","):
        entry = chunk.strip()
        if not entry:
            continue
        parts = [p.strip() for p in entry.split("|")]
        url = parts[0]
        if not url:
            continue
        category = parts[1] if len(parts) > 1 and parts[1] else "general"
        language = normalize_language(parts[2] if len(parts) > 2 else None)
        feeds.append(Feed(url=url, category=category, language=language))
    return feeds or list(DEFAULT_FEEDS)


def _clean_text(text: str) -> str:
    """Feed prose to plain text: drop markup, then decode entities.

    That order matters, and so does the unescape. Several feeds (Aaj Tak, The
    Verge) double-encode — the XML carries ``&amp;#039;``, so the parser hands
    back the literal ``&#039;`` and the headline reaches the model as
    ``&#039;मैं गुस्से में था&#039;``. Ungrounded that is merely ugly; as
    grounding it is a headline the model will faithfully quote into a question.
    """
    stripped = _TAG_RE.sub(" ", text or "")
    return _WS_RE.sub(" ", html.unescape(stripped)).strip()


def _localname(tag: str) -> str:
    return _NS_RE.sub("", tag or "")


def _parse_date(raw: Optional[str]) -> Optional[datetime]:
    """RFC 822 (RSS) or ISO 8601 (Atom), whichever the feed speaks."""
    text = (raw or "").strip()
    if not text:
        return None
    try:
        parsed = parsedate_to_datetime(text)
        if parsed is not None:
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        pass
    iso = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    try:
        parsed = datetime.fromisoformat(iso)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _canonical_host(netloc: str) -> str:
    host = (netloc or "").lower()
    return host[4:] if host.startswith("www.") else host


def document_hash(url: str, title: str) -> str:
    """Dedupe key. URL alone is not enough — aggregator feeds append tracking
    parameters that change per fetch, so the query string is dropped, the title
    carries the identity, and the path disambiguates two stories that happen to
    share a headline.

    The host is canonicalised the same way ``Feed.source`` does it. A publisher
    that links its own stories as both ``example.com`` and ``www.example.com``
    would otherwise insert every story twice, and both copies would then be
    offered to the model as if they were independent corroboration.
    """
    base = urlparse((url or "").strip())
    canonical = f"{_canonical_host(base.netloc)}{base.path.rstrip('/')}"
    return sha256(f"{canonical}|{title.strip().lower()}".encode("utf-8")).hexdigest()


def parse_feed(xml: str, feed: Feed, *, limit: int) -> list[dict]:
    """Pull items out of an RSS 2.0 or Atom document.

    Returns dicts rather than model instances so this stays a pure function —
    the harvest test feeds it fixture XML with no database in sight.
    """
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        logger.warning("feed_parse_failed", feed=feed.url, error=str(exc))
        return []

    items = [el for el in root.iter() if _localname(el.tag) in {"item", "entry"}]
    documents: list[dict] = []
    for item in items[:limit]:
        fields: dict[str, str] = {}
        link = ""
        for child in item:
            name = _localname(child.tag)
            if name == "link":
                # RSS puts the URL in the text, Atom in an href attribute.
                link = link or (child.get("href") or (child.text or "")).strip()
            elif name not in fields:
                fields[name] = (child.text or "").strip()

        title = _clean_text(fields.get("title", ""))
        url = link or fields.get("guid", "")
        if not title or not url:
            continue

        published = _parse_date(
            fields.get("pubDate") or fields.get("published") or fields.get("updated")
        )
        if published is None:
            # An undated document cannot anchor a question's TTL, and guessing
            # "now" would let a month-old story mint a fresh 30-day question.
            continue

        summary = _clean_text(
            fields.get("description") or fields.get("summary") or fields.get("content") or ""
        )
        documents.append(
            {
                "source": feed.source,
                "url": url[:2000],
                "title": title[:500],
                "summary": summary[:1200],
                "published_at": published,
                "language": feed.language.value,
                "category": feed.category,
                "content_hash": document_hash(url, title),
            }
        )
    return documents


async def _fetch_feed(client: httpx.AsyncClient, feed: Feed) -> list[dict]:
    limit = settings.news_harvest_max_items_per_feed
    try:
        response = await client.get(feed.url)
        response.raise_for_status()
    except Exception as exc:  # noqa: BLE001 — one dead feed must not stop a harvest
        logger.warning("feed_fetch_failed", feed=feed.url, error=str(exc))
        return []
    return parse_feed(response.text, feed, limit=limit)


async def harvest(db: AsyncSession, *, feeds: Optional[Iterable[Feed]] = None) -> int:
    """Fetch every feed and upsert what is new. Returns rows inserted.

    Feeds are fetched concurrently but written in one statement: the harvest is
    network-bound, and holding a transaction open across a dozen sequential
    HTTP round trips is what would make this slow.
    """
    if not settings.news_corpus_enabled:
        return 0

    feed_list = list(feeds if feeds is not None else configured_feeds())
    if not feed_list:
        return 0

    headers = {"User-Agent": "SpeedQuiz/1.0 (+https://speedquiz.app)"}
    async with httpx.AsyncClient(timeout=20.0, headers=headers, follow_redirects=True) as client:
        batches = await asyncio.gather(
            *(_fetch_feed(client, feed) for feed in feed_list),
            return_exceptions=False,
        )

    rows: dict[str, dict] = {}
    for batch in batches:
        for doc in batch:
            # Same story from two feeds: first wins, which is the earlier feed
            # in the configured order.
            rows.setdefault(doc["content_hash"], doc)

    if not rows:
        logger.warning("harvest_empty", feeds=len(feed_list))
        return 0

    payload = [{"id": uuid4(), **doc} for doc in rows.values()]
    statement = pg_insert(NewsDocument).values(payload)
    # Re-serving the same story for days is normal feed behaviour, so a
    # collision is the expected case, not an error.
    statement = statement.on_conflict_do_nothing(index_elements=["content_hash"])
    result = await db.execute(statement)

    inserted = result.rowcount if result.rowcount is not None else 0
    logger.info(
        "harvest_complete",
        feeds=len(feed_list),
        seen=len(rows),
        inserted=inserted,
    )
    return inserted


async def purge_old(db: AsyncSession) -> int:
    """Drop documents past the retention window."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=settings.news_corpus_retention_days)
    result = await db.execute(
        delete(NewsDocument).where(NewsDocument.published_at < cutoff)
    )
    removed = result.rowcount or 0
    if removed:
        logger.info("news_corpus_purged", removed=removed, cutoff=cutoff.isoformat())
    return removed


def _tsquery(queries: list[str], config: str):
    """OR the caller's queries into one tsquery.

    ``websearch_to_tsquery`` rather than ``to_tsquery``: the input is a topic
    string that originated with a player, and the strict parser raises a
    syntax error on a stray quote or ampersand. The websearch parser never
    raises — worst case it yields an empty query, which the caller checks for.
    """
    combined = None
    for query in queries:
        text = query.strip()
        if not text:
            continue
        node = func.websearch_to_tsquery(config, text)
        combined = node if combined is None else combined.op("||")(node)
    return combined


async def search(
    db: AsyncSession,
    *,
    queries: list[str],
    language: ContentLanguage = DEFAULT_LANGUAGE,
    category: Optional[str] = None,
    limit: Optional[int] = None,
    max_age_days: Optional[int] = None,
) -> list[ContextSnippet]:
    """Rank the corpus against a topic's search queries."""
    language = normalize_language(language)
    config = _FTS_CONFIG.get(language, "simple")
    cleaned = [q for q in (queries or []) if q and q.strip()]
    if not cleaned:
        return []

    tsquery = _tsquery(cleaned, config)
    if tsquery is None:
        return []

    take = limit or settings.grounding_snippet_count
    stmt = (
        select(NewsDocument)
        .where(
            NewsDocument.language == language.value,
            NewsDocument.search_vector.op("@@")(tsquery),
        )
        # Relevance first, recency as the tiebreak. The other way round hands
        # a batch ten near-identical takes on whatever broke this morning.
        .order_by(
            func.ts_rank_cd(NewsDocument.search_vector, tsquery).desc(),
            NewsDocument.published_at.desc(),
        )
        .limit(take)
    )
    if category:
        stmt = stmt.where(NewsDocument.category == category)
    if max_age_days:
        cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
        stmt = stmt.where(NewsDocument.published_at >= cutoff)

    rows = list((await db.execute(stmt)).scalars().all())
    return _to_snippets(rows)


async def recent(
    db: AsyncSession,
    *,
    category: str,
    language: ContentLanguage = DEFAULT_LANGUAGE,
    limit: Optional[int] = None,
    max_age_days: int = 7,
) -> list[ContextSnippet]:
    """Newest documents in a category — the input to a pre-built news bank.

    No query, because there is no user prompt: the bank *is* "what happened in
    sport this week".
    """
    language = normalize_language(language)
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
    stmt = (
        select(NewsDocument)
        .where(
            NewsDocument.language == language.value,
            NewsDocument.category == category,
            NewsDocument.published_at >= cutoff,
        )
        .order_by(NewsDocument.published_at.desc())
        .limit(limit or settings.grounding_snippet_count)
    )
    rows = list((await db.execute(stmt)).scalars().all())
    return _to_snippets(rows)


def _to_snippets(rows: list[NewsDocument]) -> list[ContextSnippet]:
    """Label documents S1..Sn for citation.

    Positional labels rather than ids: the model repeats them back once per
    question, and a UUID would cost more output tokens than the citation is
    worth. They are only meaningful within the one call they were built for,
    which is why the pipeline validates them against the context it passed.
    """
    return [
        ContextSnippet(
            id=f"S{i + 1}",
            title=row.title,
            summary=row.summary,
            url=row.url,
            source=row.source,
            published_at=row.published_at,
        )
        for i, row in enumerate(rows)
    ]


async def context_for(
    db: AsyncSession,
    *,
    queries: list[str],
    language: ContentLanguage = DEFAULT_LANGUAGE,
    category: Optional[str] = None,
    max_age_days: Optional[int] = None,
) -> RetrievedContext:
    """Corpus lookup packaged as generation grounding."""
    snippets = await search(
        db,
        queries=queries,
        language=language,
        category=category,
        max_age_days=max_age_days,
    )
    return RetrievedContext(snippets=snippets, query=" | ".join(queries or []))


async def corpus_size(db: AsyncSession, *, language: Optional[ContentLanguage] = None) -> int:
    stmt = select(func.count()).select_from(NewsDocument)
    if language is not None:
        stmt = stmt.where(NewsDocument.language == normalize_language(language).value)
    return int(await db.scalar(stmt) or 0)
