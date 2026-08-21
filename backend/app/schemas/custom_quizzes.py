"""Wire contract for player-authored quizzes.

Two rules shape everything here:

* **The answer key is author-only.** [CustomQuizQuestionOut] carries
  ``correct_option_index`` because the person reading it wrote it. Nothing a
  *player* fetches ever includes it — they get questions through the ordinary
  session and match endpoints, which resolve correctness server-side.
* **Text is normalized at the boundary, not at the database.** Prompts and
  options arrive from a phone keyboard, so they get whitespace-collapsed and
  length-checked here once, rather than in every service that reads them.
"""

from __future__ import annotations

from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field, field_validator, model_validator

from app.core.languages import ContentLanguage, normalize_language
from app.models import (
    CustomQuizStatus,
    CustomQuizVisibility,
    DifficultyLabel,
    GameMode,
)
from app.schemas.quiz import QuizSessionOut

#: Options per question. Fixed at four everywhere else in the app — the play
#: screen lays out a 2x2 grid and `SubmitAnswerRequest` bounds the index — so
#: the editor enforces the same shape rather than inventing a variable one.
OPTION_COUNT = 4


def _tidy(value: str) -> str:
    """Collapse whitespace and drop the invisibles a paste drags along.

    ``isprintable()`` is False for every C0/C1 control *and* for the format
    characters that make text lie about itself — zero-width spaces, bidi
    overrides, the BOM. A question prompt is one line of plain text, so
    anything in that set is either a rendering bug waiting to happen or a
    deliberate one. Real whitespace survives the filter and is then
    collapsed, so a pasted multi-line prompt becomes a single tidy line
    rather than being rejected.
    """
    if not value:
        return ""
    kept = [ch for ch in value if ch.isprintable() or ch.isspace()]
    return " ".join("".join(kept).split())


class CustomQuizQuestionIn(BaseModel):
    """One question as the author typed it."""

    prompt: str = Field(min_length=4, max_length=300)
    options: list[str] = Field(min_length=OPTION_COUNT, max_length=OPTION_COUNT)
    correct_option_index: int = Field(ge=0, le=OPTION_COUNT - 1)
    explanation: Optional[str] = Field(default=None, max_length=400)
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM

    @field_validator("prompt", mode="before")
    @classmethod
    def _tidy_prompt(cls, value: object) -> object:
        return _tidy(value) if isinstance(value, str) else value

    @field_validator("explanation", mode="before")
    @classmethod
    def _tidy_explanation(cls, value: object) -> object:
        if not isinstance(value, str):
            return value
        tidied = _tidy(value)
        return tidied or None

    @field_validator("options", mode="before")
    @classmethod
    def _tidy_options(cls, value: object) -> object:
        if not isinstance(value, list):
            return value
        return [_tidy(v) if isinstance(v, str) else v for v in value]

    @field_validator("options")
    @classmethod
    def _distinct_non_empty(cls, value: list[str]) -> list[str]:
        for option in value:
            if not option:
                raise ValueError("Every option needs text")
            if len(option) > 160:
                raise ValueError("An option can be at most 160 characters")
        # Case-insensitive, because "Paris" and "paris" are the same answer to
        # a player and a quiz with two right answers is a broken quiz.
        folded = [o.casefold() for o in value]
        if len(set(folded)) != len(folded):
            raise ValueError("Options must all be different")
        return value


class CreateCustomQuizRequest(BaseModel):
    title: str = Field(min_length=2, max_length=80)
    description: Optional[str] = Field(default=None, max_length=280)
    icon: Optional[str] = Field(default=None, max_length=16)
    language: Optional[ContentLanguage] = None
    visibility: CustomQuizVisibility = CustomQuizVisibility.PRIVATE
    default_mode: GameMode = GameMode.CASUAL
    default_difficulty: DifficultyLabel = DifficultyLabel.MEDIUM
    #: Optional starter set, so "create" and "write the first question" can be
    #: one round trip when the client already has them (an AI draft accepted
    #: wholesale, or a retry after a failed create).
    questions: list[CustomQuizQuestionIn] = Field(default_factory=list, max_length=50)

    @field_validator("title", "description", mode="before")
    @classmethod
    def _tidy_text(cls, value: object) -> object:
        if not isinstance(value, str):
            return value
        tidied = _tidy(value)
        return tidied or None

    @field_validator("language", mode="before")
    @classmethod
    def _coerce_language(cls, value: object) -> object:
        if value is None or isinstance(value, ContentLanguage):
            return value
        return normalize_language(value)


class UpdateCustomQuizRequest(BaseModel):
    """Partial update. Every field is optional; absent means "leave it"."""

    title: Optional[str] = Field(default=None, min_length=2, max_length=80)
    description: Optional[str] = Field(default=None, max_length=280)
    icon: Optional[str] = Field(default=None, max_length=16)
    visibility: Optional[CustomQuizVisibility] = None
    default_mode: Optional[GameMode] = None
    default_difficulty: Optional[DifficultyLabel] = None

    @field_validator("title", mode="before")
    @classmethod
    def _tidy_title(cls, value: object) -> object:
        return _tidy(value) if isinstance(value, str) else value

    @field_validator("description", mode="before")
    @classmethod
    def _tidy_description(cls, value: object) -> object:
        # Distinct from title: an empty string here is a deliberate "clear it",
        # which the service turns into NULL.
        return _tidy(value) if isinstance(value, str) else value


class ReorderQuestionsRequest(BaseModel):
    """The full id list in the order the author wants them."""

    question_ids: list[UUID] = Field(min_length=1, max_length=50)


class AiDraftRequest(BaseModel):
    """Ask the generator for starter questions the author will then edit."""

    prompt: str = Field(min_length=3, max_length=200)
    count: int = Field(default=5, ge=1, le=10)
    difficulty: DifficultyLabel = DifficultyLabel.MEDIUM


class ReportQuizRequest(BaseModel):
    reason: str = Field(max_length=32)
    details: Optional[str] = Field(default=None, max_length=400)

    @field_validator("reason")
    @classmethod
    def _known_reason(cls, value: str) -> str:
        allowed = {"offensive", "wrong_answers", "spam", "copyright", "other"}
        if value not in allowed:
            raise ValueError(f"reason must be one of {sorted(allowed)}")
        return value


class StartCustomQuizRequest(BaseModel):
    """Start a solo run on a quiz, with the usual mode customisation."""

    mode: GameMode = GameMode.CASUAL
    difficulty: Optional[DifficultyLabel] = None
    question_time_limit_ms: Optional[int] = Field(default=None, ge=5000, le=60000)


class ChallengeWithQuizRequest(BaseModel):
    """Challenge a friend, or open a room, on a quiz you can play."""

    opponent_user_id: Optional[UUID] = None
    is_room: bool = False
    max_players: Optional[int] = Field(default=None, ge=2, le=8)
    question_count: Optional[int] = Field(default=None, ge=3, le=20)

    @model_validator(mode="after")
    def _needs_a_target(self) -> "ChallengeWithQuizRequest":
        if self.opponent_user_id is None and not self.is_room:
            raise ValueError("Pass opponent_user_id, or set is_room to open a room")
        return self


# --- Responses --------------------------------------------------------------


class CustomQuizQuestionOut(BaseModel):
    """A question as its **author** sees it — answer key included."""

    id: UUID
    position: int
    prompt: str
    options: list[str]
    correct_option_index: int
    explanation: Optional[str] = None
    difficulty: DifficultyLabel
    #: True when the question came back from the AI drafter. Purely for the
    #: editor's badge; it has no effect on play.
    ai_drafted: bool = False
    times_served: int = 0


class CustomQuizAuthorOut(BaseModel):
    user_id: UUID
    username: str
    display_name: Optional[str] = None
    avatar_id: str = "avatar_01"
    is_premium: bool = False


class CustomQuizOut(BaseModel):
    id: UUID
    topic_id: UUID
    title: str
    description: Optional[str] = None
    icon: str
    language: str
    visibility: CustomQuizVisibility
    status: CustomQuizStatus
    #: Present once published, and only for the author or someone who already
    #: has access — it is the key to the quiz, not a public identifier.
    code: Optional[str] = None
    question_count: int
    default_mode: GameMode
    default_difficulty: DifficultyLabel
    play_count: int
    player_count: int
    top_score: int
    author: CustomQuizAuthorOut
    #: True when the viewer wrote it.
    is_owner: bool = False
    #: The viewer's best score, when they have played it.
    my_best_score: Optional[int] = None
    #: Why the author cannot publish yet, in a code the client can localize:
    #: `too_few_questions` | `quiz_limit_reached` | `question_limit_exceeded`.
    #: Empty on a quiz that is ready.
    publish_blockers: list[str] = Field(default_factory=list)
    #: How many questions *this viewer's* plan lets this quiz hold. Carried on
    #: the quiz rather than only on the library response so the editor never
    #: has to guess when it is opened without the library having loaded.
    max_questions: int = 50
    #: The publish floor. Sent so the editor states the real number rather than
    #: hardcoding one that goes stale the first time an operator tunes it.
    min_questions: int = 3
    moderation_note: Optional[str] = None
    created_at: datetime
    updated_at: datetime
    published_at: Optional[datetime] = None


class CustomQuizDetailOut(CustomQuizOut):
    """The editor's view: the quiz plus every question in author order."""

    questions: list[CustomQuizQuestionOut] = Field(default_factory=list)


class CustomQuizListResponse(BaseModel):
    #: Quizzes the viewer wrote, newest first.
    mine: list[CustomQuizOut] = Field(default_factory=list)
    #: Quizzes shared with the viewer that they still have access to.
    shared: list[CustomQuizOut] = Field(default_factory=list)
    #: How many more published quizzes this account may create. None = no cap.
    remaining_slots: Optional[int] = None
    max_questions: int = 50


class CustomQuizLeaderboardEntryOut(BaseModel):
    rank: int
    user_id: UUID
    username: str
    display_name: Optional[str] = None
    avatar_id: str = "avatar_01"
    is_premium: bool = False
    best_score: int
    accuracy: float
    played_at: datetime
    is_me: bool = False


class CustomQuizLeaderboardResponse(BaseModel):
    quiz_id: UUID
    entries: list[CustomQuizLeaderboardEntryOut] = Field(default_factory=list)
    #: The viewer's own row, even when it falls outside the returned page.
    me: Optional[CustomQuizLeaderboardEntryOut] = None
    total_players: int = 0


class AiDraftResponse(BaseModel):
    """Drafts for the author to edit. Nothing is saved until they say so."""

    questions: list[CustomQuizQuestionIn] = Field(default_factory=list)
    #: Fresh drafting runs left today. None = unlimited (premium).
    remaining_today: Optional[int] = None


class StartCustomQuizResponse(BaseModel):
    quiz_id: UUID
    session: QuizSessionOut
