"""Apple App Store Server API purchase verification."""

from __future__ import annotations

import base64
import json
import time
from datetime import datetime, timezone
from typing import Any, Optional

import httpx
from fastapi import HTTPException, status
from jose import jwt

from app.core.config import get_settings
from app.payments.store_types import VerifiedPurchase

_APPLE_AUDIENCE = "appstoreconnect-v1"
_PROD_BASE = "https://api.storekit.itunes.apple.com"
_SANDBOX_BASE = "https://api.storekit-sandbox.itunes.apple.com"


def apple_credentials_configured() -> bool:
    settings = get_settings()
    return bool(
        (settings.apple_iap_issuer_id or "").strip()
        and (settings.apple_iap_key_id or "").strip()
        and (settings.apple_iap_private_key or "").strip()
    )


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


def _api_base() -> str:
    env = (get_settings().apple_iap_environment or "Sandbox").strip().lower()
    if env in {"production", "prod"}:
        return _PROD_BASE
    return _SANDBOX_BASE


def decode_signed_transaction(jws: str) -> dict[str, Any]:
    """Decode App Store JWS payload (signature trust deferred to TLS + Apple API)."""
    parts = jws.split(".")
    if len(parts) != 3:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid Apple signedTransactionInfo",
        )
    payload_b64 = parts[1]
    padding = "=" * (-len(payload_b64) % 4)
    try:
        raw = base64.urlsafe_b64decode(payload_b64 + padding)
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Could not decode Apple transaction payload",
        ) from exc
    if not isinstance(data, dict):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Apple transaction payload must be an object",
        )
    return data


def _ms_to_dt(value: Any) -> Optional[datetime]:
    if value is None or value == "":
        return None
    try:
        ms = int(value)
    except (TypeError, ValueError):
        return None
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)


async def verify_apple_purchase(
    *,
    product_id: str,
    purchase_token: str,
    original_transaction_id: Optional[str] = None,
    client: Optional[httpx.AsyncClient] = None,
) -> VerifiedPurchase:
    if not apple_credentials_configured():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Apple IAP not configured — set APPLE_IAP_ISSUER_ID, "
                "APPLE_IAP_KEY_ID, and APPLE_IAP_PRIVATE_KEY"
            ),
        )

    settings = get_settings()
    expected_product = settings.iap_premium_product_id
    transaction_id = (original_transaction_id or "").strip() or purchase_token.strip()
    if not transaction_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Apple transaction id is required",
        )

    url = f"{_api_base()}/inApps/v1/transactions/{transaction_id}"
    headers = {"Authorization": f"Bearer {build_app_store_token()}"}

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
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Apple transaction not found",
        )
    if response.status_code >= 400:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=f"Apple verification failed ({response.status_code})",
        )

    body = response.json()
    signed = body.get("signedTransactionInfo")
    if not signed or not isinstance(signed, str):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Apple response missing signedTransactionInfo",
        )

    tx = decode_signed_transaction(signed)
    store_product = str(tx.get("productId") or "")
    if store_product != expected_product or product_id != expected_product:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Apple product mismatch (got {store_product!r})",
        )

    bundle = str(tx.get("bundleId") or "")
    expected_bundle = (settings.apple_iap_bundle_id or "").strip()
    if expected_bundle and bundle and bundle != expected_bundle:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Apple bundleId mismatch (got {bundle!r})",
        )

    rev = tx.get("revocationDate")
    if rev:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail="Apple purchase was revoked",
        )

    txn = str(
        tx.get("originalTransactionId")
        or tx.get("transactionId")
        or transaction_id
    )
    return VerifiedPurchase(
        product_id=store_product,
        original_transaction_id=txn,
        expires_at=_ms_to_dt(tx.get("expiresDate")),
    )
