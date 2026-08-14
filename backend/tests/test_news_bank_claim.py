"""The daily-build claim: exactly once a day, but not stuck on a bad day."""

from datetime import datetime, timezone

import pytest

from app.services import news_banks

NOW = datetime(2026, 8, 14, 3, 0, tzinfo=timezone.utc)


class _FakeRedis:
    def __init__(self, *, raises: bool = False):
        self.store: dict[str, str] = {}
        self.ttl: dict[str, int] = {}
        self.raises = raises

    async def set(self, key, value, nx=False, ex=None):
        if self.raises:
            raise ConnectionError("redis down")
        if nx and key in self.store:
            return None
        self.store[key] = value
        if ex is not None:
            self.ttl[key] = ex
        return True


def _use(monkeypatch, redis):
    async def _get():
        if redis.raises:
            raise ConnectionError("redis down")
        return redis

    monkeypatch.setattr(news_banks, "get_redis", _get)


@pytest.mark.asyncio
async def test_only_the_first_caller_of_the_day_builds(monkeypatch):
    """Tick counting restarts with the process, so a worker redeploying twice
    in a morning would otherwise rebuild every bank twice and pay for it."""
    _use(monkeypatch, _FakeRedis())
    assert await news_banks.claim_daily_build(now=NOW) is True
    assert await news_banks.claim_daily_build(now=NOW) is False
    assert await news_banks.claim_daily_build(now=NOW) is False


@pytest.mark.asyncio
async def test_a_new_day_can_be_claimed_again(monkeypatch):
    _use(monkeypatch, _FakeRedis())
    assert await news_banks.claim_daily_build(now=NOW) is True
    tomorrow = NOW.replace(day=15)
    assert await news_banks.claim_daily_build(now=tomorrow) is True


@pytest.mark.asyncio
async def test_claim_fails_closed_when_redis_is_down(monkeypatch):
    """Skipping a rebuild costs one day of staleness on banks that carry their
    own expiry; double-building costs money every time."""
    _use(monkeypatch, _FakeRedis(raises=True))
    assert await news_banks.claim_daily_build(now=NOW) is False


@pytest.mark.asyncio
async def test_claim_holds_the_day_for_36_hours(monkeypatch):
    redis = _FakeRedis()
    _use(monkeypatch, redis)
    await news_banks.claim_daily_build(now=NOW)
    assert redis.ttl["news_banks_built:2026-08-14"] == 60 * 60 * 36


@pytest.mark.asyncio
async def test_deferring_shortens_the_claim_so_a_failure_retries(monkeypatch):
    """A build that produced nothing must not sit on the day for 36 hours."""
    redis = _FakeRedis()
    _use(monkeypatch, redis)
    await news_banks.claim_daily_build(now=NOW)
    await news_banks.defer_daily_build(minutes=60, now=NOW)
    assert redis.ttl["news_banks_built:2026-08-14"] == 3600


@pytest.mark.asyncio
async def test_deferring_keeps_the_key_so_the_next_tick_does_not_retry(monkeypatch):
    """A backoff, not a reset — deleting the key would let a sustained outage
    hammer the provider every few minutes."""
    redis = _FakeRedis()
    _use(monkeypatch, redis)
    await news_banks.claim_daily_build(now=NOW)
    await news_banks.defer_daily_build(now=NOW)
    assert "news_banks_built:2026-08-14" in redis.store
    assert await news_banks.claim_daily_build(now=NOW) is False


@pytest.mark.asyncio
async def test_defer_never_raises_when_redis_is_down(monkeypatch):
    """It runs in the worker's exception handler; throwing here would mask the
    build failure it is reacting to."""
    _use(monkeypatch, _FakeRedis(raises=True))
    await news_banks.defer_daily_build(now=NOW)


@pytest.mark.asyncio
async def test_refresh_all_is_a_noop_when_disabled(monkeypatch):
    monkeypatch.setattr(news_banks.settings, "daily_news_banks_enabled", False)
    assert await news_banks.refresh_all() == {}
