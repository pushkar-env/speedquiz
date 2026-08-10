from fastapi import APIRouter, status

from app.auth.deps import (
    CurrentUser,
    DbSession,
    OptionalUser,
    create_guest_user,
    login_email_user,
    login_or_link_google,
    refresh_access_token,
    register_email_user,
    upgrade_guest_to_email,
)
from app.schemas.auth import (
    EmailLoginRequest,
    EmailRegisterRequest,
    GoogleAuthRequest,
    GuestAuthRequest,
    GuestAuthResponse,
    RefreshRequest,
    TokenResponse,
    UpgradeGuestRequest,
    UserMeResponse,
)

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/guest", response_model=GuestAuthResponse, status_code=status.HTTP_201_CREATED)
async def auth_guest(payload: GuestAuthRequest, db: DbSession) -> GuestAuthResponse:
    return await create_guest_user(db, device_info=payload.device_info)


@router.post("/google", response_model=TokenResponse)
async def auth_google(
    payload: GoogleAuthRequest,
    db: DbSession,
    user: OptionalUser,
) -> TokenResponse:
    guest = user if user is not None and user.is_guest else None
    return await login_or_link_google(db, id_token=payload.id_token, guest_user=guest)


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def auth_register(payload: EmailRegisterRequest, db: DbSession) -> TokenResponse:
    return await register_email_user(
        db, email=payload.email, password=payload.password, username=payload.username
    )


@router.post("/login", response_model=TokenResponse)
async def auth_login(payload: EmailLoginRequest, db: DbSession) -> TokenResponse:
    return await login_email_user(db, email=payload.email, password=payload.password)


@router.post("/upgrade", response_model=TokenResponse)
async def auth_upgrade(
    payload: UpgradeGuestRequest,
    user: CurrentUser,
    db: DbSession,
) -> TokenResponse:
    return await upgrade_guest_to_email(
        db,
        guest_user=user,
        email=payload.email,
        password=payload.password,
        username=payload.username,
    )


@router.post("/refresh", response_model=TokenResponse)
async def auth_refresh(payload: RefreshRequest, db: DbSession) -> TokenResponse:
    return await refresh_access_token(db, payload.refresh_token)


@router.get("/me", response_model=UserMeResponse)
async def auth_me(user: CurrentUser) -> UserMeResponse:
    profile = user.profile
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
    )
