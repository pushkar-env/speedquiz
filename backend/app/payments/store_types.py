"""Store-neutral verification result.

Apple and Google describe the same subscription with entirely different
vocabularies. Both adapters normalise into `VerifiedSubscription` so that the
state machine, the webhook handlers and the persistence layer never branch on
platform.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional


class StoreState(str, Enum):
    """What the store says the subscription is doing right now."""

    ACTIVE = "active"
    #: Renewal failed, store is retrying, entitlement explicitly retained.
    GRACE = "grace"
    #: Retry window elapsed; Play suspends access until the user pays.
    ON_HOLD = "on_hold"
    #: Play-only user-initiated pause.
    PAUSED = "paused"
    #: Awaiting payment — UPI, net banking, or Apple "Ask to Buy".
    PENDING = "pending"
    #: Auto-renew switched off; still entitled until expires_at.
    CANCELLED = "cancelled"
    EXPIRED = "expired"
    #: Refund or chargeback. Entitlement is pulled immediately.
    REVOKED = "revoked"


@dataclass(frozen=True)
class VerifiedSubscription:
    """A subscription as the store currently reports it."""

    platform: str  # ios | android
    product_id: str
    store_subscription_id: str
    state: StoreState

    plan_code: Optional[str] = None
    original_transaction_id: Optional[str] = None
    latest_transaction_id: Optional[str] = None
    purchase_token: Optional[str] = None

    started_at: Optional[datetime] = None
    current_period_start: Optional[datetime] = None
    expires_at: Optional[datetime] = None
    grace_until: Optional[datetime] = None
    auto_resume_at: Optional[datetime] = None
    cancelled_at: Optional[datetime] = None
    revoked_at: Optional[datetime] = None

    auto_renewing: bool = True
    cancel_reason: Optional[str] = None
    is_intro_offer: bool = False
    offer_id: Optional[str] = None

    country: Optional[str] = None
    currency: Optional[str] = None
    price_micros: Optional[int] = None

    environment: str = "Production"
    is_test: bool = False

    #: Our user id as handed to the store at purchase time (Play
    #: obfuscatedAccountId / Apple appAccountToken). Lets a webhook attribute a
    #: purchase to an account even if the client never called verify.
    account_token: Optional[str] = None
    #: Play: the token this purchase replaced during an upgrade/downgrade.
    linked_purchase_token: Optional[str] = None
    #: Play requires acknowledgement within three days or it auto-refunds.
    needs_acknowledgement: bool = False

    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def is_lifetime(self) -> bool:
        return self.expires_at is None and self.state is StoreState.ACTIVE
