"""Google Sign-In auth tests."""

from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.auth.google import GoogleIdentity, verify_google_id_token
from app.auth.deps import login_or_link_google
from app.models import AuthProvider


def _settings(**overrides):
    base = SimpleNamespace(google_client_id="")
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


@pytest.mark.asyncio
async def test_google_auth_503_when_client_id_unset():
    with patch("app.auth.google.get_settings", return_value=_settings()):
        with pytest.raises(HTTPException) as exc:
            await verify_google_id_token("a" * 40)
    assert exc.value.status_code == 503


@pytest.mark.asyncio
async def test_verify_rejects_empty_token_when_configured():
    with patch(
        "app.auth.google.get_settings",
        return_value=_settings(google_client_id="web-client.apps.googleusercontent.com"),
    ):
        with pytest.raises(HTTPException) as exc:
            await verify_google_id_token("   ")
    assert exc.value.status_code == 400


def _user(*, guest: bool = False, email=None, provider=AuthProvider.GUEST, subject=None):
    profile = SimpleNamespace(
        username="player_abc",
        display_name="player_abc",
        avatar_id="default",
        level=1,
        xp=0,
        coins=0,
        current_streak=0,
        daily_streak=0,
        best_streak=0,
        onboarding_completed=False,
        theme_preference="system",
    )
    return SimpleNamespace(
        id=uuid4(),
        email=email,
        is_guest=guest,
        is_premium=False,
        role=SimpleNamespace(value="player"),
        auth_provider=provider,
        provider_subject=subject,
        password_hash=None,
        profile=profile,
        last_login_at=None,
    )


@pytest.mark.asyncio
async def test_login_or_link_creates_google_user():
    identity = GoogleIdentity(
        subject="google-sub-1",
        email="player@gmail.com",
        email_verified=True,
        name="Player One",
    )
    db = MagicMock()
    db.scalar = AsyncMock(return_value=None)
    db.add = MagicMock()
    db.flush = AsyncMock()

    created = _user(guest=False, email="player@gmail.com", provider=AuthProvider.GOOGLE)

    async def _execute(stmt):
        # First lookups return empty; final reload returns created user
        result = MagicMock()
        # Track call count via side_effect list is cleaner
        return result

    call_count = {"n": 0}

    async def execute_side_effect(stmt):
        call_count["n"] += 1
        result = MagicMock()
        if call_count["n"] <= 2:
            result.scalar_one_or_none = MagicMock(return_value=None)
            result.scalar_one = MagicMock(side_effect=AssertionError("unexpected"))
        else:
            result.scalar_one_or_none = MagicMock(return_value=created)
            result.scalar_one = MagicMock(return_value=created)
        return result

    db.execute = AsyncMock(side_effect=execute_side_effect)

    with (
        patch("app.auth.deps._ensure_unique_username", new=AsyncMock(return_value="player_one")),
        patch("app.auth.deps.settings") as settings,
        patch("app.auth.deps.create_access_token", return_value="access"),
        patch("app.auth.deps.create_refresh_token", return_value="refresh"),
        patch(
            "app.auth.google.verify_google_id_token",
            new=AsyncMock(return_value=identity),
        ),
    ):
        settings.jwt_refresh_token_expire_days = 30
        out = await login_or_link_google(db, id_token="fake.jwt.token", guest_user=None)

    assert out.access_token == "access"
    assert out.refresh_token == "refresh"
    assert db.add.call_count >= 1


@pytest.mark.asyncio
async def test_login_or_link_upgrades_guest():
    identity = GoogleIdentity(
        subject="google-sub-2",
        email="guest@gmail.com",
        email_verified=True,
        name="Guest Up",
    )
    guest = _user(guest=True)
    db = MagicMock()
    db.scalar = AsyncMock(return_value=None)
    db.flush = AsyncMock()

    async def execute_side_effect(stmt):
        result = MagicMock()
        # lookups empty, then return guest as upgraded
        if not hasattr(execute_side_effect, "n"):
            execute_side_effect.n = 0
        execute_side_effect.n += 1
        if execute_side_effect.n == 1:
            result.scalar_one_or_none = MagicMock(return_value=None)
        elif execute_side_effect.n == 2:
            result.scalar_one_or_none = MagicMock(return_value=None)
        else:
            guest.is_guest = False
            guest.auth_provider = AuthProvider.GOOGLE
            guest.email = "guest@gmail.com"
            guest.provider_subject = "google-sub-2"
            result.scalar_one = MagicMock(return_value=guest)
            result.scalar_one_or_none = MagicMock(return_value=guest)
        return result

    db.execute = AsyncMock(side_effect=execute_side_effect)

    with (
        patch(
            "app.auth.google.verify_google_id_token",
            new=AsyncMock(return_value=identity),
        ),
        patch("app.auth.deps.settings") as settings,
        patch("app.auth.deps.create_access_token", return_value="access"),
        patch("app.auth.deps.create_refresh_token", return_value="refresh"),
    ):
        settings.jwt_refresh_token_expire_days = 30
        out = await login_or_link_google(db, id_token="fake.jwt.token", guest_user=guest)

    assert guest.auth_provider == AuthProvider.GOOGLE
    assert guest.is_guest is False
    assert guest.provider_subject == "google-sub-2"
    assert out.user.email == "guest@gmail.com"


@pytest.mark.asyncio
async def test_email_conflict_409():
    identity = GoogleIdentity(
        subject="google-sub-3",
        email="taken@gmail.com",
        email_verified=True,
    )
    owner = _user(
        guest=False,
        email="taken@gmail.com",
        provider=AuthProvider.EMAIL,
    )
    db = MagicMock()

    async def execute_side_effect(stmt):
        result = MagicMock()
        if not hasattr(execute_side_effect, "n"):
            execute_side_effect.n = 0
        execute_side_effect.n += 1
        if execute_side_effect.n == 1:
            result.scalar_one_or_none = MagicMock(return_value=None)  # no google sub
        else:
            result.scalar_one_or_none = MagicMock(return_value=owner)
        return result

    db.execute = AsyncMock(side_effect=execute_side_effect)

    with patch(
        "app.auth.google.verify_google_id_token",
        new=AsyncMock(return_value=identity),
    ):
        with pytest.raises(HTTPException) as exc:
            await login_or_link_google(db, id_token="fake.jwt.token", guest_user=None)
    assert exc.value.status_code == 409
