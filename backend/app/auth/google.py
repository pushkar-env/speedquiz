"""Google ID token verification via JWKS (no google-auth dependency)."""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Optional

import httpx
from fastapi import HTTPException, status
from jose import JWTError, jwk, jwt

from app.core.config import get_settings

_GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
_GOOGLE_ISSUERS = {"accounts.google.com", "https://accounts.google.com"}
_JWKS_TTL_SECONDS = 3600

_jwks_cache: dict[str, Any] = {"fetched_at": 0.0, "keys": []}


@dataclass(frozen=True)
class GoogleIdentity:
    subject: str
    email: Optional[str]
    email_verified: bool
    name: Optional[str] = None


def google_auth_configured() -> bool:
    return bool((get_settings().google_client_id or "").strip())


async def _fetch_jwks(*, client: Optional[httpx.AsyncClient] = None) -> list[dict[str, Any]]:
    now = time.time()
    if _jwks_cache["keys"] and now - float(_jwks_cache["fetched_at"]) < _JWKS_TTL_SECONDS:
        return list(_jwks_cache["keys"])

    async def _get(http: httpx.AsyncClient) -> httpx.Response:
        return await http.get(_GOOGLE_JWKS_URL)

    try:
        if client is not None:
            response = await _get(client)
        else:
            async with httpx.AsyncClient(timeout=15.0) as http:
                response = await _get(http)
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Google JWKS unreachable: {exc}",
        ) from exc

    if response.status_code >= 400:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Google JWKS failed ({response.status_code})",
        )

    body = response.json()
    keys = body.get("keys") or []
    if not isinstance(keys, list) or not keys:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Google JWKS response missing keys",
        )
    _jwks_cache["keys"] = keys
    _jwks_cache["fetched_at"] = now
    return keys


def _rsa_key_for_kid(keys: list[dict[str, Any]], kid: str) -> dict[str, Any]:
    for key in keys:
        if key.get("kid") == kid:
            return key
    # Cache may be stale after Google rotation
    raise KeyError(kid)


def clear_jwks_cache() -> None:
    _jwks_cache["keys"] = []
    _jwks_cache["fetched_at"] = 0.0


async def verify_google_id_token(
    id_token: str,
    *,
    client: Optional[httpx.AsyncClient] = None,
) -> GoogleIdentity:
    settings = get_settings()
    audience = (settings.google_client_id or "").strip()
    if not audience:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Google Sign-In not configured — set GOOGLE_CLIENT_ID",
        )

    token = (id_token or "").strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="id_token is required",
        )

    try:
        header = jwt.get_unverified_header(token)
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Google ID token header",
        ) from exc

    kid = header.get("kid")
    if not kid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Google ID token missing kid",
        )

    keys = await _fetch_jwks(client=client)
    try:
        jwk_dict = _rsa_key_for_kid(keys, kid)
    except KeyError:
        clear_jwks_cache()
        keys = await _fetch_jwks(client=client)
        try:
            jwk_dict = _rsa_key_for_kid(keys, kid)
        except KeyError as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Google ID token kid not found in JWKS",
            ) from exc

    try:
        rsa_key = jwk.construct(jwk_dict)
        claims = jwt.decode(
            token,
            rsa_key,
            algorithms=["RS256"],
            audience=audience,
            options={"verify_at_hash": False},
        )
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid Google ID token: {exc}",
        ) from exc

    iss = str(claims.get("iss") or "")
    if iss not in _GOOGLE_ISSUERS:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Google ID token issuer",
        )

    sub = str(claims.get("sub") or "").strip()
    if not sub:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Google ID token missing subject",
        )

    email = claims.get("email")
    email_str = str(email).strip().lower() if email else None
    email_verified = bool(claims.get("email_verified"))
    if email_str and not email_verified:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Google email is not verified",
        )

    name = claims.get("name")
    return GoogleIdentity(
        subject=sub,
        email=email_str,
        email_verified=email_verified,
        name=str(name) if name else None,
    )
