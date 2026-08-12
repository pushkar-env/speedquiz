"""What a user is allowed to do, derived from their subscriptions.

`user.is_premium` is a cache of "has at least one entitled subscription". The
feature gates below read that flag rather than re-deriving state, so a request
handler never pays for a subscription query — but anything that *changes*
entitlement must call `billing.refresh_premium_flag` so the cache stays honest.

Current gates:

* unique questions per topic  (free soft-caps, premium unlimited)
* custom AI topic generations (free daily quota, premium unlimited)
* cosmetics: premium avatars and profile flair
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models import Subscription, User
from app.payments import state as sub_state
from app.payments.plans import manage_subscription_url, plan_for_code

settings = get_settings()


def unique_question_allowance(user: Optional[User]) -> Optional[int]:
    """Max unique questions per topic before the paywall. None = unlimited."""
    if not settings.entitlements_enforce_question_caps:
        return None
    if user is None:
        return settings.free_unique_questions_per_topic
    if user.is_premium:
        return None
    return settings.free_unique_questions_per_topic


def custom_topics_unlimited(user: Optional[User]) -> bool:
    if user and user.is_premium:
        return True
    return not settings.entitlements_enforce_question_caps


def premium_cosmetics_unlocked(user: Optional[User]) -> bool:
    """Premium avatars, animated profile ring, leaderboard badge."""
    return bool(user and user.is_premium)


def entitlements_status(user: User) -> dict[str, Any]:
    """Feature-flag view, with no subscription detail. Cheap — no queries."""
    enforce = bool(settings.entitlements_enforce_question_caps)
    return {
        "is_premium": bool(user.is_premium),
        "enforce_caps": enforce,
        "unique_per_topic_limit": (
            None
            if user.is_premium or not enforce
            else settings.free_unique_questions_per_topic
        ),
        "custom_topics_unlimited": custom_topics_unlimited(user),
        "premium_cosmetics": premium_cosmetics_unlocked(user),
        "dev_toggle_allowed": (
            not settings.is_production or settings.entitlements_dev_toggle
        ),
        "premium_product_id": settings.iap_premium_product_id,
        # "stub" until the store adapters are switched on. The client shows a
        # test-mode banner and offers a simulated purchase so the paywall can
        # be exercised end to end before any store products exist.
        "billing_mode": "store" if settings.store_verification_enabled else "stub",
        "stub_purchase_allowed": settings.stub_purchase_allowed,
    }


async def entitlements_detail(
    db: AsyncSession,
    user: User,
    *,
    now: Optional[datetime] = None,
) -> dict[str, Any]:
    """Full entitlement payload, including live subscription state.

    Expires stale rows on the way through, so a lapsed subscription stops
    granting premium the next time anyone asks — no cron required.
    """
    moment = now or datetime.now(timezone.utc)
    rows = list(
        (
            await db.scalars(
                select(Subscription).where(Subscription.user_id == user.id)
            )
        ).all()
    )

    changed = False
    for row in rows:
        if sub_state.refresh_status(row, now=moment):
            changed = True

    entitled = sub_state.any_entitled(rows, now=moment)
    if user.is_premium != entitled:
        user.is_premium = entitled
        changed = True
    if changed:
        await db.flush()

    snapshot = sub_state.snapshot(rows, now=moment)
    plan = plan_for_code(snapshot.plan_code) if snapshot.plan_code else None

    payload = entitlements_status(user)
    payload.update(
        {
            "plan_code": snapshot.plan_code,
            "plan_title": plan.title if plan else None,
            "product_id": snapshot.product_id,
            "platform": snapshot.platform,
            "subscription_status": snapshot.status.value,
            "expires_at": _iso(snapshot.expires_at),
            "grace_until": _iso(snapshot.grace_until),
            "auto_renewing": snapshot.auto_renewing,
            "will_renew": snapshot.will_renew,
            "is_intro_offer": snapshot.is_intro_offer,
            "needs_payment_fix": snapshot.needs_payment_fix,
            "is_pending": snapshot.is_pending,
            "manage_url": manage_subscription_url(
                snapshot.platform, snapshot.product_id
            ),
        }
    )
    return payload


def _iso(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    aware = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return aware.astimezone(timezone.utc).isoformat()
