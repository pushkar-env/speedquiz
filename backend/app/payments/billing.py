"""Purchase verification and subscription persistence.

The client never decides whether someone is premium — it hands us a store
token and we ask the store. This module is the only place that writes to
`subscriptions`, so every grant, renewal, refund and transfer flows through
one audited path.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.logging import get_logger
from app.models import Subscription, SubscriptionStatus, User
from app.payments import state as sub_state
from app.payments.plans import PlanCode, plan_for_product
from app.payments.store_apple import verify_apple_purchase
from app.payments.store_google import (
    acknowledge_google_subscription,
    verify_google_purchase,
)
from app.payments.store_types import StoreState, VerifiedSubscription

logger = get_logger(__name__)


def _settings():
    # Read through rather than binding at import time so tests (and a running
    # process reading a changed env) see current values.
    return get_settings()


def _assert_known_product(product_id: str) -> None:
    if plan_for_product(product_id) is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown product_id {product_id!r}",
        )


def _assert_platform(platform: str) -> str:
    p = (platform or "").strip().lower()
    if p not in {"ios", "android"}:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="platform must be ios or android",
        )
    return p


async def _verify_with_store(
    *,
    platform: str,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str],
) -> VerifiedSubscription:
    if platform == "ios":
        return await verify_apple_purchase(
            product_id=product_id,
            purchase_token=purchase_token,
            original_transaction_id=original_transaction_id,
        )
    return await verify_google_purchase(
        product_id=product_id,
        purchase_token=purchase_token,
    )


def _stub_verification(
    *,
    platform: str,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str],
) -> VerifiedSubscription:
    """Synthesise a verified subscription for local development.

    Refused in production unless explicitly allowed, because it would let any
    client mint premium with an arbitrary string.
    """
    settings = _settings()
    if settings.is_production and not settings.billing_allow_stub_in_production:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Stub billing verification is disabled in production",
        )

    plan = plan_for_product(product_id)
    txn = (original_transaction_id or "").strip() or purchase_token.strip()
    now = datetime.now(timezone.utc)
    months = plan.months if plan else 1
    expires = None
    if plan is None or plan.is_subscription:
        # Approximate month length is fine for a dev fixture.
        expires = now + timedelta(days=months * 30)

    # The `is_test` flag exists to stop a *store* sandbox transaction unlocking
    # a production deployment. A stub row is not that — it only exists because
    # an operator turned stub mode on. Marking it test on a staging box running
    # APP_ENV=production would make verification return 200 and grant nothing,
    # which is a silent no-op rather than a safety feature.
    treat_as_test = not (
        settings.is_production and settings.billing_allow_stub_in_production
    )

    return VerifiedSubscription(
        platform=platform,
        product_id=product_id,
        plan_code=plan.code.value if plan else None,
        store_subscription_id=txn,
        state=StoreState.ACTIVE,
        original_transaction_id=txn,
        latest_transaction_id=txn,
        purchase_token=purchase_token,
        started_at=now,
        current_period_start=now,
        expires_at=expires,
        auto_renewing=bool(plan and plan.is_subscription),
        environment="Sandbox",
        is_test=treat_as_test,
        raw={"stub": True},
    )


async def _resolve_store_identity(
    db: AsyncSession,
    verified: VerifiedSubscription,
) -> tuple[str, Optional[Subscription]]:
    """Find the subscription row this purchase belongs to.

    On Play an upgrade or downgrade issues a brand-new purchase token and
    points `linkedPurchaseToken` at the old one. Following that chain is what
    keeps a monthly→annual switch as one subscription rather than two, which in
    turn keeps the user from appearing to hold two entitlements at once.
    """
    identity = verified.store_subscription_id

    if verified.linked_purchase_token:
        linked = await db.scalar(
            select(Subscription).where(
                Subscription.platform == verified.platform,
                Subscription.store_subscription_id == verified.linked_purchase_token,
            )
        )
        if linked is None:
            linked = await db.scalar(
                select(Subscription).where(
                    Subscription.platform == verified.platform,
                    Subscription.purchase_token == verified.linked_purchase_token,
                )
            )
        if linked is not None:
            # Keep the original identity so the chain stays stable across
            # repeated plan switches.
            return linked.store_subscription_id, linked

    existing = await db.scalar(
        select(Subscription).where(
            Subscription.platform == verified.platform,
            Subscription.store_subscription_id == identity,
        )
    )
    return identity, existing


async def _assert_ownership(
    db: AsyncSession,
    existing: Subscription,
    user: User,
) -> None:
    """Decide whether `user` may claim a subscription owned by someone else.

    A guest who reinstalls gets a brand-new account, so the store purchase is
    the strongest identity they have — refusing to transfer would strand a
    paying customer with no way back. A subscription attached to a *signed-in*
    account is different: handing it to whoever presents the token would let
    one device take over another person's purchase, so that case is refused
    and the user is told to sign in.
    """
    if existing.user_id == user.id:
        return

    previous = await db.scalar(select(User).where(User.id == existing.user_id))
    if previous is not None and not previous.is_guest:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                "This purchase belongs to another SpeedQuiz account. "
                "Sign in with that account to restore it."
            ),
        )

    logger.info(
        "subscription_transferred",
        subscription_id=str(existing.id),
        from_user_id=str(existing.user_id),
        to_user_id=str(user.id),
    )
    if previous is not None:
        previous.is_premium = False
    existing.user_id = user.id


async def refresh_premium_flag(
    db: AsyncSession,
    user: User,
    *,
    now: Optional[datetime] = None,
) -> bool:
    """Recompute `user.is_premium` from the subscription rows.

    `is_premium` is a denormalised cache read on nearly every request; the
    subscriptions table is the truth. Also lazily expires stale rows so a
    dropped webhook cannot leave premium switched on forever.
    """
    moment = now or datetime.now(timezone.utc)
    rows = (
        await db.scalars(select(Subscription).where(Subscription.user_id == user.id))
    ).all()

    for row in rows:
        if sub_state.refresh_status(row, now=moment):
            logger.info(
                "subscription_lazily_expired",
                subscription_id=str(row.id),
                user_id=str(user.id),
            )

    entitled = sub_state.any_entitled(rows, now=moment)
    if user.is_premium != entitled:
        user.is_premium = entitled
    await db.flush()
    return entitled


async def upsert_verified_subscription(
    db: AsyncSession,
    user: User,
    verified: VerifiedSubscription,
    *,
    now: Optional[datetime] = None,
) -> Subscription:
    """Write store truth into `subscriptions` for `user`."""
    moment = now or datetime.now(timezone.utc)
    identity, existing = await _resolve_store_identity(db, verified)

    if existing is not None:
        await _assert_ownership(db, existing, user)
        subscription = existing
    else:
        subscription = Subscription(
            id=uuid4(),
            user_id=user.id,
            platform=verified.platform,
            store_subscription_id=identity,
        )
        db.add(subscription)

    subscription.store_subscription_id = identity
    sub_state.apply_verified(subscription, verified, now=moment)
    await db.flush()
    return subscription


async def verify_and_grant(
    db: AsyncSession,
    user: User,
    *,
    platform: str,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str] = None,
) -> Subscription:
    """Verify a store purchase and reconcile the user's entitlement.

    Returns the subscription row. `user.is_premium` is refreshed as a side
    effect, so callers can read it straight afterwards.
    """
    platform = _assert_platform(platform)
    _assert_known_product(product_id)

    token = (purchase_token or "").strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="purchase_token is required",
        )

    settings = _settings()
    mode = (settings.billing_verify_mode or "stub").strip().lower()

    if mode == "stub":
        verified = _stub_verification(
            platform=platform,
            product_id=product_id,
            purchase_token=token,
            original_transaction_id=original_transaction_id,
        )
    elif mode in {"apple_google", "store"}:
        verified = await _verify_with_store(
            platform=platform,
            product_id=product_id,
            purchase_token=token,
            original_transaction_id=original_transaction_id,
        )
    else:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Unknown BILLING_VERIFY_MODE={mode}",
        )

    if verified.is_test and settings.is_production and mode != "stub":
        # A sandbox transaction reaching production is either a tester on the
        # wrong build or someone probing; either way it must not grant premium.
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail="Sandbox purchases cannot be redeemed in production",
        )

    subscription = await upsert_verified_subscription(db, user, verified)

    # Play refunds any purchase not acknowledged within three days.
    if verified.needs_acknowledgement and platform == "android" and mode != "stub":
        acknowledged = await acknowledge_google_subscription(
            product_id=verified.product_id,
            purchase_token=verified.purchase_token or token,
        )
        if not acknowledged:
            logger.warning(
                "play_acknowledge_pending",
                subscription_id=str(subscription.id),
                product_id=verified.product_id,
            )

    await refresh_premium_flag(db, user)
    await _track(
        db,
        "subscription_verified",
        user_id=user.id,
        properties={
            "platform": platform,
            "product_id": verified.product_id,
            "plan": verified.plan_code,
            "state": verified.state.value,
            "country": verified.country,
            "is_intro_offer": verified.is_intro_offer,
            "environment": verified.environment,
        },
    )
    return subscription


async def sync_subscription_from_store(
    db: AsyncSession,
    *,
    platform: str,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str] = None,
    account_token: Optional[str] = None,
) -> Optional[Subscription]:
    """Re-fetch a subscription from the store and persist the result.

    The webhook path. The notification tells us *which* subscription changed;
    the authoritative state always comes from a fresh API call, so a forged or
    replayed notification cannot move a subscription to a state the store does
    not agree with.
    """
    verified = await _verify_with_store(
        platform=platform,
        product_id=product_id,
        purchase_token=purchase_token,
        original_transaction_id=original_transaction_id,
    )

    identity, existing = await _resolve_store_identity(db, verified)
    owner: Optional[User] = None

    if existing is not None:
        owner = await db.scalar(select(User).where(User.id == existing.user_id))
    else:
        # No local row: the purchase completed but the client never called
        # verify (killed app, lost network, or a UPI payment that settled
        # hours later). The account token we passed at purchase time is what
        # lets us attribute it anyway.
        owner = await _user_from_account_token(db, account_token or verified.account_token)
        if owner is None:
            logger.warning(
                "subscription_notification_unattributed",
                platform=platform,
                product_id=product_id,
                store_subscription_id=identity,
            )
            return None

    if owner is None:
        logger.warning(
            "subscription_owner_missing",
            store_subscription_id=identity,
        )
        return None

    subscription = await upsert_verified_subscription(db, owner, verified)
    await refresh_premium_flag(db, owner)
    return subscription


async def _user_from_account_token(
    db: AsyncSession,
    account_token: Optional[str],
) -> Optional[User]:
    """Resolve the account id we handed the store at purchase time."""
    raw = (account_token or "").strip()
    if not raw:
        return None
    try:
        user_id = UUID(raw)
    except (ValueError, AttributeError, TypeError):
        return None
    return await db.scalar(select(User).where(User.id == user_id))


async def revoke_subscription(
    db: AsyncSession,
    subscription: Subscription,
    *,
    reason: str = "refund",
    now: Optional[datetime] = None,
) -> Subscription:
    """Pull entitlement immediately — refund, chargeback, or Play void."""
    moment = now or datetime.now(timezone.utc)
    subscription.status = SubscriptionStatus.REVOKED
    subscription.revoked_at = moment
    subscription.auto_renewing = False
    subscription.cancel_reason = reason
    subscription.entitlements = {
        **(subscription.entitlements or {}),
        "premium": False,
        "state": SubscriptionStatus.REVOKED.value,
    }
    await db.flush()

    owner = await db.scalar(select(User).where(User.id == subscription.user_id))
    if owner is not None:
        await refresh_premium_flag(db, owner, now=moment)
        await _track(
            db,
            "subscription_revoked",
            user_id=owner.id,
            properties={"reason": reason, "product_id": subscription.product_id},
        )
    return subscription


async def _track(
    db: AsyncSession,
    event: str,
    *,
    user_id,
    properties: dict,
) -> None:
    """Analytics writes must never break a purchase."""
    try:
        from app.analytics import track_event

        await track_event(db, event, user_id=user_id, properties=properties)
    except Exception as exc:  # noqa: BLE001 — telemetry is not worth a 500
        logger.warning("billing_analytics_failed", event=event, error=str(exc))


def legacy_lifetime_product_id() -> str:
    return _settings().iap_premium_product_id


__all__ = [
    "PlanCode",
    "refresh_premium_flag",
    "revoke_subscription",
    "sync_subscription_from_store",
    "upsert_verified_subscription",
    "verify_and_grant",
]
