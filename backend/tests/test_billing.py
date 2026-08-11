"""IAP billing stub verification tests."""

from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.models import SubscriptionStatus
from app.payments.billing import verify_and_grant


def _user(*, premium: bool = False):
    return SimpleNamespace(id=uuid4(), is_premium=premium)


@pytest.mark.asyncio
async def test_stub_verify_grants_premium():
    user = _user()
    db = MagicMock()
    db.scalar = AsyncMock(return_value=None)
    db.add = MagicMock()
    db.flush = AsyncMock()

    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "speedquiz_premium"
        settings.billing_verify_mode = "stub"
        settings.is_production = False
        settings.billing_allow_stub_in_production = False

        out = await verify_and_grant(
            db,
            user,
            platform="android",
            product_id="speedquiz_premium",
            purchase_token="tok_abc",
            original_transaction_id="txn_1",
        )

    assert out.is_premium is True
    db.add.assert_called_once()
    sub = db.add.call_args[0][0]
    assert sub.status == SubscriptionStatus.ACTIVE
    assert sub.original_transaction_id == "txn_1"


@pytest.mark.asyncio
async def test_stub_verify_idempotent_same_txn():
    user = _user()
    existing = SimpleNamespace(
        user_id=user.id,
        status=SubscriptionStatus.EXPIRED,
        product_id="speedquiz_premium",
        platform="ios",
        entitlements={},
        expires_at=None,
    )
    db = MagicMock()
    db.scalar = AsyncMock(return_value=existing)
    db.flush = AsyncMock()

    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "speedquiz_premium"
        settings.billing_verify_mode = "stub"
        settings.is_production = False
        settings.billing_allow_stub_in_production = False

        await verify_and_grant(
            db,
            user,
            platform="ios",
            product_id="speedquiz_premium",
            purchase_token="tok",
            original_transaction_id="txn_same",
        )

    assert user.is_premium is True
    assert existing.status == SubscriptionStatus.ACTIVE
    db.add.assert_not_called()


@pytest.mark.asyncio
async def test_wrong_product_rejected():
    db = MagicMock()
    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "speedquiz_premium"
        settings.billing_verify_mode = "stub"
        settings.is_production = False
        with pytest.raises(HTTPException) as exc:
            await verify_and_grant(
                db,
                _user(),
                platform="android",
                product_id="other_sku",
                purchase_token="tok",
            )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_empty_token_rejected():
    db = MagicMock()
    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "speedquiz_premium"
        settings.billing_verify_mode = "stub"
        settings.is_production = False
        with pytest.raises(HTTPException) as exc:
            await verify_and_grant(
                db,
                _user(),
                platform="android",
                product_id="speedquiz_premium",
                purchase_token="  ",
            )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_production_stub_refused():
    db = MagicMock()
    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "speedquiz_premium"
        settings.billing_verify_mode = "stub"
        settings.is_production = True
        settings.billing_allow_stub_in_production = False
        with pytest.raises(HTTPException) as exc:
            await verify_and_grant(
                db,
                _user(),
                platform="ios",
                product_id="speedquiz_premium",
                purchase_token="tok",
            )
    assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_apple_google_mode_missing_creds_503():
    db = MagicMock()
    with patch("app.payments.billing.settings") as settings:
        settings.iap_premium_product_id = "speedquiz_premium"
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
                    product_id="speedquiz_premium",
                    purchase_token="tok",
                )
    assert exc.value.status_code == 503
