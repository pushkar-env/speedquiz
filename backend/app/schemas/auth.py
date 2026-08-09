from datetime import datetime
from typing import Optional
from uuid import UUID

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
    onboarding_completed: bool
    theme_preference: str

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
