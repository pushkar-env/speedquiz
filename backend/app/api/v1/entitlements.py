from typing import Optional

from pydantic import BaseModel, Field

from app.auth.deps import CurrentUser, DbSession
from app.core.config import get_settings
from app.payments.billing import refresh_premium_flag, verify_and_grant
from app.payments.entitlements import entitlements_detail
from app.payments.plans import purchasable_plans
from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/entitlements", tags=["entitlements"])


class EntitlementsMeOut(BaseModel):
    """Feature flags plus the state of the user's subscription."""

    is_premium: bool
    enforce_caps: bool
    unique_per_topic_limit: int | None = None
    custom_topics_unlimited: bool
    premium_cosmetics: bool = False
    dev_toggle_allowed: bool
    premium_product_id: str = "speedquiz_premium"
    #: "stub" while store verification is off — the client shows a test banner.
    billing_mode: str = "stub"
    #: The client may complete a simulated purchase (test deployments only).
    stub_purchase_allowed: bool = False

    plan_code: Optional[str] = None
    plan_title: Optional[str] = None
    product_id: Optional[str] = None
    platform: Optional[str] = None
    subscription_status: str = "none"
    expires_at: Optional[str] = None
    grace_until: Optional[str] = None
    auto_renewing: bool = False
    will_renew: bool = False
    is_intro_offer: bool = False
    #: Store is retrying a failed payment — the UI should prompt a card update.
    needs_payment_fix: bool = False
    #: A purchase is awaiting settlement (UPI, net banking, Ask to Buy).
    is_pending: bool = False
    manage_url: Optional[str] = None


class PlanOut(BaseModel):
    """Plan shape only.

    Prices deliberately excluded: Play and the App Store are the merchant of
    record and own the localised price, so the client renders theirs. A price
    sent from here would be wrong for every market it was not written for.
    """

    code: str
    product_id: str
    period: str
    months: int
    title: str
    subtitle: str
    recommended: bool = False
    badge: Optional[str] = None


class PlansOut(BaseModel):
    plans: list[PlanOut]
    #: Both plans live in one Apple subscription group, so switching between
    #: them is an upgrade/downgrade rather than a second subscription.
    subscription_group: str = "speedquiz_premium"


class DevPremiumRequest(BaseModel):
    enabled: bool = Field(description="Set user.is_premium")


class PurchaseVerifyRequest(BaseModel):
    platform: str = Field(description="ios or android")
    product_id: str
    purchase_token: str = Field(min_length=1)
    original_transaction_id: Optional[str] = None


class PurchaseRestoreRequest(BaseModel):
    purchases: list[PurchaseVerifyRequest] = Field(default_factory=list)


@router.get("/plans", response_model=PlansOut)
async def get_plans() -> PlansOut:
    """What the paywall may offer. Open to guests — they can buy too."""
    return PlansOut(
        plans=[
            PlanOut(
                code=plan.code.value,
                product_id=plan.product_id,
                period=plan.period.value,
                months=plan.months,
                title=plan.title,
                subtitle=plan.subtitle,
                recommended=plan.recommended,
                badge=plan.badge,
            )
            for plan in purchasable_plans()
        ]
    )


@router.get("/me", response_model=EntitlementsMeOut)
async def get_my_entitlements(user: CurrentUser, db: DbSession) -> EntitlementsMeOut:
    return EntitlementsMeOut(**await entitlements_detail(db, user))


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
    enabled = bool(payload.enabled)
    detail = await entitlements_detail(db, user)

    # entitlements_detail recomputes is_premium from real subscriptions, which
    # for a dev toggle is always false. Overriding both the row and the payload
    # is the point of this endpoint — it exists to test the gates without a
    # store purchase.
    user.is_premium = enabled
    await db.flush()
    detail["is_premium"] = enabled
    detail["premium_cosmetics"] = enabled
    detail["custom_topics_unlimited"] = enabled or detail["custom_topics_unlimited"]
    if enabled:
        detail["unique_per_topic_limit"] = None
    return EntitlementsMeOut(**detail)


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
    return EntitlementsMeOut(**await entitlements_detail(db, user))


@router.post("/purchases/restore", response_model=EntitlementsMeOut)
async def restore_purchases(
    payload: PurchaseRestoreRequest,
    user: CurrentUser,
    db: DbSession,
) -> EntitlementsMeOut:
    """Re-verify everything the store says this account owns.

    One bad entry must not sink the whole restore: a user with an old expired
    subscription alongside a live one should still get their live one back, so
    failures are collected and only reported if *nothing* verified.
    """
    if not payload.purchases:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="purchases list is required",
        )

    errors: list[str] = []
    restored = 0
    for item in payload.purchases:
        try:
            await verify_and_grant(
                db,
                user,
                platform=item.platform,
                product_id=item.product_id,
                purchase_token=item.purchase_token,
                original_transaction_id=item.original_transaction_id,
            )
            restored += 1
        except HTTPException as exc:
            errors.append(f"{item.product_id}: {exc.detail}")

    if restored == 0 and errors:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="; ".join(errors[:3]),
        )

    await refresh_premium_flag(db, user)
    return EntitlementsMeOut(**await entitlements_detail(db, user))
