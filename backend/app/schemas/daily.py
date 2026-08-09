from datetime import date
from typing import Literal, Optional
from uuid import UUID

from pydantic import BaseModel

from app.models import DifficultyLabel


class DailyChallengeOut(BaseModel):
    id: UUID
    challenge_date: date
    title: str
    topic_id: UUID
    topic_name: str
    topic_icon: str = "📅"
    difficulty: DifficultyLabel
    question_count: int
    status: Literal["available", "in_progress", "completed"]
    best_score: Optional[int] = None
    session_id: Optional[UUID] = None