"""Custom topic API schemas."""

from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field

from app.models import DifficultyLabel, GameMode
from app.schemas.quiz import QuizSessionOut


class CreateCustomTopicRequest(BaseModel):
    prompt: str = Field(min_length=3, max_length=400)
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM
    mode: GameMode = GameMode.CASUAL
    style: Optional[str] = Field(default=None, max_length=120)
    requested_count: int = Field(default=10, ge=5, le=20)


class CustomTopicResponse(BaseModel):
    id: UUID
    status: str
    classified_subject: Optional[str] = None
    topic_id: Optional[UUID] = None
    topic_name: Optional[str] = None
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
