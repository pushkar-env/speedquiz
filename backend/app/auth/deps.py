from datetime import datetime, timedelta, timezone
from hashlib import sha256
from typing import Annotated, Optional
from uuid import UUID

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.languages import normalize_language
from app.core.config import get_settings
from app.core.database import get_db
from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    verify_password,
)
from app.models import AuthProvider, PlayerStatistics, RefreshToken, User, UserProfile, UserRole
from app.schemas.auth import GuestAuthResponse, TokenResponse, UserMeResponse

settings = get_settings()

bearer_scheme = HTTPBearer(auto_error=False)


def _username_from_seed(seed: str) -> str:
    suffix = sha256(seed.encode()).hexdigest()[:8]
    return f"player_{suffix}"


async def _ensure_unique_username(db: AsyncSession, base: str) -> str:
    candidate = base[:32]
    counter = 1
    while True:
        exists = await db.scalar(select(UserProfile.id).where(UserProfile.username == candidate))
        if not exists:
            return candidate
        candidate = f"{base[:24]}_{counter}"
        counter += 1


async def create_guest_user(db: AsyncSession, device_info: Optional[str] = None) -> GuestAuthResponse:
    user = User(
        auth_provider=AuthProvider.GUEST,
        is_guest=True,
        role=UserRole.PLAYER,
        last_login_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.flush()

    username = await _ensure_unique_username(db, _username_from_seed(str(user.id)))
    profile = UserProfile(user_id=user.id, username=username, display_name=username)
    stats = PlayerStatistics(user_id=user.id)
    db.add(profile)
    db.add(stats)

    access = create_access_token(user.id, is_guest=True)
    refresh = create_refresh_token(user.id)
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=sha256(refresh.encode()).hexdigest(),
            expires_at=datetime.now(timezone.utc)
            + timedelta(days=settings.jwt_refresh_token_expire_days),
            device_info=device_info,
        )
    )
    await db.flush()

    return GuestAuthResponse(
        access_token=access,
        refresh_token=refresh,
        token_type="bearer",
        user=UserMeResponse(
            id=user.id,
            email=None,
            is_guest=True,
            is_premium=False,
            role=user.role.value,
            username=profile.username,
            display_name=profile.display_name,
            avatar_id=profile.avatar_id,
            level=profile.level,
            xp=profile.xp,
            coins=profile.coins,
            current_streak=profile.current_streak,
            daily_streak=profile.daily_streak,
            best_streak=profile.best_streak,
            onboarding_completed=profile.onboarding_completed,
            theme_preference=profile.theme_preference,
            app_language=normalize_language(profile.app_language).value,
            quiz_language=normalize_language(profile.quiz_language).value,
        ),
    )


async def register_email_user(
    db: AsyncSession,
    email: str,
    password: str,
    username: Optional[str] = None,
) -> TokenResponse:
    existing = await db.scalar(select(User.id).where(User.email == email.lower()))
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    user = User(
        email=email.lower(),
        password_hash=hash_password(password),
        auth_provider=AuthProvider.EMAIL,
        is_guest=False,
        last_login_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.flush()

    uname = await _ensure_unique_username(
        db, username or _username_from_seed(email.lower())
    )
    profile = UserProfile(user_id=user.id, username=uname, display_name=uname)
    stats = PlayerStatistics(user_id=user.id)
    db.add(profile)
    db.add(stats)

    access = create_access_token(user.id, is_guest=False)
    refresh = create_refresh_token(user.id)
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=sha256(refresh.encode()).hexdigest(),
            expires_at=datetime.now(timezone.utc)
            + timedelta(days=settings.jwt_refresh_token_expire_days),
        )
    )
    await db.flush()

    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        token_type="bearer",
        user=_to_me(user, profile),
    )


async def login_email_user(db: AsyncSession, email: str, password: str) -> TokenResponse:
    result = await db.execute(
        select(User)
        .options(selectinload(User.profile))
        .where(User.email == email.lower(), User.is_active.is_(True))
    )
    user = result.scalar_one_or_none()
    if not user or not user.password_hash or not verify_password(password, user.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    user.last_login_at = datetime.now(timezone.utc)
    access = create_access_token(user.id, is_guest=False)
    refresh = create_refresh_token(user.id)
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=sha256(refresh.encode()).hexdigest(),
            expires_at=datetime.now(timezone.utc)
            + timedelta(days=settings.jwt_refresh_token_expire_days),
        )
    )
    await db.flush()
    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        token_type="bearer",
        user=_to_me(user, user.profile),
    )


async def upgrade_guest_to_email(
    db: AsyncSession,
    guest_user: User,
    email: str,
    password: str,
    username: Optional[str] = None,
) -> TokenResponse:
    if not guest_user.is_guest:
        raise HTTPException(status_code=400, detail="Account is already upgraded")

    existing = await db.scalar(select(User.id).where(User.email == email.lower()))
    if existing:
        raise HTTPException(status_code=409, detail="Email already registered")

    guest_user.email = email.lower()
    guest_user.password_hash = hash_password(password)
    guest_user.auth_provider = AuthProvider.EMAIL
    guest_user.is_guest = False
    guest_user.last_login_at = datetime.now(timezone.utc)

    if username and guest_user.profile:
        guest_user.profile.username = await _ensure_unique_username(db, username)
        guest_user.profile.display_name = guest_user.profile.username

    access = create_access_token(guest_user.id, is_guest=False)
    refresh = create_refresh_token(guest_user.id)
    db.add(
        RefreshToken(
            user_id=guest_user.id,
            token_hash=sha256(refresh.encode()).hexdigest(),
            expires_at=datetime.now(timezone.utc)
            + timedelta(days=settings.jwt_refresh_token_expire_days),
        )
    )
    await db.flush()
    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        token_type="bearer",
        user=_to_me(guest_user, guest_user.profile),
    )


def _to_me(user: User, profile: UserProfile) -> UserMeResponse:
    return UserMeResponse(
        id=user.id,
        email=user.email,
        is_guest=user.is_guest,
        is_premium=user.is_premium,
        role=user.role.value,
        username=profile.username,
        display_name=profile.display_name,
        avatar_id=profile.avatar_id,
        level=profile.level,
        xp=profile.xp,
        coins=profile.coins,
        current_streak=profile.current_streak,
        daily_streak=profile.daily_streak,
        best_streak=profile.best_streak,
        onboarding_completed=profile.onboarding_completed,
        theme_preference=profile.theme_preference,
        app_language=normalize_language(profile.app_language).value,
        quiz_language=normalize_language(profile.quiz_language).value,
    )


async def _issue_tokens(db: AsyncSession, user: User) -> TokenResponse:
    if not user.profile:
        result = await db.execute(
            select(User)
            .options(selectinload(User.profile))
            .where(User.id == user.id)
        )
        user = result.scalar_one()
    access = create_access_token(user.id, is_guest=user.is_guest)
    refresh = create_refresh_token(user.id)
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=sha256(refresh.encode()).hexdigest(),
            expires_at=datetime.now(timezone.utc)
            + timedelta(days=settings.jwt_refresh_token_expire_days),
        )
    )
    await db.flush()
    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        token_type="bearer",
        user=_to_me(user, user.profile),
    )


async def login_or_link_google(
    db: AsyncSession,
    *,
    id_token: str,
    guest_user: Optional[User] = None,
) -> TokenResponse:
    from app.auth.google import verify_google_id_token

    identity = await verify_google_id_token(id_token)

    existing = await db.execute(
        select(User)
        .options(selectinload(User.profile))
        .where(
            User.auth_provider == AuthProvider.GOOGLE,
            User.provider_subject == identity.subject,
            User.is_active.is_(True),
        )
    )
    google_user = existing.scalar_one_or_none()

    if google_user is not None:
        if (
            guest_user is not None
            and guest_user.is_guest
            and guest_user.id != google_user.id
        ):
            # Guest tried to link to an already-registered Google account — sign into Google.
            pass
        google_user.last_login_at = datetime.now(timezone.utc)
        return await _issue_tokens(db, google_user)

    if identity.email:
        email_owner = await db.execute(
            select(User)
            .options(selectinload(User.profile))
            .where(User.email == identity.email, User.is_active.is_(True))
        )
        owner = email_owner.scalar_one_or_none()
        if owner is not None and not (
            guest_user is not None and guest_user.is_guest and owner.id == guest_user.id
        ):
            if owner.auth_provider != AuthProvider.GOOGLE:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Email already registered with another sign-in method",
                )

    if guest_user is not None and guest_user.is_guest:
        if identity.email:
            conflict = await db.scalar(
                select(User.id).where(
                    User.email == identity.email,
                    User.id != guest_user.id,
                )
            )
            if conflict:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Email already registered with another sign-in method",
                )
            guest_user.email = identity.email
        guest_user.auth_provider = AuthProvider.GOOGLE
        guest_user.provider_subject = identity.subject
        guest_user.is_guest = False
        guest_user.password_hash = None
        guest_user.last_login_at = datetime.now(timezone.utc)
        if identity.name and guest_user.profile and not guest_user.profile.display_name:
            guest_user.profile.display_name = identity.name[:64]
        await db.flush()
        # Reload profile relationship
        result = await db.execute(
            select(User)
            .options(selectinload(User.profile))
            .where(User.id == guest_user.id)
        )
        return await _issue_tokens(db, result.scalar_one())

    user = User(
        email=identity.email,
        auth_provider=AuthProvider.GOOGLE,
        provider_subject=identity.subject,
        is_guest=False,
        last_login_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.flush()

    base_name = (identity.name or identity.email or identity.subject).split("@")[0]
    safe = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in base_name)[:24] or "player"
    uname = await _ensure_unique_username(db, safe.lower())
    profile = UserProfile(
        user_id=user.id,
        username=uname,
        display_name=identity.name[:64] if identity.name else uname,
    )
    stats = PlayerStatistics(user_id=user.id)
    db.add(profile)
    db.add(stats)
    await db.flush()

    result = await db.execute(
        select(User).options(selectinload(User.profile)).where(User.id == user.id)
    )
    return await _issue_tokens(db, result.scalar_one())


async def get_current_user(
    credentials: Annotated[Optional[HTTPAuthorizationCredentials], Depends(bearer_scheme)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> User:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    try:
        payload = decode_token(credentials.credentials)
        if payload.get("type") != "access":
            raise ValueError("Wrong token type")
        user_id = UUID(payload["sub"])
    except (ValueError, KeyError, TypeError):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

    result = await db.execute(
        select(User)
        .options(selectinload(User.profile), selectinload(User.statistics))
        .where(User.id == user_id, User.is_active.is_(True))
    )
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    return user


async def get_optional_user(
    credentials: Annotated[Optional[HTTPAuthorizationCredentials], Depends(bearer_scheme)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> Optional[User]:
    if credentials is None:
        return None
    try:
        return await get_current_user(credentials, db)
    except HTTPException:
        return None


async def refresh_access_token(db: AsyncSession, refresh_token: str) -> TokenResponse:
    """Rotate a valid refresh token into a new access + refresh pair."""
    try:
        payload = decode_token(refresh_token)
        if payload.get("type") != "refresh":
            raise ValueError("Wrong token type")
        user_id = UUID(payload["sub"])
    except (ValueError, KeyError, TypeError):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

    token_hash = sha256(refresh_token.encode()).hexdigest()
    stored = await db.scalar(
        select(RefreshToken).where(
            RefreshToken.token_hash == token_hash,
            RefreshToken.revoked_at.is_(None),
        )
    )
    now = datetime.now(timezone.utc)
    if not stored or stored.expires_at < now or stored.user_id != user_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token expired")

    result = await db.execute(
        select(User)
        .options(selectinload(User.profile))
        .where(User.id == user_id, User.is_active.is_(True))
    )
    user = result.scalar_one_or_none()
    if not user or not user.profile:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")

    stored.revoked_at = now
    access = create_access_token(user.id, is_guest=user.is_guest)
    new_refresh = create_refresh_token(user.id)
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=sha256(new_refresh.encode()).hexdigest(),
            expires_at=now + timedelta(days=settings.jwt_refresh_token_expire_days),
            device_info=stored.device_info,
        )
    )
    await db.flush()
    return TokenResponse(
        access_token=access,
        refresh_token=new_refresh,
        token_type="bearer",
        user=_to_me(user, user.profile),
    )


CurrentUser = Annotated[User, Depends(get_current_user)]
OptionalUser = Annotated[Optional[User], Depends(get_optional_user)]
DbSession = Annotated[AsyncSession, Depends(get_db)]
