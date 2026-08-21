import enum
import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Optional

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Computed,
    Date,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    PrimaryKeyConstraint,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, TSVECTOR, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.core.freshness import DEFAULT_VOLATILITY
from app.core.languages import DEFAULT_LANGUAGE, LANGUAGE_CODE_MAX_LENGTH


def utcnow() -> datetime:
    return datetime.utcnow()


def language_column(**kwargs):
    """A BCP-47 primary subtag column, defaulting to the app's base language.

    Every row written before languages existed is English, so the server
    default backfills them without a data migration. See ``app.core.languages``
    for why this is a string rather than a Postgres enum.
    """
    return mapped_column(
        String(LANGUAGE_CODE_MAX_LENGTH),
        default=DEFAULT_LANGUAGE.value,
        server_default=DEFAULT_LANGUAGE.value,
        nullable=False,
        **kwargs,
    )


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


class AnswerType(str, enum.Enum):
    """How a question is answered.

    ``SINGLE`` is what the whole bank was before exam mode, which is why it is
    the server default: every pre-existing row is already correct.
    """

    SINGLE = "single"
    MULTI = "multi"
    NUMERIC = "numeric"


class SolutionStatus(str, enum.Enum):
    """How far a worked solution can be trusted.

    Set by the ingestion pipeline. Only ``VERIFIED`` is shown to students: a
    solution written after the model was told the answer can reach the right
    result by an invalid route, and a plausible wrong method is worse than no
    method at all.
    """

    VERIFIED = "verified"
    NEEDS_REVIEW = "needs_review"
    WITHHELD = "withheld"


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
    """Lifecycle of a store subscription, as we resolve it.

    Entitled states are ACTIVE, GRACE and CANCELLED — a cancelled subscription
    keeps premium until the paid period runs out, which is what both stores
    promise the buyer. ON_HOLD, PAUSED, EXPIRED and REVOKED are not entitled.
    """

    NONE = "none"
    ACTIVE = "active"
    # Renewal payment failed; store is retrying and told us to keep serving.
    GRACE = "grace"
    # Grace elapsed, still in billing retry. Play suspends the entitlement.
    ON_HOLD = "on_hold"
    # Play-only: user paused the subscription; resumes automatically.
    PAUSED = "paused"
    # Purchase awaiting payment (UPI / net banking / "ask to buy").
    PENDING = "pending"
    # Auto-renew off but the paid period has not ended yet.
    CANCELLED = "cancelled"
    EXPIRED = "expired"
    # Refunded or charged back — entitlement pulled immediately.
    REVOKED = "revoked"


#: Statuses that grant premium (subject to the period not having elapsed).
ENTITLED_SUBSCRIPTION_STATUSES = frozenset(
    {
        SubscriptionStatus.ACTIVE,
        SubscriptionStatus.GRACE,
        SubscriptionStatus.CANCELLED,
    }
)


class GenerationJobStatus(str, enum.Enum):
    QUEUED = "queued"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class FriendshipStatus(str, enum.Enum):
    """Lifecycle of one directed friend request.

    Only PENDING and ACCEPTED occupy the unordered-pair slot (see the partial
    unique index on ``friendships``), so a declined request can be sent again
    later without a delete-then-insert dance.
    """

    PENDING = "pending"
    ACCEPTED = "accepted"
    DECLINED = "declined"
    CANCELLED = "cancelled"


class MatchFormat(str, enum.Enum):
    """How many seats a match has."""

    #: Exactly two players. The only format that can be rated.
    DUEL = "duel"
    #: 3-8 players in a private, code-joined room.
    ROOM = "room"


class MatchKind(str, enum.Enum):
    #: Friend challenge or private room. Never touches rating.
    FRIENDLY = "friendly"
    #: Matchmade 1v1 from the ranked queue. Moves Elo.
    RANKED = "ranked"


class MatchDelivery(str, enum.Enum):
    """Whether players are answering at the same moment.

    A LIVE match runs on a shared server clock over the realtime channel. An
    ASYNC match hands each player the identical question set to play whenever
    they open the app — which is what a challenge to an offline friend becomes,
    and what a live match degrades to when the opponent never connects.
    """

    LIVE = "live"
    ASYNC = "async"


class MatchStatus(str, enum.Enum):
    #: Created; at least one invitee has neither joined nor declined.
    PENDING = "pending"
    #: Everyone present, waiting on the host (or the countdown) to start.
    LOBBY = "lobby"
    #: Rounds are being served.
    LIVE = "live"
    #: Async only — one side has played, the other has not yet.
    AWAITING_OPPONENT = "awaiting_opponent"
    COMPLETED = "completed"
    #: Nobody ever played, or the async deadline passed with one side idle.
    EXPIRED = "expired"
    CANCELLED = "cancelled"


#: Statuses where the match can still change. Anything else is history.
OPEN_MATCH_STATUSES = frozenset(
    {
        MatchStatus.PENDING,
        MatchStatus.LOBBY,
        MatchStatus.LIVE,
        MatchStatus.AWAITING_OPPONENT,
    }
)


class ParticipantStatus(str, enum.Enum):
    #: Challenged, has not answered the invite.
    INVITED = "invited"
    #: In the lobby.
    JOINED = "joined"
    #: Tapped ready; the match starts when everyone has.
    READY = "ready"
    PLAYING = "playing"
    FINISHED = "finished"
    DECLINED = "declined"
    #: Walked out mid-match, or ran out the async clock. Scores what they had.
    FORFEITED = "forfeited"


#: Participants who still owe the match something, so it cannot be finalized.
ACTIVE_PARTICIPANT_STATUSES = frozenset(
    {
        ParticipantStatus.JOINED,
        ParticipantStatus.READY,
        ParticipantStatus.PLAYING,
    }
)


class MatchOutcome(str, enum.Enum):
    WIN = "win"
    LOSS = "loss"
    DRAW = "draw"


class NotificationType(str, enum.Enum):
    FRIEND_REQUEST = "friend_request"
    FRIEND_ACCEPTED = "friend_accepted"
    MATCH_INVITE = "match_invite"
    MATCH_YOUR_TURN = "match_your_turn"
    MATCH_RESULT = "match_result"
    MATCH_EXPIRING = "match_expiring"


class DevicePlatform(str, enum.Enum):
    ANDROID = "android"
    IOS = "ios"


class CustomQuizVisibility(str, enum.Enum):
    """Who may open a player-authored quiz.

    Deliberately not a public tier. A browsable feed of user content needs
    screening on publish, a report queue and someone to work it; shipping the
    tier without that machinery is how a quiz app becomes a moderation
    incident. ``LINK`` covers the sharing the feature actually needs — the
    author decides who gets the code.
    """

    #: Only the author.
    PRIVATE = "private"
    #: The author and anyone they have an accepted friendship with.
    FRIENDS = "friends"
    #: Anyone holding the share code. Access, once used, is remembered in
    #: ``custom_quiz_access`` so the code is needed exactly once.
    LINK = "link"


class CustomQuizStatus(str, enum.Enum):
    #: Being written. Its questions sit at PENDING so the dealer skips them.
    DRAFT = "draft"
    PUBLISHED = "published"
    #: Author retired it. Existing results survive; it can no longer be started.
    ARCHIVED = "archived"
    #: Pulled by moderation once reports crossed the auto-hide threshold. Only
    #: the author can still see it, and only to read the reason.
    HIDDEN = "hidden"


#: Statuses a quiz can be started from.
PLAYABLE_QUIZ_STATUSES = frozenset({CustomQuizStatus.PUBLISHED})


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
    #: The handle other players search for and challenge by. Uniqueness is
    #: enforced case-insensitively by ``uq_user_profiles_username_lower`` — a
    #: plain unique constraint would happily seat both `Ravi` and `ravi`, which
    #: makes "add ravi" ambiguous and impersonation trivial.
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True, nullable=False)
    #: Folded form of `username` used to judge whether two handles are
    #: confusable: lowercased, separators dropped, and digits mapped to the
    #: letters they imitate, so `Ravi`, `r_a_v_i` and `R4vi` all reduce to
    #: `ravi`. Unique, because the impersonation this prevents is the whole
    #: reason a stranger can be challenged by name. Maintained by
    #: `app.services.usernames` — never write `username` without it.
    username_skeleton: Mapped[str] = mapped_column(
        String(32), unique=True, index=True, nullable=False, default=""
    )
    #: When the handle was last changed, for the rename cooldown. NULL means the
    #: player still has the auto-generated one and their first change is free.
    username_changed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Short, unambiguous invite code (Crockford-ish alphabet, no vowels, so it
    #: cannot spell anything and cannot be misread as 0/O or 1/I). Shared as a
    #: deep link; never used for login.
    friend_code: Mapped[Optional[str]] = mapped_column(String(12), unique=True, index=True)
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
    #: Per-event push opt-outs, e.g. ``{"match_invite": false}``. Absent keys
    #: mean opted in, so a new notification type does not need a backfill and
    #: an old client that cannot render the toggle still receives it.
    notification_prefs: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    onboarding_completed: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    theme_preference: Mapped[str] = mapped_column(String(16), default="dark", nullable=False)
    #: Language the app chrome is drawn in. The client owns this setting; we
    #: store it so a reinstall or a second device opens in the right language.
    app_language: Mapped[str] = language_column()
    #: Content language the quiz setup screen preselects. The run itself is
    #: governed by `quiz_sessions.language`, which is chosen per run.
    quiz_language: Mapped[str] = language_column()

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

    #: Head-to-head record across every finished match, friendly and ranked.
    #: Separate from `player_ratings`, which is per-season and ranked-only —
    #: this is the lifetime number a profile shows.
    multiplayer_played: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    multiplayer_wins: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    multiplayer_losses: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    multiplayer_draws: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

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
    #: ``{"hi": "विज्ञान"}`` — `name` stays the English source of truth and the
    #: fallback for any language without an entry.
    name_i18n: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

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
    #: A rolling current-affairs bank, rebuilt daily from the news corpus.
    #: Distinct from ``is_custom`` (which means "a player asked for this"):
    #: these are curated topics that happen to be perishable. The flag exists
    #: so the generic watermark top-up leaves them alone — filling a news bank
    #: with ungrounded questions is exactly the staleness this feature removes.
    is_news: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    popularity_score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    question_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: Localized display names keyed by language code — see TopicCategory.
    name_i18n: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: Localized descriptions keyed by language code.
    description_i18n: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: A bank a *player wrote by hand*, owned by one ``custom_quizzes`` row.
    #:
    #: Distinct from ``is_custom`` (an AI bank a player asked for) even though
    #: both are set on these topics: ``is_custom`` is what makes the generation
    #: watermark leave the bank alone, while this is what makes gameplay treat
    #: it as a **finite deck** — no reshuffling past the last question, no
    #: global leaderboard, no skill rating. Two different questions, so two
    #: different flags rather than one overloaded one.
    is_user_generated: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=text("false"), nullable=False
    )
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
    #: Language the generated bank is written in. Part of `cache_key` too, so
    #: the same prompt in two languages produces two banks, not one reused one.
    language: Mapped[str] = language_column()


class CustomQuiz(Base, TimestampMixin):
    """One quiz a player wrote themselves.

    The rows here are the *shell* — title, share code, visibility, counters.
    The questions live in the ordinary ``questions`` table under a hidden
    ``topics`` row that this quiz owns, which is the whole point of the design:
    every downstream system already speaks topic_id, so a hand-written quiz
    gets sessions, the three game modes, multiplayer boards, results, sharing
    and anti-cheat without any of them learning a new concept.

    A question's *draft-ness* is its ``QuestionStatus``: PENDING while the quiz
    is a draft (the dealer only ever selects ACTIVE), ACTIVE once published.
    That keeps one copy of the text rather than an authoring table and a
    published table that can drift apart.
    """

    __tablename__ = "custom_quizzes"
    __table_args__ = (
        # "My quizzes", newest first — the first screen the feature opens on.
        Index("ix_custom_quizzes_owner_status", "owner_user_id", "status"),
        Index("ix_custom_quizzes_owner_created", "owner_user_id", "created_at"),
        CheckConstraint(
            "question_count >= 0 AND play_count >= 0", name="ck_custom_quiz_counters"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    #: The bank this quiz owns. Created with the quiz and deleted with it —
    #: cascading, because a topic with no quiz in front of it is unreachable
    #: content that would still show up in every inventory count.
    topic_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE"), nullable=False, unique=True
    )

    title: Mapped[str] = mapped_column(String(80), nullable=False)
    description: Mapped[Optional[str]] = mapped_column(String(280))
    #: A single emoji. Stored wide enough for a ZWJ sequence.
    icon: Mapped[str] = mapped_column(String(16), default="🧠", nullable=False)
    #: Language the questions are written in. Fixed after the first question is
    #: added — a bank that mixes languages is unplayable in either.
    language: Mapped[str] = language_column()

    visibility: Mapped[CustomQuizVisibility] = mapped_column(
        pg_enum(CustomQuizVisibility, "custom_quiz_visibility"),
        default=CustomQuizVisibility.PRIVATE,
        nullable=False,
    )
    status: Mapped[CustomQuizStatus] = mapped_column(
        pg_enum(CustomQuizStatus, "custom_quiz_status"),
        default=CustomQuizStatus.DRAFT,
        nullable=False,
    )
    #: Share code, minted on first publish and kept stable afterwards so a link
    #: already sent to a friend keeps working across an unpublish/republish.
    code: Mapped[Optional[str]] = mapped_column(String(12), unique=True, index=True)

    #: Playable questions. Denormalized so a list of quizzes is one query.
    question_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: The author's suggested setup. The player can still choose otherwise.
    default_mode: Mapped[GameMode] = mapped_column(
        pg_enum(GameMode, "game_mode", create_constraint=False),
        default=GameMode.CASUAL,
        nullable=False,
    )
    default_difficulty: Mapped[DifficultyLabel] = mapped_column(
        pg_enum(DifficultyLabel, "difficulty_label", create_constraint=False),
        default=DifficultyLabel.MEDIUM,
        nullable=False,
    )

    play_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: Distinct players who have finished a run. Incremented on a player's
    #: first finish, which is the only cheap way to have the number at all.
    player_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: Top score anyone has posted, for the list row. The full ladder is a
    #: query over ``scores``; this is just the headline.
    top_score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    published_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    archived_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    #: Distinct players who have reported it. Crossing the configured threshold
    #: flips `status` to HIDDEN without waiting for a human.
    report_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    moderation_note: Mapped[Optional[str]] = mapped_column(String(255))


class CustomQuizAccess(Base):
    """A player's standing permission to open one quiz — and their library.

    Written when someone redeems a share code or is invited to a match on a
    quiz. Two jobs in one row: the code is then needed exactly once (a friend
    who played yesterday does not have to find the message again), and "quizzes
    shared with me" is a plain indexed read rather than a scan of match history.
    """

    __tablename__ = "custom_quiz_access"
    __table_args__ = (
        UniqueConstraint("quiz_id", "user_id", name="uq_custom_quiz_access"),
        # The player's library, newest first.
        Index("ix_custom_quiz_access_user_created", "user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    quiz_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("custom_quizzes.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    #: code | invite — how they got in. Kept for support and for analytics on
    #: which sharing path actually works.
    source: Mapped[str] = mapped_column(String(16), default="code", nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class CustomQuizReport(Base):
    """One player's report of one quiz.

    Unique per (quiz, player) so ``report_count`` counts distinct people rather
    than distinct taps — the auto-hide threshold is meaningless otherwise, and
    a single motivated account could bury anyone's quiz.
    """

    __tablename__ = "custom_quiz_reports"
    __table_args__ = (
        UniqueConstraint("quiz_id", "user_id", name="uq_custom_quiz_report_once"),
        Index("ix_custom_quiz_reports_status", "status", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    quiz_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("custom_quizzes.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    reason: Mapped[str] = mapped_column(String(32), nullable=False)
    details: Mapped[Optional[str]] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(16), default="open", nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Question(Base, TimestampMixin):
    __tablename__ = "questions"
    __table_args__ = (
        # The dealing query in quiz_service._select_questions filters on
        # exactly this prefix — topic, language, status — before narrowing by
        # difficulty band. Language sits second because every read is now
        # language-scoped: serving a Hindi run an English question is a bug,
        # not a fallback.
        Index(
            "ix_questions_topic_language_status",
            "topic_id",
            "language",
            "status",
            "difficulty",
        ),
        Index("ix_questions_quality_status", "quality_score", "status"),
        # Only the perishable minority. The sweep that retires them scans this
        # instead of the whole table, and a bank of permanent questions carries
        # no index-maintenance cost for a feature it never uses.
        Index(
            "ix_questions_expiring",
            "expires_at",
            postgresql_where=text("expires_at IS NOT NULL"),
        ),
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
    #: Language this question is *written in*. Never translated at serve time —
    #: gameplay reads the bank directly and must not call an LLM.
    language: Mapped[str] = language_column()
    source: Mapped[Optional[str]] = mapped_column(String(255))
    difficulty: Mapped[float] = mapped_column(Float, nullable=False, default=0.5)
    difficulty_label: Mapped[DifficultyLabel] = mapped_column(pg_enum(DifficultyLabel, "difficulty_label", create_constraint=False),
        default=DifficultyLabel.MEDIUM,
        nullable=False,
    )
    #: NULL for a numeric-entry question, which has no options at all. It was
    #: non-null for the whole life of the bank before exam mode, and every row
    #: written then still has a value.
    correct_option_index: Mapped[Optional[int]] = mapped_column(Integer)
    #: How this question is answered. ``single`` is the server default, so the
    #: entire pre-existing bank is already correct without a data migration.
    answer_type: Mapped[AnswerType] = mapped_column(
        pg_enum(AnswerType, "answer_type", create_constraint=False),
        default=AnswerType.SINGLE,
        server_default=AnswerType.SINGLE.value,
        nullable=False,
    )
    #: The answer, for anything ``correct_option_index`` cannot express:
    #: ``{"value": 13.5, "tolerance": 0.01, "mode": "absolute"}`` for numeric,
    #: ``{"mask": [0, 2]}`` for multi-select. One JSON column rather than a
    #: column per answer type, so a future type needs no migration.
    answer_spec: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: Structured content blocks — text with inline LaTeX, and figure
    #: references. ``prompt`` stays the flat rendering, which is what dedup,
    #: search and moderation read, and what an older client falls back to.
    content: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: Per-option blocks, parallel to ``options`` by position. Kept off
    #: ``QuestionOption`` so that table stays a narrow hot-path read.
    option_content: Mapped[list] = mapped_column(JSONB, default=list, nullable=False)
    #: Whether the worked solution in ``explanation`` can be shown. See
    #: ``SolutionStatus`` — an unverified solution is withheld, not displayed.
    solution_status: Mapped[SolutionStatus] = mapped_column(
        pg_enum(SolutionStatus, "solution_status", create_constraint=False),
        default=SolutionStatus.VERIFIED,
        server_default=SolutionStatus.VERIFIED.value,
        nullable=False,
    )
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
    #: When this fact was last known true — the publish date of the source it
    #: came from, not the row's creation time. A question written today from a
    #: three-week-old article is three weeks old, and its TTL is measured from
    #: the article.
    valid_as_of: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: When to stop dealing this question. NULL means never, which is what
    #: every row written before freshness existed means — so the sweep leaves
    #: the entire legacy bank alone.
    expires_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: How fast the answer goes stale. See ``app.core.freshness``.
    volatility: Mapped[str] = mapped_column(
        String(16),
        default=DEFAULT_VOLATILITY.value,
        server_default=DEFAULT_VOLATILITY.value,
        nullable=False,
    )
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
    #: Content language for the whole run. Fixed at creation: a run that
    #: switched languages mid-way would break both the streak and the bank's
    #: seen-question bookkeeping.
    language: Mapped[str] = language_column()
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
    """One store subscription, mirrored from Apple / Google.

    The store is always the source of truth. Every column here is a cache of
    what a verification call or a server notification last told us, so the
    resolver can answer "is this user premium?" without a network hop.
    """

    __tablename__ = "subscriptions"
    __table_args__ = (
        # Identity of a subscription at the store. Apple gives us a stable
        # originalTransactionId; on Play we follow linkedPurchaseToken back to
        # the first token in the upgrade chain and use that.
        UniqueConstraint(
            "platform", "store_subscription_id", name="uq_subscription_store_identity"
        ),
        Index("ix_subscriptions_user_status", "user_id", "status"),
        # Drives the "which subscriptions need re-syncing?" sweep.
        Index("ix_subscriptions_status_expires", "status", "expires_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    status: Mapped[SubscriptionStatus] = mapped_column(pg_enum(SubscriptionStatus, "subscription_status"),
        default=SubscriptionStatus.NONE,
        nullable=False,
    )
    platform: Mapped[str] = mapped_column(String(16), nullable=False, default="android")
    product_id: Mapped[Optional[str]] = mapped_column(String(128))
    #: PlanCode value — monthly / annual / legacy_lifetime.
    plan_code: Mapped[Optional[str]] = mapped_column(String(32))

    #: Stable store identity; see the unique constraint above. Text rather than
    #: a bounded String because on Play this *is* a purchase token, and those
    #: routinely run past 255 characters.
    store_subscription_id: Mapped[str] = mapped_column(Text, nullable=False)
    #: Apple's originalTransactionId. Kept as its own column because restore
    #: and legacy rows both key off it.
    original_transaction_id: Mapped[Optional[str]] = mapped_column(String(255), index=True)
    #: Most recent transaction/order id, for support lookups and refunds.
    latest_transaction_id: Mapped[Optional[str]] = mapped_column(String(255))
    #: Play purchase token for the *current* item in the upgrade chain. Long
    #: enough that String(255) would truncate, so Text.
    purchase_token: Mapped[Optional[str]] = mapped_column(Text)

    started_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    current_period_start: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Set while the store is retrying a failed renewal. Premium survives here.
    grace_until: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Play-only: when a paused subscription resumes on its own.
    auto_resume_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    cancelled_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    auto_renewing: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    #: Free-text reason from the store (user_initiated, billing_error, …).
    cancel_reason: Mapped[Optional[str]] = mapped_column(String(64))
    #: True while an introductory / promotional price is being charged.
    is_intro_offer: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    offer_id: Mapped[Optional[str]] = mapped_column(String(128))

    #: Billing country and money, straight from the store payload. Kept for
    #: revenue reporting by market (IN vs US) — never used for entitlement.
    country: Mapped[Optional[str]] = mapped_column(String(8))
    currency: Mapped[Optional[str]] = mapped_column(String(8))
    price_micros: Mapped[Optional[int]] = mapped_column(BigInteger)

    #: Sandbox / Production. A sandbox purchase must never grant real premium
    #: in a production deployment.
    environment: Mapped[Optional[str]] = mapped_column(String(16))
    #: True for Play licence-test purchases and Apple sandbox transactions.
    is_test: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    last_verified_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    entitlements: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: Last raw store payload, redacted of tokens. Support and dispute triage.
    raw: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)


class BillingEvent(Base):
    """Append-only log of store notifications.

    Two jobs: idempotency (stores retry notifications aggressively, and Play
    redelivers the whole Pub/Sub backlog after an outage) and forensics — when
    a player says "I paid and got nothing", this table is the receipt.
    """

    __tablename__ = "billing_events"
    __table_args__ = (
        # The store's own event id. Unique so a redelivery is a no-op insert
        # conflict rather than a double-grant.
        UniqueConstraint("provider", "event_id", name="uq_billing_event_provider_id"),
        Index("ix_billing_events_store_subscription", "store_subscription_id"),
        Index("ix_billing_events_created", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    provider: Mapped[str] = mapped_column(String(16), nullable=False)  # apple / google
    event_id: Mapped[str] = mapped_column(String(255), nullable=False)
    notification_type: Mapped[Optional[str]] = mapped_column(String(64))
    subtype: Mapped[Optional[str]] = mapped_column(String(64))
    #: Play purchase tokens exceed 255 characters; see Subscription above.
    store_subscription_id: Mapped[Optional[str]] = mapped_column(Text)
    product_id: Mapped[Optional[str]] = mapped_column(String(128))
    user_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL")
    )
    subscription_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("subscriptions.id", ondelete="SET NULL")
    )
    payload: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    processed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    error: Mapped[Optional[str]] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


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
    #: Which language bank this job fills. A column rather than a payload key
    #: so the "is a top-up already in flight?" check stays a plain indexed
    #: predicate — that check runs on the session-create path.
    language: Mapped[str] = language_column()
    error_message: Mapped[Optional[str]] = mapped_column(Text)
    payload: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)


class NewsDocument(Base, TimestampMixin):
    """One retrieved fact the generator may build questions from.

    Title, summary, link and publish date only — never article body. Facts are
    not copyrightable and a question derived from one is our own work, but a
    stored copy of the prose is the publisher's, so the harvester deliberately
    keeps what an RSS feed already offers for syndication and nothing more.

    This is the piece that makes current-affairs content affordable. Ten
    thousand players asking about this week's news share one harvest of these
    rows, so retrieval cost scales with *topics × days* rather than with users.
    """

    __tablename__ = "news_documents"
    __table_args__ = (
        # Retrieval is always "recent documents in one language", optionally
        # narrowed to a category. Publish date descends because every query
        # wants the newest first and an ordered index scan avoids a sort.
        Index(
            "ix_news_documents_language_published",
            "language",
            "published_at",
        ),
        Index("ix_news_documents_category_published", "category", "published_at"),
        Index(
            "ix_news_documents_search",
            "search_vector",
            postgresql_using="gin",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    source: Mapped[str] = mapped_column(String(120), nullable=False)
    url: Mapped[str] = mapped_column(Text, nullable=False)
    title: Mapped[str] = mapped_column(Text, nullable=False)
    summary: Mapped[str] = mapped_column(Text, default="", nullable=False)
    #: Publish date from the feed. Drives both retrieval ordering and the TTL
    #: of every question generated from this row, so a document with no usable
    #: date is dropped at harvest rather than stored undated.
    published_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, index=True
    )
    language: Mapped[str] = language_column()
    #: Coarse bucket — india, world, sport, tech, business, entertainment.
    #: Set per feed, not inferred, so it costs nothing and never drifts.
    category: Mapped[str] = mapped_column(String(40), default="general", nullable=False)
    #: Dedupe key over (url, title). The same story arrives from several feeds
    #: and the same feed re-serves it for days.
    content_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    #: Set by the database clock, not the client's.
    #:
    #: The obvious `default=utcnow` is wrong here: that helper returns a *naive*
    #: datetime, and a naive value bound to a `timestamptz` is interpreted in
    #: the writer's local zone. A harvest run from an IST workstation recorded
    #: 02:33 UTC as 21:03 the previous day — harmless for retrieval, which
    #: orders by `published_at`, but it makes the one column you reach for when
    #: asking "is the harvester actually running?" lie to you.
    fetched_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    #: Generated by Postgres so it can never disagree with the text it indexes.
    #:
    #: The config is chosen per row: English gets stemming, Hindi falls back to
    #: `simple`, because Postgres ships no Hindi stemmer and `english` applied
    #: to Devanagari would tokenize but stem nonsense. The two-argument
    #: `to_tsvector` is required here — the one-argument form reads
    #: `default_text_search_config` and so is only STABLE, which a generated
    #: column rejects.
    search_vector: Mapped[str] = mapped_column(
        TSVECTOR,
        Computed(
            "to_tsvector("
            "CASE WHEN language = 'en' THEN 'english'::regconfig "
            "ELSE 'simple'::regconfig END, "
            "coalesce(title, '') || ' ' || coalesce(summary, ''))",
            persisted=True,
        ),
        nullable=True,
    )


class Friendship(Base, TimestampMixin):
    """One directed friend request and, once accepted, the friendship itself.

    Kept as a single directed row rather than a request table plus an edge
    table: who asked matters (the addressee is the one who can accept), and
    collapsing the two states into one row means accepting is an UPDATE and
    can never leave a request and an edge disagreeing with each other.

    ``pair_key`` is generated by Postgres so the unordered pair {A,B} has one
    canonical spelling no matter which direction the row was written in. The
    partial unique index on it is what stops A and B from each holding an open
    request to the other; the service turns that crossing case into an instant
    mutual accept instead.
    """

    __tablename__ = "friendships"
    __table_args__ = (
        Index(
            "uq_friendship_open_pair",
            "pair_key",
            unique=True,
            postgresql_where=text("status IN ('pending', 'accepted')"),
        ),
        # "Who are my friends?" and "who is waiting on me?" both read from here.
        Index("ix_friendships_addressee_status", "addressee_id", "status"),
        Index("ix_friendships_requester_status", "requester_id", "status"),
        CheckConstraint("requester_id <> addressee_id", name="ck_friendship_not_self"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    requester_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    addressee_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    status: Mapped[FriendshipStatus] = mapped_column(
        pg_enum(FriendshipStatus, "friendship_status"),
        default=FriendshipStatus.PENDING,
        nullable=False,
    )
    responded_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Canonical spelling of the unordered pair — see the class docstring.
    pair_key: Mapped[str] = mapped_column(
        String(73),
        Computed(
            "CASE WHEN requester_id < addressee_id "
            "THEN requester_id::text || ':' || addressee_id::text "
            "ELSE addressee_id::text || ':' || requester_id::text END",
            persisted=True,
        ),
        nullable=False,
    )


class UserBlock(Base, TimestampMixin):
    """A one-way block. Hides the blocker, and refuses requests and invites.

    Separate from ``friendships`` on purpose: a block must survive unfriending
    and must not occupy the open-pair slot, or unblocking someone would leave
    the pair unable to become friends again.
    """

    __tablename__ = "user_blocks"
    __table_args__ = (
        UniqueConstraint("blocker_id", "blocked_id", name="uq_user_block_pair"),
        CheckConstraint("blocker_id <> blocked_id", name="ck_user_block_not_self"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    blocker_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    blocked_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    reason: Mapped[Optional[str]] = mapped_column(String(64))


class Match(Base, TimestampMixin):
    """One multiplayer game: a duel, a private room, or a ranked pairing.

    The question set is decided once, at creation, and frozen into
    ``question_ids`` + ``option_orders``. Everyone in the match therefore sees
    the same prompts in the same order with the same answer buttons in the same
    positions — which is what makes the comparison meaningful, and what lets an
    async opponent play the identical board hours later.

    The answer key is deliberately *not* stored here. Correctness is resolved
    against the `questions` row at submit time, so nothing the client can reach
    ever contains it.
    """

    __tablename__ = "matches"
    __table_args__ = (
        # The lobby list and the "do I owe someone a turn?" badge both scan by
        # status; the created_at leg keeps the newest-first ordering indexed.
        Index("ix_matches_status_created", "status", "created_at"),
        # Drives the expiry sweep for abandoned async challenges.
        Index("ix_matches_status_expires", "status", "expires_at"),
        CheckConstraint("max_players BETWEEN 2 AND 8", name="ck_match_seat_count"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    #: Shareable room code. Only friendly matches get one — a ranked pairing is
    #: not something you invite anyone into.
    code: Mapped[Optional[str]] = mapped_column(String(12), unique=True, index=True)
    format: Mapped[MatchFormat] = mapped_column(
        pg_enum(MatchFormat, "match_format"), default=MatchFormat.DUEL, nullable=False
    )
    kind: Mapped[MatchKind] = mapped_column(
        pg_enum(MatchKind, "match_kind"), default=MatchKind.FRIENDLY, nullable=False
    )
    delivery: Mapped[MatchDelivery] = mapped_column(
        pg_enum(MatchDelivery, "match_delivery"), default=MatchDelivery.LIVE, nullable=False
    )
    status: Mapped[MatchStatus] = mapped_column(
        pg_enum(MatchStatus, "match_status"), default=MatchStatus.PENDING, nullable=False
    )

    created_by_user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    topic_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="CASCADE"), nullable=False
    )
    mode: Mapped[GameMode] = mapped_column(
        pg_enum(GameMode, "game_mode", create_constraint=False),
        default=GameMode.CASUAL,
        nullable=False,
    )
    difficulty: Mapped[DifficultyLabel] = mapped_column(
        pg_enum(DifficultyLabel, "difficulty_label", create_constraint=False),
        default=DifficultyLabel.MEDIUM,
        nullable=False,
    )
    #: Content language for the whole match. Every participant plays the same
    #: language, because they are playing the same questions.
    language: Mapped[str] = language_column()

    max_players: Mapped[int] = mapped_column(Integer, default=2, nullable=False)
    question_count: Mapped[int] = mapped_column(Integer, default=7, nullable=False)
    question_time_limit_ms: Mapped[int] = mapped_column(Integer, default=15000, nullable=False)

    #: Ordered bank question ids, one per round.
    question_ids: Mapped[list] = mapped_column(JSONB, default=list, nullable=False)
    #: Per-round option permutation, parallel to `question_ids`. Shared, so two
    #: players comparing screens see the same button in the same place.
    option_orders: Mapped[list] = mapped_column(JSONB, default=list, nullable=False)
    #: Seed the set was drawn with. Kept for support and dispute triage.
    seed: Mapped[str] = mapped_column(String(64), default="", nullable=False)

    current_round_index: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: When the live round clock started. NULL between rounds.
    round_started_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    started_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Async deadline, or the lobby's patience for a live match nobody joins.
    expires_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    #: True once Elo has been settled, so a replayed finalize cannot double-pay.
    rating_applied: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    #: Season the ranked result counted toward, e.g. "2026-08".
    season_key: Mapped[Optional[str]] = mapped_column(String(16), index=True)
    config: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    participants: Mapped[list["MatchParticipant"]] = relationship(
        back_populates="match", cascade="all, delete-orphan"
    )


class MatchParticipant(Base, TimestampMixin):
    __tablename__ = "match_participants"
    __table_args__ = (
        UniqueConstraint("match_id", "user_id", name="uq_match_participant"),
        # "My matches" reads this: every list the player sees starts here.
        Index("ix_match_participants_user_status", "user_id", "status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    match_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("matches.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    status: Mapped[ParticipantStatus] = mapped_column(
        pg_enum(ParticipantStatus, "participant_status"),
        default=ParticipantStatus.INVITED,
        nullable=False,
    )
    is_host: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    correct_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    incorrect_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    best_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: Sum of server-resolved answer times. Breaks a tie on equal score, which
    #: is common on short question sets.
    total_answer_ms: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: How far this player has got. In an async match the two sides diverge.
    rounds_answered: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: When this player was handed their current round. A live match times
    #: every player off one shared clock on the match row; an async match has
    #: no shared clock at all, so each side's speed bonus is measured from the
    #: moment *they* were served.
    round_served_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    joined_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Last realtime heartbeat, for the live presence dot and drop detection.
    last_seen_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    placement: Mapped[Optional[int]] = mapped_column(Integer)
    outcome: Mapped[Optional[MatchOutcome]] = mapped_column(
        pg_enum(MatchOutcome, "match_outcome")
    )
    rating_before: Mapped[Optional[int]] = mapped_column(Integer)
    rating_after: Mapped[Optional[int]] = mapped_column(Integer)
    xp_earned: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    coins_earned: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    match: Mapped[Match] = relationship(back_populates="participants")


class MatchAnswer(Base):
    __tablename__ = "match_answers"
    __table_args__ = (
        # One answer per player per round, enforced by the database rather than
        # by a read-then-write in the service — two taps racing on a flaky
        # connection is the normal case, not the exotic one.
        UniqueConstraint("participant_id", "round_index", name="uq_match_answer_once"),
        Index("ix_match_answers_match_round", "match_id", "round_index"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    match_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("matches.id", ondelete="CASCADE"), nullable=False
    )
    participant_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("match_participants.id", ondelete="CASCADE"), nullable=False
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    round_index: Mapped[int] = mapped_column(Integer, nullable=False)
    question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("questions.id", ondelete="CASCADE"), nullable=False
    )
    #: NULL means the clock ran out with nothing selected.
    selected_option_index: Mapped[Optional[int]] = mapped_column(Integer)
    is_correct: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    client_elapsed_ms: Mapped[Optional[int]] = mapped_column(Integer)
    server_elapsed_ms: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    base_points: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    speed_bonus: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    streak_multiplier: Mapped[Decimal] = mapped_column(Numeric(4, 2), default=1, nullable=False)
    points_awarded: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    answered_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class PlayerRating(Base, TimestampMixin):
    """Elo-style ranked rating, one row per player per season.

    Seasons are a key rather than a table (`YYYY-MM`): rollover is then simply
    the first ranked match of a new month creating a fresh row seeded from the
    old one, with no scheduled job that can fail to run and no window where the
    ladder is missing.
    """

    __tablename__ = "player_ratings"
    __table_args__ = (
        UniqueConstraint("user_id", "season_key", name="uq_player_rating_season"),
        # The ranked ladder page, and the matchmaker's band query.
        Index("ix_player_ratings_season_rating", "season_key", "rating"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    season_key: Mapped[str] = mapped_column(String(16), nullable=False)
    rating: Mapped[int] = mapped_column(Integer, default=1000, nullable=False)
    peak_rating: Mapped[int] = mapped_column(Integer, default=1000, nullable=False)
    #: Placement matches move rating harder and hide the tier until done.
    placements_remaining: Mapped[int] = mapped_column(Integer, default=5, nullable=False)
    matches_played: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    wins: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    losses: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    draws: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    win_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    best_win_streak: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    last_match_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))


class DeviceToken(Base, TimestampMixin):
    """An FCM registration token for one install of the app.

    Tokens are owned by an install, not by an account: signing out of a shared
    phone must not keep pushing the previous player's challenges to it, so the
    service reassigns a token to whoever registers it last rather than letting
    two users hold the same one.
    """

    __tablename__ = "device_tokens"
    __table_args__ = (
        Index("ix_device_tokens_user_active", "user_id", "is_active"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    #: FCM tokens have no documented maximum and run well past 255 characters.
    token: Mapped[str] = mapped_column(Text, unique=True, nullable=False)
    platform: Mapped[DevicePlatform] = mapped_column(
        pg_enum(DevicePlatform, "device_platform"),
        default=DevicePlatform.ANDROID,
        nullable=False,
    )
    app_version: Mapped[Optional[str]] = mapped_column(String(32))
    #: App language at registration time, so a push can be written in it
    #: without a join back to the profile on the send path.
    language: Mapped[str] = language_column()
    #: Device's offset from UTC in minutes, reported by the client. This is the
    #: only way the server can know that 22:00 "local" means something
    #: different in Mumbai and in London, and quiet hours are worse than
    #: useless if they silence the wrong six hours.
    utc_offset_minutes: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    last_seen_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Consecutive send failures. FCM's UNREGISTERED retires a token outright;
    #: this catches the slower rot of tokens that merely stop working.
    failure_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)


class Notification(Base):
    """In-app inbox row. Also the audit trail for what push was attempted.

    Stores a `type` plus a data `payload` rather than rendered text, so the
    client draws it from its own compile-checked string table and the row does
    not go stale when the player switches language. Push notifications, which
    have to carry real words, are rendered separately at send time.
    """

    __tablename__ = "notifications"
    __table_args__ = (
        Index("ix_notifications_user_created", "user_id", "created_at"),
        # Powers the unread badge without scanning the whole inbox.
        Index(
            "ix_notifications_user_unread",
            "user_id",
            postgresql_where=text("read_at IS NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    type: Mapped[NotificationType] = mapped_column(
        pg_enum(NotificationType, "notification_type"), nullable=False
    )
    #: Who caused this — the challenger, the friend who accepted.
    actor_user_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    match_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("matches.id", ondelete="CASCADE")
    )
    payload: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: In-app route this opens, e.g. `/battle/match/<id>`.
    deep_link: Mapped[Optional[str]] = mapped_column(String(255))
    read_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    pushed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


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


# ---------------------------------------------------------------------------
# Exam mode: past-year papers and the mock tests run against them.
#
# The content layer sits *on top of* `questions` rather than beside it. Every
# paper owns one hidden `topics` row and writes ordinary `questions` under it,
# exactly as `CustomQuiz` does — so practice mode, the three game modes,
# multiplayer, scoring and anti-cheat all keep working against a concept they
# already have, and only the timed full-length attempt needs new machinery.
#
# What genuinely could not be reused is the *attempt*: a three-hour paper needs
# free navigation, mark-for-review, changing an answer, one shared clock and
# submit-at-end, and `QuizSession` is built around answer-once-and-advance with
# a per-question timer (`uq_answer_once` makes changing an answer a constraint
# violation). Hence `MockTestAttempt` below.
# ---------------------------------------------------------------------------


class ExamPaperStatus(str, enum.Enum):
    DRAFT = "draft"
    IN_REVIEW = "in_review"
    PUBLISHED = "published"
    ARCHIVED = "archived"


class AttemptMode(str, enum.Enum):
    FULL = "full"
    SECTIONAL = "sectional"
    PRACTICE = "practice"


class AttemptStatus(str, enum.Enum):
    IN_PROGRESS = "in_progress"
    SUBMITTED = "submitted"
    #: The deadline passed without a client submission — app killed, phone
    #: died, tunnel. Scored exactly like a submission; the distinction is kept
    #: only so the results screen can say what happened.
    AUTO_SUBMITTED = "auto_submitted"
    ABANDONED = "abandoned"


class ResponseState(str, enum.Enum):
    """The five states of the official CBT answer palette.

    Mirrored exactly, colours included, because candidates have drilled on this
    palette for two years and inventing a different one is a usability cost
    with no upside.
    """

    NOT_VISITED = "not_visited"
    NOT_ANSWERED = "not_answered"
    ANSWERED = "answered"
    MARKED = "marked"
    ANSWERED_AND_MARKED = "answered_and_marked"


class Exam(Base, TimestampMixin):
    __tablename__ = "exams"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    slug: Mapped[str] = mapped_column(String(64), unique=True, nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    #: NTA, IIT, AIIMS — shown on the paper card, and the thing a student
    #: recognises as the authority behind the key.
    authority: Mapped[Optional[str]] = mapped_column(String(120))
    description: Mapped[Optional[str]] = mapped_column(Text)
    icon: Mapped[str] = mapped_column(String(64), default="exam", nullable=False)
    #: Fallback marking when a section does not override it.
    default_marking: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    name_i18n: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    papers: Mapped[list["ExamPaper"]] = relationship(back_populates="exam")


class ExamPaper(Base, TimestampMixin):
    """One real paper that was actually sat."""

    __tablename__ = "exam_papers"
    __table_args__ = (
        UniqueConstraint(
            "exam_id", "year", "session", "shift", "paper_code",
            name="uq_exam_paper_identity",
        ),
        # The catalog read: published papers for one exam, newest first.
        Index("ix_exam_papers_exam_status_year", "exam_id", "status", "year"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    exam_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("exams.id", ondelete="CASCADE"), nullable=False, index=True
    )
    #: Stable identity from the ingestion pipeline
    #: ("jee-main-2025-january-shift1"). Re-ingesting the same PDF lands here.
    key: Mapped[str] = mapped_column(String(120), unique=True, nullable=False, index=True)

    year: Mapped[int] = mapped_column(Integer, nullable=False)
    #: "january" / "april". Empty string rather than NULL so the unique
    #: constraint above actually constrains — in Postgres, NULLs never collide.
    session: Mapped[str] = mapped_column(String(32), default="", server_default="", nullable=False)
    shift: Mapped[int] = mapped_column(Integer, default=0, server_default="0", nullable=False)
    paper_code: Mapped[str] = mapped_column(String(32), default="", server_default="", nullable=False)
    held_on: Mapped[Optional[date]] = mapped_column(Date)

    title: Mapped[str] = mapped_column(String(160), nullable=False)
    duration_minutes: Mapped[int] = mapped_column(Integer, default=180, nullable=False)
    total_marks: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    question_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    language: Mapped[str] = language_column()

    #: The hidden bank this paper owns — the CustomQuiz trick. Practice mode
    #: deals out of it with the existing dealer and needs no new code.
    topic_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("topics.id", ondelete="SET NULL"), unique=True
    )

    status: Mapped[ExamPaperStatus] = mapped_column(
        pg_enum(ExamPaperStatus, "exam_paper_status"),
        default=ExamPaperStatus.DRAFT,
        nullable=False,
    )
    #: Free users get a couple of papers per exam; the rest are premium.
    is_free: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    #: Provenance, so a bad paper can be traced back to the PDF that made it.
    source_pdf: Mapped[Optional[str]] = mapped_column(String(255))
    source_sha256: Mapped[Optional[str]] = mapped_column(String(64), index=True)
    ingest_meta: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    attempt_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    published_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    exam: Mapped[Exam] = relationship(back_populates="papers")
    sections: Mapped[list["ExamSection"]] = relationship(
        back_populates="paper", cascade="all, delete-orphan", order_by="ExamSection.position"
    )
    questions: Mapped[list["ExamQuestion"]] = relationship(
        back_populates="paper", cascade="all, delete-orphan",
        order_by="ExamQuestion.question_number",
    )


class ExamSection(Base, TimestampMixin):
    """A section of a paper, and the rules that score it.

    Marking lives here as data rather than in code so that adding an exam is a
    row, not a release: JEE's +4/-1, GATE's +1/-1/3 and NAT's no-negative all
    differ only in this JSON.
    """

    __tablename__ = "exam_sections"
    __table_args__ = (
        UniqueConstraint("paper_id", "position", name="uq_exam_section_position"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    paper_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("exam_papers.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    subject: Mapped[str] = mapped_column(String(80), nullable=False)
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    first_question: Mapped[int] = mapped_column(Integer, nullable=False)
    last_question: Mapped[int] = mapped_column(Integer, nullable=False)
    question_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    answer_type: Mapped[AnswerType] = mapped_column(
        pg_enum(AnswerType, "answer_type", create_constraint=False),
        default=AnswerType.SINGLE,
        nullable=False,
    )
    #: ``{"correct": 4, "incorrect": -1, "unattempted": 0}``
    marking: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: ``{"count_best_n": 5}`` — JEE Section B scores only the best 5 attempted.
    rules: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    #: NULL means the section shares the paper's single clock, which is the
    #: normal case; a value locks the section independently (GATE-style).
    time_limit_minutes: Mapped[Optional[int]] = mapped_column(Integer)

    paper: Mapped[ExamPaper] = relationship(back_populates="sections")


class ExamQuestion(Base, TimestampMixin):
    """A question's place in a paper, plus what is true of it only here.

    The question text lives in ``questions``; this row carries the per-paper
    facts — its printed number, what it is worth, and whether the board later
    revised the key.
    """

    __tablename__ = "exam_questions"
    __table_args__ = (
        UniqueConstraint("paper_id", "question_number", name="uq_exam_question_number"),
        Index("ix_exam_questions_paper_section", "paper_id", "section_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    paper_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("exam_papers.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    section_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("exam_sections.id", ondelete="SET NULL")
    )
    question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("questions.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    question_number: Mapped[int] = mapped_column(Integer, nullable=False)
    marks: Mapped[float] = mapped_column(Float, default=1, nullable=False)
    negative_marks: Mapped[float] = mapped_column(Float, default=0, nullable=False)

    #: Boards drop or regrade questions every year. Bumping the revision and
    #: widening ``accepted_answers`` fixes the key without rewriting history,
    #: and a re-score job replays the attempts it affected.
    key_revision: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    #: Awarded to everyone who attempted it, right or wrong.
    is_dropped: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    #: Extra answers the board later accepted, in the same shape as
    #: ``Question.answer_spec``.
    accepted_answers: Mapped[list] = mapped_column(JSONB, default=list, nullable=False)

    #: What the board actually printed, kept verbatim for auditing a dispute.
    answer_key_raw: Mapped[Optional[str]] = mapped_column(String(64))

    paper: Mapped[ExamPaper] = relationship(back_populates="questions")
    question: Mapped["Question"] = relationship()


class QuestionAsset(Base, TimestampMixin):
    """One figure, stored content-addressed.

    ``checksum`` is the sha256 of the canonical PNG and doubles as the storage
    key, which makes the object immutable by construction: correcting a figure
    produces a new key. That earns a one-year immutable cache header, a near
    100% CDN hit rate, and free dedup when the same figure appears in two
    shifts of the same paper.
    """

    __tablename__ = "question_assets"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    checksum: Mapped[str] = mapped_column(String(64), unique=True, nullable=False, index=True)
    kind: Mapped[str] = mapped_column(String(16), default="raster", nullable=False)
    width: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    height: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    alt_text: Mapped[Optional[str]] = mapped_column(Text)
    #: ``{"light": {"url": ..., "bytes": n}, "dark": {...}}``. A single
    #: black-on-white diagram is illegible on a dark ground, so both variants
    #: are baked at ingest rather than inverted at runtime.
    variants: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    total_bytes: Mapped[int] = mapped_column(Integer, default=0, nullable=False)


class QuestionAssetLink(Base):
    """Which figures a question uses, and in what role."""

    __tablename__ = "question_asset_links"
    __table_args__ = (
        UniqueConstraint("question_id", "ref", name="uq_question_asset_ref"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("questions.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    asset_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("question_assets.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    #: The token the content blocks refer to ("fig1"), stable within a question.
    ref: Mapped[str] = mapped_column(String(16), nullable=False)
    role: Mapped[str] = mapped_column(String(24), default="figure", nullable=False)
    position: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    asset: Mapped[QuestionAsset] = relationship()


class MockTestAttempt(Base, TimestampMixin):
    __tablename__ = "mock_test_attempts"
    __table_args__ = (
        Index("ix_mock_attempts_user_status", "user_id", "status"),
        Index("ix_mock_attempts_paper_score", "paper_id", "score"),
        # The auto-submit sweep scans only live attempts past their deadline,
        # which is a tiny slice of a table that grows without bound.
        Index(
            "ix_mock_attempts_live_deadline",
            "server_deadline_at",
            postgresql_where=text("status = 'in_progress'"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    paper_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("exam_papers.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    mode: Mapped[AttemptMode] = mapped_column(
        pg_enum(AttemptMode, "attempt_mode"), default=AttemptMode.FULL, nullable=False
    )
    status: Mapped[AttemptStatus] = mapped_column(
        pg_enum(AttemptStatus, "attempt_status"),
        default=AttemptStatus.IN_PROGRESS,
        nullable=False,
    )
    #: Only set for a sectional attempt.
    section_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True), ForeignKey("exam_sections.id", ondelete="SET NULL")
    )

    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    #: Stamped once, at start. The client counts down locally against a
    #: server-supplied clock and every sync returns the authoritative
    #: remainder; client-reported elapsed time is never trusted for scoring.
    server_deadline_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    submitted_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    #: Monotonic counter the client echoes back, so an out-of-order sync
    #: arriving after a retry cannot overwrite newer answers.
    last_sync_revision: Mapped[int] = mapped_column(BigInteger, default=0, nullable=False)

    score: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    max_score: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    correct_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    incorrect_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    unattempted_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    #: ``{"<section_id>": {"score": 44, "correct": 12, ...}}``
    section_scores: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    percentile: Mapped[Optional[float]] = mapped_column(Float)
    total_time_ms: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    config: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    paper: Mapped[ExamPaper] = relationship()


class MockTestResponse(Base):
    """One candidate's state on one question.

    The fastest-growing table in the schema — 90 rows per attempt — and the
    reason the client syncs deltas in batches rather than writing per tap. The
    composite primary key makes a sync an idempotent bulk upsert.
    """

    __tablename__ = "mock_test_responses"
    __table_args__ = (
        PrimaryKeyConstraint("attempt_id", "exam_question_id", name="pk_mock_test_response"),
    )

    attempt_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("mock_test_attempts.id", ondelete="CASCADE"),
        nullable=False,
    )
    exam_question_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("exam_questions.id", ondelete="CASCADE"), nullable=False
    )
    state: Mapped[ResponseState] = mapped_column(
        pg_enum(ResponseState, "response_state"),
        default=ResponseState.NOT_VISITED,
        nullable=False,
    )
    #: Selected option indices, 0-based. A list even for single-choice, so
    #: multi-select needs no second column and no migration.
    selected: Mapped[list] = mapped_column(JSONB, default=list, nullable=False)
    numeric_value: Mapped[Optional[float]] = mapped_column(Float)
    #: Exactly what the candidate typed, before parsing. A dispute about a
    #: numeric answer is unresolvable without it.
    numeric_raw: Mapped[Optional[str]] = mapped_column(String(64))

    time_spent_ms: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    visit_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    client_revision: Mapped[int] = mapped_column(BigInteger, default=0, nullable=False)

    #: Filled at submission, never before — these are the scored results.
    is_correct: Mapped[Optional[bool]] = mapped_column(Boolean)
    marks_awarded: Mapped[Optional[float]] = mapped_column(Float)
    #: False when a Section-B "best 5 of 10" rule left this one out.
    counted: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    first_seen_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    last_updated_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
