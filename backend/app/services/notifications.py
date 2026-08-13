"""Notifications: the in-app inbox, and the push that reaches a closed app.

Two audiences, two representations
----------------------------------
The **inbox row** stores a type and a data payload, never rendered text. The
client draws it from its own compile-checked string table, which means the
inbox is correct in whatever language the app is currently set to — including
after the player switches language, when text baked in at write time would be
stale.

A **push notification** has to carry real words, because it is rendered by the
operating system with the app closed. Those are written here, in the language
recorded on the device token. The two paths therefore say the same thing twice,
in different places, on purpose.

Delivery is best-effort and never blocks
----------------------------------------
Nothing in this module raises into a request. A challenge that was created but
whose push failed is a quieter challenge, not a failed one, and the inbox row
is already committed by then.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID, uuid4

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.languages import ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.models import (
    DeviceToken,
    Notification,
    NotificationType,
    UserProfile,
)
from app.push import fcm

logger = get_logger(__name__)

#: Notification types that ignore quiet hours.
#:
#: A live match is the one thing where silence is worse than noise: the round
#: clock is running, and a player who misses the ping loses the game. Everything
#: else — a friend request, a result summary — can wait until morning.
_QUIET_HOURS_EXEMPT = frozenset({NotificationType.MATCH_YOUR_TURN})


def _now() -> datetime:
    return datetime.now(timezone.utc)


# --- Push copy --------------------------------------------------------------
#
# Kept here rather than in a general localization table because these are the
# only server-rendered player-facing strings in the codebase. Everything else
# the player reads is drawn by the client from `SqStrings`.

_COPY: dict[NotificationType, dict[str, tuple[str, str]]] = {
    NotificationType.FRIEND_REQUEST: {
        "en": ("New friend request", "{actor} wants to be friends"),
        "hi": ("नई फ़्रेंड रिक्वेस्ट", "{actor} आपसे दोस्ती करना चाहते हैं"),
    },
    NotificationType.FRIEND_ACCEPTED: {
        "en": ("Friend added", "{actor} accepted your friend request"),
        "hi": ("दोस्त जुड़ गए", "{actor} ने आपकी रिक्वेस्ट स्वीकार कर ली"),
    },
    NotificationType.MATCH_INVITE: {
        "en": ("You've been challenged", "{actor} challenged you to {topic}"),
        "hi": ("आपको चुनौती मिली है", "{actor} ने आपको {topic} में चुनौती दी है"),
    },
    NotificationType.MATCH_YOUR_TURN: {
        "en": ("Your turn", "{actor} is waiting for you to play"),
        "hi": ("आपकी बारी", "{actor} आपके खेलने का इंतज़ार कर रहे हैं"),
    },
    NotificationType.MATCH_RESULT: {
        "en": ("Match finished", "{result} against {actor}"),
        "hi": ("मैच खत्म", "{actor} के खिलाफ़ {result}"),
    },
    NotificationType.MATCH_EXPIRING: {
        "en": ("Challenge expiring", "Your match with {actor} ends soon"),
        "hi": ("चुनौती समाप्त हो रही है", "{actor} के साथ आपका मैच जल्द खत्म होगा"),
    },
}


def render_push(
    notification_type: NotificationType,
    language: ContentLanguage,
    params: dict[str, str],
) -> tuple[str, str]:
    """Title and body for a push, in `language`, falling back to English."""
    table = _COPY.get(notification_type, {})
    title, body = table.get(language.value) or table.get("en") or ("SpeedQuiz", "")
    safe = {"actor": "A player", "topic": "a quiz", "result": "Result", **params}
    try:
        return title.format(**safe), body.format(**safe)
    except (KeyError, IndexError):
        return title, body


# --- Preferences ------------------------------------------------------------


def wants(profile: Optional[UserProfile], notification_type: NotificationType) -> bool:
    """Absent means opted in, so a new type needs no backfill."""
    if profile is None:
        return True
    prefs = profile.notification_prefs or {}
    return bool(prefs.get(notification_type.value, True))


def in_quiet_hours(device: DeviceToken, at: Optional[datetime] = None) -> bool:
    """Is it the middle of the night where this device is?

    Uses the offset the client reported, because a server-side hour is the
    wrong hour for most of the world. Handles the window wrapping midnight,
    which is the normal case (22:00 to 08:00).
    """
    settings = get_settings()
    if not settings.push_quiet_hours_enabled:
        return False

    moment = at or _now()
    local_hour = (moment + timedelta(minutes=device.utc_offset_minutes)).hour
    start = settings.push_quiet_hours_start % 24
    end = settings.push_quiet_hours_end % 24
    if start == end:
        return False
    if start < end:
        return start <= local_hour < end
    return local_hour >= start or local_hour < end


# --- Writing ----------------------------------------------------------------


async def notify(
    db: AsyncSession,
    *,
    user_id: UUID,
    notification_type: NotificationType,
    actor_user_id: Optional[UUID] = None,
    match_id: Optional[UUID] = None,
    payload: Optional[dict] = None,
    deep_link: Optional[str] = None,
    push_params: Optional[dict[str, str]] = None,
) -> Optional[Notification]:
    """Record a notification and try to push it.

    The inbox row is written even when push is off or the player has opted out
    of the push for this type: opting out of an interruption is not opting out
    of being told.
    """
    profile = await db.scalar(select(UserProfile).where(UserProfile.user_id == user_id))

    row = Notification(
        id=uuid4(),
        user_id=user_id,
        type=notification_type,
        actor_user_id=actor_user_id,
        match_id=match_id,
        payload=payload or {},
        deep_link=deep_link,
    )
    db.add(row)
    await db.flush()

    if wants(profile, notification_type):
        delivered = await _push(
            db,
            user_id=user_id,
            notification=row,
            params=push_params or {},
        )
        if delivered:
            row.pushed_at = _now()
            await db.flush()
    return row


async def _push(
    db: AsyncSession,
    *,
    user_id: UUID,
    notification: Notification,
    params: dict[str, str],
) -> bool:
    settings = get_settings()
    if not settings.push_delivery_enabled:
        return False

    devices = (
        await db.execute(
            select(DeviceToken).where(
                DeviceToken.user_id == user_id, DeviceToken.is_active.is_(True)
            )
        )
    ).scalars().all()
    if not devices:
        return False

    exempt = notification.type in _QUIET_HOURS_EXEMPT
    sendable = [d for d in devices if exempt or not in_quiet_hours(d)]
    if not sendable:
        logger.info("push_suppressed_quiet_hours", user_id=str(user_id))
        return False

    data = {
        "type": notification.type.value,
        "notification_id": str(notification.id),
    }
    if notification.match_id:
        data["match_id"] = str(notification.match_id)
    if notification.deep_link:
        data["deep_link"] = notification.deep_link

    delivered = False
    # Grouped by language so a two-device player with different app languages
    # gets each device's push written correctly.
    by_language: dict[str, list[DeviceToken]] = {}
    for device in sendable:
        by_language.setdefault(normalize_language(device.language).value, []).append(device)

    for language_code, group in by_language.items():
        title, body = render_push(
            notification.type, normalize_language(language_code), params
        )
        result = await fcm.send(
            [d.token for d in group],
            fcm.PushMessage(
                title=title,
                body=body,
                data=data,
                collapse_key=(
                    f"match:{notification.match_id}" if notification.match_id else None
                ),
                high_priority=notification.type in _QUIET_HOURS_EXEMPT,
            ),
        )
        delivered = delivered or result.sent > 0
        if result.dead_tokens:
            await _retire_tokens(db, result.dead_tokens)
    return delivered


async def _retire_tokens(db: AsyncSession, tokens: list[str]) -> None:
    """Deactivate tokens FCM says will never deliver again."""
    await db.execute(
        update(DeviceToken)
        .where(DeviceToken.token.in_(tokens))
        .values(is_active=False, failure_count=DeviceToken.failure_count + 1)
    )
    await db.flush()
    logger.info("push_tokens_retired", count=len(tokens))


# --- Devices ----------------------------------------------------------------


async def register_device(
    db: AsyncSession,
    *,
    user_id: UUID,
    token: str,
    platform,
    app_version: Optional[str],
    language: ContentLanguage,
    utc_offset_minutes: int,
) -> DeviceToken:
    """Claim an FCM token for this user.

    A token identifies an *install*, not an account. If it is already on file
    for someone else, it is reassigned rather than duplicated — otherwise
    signing into a friend's phone would leave that phone receiving both
    players' challenges, which is a privacy leak, not a bug in the tray.
    """
    existing = await db.scalar(select(DeviceToken).where(DeviceToken.token == token))
    if existing is not None:
        existing.user_id = user_id
        existing.platform = platform
        existing.app_version = app_version
        existing.language = language.value
        existing.utc_offset_minutes = utc_offset_minutes
        existing.is_active = True
        existing.failure_count = 0
        existing.last_seen_at = _now()
        await db.flush()
        return existing

    row = DeviceToken(
        id=uuid4(),
        user_id=user_id,
        token=token,
        platform=platform,
        app_version=app_version,
        language=language.value,
        utc_offset_minutes=utc_offset_minutes,
        last_seen_at=_now(),
    )
    db.add(row)
    await db.flush()
    return row


async def unregister_device(db: AsyncSession, *, user_id: UUID, token: str) -> None:
    """Release a token on sign-out, so the next player on this phone is clean."""
    await db.execute(
        update(DeviceToken)
        .where(DeviceToken.token == token, DeviceToken.user_id == user_id)
        .values(is_active=False)
    )
    await db.flush()


# --- Reading ----------------------------------------------------------------


async def list_for_user(
    db: AsyncSession, user_id: UUID, *, limit: int = 40
) -> tuple[list[Notification], int]:
    rows = (
        await db.execute(
            select(Notification)
            .where(Notification.user_id == user_id)
            .order_by(Notification.created_at.desc())
            .limit(limit)
        )
    ).scalars().all()
    unread = int(
        await db.scalar(
            select(func.count())
            .select_from(Notification)
            .where(Notification.user_id == user_id, Notification.read_at.is_(None))
        )
        or 0
    )
    return list(rows), unread


async def mark_read(
    db: AsyncSession, user_id: UUID, *, notification_ids: Optional[list[UUID]] = None
) -> int:
    stmt = (
        update(Notification)
        .where(Notification.user_id == user_id, Notification.read_at.is_(None))
        .values(read_at=_now())
    )
    if notification_ids:
        stmt = stmt.where(Notification.id.in_(notification_ids))
    result = await db.execute(stmt)
    await db.flush()
    return int(result.rowcount or 0)


async def set_preferences(
    db: AsyncSession, profile: UserProfile, prefs: dict[str, bool]
) -> dict:
    """Merge, don't replace: an old client that knows three types must not
    silently reset the two it has never heard of."""
    known = {t.value for t in NotificationType}
    merged = dict(profile.notification_prefs or {})
    merged.update({k: bool(v) for k, v in prefs.items() if k in known})
    profile.notification_prefs = merged
    await db.flush()
    return merged
