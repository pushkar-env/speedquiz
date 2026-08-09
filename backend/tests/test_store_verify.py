"""Store verification adapters (Apple / Google) + billing wiring."""

from __future__ import annotations

import base64
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import httpx
import pytest
from fastapi import HTTPException

from app.models import SubscriptionStatus
from app.payments.billing import verify_and_grant
from app.payments.store_apple import decode_signed_transaction, verify_apple_purchase
from app.payments.store_google import verify_google_purchase
from app.payments.store_types import VerifiedPurchase


def _user(*, premium: bool = False):
    return SimpleNamespace(id=uuid4(), is_premium=premium)


def _jws(payload: dict) -> str:
    header = base64.urlsafe_b64encode(b'{"alg":"ES256","typ":"JWT"}').rstrip(b"=").decode()
    body = (
        base64.urlsafe_b64encode(json.dumps(payload).encode("utf-8")).rstrip(b"=").decode()
    )
    return f"{header}.{body}.fakesig"


def _apple_settings(**overrides):
    base = SimpleNamespace(
        iap_premium_product_id="quizverse_premium",
        apple_iap_issuer_id="issuer",
        apple_iap_key_id="key",
        apple_iap_private_key="-----BEGIN PRIVATE KEY-----\nX\n-----END PRIVATE KEY-----",
        apple_iap_bundle_id="com.quizverse.app",
        apple_iap_environment="Sandbox",
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


def _google_settings(**overrides):
    base = SimpleNamespace(
        iap_premium_product_id="quizverse_premium",
        iap_android_package="com.quizverse.app",
        app_link_android_package="com.quizverse.app",
        google_play_service_account_json='{"type":"service_account","client_email":"a@b.c"}',
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


def test_decode_signed_transaction():
    payload = {
        "productId": "quizverse_premium",
        "originalTransactionId": "txn_apple_1",
        "bundleId": "com.quizverse.app",
    }
    decoded = decode_signed_transaction(_jws(payload))
    assert decoded["productId"] == "quizverse_premium"
    assert decoded["originalTransactionId"] == "txn_apple_1"


@pytest.mark.asyncio
async def test_apple_missing_creds_503():
    with patch("app.payments.store_apple.get_settings", return_value=_apple_settings(
        apple_iap_issuer_id="",
        apple_iap_key_id="",
        apple_iap_private_key="",
    )):
        with pytest.raises(HTTPException) as exc:
            await verify_apple_purchase(
                product_id="quizverse_premium",
                purchase_token="txn",
            )
    assert exc.value.status_code == 503


@pytest.mark.asyncio
async def test_apple_verify_success():
    signed = _jws(
        {
            "productId": "quizverse_premium",
            "originalTransactionId": "orig_1",
            "transactionId": "txn_1",
            "bundleId": "com.quizverse.app",
        }
    )
    response = httpx.Response(
        200,
        json={"signedTransactionInfo": signed},
        request=httpx.Request("GET", "https://example.test"),
    )
    client = AsyncMock()
    client.get = AsyncMock(return_value=response)

    with (
        patch("app.payments.store_apple.get_settings", return_value=_apple_settings()),
        patch("app.payments.store_apple.build_app_store_token", return_value="jwt"),
    ):
        verified = await verify_apple_purchase(
            product_id="quizverse_premium",
            purchase_token="txn_1",
            client=client,
        )

    assert isinstance(verified, VerifiedPurchase)
    assert verified.product_id == "quizverse_premium"
    assert verified.original_transaction_id == "orig_1"


@pytest.mark.asyncio
async def test_apple_wrong_product_400():
    signed = _jws(
        {
            "productId": "other_sku",
            "originalTransactionId": "orig_1",
            "bundleId": "com.quizverse.app",
        }
    )
    response = httpx.Response(
        200,
        json={"signedTransactionInfo": signed},
        request=httpx.Request("GET", "https://example.test"),
    )
    client = AsyncMock()
    client.get = AsyncMock(return_value=response)

    with (
        patch("app.payments.store_apple.get_settings", return_value=_apple_settings()),
        patch("app.payments.store_apple.build_app_store_token", return_value="jwt"),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_apple_purchase(
                product_id="quizverse_premium",
                purchase_token="txn_1",
                client=client,
            )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_google_missing_creds_503():
    with patch(
        "app.payments.store_google.get_settings",
        return_value=_google_settings(google_play_service_account_json=""),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_google_purchase(
                product_id="quizverse_premium",
                purchase_token="tok",
            )
    assert exc.value.status_code == 503


@pytest.mark.asyncio
async def test_google_verify_success():
    response = httpx.Response(
        200,
        json={"purchaseState": 0, "orderId": "GPA.1234"},
        request=httpx.Request("GET", "https://example.test"),
    )
    client = AsyncMock()
    client.get = AsyncMock(return_value=response)

    with patch(
        "app.payments.store_google.get_settings",
        return_value=_google_settings(),
    ):
        verified = await verify_google_purchase(
            product_id="quizverse_premium",
            purchase_token="play_token",
            client=client,
            access_token="ya29.test",
        )

    assert verified.original_transaction_id == "GPA.1234"
    assert verified.product_id == "quizverse_premium"


@pytest.mark.asyncio
async def test_google_canceled_402():
    response = httpx.Response(
        200,
        json={"purchaseState": 1, "orderId": "GPA.x"},
        request=httpx.Request("GET", "https://example.test"),
    )
    client = AsyncMock()
    client.get = AsyncMock(return_value=response)

    with patch(
        "app.payments.store_google.get_settings",
        return_value=_google_settings(),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_google_purchase(
                product_id="quizverse_premium",
                purchase_token="play_token",
                client=client,
                access_token="ya29.test",
            )
    assert exc.value.status_code == 402


@pytest.mark.asyncio
async def test_billing_apple_google_missing_creds_503():
    db = MagicMock()
    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "quizverse_premium"
        settings.billing_verify_mode = "apple_google"
        settings.is_production = False
        with patch(
            "app.payments.billing.verify_apple_purchase",
            new=AsyncMock(
                side_effect=HTTPException(
                    status_code=503,
                    detail="Apple IAP not configured",
                )
            ),
        ):
            with pytest.raises(HTTPException) as exc:
                await verify_and_grant(
                    db,
                    _user(),
                    platform="ios",
                    product_id="quizverse_premium",
                    purchase_token="tok",
                )
    assert exc.value.status_code == 503


@pytest.mark.asyncio
async def test_billing_apple_google_grants_on_verified():
    user = _user()
    db = MagicMock()
    db.scalar = AsyncMock(return_value=None)
    db.add = MagicMock()
    db.flush = AsyncMock()

    verified = VerifiedPurchase(
        product_id="quizverse_premium",
        original_transaction_id="store_txn_9",
        expires_at=None,
    )

    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "quizverse_premium"
        settings.billing_verify_mode = "apple_google"
        settings.is_production = False
        with patch(
            "app.payments.billing.verify_google_purchase",
            new=AsyncMock(return_value=verified),
        ):
            out = await verify_and_grant(
                db,
                user,
                platform="android",
                product_id="quizverse_premium",
                purchase_token="play_tok",
            )

    assert out.is_premium is True
    sub = db.add.call_args[0][0]
    assert sub.original_transaction_id == "store_txn_9"
    assert sub.status == SubscriptionStatus.ACTIVE
    assert sub.entitlements.get("verify_mode") == "apple_google"
