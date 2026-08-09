"""Google Play Developer API purchase verification (httpx + service-account JWT)."""

from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from typing import Any, Optional
from urllib.parse import quote

import httpx
from fastapi import HTTPException, status
from jose import jwt

from app.core.config import get_settings
from app.payments.store_types import VerifiedPurchase

_ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
_TOKEN_URL = "https://oauth2.googleapis.com/token"
_PRODUCTS_URL = (
    "https://androidpublisher.googleapis.com/androidpublisher/v3/"
    "applications/{package}/purchases/products/{product}/tokens/{token}"
)


def google_credentials_configured() -> bool:
    raw = (get_settings().google_play_service_account_json or "").strip()
    return bool(raw)


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


async def verify_google_purchase(
    *,
    product_id: str,
    purchase_token: str,
    client: Optional[httpx.AsyncClient] = None,
    access_token: Optional[str] = None,
) -> VerifiedPurchase:
    if not google_credentials_configured():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Google Play not configured — set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON",
        )

    settings = get_settings()
    expected_product = settings.iap_premium_product_id
    if product_id != expected_product:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown product_id (expected {expected_product})",
        )

    token = purchase_token.strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="purchase_token is required",
        )

    package = (settings.iap_android_package or settings.app_link_android_package).strip()
    url = _PRODUCTS_URL.format(
        package=quote(package, safe=""),
        product=quote(product_id, safe=""),
        token=quote(token, safe=""),
    )
    bearer = access_token or await fetch_google_access_token(client=client)
    headers = {"Authorization": f"Bearer {bearer}"}

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
            detail=f"Google Play API unreachable: {exc}",
        ) from exc

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
    # purchaseState: 0 = purchased, 1 = canceled, 2 = pending
    purchase_state = body.get("purchaseState")
    if purchase_state not in (0, "0", None):
        if purchase_state is not None:
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail=f"Google Play purchase not active (state={purchase_state})",
            )

    order_id = str(body.get("orderId") or token)
    return VerifiedPurchase(
        product_id=product_id,
        original_transaction_id=order_id,
        expires_at=_ms_to_dt(body.get("expiryTimeMillis")),
    )
