"""Entitlement resolution: who gets premium, and until when."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from app.models import Subscription, SubscriptionStatus
from app.payments import state as sub_state
from app.payments.store_types import StoreState, VerifiedSubscription

NOW = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)


def _sub(**overrides) -> Subscription:
    """A subscription row with column defaults filled in.

    SQLAlchemy applies `default=` at INSERT, not construction, so an unset
    boolean would be None here and silently change what the resolver sees.
    """
    values = {
        "id": uuid4(),
        "user_id": uuid4(),
        "platform": "android",
        "product_id": "speedquiz_premium_monthly",
        "plan_code": "monthly",
        "store_subscription_id": "token_1",
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


def _not_production():
    return SimpleNamespace(is_production=False, billing_grace_period_days=3)


# --- is_entitled -----------------------------------------------------------


def test_active_within_period_is_entitled():
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(_sub(), now=NOW) is True


def test_active_past_expiry_is_not_entitled():
    row = _sub(expires_at=NOW - timedelta(minutes=1))
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is False


def test_cancelled_but_still_in_period_keeps_premium():
    """Both stores promise access through the period already paid for."""
    row = _sub(
        status=SubscriptionStatus.CANCELLED,
        auto_renewing=False,
        expires_at=NOW + timedelta(days=4),
    )
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is True


def test_grace_period_extends_past_expiry():
    """A failed renewal that the store is still retrying keeps access."""
    row = _sub(
        status=SubscriptionStatus.GRACE,
        expires_at=NOW - timedelta(days=1),
        grace_until=NOW + timedelta(days=2),
    )
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is True


def test_grace_expired_is_not_entitled():
    row = _sub(
        status=SubscriptionStatus.GRACE,
        expires_at=NOW - timedelta(days=5),
        grace_until=NOW - timedelta(hours=1),
    )
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is False


def test_on_hold_and_paused_are_not_entitled():
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        for status in (
            SubscriptionStatus.ON_HOLD,
            SubscriptionStatus.PAUSED,
            SubscriptionStatus.PENDING,
            SubscriptionStatus.EXPIRED,
            SubscriptionStatus.REVOKED,
        ):
            assert sub_state.is_entitled(_sub(status=status), now=NOW) is False


def test_revoked_at_beats_an_active_status():
    """A refund pulls access even if the period has not ended."""
    row = _sub(status=SubscriptionStatus.ACTIVE, revoked_at=NOW - timedelta(hours=2))
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is False


def test_lifetime_row_never_expires():
    row = _sub(plan_code="legacy_lifetime", expires_at=None, auto_renewing=False)
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is True


def test_sandbox_purchase_does_not_unlock_production():
    row = _sub(is_test=True)
    with patch(
        "app.payments.state.get_settings",
        return_value=SimpleNamespace(is_production=True, billing_grace_period_days=3),
    ):
        assert sub_state.is_entitled(row, now=NOW) is False
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is True


def test_naive_expiry_is_treated_as_utc():
    """Rows read back from a driver without tzinfo must not raise."""
    row = _sub(expires_at=(NOW + timedelta(days=1)).replace(tzinfo=None))
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        assert sub_state.is_entitled(row, now=NOW) is True


# --- refresh_status --------------------------------------------------------


def test_refresh_status_expires_a_lapsed_row():
    """The safety net for a webhook that never arrived."""
    row = _sub(expires_at=NOW - timedelta(days=1))
    assert sub_state.refresh_status(row, now=NOW) is True
    assert row.status is SubscriptionStatus.EXPIRED


def test_refresh_status_leaves_a_live_row_alone():
    row = _sub()
    assert sub_state.refresh_status(row, now=NOW) is False
    assert row.status is SubscriptionStatus.ACTIVE


def test_refresh_status_respects_grace():
    row = _sub(
        status=SubscriptionStatus.GRACE,
        expires_at=NOW - timedelta(days=1),
        grace_until=NOW + timedelta(days=1),
    )
    assert sub_state.refresh_status(row, now=NOW) is False
    assert row.status is SubscriptionStatus.GRACE


def test_refresh_status_never_resurrects_a_revoked_row():
    row = _sub(status=SubscriptionStatus.REVOKED, expires_at=NOW + timedelta(days=5))
    assert sub_state.refresh_status(row, now=NOW) is False
    assert row.status is SubscriptionStatus.REVOKED


# --- selection and snapshot ------------------------------------------------


def test_best_subscription_prefers_entitled_then_longest():
    lapsed = _sub(expires_at=NOW - timedelta(days=30), status=SubscriptionStatus.EXPIRED)
    short = _sub(expires_at=NOW + timedelta(days=5))
    long = _sub(plan_code="annual", expires_at=NOW + timedelta(days=300))

    with patch("app.payments.state.get_settings", return_value=_not_production()):
        best = sub_state.best_subscription([lapsed, short, long], now=NOW)
    assert best is long


def test_snapshot_flags_payment_problem_and_renewal():
    row = _sub(
        status=SubscriptionStatus.GRACE,
        expires_at=NOW - timedelta(hours=1),
        grace_until=NOW + timedelta(days=2),
    )
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        snap = sub_state.snapshot([row], now=NOW)

    assert snap.is_premium is True
    assert snap.needs_payment_fix is True
    assert snap.will_renew is True
    assert snap.plan_code == "monthly"


def test_snapshot_of_no_subscriptions_is_free():
    snap = sub_state.snapshot([], now=NOW)
    assert snap.is_premium is False
    assert snap.status is SubscriptionStatus.NONE
    assert snap.plan_code is None


def test_snapshot_reports_pending_purchase():
    """UPI and net banking can leave a purchase settling for hours."""
    row = _sub(status=SubscriptionStatus.PENDING, expires_at=None)
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        snap = sub_state.snapshot([row], now=NOW)
    assert snap.is_pending is True
    assert snap.is_premium is False


# --- grace fallback --------------------------------------------------------


def test_effective_grace_uses_store_date_when_given():
    verified = VerifiedSubscription(
        platform="ios",
        product_id="speedquiz_premium_annual",
        store_subscription_id="orig_1",
        state=StoreState.GRACE,
        expires_at=NOW,
        grace_until=NOW + timedelta(days=16),
    )
    assert sub_state.effective_grace_until(verified) == NOW + timedelta(days=16)


def test_effective_grace_falls_back_to_configured_window():
    """Play signals grace without a deadline, so we supply one."""
    verified = VerifiedSubscription(
        platform="android",
        product_id="speedquiz_premium_monthly",
        store_subscription_id="tok",
        state=StoreState.GRACE,
        expires_at=NOW,
    )
    with patch(
        "app.payments.state.get_settings",
        return_value=SimpleNamespace(is_production=False, billing_grace_period_days=3),
    ):
        assert sub_state.effective_grace_until(verified) == NOW + timedelta(days=3)


def test_effective_grace_is_none_when_not_in_grace():
    verified = VerifiedSubscription(
        platform="android",
        product_id="speedquiz_premium_monthly",
        store_subscription_id="tok",
        state=StoreState.ACTIVE,
        expires_at=NOW,
    )
    assert sub_state.effective_grace_until(verified) is None


# --- apply_verified --------------------------------------------------------


def test_apply_verified_copies_store_truth_onto_the_row():
    row = _sub(status=SubscriptionStatus.EXPIRED, auto_renewing=False)
    verified = VerifiedSubscription(
        platform="android",
        product_id="speedquiz_premium_annual",
        plan_code="annual",
        store_subscription_id="token_1",
        state=StoreState.ACTIVE,
        expires_at=NOW + timedelta(days=365),
        auto_renewing=True,
        country="IN",
        currency="INR",
        price_micros=399_000_000,
        latest_transaction_id="GPA.999",
    )

    with patch("app.payments.state.get_settings", return_value=_not_production()):
        sub_state.apply_verified(row, verified, now=NOW)

    assert row.status is SubscriptionStatus.ACTIVE
    assert row.plan_code == "annual"
    assert row.auto_renewing is True
    assert row.country == "IN"
    assert row.currency == "INR"
    assert row.latest_transaction_id == "GPA.999"
    assert row.entitlements["premium"] is True


def test_apply_verified_clears_revocation_on_resubscribe():
    row = _sub(status=SubscriptionStatus.REVOKED, revoked_at=NOW - timedelta(days=1))
    verified = VerifiedSubscription(
        platform="ios",
        product_id="speedquiz_premium_monthly",
        plan_code="monthly",
        store_subscription_id="orig",
        state=StoreState.ACTIVE,
        expires_at=NOW + timedelta(days=30),
    )
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        sub_state.apply_verified(row, verified, now=NOW)

    assert row.revoked_at is None
    assert row.status is SubscriptionStatus.ACTIVE


def test_apply_verified_records_revocation():
    row = _sub()
    verified = VerifiedSubscription(
        platform="ios",
        product_id="speedquiz_premium_monthly",
        plan_code="monthly",
        store_subscription_id="orig",
        state=StoreState.REVOKED,
        expires_at=NOW + timedelta(days=20),
    )
    with patch("app.payments.state.get_settings", return_value=_not_production()):
        sub_state.apply_verified(row, verified, now=NOW)

    assert row.status is SubscriptionStatus.REVOKED
    assert row.revoked_at == NOW
    assert row.entitlements["premium"] is False
