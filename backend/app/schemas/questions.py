"""Question teach / report schemas."""

from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class TeachMeRequest(BaseModel):
    user_option_text: Optional[str] = Field(default=None, max_length=500)


class TeachMeResponse(BaseModel):
    question_id: UUID
    why_correct: str
    why_wrong: str
    key_concept: str
    memorable_fact: str


class QuestionReportRequest(BaseModel):
    reason: str = Field(min_length=2, max_length=64)
    details: Optional[str] = Field(default=None, max_length=1000)
