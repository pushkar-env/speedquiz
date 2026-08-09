"""Quiz API request/response schemas. Correct answers are never exposed before answering."""

from datetime import datetime
from decimal import Decimal
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field

from app.models import DifficultyLabel, GameMode, QuizSessionStatus
from app.schemas.achievements import AchievementUnlockedOut


class CreateQuizSessionRequest(BaseModel):
    topic_id: UUID
    mode: GameMode = GameMode.CASUAL
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM
    question_time_limit_ms: Optional[int] = Field(default=None, ge=5000, le=60000)


class QuizOptionOut(BaseModel):
    index: int
    text: str


class PlayableQuestionOut(BaseModel):
    quiz_question_id: UUID
    question_id: UUID
    sequence_index: int
    prompt: str
    options: list[QuizOptionOut]
    time_limit_ms: int
    served_at: datetime


class QuizSessionOut(BaseModel):
    id: UUID
    topic_id: UUID
    topic_name: str
    mode: GameMode
    difficulty: DifficultyLabel
    status: QuizSessionStatus
    score: int
    streak: int
    best_streak: int
    lives: Optional[int] = None
    time_budget_ms: Optional[int] = None
    time_remaining_ms: Optional[int] = None
    question_time_limit_ms: int
    current_question_index: int
    correct_count: int
    incorrect_count: int
    question_number: int
    current_question: Optional[PlayableQuestionOut] = None


class SubmitAnswerRequest(BaseModel):
    quiz_question_id: UUID
    selected_option_index: Optional[int] = Field(default=None, ge=0, le=3)
    client_elapsed_ms: Optional[int] = Field(default=None, ge=0, le=120000)
    timed_out: bool = False


class AnswerFeedbackOut(BaseModel):
    is_correct: bool
    selected_option_index: Optional[int]
    correct_option_index: int
    correct_option_text: str
    explanation: str
    base_points: int
    speed_bonus: int
    streak_multiplier: float
    points_awarded: int
    score: int
    streak: int
    best_streak: int
    lives: Optional[int] = None
    time_remaining_ms: Optional[int] = None
    session_status: QuizSessionStatus
    run_ended: bool
    next_question: Optional[PlayableQuestionOut] = None


class QuizResultOut(BaseModel):
    session_id: UUID
    topic_name: str
    mode: GameMode
    difficulty: DifficultyLabel
    final_score: int
    accuracy: float
    best_streak: int
    questions_answered: int
    correct_count: int
    incorrect_count: int
    average_answer_ms: int
    xp_earned: int
    is_personal_best: bool
    previous_best: int
    share_text: str
    comparisons: dict
    new_achievements: list[AchievementUnlockedOut] = Field(default_factory=list)
    level: Optional[int] = None
    xp: Optional[int] = None
    coins: Optional[int] = None
    daily_streak: Optional[int] = None
    current_streak: Optional[int] = None
