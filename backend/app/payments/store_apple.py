"""App Store Server API — auto-renewable subscription verification.

Uses `GET /inApps/v1/subscriptions/{transactionId}`, which returns the whole
subscription group with the latest signed transaction and renewal info. That
single call answers every question we need: is it active, when does it expire,
is auto-renew on, is it in billing retry, was it refunded.

Both the sandbox and production hosts are tried, because a transaction id does
not carry its environment and TestFlight builds hit sandbox while the same
binary in the App Store hits production.
"""

from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Any, Optional

import httpx
from fastapi import HTTPException, status
from jose import jwt

from app.core.config import get_settings
from app.core.logging import get_logger
from app.payments.apple_jws import AppleJwsError, decode_unverified
from app.payments.plans import plan_for_product
from app.payments.store_types import StoreState, VerifiedSubscription

logger = get_logger(__name__)

_APPLE_AUDIENCE = "appstoreconnect-v1"
_PROD_BASE = "https://api.storekit.itunes.apple.com"
_SANDBOX_BASE = "https://api.storekit-sandbox.itunes.apple.com"

#: `status` values in the subscription-status response.
_STATUS_ACTIVE = 1
_STATUS_EXPIRED = 2
_STATUS_BILLING_RETRY = 3
_STATUS_GRACE = 4
_STATUS_REVOKED = 5

#: `expirationIntent` in JWSRenewalInfo.
_EXPIRATION_INTENTS = {
    1: "user_cancelled",
    2: "billing_error",
    3: "price_increase_declined",
    4: "product_unavailable",
}


def apple_credentials_configured() -> bool:
    return get_settings().apple_iap_configured


def _normalize_pem(raw: str) -> str:
    text = (raw or "").strip()
    if "\\n" in text and "\n" not in text.replace("\\n", ""):
        text = text.replace("\\n", "\n")
    return text


def build_app_store_token(*, now: Optional[int] = None) -> str:
    settings = get_settings()
    issued = now if now is not None else int(time.time())
    payload = {
        "iss": settings.apple_iap_issuer_id.strip(),
        "iat": issued,
        "exp": issued + 20 * 60,
        "aud": _APPLE_AUDIENCE,
        "bid": (settings.apple_iap_bundle_id or "").strip(),
    }
    return jwt.encode(
        payload,
        _normalize_pem(settings.apple_iap_private_key),
        algorithm="ES256",
        headers={"kid": settings.apple_iap_key_id.strip(), "typ": "JWT"},
    )


def _api_bases() -> list[str]:
    """Preferred host first, the other as fallback."""
    env = (get_settings().apple_iap_environment or "Sandbox").strip().lower()
    if env in {"production", "prod"}:
        return [_PROD_BASE, _SANDBOX_BASE]
    return [_SANDBOX_BASE, _PROD_BASE]


def decode_signed_transaction(jws: str) -> dict[str, Any]:
    """Decode a JWS returned by the App Store Server API over TLS.

    Signature trust comes from the authenticated HTTPS call to Apple. Webhook
    bodies go through `apple_jws.verify_and_decode` instead.
    """
    try:
        return decode_unverified(jws)
    except AppleJwsError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Could not decode Apple payload: {exc}",
        ) from exc


def _ms_to_dt(value: Any) -> Optional[datetime]:
    if value is None or value == "":
        return None
    try:
        ms = int(value)
    except (TypeError, ValueError):
        return None
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)


def _resolve_state(
    *,
    api_status: Optional[int],
    transaction: dict[str, Any],
    renewal: dict[str, Any],
    now: datetime,
) -> tuple[StoreState, Optional[datetime]]:
    """Map Apple's status to ours, returning (state, grace_until)."""
    if transaction.get("revocationDate"):
        return StoreState.REVOKED, None

    grace_until = _ms_to_dt(renewal.get("gracePeriodExpiresDate"))
    auto_renew_on = str(renewal.get("autoRenewStatus", "1")) == "1"
    expires_at = _ms_to_dt(transaction.get("expiresDate"))

    if api_status == _STATUS_REVOKED:
        return StoreState.REVOKED, None
    if api_status == _STATUS_GRACE:
        return StoreState.GRACE, grace_until
    if api_status == _STATUS_BILLING_RETRY:
        # Retrying with a live grace window is still entitled; past it, Apple
        # has stopped service and so do we.
        if grace_until and grace_until > now:
            return StoreState.GRACE, grace_until
        return StoreState.ON_HOLD, grace_until
    if api_status == _STATUS_EXPIRED:
        return StoreState.EXPIRED, None
    if api_status == _STATUS_ACTIVE:
        return (StoreState.ACTIVE if auto_renew_on else StoreState.CANCELLED), None

    # No status field (notification path): fall back to the dates.
    if expires_at and expires_at <= now:
        if grace_until and grace_until > now:
            return StoreState.GRACE, grace_until
        return StoreState.EXPIRED, None
    return (StoreState.ACTIVE if auto_renew_on else StoreState.CANCELLED), None


def build_verified_subscription(
    *,
    transaction: dict[str, Any],
    renewal: dict[str, Any],
    api_status: Optional[int] = None,
    environment: Optional[str] = None,
    now: Optional[datetime] = None,
) -> VerifiedSubscription:
    """Normalise a signed transaction + renewal-info pair.

    Shared by the polling path and the notification path so both produce
    identical state for the same subscription.
    """
    moment = now or datetime.now(timezone.utc)
    product_id = str(transaction.get("productId") or "")
    plan = plan_for_product(product_id)

    state, grace_until = _resolve_state(
        api_status=api_status,
        transaction=transaction,
        renewal=renewal,
        now=moment,
    )

    original_txn = str(
        transaction.get("originalTransactionId") or transaction.get("transactionId") or ""
    )
    env = str(
        environment or transaction.get("environment") or renewal.get("environment") or "Production"
    )
    # Entitlement must fail safe: if *any* environment marker says sandbox,
    # treat the whole thing as a test purchase. Trusting only the outermost
    # value would let a sandbox transaction returned in a production-shaped
    # response unlock premium for real.
    is_test = any(
        str(marker).strip().lower() != "production"
        for marker in (
            env,
            transaction.get("environment"),
            renewal.get("environment"),
        )
        if marker
    )

    price_raw = transaction.get("price")
    try:
        # Apple quotes price in milliunits; our column is micros.
        price_micros = int(price_raw) * 1000 if price_raw is not None else None
    except (TypeError, ValueError):
        price_micros = None

    expiration_intent = renewal.get("expirationIntent")
    cancel_reason = _EXPIRATION_INTENTS.get(
        int(expiration_intent) if str(expiration_intent).isdigit() else -1
    )

    revoked_at = _ms_to_dt(transaction.get("revocationDate"))
    auto_renew_on = str(renewal.get("autoRenewStatus", "1")) == "1"

    return VerifiedSubscription(
        platform="ios",
        product_id=product_id,
        plan_code=plan.code.value if plan else None,
        store_subscription_id=original_txn,
        state=state,
        original_transaction_id=original_txn,
        latest_transaction_id=str(transaction.get("transactionId") or "") or None,
        started_at=_ms_to_dt(transaction.get("originalPurchaseDate")),
        current_period_start=_ms_to_dt(transaction.get("purchaseDate")),
        expires_at=_ms_to_dt(transaction.get("expiresDate")),
        grace_until=grace_until,
        cancelled_at=None if auto_renew_on else moment,
        revoked_at=revoked_at,
        auto_renewing=auto_renew_on,
        cancel_reason=cancel_reason,
        # offerType 1 is the introductory offer — the intro-price plan we sell.
        is_intro_offer=str(transaction.get("offerType") or "") == "1",
        offer_id=str(transaction.get("offerIdentifier") or "") or None,
        country=str(transaction.get("storefront") or "") or None,
        currency=str(transaction.get("currency") or "") or None,
        price_micros=price_micros,
        environment=env,
        is_test=is_test,
        account_token=str(transaction.get("appAccountToken") or "") or None,
        raw={
            "transaction": _redacted(transaction),
            "renewal": _redacted(renewal),
            "api_status": api_status,
        },
    )


def _redacted(payload: dict[str, Any]) -> dict[str, Any]:
    """Strip nothing sensitive today, but keep the payload bounded in size."""
    return {k: v for k, v in payload.items() if not isinstance(v, (dict, list))}


def _pick_transaction(
    body: dict[str, Any],
) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]], Optional[int]]:
    """Choose the transaction the app cares about from the group response.

    A subscription group can report several products (monthly and annual after
    a switch). Prefer one we actually sell, and among those the one Apple marks
    active.
    """
    best: tuple[int, dict[str, Any], dict[str, Any], Optional[int]] | None = None

    for group in body.get("data") or []:
        for entry in (group or {}).get("lastTransactions") or []:
            signed_txn = entry.get("signedTransactionInfo")
            if not signed_txn:
                continue
            transaction = decode_signed_transaction(signed_txn)
            renewal = (
                decode_signed_transaction(entry["signedRenewalInfo"])
                if entry.get("signedRenewalInfo")
                else {}
            )
            entry_status = entry.get("status")
            try:
                entry_status = int(entry_status) if entry_status is not None else None
            except (TypeError, ValueError):
                entry_status = None

            known = plan_for_product(str(transaction.get("productId") or "")) is not None
            # Active/grace outrank expired; a product we sell outranks one we do not.
            rank = (2 if known else 0) + (
                1 if entry_status in (_STATUS_ACTIVE, _STATUS_GRACE) else 0
            )
            if best is None or rank > best[0]:
                best = (rank, transaction, renewal, entry_status)

    if best is None:
        return None, None, None
    return best[1], best[2], best[3]


async def _get_subscription_status(
    transaction_id: str,
    *,
    client: Optional[httpx.AsyncClient] = None,
) -> tuple[dict[str, Any], str]:
    """Query Apple, trying the configured host then the other environment."""
    headers = {"Authorization": f"Bearer {build_app_store_token()}"}
    last_error: Optional[int] = None

    for base in _api_bases():
        url = f"{base}/inApps/v1/subscriptions/{transaction_id}"

        async def _get(http: httpx.AsyncClient) -> httpx.Response:
            return await http.get(url, headers=headers)

        try:
            if client is not None:
                response = await _get(client)
            else:
                async with httpx.AsyncClient(timeout=20.0) as http:
                    response = await _get(http)
        except httpx.HTTPError as exc:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"Apple App Store API unreachable: {exc}",
            ) from exc

        if response.status_code == 404:
            # Not in this environment — try the other one.
            last_error = 404
            continue
        if response.status_code >= 400:
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail=f"Apple verification failed ({response.status_code})",
            )
        body = response.json()
        environment = str(
            body.get("environment")
            or ("Production" if base == _PROD_BASE else "Sandbox")
        )
        return body, environment

    raise HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail="Apple transaction not found"
        if last_error == 404
        else "Apple verification failed",
    )


async def verify_apple_subscription(
    *,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str] = None,
    client: Optional[httpx.AsyncClient] = None,
) -> VerifiedSubscription:
    """Verify an iOS purchase and return its current subscription state."""
    if not apple_credentials_configured():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Apple IAP not configured — set APPLE_IAP_ISSUER_ID, "
                "APPLE_IAP_KEY_ID, and APPLE_IAP_PRIVATE_KEY"
            ),
        )

    settings = get_settings()
    transaction_id = (original_transaction_id or "").strip() or (purchase_token or "").strip()
    if not transaction_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Apple transaction id is required",
        )

    body, environment = await _get_subscription_status(transaction_id, client=client)
    transaction, renewal, api_status = _pick_transaction(body)
    if transaction is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Apple returned no transactions for this subscription",
        )

    store_product = str(transaction.get("productId") or "")
    if plan_for_product(store_product) is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Apple product not sold by this app (got {store_product!r})",
        )

    expected_bundle = (settings.apple_iap_bundle_id or "").strip()
    bundle = str(transaction.get("bundleId") or "")
    if expected_bundle and bundle and bundle != expected_bundle:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Apple bundleId mismatch (got {bundle!r})",
        )

    return build_verified_subscription(
        transaction=transaction,
        renewal=renewal or {},
        api_status=api_status,
        environment=str(body.get("environment") or environment),
    )


async def verify_apple_purchase(
    *,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str] = None,
    client: Optional[httpx.AsyncClient] = None,
) -> VerifiedSubscription:
    """Backwards-compatible alias used by the billing orchestrator."""
    return await verify_apple_subscription(
        product_id=product_id,
        purchase_token=purchase_token,
        original_transaction_id=original_transaction_id,
        client=client,
    )
