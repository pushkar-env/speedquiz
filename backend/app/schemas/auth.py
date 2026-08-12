from datetime import datetime
from typing import Optional
from uuid import UUID

from app.core.languages import ContentLanguage
from pydantic import BaseModel, EmailStr, Field


class GuestAuthRequest(BaseModel):
    device_info: Optional[str] = Field(default=None, max_length=255)


class EmailRegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    username: Optional[str] = Field(default=None, min_length=3, max_length=32)


class EmailLoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class UpgradeGuestRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    username: Optional[str] = Field(default=None, min_length=3, max_length=32)


class RefreshRequest(BaseModel):
    refresh_token: str


class GoogleAuthRequest(BaseModel):
    id_token: str = Field(min_length=20, max_length=8192)


class UserMeResponse(BaseModel):
    id: UUID
    email: Optional[EmailStr] = None
    is_guest: bool
    is_premium: bool
    role: str
    username: str
    display_name: Optional[str] = None
    avatar_id: str
    level: int
    xp: int
    coins: int
    current_streak: int
    daily_streak: int = 0
    best_streak: int = 0
    onboarding_completed: bool
    theme_preference: str
    #: Language preferences, so a fresh install of a signed-in account opens in
    #: the right language without waiting on a second request.
    app_language: str = ContentLanguage.ENGLISH.value
    quiz_language: str = ContentLanguage.ENGLISH.value

    model_config = {"from_attributes": True}


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user: UserMeResponse


class GuestAuthResponse(TokenResponse):
    pass


class HealthResponse(BaseModel):
    status: str
    service: str
    timestamp: datetime


class ReadyResponse(BaseModel):
    status: str
    database: bool
    redis: bool
    timestamp: datetime
