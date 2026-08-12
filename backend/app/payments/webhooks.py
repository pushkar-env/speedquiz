"""Store server notification handling.

Without these, a subscription is only as current as the last time the app
happened to call verify: renewals would be invisible, cancellations would keep
granting premium until expiry, and refunds would never revoke anything.

Both handlers follow the same shape:

1. Authenticate the request (Apple: JWS signature; Google: Pub/Sub auth).
2. Record the event, keyed on the store's own id, so redelivery is a no-op.
3. Re-fetch the subscription from the store API and persist *that*.

Step 3 is what makes step 1 survivable. Even a perfectly forged notification
can only ask us to re-read a purchase token from the store, and the store will
say "no such purchase" or return the real state.
"""

from __future__ import annotations

import base64
import binascii
import json
from datetime import datetime, timezone
from typing import Any, Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.exc import IntegrityError

from app.core.logging import get_logger
from app.models import BillingEvent, Subscription
from app.payments import billing
from app.payments.apple_jws import AppleJwsError, verify_and_decode
from app.payments.plans import plan_for_product
from app.payments.store_apple import build_verified_subscription as build_apple_subscription
from app.payments.store_apple import decode_signed_transaction

logger = get_logger(__name__)


class WebhookRejected(Exception):
    """The request could not be authenticated — respond 4xx, do not retry."""


#: Play notification type ids we act on. Everything else is logged only.
GOOGLE_SUBSCRIPTION_TYPES = {
    1: "SUBSCRIPTION_RECOVERED",
    2: "SUBSCRIPTION_RENEWED",
    3: "SUBSCRIPTION_CANCELED",
    4: "SUBSCRIPTION_PURCHASED",
    5: "SUBSCRIPTION_ON_HOLD",
    6: "SUBSCRIPTION_IN_GRACE_PERIOD",
    7: "SUBSCRIPTION_RESTARTED",
    8: "SUBSCRIPTION_PRICE_CHANGE_CONFIRMED",
    9: "SUBSCRIPTION_DEFERRED",
    10: "SUBSCRIPTION_PAUSED",
    11: "SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED",
    12: "SUBSCRIPTION_REVOKED",
    13: "SUBSCRIPTION_EXPIRED",
    20: "SUBSCRIPTION_PENDING_PURCHASE_CANCELED",
}

#: Apple notification types that mean "the money came back".
APPLE_REVOKING_TYPES = {"REFUND", "REVOKE"}


async def _record_event(
    db: AsyncSession,
    *,
    provider: str,
    event_id: str,
    notification_type: Optional[str],
    subtype: Optional[str],
    store_subscription_id: Optional[str],
    product_id: Optional[str],
    payload: dict[str, Any],
) -> Optional[BillingEvent]:
    """Insert the event, or return None when it is a redelivery.

    The unique constraint on (provider, event_id) is the idempotency
    mechanism. A savepoint keeps the conflict from poisoning the outer
    transaction, which still has to serve the rest of the request.
    """
    existing = await db.scalar(
        select(BillingEvent).where(
            BillingEvent.provider == provider,
            BillingEvent.event_id == event_id,
        )
    )
    if existing is not None:
        logger.info("billing_event_duplicate", provider=provider, event_id=event_id)
        return None

    event = BillingEvent(
        provider=provider,
        event_id=event_id,
        notification_type=notification_type,
        subtype=subtype,
        store_subscription_id=store_subscription_id,
        product_id=product_id,
        payload=payload,
    )
    try:
        async with db.begin_nested():
            db.add(event)
            await db.flush()
    except IntegrityError:
        # Two deliveries raced; the other one wins.
        logger.info("billing_event_race", provider=provider, event_id=event_id)
        return None
    return event


def _decode_pubsub_message(body: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Unwrap a Pub/Sub push envelope into (messageId, DeveloperNotification)."""
    message = body.get("message")
    if not isinstance(message, dict):
        raise WebhookRejected("Pub/Sub envelope missing message")

    message_id = str(message.get("messageId") or message.get("message_id") or "")
    if not message_id:
        raise WebhookRejected("Pub/Sub message missing messageId")

    data = message.get("data")
    if not data:
        raise WebhookRejected("Pub/Sub message missing data")

    try:
        decoded = base64.b64decode(data)
        notification = json.loads(decoded)
    except (binascii.Error, ValueError, json.JSONDecodeError) as exc:
        raise WebhookRejected("Pub/Sub data is not base64 JSON") from exc

    if not isinstance(notification, dict):
        raise WebhookRejected("Developer notification must be an object")
    return message_id, notification


async def handle_google_notification(
    db: AsyncSession,
    body: dict[str, Any],
) -> dict[str, Any]:
    """Process one Play Real-Time Developer Notification."""
    message_id, notification = _decode_pubsub_message(body)

    if "testNotification" in notification:
        logger.info("play_test_notification", message_id=message_id)
        return {"status": "ok", "handled": "test"}

    subscription_notification = notification.get("subscriptionNotification")
    voided = notification.get("voidedPurchaseNotification")

    if isinstance(voided, dict):
        return await _handle_google_voided(db, message_id, notification, voided)

    if not isinstance(subscription_notification, dict):
        # One-time product notifications: nothing we sell any more.
        logger.info("play_notification_ignored", message_id=message_id)
        return {"status": "ok", "handled": "ignored"}

    purchase_token = str(subscription_notification.get("purchaseToken") or "")
    product_id = str(subscription_notification.get("subscriptionId") or "")
    raw_type = subscription_notification.get("notificationType")
    try:
        type_name = GOOGLE_SUBSCRIPTION_TYPES.get(int(raw_type), str(raw_type))
    except (TypeError, ValueError):
        type_name = str(raw_type)

    if not purchase_token:
        raise WebhookRejected("Subscription notification missing purchaseToken")

    event = await _record_event(
        db,
        provider="google",
        event_id=message_id,
        notification_type=type_name,
        subtype=None,
        store_subscription_id=purchase_token,
        product_id=product_id,
        payload=notification,
    )
    if event is None:
        return {"status": "ok", "handled": "duplicate"}

    if plan_for_product(product_id) is None:
        event.processed_at = datetime.now(timezone.utc)
        event.error = f"unknown product {product_id}"
        await db.flush()
        return {"status": "ok", "handled": "unknown_product"}

    subscription = await billing.sync_subscription_from_store(
        db,
        platform="android",
        product_id=product_id,
        purchase_token=purchase_token,
    )

    event.processed_at = datetime.now(timezone.utc)
    if subscription is not None:
        event.subscription_id = subscription.id
        event.user_id = subscription.user_id
    else:
        event.error = "no matching account"
    await db.flush()

    logger.info(
        "play_notification_processed",
        message_id=message_id,
        notification_type=type_name,
        matched=subscription is not None,
    )
    return {"status": "ok", "handled": type_name}


async def _handle_google_voided(
    db: AsyncSession,
    message_id: str,
    notification: dict[str, Any],
    voided: dict[str, Any],
) -> dict[str, Any]:
    """Refund / chargeback — revoke immediately."""
    purchase_token = str(voided.get("purchaseToken") or "")
    event = await _record_event(
        db,
        provider="google",
        event_id=message_id,
        notification_type="VOIDED_PURCHASE",
        subtype=str(voided.get("refundType") or "") or None,
        store_subscription_id=purchase_token or None,
        product_id=None,
        payload=notification,
    )
    if event is None:
        return {"status": "ok", "handled": "duplicate"}

    subscription = None
    if purchase_token:
        subscription = await db.scalar(
            select(Subscription).where(
                Subscription.platform == "android",
                Subscription.purchase_token == purchase_token,
            )
        ) or await db.scalar(
            select(Subscription).where(
                Subscription.platform == "android",
                Subscription.store_subscription_id == purchase_token,
            )
        )

    if subscription is not None:
        await billing.revoke_subscription(db, subscription, reason="play_voided")
        event.subscription_id = subscription.id
        event.user_id = subscription.user_id
    else:
        event.error = "no matching subscription"

    event.processed_at = datetime.now(timezone.utc)
    await db.flush()
    return {"status": "ok", "handled": "VOIDED_PURCHASE"}


async def handle_apple_notification(
    db: AsyncSession,
    signed_payload: str,
) -> dict[str, Any]:
    """Process one App Store Server Notification V2.

    The signature is verified before anything is read from the payload — an
    unverified notification is treated as hostile input, not as data.
    """
    try:
        payload = verify_and_decode(signed_payload)
    except AppleJwsError as exc:
        raise WebhookRejected(str(exc)) from exc

    notification_type = str(payload.get("notificationType") or "")
    subtype = str(payload.get("subtype") or "") or None
    notification_uuid = str(payload.get("notificationUUID") or "")
    if not notification_uuid:
        raise WebhookRejected("Apple notification missing notificationUUID")

    data = payload.get("data")
    data = data if isinstance(data, dict) else {}

    if notification_type == "TEST":
        await _record_event(
            db,
            provider="apple",
            event_id=notification_uuid,
            notification_type=notification_type,
            subtype=subtype,
            store_subscription_id=None,
            product_id=None,
            payload={"notificationType": notification_type},
        )
        logger.info("apple_test_notification", notification_uuid=notification_uuid)
        return {"status": "ok", "handled": "test"}

    signed_transaction = data.get("signedTransactionInfo")
    if not signed_transaction:
        logger.info(
            "apple_notification_without_transaction",
            notification_type=notification_type,
        )
        return {"status": "ok", "handled": "ignored"}

    # The inner JWSs are part of the payload we already verified, so decoding
    # them without a second signature check is safe here.
    transaction = decode_signed_transaction(signed_transaction)
    renewal = (
        decode_signed_transaction(data["signedRenewalInfo"])
        if data.get("signedRenewalInfo")
        else {}
    )

    product_id = str(transaction.get("productId") or "")
    original_txn = str(
        transaction.get("originalTransactionId") or transaction.get("transactionId") or ""
    )

    event = await _record_event(
        db,
        provider="apple",
        event_id=notification_uuid,
        notification_type=notification_type,
        subtype=subtype,
        store_subscription_id=original_txn or None,
        product_id=product_id or None,
        payload={
            "notificationType": notification_type,
            "subtype": subtype,
            "environment": data.get("environment"),
            "bundleId": data.get("bundleId"),
            "productId": product_id,
            "originalTransactionId": original_txn,
        },
    )
    if event is None:
        return {"status": "ok", "handled": "duplicate"}

    if plan_for_product(product_id) is None:
        event.processed_at = datetime.now(timezone.utc)
        event.error = f"unknown product {product_id}"
        await db.flush()
        return {"status": "ok", "handled": "unknown_product"}

    subscription: Optional[Subscription] = None

    if notification_type in APPLE_REVOKING_TYPES:
        # Refunds are terminal; the notification carries everything needed and
        # the status endpoint may still report the subscription as active.
        subscription = await db.scalar(
            select(Subscription).where(
                Subscription.platform == "ios",
                Subscription.store_subscription_id == original_txn,
            )
        )
        if subscription is not None:
            await billing.revoke_subscription(
                db, subscription, reason=notification_type.lower()
            )
    else:
        subscription = await billing.sync_subscription_from_store(
            db,
            platform="ios",
            product_id=product_id,
            purchase_token=original_txn,
            original_transaction_id=original_txn,
            account_token=str(transaction.get("appAccountToken") or "") or None,
        )
        if subscription is None:
            # The store API could not attribute it; fall back to the signed
            # payload we already trust so a renewal is not silently dropped.
            subscription = await _apply_apple_payload(
                db,
                transaction=transaction,
                renewal=renewal,
                original_txn=original_txn,
            )

    event.processed_at = datetime.now(timezone.utc)
    if subscription is not None:
        event.subscription_id = subscription.id
        event.user_id = subscription.user_id
    else:
        event.error = "no matching account"
    await db.flush()

    logger.info(
        "apple_notification_processed",
        notification_uuid=notification_uuid,
        notification_type=notification_type,
        subtype=subtype,
        matched=subscription is not None,
    )
    return {"status": "ok", "handled": notification_type}


async def _apply_apple_payload(
    db: AsyncSession,
    *,
    transaction: dict[str, Any],
    renewal: dict[str, Any],
    original_txn: str,
) -> Optional[Subscription]:
    """Update an existing row straight from a verified notification."""
    existing = await db.scalar(
        select(Subscription).where(
            Subscription.platform == "ios",
            Subscription.store_subscription_id == original_txn,
        )
    )
    if existing is None:
        return None

    from app.models import User

    owner = await db.scalar(select(User).where(User.id == existing.user_id))
    if owner is None:
        return None

    verified = build_apple_subscription(transaction=transaction, renewal=renewal)
    subscription = await billing.upsert_verified_subscription(db, owner, verified)
    await billing.refresh_premium_flag(db, owner)
    return subscription
