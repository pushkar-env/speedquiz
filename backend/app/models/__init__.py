import enum
import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Optional

from sqlalchemy import (
    Boolean,
    Date,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base


def utcnow() -> datetime:
    return datetime.utcnow()


def pg_enum(enum_cls: type[enum.Enum], name: str, *, create_constraint: bool = True):
    """Persist enum *values* (lowercase) to match Postgres ENUM labels."""
    return Enum(
        enum_cls,
        name=name,
        values_callable=lambda members: [m.value for m in members],
        create_constraint=create_constraint,
    )


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class AuthProvider(str, enum.Enum):
    GUEST = "guest"
    EMAIL = "email"
    GOOGLE = "google"
    APPLE = "apple"


class UserRole(str, enum.Enum):
    PLAYER = "player"
    ADMIN = "admin"
    MODERATOR = "moderator"


class QuestionStatus(str, enum.Enum):
    PENDING = "pending"
    ACTIVE = "active"
    REJECTED = "rejected"
    RETIRED = "retired"
    REPORTED = "reported"


class GameMode(str, enum.Enum):
    CASUAL = "casual"
    SPEEDRUN = "speedrun"
    SURVIVAL = "survival"
    NEGATIVE = "negative"
    SUDDEN_DEATH = "sudden_death"
    DAILY = "daily"


class DifficultyLabel(str, enum.Enum):
    EASY = "easy"
    MEDIUM = "medium"
    HARD = "hard"
    EXPERT = "expert"


class QuizSessionStatus(str, enum.Enum):
    PENDING = "pending"
    ACTIVE = "active"
    COMPLETED = "completed"
    ABANDONED = "abandoned"
    EXPIRED = "expired"


class SubscriptionStatus(str, enum.Enum):
    NONE = "none"
    ACTIVE = "active"
    GRACE = "grace"
    EXPIRED = "expired"
    CANCELLED = "cancelled"


class GenerationJobStatus(str, enum.Enum):
    QUEUED = "queued"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class User(Base, TimestampMixin):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email: Mapped[Optional[str]] = mapped_column(String(320), unique=True, index=True)
    password_hash: Mapped[Optional[str]] = mapped_column(String(255))
    auth_provider: Mapped[AuthProvider] = mapped_column(pg_enum(AuthProvider, "auth_provider"), default=AuthProvider.GUEST, nullable=False
    )
    provider_subject: Mapped[Optional[str]] = mapped_column(String(255), index=True)
    role: Mapped[UserRole] = mapped_column(pg_enum(UserRole, "user_role"), default=UserRole.PLAYER, nullable=False
    )
    is_guest: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    is_premium: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    last_login_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    profile: Mapped["UserProfile"] = relationship(back_populates="user", uselist=False)
    statistics: Mapped["PlayerStatistics"] = relationship(back_populates="user", uselist=False)
    refresh_tokens: Mapped[list["RefreshToken"]] = relationship(back_populates="user")


class UserProfile(Base, TimestampMixin):
    __tablename__ = "user_profiles"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), unique=True, nullable=False
    )
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True, nullable=False)
    display_name: Mapped[Optional[str]] = mapped_column(String(64))
    avatar_id: Mapped[str] = mapped_column(String(64), default="avatar_01", nullable=False)
    bio: Mapped[Optional[str]] = mapped_column(String(280))
    level: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    xp: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    coins: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    current_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    best_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    daily_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    last_played_date: Mapped[Optional[date]] = mapped_column(Date)
    favorite_topic_ids: Mapped[list] = mapped_column(JSONB, default=list, nullable=False)
    onboarding_completed: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    theme_preference: Mapped[str] = mapped_column(String(16), default="dark", nullable=False)

    user: Mapped[User] = relationship(back_populates="profile")


class PlayerStatistics(Base, TimestampMixin):
    __tablename__ = "player_statistics"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), unique=True, nullable=False
    )
    total_quizzes: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_questions: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_correct: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_incorrect: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    best_score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    best_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    average_answer_ms: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    topic_mastery: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    skill_ratings: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    user: Mapped[User] = relationship(back_populates="statistics")

    @property
    def accuracy(self) -> float:
        if self.total_questions == 0:
            return 0.0
        return round(100.0 * self.total_correct / self.total_questions, 2)


class RefreshToken(Base, TimestampMixin):
    __tablename__ = "refresh_tokens"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    token_hash: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    device_info: Mapped[Optional[str]] = mapped_column(String(255))

    user: Mapped[User] = relationship(back_populates="refresh_tokens")


class TopicCategory(Base, TimestampMixin):
    __tablename__ = "topic_categories"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    slug: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    description: Mapped[Optional[str]] = mapped_column(String(255))
    icon: Mapped[str] = mapped_column(String(64), default="category", nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    topics: Mapped[list["Topic"]] = relationship(back_populates="category")


class Topic(Base, TimestampMixin):
    __tablename__ = "topics"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    category_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topic_categories.id", ondelete="SET NULL")
    )
    slug: Mapped[str] = mapped_column(String(100), unique=True, nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[Optional[str]] = mapped_column(Text)
    icon: Mapped[str] = mapped_column(String(64), default="topic", nullable=False)
    is_custom: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    is_trending: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    popularity_score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    question_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    created_by_user_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL")
    )

    category: Mapped[Optional[TopicCategory]] = relationship(back_populates="topics")
    subtopics: Mapped[list["Subtopic"]] = relationship(back_populates="topic")
    questions: Mapped[list["Question"]] = relationship(back_populates="topic")


class Subtopic(Base, TimestampMixin):
    __tablename__ = "subtopics"
    __table_args__ = (UniqueConstraint("topic_id", "slug", name="uq_subtopic_topic_slug"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    topic_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE"), nullable=False, index=True
    )
    slug: Mapped[str] = mapped_column(String(120), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[Optional[str]] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    topic: Mapped[Topic] = relationship(back_populates="subtopics")


class CustomTopic(Base, TimestampMixin):
    __tablename__ = "custom_topics"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    topic_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="SET NULL")
    )
    prompt: Mapped[str] = mapped_column(Text, nullable=False)
    sanitized_prompt: Mapped[str] = mapped_column(Text, nullable=False)
    classified_subject: Mapped[Optional[str]] = mapped_column(String(120))
    difficulty: Mapped[DifficultyLabel] = mapped_column(pg_enum(DifficultyLabel, "difficulty_label"),
        default=DifficultyLabel.MEDIUM,
        nullable=False,
    )
    style: Mapped[Optional[str]] = mapped_column(String(120))
    requested_count: Mapped[int] = mapped_column(Integer, default=10, nullable=False)
    cache_key: Mapped[str] = mapped_column(String(128), index=True, nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="pending", nullable=False)


class Question(Base, TimestampMixin):
    __tablename__ = "questions"
    __table_args__ = (
        Index("ix_questions_topic_difficulty_status", "topic_id", "difficulty", "status"),
        Index("ix_questions_quality_status", "quality_score", "status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    topic_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE"), nullable=False, index=True
    )
    subtopic_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("subtopics.id", ondelete="SET NULL")
    )
    prompt: Mapped[str] = mapped_column(Text, nullable=False)
    explanation: Mapped[str] = mapped_column(Text, nullable=False)
    source: Mapped[Optional[str]] = mapped_column(String(255))
    difficulty: Mapped[float] = mapped_column(Float, nullable=False, default=0.5)
    difficulty_label: Mapped[DifficultyLabel] = mapped_column(pg_enum(DifficultyLabel, "difficulty_label", create_constraint=False),
        default=DifficultyLabel.MEDIUM,
        nullable=False,
    )
    correct_option_index: Mapped[int] = mapped_column(Integer, nullable=False)
    quality_score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    status: Mapped[QuestionStatus] = mapped_column(pg_enum(QuestionStatus, "question_status"),
        default=QuestionStatus.PENDING,
        nullable=False,
        index=True,
    )
    content_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    embedding_fingerprint: Mapped[Optional[str]] = mapped_column(String(128), index=True)
    times_served: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    times_correct: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    times_incorrect: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    times_reported: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    generation_meta: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    topic: Mapped[Topic] = relationship(back_populates="questions")
    options: Mapped[list["QuestionOption"]] = relationship(
        back_populates="question", cascade="all, delete-orphan", order_by="QuestionOption.position"
    )


class QuestionOption(Base):
    __tablename__ = "question_options"
    __table_args__ = (
        UniqueConstraint("question_id", "position", name="uq_question_option_position"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("questions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False)

    question: Mapped[Question] = relationship(back_populates="options")


class QuizSession(Base, TimestampMixin):
    __tablename__ = "quiz_sessions"
    __table_args__ = (Index("ix_quiz_sessions_user_status", "user_id", "status"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    topic_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE"), nullable=False
    )
    mode: Mapped[GameMode] = mapped_column(pg_enum(GameMode, "game_mode"), nullable=False)
    difficulty: Mapped[DifficultyLabel] = mapped_column(pg_enum(DifficultyLabel, "difficulty_label", create_constraint=False),
        nullable=False,
    )
    status: Mapped[QuizSessionStatus] = mapped_column(pg_enum(QuizSessionStatus, "quiz_session_status"),
        default=QuizSessionStatus.PENDING,
        nullable=False,
    )
    score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    best_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    lives: Mapped[Optional[int]] = mapped_column(Integer)
    time_budget_ms: Mapped[Optional[int]] = mapped_column(Integer)
    time_remaining_ms: Mapped[Optional[int]] = mapped_column(Integer)
    question_time_limit_ms: Mapped[int] = mapped_column(Integer, default=15000, nullable=False)
    current_question_index: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    correct_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    incorrect_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    started_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    config: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    is_daily_challenge: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    daily_challenge_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("daily_challenges.id", ondelete="SET NULL")
    )


class QuizQuestion(Base):
    __tablename__ = "quiz_questions"
    __table_args__ = (
        UniqueConstraint("session_id", "sequence_index", name="uq_quiz_question_sequence"),
        # Same bank question may be reshuffled and re-served in long endless runs.
        Index("ix_quiz_questions_session_question", "session_id", "question_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("quiz_sessions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("questions.id", ondelete="CASCADE"), nullable=False
    )
    sequence_index: Mapped[int] = mapped_column(Integer, nullable=False)
    served_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    option_order: Mapped[list] = mapped_column(JSONB, default=list, nullable=False)


class Answer(Base, TimestampMixin):
    __tablename__ = "answers"
    __table_args__ = (
        UniqueConstraint("session_id", "quiz_question_id", name="uq_answer_once"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("quiz_sessions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    quiz_question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("quiz_questions.id", ondelete="CASCADE"), nullable=False
    )
    question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("questions.id", ondelete="CASCADE"), nullable=False
    )
    selected_option_index: Mapped[Optional[int]] = mapped_column(Integer)
    is_correct: Mapped[bool] = mapped_column(Boolean, nullable=False)
    client_elapsed_ms: Mapped[Optional[int]] = mapped_column(Integer)
    server_elapsed_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    base_points: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    speed_bonus: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    streak_multiplier: Mapped[Decimal] = mapped_column(Numeric(4, 2), default=1, nullable=False)
    points_awarded: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    answered_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Score(Base, TimestampMixin):
    __tablename__ = "scores"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("quiz_sessions.id", ondelete="CASCADE"), unique=True, nullable=False
    )
    topic_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE"), nullable=False, index=True
    )
    mode: Mapped[GameMode] = mapped_column(pg_enum(GameMode, "game_mode", create_constraint=False))
    difficulty: Mapped[DifficultyLabel] = mapped_column(pg_enum(DifficultyLabel, "difficulty_label", create_constraint=False)
    )
    final_score: Mapped[int] = mapped_column(Integer, nullable=False)
    accuracy: Mapped[float] = mapped_column(Float, nullable=False)
    best_streak: Mapped[int] = mapped_column(Integer, nullable=False)
    questions_answered: Mapped[int] = mapped_column(Integer, nullable=False)
    xp_earned: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_personal_best: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)


class QuizResult(Base, TimestampMixin):
    __tablename__ = "quiz_results"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("quiz_sessions.id", ondelete="CASCADE"), unique=True, nullable=False
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    summary: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    share_payload: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    comparisons: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)


class LeaderboardEntry(Base, TimestampMixin):
    __tablename__ = "leaderboards"
    __table_args__ = (
        Index("ix_leaderboards_scope_period", "scope", "period_key", "rank"),
        UniqueConstraint(
            "scope", "period_key", "user_id", "topic_id", "mode", name="uq_leaderboard_entry"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    scope: Mapped[str] = mapped_column(String(32), nullable=False)  # global/weekly/monthly/daily/topic
    period_key: Mapped[str] = mapped_column(String(32), nullable=False)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    topic_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE")
    )
    mode: Mapped[Optional[GameMode]] = mapped_column(pg_enum(GameMode, "game_mode", create_constraint=False)
    )
    score: Mapped[int] = mapped_column(Integer, nullable=False)
    rank: Mapped[int] = mapped_column(Integer, nullable=False)


class Streak(Base, TimestampMixin):
    __tablename__ = "streaks"
    __table_args__ = (UniqueConstraint("user_id", "streak_type", name="uq_user_streak_type"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    streak_type: Mapped[str] = mapped_column(String(32), nullable=False)  # daily, play, correct
    current_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    best_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    last_increment_date: Mapped[Optional[date]] = mapped_column(Date)


class Achievement(Base, TimestampMixin):
    __tablename__ = "achievements"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    code: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False)
    icon: Mapped[str] = mapped_column(String(64), default="trophy", nullable=False)
    category: Mapped[str] = mapped_column(String(64), default="general", nullable=False)
    criteria: Mapped[dict] = mapped_column(JSONB, nullable=False)
    xp_reward: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    coins_reward: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)


class UserAchievement(Base, TimestampMixin):
    __tablename__ = "user_achievements"
    __table_args__ = (
        UniqueConstraint("user_id", "achievement_id", name="uq_user_achievement"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    achievement_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("achievements.id", ondelete="CASCADE"), nullable=False
    )
    unlocked_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    meta: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)


class QuestionReport(Base, TimestampMixin):
    __tablename__ = "question_reports"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("questions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    reason: Mapped[str] = mapped_column(String(64), nullable=False)
    details: Mapped[Optional[str]] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(32), default="open", nullable=False)


class Subscription(Base, TimestampMixin):
    __tablename__ = "subscriptions"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    status: Mapped[SubscriptionStatus] = mapped_column(pg_enum(SubscriptionStatus, "subscription_status"),
        default=SubscriptionStatus.NONE,
        nullable=False,
    )
    product_id: Mapped[Optional[str]] = mapped_column(String(128))
    platform: Mapped[Optional[str]] = mapped_column(String(32))  # ios / android
    original_transaction_id: Mapped[Optional[str]] = mapped_column(String(255), unique=True)
    expires_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    entitlements: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)


class DailyChallenge(Base, TimestampMixin):
    __tablename__ = "daily_challenges"
    __table_args__ = (UniqueConstraint("challenge_date", name="uq_daily_challenge_date"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    challenge_date: Mapped[date] = mapped_column(Date, nullable=False)
    topic_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    difficulty: Mapped[DifficultyLabel] = mapped_column(pg_enum(DifficultyLabel, "difficulty_label", create_constraint=False),
        nullable=False,
    )
    question_ids: Mapped[list] = mapped_column(JSONB, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)


class GenerationJob(Base, TimestampMixin):
    __tablename__ = "generation_jobs"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    topic_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="SET NULL")
    )
    custom_topic_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("custom_topics.id", ondelete="SET NULL")
    )
    requested_by_user_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL")
    )
    status: Mapped[GenerationJobStatus] = mapped_column(pg_enum(GenerationJobStatus, "generation_job_status"),
        default=GenerationJobStatus.QUEUED,
        nullable=False,
        index=True,
    )
    requested_count: Mapped[int] = mapped_column(Integer, default=10, nullable=False)
    approved_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    rejected_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    error_message: Mapped[Optional[str]] = mapped_column(Text)
    payload: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)


class AnalyticsEvent(Base):
    __tablename__ = "analytics_events"
    __table_args__ = (
        Index("ix_analytics_events_event_created", "event", "created_at"),
        Index("ix_analytics_events_user_created", "user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    event: Mapped[str] = mapped_column(String(128), nullable=False)
    properties: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
