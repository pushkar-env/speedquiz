from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class AchievementUnlockedOut(BaseModel):
    id: UUID
    code: str
    name: str
    description: str
    icon: str
    category: str
    xp_reward: int
    coins_reward: int


class AchievementOut(BaseModel):
    id: UUID
    code: str
    name: str
    description: str
    icon: str
    category: str
    xp_reward: int
    coins_reward: int
    sort_order: int
    unlocked: bool
    unlocked_at: Optional[datetime] = None

    model_config = {"from_attributes": True}


class AchievementListResponse(BaseModel):
    items: list[AchievementOut]
    unlocked_count: int = Field(ge=0)
    total: int = Field(ge=0)
