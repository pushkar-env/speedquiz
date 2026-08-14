"""Pre-built news banks and the retrieval orchestrator (no DB, no network)."""

import pytest

from app.ai.retrieval import _fallback_queries, build_context
from app.core.freshness import Temporality
from app.core.languages import ContentLanguage, supported_languages
from app.services import news_banks, news_corpus


# --- topic specs -------------------------------------------------------------


def test_every_news_topic_maps_to_a_harvested_category():
    """A bank whose category no feed fills would silently never refresh."""
    assert {spec.category for spec in news_banks.NEWS_TOPICS} == set(news_corpus.CATEGORIES)


def test_every_category_has_at_least_one_feed():
    covered = {feed.category for feed in news_corpus.DEFAULT_FEEDS}
    for spec in news_banks.NEWS_TOPICS:
        assert spec.category in covered, f"no feed fills {spec.slug}"


def test_news_topic_slugs_are_unique_and_namespaced():
    slugs = [spec.slug for spec in news_banks.NEWS_TOPICS]
    assert len(slugs) == len(set(slugs))
    assert all(slug.startswith("news-") for slug in slugs)


def test_every_news_topic_is_named_in_every_supported_language():
    """The topic list is player-visible, so a missing translation would show an
    English title inside an otherwise Hindi catalog."""
    codes = {profile.code for profile in supported_languages()}
    assert codes == {"en", "hi"}
    for spec in news_banks.NEWS_TOPICS:
        assert spec.name.strip()
        assert spec.name_hi.strip()
        # Devanagari, not a romanised placeholder.
        assert any("ऀ" <= ch <= "ॿ" for ch in spec.name_hi)


# --- retrieval orchestration -------------------------------------------------


@pytest.mark.asyncio
async def test_settled_topics_never_touch_the_corpus():
    """Passing None for the session proves it: a static topic must short-circuit
    before any query. This is the branch most requests take, and it has to cost
    exactly what it cost before grounding existed."""
    context = await build_context(None, subject="The Mughal Empire", temporality=Temporality.STATIC)
    assert not context


@pytest.mark.asyncio
async def test_grounding_is_skipped_entirely_when_the_corpus_is_disabled(monkeypatch):
    monkeypatch.setattr("app.ai.retrieval.settings.news_corpus_enabled", False)
    context = await build_context(None, subject="today's news", temporality=Temporality.CURRENT)
    assert not context


@pytest.mark.asyncio
async def test_a_topic_with_no_searchable_subject_is_not_retrieved_for():
    context = await build_context(None, subject="   ", temporality=Temporality.CURRENT)
    assert not context


def test_classifier_queries_are_preferred_over_the_bare_subject():
    assert _fallback_queries("India news", ["monsoon session", "budget 2026"]) == [
        "monsoon session",
        "budget 2026",
    ]


def test_the_subject_is_the_fallback_when_the_classifier_offered_nothing():
    assert _fallback_queries("India news", None) == ["India news"]
    assert _fallback_queries("India news", ["", "  "]) == ["India news"]


def test_at_most_three_queries_are_ever_issued():
    """Each query widens the tsquery; an unbounded list from a model that
    misread the instruction would turn one lookup into a table scan."""
    many = [f"query {i}" for i in range(10)]
    assert len(_fallback_queries("subject", many)) == 3


# --- language configuration --------------------------------------------------


def test_hindi_uses_the_simple_text_search_config():
    """Postgres ships no Hindi stemmer, and `english` applied to Devanagari
    would tokenize but stem nonsense. Must match the generated column."""
    assert news_corpus._FTS_CONFIG[ContentLanguage.HINDI] == "simple"
    assert news_corpus._FTS_CONFIG[ContentLanguage.ENGLISH] == "english"
