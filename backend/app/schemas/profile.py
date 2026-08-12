from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.core.languages import ContentLanguage, normalize_language


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
    #: Total playable questions across every language.
    question_count: int
    #: Playable questions per language, e.g. ``{"en": 412, "hi": 60}``. The
    #: client decides whether a topic is offered in the chosen quiz language
    #: from this, not from `question_count` — a topic can be deep in English
    #: and empty in Hindi.
    question_counts: dict[str, int] = Field(default_factory=dict)
    category: Optional[TopicCategoryOut] = None

    model_config = {"from_attributes": True}


class TopicListResponse(BaseModel):
    items: list[TopicOut]
    total: int
    #: Language the names in this response were localized to.
    language: str = ContentLanguage.ENGLISH.value


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
    #: Language the app chrome is drawn in on this account.
    app_language: str = ContentLanguage.ENGLISH.value
    #: Content language the quiz setup screen preselects.
    quiz_language: str = ContentLanguage.ENGLISH.value
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
    app_language: Optional[ContentLanguage] = None
    quiz_language: Optional[ContentLanguage] = None

    @field_validator("app_language", "quiz_language", mode="before")
    @classmethod
    def _coerce_language(cls, value: object) -> object:
        """Tolerate full locale tags from the device (``hi-IN``, ``en_US``)."""
        if value is None or isinstance(value, ContentLanguage):
            return value
        return normalize_language(value)
