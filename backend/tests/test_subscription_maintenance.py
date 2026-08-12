"""The periodic backstop for store notifications that never arrived."""

from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

import pytest

from app.models import Subscription, SubscriptionStatus, User
from app.payments.maintenance import expire_lapsed_subscriptions
from tests.fakes import FakeSession

NOW = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)


def _user(*, premium: bool = True) -> User:
    return User(id=uuid4(), is_premium=premium, is_guest=False, is_active=True)


def _sub(user_id, **overrides) -> Subscription:
    values = {
        "id": uuid4(),
        "user_id": user_id,
        "platform": "android",
        "product_id": "speedquiz_premium_monthly",
        "plan_code": "monthly",
        "store_subscription_id": str(uuid4()),
        "status": SubscriptionStatus.ACTIVE,
        "expires_at": NOW + timedelta(days=10),
        "grace_until": None,
        "revoked_at": None,
        "auto_renewing": True,
        "is_intro_offer": False,
        "is_test": False,
    }
    values.update(overrides)
    return Subscription(**values)


def _run_with(db: FakeSession):
    """Patch the sweep's session and the settings the resolver reads."""

    @asynccontextmanager
    async def _scope():
        yield db

    return (
        patch("app.payments.maintenance.session_scope", _scope),
        patch(
            "app.payments.state.get_settings",
            return_value=SimpleNamespace(
                is_production=False, billing_grace_period_days=3
            ),
        ),
    )


@pytest.mark.asyncio
async def test_sweep_expires_a_lapsed_subscription_and_clears_premium():
    user = _user(premium=True)
    lapsed = _sub(user.id, expires_at=NOW - timedelta(days=2))
    db = FakeSession([lapsed])
    db.scalar_results = [user]

    scope_patch, settings_patch = _run_with(db)
    with scope_patch, settings_patch:
        expired = await expire_lapsed_subscriptions(now=NOW)

    assert expired == 1
    assert lapsed.status is SubscriptionStatus.EXPIRED
    assert user.is_premium is False


@pytest.mark.asyncio
async def test_sweep_leaves_a_live_subscription_alone():
    user = _user()
    live = _sub(user.id)
    db = FakeSession([live])
    db.scalar_results = [user]

    scope_patch, settings_patch = _run_with(db)
    with scope_patch, settings_patch:
        expired = await expire_lapsed_subscriptions(now=NOW)

    assert expired == 0
    assert live.status is SubscriptionStatus.ACTIVE
    assert user.is_premium is True


@pytest.mark.asyncio
async def test_sweep_does_not_cut_off_a_subscription_still_in_grace():
    """The store is still retrying the payment — taking access away here is
    exactly the involuntary churn the grace period exists to prevent."""
    user = _user()
    in_grace = _sub(
        user.id,
        status=SubscriptionStatus.GRACE,
        expires_at=NOW - timedelta(days=1),
        grace_until=NOW + timedelta(days=2),
    )
    db = FakeSession([in_grace])
    db.scalar_results = [user]

    scope_patch, settings_patch = _run_with(db)
    with scope_patch, settings_patch:
        expired = await expire_lapsed_subscriptions(now=NOW)

    assert expired == 0
    assert in_grace.status is SubscriptionStatus.GRACE
    assert user.is_premium is True


@pytest.mark.asyncio
async def test_sweep_keeps_premium_when_another_subscription_is_still_live():
    """A user who switched plans holds an old row and a current one."""
    user = _user()
    old = _sub(user.id, expires_at=NOW - timedelta(days=5))
    current = _sub(user.id, plan_code="annual", expires_at=NOW + timedelta(days=300))
    db = FakeSession([old, current])
    db.scalar_results = [user]

    scope_patch, settings_patch = _run_with(db)
    with scope_patch, settings_patch:
        expired = await expire_lapsed_subscriptions(now=NOW)

    assert expired == 1
    assert old.status is SubscriptionStatus.EXPIRED
    assert current.status is SubscriptionStatus.ACTIVE
    assert user.is_premium is True


@pytest.mark.asyncio
async def test_sweep_is_a_no_op_when_nothing_has_lapsed():
    db = FakeSession([])
    scope_patch, settings_patch = _run_with(db)
    with scope_patch, settings_patch:
        assert await expire_lapsed_subscriptions(now=NOW) == 0
    assert db.flush_count == 0
