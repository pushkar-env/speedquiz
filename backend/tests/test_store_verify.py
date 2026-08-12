"""Store verification adapters — Play subscriptionsv2 and App Store Server API."""

from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from fastapi import HTTPException

from app.payments.store_apple import verify_apple_purchase
from app.payments.store_google import (
    _rfc3339_to_dt,
    acknowledge_google_subscription,
    verify_google_purchase,
)
from app.payments.store_types import StoreState, VerifiedSubscription

MONTHLY = "speedquiz_premium_monthly"
ANNUAL = "speedquiz_premium_annual"
LEGACY = "speedquiz_premium"


# --- helpers ---------------------------------------------------------------


def _jws(payload: dict) -> str:
    """A JWS whose payload is readable without signature verification.

    Legitimate for the polling path: those values arrive over an authenticated
    TLS call to Apple, so the connection establishes Apple's identity.
    """
    header = base64.urlsafe_b64encode(b'{"alg":"ES256","typ":"JWT"}').rstrip(b"=").decode()
    body = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=").decode()
    return f"{header}.{body}.signature"


def _apple_settings(**overrides):
    base = SimpleNamespace(
        apple_iap_issuer_id="issuer",
        apple_iap_key_id="key",
        apple_iap_private_key="-----BEGIN PRIVATE KEY-----\nX\n-----END PRIVATE KEY-----",
        apple_iap_bundle_id="com.speedquiz.app",
        apple_iap_environment="Production",
        apple_iap_configured=True,
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


def _google_settings(**overrides):
    base = SimpleNamespace(
        iap_android_package="com.speedquiz.app",
        app_link_android_package="com.speedquiz.app",
        google_play_service_account_json='{"type":"service_account","client_email":"a@b.c"}',
        google_play_configured=True,
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


def _play_body(**overrides) -> dict:
    body = {
        "kind": "androidpublisher#subscriptionPurchaseV2",
        "regionCode": "IN",
        "startTime": "2026-08-01T10:00:00.000Z",
        "subscriptionState": "SUBSCRIPTION_STATE_ACTIVE",
        "latestOrderId": "GPA.3333-1111-2222-33333",
        "acknowledgementState": "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
        "lineItems": [
            {
                "productId": ANNUAL,
                "expiryTime": "2027-08-01T10:00:00.000Z",
                "autoRenewingPlan": {"autoRenewEnabled": True},
            }
        ],
    }
    body.update(overrides)
    return body


def _play_client(body: dict, *, status_code: int = 200):
    response = httpx.Response(
        status_code, json=body, request=httpx.Request("GET", "https://example.test")
    )
    client = AsyncMock()
    client.request = AsyncMock(return_value=response)
    return client


async def _verify_play(body: dict, *, product_id: str = ANNUAL, token: str = "tok"):
    with patch(
        "app.payments.store_google.get_settings", return_value=_google_settings()
    ):
        return await verify_google_purchase(
            product_id=product_id,
            purchase_token=token,
            client=_play_client(body),
            access_token="ya29.test",
        )


def _apple_body(transaction: dict, renewal: dict | None = None, *, status_code: int = 1):
    return {
        "environment": "Production",
        "bundleId": "com.speedquiz.app",
        "data": [
            {
                "subscriptionGroupIdentifier": "21234567",
                "lastTransactions": [
                    {
                        "originalTransactionId": transaction.get(
                            "originalTransactionId", "orig_1"
                        ),
                        "status": status_code,
                        "signedTransactionInfo": _jws(transaction),
                        "signedRenewalInfo": _jws(renewal or {}),
                    }
                ],
            }
        ],
    }


def _apple_transaction(**overrides) -> dict:
    base = {
        "productId": ANNUAL,
        "originalTransactionId": "orig_1",
        "transactionId": "txn_9",
        "bundleId": "com.speedquiz.app",
        "purchaseDate": 1754000000000,
        "originalPurchaseDate": 1754000000000,
        "expiresDate": 1785536000000,
        "type": "Auto-Renewable Subscription",
        "environment": "Production",
        "storefront": "USA",
        "currency": "USD",
        "price": 49990,
    }
    base.update(overrides)
    return base


async def _verify_apple(body: dict, *, product_id: str = ANNUAL):
    client = AsyncMock()
    client.get = AsyncMock(
        return_value=httpx.Response(
            200, json=body, request=httpx.Request("GET", "https://example.test")
        )
    )
    with (
        patch("app.payments.store_apple.get_settings", return_value=_apple_settings()),
        patch("app.payments.store_apple.build_app_store_token", return_value="jwt"),
    ):
        return await verify_apple_purchase(
            product_id=product_id, purchase_token="orig_1", client=client
        )


# --- Google Play -----------------------------------------------------------


@pytest.mark.asyncio
async def test_play_active_subscription_maps_to_active():
    verified = await _verify_play(_play_body())

    assert isinstance(verified, VerifiedSubscription)
    assert verified.state is StoreState.ACTIVE
    assert verified.product_id == ANNUAL
    assert verified.plan_code == "annual"
    assert verified.auto_renewing is True
    assert verified.latest_transaction_id == "GPA.3333-1111-2222-33333"
    assert verified.needs_acknowledgement is False


@pytest.mark.asyncio
async def test_play_records_billing_region_for_revenue_reporting():
    """regionCode is how we tell an India renewal from a US one."""
    verified = await _verify_play(_play_body(regionCode="US"))
    assert verified.country == "US"


@pytest.mark.asyncio
async def test_play_auto_renew_off_reads_as_cancelled():
    """Play still says ACTIVE; the UI needs to say "ends on <date>"."""
    body = _play_body()
    body["lineItems"][0]["autoRenewingPlan"] = {"autoRenewEnabled": False}
    verified = await _verify_play(body)

    assert verified.state is StoreState.CANCELLED
    assert verified.auto_renewing is False


@pytest.mark.asyncio
async def test_play_state_mapping():
    cases = {
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": StoreState.GRACE,
        "SUBSCRIPTION_STATE_ON_HOLD": StoreState.ON_HOLD,
        "SUBSCRIPTION_STATE_PAUSED": StoreState.PAUSED,
        "SUBSCRIPTION_STATE_PENDING": StoreState.PENDING,
        "SUBSCRIPTION_STATE_EXPIRED": StoreState.EXPIRED,
        "SUBSCRIPTION_STATE_CANCELED": StoreState.CANCELLED,
    }
    for raw, expected in cases.items():
        verified = await _verify_play(_play_body(subscriptionState=raw))
        assert verified.state is expected, raw


@pytest.mark.asyncio
async def test_play_unknown_state_is_not_entitling():
    """An unrecognised state must fail closed, not grant premium."""
    verified = await _verify_play(_play_body(subscriptionState="SOMETHING_NEW"))
    assert verified.state is StoreState.EXPIRED


@pytest.mark.asyncio
async def test_play_pending_purchase_is_surfaced():
    """UPI and net banking settle asynchronously — common in India."""
    verified = await _verify_play(_play_body(subscriptionState="SUBSCRIPTION_STATE_PENDING"))
    assert verified.state is StoreState.PENDING


@pytest.mark.asyncio
async def test_play_reports_pending_acknowledgement():
    """Unacknowledged purchases are auto-refunded after three days."""
    verified = await _verify_play(
        _play_body(acknowledgementState="ACKNOWLEDGEMENT_STATE_PENDING")
    )
    assert verified.needs_acknowledgement is True


@pytest.mark.asyncio
async def test_play_surfaces_linked_purchase_token_for_plan_switches():
    verified = await _verify_play(_play_body(linkedPurchaseToken="old_token"))
    assert verified.linked_purchase_token == "old_token"


@pytest.mark.asyncio
async def test_play_surfaces_account_token_and_offer():
    body = _play_body(
        externalAccountIdentifiers={"obfuscatedExternalAccountId": "user-uuid"}
    )
    body["lineItems"][0]["offerDetails"] = {"basePlanId": "annual", "offerId": "intro50"}
    verified = await _verify_play(body)

    assert verified.account_token == "user-uuid"
    assert verified.offer_id == "intro50"
    assert verified.is_intro_offer is True


@pytest.mark.asyncio
async def test_play_licence_test_purchase_is_flagged():
    verified = await _verify_play(_play_body(testPurchase={}))
    assert verified.is_test is True
    assert verified.environment == "Sandbox"


@pytest.mark.asyncio
async def test_play_rejects_a_product_we_do_not_sell():
    body = _play_body()
    body["lineItems"][0]["productId"] = "someone_elses_sku"
    with pytest.raises(HTTPException) as exc:
        await _verify_play(body, product_id="someone_elses_sku")
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_play_missing_purchase_is_400():
    with patch(
        "app.payments.store_google.get_settings", return_value=_google_settings()
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_google_purchase(
                product_id=ANNUAL,
                purchase_token="tok",
                client=_play_client({}, status_code=404),
                access_token="ya29.test",
            )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_play_missing_credentials_503():
    with patch(
        "app.payments.store_google.get_settings",
        return_value=_google_settings(google_play_configured=False),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_google_purchase(product_id=ANNUAL, purchase_token="tok")
    assert exc.value.status_code == 503


@pytest.mark.asyncio
async def test_play_legacy_one_time_unlock_still_verifies():
    """Anyone who bought the pre-subscription unlock keeps premium."""
    with patch(
        "app.payments.store_google.get_settings", return_value=_google_settings()
    ):
        verified = await verify_google_purchase(
            product_id=LEGACY,
            purchase_token="tok",
            client=_play_client({"purchaseState": 0, "orderId": "GPA.legacy"}),
            access_token="ya29.test",
        )

    assert verified.plan_code == "legacy_lifetime"
    assert verified.state is StoreState.ACTIVE
    assert verified.expires_at is None


@pytest.mark.asyncio
async def test_acknowledge_treats_already_acknowledged_as_success():
    response = httpx.Response(
        400,
        text="The subscription purchase is already acknowledged.",
        request=httpx.Request("POST", "https://example.test"),
    )
    client = AsyncMock()
    client.request = AsyncMock(return_value=response)

    with patch(
        "app.payments.store_google.get_settings", return_value=_google_settings()
    ):
        ok = await acknowledge_google_subscription(
            product_id=ANNUAL,
            purchase_token="tok",
            client=client,
            access_token="ya29.test",
        )
    assert ok is True


def test_rfc3339_parsing_handles_nanoseconds_and_offsets():
    """Play emits more fractional digits than fromisoformat accepts."""
    assert _rfc3339_to_dt("2026-08-01T10:00:00.123456789Z") == datetime(
        2026, 8, 1, 10, 0, 0, 123456, tzinfo=timezone.utc
    )
    assert _rfc3339_to_dt("2026-08-01T10:00:00Z") == datetime(
        2026, 8, 1, 10, 0, tzinfo=timezone.utc
    )
    assert _rfc3339_to_dt("2026-08-01T15:30:00+05:30") == datetime(
        2026, 8, 1, 15, 30, tzinfo=timezone(timedelta(hours=5, minutes=30))
    )
    assert _rfc3339_to_dt("nonsense") is None
    assert _rfc3339_to_dt(None) is None


# --- Apple -----------------------------------------------------------------


@pytest.mark.asyncio
async def test_apple_active_subscription():
    verified = await _verify_apple(
        _apple_body(_apple_transaction(), {"autoRenewStatus": 1})
    )

    assert verified.state is StoreState.ACTIVE
    assert verified.product_id == ANNUAL
    assert verified.plan_code == "annual"
    assert verified.store_subscription_id == "orig_1"
    assert verified.country == "USA"
    assert verified.currency == "USD"
    # Apple quotes milliunits; we store micros.
    assert verified.price_micros == 49_990_000


@pytest.mark.asyncio
async def test_apple_auto_renew_off_is_cancelled():
    verified = await _verify_apple(
        _apple_body(_apple_transaction(), {"autoRenewStatus": 0})
    )
    assert verified.state is StoreState.CANCELLED
    assert verified.auto_renewing is False


@pytest.mark.asyncio
async def test_apple_grace_period_status():
    grace_ms = int((datetime.now(timezone.utc) + timedelta(days=10)).timestamp() * 1000)
    verified = await _verify_apple(
        _apple_body(
            _apple_transaction(),
            {"autoRenewStatus": 1, "gracePeriodExpiresDate": grace_ms},
            status_code=4,
        )
    )
    assert verified.state is StoreState.GRACE
    assert verified.grace_until is not None


@pytest.mark.asyncio
async def test_apple_billing_retry_without_grace_is_on_hold():
    verified = await _verify_apple(
        _apple_body(_apple_transaction(), {"autoRenewStatus": 1}, status_code=3)
    )
    assert verified.state is StoreState.ON_HOLD


@pytest.mark.asyncio
async def test_apple_expired_and_revoked_statuses():
    expired = await _verify_apple(
        _apple_body(_apple_transaction(), {"autoRenewStatus": 0}, status_code=2)
    )
    assert expired.state is StoreState.EXPIRED

    revoked = await _verify_apple(
        _apple_body(
            _apple_transaction(revocationDate=1754100000000),
            {"autoRenewStatus": 0},
            status_code=5,
        )
    )
    assert revoked.state is StoreState.REVOKED
    assert revoked.revoked_at is not None


@pytest.mark.asyncio
async def test_apple_intro_offer_is_recorded():
    verified = await _verify_apple(
        _apple_body(
            _apple_transaction(offerType=1, offerIdentifier="intro50"),
            {"autoRenewStatus": 1},
        )
    )
    assert verified.is_intro_offer is True
    assert verified.offer_id == "intro50"


@pytest.mark.asyncio
async def test_apple_sandbox_transaction_is_flagged_as_test():
    verified = await _verify_apple(
        _apple_body(_apple_transaction(environment="Sandbox"), {"autoRenewStatus": 1})
    )
    assert verified.is_test is True


@pytest.mark.asyncio
async def test_apple_account_token_links_purchase_to_account():
    verified = await _verify_apple(
        _apple_body(
            _apple_transaction(appAccountToken="user-uuid"), {"autoRenewStatus": 1}
        )
    )
    assert verified.account_token == "user-uuid"


@pytest.mark.asyncio
async def test_apple_rejects_a_product_we_do_not_sell():
    with pytest.raises(HTTPException) as exc:
        await _verify_apple(
            _apple_body(_apple_transaction(productId="other_sku"), {"autoRenewStatus": 1}),
            product_id="other_sku",
        )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_apple_bundle_mismatch_rejected():
    with pytest.raises(HTTPException) as exc:
        await _verify_apple(
            _apple_body(
                _apple_transaction(bundleId="com.someone.else"), {"autoRenewStatus": 1}
            )
        )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_apple_falls_back_to_the_other_environment_on_404():
    """A TestFlight tester's transaction is not in production, and vice versa."""
    found = _apple_body(_apple_transaction(), {"autoRenewStatus": 1})
    responses = [
        httpx.Response(404, request=httpx.Request("GET", "https://prod.test")),
        httpx.Response(
            200, json=found, request=httpx.Request("GET", "https://sandbox.test")
        ),
    ]
    client = AsyncMock()
    client.get = AsyncMock(side_effect=responses)

    with (
        patch("app.payments.store_apple.get_settings", return_value=_apple_settings()),
        patch("app.payments.store_apple.build_app_store_token", return_value="jwt"),
    ):
        verified = await verify_apple_purchase(
            product_id=ANNUAL, purchase_token="orig_1", client=client
        )

    assert verified.state is StoreState.ACTIVE
    assert client.get.await_count == 2


@pytest.mark.asyncio
async def test_apple_not_found_in_either_environment_is_400():
    client = AsyncMock()
    client.get = AsyncMock(
        return_value=httpx.Response(404, request=httpx.Request("GET", "https://x.test"))
    )
    with (
        patch("app.payments.store_apple.get_settings", return_value=_apple_settings()),
        patch("app.payments.store_apple.build_app_store_token", return_value="jwt"),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_apple_purchase(
                product_id=ANNUAL, purchase_token="missing", client=client
            )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_apple_missing_credentials_503():
    with patch(
        "app.payments.store_apple.get_settings",
        return_value=_apple_settings(apple_iap_configured=False),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_apple_purchase(product_id=ANNUAL, purchase_token="orig_1")
    assert exc.value.status_code == 503
