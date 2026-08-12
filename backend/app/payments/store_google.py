"""Google Play Developer API — subscription verification and acknowledgement.

Two endpoints matter:

* `purchases.subscriptionsv2.get` returns the whole subscription (state, line
  items, offer, region, upgrade chain) in one call. The v1 `purchases.products`
  endpoint the earlier one-time unlock used cannot describe a subscription at
  all.
* `purchases.subscriptions.acknowledge` must be called within three days of
  purchase or **Play automatically refunds the user and revokes the
  subscription**. Acknowledging is not optional bookkeeping; skipping it is a
  silent revenue leak.

Authentication is a service-account JWT exchanged for an access token, so there
is no extra client library dependency.
"""

from __future__ import annotations

import json
import re
import time
from datetime import datetime, timezone
from typing import Any, Optional
from urllib.parse import quote

import httpx
from fastapi import HTTPException, status
from jose import jwt

from app.core.config import get_settings
from app.core.logging import get_logger
from app.payments.plans import PlanCode, plan_for_product
from app.payments.store_types import StoreState, VerifiedSubscription

logger = get_logger(__name__)

_ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
_TOKEN_URL = "https://oauth2.googleapis.com/token"
_API_ROOT = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
_SUBSCRIPTIONS_V2_URL = _API_ROOT + "/{package}/purchases/subscriptionsv2/tokens/{token}"
_ACKNOWLEDGE_URL = (
    _API_ROOT + "/{package}/purchases/subscriptions/{product}/tokens/{token}:acknowledge"
)
_PRODUCTS_URL = _API_ROOT + "/{package}/purchases/products/{product}/tokens/{token}"

#: SubscriptionPurchaseV2.subscriptionState → our neutral state.
_STATE_MAP = {
    "SUBSCRIPTION_STATE_ACTIVE": StoreState.ACTIVE,
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": StoreState.GRACE,
    "SUBSCRIPTION_STATE_ON_HOLD": StoreState.ON_HOLD,
    "SUBSCRIPTION_STATE_PAUSED": StoreState.PAUSED,
    "SUBSCRIPTION_STATE_PENDING": StoreState.PENDING,
    "SUBSCRIPTION_STATE_CANCELED": StoreState.CANCELLED,
    "SUBSCRIPTION_STATE_EXPIRED": StoreState.EXPIRED,
    "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED": StoreState.EXPIRED,
}


def google_credentials_configured() -> bool:
    return get_settings().google_play_configured


def _service_account_info() -> dict[str, Any]:
    raw = (get_settings().google_play_service_account_json or "").strip()
    if not raw:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Google Play not configured — set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON",
        )
    try:
        info = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is not valid JSON",
        ) from exc
    if not isinstance(info, dict):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="GOOGLE_PLAY_SERVICE_ACCOUNT_JSON must be a JSON object",
        )
    return info


def build_google_service_account_jwt(*, now: Optional[int] = None) -> str:
    info = _service_account_info()
    email = info.get("client_email")
    private_key = info.get("private_key")
    if not email or not private_key:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Service account JSON missing client_email or private_key",
        )
    issued = now if now is not None else int(time.time())
    payload = {
        "iss": email,
        "scope": _ANDROID_PUBLISHER_SCOPE,
        "aud": _TOKEN_URL,
        "iat": issued,
        "exp": issued + 3600,
    }
    return jwt.encode(payload, private_key, algorithm="RS256")


async def fetch_google_access_token(
    *,
    client: Optional[httpx.AsyncClient] = None,
) -> str:
    assertion = build_google_service_account_jwt()
    data = {
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }

    async def _post(http: httpx.AsyncClient) -> httpx.Response:
        return await http.post(_TOKEN_URL, data=data)

    try:
        if client is not None:
            response = await _post(client)
        else:
            async with httpx.AsyncClient(timeout=20.0) as http:
                response = await _post(http)
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Google OAuth unreachable: {exc}",
        ) from exc

    if response.status_code >= 400:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Google OAuth failed ({response.status_code})",
        )
    body = response.json()
    token = body.get("access_token")
    if not token:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Google OAuth response missing access_token",
        )
    return str(token)


def _ms_to_dt(value: Any) -> Optional[datetime]:
    if value is None or value == "":
        return None
    try:
        ms = int(value)
    except (TypeError, ValueError):
        return None
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)


_RFC3339_RE = re.compile(
    r"^(?P<base>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})"
    r"(?:\.(?P<frac>\d+))?"
    r"(?P<offset>Z|[+-]\d{2}:?\d{2})?$"
)


def _rfc3339_to_dt(value: Any) -> Optional[datetime]:
    """Parse Play's RFC 3339 timestamps ("2026-01-01T00:00:00.000Z").

    `fromisoformat` alone is not enough: Play emits nanosecond precision on
    some fields and Python accepts at most six fractional digits.
    """
    if not value or not isinstance(value, str):
        return None
    match = _RFC3339_RE.match(value.strip())
    if not match:
        return None

    frac = (match.group("frac") or "").ljust(6, "0")[:6]
    offset = match.group("offset") or "+00:00"
    if offset == "Z":
        offset = "+00:00"
    elif len(offset) == 5:  # +0530 → +05:30
        offset = f"{offset[:3]}:{offset[3:]}"

    try:
        return datetime.fromisoformat(f"{match.group('base')}.{frac}{offset}")
    except ValueError:
        return None


def _package_name() -> str:
    settings = get_settings()
    return (settings.iap_android_package or settings.app_link_android_package).strip()


async def _authed_request(
    method: str,
    url: str,
    *,
    client: Optional[httpx.AsyncClient],
    access_token: Optional[str],
    json_body: Optional[dict[str, Any]] = None,
) -> httpx.Response:
    bearer = access_token or await fetch_google_access_token(client=client)
    headers = {"Authorization": f"Bearer {bearer}"}

    async def _send(http: httpx.AsyncClient) -> httpx.Response:
        return await http.request(method, url, headers=headers, json=json_body)

    try:
        if client is not None:
            return await _send(client)
        async with httpx.AsyncClient(timeout=20.0) as http:
            return await _send(http)
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Google Play API unreachable: {exc}",
        ) from exc


def _pick_line_item(body: dict[str, Any]) -> dict[str, Any]:
    """Choose the line item for a product we sell, else the first one."""
    items = [i for i in (body.get("lineItems") or []) if isinstance(i, dict)]
    if not items:
        return {}
    for item in items:
        if plan_for_product(str(item.get("productId") or "")) is not None:
            return item
    return items[0]


def _cancel_reason(body: dict[str, Any]) -> Optional[str]:
    context = body.get("canceledStateContext")
    if not isinstance(context, dict):
        return None
    if "userInitiatedCancellation" in context:
        return "user_cancelled"
    if "systemInitiatedCancellation" in context:
        return "billing_error"
    if "developerInitiatedCancellation" in context:
        return "developer_cancelled"
    if "replacementCancellation" in context:
        return "replaced"
    return None


def build_verified_subscription(
    body: dict[str, Any],
    *,
    purchase_token: str,
) -> VerifiedSubscription:
    """Normalise a `SubscriptionPurchaseV2` payload."""
    line_item = _pick_line_item(body)
    product_id = str(line_item.get("productId") or "")
    plan = plan_for_product(product_id)

    raw_state = str(body.get("subscriptionState") or "")
    state = _STATE_MAP.get(raw_state, StoreState.EXPIRED)

    auto_renewing_plan = line_item.get("autoRenewingPlan")
    auto_renewing = bool(
        isinstance(auto_renewing_plan, dict)
        and auto_renewing_plan.get("autoRenewEnabled", False)
    )
    # A cancelled-but-unexpired subscription still reports ACTIVE with
    # autoRenewEnabled=false; surface that as CANCELLED so the UI can say
    # "ends on <date>" instead of implying it will renew.
    if state is StoreState.ACTIVE and not auto_renewing:
        state = StoreState.CANCELLED

    offer_details = line_item.get("offerDetails")
    offer_id = None
    if isinstance(offer_details, dict):
        offer_id = str(offer_details.get("offerId") or "") or None

    paused_context = body.get("pausedStateContext")
    auto_resume_at = None
    if isinstance(paused_context, dict):
        auto_resume_at = _rfc3339_to_dt(paused_context.get("autoResumeTime"))

    identifiers = body.get("externalAccountIdentifiers")
    account_token = None
    if isinstance(identifiers, dict):
        account_token = (
            str(identifiers.get("obfuscatedExternalAccountId") or "")
            or str(identifiers.get("externalAccountId") or "")
            or None
        )

    acknowledgement = str(body.get("acknowledgementState") or "")
    cancelled_at = None
    context = body.get("canceledStateContext")
    if isinstance(context, dict):
        user_cancel = context.get("userInitiatedCancellation")
        if isinstance(user_cancel, dict):
            cancelled_at = _rfc3339_to_dt(user_cancel.get("cancelTime"))

    # `testPurchase` is present (as {}) only for licence-test accounts, so
    # membership — not truthiness — is the signal.
    is_test = "testPurchase" in body

    return VerifiedSubscription(
        platform="android",
        product_id=product_id,
        plan_code=plan.code.value if plan else None,
        # Play has no stable subscription id across upgrades; the caller
        # resolves the root of the linkedPurchaseToken chain and overrides this.
        store_subscription_id=purchase_token,
        state=state,
        latest_transaction_id=str(body.get("latestOrderId") or "") or None,
        purchase_token=purchase_token,
        started_at=_rfc3339_to_dt(body.get("startTime")),
        expires_at=_rfc3339_to_dt(line_item.get("expiryTime")),
        auto_resume_at=auto_resume_at,
        cancelled_at=cancelled_at,
        auto_renewing=auto_renewing,
        cancel_reason=_cancel_reason(body),
        # Play models an intro price as an *offer* applied to the base plan, so
        # the presence of an offerId is what "currently on intro pricing" means.
        is_intro_offer=bool(offer_id),
        offer_id=offer_id,
        country=str(body.get("regionCode") or "") or None,
        environment="Sandbox" if is_test else "Production",
        is_test=is_test,
        account_token=account_token,
        linked_purchase_token=str(body.get("linkedPurchaseToken") or "") or None,
        needs_acknowledgement=acknowledgement == "ACKNOWLEDGEMENT_STATE_PENDING",
        raw={
            "subscriptionState": raw_state,
            "acknowledgementState": acknowledgement,
            "regionCode": body.get("regionCode"),
            "productId": product_id,
            "latestOrderId": body.get("latestOrderId"),
        },
    )


async def verify_google_subscription(
    *,
    product_id: str,
    purchase_token: str,
    client: Optional[httpx.AsyncClient] = None,
    access_token: Optional[str] = None,
) -> VerifiedSubscription:
    """Fetch the authoritative state of an Android subscription purchase."""
    if not google_credentials_configured():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Google Play not configured — set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON",
        )

    token = (purchase_token or "").strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="purchase_token is required",
        )

    url = _SUBSCRIPTIONS_V2_URL.format(
        package=quote(_package_name(), safe=""),
        token=quote(token, safe=""),
    )
    response = await _authed_request(
        "GET", url, client=client, access_token=access_token
    )

    if response.status_code == 404:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Google Play purchase not found",
        )
    if response.status_code >= 400:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=f"Google Play verification failed ({response.status_code})",
        )

    verified = build_verified_subscription(response.json(), purchase_token=token)
    if plan_for_product(verified.product_id) is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Google Play product not sold by this app (got {verified.product_id!r})",
        )
    return verified


async def acknowledge_google_subscription(
    *,
    product_id: str,
    purchase_token: str,
    client: Optional[httpx.AsyncClient] = None,
    access_token: Optional[str] = None,
) -> bool:
    """Acknowledge a purchase so Play does not auto-refund it.

    Returns True when Play accepted the acknowledgement. Failure is logged and
    reported, never raised: the user has already paid and been granted access,
    and a retry sweep can pick it up.
    """
    token = (purchase_token or "").strip()
    if not token or not product_id:
        return False

    url = _ACKNOWLEDGE_URL.format(
        package=quote(_package_name(), safe=""),
        product=quote(product_id, safe=""),
        token=quote(token, safe=""),
    )
    try:
        response = await _authed_request(
            "POST", url, client=client, access_token=access_token, json_body={}
        )
    except HTTPException as exc:
        logger.warning(
            "play_acknowledge_unreachable", product_id=product_id, detail=str(exc.detail)
        )
        return False

    if response.status_code < 400:
        return True
    # 400 here usually means "already acknowledged", which is a success for us.
    already_done = response.status_code == 400 and "already" in response.text.lower()
    if already_done:
        return True
    logger.warning(
        "play_acknowledge_failed",
        product_id=product_id,
        status_code=response.status_code,
    )
    return False


async def verify_google_legacy_product(
    *,
    product_id: str,
    purchase_token: str,
    client: Optional[httpx.AsyncClient] = None,
    access_token: Optional[str] = None,
) -> VerifiedSubscription:
    """Verify the retired one-time unlock (`purchases.products`).

    Kept so anyone who bought the non-consumable before the subscription
    launch keeps premium when they reinstall and hit Restore.
    """
    token = (purchase_token or "").strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="purchase_token is required",
        )

    url = _PRODUCTS_URL.format(
        package=quote(_package_name(), safe=""),
        product=quote(product_id, safe=""),
        token=quote(token, safe=""),
    )
    response = await _authed_request(
        "GET", url, client=client, access_token=access_token
    )

    if response.status_code == 404:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Google Play purchase not found",
        )
    if response.status_code >= 400:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=f"Google Play verification failed ({response.status_code})",
        )

    body = response.json()
    purchase_state = body.get("purchaseState")
    if purchase_state not in (0, "0", None):
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=f"Google Play purchase not active (state={purchase_state})",
        )

    order_id = str(body.get("orderId") or token)
    return VerifiedSubscription(
        platform="android",
        product_id=product_id,
        plan_code=PlanCode.LEGACY_LIFETIME.value,
        store_subscription_id=order_id,
        state=StoreState.ACTIVE,
        latest_transaction_id=order_id,
        purchase_token=token,
        # A non-consumable never expires; the resolver treats a null expiry on
        # an active row as permanent.
        expires_at=None,
        auto_renewing=False,
        environment="Production",
        needs_acknowledgement=body.get("acknowledgementState") in (0, "0"),
        raw={"legacy_product": True, "orderId": order_id},
    )


async def verify_google_purchase(
    *,
    product_id: str,
    purchase_token: str,
    client: Optional[httpx.AsyncClient] = None,
    access_token: Optional[str] = None,
) -> VerifiedSubscription:
    """Route to the subscription or legacy one-time endpoint by product."""
    plan = plan_for_product(product_id)
    if plan is not None and not plan.is_subscription:
        return await verify_google_legacy_product(
            product_id=product_id,
            purchase_token=purchase_token,
            client=client,
            access_token=access_token,
        )
    return await verify_google_subscription(
        product_id=product_id,
        purchase_token=purchase_token,
        client=client,
        access_token=access_token,
    )
