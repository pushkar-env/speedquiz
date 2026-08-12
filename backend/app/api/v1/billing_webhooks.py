"""Public store notification endpoints.

Neither store can present a bearer token from our own auth system, so these
routes sit outside `CurrentUser` and authenticate on their own terms:

* Apple signs the body; `handle_apple_notification` verifies the JWS chain.
* Google Pub/Sub can carry an OIDC token, a shared secret in the push URL, or
  both. At least one is required in production.

Both always answer 200 once a notification has been recorded, even if we could
not attribute it to an account. A 5xx makes the store retry the same message
for hours and, for Pub/Sub, stalls the whole subscription behind it.
"""

from __future__ import annotations

import hmac
from typing import Any, Optional

from fastapi import APIRouter, Header, HTTPException, Query, Request, status
from pydantic import BaseModel, Field

from app.auth.deps import DbSession
from app.core.config import get_settings
from app.core.logging import get_logger
from app.payments.webhooks import (
    WebhookRejected,
    handle_apple_notification,
    handle_google_notification,
)

router = APIRouter(prefix="/billing", tags=["billing"])
logger = get_logger(__name__)


class AppleNotificationRequest(BaseModel):
    signed_payload: str = Field(alias="signedPayload", min_length=1)

    model_config = {"populate_by_name": True}


async def _verify_pubsub_auth(
    *,
    token: Optional[str],
    authorization: Optional[str],
) -> None:
    """Authenticate a Pub/Sub push request.

    Compared with `compare_digest` so a wrong secret cannot be recovered by
    timing the response.
    """
    settings = get_settings()
    shared_secret = settings.google_rtdn_shared_secret.strip()
    oidc_audience = settings.google_rtdn_oidc_audience.strip()

    if not shared_secret and not oidc_audience:
        if settings.is_production:
            # Fail closed: an unauthenticated public endpoint that writes to
            # the billing tables is not something to leave open by omission.
            logger.error("rtdn_auth_not_configured")
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Play notifications are not configured",
            )
        return

    if shared_secret:
        if token and hmac.compare_digest(token, shared_secret):
            return
        if not oidc_audience:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Invalid notification token",
            )

    if oidc_audience:
        if not authorization or not authorization.lower().startswith("bearer "):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Missing Pub/Sub OIDC token",
            )
        await _verify_oidc_token(authorization.split(" ", 1)[1].strip())
        return

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Invalid notification token",
    )


async def _verify_oidc_token(token: str) -> None:
    """Validate the Google-signed OIDC token on a Pub/Sub push.

    Verified against Google's published JWKS, with the audience and (when
    configured) the service-account email both checked — an unverified token
    would be no better than no token at all.
    """
    from app.payments.google_oidc import GoogleOidcError, verify_pubsub_oidc_token

    settings = get_settings()
    try:
        await verify_pubsub_oidc_token(
            token,
            audience=settings.google_rtdn_oidc_audience.strip(),
            service_account=settings.google_rtdn_oidc_service_account.strip() or None,
        )
    except GoogleOidcError as exc:
        logger.warning("rtdn_oidc_rejected", error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid Pub/Sub OIDC token",
        ) from exc


@router.post("/webhooks/google", status_code=status.HTTP_200_OK)
async def google_rtdn_webhook(
    request: Request,
    db: DbSession,
    token: Optional[str] = Query(default=None),
    authorization: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    """Play Real-Time Developer Notifications (Pub/Sub push)."""
    await _verify_pubsub_auth(token=token, authorization=authorization)

    try:
        body = await request.json()
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Body must be JSON",
        ) from exc
    if not isinstance(body, dict):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Body must be a JSON object",
        )

    try:
        return await handle_google_notification(db, body)
    except WebhookRejected as exc:
        # Malformed, not transient. 400 stops Pub/Sub from redelivering it
        # forever; a 5xx here would block every later message in the queue.
        logger.warning("rtdn_rejected", error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)
        ) from exc


@router.post("/webhooks/apple", status_code=status.HTTP_200_OK)
async def apple_server_notification(
    payload: AppleNotificationRequest,
    db: DbSession,
) -> dict[str, Any]:
    """App Store Server Notifications V2."""
    try:
        return await handle_apple_notification(db, payload.signed_payload)
    except WebhookRejected as exc:
        logger.warning("apple_notification_rejected", error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)
        ) from exc
