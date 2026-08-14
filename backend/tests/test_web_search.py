"""Gates on the paid search path (no network).

Every test here is about *not* spending money. The search path costs roughly
five times the LLM batch it feeds, so each gate is asserted independently —
a regression that opens any one of them is a bill, not a bug report.
"""

import pytest

from app.ai import web_search
from app.ai.web_search import _budget_key, _claim_budget, _entitled, search_is_available
from app.models import User


class _FakeRedis:
    def __init__(self, *, start: int = 0, raises: bool = False):
        self.counter = start
        self.raises = raises
        self.expired: list[str] = []

    async def incr(self, key):
        if self.raises:
            raise ConnectionError("redis down")
        self.counter += 1
        return self.counter

    async def expire(self, key, ttl):
        self.expired.append(key)


def _use_redis(monkeypatch, redis):
    async def _get():
        if getattr(redis, "raises", False):
            raise ConnectionError("redis down")
        return redis

    monkeypatch.setattr(web_search, "get_redis", _get)


def _configure(monkeypatch, **values):
    for key, value in values.items():
        monkeypatch.setattr(web_search.settings, key, value)


# --- gate 1: configured ------------------------------------------------------


def test_search_is_off_by_default(monkeypatch):
    _configure(monkeypatch, search_provider="none", search_api_key="")
    assert search_is_available() is False


def test_a_provider_without_a_key_is_not_available(monkeypatch):
    _configure(monkeypatch, search_provider="exa", search_api_key="")
    assert search_is_available() is False


def test_an_unknown_provider_is_not_available(monkeypatch):
    _configure(monkeypatch, search_provider="google", search_api_key="k")
    assert search_is_available() is False


@pytest.mark.parametrize("provider", ["exa", "tavily"])
def test_a_configured_provider_is_available(monkeypatch, provider):
    _configure(monkeypatch, search_provider=provider, search_api_key="k")
    assert search_is_available() is True


# --- gate 2: entitlement -----------------------------------------------------


def test_anonymous_callers_cannot_trigger_a_paid_search(monkeypatch):
    _configure(monkeypatch, search_premium_only=True)
    assert _entitled(None) is False


def test_free_users_cannot_trigger_a_paid_search(monkeypatch):
    _configure(monkeypatch, search_premium_only=True)
    assert _entitled(User(is_premium=False)) is False


def test_premium_users_can(monkeypatch):
    _configure(monkeypatch, search_premium_only=True)
    assert _entitled(User(is_premium=True)) is True


def test_the_premium_gate_can_be_opened_deliberately(monkeypatch):
    _configure(monkeypatch, search_premium_only=False)
    assert _entitled(None) is True


# --- gate 3: budget ----------------------------------------------------------


@pytest.mark.asyncio
async def test_a_zero_budget_blocks_every_search(monkeypatch):
    _configure(monkeypatch, search_daily_budget=0)
    assert await _claim_budget() is False


@pytest.mark.asyncio
async def test_claims_succeed_up_to_the_budget_then_stop(monkeypatch):
    _configure(monkeypatch, search_daily_budget=3)
    _use_redis(monkeypatch, _FakeRedis())
    assert [await _claim_budget() for _ in range(5)] == [True, True, True, False, False]


@pytest.mark.asyncio
async def test_the_first_claim_of_the_day_sets_an_expiry(monkeypatch):
    _configure(monkeypatch, search_daily_budget=5)
    redis = _FakeRedis()
    _use_redis(monkeypatch, redis)
    await _claim_budget()
    await _claim_budget()
    # Only the first claim arms the TTL; re-arming on every claim would let a
    # busy day push the counter's expiry indefinitely into the future.
    assert len(redis.expired) == 1


@pytest.mark.asyncio
async def test_budget_fails_closed_when_redis_is_unreachable(monkeypatch):
    """An unmeasurable budget is not an unlimited one."""
    _configure(monkeypatch, search_daily_budget=100)
    _use_redis(monkeypatch, _FakeRedis(raises=True))
    assert await _claim_budget() is False


def test_the_budget_key_rolls_daily():
    from datetime import datetime, timezone

    a = _budget_key(datetime(2026, 8, 13, 23, 59, tzinfo=timezone.utc))
    b = _budget_key(datetime(2026, 8, 14, 0, 1, tzinfo=timezone.utc))
    assert a != b and a.endswith("2026-08-13")


# --- the gates in combination ------------------------------------------------


@pytest.mark.asyncio
async def test_no_search_is_attempted_when_the_provider_is_off(monkeypatch):
    _configure(monkeypatch, search_provider="none", search_api_key="")
    context = await web_search.search_provider_context(None, queries=["anything"])
    assert not context


@pytest.mark.asyncio
async def test_no_search_is_attempted_for_an_unentitled_user(monkeypatch):
    _configure(
        monkeypatch,
        search_provider="exa",
        search_api_key="k",
        search_premium_only=True,
        search_daily_budget=100,
    )
    # A redis that would happily grant budget — the entitlement gate must stop
    # this before the budget is even consulted.
    redis = _FakeRedis()
    _use_redis(monkeypatch, redis)
    context = await web_search.search_provider_context(
        None, queries=["artemis crew"], user=User(is_premium=False)
    )
    assert not context
    assert redis.counter == 0


@pytest.mark.asyncio
async def test_an_empty_query_never_spends_budget(monkeypatch):
    _configure(
        monkeypatch,
        search_provider="exa",
        search_api_key="k",
        search_premium_only=False,
        search_daily_budget=100,
    )
    redis = _FakeRedis()
    _use_redis(monkeypatch, redis)
    assert not await web_search.search_provider_context(None, queries=["", "  "])
    assert redis.counter == 0
