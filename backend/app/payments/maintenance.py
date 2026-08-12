"""Periodic subscription reconciliation.

Webhooks are the primary way a subscription's state reaches us, and they are
not reliable enough to be the only way: Pub/Sub can fail delivery for hours,
Apple retries a fixed number of times and then gives up, and a deploy during
either window drops whatever was in flight.

`user.is_premium` is a cache read on nearly every request, so a dropped
"expired" notification would leave a lapsed subscriber with premium
indefinitely. This sweep is the backstop — it expires anything whose paid
period has demonstrably ended, without needing the store to tell us again.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import func, select

from app.core.database import session_scope
from app.core.logging import get_logger
from app.models import (
    ENTITLED_SUBSCRIPTION_STATUSES,
    Subscription,
    User,
)
from app.payments import state as sub_state

logger = get_logger(__name__)

#: Bounded so one sweep cannot hold a transaction open over a huge backlog.
_DEFAULT_BATCH = 500


async def expire_lapsed_subscriptions(
    *,
    limit: int = _DEFAULT_BATCH,
    now: Optional[datetime] = None,
) -> int:
    """Demote subscriptions whose period (and grace) have both elapsed.

    Returns the number of subscriptions expired.
    """
    moment = now or datetime.now(timezone.utc)

    async with session_scope() as db:
        # A subscription is only past due once the later of its expiry and its
        # grace deadline has passed — expiring on `expires_at` alone would cut
        # off users the store is still retrying payment for.
        deadline = func.greatest(
            Subscription.expires_at,
            func.coalesce(Subscription.grace_until, Subscription.expires_at),
        )

        rows = list(
            (
                await db.scalars(
                    select(Subscription)
                    .where(
                        Subscription.status.in_(
                            [s.value for s in ENTITLED_SUBSCRIPTION_STATUSES]
                        ),
                        Subscription.expires_at.is_not(None),
                        deadline < moment,
                    )
                    .order_by(Subscription.expires_at)
                    .limit(limit)
                )
            ).all()
        )

        if not rows:
            return 0

        affected_users: set = set()
        expired = 0
        for row in rows:
            if sub_state.refresh_status(row, now=moment):
                expired += 1
                affected_users.add(row.user_id)

        # Recompute the cached flag once per user, not once per subscription —
        # someone who switched plans holds several rows.
        for user_id in affected_users:
            user = await db.scalar(select(User).where(User.id == user_id))
            if user is None:
                continue
            remaining = list(
                (
                    await db.scalars(
                        select(Subscription).where(Subscription.user_id == user_id)
                    )
                ).all()
            )
            entitled = sub_state.any_entitled(remaining, now=moment)
            if user.is_premium != entitled:
                user.is_premium = entitled

        await db.flush()

        if expired:
            logger.info(
                "subscriptions_expired_by_sweep",
                count=expired,
                users=len(affected_users),
            )
        return expired
