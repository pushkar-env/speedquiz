"""How long a fact stays true, and how long a generated bank stays reusable.

Two separate axes, deliberately not merged:

``Temporality``
    A property of the *request*. "Quiz me on the Mughal Empire" is ``static``;
    "current affairs this week" is ``current``. It decides whether generation
    needs live grounding at all, and how long the generated bank may be reused
    for the *next* player who asks the same thing.

``Volatility``
    A property of one *question*. A bank generated from this week's news is
    mostly ``fast``, but "In which year was the RBI founded?" is ``static``
    even when it was written from today's front page. It decides when that one
    row stops being dealt.

Keeping them apart is what lets a news-sourced bank hold a mix: the durable
questions survive the sweep, only the perishable ones retire.

Why plain strings and not a Postgres ENUM
------------------------------------------
Same reasoning as ``app.core.languages``: adding ``live`` (sub-hour facts —
scores, markets) should be a deploy, not an ``ALTER TYPE`` on a table with
millions of rows. Values are validated here at the boundary instead.
"""

from __future__ import annotations

import enum
import re
from datetime import date, datetime, timedelta, timezone
from typing import Optional


class Temporality(str, enum.Enum):
    """How much a *topic* depends on facts that move."""

    #: Settled subjects. The model's training data is as good as a live source.
    STATIC = "static"
    #: Real but slow drift — a sports league, a franchise, an ongoing series.
    EVOLVING = "evolving"
    #: Needs live grounding to be correct at all.
    CURRENT = "current"


class Volatility(str, enum.Enum):
    """How fast one *question's* answer goes stale."""

    STATIC = "static"
    SLOW = "slow"
    FAST = "fast"


DEFAULT_TEMPORALITY = Temporality.STATIC
DEFAULT_VOLATILITY = Volatility.STATIC

#: How long a question of each volatility keeps being dealt. ``None`` means
#: forever, which is the behaviour every row had before this module existed —
#: so an unclassified question is unaffected by the sweep.
DEFAULT_TTL_DAYS: dict[Volatility, Optional[int]] = {
    Volatility.STATIC: None,
    Volatility.SLOW: 365,
    Volatility.FAST: 30,
}

#: Reuse window per temporality, in days, before a cache key rolls over.
#: ``STATIC`` is absent on purpose — it never rolls.
_BASE_REUSE_DAYS: dict[Temporality, int] = {
    Temporality.CURRENT: 1,
    Temporality.EVOLVING: 7,
}


def normalize_temporality(raw: object, *, default: Temporality = DEFAULT_TEMPORALITY) -> Temporality:
    """Parse anything an LLM, column or job payload offers into a Temporality.

    Never raises: a model that answers "very current" instead of one of the
    three values should degrade to the safe default, not 500 a request.
    """
    if isinstance(raw, Temporality):
        return raw
    if raw is None:
        return default
    text = str(raw).strip().lower()
    try:
        return Temporality(text)
    except ValueError:
        return default


def normalize_volatility(raw: object, *, default: Volatility = DEFAULT_VOLATILITY) -> Volatility:
    """Parse anything into a Volatility. Never raises — see above."""
    if isinstance(raw, Volatility):
        return raw
    if raw is None:
        return default
    text = str(raw).strip().lower()
    try:
        return Volatility(text)
    except ValueError:
        return default


def volatility_for_temporality(temporality: Temporality) -> Volatility:
    """The volatility a question inherits when the model does not label it.

    Deliberately pessimistic for time-sensitive topics: an unlabelled question
    from a ``current`` batch expires, because the cost of retiring a durable
    question early is one regeneration, and the cost of keeping a stale one is
    a player being told something false.
    """
    if temporality is Temporality.CURRENT:
        return Volatility.FAST
    if temporality is Temporality.EVOLVING:
        return Volatility.SLOW
    return Volatility.STATIC


def _settings_ttl_table() -> dict[Volatility, Optional[int]]:
    """TTLs as configured for this deployment.

    Imported lazily: ``app.core.config`` is cheap but this module is imported
    by ``app.models``, and a module-level import there would put settings
    resolution ahead of table definition on every process start.
    """
    from app.core.config import get_settings

    settings = get_settings()
    return {
        Volatility.STATIC: None,
        Volatility.SLOW: settings.question_ttl_slow_days,
        Volatility.FAST: settings.question_ttl_fast_days,
    }


def ttl_days_for(
    volatility: Volatility,
    *,
    overrides: Optional[dict[Volatility, Optional[int]]] = None,
) -> Optional[int]:
    table = overrides if overrides is not None else _settings_ttl_table()
    return table.get(volatility, DEFAULT_TTL_DAYS.get(volatility))


def expires_at_for(
    volatility: Volatility,
    *,
    valid_as_of: Optional[datetime] = None,
    ttl_days: Optional[int] = None,
) -> Optional[datetime]:
    """When a question of this volatility should stop being dealt.

    ``None`` means never. ``valid_as_of`` anchors the clock to when the fact
    was actually checked rather than to now, so a question generated from a
    three-week-old article does not get a fresh 30 days.
    """
    days = ttl_days if ttl_days is not None else ttl_days_for(volatility)
    if days is None:
        return None
    anchor = valid_as_of or datetime.now(timezone.utc)
    if anchor.tzinfo is None:
        anchor = anchor.replace(tzinfo=timezone.utc)
    return anchor + timedelta(days=days)


def freshness_bucket(
    temporality: Temporality,
    *,
    recency_window_days: Optional[int] = None,
    now: Optional[datetime] = None,
) -> str:
    """A cache-key component that rolls over as fast as the topic changes.

    Empty string for static topics, so their keys are byte-identical to what
    they hashed to before this existed — the 80% case keeps caching forever and
    keeps costing nothing.

    ``recency_window_days`` may only *tighten* the bucket, never loosen it. A
    model claiming a 365-day window on a topic it also called ``current`` is
    reaching past what it can know; the topic's own base window wins.
    """
    if temporality is Temporality.STATIC:
        return ""

    moment = now or datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)

    base = _BASE_REUSE_DAYS.get(temporality, 1)
    window = base if not recency_window_days else min(base, max(1, int(recency_window_days)))

    if window <= 1:
        return moment.strftime("%Y-%m-%d")
    if window <= 7:
        iso = moment.isocalendar()
        return f"{iso.year}-W{iso.week:02d}"
    return moment.strftime("%Y-%m")


#: Words that make a prompt time-sensitive beyond argument, in both content
#: languages. Deliberately narrow — this list exists to *escalate* a topic the
#: model called settled, never to demote one it called current, so a miss here
#: costs nothing while a false positive costs a retrieval.
#:
#: Hindi entries are matched on the Devanagari itself. Transliterations
#: ("taaza", "abhi") are absent on purpose: players typing Hinglish get the
#: model's judgement, and adding romanised stems would collide with English
#: words in other topics.
_CURRENT_TERMS = (
    # English
    r"current(?:ly)?",
    r"latest",
    r"recent(?:ly)?",
    r"today(?:'?s)?",
    r"yesterday(?:'?s)?",
    r"this (?:week|month|year|season)",
    r"past (?:week|month|few days)",
    r"right now",
    r"as of now",
    r"up[- ]?to[- ]?date",
    r"newest",
    r"breaking",
    r"news",
    r"headlines?",
    r"current affairs",
    r"present[- ]day",
    r"ongoing",
    r"who is the (?:current|present|new)",
    # Hindi
    r"वर्तमान",
    r"ताज़ा",
    r"ताजा",
    r"हाल ही",
    r"आज",
    r"अभी",
    r"नवीनतम",
    r"समाचार",
    r"खबर",
    r"सुर्खियां",
    r"चालू",
)

_CURRENT_PATTERN = re.compile(
    r"(?:^|\W)(?:" + "|".join(_CURRENT_TERMS) + r")(?:\W|$)",
    re.IGNORECASE | re.UNICODE,
)

#: A four-digit year in the prompt. Only years at or past the present one are a
#: freshness signal — "1947 partition" is settled history, "2026 season" is not.
_YEAR_PATTERN = re.compile(r"\b(19|20)\d{2}\b")


def temporal_hint(prompt: str, *, now: Optional[datetime] = None) -> Optional[Temporality]:
    """Deterministic ``CURRENT`` detection, or ``None`` for "ask the model".

    A regex cannot tell ``STATIC`` from ``EVOLVING`` — that judgement needs to
    know what the subject *is* — so this only answers the question it can
    actually answer, and returns ``None`` the rest of the time.

    Its purpose is to be a floor under the classifier. The model occasionally
    calls "latest iPhone" a settled topic; it is not allowed to, and this is
    what overrules it.
    """
    text = (prompt or "").strip()
    if not text:
        return None

    if _CURRENT_PATTERN.search(text):
        return Temporality.CURRENT

    moment = now or datetime.now(timezone.utc)
    for match in _YEAR_PATTERN.finditer(text):
        if int(match.group(0)) >= moment.year:
            return Temporality.CURRENT
    return None


def resolve_temporality(
    prompt: str,
    model_answer: object,
    *,
    now: Optional[datetime] = None,
) -> Temporality:
    """Combine the model's classification with the deterministic hint.

    The hint may only escalate. A false positive costs one retrieval that was
    not strictly needed; a false negative serves a player a fact that stopped
    being true. Those are not symmetric, so neither is this rule.
    """
    classified = normalize_temporality(model_answer)
    hint = temporal_hint(prompt, now=now)
    if hint is Temporality.CURRENT:
        return Temporality.CURRENT
    return classified


def as_of_date(value: object) -> Optional[datetime]:
    """Parse an ``as_of_date`` an LLM returned, or a stored value.

    Accepts a datetime, a date, or an ISO-8601 string with or without a time
    part and with a trailing ``Z``. Anything else is ``None`` rather than an
    exception — a malformed date must not fail a whole generation batch, and a
    ``None`` here simply means the pipeline anchors the TTL to now instead.
    """
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, date):
        return datetime(value.year, value.month, value.day, tzinfo=timezone.utc)
    text = str(value).strip()
    if not text:
        return None
    if text.endswith(("Z", "z")):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
