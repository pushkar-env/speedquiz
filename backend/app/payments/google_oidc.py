"""Verification of the OIDC token on a Pub/Sub push request.

When a Pub/Sub push subscription is configured with a service account, Google
signs each delivery with a short-lived OIDC token in the `Authorization`
header. Checking it proves the request came from Google's infrastructure and
was addressed to *our* endpoint, which a shared secret in a URL cannot do
(URLs leak into logs, proxies and browser history).

Google's signing keys rotate, so the JWKS is fetched and cached rather than
pinned.
"""

from __future__ import annotations

import time
from typing import Any, Optional

import httpx
from jose import jwt
from jose.exceptions import JWTError

from app.core.logging import get_logger

logger = get_logger(__name__)

_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs"
_VALID_ISSUERS = {"https://accounts.google.com", "accounts.google.com"}
#: Google rotates signing keys roughly daily; an hour keeps us fresh without
#: making every notification wait on a network round trip.
_CACHE_TTL_SECONDS = 3600

_jwks_cache: dict[str, Any] | None = None
_jwks_fetched_at: float = 0.0


class GoogleOidcError(Exception):
    """The token is not a valid Google-signed OIDC token for this endpoint."""


def reset_jwks_cache() -> None:
    """Drop the cached key set — used by tests."""
    global _jwks_cache, _jwks_fetched_at
    _jwks_cache = None
    _jwks_fetched_at = 0.0


async def _fetch_jwks(*, client: Optional[httpx.AsyncClient] = None) -> dict[str, Any]:
    global _jwks_cache, _jwks_fetched_at

    now = time.time()
    if _jwks_cache is not None and (now - _jwks_fetched_at) < _CACHE_TTL_SECONDS:
        return _jwks_cache

    async def _get(http: httpx.AsyncClient) -> httpx.Response:
        return await http.get(_CERTS_URL)

    try:
        if client is not None:
            response = await _get(client)
        else:
            async with httpx.AsyncClient(timeout=10.0) as http:
                response = await _get(http)
    except httpx.HTTPError as exc:
        raise GoogleOidcError(f"Could not fetch Google JWKS: {exc}") from exc

    if response.status_code >= 400:
        raise GoogleOidcError(f"Google JWKS returned {response.status_code}")

    try:
        jwks = response.json()
    except ValueError as exc:
        raise GoogleOidcError("Google JWKS is not JSON") from exc

    if not isinstance(jwks, dict) or not jwks.get("keys"):
        raise GoogleOidcError("Google JWKS has no keys")

    _jwks_cache = jwks
    _jwks_fetched_at = now
    return jwks


async def verify_pubsub_oidc_token(
    token: str,
    *,
    audience: str,
    service_account: Optional[str] = None,
    client: Optional[httpx.AsyncClient] = None,
) -> dict[str, Any]:
    """Return the token claims, or raise `GoogleOidcError`."""
    if not token:
        raise GoogleOidcError("Missing OIDC token")
    if not audience:
        raise GoogleOidcError("No expected audience configured")

    jwks = await _fetch_jwks(client=client)

    try:
        claims = jwt.decode(
            token,
            jwks,
            algorithms=["RS256"],
            audience=audience,
            options={"verify_at_hash": False},
        )
    except JWTError as exc:
        raise GoogleOidcError(f"OIDC token rejected: {exc}") from exc

    issuer = str(claims.get("iss") or "")
    if issuer not in _VALID_ISSUERS:
        raise GoogleOidcError(f"Unexpected issuer {issuer!r}")

    if service_account:
        email = str(claims.get("email") or "")
        if email != service_account:
            raise GoogleOidcError(f"Unexpected service account {email!r}")
        if not claims.get("email_verified", False):
            raise GoogleOidcError("Service account email is not verified")

    return claims
