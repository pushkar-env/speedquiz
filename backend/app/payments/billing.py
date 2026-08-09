"""In-app purchase verification — stub now, Apple/Google later."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import uuid4

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models import Subscription, SubscriptionStatus, User

settings = get_settings()


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
    apple_google mode: not configured yet — refuses rather than inventing grants.
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

    if mode == "stub":
        if settings.is_production and not settings.billing_allow_stub_in_production:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Stub billing verification is disabled in production",
            )
    elif mode in {"apple_google", "store"}:
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail="Store verification not configured — set BILLING_VERIFY_MODE=stub for non-prod",
        )
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
        existing.expires_at = datetime.now(timezone.utc) + timedelta(days=365 * 10)
        existing.entitlements = {**(existing.entitlements or {}), "premium": True}
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
        expires_at=datetime.now(timezone.utc) + timedelta(days=365 * 10),
        entitlements={"premium": True, "verify_mode": mode},
    )
    db.add(sub)
    user.is_premium = True
    await db.flush()
    return user
