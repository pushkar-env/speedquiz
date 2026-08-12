"""Store notification handling: idempotency, attribution and auth."""

from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.api.v1.billing_webhooks import _verify_pubsub_auth
from app.models import BillingEvent, Subscription, SubscriptionStatus, User
from app.payments.webhooks import (
    WebhookRejected,
    handle_apple_notification,
    handle_google_notification,
)
from tests.fakes import FakeSession

ANNUAL = "speedquiz_premium_annual"
NOW = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)


def _envelope(notification: dict, *, message_id: str = "msg-1") -> dict:
    return {
        "message": {
            "data": base64.b64encode(json.dumps(notification).encode()).decode(),
            "messageId": message_id,
            "publishTime": "2026-08-12T12:00:00Z",
        },
        "subscription": "projects/p/subscriptions/s",
    }


def _subscription_notification(**overrides) -> dict:
    payload = {
        "version": "1.0",
        "packageName": "com.speedquiz.app",
        "eventTimeMillis": "1785500000000",
        "subscriptionNotification": {
            "version": "1.0",
            "notificationType": 2,  # SUBSCRIPTION_RENEWED
            "purchaseToken": "play_token",
            "subscriptionId": ANNUAL,
        },
    }
    payload["subscriptionNotification"].update(overrides)
    return payload


def _sub(user_id, **overrides) -> Subscription:
    values = {
        "id": uuid4(),
        "user_id": user_id,
        "platform": "android",
        "product_id": ANNUAL,
        "plan_code": "annual",
        "store_subscription_id": "play_token",
        "purchase_token": "play_token",
        "status": SubscriptionStatus.ACTIVE,
        "expires_at": NOW + timedelta(days=300),
        "grace_until": None,
        "revoked_at": None,
        "auto_renewing": True,
        "is_intro_offer": False,
        "is_test": False,
    }
    values.update(overrides)
    return Subscription(**values)


def _settings(**overrides):
    base = SimpleNamespace(
        is_production=False,
        billing_grace_period_days=3,
        google_rtdn_shared_secret="",
        google_rtdn_oidc_audience="",
        google_rtdn_oidc_service_account="",
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


# --- Google RTDN ------------------------------------------------------------


@pytest.mark.asyncio
async def test_renewal_notification_resyncs_from_the_store():
    """The notification says *what* changed; the store says what it is now."""
    db = FakeSession()
    sync = AsyncMock(return_value=_sub(uuid4()))

    with patch("app.payments.billing.sync_subscription_from_store", new=sync):
        result = await handle_google_notification(db, _envelope(_subscription_notification()))

    assert result["handled"] == "SUBSCRIPTION_RENEWED"
    sync.assert_awaited_once()
    assert sync.await_args.kwargs["purchase_token"] == "play_token"
    assert len([r for r in db.added if isinstance(r, BillingEvent)]) == 1


@pytest.mark.asyncio
async def test_redelivered_notification_is_a_no_op():
    """Pub/Sub redelivers aggressively and replays backlogs after an outage."""
    existing = BillingEvent(provider="google", event_id="msg-1", payload={})
    db = FakeSession([existing])
    sync = AsyncMock()

    with patch("app.payments.billing.sync_subscription_from_store", new=sync):
        result = await handle_google_notification(db, _envelope(_subscription_notification()))

    assert result["handled"] == "duplicate"
    sync.assert_not_awaited()


@pytest.mark.asyncio
async def test_voided_purchase_revokes_immediately():
    """A refund is money back; premium has to stop the same moment."""
    user_id = uuid4()
    subscription = _sub(user_id)
    db = FakeSession([subscription])
    revoke = AsyncMock()

    notification = {
        "version": "1.0",
        "packageName": "com.speedquiz.app",
        "voidedPurchaseNotification": {
            "purchaseToken": "play_token",
            "orderId": "GPA.1",
            "productType": 1,
            "refundType": 1,
        },
    }

    with patch("app.payments.billing.revoke_subscription", new=revoke):
        result = await handle_google_notification(db, _envelope(notification))

    assert result["handled"] == "VOIDED_PURCHASE"
    revoke.assert_awaited_once()
    assert revoke.await_args.args[1] is subscription


@pytest.mark.asyncio
async def test_test_notification_is_acknowledged_without_side_effects():
    db = FakeSession()
    sync = AsyncMock()

    with patch("app.payments.billing.sync_subscription_from_store", new=sync):
        result = await handle_google_notification(
            db, _envelope({"version": "1.0", "testNotification": {"version": "1.0"}})
        )

    assert result["handled"] == "test"
    sync.assert_not_awaited()


@pytest.mark.asyncio
async def test_notification_for_an_unknown_product_is_recorded_not_synced():
    db = FakeSession()
    sync = AsyncMock()

    with patch("app.payments.billing.sync_subscription_from_store", new=sync):
        result = await handle_google_notification(
            db, _envelope(_subscription_notification(subscriptionId="someone_elses_sku"))
        )

    assert result["handled"] == "unknown_product"
    sync.assert_not_awaited()


@pytest.mark.asyncio
async def test_malformed_envelopes_are_rejected():
    db = FakeSession()
    for body in (
        {},
        {"message": {}},
        {"message": {"messageId": "m"}},
        {"message": {"messageId": "m", "data": "!!!not base64!!!"}},
    ):
        with pytest.raises(WebhookRejected):
            await handle_google_notification(db, body)


@pytest.mark.asyncio
async def test_subscription_notification_without_token_is_rejected():
    db = FakeSession()
    with pytest.raises(WebhookRejected):
        await handle_google_notification(
            db, _envelope(_subscription_notification(purchaseToken=""))
        )


# --- Apple ASSN v2 ----------------------------------------------------------


def _apple_payload(**overrides) -> dict:
    payload = {
        "notificationType": "DID_RENEW",
        "subtype": None,
        "notificationUUID": "uuid-1",
        "version": "2.0",
        "data": {
            "bundleId": "com.speedquiz.app",
            "environment": "Production",
            "signedTransactionInfo": "signed-txn",
            "signedRenewalInfo": "signed-renewal",
        },
    }
    payload.update(overrides)
    return payload


def _apple_patches(payload: dict, transaction: dict | None = None):
    transaction = transaction or {
        "productId": ANNUAL,
        "originalTransactionId": "orig_1",
        "transactionId": "txn_1",
    }
    return (
        patch("app.payments.webhooks.verify_and_decode", return_value=payload),
        patch(
            "app.payments.webhooks.decode_signed_transaction",
            side_effect=lambda jws: transaction if jws == "signed-txn" else {},
        ),
    )


@pytest.mark.asyncio
async def test_apple_renewal_resyncs_from_the_store():
    db = FakeSession()
    sync = AsyncMock(return_value=_sub(uuid4(), platform="ios"))
    verify_patch, decode_patch = _apple_patches(_apple_payload())

    with verify_patch, decode_patch, patch(
        "app.payments.billing.sync_subscription_from_store", new=sync
    ):
        result = await handle_apple_notification(db, "jws")

    assert result["handled"] == "DID_RENEW"
    sync.assert_awaited_once()


@pytest.mark.asyncio
async def test_apple_refund_revokes_without_calling_the_store():
    """The status endpoint can still report active right after a refund."""
    subscription = _sub(uuid4(), platform="ios", store_subscription_id="orig_1")
    db = FakeSession([subscription])
    revoke = AsyncMock()
    verify_patch, decode_patch = _apple_patches(
        _apple_payload(notificationType="REFUND")
    )

    with verify_patch, decode_patch, patch(
        "app.payments.billing.revoke_subscription", new=revoke
    ):
        result = await handle_apple_notification(db, "jws")

    assert result["handled"] == "REFUND"
    revoke.assert_awaited_once()
    assert revoke.await_args.args[1] is subscription


@pytest.mark.asyncio
async def test_apple_duplicate_notification_uuid_is_ignored():
    existing = BillingEvent(provider="apple", event_id="uuid-1", payload={})
    db = FakeSession([existing])
    sync = AsyncMock()
    verify_patch, decode_patch = _apple_patches(_apple_payload())

    with verify_patch, decode_patch, patch(
        "app.payments.billing.sync_subscription_from_store", new=sync
    ):
        result = await handle_apple_notification(db, "jws")

    assert result["handled"] == "duplicate"
    sync.assert_not_awaited()


@pytest.mark.asyncio
async def test_apple_unverifiable_payload_is_rejected():
    """An unsigned notification must never reach the billing tables."""
    from app.payments.apple_jws import AppleJwsError

    db = FakeSession()
    with patch(
        "app.payments.webhooks.verify_and_decode",
        side_effect=AppleJwsError("bad signature"),
    ):
        with pytest.raises(WebhookRejected):
            await handle_apple_notification(db, "forged")


@pytest.mark.asyncio
async def test_apple_test_notification_is_acknowledged():
    db = FakeSession()
    with patch(
        "app.payments.webhooks.verify_and_decode",
        return_value=_apple_payload(notificationType="TEST", data={}),
    ):
        result = await handle_apple_notification(db, "jws")
    assert result["handled"] == "test"


# --- Pub/Sub authentication -------------------------------------------------


@pytest.mark.asyncio
async def test_shared_secret_accepts_the_right_token():
    with patch(
        "app.api.v1.billing_webhooks.get_settings",
        return_value=_settings(google_rtdn_shared_secret="s3cret"),
    ):
        await _verify_pubsub_auth(token="s3cret", authorization=None)


@pytest.mark.asyncio
async def test_shared_secret_rejects_a_wrong_token():
    with patch(
        "app.api.v1.billing_webhooks.get_settings",
        return_value=_settings(google_rtdn_shared_secret="s3cret"),
    ):
        for bad in (None, "", "wrong"):
            with pytest.raises(HTTPException) as exc:
                await _verify_pubsub_auth(token=bad, authorization=None)
            assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_unauthenticated_endpoint_fails_closed_in_production():
    """An open endpoint that writes billing rows is not an acceptable default."""
    with patch(
        "app.api.v1.billing_webhooks.get_settings",
        return_value=_settings(is_production=True),
    ):
        with pytest.raises(HTTPException) as exc:
            await _verify_pubsub_auth(token=None, authorization=None)
        assert exc.value.status_code == 503


@pytest.mark.asyncio
async def test_local_development_allows_an_unauthenticated_push():
    with patch(
        "app.api.v1.billing_webhooks.get_settings", return_value=_settings()
    ):
        await _verify_pubsub_auth(token=None, authorization=None)


@pytest.mark.asyncio
async def test_oidc_token_is_verified_when_configured():
    verify = AsyncMock(return_value={"email": "pubsub@project.iam.gserviceaccount.com"})
    with (
        patch(
            "app.api.v1.billing_webhooks.get_settings",
            return_value=_settings(google_rtdn_oidc_audience="https://api.speedquiz.app"),
        ),
        patch("app.payments.google_oidc.verify_pubsub_oidc_token", new=verify),
    ):
        await _verify_pubsub_auth(token=None, authorization="Bearer abc.def.ghi")

    verify.assert_awaited_once()
    assert verify.await_args.kwargs["audience"] == "https://api.speedquiz.app"


@pytest.mark.asyncio
async def test_missing_oidc_header_is_rejected():
    with patch(
        "app.api.v1.billing_webhooks.get_settings",
        return_value=_settings(google_rtdn_oidc_audience="https://api.speedquiz.app"),
    ):
        with pytest.raises(HTTPException) as exc:
            await _verify_pubsub_auth(token=None, authorization=None)
        assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_shared_secret_short_circuits_before_oidc():
    """Both configured: a valid secret is enough, no JWKS round trip."""
    verify = AsyncMock()
    with (
        patch(
            "app.api.v1.billing_webhooks.get_settings",
            return_value=_settings(
                google_rtdn_shared_secret="s3cret",
                google_rtdn_oidc_audience="https://api.speedquiz.app",
            ),
        ),
        patch("app.payments.google_oidc.verify_pubsub_oidc_token", new=verify),
    ):
        await _verify_pubsub_auth(token="s3cret", authorization=None)
    verify.assert_not_awaited()
