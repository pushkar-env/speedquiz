"""Quiz API request/response schemas. Correct answers are never exposed before answering."""

from datetime import datetime
from decimal import Decimal
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.core.languages import ContentLanguage, normalize_language
from app.models import DifficultyLabel, GameMode, QuizSessionStatus
from app.schemas.achievements import AchievementUnlockedOut


class CreateQuizSessionRequest(BaseModel):
    topic_id: UUID
    mode: GameMode = GameMode.CASUAL
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM
    question_time_limit_ms: Optional[int] = Field(default=None, ge=5000, le=60000)
    adaptive: bool = False
    #: Language to serve questions in. ``None`` means "whatever this player
    #: last chose", which is what a client too old to know about languages
    #: gets — never a 422.
    language: Optional[ContentLanguage] = Field(
        default=None,
        description="Content language for the run (en, hi). Defaults to the player's last choice.",
    )

    @field_validator("language", mode="before")
    @classmethod
    def _coerce_language(cls, value: object) -> object:
        """Accept ``hi-IN`` and friends; an unknown tag falls back, not fails."""
        if value is None or isinstance(value, ContentLanguage):
            return value
        return normalize_language(value)


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
    #: Language the questions in this run are written in.
    language: str = ContentLanguage.ENGLISH.value
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

    # --- Speedrun ---------------------------------------------------------
    # Defaulted so every other mode (and any older client) is unaffected.
    #: Lump bonus for crossing a streak milestone, already inside points_awarded.
    milestone_bonus: int = 0
    #: Signed clock change the answer itself earned: refund or penalty.
    time_delta_ms: Optional[int] = None
    #: What the question plus its verdict flash cost off the clock.
    time_burned_ms: Optional[int] = None
    #: Streak is hot — the HUD switches to its overdrive treatment.
    overdrive: bool = False
    #: blitz | fast | clean | clutch — how quick the correct answer was.
    speed_tier: Optional[str] = None


class QuizResultOut(BaseModel):
    session_id: UUID
    topic_name: str
    mode: GameMode
    difficulty: DifficultyLabel
    #: Language the run was played in.
    language: str = ContentLanguage.ENGLISH.value
    final_score: int
    accuracy: float
    best_streak: int
    questions_answered: int
    correct_count: int
    incorrect_count: int
    average_answer_ms: int
    #: Wall time the run lasted. The headline stat for a speedrun.
    duration_ms: int = 0
    xp_earned: int
    is_personal_best: bool
    previous_best: int
    share_text: str
    share_payload: dict = Field(default_factory=dict)
    comparisons: dict
    new_achievements: list[AchievementUnlockedOut] = Field(default_factory=list)
    level: Optional[int] = None
    xp: Optional[int] = None
    coins: Optional[int] = None
    daily_streak: Optional[int] = None
    current_streak: Optional[int] = None
