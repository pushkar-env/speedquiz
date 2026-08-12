"""Subscription state reconciliation.

The stores tell us what happened; this module decides what it means for a
player's access. Kept free of I/O so every branch is directly testable.

Two rules shape everything here:

* **Never take access away for a problem the store is still working on.** A
  failed renewal in India is usually an expired card mandate, not a churned
  user. The store retries for days; we keep serving until it gives up.
* **Take access away immediately on a refund.** A revoked purchase is money
  returned, and continuing to serve premium is a straight loss.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

from app.core.config import get_settings
from app.models import (
    ENTITLED_SUBSCRIPTION_STATUSES,
    Subscription,
    SubscriptionStatus,
)
from app.payments.store_types import StoreState, VerifiedSubscription

#: Store state → persisted status. One-to-one today, but the indirection keeps
#: store vocabulary out of the database.
_STATE_TO_STATUS = {
    StoreState.ACTIVE: SubscriptionStatus.ACTIVE,
    StoreState.GRACE: SubscriptionStatus.GRACE,
    StoreState.ON_HOLD: SubscriptionStatus.ON_HOLD,
    StoreState.PAUSED: SubscriptionStatus.PAUSED,
    StoreState.PENDING: SubscriptionStatus.PENDING,
    StoreState.CANCELLED: SubscriptionStatus.CANCELLED,
    StoreState.EXPIRED: SubscriptionStatus.EXPIRED,
    StoreState.REVOKED: SubscriptionStatus.REVOKED,
}


def status_for(state: StoreState) -> SubscriptionStatus:
    return _STATE_TO_STATUS.get(state, SubscriptionStatus.EXPIRED)


def effective_grace_until(verified: VerifiedSubscription) -> Optional[datetime]:
    """When premium should actually stop for a subscription in billing retry.

    Apple hands us an explicit `gracePeriodExpiresDate`; Play signals the grace
    period through its state without a deadline. When neither gives a date we
    grant a configured window past expiry so a retryable decline does not lock
    a paying user out mid-session.
    """
    if verified.grace_until is not None:
        return verified.grace_until
    if verified.state is not StoreState.GRACE:
        return None
    if verified.expires_at is None:
        return None
    days = max(0, get_settings().billing_grace_period_days)
    return verified.expires_at + timedelta(days=days)


def is_entitled(
    subscription: Subscription,
    *,
    now: Optional[datetime] = None,
) -> bool:
    """Does this row currently grant premium?

    Applied on read as well as on write, so a subscription that lapsed while
    nobody was looking stops granting access even if no webhook arrived.
    """
    moment = now or datetime.now(timezone.utc)

    if subscription.status not in ENTITLED_SUBSCRIPTION_STATUSES:
        return False
    if subscription.revoked_at is not None:
        return False

    # A sandbox purchase must never unlock a production deployment; otherwise
    # anyone with a test account gets premium for free.
    if subscription.is_test and get_settings().is_production:
        return False

    # No expiry on an active row means the retired lifetime unlock.
    if subscription.expires_at is None:
        return True

    deadline = subscription.expires_at
    if subscription.grace_until is not None and subscription.grace_until > deadline:
        deadline = subscription.grace_until

    return _as_utc(deadline) > moment


def _as_utc(value: datetime) -> datetime:
    """Treat naive timestamps as UTC.

    Rows written before timezone-aware columns landed, and SQLite in tests,
    both hand back naive datetimes; comparing one to an aware `now()` raises.
    """
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def any_entitled(
    subscriptions: Iterable[Subscription],
    *,
    now: Optional[datetime] = None,
) -> bool:
    return any(is_entitled(s, now=now) for s in subscriptions)


def best_subscription(
    subscriptions: Iterable[Subscription],
    *,
    now: Optional[datetime] = None,
) -> Optional[Subscription]:
    """The row the UI should describe.

    An entitled subscription always wins; among equals the one that runs
    longest, so a user who upgraded monthly → annual sees the annual plan.
    """
    moment = now or datetime.now(timezone.utc)
    rows = list(subscriptions)
    if not rows:
        return None

    def sort_key(sub: Subscription) -> tuple[int, float]:
        entitled = 1 if is_entitled(sub, now=moment) else 0
        if sub.expires_at is None:
            # Lifetime sorts above any dated subscription when entitled.
            horizon = float("inf") if entitled else float("-inf")
        else:
            horizon = _as_utc(sub.expires_at).timestamp()
        return entitled, horizon

    return max(rows, key=sort_key)


def refresh_status(
    subscription: Subscription,
    *,
    now: Optional[datetime] = None,
) -> bool:
    """Lazily expire a row whose period has elapsed.

    Webhooks are the primary path, but they get dropped: Pub/Sub can fail
    delivery for hours and Apple retries a fixed number of times before giving
    up. Without this, a lapsed subscription would keep granting premium
    indefinitely. Returns True when the status changed.
    """
    moment = now or datetime.now(timezone.utc)

    if subscription.status not in ENTITLED_SUBSCRIPTION_STATUSES:
        return False
    if subscription.expires_at is None:
        return False

    deadline = _as_utc(subscription.expires_at)
    if subscription.grace_until is not None:
        grace = _as_utc(subscription.grace_until)
        if grace > deadline:
            deadline = grace

    if deadline > moment:
        return False

    subscription.status = SubscriptionStatus.EXPIRED
    return True


def apply_verified(
    subscription: Subscription,
    verified: VerifiedSubscription,
    *,
    now: Optional[datetime] = None,
) -> Subscription:
    """Copy store truth onto a subscription row."""
    moment = now or datetime.now(timezone.utc)

    subscription.platform = verified.platform
    subscription.product_id = verified.product_id or subscription.product_id
    subscription.plan_code = verified.plan_code or subscription.plan_code
    subscription.status = status_for(verified.state)

    if verified.original_transaction_id:
        subscription.original_transaction_id = verified.original_transaction_id
    if verified.latest_transaction_id:
        subscription.latest_transaction_id = verified.latest_transaction_id
    if verified.purchase_token:
        subscription.purchase_token = verified.purchase_token

    subscription.started_at = verified.started_at or subscription.started_at
    subscription.current_period_start = (
        verified.current_period_start or subscription.current_period_start
    )
    subscription.expires_at = verified.expires_at
    subscription.grace_until = effective_grace_until(verified)
    subscription.auto_resume_at = verified.auto_resume_at
    subscription.auto_renewing = verified.auto_renewing
    subscription.cancel_reason = verified.cancel_reason

    if verified.state is StoreState.REVOKED:
        subscription.revoked_at = verified.revoked_at or moment
    else:
        subscription.revoked_at = None

    if verified.state is StoreState.CANCELLED:
        subscription.cancelled_at = (
            verified.cancelled_at or subscription.cancelled_at or moment
        )
    elif verified.auto_renewing:
        # Resubscribed / auto-renew turned back on.
        subscription.cancelled_at = None

    subscription.is_intro_offer = verified.is_intro_offer
    subscription.offer_id = verified.offer_id
    subscription.country = verified.country or subscription.country
    subscription.currency = verified.currency or subscription.currency
    subscription.price_micros = verified.price_micros or subscription.price_micros
    subscription.environment = verified.environment
    subscription.is_test = verified.is_test
    subscription.last_verified_at = moment
    subscription.raw = verified.raw or {}
    subscription.entitlements = {
        "premium": is_entitled(subscription, now=moment),
        "plan": subscription.plan_code,
        "state": subscription.status.value,
    }
    return subscription


@dataclass(frozen=True)
class EntitlementSnapshot:
    """Everything the client needs to render subscription state."""

    is_premium: bool
    plan_code: Optional[str] = None
    product_id: Optional[str] = None
    platform: Optional[str] = None
    status: SubscriptionStatus = SubscriptionStatus.NONE
    expires_at: Optional[datetime] = None
    grace_until: Optional[datetime] = None
    auto_renewing: bool = False
    is_intro_offer: bool = False
    will_renew: bool = False
    #: True when the store needs the user to fix a payment method.
    needs_payment_fix: bool = False
    #: True while a UPI / net-banking / Ask-to-Buy purchase settles.
    is_pending: bool = False


def snapshot(
    subscriptions: Iterable[Subscription],
    *,
    now: Optional[datetime] = None,
) -> EntitlementSnapshot:
    """Summarise a user's subscriptions for the API layer."""
    moment = now or datetime.now(timezone.utc)
    rows = list(subscriptions)
    best = best_subscription(rows, now=moment)

    if best is None:
        return EntitlementSnapshot(is_premium=False)

    entitled = is_entitled(best, now=moment)
    return EntitlementSnapshot(
        is_premium=entitled,
        plan_code=best.plan_code,
        product_id=best.product_id,
        platform=best.platform,
        status=best.status,
        expires_at=best.expires_at,
        grace_until=best.grace_until,
        auto_renewing=bool(best.auto_renewing),
        is_intro_offer=bool(best.is_intro_offer),
        will_renew=entitled and bool(best.auto_renewing),
        needs_payment_fix=best.status
        in {SubscriptionStatus.GRACE, SubscriptionStatus.ON_HOLD},
        is_pending=any(s.status is SubscriptionStatus.PENDING for s in rows),
    )
