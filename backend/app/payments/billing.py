"""In-app purchase verification — stub or Apple/Google store adapters."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import uuid4

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models import Subscription, SubscriptionStatus, User
from app.payments.store_apple import verify_apple_purchase
from app.payments.store_google import verify_google_purchase
from app.payments.store_types import VerifiedPurchase

settings = get_settings()

_DEFAULT_TTL = timedelta(days=365 * 10)


def _assert_premium_product(product_id: str) -> None:
    expected = settings.iap_premium_product_id
    if product_id != expected:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown product_id (expected {expected})",
        )


def _assert_platform(platform: str) -> str:
    p = platform.strip().lower()
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
) -> VerifiedPurchase:
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


async def verify_and_grant(
    db: AsyncSession,
    user: User,
    *,
    platform: str,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str] = None,
) -> User:
    """
    Verify a store purchase and grant premium.

    Stub mode (default, non-production): accepts non-empty tokens and upserts Subscription.
    apple_google mode: verifies via App Store Server API / Play Developer API (503 if creds missing).
    """
    platform = _assert_platform(platform)
    _assert_premium_product(product_id)

    token = (purchase_token or "").strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="purchase_token is required",
        )

    txn = (original_transaction_id or "").strip() or token
    mode = (settings.billing_verify_mode or "stub").strip().lower()
    expires_at = datetime.now(timezone.utc) + _DEFAULT_TTL

    if mode == "stub":
        if settings.is_production and not settings.billing_allow_stub_in_production:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Stub billing verification is disabled in production",
            )
    elif mode in {"apple_google", "store"}:
        verified = await _verify_with_store(
            platform=platform,
            product_id=product_id,
            purchase_token=token,
            original_transaction_id=original_transaction_id,
        )
        product_id = verified.product_id
        txn = verified.original_transaction_id
        if verified.expires_at is not None:
            expires_at = verified.expires_at
    else:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Unknown BILLING_VERIFY_MODE={mode}",
        )

    existing = await db.scalar(
        select(Subscription).where(Subscription.original_transaction_id == txn)
    )
    if existing is not None:
        if existing.user_id != user.id:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Purchase already linked to another account",
            )
        existing.status = SubscriptionStatus.ACTIVE
        existing.product_id = product_id
        existing.platform = platform
        existing.expires_at = expires_at
        existing.entitlements = {
            **(existing.entitlements or {}),
            "premium": True,
            "verify_mode": mode,
        }
        user.is_premium = True
        await db.flush()
        return user

    sub = Subscription(
        id=uuid4(),
        user_id=user.id,
        status=SubscriptionStatus.ACTIVE,
        product_id=product_id,
        platform=platform,
        original_transaction_id=txn,
        expires_at=expires_at,
        entitlements={"premium": True, "verify_mode": mode},
    )
    db.add(sub)
    user.is_premium = True
    await db.flush()
    return user
