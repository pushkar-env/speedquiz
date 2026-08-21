"""Wire shapes for exam mode."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any, Optional
from uuid import UUID

from pydantic import BaseModel, Field


class ExamOut(BaseModel):
    id: UUID
    slug: str
    name: str
    authority: Optional[str] = None
    icon: str
    paper_count: int = 0


class PaperSummaryOut(BaseModel):
    id: UUID
    key: str
    title: str
    year: int
    session: str = ""
    shift: int = 0
    held_on: Optional[date] = None
    duration_minutes: int
    total_marks: float
    question_count: int
    is_free: bool
    #: Whether this user may open it right now. Free papers are open to
    #: everyone; the rest need premium.
    is_locked: bool = False
    attempt_count: int = 0
    #: The caller's own history, so the list row can say "Resume" or "82/300".
    best_score: Optional[float] = None
    last_attempt_id: Optional[UUID] = None
    last_attempt_status: Optional[str] = None


class SectionOut(BaseModel):
    id: UUID
    name: str
    subject: str
    position: int
    first_question: int
    last_question: int
    question_count: int
    answer_type: str
    marking: dict = Field(default_factory=dict)
    rules: dict = Field(default_factory=dict)


class AssetOut(BaseModel):
    checksum: str
    width: int
    height: int
    alt_text: Optional[str] = None
    #: ``{"light": {"url": ..., "bytes": n}, "dark": {...}}``
    variants: dict = Field(default_factory=dict)


class PaperQuestionOut(BaseModel):
    """One question, as the client renders it.

    Carries no answer. The key stays server-side until the attempt is
    submitted, which is the whole reason the manifest can be cached and shared
    between users.
    """

    id: UUID
    number: int
    section_id: Optional[UUID] = None
    answer_type: str
    marks: float
    negative_marks: float
    #: Structured blocks: ``[{"t":"text","v":"...$x^2$..."},{"t":"figure","ref":"fig1"}]``
    stem: list[dict] = Field(default_factory=list)
    #: Parallel to the option list; each entry is that option's blocks.
    options: list[list[dict]] = Field(default_factory=list)
    #: Flat text per option, for accessibility and any client too old for blocks.
    option_text: list[str] = Field(default_factory=list)
    unit: Optional[str] = None
    #: ref -> checksum, resolving the figure blocks above against `assets`.
    figures: dict[str, str] = Field(default_factory=dict)


class PaperManifestOut(BaseModel):
    """Everything needed to run the paper offline.

    Fetched once before the clock starts. A three-hour test on patchy mobile
    data cannot afford to discover a missing figure at minute forty.
    """

    paper: PaperSummaryOut
    exam: ExamOut
    sections: list[SectionOut]
    questions: list[PaperQuestionOut]
    assets: list[AssetOut]
    total_asset_bytes: int = 0
    etag: str


class StartAttemptRequest(BaseModel):
    mode: str = Field(default="full", pattern="^(full|sectional|practice)$")
    section_id: Optional[UUID] = None
    #: "casual" leaves the paper clock as the only limit; "timed" adds a
    #: per-question one. Orthogonal to `mode`, so practice can be either.
    pacing: str = Field(default="casual", pattern="^(casual|timed)$")
    #: Overall limit. None uses the paper's own duration.
    duration_minutes: Optional[int] = Field(default=None, ge=5, le=360)
    #: Only meaningful when pacing is "timed". None derives an even split of
    #: the overall budget.
    per_question_seconds: Optional[int] = Field(default=None, ge=10, le=1800)


class ResponseIn(BaseModel):
    exam_question_id: UUID
    state: str = Field(default="not_visited")
    selected: list[int] = Field(default_factory=list)
    numeric_value: Optional[float] = None
    numeric_raw: Optional[str] = Field(default=None, max_length=64)
    time_spent_ms: int = 0
    visit_count: int = 0
    #: Monotonic per attempt. An out-of-order retry with a lower revision is
    #: discarded rather than allowed to overwrite newer state.
    client_revision: int = 0


class SyncResponsesRequest(BaseModel):
    #: Only what changed since the last flush -- typically a handful of rows,
    #: not the whole answer sheet.
    responses: list[ResponseIn] = Field(default_factory=list, max_length=500)


class AttemptOut(BaseModel):
    id: UUID
    paper_id: UUID
    mode: str
    status: str
    started_at: datetime
    server_deadline_at: datetime
    #: Authoritative. The client counts down locally and reconciles to this on
    #: every sync; its own elapsed time is never trusted for scoring.
    remaining_ms: int
    server_now: datetime
    submitted_at: Optional[datetime] = None
    pacing: str = "casual"
    per_question_seconds: Optional[int] = None
    #: False for practice runs, which stay out of the paper's percentile.
    counts_for_rank: bool = True
    responses: list[dict] = Field(default_factory=list)


class SyncResponsesOut(BaseModel):
    accepted: int
    rejected: int
    remaining_ms: int
    server_now: datetime
    status: str


class QuestionResultOut(BaseModel):
    exam_question_id: UUID
    number: int
    section_id: Optional[UUID] = None
    is_correct: Optional[bool] = None
    marks_awarded: float = 0
    counted: bool = True
    time_spent_ms: int = 0
    #: The key, revealed only now.
    correct_option_index: Optional[int] = None
    correct_value: Optional[float] = None
    selected: list[int] = Field(default_factory=list)
    numeric_value: Optional[float] = None
    #: Empty when the solution did not pass verification -- a plausible wrong
    #: method is worse than none. See `SolutionStatus`.
    solution: str = ""
    chapter: Optional[str] = None


class AttemptResultOut(BaseModel):
    attempt: AttemptOut
    score: float
    max_score: float
    correct: int
    incorrect: int
    unattempted: int
    percentile: Optional[float] = None
    rank: Optional[int] = None
    total_attempts: int = 0
    sections: dict[str, Any] = Field(default_factory=dict)
    questions: list[QuestionResultOut] = Field(default_factory=list)
    #: Chapter -> {correct, total, marks}. The weak-area engine.
    chapters: dict[str, Any] = Field(default_factory=dict)


class CheckAnswerRequest(BaseModel):
    exam_question_id: UUID
    selected: list[int] = Field(default_factory=list, max_length=8)
    numeric_value: Optional[float] = None


class CheckAnswerOut(BaseModel):
    """Instant feedback on one practice question."""

    exam_question_id: UUID
    is_correct: bool
    marks_awarded: float
    answer_type: str
    correct_option_index: Optional[int] = None
    correct_value: Optional[float] = None
    #: Empty when the solution has not passed verification. `solution_available`
    #: lets the client say "being checked" rather than show a blank panel.
    solution: str = ""
    solution_available: bool = False
    chapter: Optional[str] = None
    key_concept: Optional[str] = None


class NotebookEntryOut(BaseModel):
    id: UUID
    question_id: UUID
    chapter: str
    subject: str = ""
    status: str
    wrong_count: int
    last_wrong_at: datetime
    #: "JEE Main 2025 January Shift 1 · Q28"
    source: Optional[str] = None
    answer_type: str
    stem: list[dict] = Field(default_factory=list)
    options: list[list[dict]] = Field(default_factory=list)
    option_text: list[str] = Field(default_factory=list)
    figures: dict[str, str] = Field(default_factory=dict)
    correct_option_index: Optional[int] = None
    correct_value: Optional[float] = None
    your_selected: list[int] = Field(default_factory=list)
    your_numeric: Optional[float] = None
    solution: str = ""


class NotebookChapterOut(BaseModel):
    name: str
    count: int


class NotebookOut(BaseModel):
    total: int
    open_count: int
    items: list[NotebookEntryOut] = Field(default_factory=list)
    assets: list[AssetOut] = Field(default_factory=list)
    chapters: list[NotebookChapterOut] = Field(default_factory=list)


class SetNotebookStatusRequest(BaseModel):
    status: str = Field(pattern="^(open|reviewed|recovered)$")
