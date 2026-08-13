"""Firebase Cloud Messaging, HTTP v1.

Authentication is a service-account JWT exchanged for an access token — the
same shape as `app.payments.store_google`, and for the same reason: it needs no
extra client library, and the one dependency the Firebase Admin SDK would add
is a large one for a single POST.

Not configured is a supported state
-----------------------------------
With no service account, [send] returns a no-op result instead of raising. A
deployment without a Firebase project still has a working multiplayer feature —
the in-app inbox carries every notification — it is just quieter. Treating
missing push as a fatal misconfiguration would make the feature undeployable
until somebody finishes a console wizard.

Token retirement
----------------
FCM answers UNREGISTERED / INVALID_ARGUMENT for tokens that will never work
again — an uninstalled app, a wiped device. Those are reported back so the
caller can deactivate the row rather than retrying them forever, which is how
a token table turns into a slow, permanent source of errors.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import httpx
from jose import jwt

from app.core.config import get_settings
from app.core.logging import get_logger

logger = get_logger(__name__)

_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
_TOKEN_URL = "https://oauth2.googleapis.com/token"
_SEND_URL = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"

#: Refresh a little before the hour is up, so a send never races expiry.
_TOKEN_SAFETY_MARGIN_SECONDS = 120

#: Errors that mean "this token is dead", as opposed to "try again later".
_PERMANENT_ERRORS = frozenset(
    {"UNREGISTERED", "INVALID_ARGUMENT", "SENDER_ID_MISMATCH"}
)


@dataclass
class PushResult:
    sent: int = 0
    failed: int = 0
    #: Tokens the caller should deactivate — they will never deliver again.
    dead_tokens: list[str] = field(default_factory=list)
    #: True when push is not configured, so callers can distinguish "nothing to
    #: do" from "tried and failed".
    skipped: bool = False


@dataclass
class PushMessage:
    title: str
    body: str
    #: Data payload the app reads to route the tap. Values must be strings —
    #: FCM rejects anything else in the `data` map.
    data: dict[str, str] = field(default_factory=dict)
    #: Collapse key. A second "your turn" for the same match replaces the
    #: first in the tray rather than stacking.
    collapse_key: Optional[str] = None
    #: Android notification channel; must exist in the app or the notification
    #: is dropped silently on Android 8+.
    channel_id: str = "speedquiz_multiplayer"
    high_priority: bool = True


class _TokenCache:
    """One access token per process, refreshed just before it expires."""

    def __init__(self) -> None:
        self._token: Optional[str] = None
        self._expires_at: float = 0.0

    def get(self) -> Optional[str]:
        if self._token and time.time() < self._expires_at:
            return self._token
        return None

    def set(self, token: str, expires_in: int) -> None:
        self._token = token
        self._expires_at = time.time() + max(60, expires_in - _TOKEN_SAFETY_MARGIN_SECONDS)

    def clear(self) -> None:
        self._token = None
        self._expires_at = 0.0


_token_cache = _TokenCache()


def _service_account() -> Optional[dict[str, Any]]:
    raw = (get_settings().fcm_service_account_json or "").strip()
    if not raw:
        return None
    try:
        info = json.loads(raw)
    except json.JSONDecodeError:
        logger.error("fcm_service_account_invalid_json")
        return None
    return info if isinstance(info, dict) else None


def project_id() -> Optional[str]:
    settings = get_settings()
    if settings.fcm_project_id.strip():
        return settings.fcm_project_id.strip()
    info = _service_account()
    return info.get("project_id") if info else None


async def _access_token(client: httpx.AsyncClient) -> Optional[str]:
    cached = _token_cache.get()
    if cached:
        return cached

    info = _service_account()
    if not info:
        return None
    email = info.get("client_email")
    private_key = info.get("private_key")
    if not email or not private_key:
        logger.error("fcm_service_account_missing_fields")
        return None

    issued = int(time.time())
    assertion = jwt.encode(
        {
            "iss": email,
            "scope": _SCOPE,
            "aud": _TOKEN_URL,
            "iat": issued,
            "exp": issued + 3600,
        },
        private_key,
        algorithm="RS256",
    )
    try:
        response = await client.post(
            _TOKEN_URL,
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
    except httpx.HTTPError as exc:
        logger.warning("fcm_oauth_unreachable", error=str(exc))
        return None

    if response.status_code >= 400:
        logger.warning("fcm_oauth_failed", status=response.status_code)
        return None

    body = response.json()
    token = body.get("access_token")
    if not token:
        return None
    _token_cache.set(token, int(body.get("expires_in", 3600)))
    return token


def _envelope(token: str, message: PushMessage) -> dict[str, Any]:
    return {
        "message": {
            "token": token,
            "notification": {"title": message.title, "body": message.body},
            "data": {k: str(v) for k, v in message.data.items()},
            "android": {
                "priority": "HIGH" if message.high_priority else "NORMAL",
                "collapse_key": message.collapse_key,
                "notification": {
                    "channel_id": message.channel_id,
                    # Tapping opens the app and hands the data payload to the
                    # Flutter side, which routes on `deep_link`.
                    "click_action": "FLUTTER_NOTIFICATION_CLICK",
                },
            },
            "apns": {
                "headers": {
                    "apns-priority": "10" if message.high_priority else "5",
                    **(
                        {"apns-collapse-id": message.collapse_key}
                        if message.collapse_key
                        else {}
                    ),
                },
                "payload": {"aps": {"sound": "default", "content-available": 1}},
            },
        }
    }


async def send(tokens: list[str], message: PushMessage) -> PushResult:
    """Deliver `message` to each token. Never raises.

    Sends are sequential rather than gathered. A push is not on any user's
    critical path, and a burst of parallel requests to FCM from every replica
    at once is a good way to earn a rate limit that *is* felt.
    """
    result = PushResult()
    settings = get_settings()
    if not settings.push_delivery_enabled or not tokens:
        result.skipped = True
        return result

    project = project_id()
    if not project:
        logger.warning("fcm_project_id_missing")
        result.skipped = True
        return result

    url = _SEND_URL.format(project=project)
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            access_token = await _access_token(client)
            if not access_token:
                result.skipped = True
                return result

            headers = {"Authorization": f"Bearer {access_token}"}
            for token in tokens:
                try:
                    response = await client.post(
                        url, headers=headers, json=_envelope(token, message)
                    )
                except httpx.HTTPError as exc:
                    logger.warning("fcm_send_unreachable", error=str(exc))
                    result.failed += 1
                    continue

                if response.status_code == 200:
                    result.sent += 1
                    continue

                if response.status_code == 401:
                    # A token that expired between the fetch and the send.
                    # Drop the cache so the next call re-authenticates.
                    _token_cache.clear()

                result.failed += 1
                reason = _error_status(response)
                if reason in _PERMANENT_ERRORS:
                    result.dead_tokens.append(token)
                else:
                    logger.warning(
                        "fcm_send_failed", status=response.status_code, reason=reason
                    )
    except Exception as exc:  # noqa: BLE001 — push must never fail a request
        logger.warning("fcm_send_error", error=str(exc))
    return result


def _error_status(response: httpx.Response) -> str:
    try:
        body = response.json()
    except (ValueError, TypeError):
        return "UNKNOWN"
    error = body.get("error") or {}
    for detail in error.get("details") or []:
        if detail.get("@type", "").endswith("FcmError"):
            return str(detail.get("errorCode", "UNKNOWN"))
    return str(error.get("status", "UNKNOWN"))
