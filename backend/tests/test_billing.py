"""Purchase verification, account linking and entitlement refresh."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.models import Subscription, SubscriptionStatus, User
from app.payments.billing import (
    refresh_premium_flag,
    revoke_subscription,
    verify_and_grant,
)
from app.payments.store_types import StoreState, VerifiedSubscription
from tests.fakes import FakeSession

MONTHLY = "speedquiz_premium_monthly"
ANNUAL = "speedquiz_premium_annual"
NOW = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)


def _user(*, premium: bool = False, guest: bool = False, user_id=None) -> User:
    return User(
        id=user_id or uuid4(),
        is_premium=premium,
        is_guest=guest,
        is_active=True,
    )


def _sub(user_id, **overrides) -> Subscription:
    values = {
        "id": uuid4(),
        "user_id": user_id,
        "platform": "android",
        "product_id": MONTHLY,
        "plan_code": "monthly",
        "store_subscription_id": "tok_1",
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


def _settings(**overrides):
    base = SimpleNamespace(
        is_production=False,
        billing_verify_mode="stub",
        billing_allow_stub_in_production=False,
        billing_grace_period_days=3,
        iap_premium_product_id="speedquiz_premium",
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


def _patched(settings):
    """Patch every module that reads settings during a grant."""
    return (
        patch("app.payments.billing.get_settings", return_value=settings),
        patch("app.payments.state.get_settings", return_value=settings),
    )


async def _grant(db, user, *, settings=None, **kwargs):
    settings = settings or _settings()
    billing_patch, state_patch = _patched(settings)
    with billing_patch, state_patch:
        return await verify_and_grant(db, user, **kwargs)


# --- stub mode -------------------------------------------------------------


@pytest.mark.asyncio
async def test_stub_verify_creates_subscription_and_grants_premium():
    user = _user()
    # No Subscription rows yet, so the identity lookup misses and a new row
    # is created; refresh_premium_flag then sees it via scalars().
    db = FakeSession([user])

    sub = await _grant(
        db,
        user,
        platform="android",
        product_id=MONTHLY,
        purchase_token="tok_abc",
        original_transaction_id="txn_1",
    )

    assert sub.status is SubscriptionStatus.ACTIVE
    assert sub.plan_code == "monthly"
    assert sub.store_subscription_id == "txn_1"
    assert user.is_premium is True


@pytest.mark.asyncio
async def test_stub_verify_is_idempotent_for_the_same_transaction():
    user = _user()
    existing = _sub(user.id, store_subscription_id="txn_same", status=SubscriptionStatus.EXPIRED)
    db = FakeSession([existing, user])

    sub = await _grant(
        db,
        user,
        platform="android",
        product_id=MONTHLY,
        purchase_token="tok",
        original_transaction_id="txn_same",
    )

    assert sub is existing
    # Re-verifying the same transaction must reuse the row, never duplicate it.
    assert [r for r in db.added if isinstance(r, Subscription)] == []
    assert existing.status is SubscriptionStatus.ACTIVE


@pytest.mark.asyncio
async def test_annual_plan_is_recognised():
    user = _user()
    db = FakeSession([user])

    sub = await _grant(
        db,
        user,
        platform="ios",
        product_id=ANNUAL,
        purchase_token="tok",
        original_transaction_id="txn_annual",
    )
    assert sub.plan_code == "annual"
    assert sub.platform == "ios"


@pytest.mark.asyncio
async def test_unknown_product_rejected():
    db = FakeSession()
    with pytest.raises(HTTPException) as exc:
        await _grant(
            db,
            _user(),
            platform="android",
            product_id="not_our_sku",
            purchase_token="tok",
        )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_empty_token_rejected():
    db = FakeSession()
    with pytest.raises(HTTPException) as exc:
        await _grant(
            db, _user(), platform="android", product_id=MONTHLY, purchase_token="   "
        )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_bad_platform_rejected():
    db = FakeSession()
    with pytest.raises(HTTPException) as exc:
        await _grant(
            db, _user(), platform="windows", product_id=MONTHLY, purchase_token="tok"
        )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_stub_refused_in_production():
    """Otherwise any client could mint premium with an arbitrary string."""
    db = FakeSession()
    with pytest.raises(HTTPException) as exc:
        await _grant(
            db,
            _user(),
            settings=_settings(is_production=True),
            platform="ios",
            product_id=MONTHLY,
            purchase_token="tok",
        )
    assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_stub_actually_grants_when_allowed_in_production():
    """A staging box runs APP_ENV=production with stub billing switched on.

    The sandbox guard exists to stop a *store* sandbox transaction unlocking
    production; applying it to a stub the operator deliberately enabled made
    verification return 200 and grant nothing — a silent no-op.
    """
    user = _user()
    db = FakeSession([user])

    sub = await _grant(
        db,
        user,
        settings=_settings(
            is_production=True, billing_allow_stub_in_production=True
        ),
        platform="android",
        product_id=MONTHLY,
        purchase_token="stub_tok",
        original_transaction_id="stub_tok",
    )

    assert sub.status is SubscriptionStatus.ACTIVE
    assert sub.is_test is False
    assert user.is_premium is True


@pytest.mark.asyncio
async def test_stub_stays_marked_test_outside_production():
    user = _user()
    db = FakeSession([user])

    sub = await _grant(
        db,
        user,
        platform="android",
        product_id=MONTHLY,
        purchase_token="stub_tok",
        original_transaction_id="stub_tok",
    )

    assert sub.is_test is True
    assert user.is_premium is True


# --- store mode ------------------------------------------------------------


def _verified(**overrides) -> VerifiedSubscription:
    values = {
        "platform": "android",
        "product_id": ANNUAL,
        "plan_code": "annual",
        "store_subscription_id": "store_tok",
        "state": StoreState.ACTIVE,
        "expires_at": NOW + timedelta(days=365),
        "country": "IN",
        "environment": "Production",
    }
    values.update(overrides)
    return VerifiedSubscription(**values)


@pytest.mark.asyncio
async def test_store_mode_persists_verified_state():
    user = _user()
    db = FakeSession([user])
    settings = _settings(billing_verify_mode="apple_google")

    billing_patch, state_patch = _patched(settings)
    with (
        billing_patch,
        state_patch,
        patch(
            "app.payments.billing.verify_google_purchase",
            new=AsyncMock(return_value=_verified()),
        ),
    ):
        sub = await verify_and_grant(
            db,
            user,
            platform="android",
            product_id=ANNUAL,
            purchase_token="play_tok",
        )

    assert sub.status is SubscriptionStatus.ACTIVE
    assert sub.country == "IN"
    assert user.is_premium is True


@pytest.mark.asyncio
async def test_sandbox_purchase_refused_in_production():
    user = _user()
    db = FakeSession([user])
    settings = _settings(billing_verify_mode="apple_google", is_production=True)

    billing_patch, state_patch = _patched(settings)
    with (
        billing_patch,
        state_patch,
        patch(
            "app.payments.billing.verify_apple_purchase",
            new=AsyncMock(return_value=_verified(platform="ios", is_test=True)),
        ),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_and_grant(
                db, user, platform="ios", product_id=ANNUAL, purchase_token="tok"
            )
    assert exc.value.status_code == 402


@pytest.mark.asyncio
async def test_play_purchase_is_acknowledged():
    """Play auto-refunds anything not acknowledged within three days."""
    user = _user()
    db = FakeSession([user])
    settings = _settings(billing_verify_mode="apple_google")
    acknowledge = AsyncMock(return_value=True)

    billing_patch, state_patch = _patched(settings)
    with (
        billing_patch,
        state_patch,
        patch(
            "app.payments.billing.verify_google_purchase",
            new=AsyncMock(
                return_value=_verified(needs_acknowledgement=True, purchase_token="play_tok")
            ),
        ),
        patch("app.payments.billing.acknowledge_google_subscription", new=acknowledge),
    ):
        await verify_and_grant(
            db, user, platform="android", product_id=ANNUAL, purchase_token="play_tok"
        )

    acknowledge.assert_awaited_once()


@pytest.mark.asyncio
async def test_unknown_verify_mode_is_a_server_error():
    db = FakeSession()
    with pytest.raises(HTTPException) as exc:
        await _grant(
            db,
            _user(),
            settings=_settings(billing_verify_mode="carrier_pigeon"),
            platform="ios",
            product_id=MONTHLY,
            purchase_token="tok",
        )
    assert exc.value.status_code == 500


# --- account ownership -----------------------------------------------------


@pytest.mark.asyncio
async def test_guest_reinstall_transfers_the_subscription():
    """A guest who reinstalls gets a new account; the store purchase is the
    only identity they have, so refusing would strand a paying customer."""
    old_guest = _user(premium=True, guest=True)
    new_user = _user()
    existing = _sub(old_guest.id, store_subscription_id="txn_shared")
    db = FakeSession([existing, old_guest, new_user])
    db.scalar_results = [existing, old_guest]

    sub = await _grant(
        db,
        new_user,
        platform="android",
        product_id=MONTHLY,
        purchase_token="tok",
        original_transaction_id="txn_shared",
    )

    assert sub.user_id == new_user.id
    assert old_guest.is_premium is False


@pytest.mark.asyncio
async def test_signed_in_account_purchase_is_not_stolen():
    """Handing a signed-in user's subscription to whoever presents the token
    would let one device take over another person's purchase."""
    owner = _user(premium=True, guest=False)
    other = _user()
    existing = _sub(owner.id, store_subscription_id="txn_owned")
    db = FakeSession([existing, owner, other])
    db.scalar_results = [existing, owner]

    with pytest.raises(HTTPException) as exc:
        await _grant(
            db,
            other,
            platform="android",
            product_id=MONTHLY,
            purchase_token="tok",
            original_transaction_id="txn_owned",
        )

    assert exc.value.status_code == 409
    assert "Sign in" in str(exc.value.detail)
    assert existing.user_id == owner.id


# --- schema guards ---------------------------------------------------------


def test_store_identity_columns_hold_a_real_play_purchase_token():
    """Play purchase tokens run well past 255 characters.

    On Android the store identity *is* the purchase token, so a bounded String
    column would reject every real Play subscription at INSERT — a failure that
    only shows up against the live store, never in a stubbed test.
    """
    from sqlalchemy import String

    from app.models import BillingEvent

    for column in (
        Subscription.__table__.c.store_subscription_id,
        BillingEvent.__table__.c.store_subscription_id,
        Subscription.__table__.c.purchase_token,
    ):
        length = getattr(column.type, "length", None)
        assert not (
            isinstance(column.type, String) and length is not None and length <= 512
        ), f"{column.name} is too narrow for a Play purchase token"


# --- entitlement refresh ---------------------------------------------------


@pytest.mark.asyncio
async def test_refresh_premium_flag_expires_a_lapsed_subscription():
    """The safety net for a webhook that never arrived."""
    user = _user(premium=True)
    lapsed = _sub(user.id, expires_at=NOW - timedelta(days=1))
    db = FakeSession([lapsed])

    with patch("app.payments.state.get_settings", return_value=_settings()):
        entitled = await refresh_premium_flag(db, user, now=NOW)

    assert entitled is False
    assert user.is_premium is False
    assert lapsed.status is SubscriptionStatus.EXPIRED


@pytest.mark.asyncio
async def test_refresh_premium_flag_restores_premium_when_a_row_is_live():
    user = _user(premium=False)
    db = FakeSession([_sub(user.id)])

    with patch("app.payments.state.get_settings", return_value=_settings()):
        entitled = await refresh_premium_flag(db, user, now=NOW)

    assert entitled is True
    assert user.is_premium is True


@pytest.mark.asyncio
async def test_refresh_premium_flag_keeps_premium_if_any_row_is_live():
    """A user who switched plans can hold an expired row and a live one."""
    user = _user()
    db = FakeSession(
        [
            _sub(user.id, expires_at=NOW - timedelta(days=40), status=SubscriptionStatus.EXPIRED),
            _sub(user.id, plan_code="annual", expires_at=NOW + timedelta(days=300)),
        ]
    )
    with patch("app.payments.state.get_settings", return_value=_settings()):
        assert await refresh_premium_flag(db, user, now=NOW) is True


@pytest.mark.asyncio
async def test_revoke_pulls_premium_immediately():
    user = _user(premium=True)
    sub = _sub(user.id, expires_at=NOW + timedelta(days=200))
    db = FakeSession([sub, user])

    with patch("app.payments.state.get_settings", return_value=_settings()):
        await revoke_subscription(db, sub, reason="refund", now=NOW)

    assert sub.status is SubscriptionStatus.REVOKED
    assert sub.revoked_at == NOW
    assert user.is_premium is False
