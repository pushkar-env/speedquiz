from pydantic import BaseModel, Field

from app.auth.deps import CurrentUser, DbSession
from app.core.config import get_settings
from app.payments.entitlements import entitlements_status
from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/entitlements", tags=["entitlements"])


class EntitlementsMeOut(BaseModel):
    is_premium: bool
    enforce_caps: bool
    unique_per_topic_limit: int | None = None
    custom_topics_unlimited: bool
    dev_toggle_allowed: bool


class DevPremiumRequest(BaseModel):
    enabled: bool = Field(description="Set user.is_premium")


@router.get("/me", response_model=EntitlementsMeOut)
async def get_my_entitlements(user: CurrentUser) -> EntitlementsMeOut:
    return EntitlementsMeOut(**entitlements_status(user))


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
    return EntitlementsMeOut(**entitlements_status(user))
