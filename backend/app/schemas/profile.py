from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class TopicCategoryOut(BaseModel):
    id: UUID
    slug: str
    name: str
    description: Optional[str] = None
    icon: str
    sort_order: int

    model_config = {"from_attributes": True}


class TopicOut(BaseModel):
    id: UUID
    slug: str
    name: str
    description: Optional[str] = None
    icon: str
    is_custom: bool
    is_trending: bool
    popularity_score: int
    question_count: int
    category: Optional[TopicCategoryOut] = None

    model_config = {"from_attributes": True}


class TopicListResponse(BaseModel):
    items: list[TopicOut]
    total: int


class ProfileStatsOut(BaseModel):
    total_quizzes: int
    total_questions: int
    total_correct: int
    total_incorrect: int
    accuracy: float
    best_score: int
    best_streak: int
    average_answer_ms: int
    topic_mastery: dict
    skill_ratings: dict


class ProfileOut(BaseModel):
    user_id: UUID
    username: str
    display_name: Optional[str]
    avatar_id: str
    level: int
    xp: int
    coins: int
    current_streak: int
    best_streak: int
    daily_streak: int
    favorite_topic_ids: list
    onboarding_completed: bool
    theme_preference: str
    is_premium: bool
    #: Cosmetic unlocks keyed off Premium — animated_ring, premium_badge.
    flair: dict[str, bool] = Field(default_factory=dict)
    statistics: ProfileStatsOut


class UpdateProfileRequest(BaseModel):
    display_name: Optional[str] = Field(default=None, min_length=2, max_length=64)
    avatar_id: Optional[str] = Field(default=None, max_length=64)
    theme_preference: Optional[str] = Field(default=None, pattern="^(dark|light|system)$")
    favorite_topic_ids: Optional[list[UUID]] = None
    onboarding_completed: Optional[bool] = None
