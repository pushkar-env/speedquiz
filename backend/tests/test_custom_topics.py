"""Custom topic helpers (quota / cache key)."""

from datetime import datetime, timezone

from app.core.freshness import Temporality, freshness_bucket
from app.core.languages import ContentLanguage
from app.models import DifficultyLabel
from app.services.custom_topics import cache_key_for

NOW = datetime(2026, 8, 13, 12, 0, tzinfo=timezone.utc)


def test_cache_key_stable_and_case_insensitive():
    a = cache_key_for("Elden Ring lore", DifficultyLabel.MEDIUM, None)
    b = cache_key_for("elden ring lore", DifficultyLabel.MEDIUM, "  ")
    c = cache_key_for("elden ring lore", DifficultyLabel.HARD, None)
    assert a == b
    assert a != c


def test_cache_key_includes_style():
    a = cache_key_for("Space", DifficultyLabel.MEDIUM, "trivia")
    b = cache_key_for("Space", DifficultyLabel.MEDIUM, "lore")
    assert a != b


def test_settled_topics_hash_exactly_as_they_did_before_freshness_existed():
    """Static topics get an empty bucket, so their keys are byte-identical to
    the pre-freshness ones. The reuse that makes custom topics nearly free has
    to survive this feature untouched."""
    bucket = freshness_bucket(Temporality.STATIC, now=NOW)
    assert bucket == ""
    with_bucket = cache_key_for("The Mughal Empire", DifficultyLabel.MEDIUM, None, bucket=bucket)
    without = cache_key_for("The Mughal Empire", DifficultyLabel.MEDIUM, None)
    assert with_bucket == without


def test_a_news_topic_stops_being_answered_from_yesterdays_cache():
    """The bug this closes: a cache hit is quota-exempt, so before bucketing
    the stalest possible answer was also the cheapest one to serve."""
    today = cache_key_for(
        "current affairs this week",
        DifficultyLabel.MEDIUM,
        None,
        bucket=freshness_bucket(Temporality.CURRENT, now=NOW),
    )
    tomorrow = cache_key_for(
        "current affairs this week",
        DifficultyLabel.MEDIUM,
        None,
        bucket=freshness_bucket(Temporality.CURRENT, now=NOW.replace(day=14)),
    )
    assert today != tomorrow


def test_a_news_topic_is_still_reused_within_the_same_day():
    """Bucketing must not disable caching outright — two players asking the
    same thing an hour apart still share one generation."""
    bucket = freshness_bucket(Temporality.CURRENT, now=NOW)
    morning = cache_key_for("today's headlines", DifficultyLabel.MEDIUM, None, bucket=bucket)
    evening = cache_key_for(
        "today's headlines",
        DifficultyLabel.MEDIUM,
        None,
        bucket=freshness_bucket(Temporality.CURRENT, now=NOW.replace(hour=23)),
    )
    assert morning == evening


def test_evolving_topics_are_reused_across_a_week_but_not_beyond():
    def key(moment):
        return cache_key_for(
            "IPL season",
            DifficultyLabel.MEDIUM,
            None,
            bucket=freshness_bucket(Temporality.EVOLVING, now=moment),
        )

    assert key(NOW) == key(NOW.replace(day=15))  # same ISO week
    assert key(NOW) != key(NOW.replace(day=25))  # a fortnight later


def test_language_still_separates_banks_once_a_bucket_is_present():
    bucket = freshness_bucket(Temporality.CURRENT, now=NOW)
    english = cache_key_for("news", DifficultyLabel.MEDIUM, None, ContentLanguage.ENGLISH, bucket)
    hindi = cache_key_for("news", DifficultyLabel.MEDIUM, None, ContentLanguage.HINDI, bucket)
    assert english != hindi
