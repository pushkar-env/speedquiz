"""Freshness helpers: temporality, volatility, TTLs and cache buckets (no DB)."""

from datetime import datetime, timezone

import pytest

from app.core.freshness import (
    DEFAULT_TTL_DAYS,
    Temporality,
    Volatility,
    as_of_date,
    expires_at_for,
    freshness_bucket,
    normalize_temporality,
    normalize_volatility,
    resolve_temporality,
    temporal_hint,
    volatility_for_temporality,
)

NOW = datetime(2026, 8, 13, 12, 0, tzinfo=timezone.utc)


# --- parsing -----------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("current", Temporality.CURRENT),
        ("EVOLVING", Temporality.EVOLVING),
        (Temporality.STATIC, Temporality.STATIC),
        # Models answer this field with prose more often than you would like.
        ("very current", Temporality.STATIC),
        (None, Temporality.STATIC),
        ("", Temporality.STATIC),
    ],
)
def test_normalize_temporality_never_raises(raw, expected):
    assert normalize_temporality(raw) is expected


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("fast", Volatility.FAST),
        ("Slow", Volatility.SLOW),
        ("nonsense", Volatility.STATIC),
        (None, Volatility.STATIC),
    ],
)
def test_normalize_volatility_never_raises(raw, expected):
    assert normalize_volatility(raw) is expected


def test_unlabelled_current_question_is_treated_as_perishable():
    """Retiring a durable question early costs one regeneration; keeping a
    stale one costs a player being told something false."""
    assert volatility_for_temporality(Temporality.CURRENT) is Volatility.FAST
    assert volatility_for_temporality(Temporality.EVOLVING) is Volatility.SLOW
    assert volatility_for_temporality(Temporality.STATIC) is Volatility.STATIC


# --- expiry ------------------------------------------------------------------


def test_static_questions_never_expire():
    assert expires_at_for(Volatility.STATIC, valid_as_of=NOW) is None
    assert DEFAULT_TTL_DAYS[Volatility.STATIC] is None


def test_ttl_is_anchored_to_the_source_not_to_generation_time():
    """A question written today from a three-week-old article is three weeks
    old, and must not get a fresh full TTL."""
    stale_source = datetime(2026, 7, 23, tzinfo=timezone.utc)
    expiry = expires_at_for(Volatility.FAST, valid_as_of=stale_source, ttl_days=30)
    assert expiry == datetime(2026, 8, 22, tzinfo=timezone.utc)
    assert expiry < NOW.replace(day=30)


def test_naive_valid_as_of_is_treated_as_utc():
    expiry = expires_at_for(Volatility.FAST, valid_as_of=datetime(2026, 8, 1), ttl_days=10)
    assert expiry == datetime(2026, 8, 11, tzinfo=timezone.utc)


# --- cache bucketing ---------------------------------------------------------


def test_static_topics_keep_their_pre_freshness_cache_key():
    """The 80% case must keep caching forever — that reuse is what makes
    custom topics nearly free."""
    assert freshness_bucket(Temporality.STATIC, now=NOW) == ""


def test_current_topics_roll_daily_and_evolving_roll_weekly():
    assert freshness_bucket(Temporality.CURRENT, now=NOW) == "2026-08-13"
    assert freshness_bucket(Temporality.EVOLVING, now=NOW) == "2026-W33"


def test_bucket_rolls_over_between_days():
    tomorrow = NOW.replace(day=14)
    assert freshness_bucket(Temporality.CURRENT, now=NOW) != freshness_bucket(
        Temporality.CURRENT, now=tomorrow
    )


def test_recency_window_may_tighten_a_bucket_but_never_loosen_it():
    # A model claiming a year-long window on a weekly topic is reaching past
    # what it can know; the topic's own base window wins.
    assert (
        freshness_bucket(Temporality.EVOLVING, recency_window_days=365, now=NOW)
        == "2026-W33"
    )
    # Claiming a *tighter* window is allowed.
    assert (
        freshness_bucket(Temporality.EVOLVING, recency_window_days=1, now=NOW)
        == "2026-08-13"
    )


# --- the deterministic hint --------------------------------------------------


@pytest.mark.parametrize(
    "prompt",
    [
        "current affairs",
        "Latest iPhone features",
        "quiz me on this week's news",
        "Who is the current prime minister",
        "today's headlines",
        "recent scientific discoveries",
        # Hindi
        "वर्तमान समाचार",
        "आज की ताज़ा खबर",
        "हाल ही की घटनाएं",
    ],
)
def test_hint_catches_obviously_time_sensitive_prompts(prompt):
    assert temporal_hint(prompt, now=NOW) is Temporality.CURRENT


@pytest.mark.parametrize(
    "prompt",
    [
        "The Mughal Empire",
        "Photosynthesis",
        "1947 partition of India",
        "Bollywood films of the 1990s",
        "Newsroom drama series",  # 'news' must not match inside a longer word
        "मुगल साम्राज्य",
    ],
)
def test_hint_stays_quiet_on_settled_subjects(prompt):
    assert temporal_hint(prompt, now=NOW) is None


def test_only_present_or_future_years_are_a_freshness_signal():
    assert temporal_hint("2026 cricket season", now=NOW) is Temporality.CURRENT
    assert temporal_hint("2030 Olympics", now=NOW) is Temporality.CURRENT
    assert temporal_hint("2019 world cup", now=NOW) is None


def test_hint_escalates_a_model_that_called_a_news_topic_settled():
    assert (
        resolve_temporality("latest AI model releases", "static", now=NOW)
        is Temporality.CURRENT
    )


def test_hint_never_demotes_the_model():
    """The regex only knows CURRENT. It must not drag an EVOLVING topic it
    happens not to recognise back down to STATIC."""
    assert (
        resolve_temporality("Premier League standings", "evolving", now=NOW)
        is Temporality.EVOLVING
    )


def test_failed_classification_falls_back_to_the_hint():
    # The OpenAI fallback omits `temporality` on purpose, so a failed classify
    # of a news prompt must still come out CURRENT.
    assert resolve_temporality("today's news", None, now=NOW) is Temporality.CURRENT
    assert resolve_temporality("the Mughal Empire", None, now=NOW) is Temporality.STATIC


# --- as-of date parsing ------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("2026-08-13", datetime(2026, 8, 13, tzinfo=timezone.utc)),
        ("2026-08-13T09:30:00Z", datetime(2026, 8, 13, 9, 30, tzinfo=timezone.utc)),
        ("2026-08-13T09:30:00+00:00", datetime(2026, 8, 13, 9, 30, tzinfo=timezone.utc)),
    ],
)
def test_as_of_date_accepts_what_models_actually_return(raw, expected):
    assert as_of_date(raw) == expected


@pytest.mark.parametrize("raw", ["", None, "last Tuesday", "not a date"])
def test_malformed_as_of_date_is_none_not_an_exception(raw):
    """A bad date must not fail a whole generation batch — it just means the
    TTL anchors to now instead."""
    assert as_of_date(raw) is None
