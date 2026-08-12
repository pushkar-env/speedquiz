"""Custom topic API schemas."""

from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.core.languages import ContentLanguage, normalize_language
from app.models import DifficultyLabel, GameMode
from app.schemas.quiz import QuizSessionOut


class CreateCustomTopicRequest(BaseModel):
    prompt: str = Field(min_length=3, max_length=400)
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM
    mode: GameMode = GameMode.CASUAL
    style: Optional[str] = Field(default=None, max_length=120)
    requested_count: int = Field(default=10, ge=5, le=20)
    #: Language to write the generated bank in. ``None`` falls back to the
    #: player's last quiz language.
    language: Optional[ContentLanguage] = None

    @field_validator("language", mode="before")
    @classmethod
    def _coerce_language(cls, value: object) -> object:
        if value is None or isinstance(value, ContentLanguage):
            return value
        return normalize_language(value)


class CustomTopicResponse(BaseModel):
    id: UUID
    status: str
    classified_subject: Optional[str] = None
    topic_id: Optional[UUID] = None
    topic_name: Optional[str] = None
    language: str = ContentLanguage.ENGLISH.value
    cache_hit: bool = False
    job_id: Optional[UUID] = None
    approved_count: int = 0
    rejected_count: int = 0
    session: Optional[QuizSessionOut] = None


class GenerationJobOut(BaseModel):
    id: UUID
    status: str
    approved_count: int
    rejected_count: int
    error_message: Optional[str] = None
