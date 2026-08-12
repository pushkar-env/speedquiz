from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class LeaderboardEntryOut(BaseModel):
    rank: int
    user_id: UUID
    username: str
    score: int
    is_me: bool = False
    avatar_id: str = "avatar_01"
    #: Drives the subscriber badge — one of the cosmetics Premium sells.
    is_premium: bool = False


class LeaderboardMeOut(BaseModel):
    rank: Optional[int] = None
    score: Optional[int] = None
    username: Optional[str] = None


class LeaderboardResponse(BaseModel):
    scope: str
    period_key: str
    items: list[LeaderboardEntryOut]
    me: LeaderboardMeOut
    total: int = Field(ge=0)
