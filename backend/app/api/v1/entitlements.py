from typing import Optional

from pydantic import BaseModel, Field

from app.auth.deps import CurrentUser, DbSession
from app.core.config import get_settings
from app.payments.billing import verify_and_grant
from app.payments.entitlements import entitlements_status
from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/entitlements", tags=["entitlements"])


class EntitlementsMeOut(BaseModel):
    is_premium: bool
    enforce_caps: bool
    unique_per_topic_limit: int | None = None
    custom_topics_unlimited: bool
    dev_toggle_allowed: bool
    premium_product_id: str = "speedquiz_premium"


class DevPremiumRequest(BaseModel):
    enabled: bool = Field(description="Set user.is_premium")


class PurchaseVerifyRequest(BaseModel):
    platform: str = Field(description="ios or android")
    product_id: str
    purchase_token: str = Field(min_length=1)
    original_transaction_id: Optional[str] = None


class PurchaseRestoreRequest(BaseModel):
    purchases: list[PurchaseVerifyRequest] = Field(default_factory=list)


def _entitlements_out(user) -> EntitlementsMeOut:
    return EntitlementsMeOut(**entitlements_status(user))


@router.get("/me", response_model=EntitlementsMeOut)
async def get_my_entitlements(user: CurrentUser) -> EntitlementsMeOut:
    return _entitlements_out(user)


@router.post("/dev/premium", response_model=EntitlementsMeOut)
async def set_dev_premium(
    payload: DevPremiumRequest,
    user: CurrentUser,
    db: DbSession,
) -> EntitlementsMeOut:
    settings = get_settings()
    allowed = (not settings.is_production) or settings.entitlements_dev_toggle
    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Dev premium toggle disabled",
        )
    user.is_premium = bool(payload.enabled)
    await db.flush()
    return _entitlements_out(user)


@router.post("/purchases/verify", response_model=EntitlementsMeOut)
async def verify_purchase(
    payload: PurchaseVerifyRequest,
    user: CurrentUser,
    db: DbSession,
) -> EntitlementsMeOut:
    await verify_and_grant(
        db,
        user,
        platform=payload.platform,
        product_id=payload.product_id,
        purchase_token=payload.purchase_token,
        original_transaction_id=payload.original_transaction_id,
    )
    return _entitlements_out(user)


@router.post("/purchases/restore", response_model=EntitlementsMeOut)
async def restore_purchases(
    payload: PurchaseRestoreRequest,
    user: CurrentUser,
    db: DbSession,
) -> EntitlementsMeOut:
    if not payload.purchases:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="purchases list is required",
        )
    for item in payload.purchases:
        await verify_and_grant(
            db,
            user,
            platform=item.platform,
            product_id=item.product_id,
            purchase_token=item.purchase_token,
            original_transaction_id=item.original_transaction_id,
        )
    return _entitlements_out(user)
