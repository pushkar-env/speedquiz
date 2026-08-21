"""Player-authored quizzes: authoring, access, and the hooks gameplay needs.

Design in one paragraph
-----------------------
A custom quiz owns one hidden ``topics`` row and writes ordinary ``questions``
under it. That single decision is why this file is mostly bookkeeping rather
than a second game engine: sessions, the three game modes, multiplayer boards,
scoring, anti-cheat, results and sharing already speak ``topic_id``, so none of
them needed to learn what a custom quiz is. What they *do* need to know is that
such a bank is **finite** — dealt once, ended at the bottom — and that it must
not touch the global ladder. Both facts travel as flags
(``topics.is_user_generated`` and ``quiz_sessions.config['finite_deck']``)
rather than as a branch in every reader.

Draft-ness is a question's ``QuestionStatus``. A draft quiz's questions sit at
PENDING, which the dealer never selects; publishing flips them to ACTIVE. One
copy of the text, so an authoring table and a published table can never drift.

Anti-farm posture
-----------------
A player who writes the questions knows the answers, so a custom run must never
be worth what a real run is worth:

* never recorded on the weekly or daily leaderboard,
* never moves Elo or the adaptive skill rating, and never enters topic mastery,
* pays XP normally on **someone else's** quiz, but on your own only once per
  cooldown window.

Each quiz gets its own ladder instead, which is the part players actually want.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from typing import Iterable, Optional, Sequence
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import get_settings
from app.core.languages import ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.models import (
    CustomQuiz,
    CustomQuizAccess,
    CustomQuizReport,
    CustomQuizStatus,
    CustomQuizVisibility,
    DifficultyLabel,
    GameMode,
    GenerationJob,
    GenerationJobStatus,
    Question,
    QuestionOption,
    QuestionStatus,
    QuizSession,
    Score,
    Topic,
    User,
    UserProfile,
)
from app.schemas.custom_quizzes import (
    OPTION_COUNT,
    AiDraftRequest,
    AiDraftResponse,
    ChallengeWithQuizRequest,
    CreateCustomQuizRequest,
    CustomQuizAuthorOut,
    CustomQuizDetailOut,
    CustomQuizLeaderboardEntryOut,
    CustomQuizLeaderboardResponse,
    CustomQuizListResponse,
    CustomQuizOut,
    CustomQuizQuestionIn,
    CustomQuizQuestionOut,
    ReportQuizRequest,
    StartCustomQuizRequest,
    StartCustomQuizResponse,
    UpdateCustomQuizRequest,
)
from app.schemas.quiz import CreateQuizSessionRequest
from app.services import friends

logger = get_logger(__name__)

#: Same alphabet the room codes use: no vowels, so a code cannot spell
#: anything, and no 0/O or 1/I to be misread off a screenshot.
QUIZ_CODE_ALPHABET = "23456789BCDFGHJKMNPQRSTVWXYZ"
QUIZ_CODE_LENGTH = 6

#: Midpoint of each band in `quiz_service.DIFFICULTY_RANGES`. An author picks a
#: label, not a number, and the number only has to land inside the band the
#: dealer will look in.
_DIFFICULTY_VALUE: dict[DifficultyLabel, float] = {
    DifficultyLabel.EASY: 0.25,
    DifficultyLabel.MEDIUM: 0.5,
    DifficultyLabel.HARD: 0.72,
    DifficultyLabel.EXPERT: 0.9,
}

#: Modes an author may nominate as the quiz's default. Mirrors
#: `quiz_service.SELECTABLE_MODES` without importing it — that module imports
#: this one for the finalize hooks, and a cycle at import time is worse than a
#: duplicated three-element set.
_SELECTABLE_MODES: frozenset[GameMode] = frozenset(
    {GameMode.CASUAL, GameMode.SPEEDRUN, GameMode.SURVIVAL}
)


#: Statuses whose questions the dealer is allowed to see.
_LIVE_STATUS = QuestionStatus.ACTIVE
_DRAFT_STATUS = QuestionStatus.PENDING


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _settings():
    return get_settings()


def _err(code: str, message: str, http_status: int = status.HTTP_400_BAD_REQUEST) -> HTTPException:
    """Structured error, so the client localizes off `code` rather than prose."""
    return HTTPException(status_code=http_status, detail={"code": code, "message": message})


def _require_enabled() -> None:
    if not _settings().custom_quiz_enabled:
        raise _err(
            "custom_quizzes_disabled",
            "Quiz creation is unavailable right now.",
            status.HTTP_503_SERVICE_UNAVAILABLE,
        )


# --- Question identity ------------------------------------------------------


def question_content_hash(
    quiz_id: UUID,
    prompt: str,
    options: Sequence[str],
    language: ContentLanguage,
) -> str:
    """Exact-duplicate key, **scoped to one quiz**.

    ``questions.content_hash`` is globally unique, which is right for the AI
    bank — two topics should not both hold the same generated question. It is
    wrong for hand-written content: "What is the capital of France?" is a
    perfectly good question for ten thousand different players' quizzes, and a
    global key would let whoever typed it first block everyone else forever.
    Salting with the quiz id keeps the column's uniqueness guarantee while
    scoping the *meaning* of duplicate to "twice in the same quiz".
    """
    raw = "|".join(
        [
            "cq",
            str(quiz_id),
            normalize_language(language).value,
            prompt.strip().lower(),
            *[o.strip().lower() for o in options],
        ]
    )
    return sha256(raw.encode("utf-8")).hexdigest()


def question_position(question: Question) -> int:
    """The author's index for one question, from its generation metadata.

    Public because the dealer sorts a finite deck by it: a hand-written quiz is
    played in the order it was written, which is the order the editor shows and
    the only one the author had any say over.
    """
    meta = question.generation_meta or {}
    block = meta.get("custom_quiz") if isinstance(meta, dict) else None
    if isinstance(block, dict):
        try:
            return int(block.get("position", 0))
        except (TypeError, ValueError):
            return 0
    return 0


def _is_ai_drafted(question: Question) -> bool:
    meta = question.generation_meta or {}
    block = meta.get("custom_quiz") if isinstance(meta, dict) else None
    return bool(isinstance(block, dict) and block.get("ai_drafted"))


def _meta_for(*, position: int, ai_drafted: bool, author_id: UUID) -> dict:
    return {
        "custom_quiz": {"position": position, "ai_drafted": ai_drafted},
        "author_user_id": str(author_id),
        "pipeline": "player_authored",
    }


async def _unique_quiz_code(db: AsyncSession) -> str:
    for _ in range(10):
        code = "".join(secrets.choice(QUIZ_CODE_ALPHABET) for _ in range(QUIZ_CODE_LENGTH))
        taken = await db.scalar(select(CustomQuiz.id).where(CustomQuiz.code == code).limit(1))
        if not taken:
            return code
    raise _err(
        "code_unavailable",
        "Could not mint a share code. Try again in a moment.",
        status.HTTP_503_SERVICE_UNAVAILABLE,
    )


def normalize_code(raw: str) -> str:
    """Uppercase, strip anything that is not in the alphabet.

    Players paste codes out of chat apps with spaces, dashes and the odd
    invisible character attached; refusing those would be refusing the code.
    """
    return "".join(ch for ch in (raw or "").upper() if ch in QUIZ_CODE_ALPHABET)[:QUIZ_CODE_LENGTH]


# --- Share links ------------------------------------------------------------


def deep_link_for(code: str) -> str:
    """The custom-scheme link that opens a quiz in an installed app."""
    return f"speedquiz://quiz/{code}"


def web_url_for(code: str) -> Optional[str]:
    """Short HTTPS link, when a public base URL is configured.

    Deliberately short (`/q/CODE`): this gets pasted into a chat message next
    to a sentence, and a long URL is the difference between a friend tapping it
    and scrolling past it. Falls back to nothing rather than to a localhost URL
    that would be useless to whoever receives it.
    """
    base = (_settings().share_public_base_url or "").strip().rstrip("/")
    if not base:
        return None
    return f"{base}/q/{code}"


@dataclass(frozen=True)
class PublicQuizPreview:
    """What the landing page may say about a quiz, to a stranger, unauthenticated.

    Title, author and size — the things already in the message the link came
    with. Never the questions, never the answer key, and never a quiz the
    author has not shared: the page exists to get somebody into the app, not to
    become a second, weaker read path into user content.
    """

    code: str
    title: str
    icon: str
    description: Optional[str]
    author_name: str
    question_count: int
    play_count: int
    deep_link: str
    language: str


async def public_preview(db: AsyncSession, code: str) -> Optional[PublicQuizPreview]:
    normalized = normalize_code(code)
    if len(normalized) != QUIZ_CODE_LENGTH:
        return None

    quiz = await db.scalar(select(CustomQuiz).where(CustomQuiz.code == normalized))
    if quiz is None or quiz.status is not CustomQuizStatus.PUBLISHED:
        return None
    if quiz.visibility is CustomQuizVisibility.PRIVATE:
        return None

    profile = await db.scalar(
        select(UserProfile).where(UserProfile.user_id == quiz.owner_user_id)
    )
    author = (profile.display_name or profile.username) if profile else "a player"
    return PublicQuizPreview(
        code=normalized,
        title=quiz.title,
        icon=quiz.icon,
        description=quiz.description,
        author_name=author,
        question_count=quiz.question_count,
        play_count=quiz.play_count,
        deep_link=deep_link_for(normalized),
        language=normalize_language(quiz.language).value,
    )


# --- Loading and access -----------------------------------------------------


async def load_quiz(db: AsyncSession, quiz_id: UUID) -> CustomQuiz:
    quiz = await db.scalar(select(CustomQuiz).where(CustomQuiz.id == quiz_id))
    if quiz is None:
        raise _err("quiz_not_found", "Quiz not found.", status.HTTP_404_NOT_FOUND)
    return quiz


async def load_owned(db: AsyncSession, user: User, quiz_id: UUID) -> CustomQuiz:
    """The quiz, if this user wrote it.

    A quiz someone else owns 404s rather than 403s: replying "exists, not
    yours" to an id probe leaks which ids are real.
    """
    quiz = await db.scalar(
        select(CustomQuiz).where(CustomQuiz.id == quiz_id, CustomQuiz.owner_user_id == user.id)
    )
    if quiz is None:
        raise _err("quiz_not_found", "Quiz not found.", status.HTTP_404_NOT_FOUND)
    return quiz


async def quiz_for_topic(db: AsyncSession, topic_id: UUID) -> Optional[CustomQuiz]:
    return await db.scalar(select(CustomQuiz).where(CustomQuiz.topic_id == topic_id))


async def has_access_row(db: AsyncSession, quiz_id: UUID, user_id: UUID) -> bool:
    row = await db.scalar(
        select(CustomQuizAccess.id).where(
            CustomQuizAccess.quiz_id == quiz_id,
            CustomQuizAccess.user_id == user_id,
        )
    )
    return row is not None


async def can_play(db: AsyncSession, user: User, quiz: CustomQuiz) -> bool:
    """Whether `user` may start a run on `quiz`.

    Ownership first (an author can always open their own draft), then the
    visibility tier, and finally a standing grant — which is what makes a share
    code needed exactly once rather than every time.
    """
    if quiz.owner_user_id == user.id:
        return True
    if quiz.status is not CustomQuizStatus.PUBLISHED:
        return False
    # A block in either direction hides the quiz, the same way it hides its
    # author everywhere else.
    if await friends.is_blocked_between(db, user.id, quiz.owner_user_id):
        return False
    if quiz.visibility is CustomQuizVisibility.FRIENDS:
        if await friends.are_friends(db, user.id, quiz.owner_user_id):
            return True
    return await has_access_row(db, quiz.id, user.id)


async def assert_can_play(db: AsyncSession, user: User, quiz: CustomQuiz) -> None:
    """Refuse unless a run on this quiz could actually be dealt.

    Anything but PUBLISHED means not playable **for anyone, including the
    author** — a draft's questions sit at PENDING and the dealer never selects
    them, so letting the author through here would hand them "no questions are
    ready for this topic" instead of "publish it first".

    *Which* refusal you get depends on what you already knew. Somebody holding
    a standing grant is told the author took the quiz down, because they have
    played it and the id is not news to them. Everybody else is told it does
    not exist: answering "exists, not yours" to an id probe is what turns a
    guessable id into an enumeration oracle.
    """
    is_owner = quiz.owner_user_id == user.id

    if quiz.status is CustomQuizStatus.HIDDEN:
        raise _err(
            "quiz_unavailable",
            "This quiz is unavailable while it is reviewed.",
            status.HTTP_403_FORBIDDEN,
        )

    if quiz.status is not CustomQuizStatus.PUBLISHED:
        if is_owner:
            if quiz.status is CustomQuizStatus.ARCHIVED:
                raise _err(
                    "quiz_archived_owner",
                    "Restore this quiz before playing it again.",
                    status.HTTP_409_CONFLICT,
                )
            raise _err(
                "quiz_not_published",
                "Publish this quiz before playing it.",
                status.HTTP_409_CONFLICT,
            )
        if await has_access_row(db, quiz.id, user.id):
            raise _err(
                "quiz_archived",
                "The author took this quiz down.",
                status.HTTP_410_GONE,
            )
        raise _err("quiz_not_found", "Quiz not found.", status.HTTP_404_NOT_FOUND)

    if not await can_play(db, user, quiz):
        raise _err("quiz_not_found", "Quiz not found.", status.HTTP_404_NOT_FOUND)
    if quiz.question_count < 1:
        raise _err("quiz_empty", "This quiz has no questions yet.", status.HTTP_409_CONFLICT)


async def grant_access(
    db: AsyncSession,
    quiz: CustomQuiz,
    user_id: UUID,
    *,
    source: str = "code",
) -> None:
    """Remember that this player may open this quiz. Idempotent.

    Never granted to the author — they own it, and a self-row would make the
    "shared with me" list include your own quizzes.
    """
    if user_id == quiz.owner_user_id:
        return
    if await has_access_row(db, quiz.id, user_id):
        return
    db.add(
        CustomQuizAccess(
            id=uuid4(),
            quiz_id=quiz.id,
            user_id=user_id,
            source=source[:16],
        )
    )
    await db.flush()


async def resolve_code(db: AsyncSession, user: User, code: str) -> CustomQuiz:
    """Redeem a share code, granting standing access on the way through."""
    normalized = normalize_code(code)
    if len(normalized) != QUIZ_CODE_LENGTH:
        raise _err("invalid_code", "That code does not look right.", status.HTTP_404_NOT_FOUND)

    quiz = await db.scalar(select(CustomQuiz).where(CustomQuiz.code == normalized))
    if quiz is None or quiz.status is not CustomQuizStatus.PUBLISHED:
        raise _err("quiz_not_found", "No quiz for that code.", status.HTTP_404_NOT_FOUND)
    if quiz.visibility is CustomQuizVisibility.PRIVATE and quiz.owner_user_id != user.id:
        # The code exists but the author has since made the quiz private.
        raise _err("quiz_not_found", "No quiz for that code.", status.HTTP_404_NOT_FOUND)
    if await friends.is_blocked_between(db, user.id, quiz.owner_user_id):
        raise _err("quiz_not_found", "No quiz for that code.", status.HTTP_404_NOT_FOUND)

    await grant_access(db, quiz, user.id, source="code")
    return quiz


# --- Quotas -----------------------------------------------------------------


async def _published_count(db: AsyncSession, user_id: UUID) -> int:
    return int(
        await db.scalar(
            select(func.count())
            .select_from(CustomQuiz)
            .where(
                CustomQuiz.owner_user_id == user_id,
                CustomQuiz.status == CustomQuizStatus.PUBLISHED,
            )
        )
        or 0
    )


def max_questions_for(user: User) -> int:
    settings = _settings()
    if user.is_premium:
        return settings.custom_quiz_max_questions
    return min(settings.custom_quiz_free_max_questions, settings.custom_quiz_max_questions)


async def remaining_slots_for(db: AsyncSession, user: User) -> Optional[int]:
    """Publishable quizzes left. ``None`` means unlimited."""
    if user.is_premium:
        return None
    used = await _published_count(db, user.id)
    return max(0, _settings().custom_quiz_free_limit - used)


# --- Serialization ----------------------------------------------------------


def _author_out(profile: Optional[UserProfile], *, is_premium: bool) -> CustomQuizAuthorOut:
    if profile is None:
        # A quiz outlives nothing — the owner FK cascades — so this is only
        # reachable mid-deletion. Render something rather than 500.
        return CustomQuizAuthorOut(user_id=uuid4(), username="player")
    return CustomQuizAuthorOut(
        user_id=profile.user_id,
        username=profile.username,
        display_name=profile.display_name,
        avatar_id=profile.avatar_id,
        is_premium=is_premium,
    )


def _question_out(question: Question) -> CustomQuizQuestionOut:
    by_position = {opt.position: opt.text for opt in question.options}
    options = [by_position.get(i, "") for i in range(OPTION_COUNT)]
    return CustomQuizQuestionOut(
        id=question.id,
        position=question_position(question),
        prompt=question.prompt,
        options=options,
        correct_option_index=question.correct_option_index,
        explanation=question.explanation or None,
        difficulty=question.difficulty_label,
        ai_drafted=_is_ai_drafted(question),
        times_served=question.times_served,
    )


async def _publish_blockers(db: AsyncSession, quiz: CustomQuiz, owner: User) -> list[str]:
    """Why this quiz cannot go live, as codes the client localizes."""
    settings = _settings()
    blockers: list[str] = []
    if quiz.question_count < settings.custom_quiz_min_questions:
        blockers.append("too_few_questions")
    if quiz.question_count > max_questions_for(owner):
        blockers.append("question_limit_exceeded")
    if quiz.status is not CustomQuizStatus.PUBLISHED:
        remaining = await remaining_slots_for(db, owner)
        if remaining is not None and remaining <= 0:
            blockers.append("quiz_limit_reached")
    return blockers


async def _profiles_for(db: AsyncSession, user_ids: Iterable[UUID]) -> dict[UUID, tuple[UserProfile, bool]]:
    ids = {uid for uid in user_ids if uid}
    if not ids:
        return {}
    rows = await db.execute(
        select(UserProfile, User.is_premium)
        .join(User, User.id == UserProfile.user_id)
        .where(UserProfile.user_id.in_(ids))
    )
    return {profile.user_id: (profile, bool(premium)) for profile, premium in rows}


async def _my_best_scores(
    db: AsyncSession,
    user_id: UUID,
    topic_ids: Sequence[UUID],
) -> dict[UUID, int]:
    """Best score per topic for one player, for a page of quizzes in one query."""
    if not topic_ids:
        return {}
    rows = await db.execute(
        select(Score.topic_id, func.max(Score.final_score))
        .where(Score.user_id == user_id, Score.topic_id.in_(list(topic_ids)))
        .group_by(Score.topic_id)
    )
    return {topic_id: int(best or 0) for topic_id, best in rows}


def serialize(
    quiz: CustomQuiz,
    viewer_id: UUID,
    *,
    author: Optional[tuple[UserProfile, bool]],
    my_best: Optional[int],
    blockers: list[str],
    max_questions: int,
) -> CustomQuizOut:
    """Assemble one quiz payload. Pure — every input is passed in.

    Deliberately not allowed to fetch its own author row, best score or publish
    blockers. It is called once per row of a list that can hold a hundred
    quizzes, and a convenient default that runs a query is three round trips
    per row the moment somebody opens the studio.
    """
    is_owner = quiz.owner_user_id == viewer_id
    profile, premium = author if author else (None, False)

    return CustomQuizOut(
        id=quiz.id,
        topic_id=quiz.topic_id,
        title=quiz.title,
        description=quiz.description,
        icon=quiz.icon,
        language=normalize_language(quiz.language).value,
        visibility=quiz.visibility,
        status=quiz.status,
        # The code is the key to the quiz. Anyone already holding access has it
        # anyway, and everyone else must be given it deliberately.
        code=quiz.code,
        question_count=quiz.question_count,
        default_mode=quiz.default_mode,
        default_difficulty=quiz.default_difficulty,
        play_count=quiz.play_count,
        player_count=quiz.player_count,
        top_score=quiz.top_score,
        author=_author_out(profile, is_premium=premium),
        is_owner=is_owner,
        my_best_score=my_best,
        publish_blockers=blockers if is_owner else [],
        max_questions=max_questions,
        min_questions=_settings().custom_quiz_min_questions,
        moderation_note=quiz.moderation_note if is_owner else None,
        created_at=quiz.created_at,
        updated_at=quiz.updated_at,
        published_at=quiz.published_at,
    )


async def serialize_one(
    db: AsyncSession,
    quiz: CustomQuiz,
    viewer: User,
) -> CustomQuizOut:
    """[serialize] for a single quiz, fetching what it needs first."""
    author = (await _profiles_for(db, [quiz.owner_user_id])).get(quiz.owner_user_id)
    best = await db.scalar(
        select(func.max(Score.final_score)).where(
            Score.user_id == viewer.id, Score.topic_id == quiz.topic_id
        )
    )
    blockers = (
        await _publish_blockers(db, quiz, viewer)
        if quiz.owner_user_id == viewer.id
        else []
    )
    return serialize(
        quiz,
        viewer.id,
        author=author,
        my_best=int(best) if best is not None else None,
        blockers=blockers,
        max_questions=max_questions_for(viewer),
    )


async def _questions_of(
    db: AsyncSession,
    quiz: CustomQuiz,
    *,
    include_retired: bool = False,
) -> list[Question]:
    """Every editable question of a quiz, in the author's order.

    Ordering happens in Python: the position lives in JSONB, the list is capped
    at 50 rows by `custom_quiz_max_questions`, and an expression index on a
    nested key would be a lot of machinery to sort a page that never grows.
    """
    stmt = (
        select(Question)
        .options(selectinload(Question.options))
        .where(Question.topic_id == quiz.topic_id)
    )
    if not include_retired:
        stmt = stmt.where(Question.status.in_([_LIVE_STATUS, _DRAFT_STATUS]))
    rows = list((await db.execute(stmt)).scalars().all())
    rows.sort(key=lambda q: (question_position(q), q.created_at))
    return rows


async def serialize_detail(
    db: AsyncSession,
    quiz: CustomQuiz,
    viewer: User,
) -> CustomQuizDetailOut:
    base = await serialize_one(db, quiz, viewer)
    questions = await _questions_of(db, quiz)
    return CustomQuizDetailOut(
        **base.model_dump(),
        questions=[_question_out(q) for q in questions],
    )


# --- Creation and editing ---------------------------------------------------


def _topic_slug(quiz_id: UUID) -> str:
    return f"cq-{str(quiz_id)[:8]}{secrets.token_hex(3)}"


async def _resolve_language(
    db: AsyncSession,
    user: User,
    requested: Optional[ContentLanguage],
) -> ContentLanguage:
    if requested is not None:
        return normalize_language(requested)
    profile = user.profile or await db.scalar(
        select(UserProfile).where(UserProfile.user_id == user.id)
    )
    return normalize_language(profile.quiz_language if profile else None)


async def _sync_counters(db: AsyncSession, quiz: CustomQuiz) -> None:
    """Recount the quiz's questions and mirror the number onto its topic."""
    total = int(
        await db.scalar(
            select(func.count())
            .select_from(Question)
            .where(
                Question.topic_id == quiz.topic_id,
                Question.status.in_([_LIVE_STATUS, _DRAFT_STATUS]),
            )
        )
        or 0
    )
    quiz.question_count = total
    topic = await db.scalar(select(Topic).where(Topic.id == quiz.topic_id))
    if topic is not None:
        topic.question_count = total
    await db.flush()


async def create_quiz(
    db: AsyncSession,
    user: User,
    payload: CreateCustomQuizRequest,
) -> CustomQuizDetailOut:
    _require_enabled()
    settings = _settings()

    # Drafts are free, but an unbounded pile of them is still a write amplifier
    # aimed at us. Cap the total a single account can hold open.
    open_drafts = int(
        await db.scalar(
            select(func.count())
            .select_from(CustomQuiz)
            .where(
                CustomQuiz.owner_user_id == user.id,
                CustomQuiz.status == CustomQuizStatus.DRAFT,
            )
        )
        or 0
    )
    draft_ceiling = max(settings.custom_quiz_free_limit * 3, 10)
    if open_drafts >= draft_ceiling:
        raise _err(
            "too_many_drafts",
            "Finish or delete one of your drafts first.",
            status.HTTP_409_CONFLICT,
        )

    if len(payload.questions) > max_questions_for(user):
        raise _err(
            "question_limit_exceeded",
            f"A quiz can hold {max_questions_for(user)} questions.",
            status.HTTP_403_FORBIDDEN,
        )

    if payload.default_mode not in _SELECTABLE_MODES:
        # Silently coercing to casual here and rejecting the same value in
        # `update_quiz` would make the two endpoints disagree about what a
        # valid mode is.
        raise _err("mode_unavailable", "That mode is no longer available.")

    language = await _resolve_language(db, user, payload.language)
    quiz_id = uuid4()

    topic = Topic(
        id=uuid4(),
        slug=_topic_slug(quiz_id),
        name=payload.title,
        description=payload.description,
        icon=payload.icon or "🧠",
        is_custom=True,
        is_user_generated=True,
        is_active=True,
        created_by_user_id=user.id,
        popularity_score=0,
    )
    db.add(topic)
    await db.flush()

    quiz = CustomQuiz(
        id=quiz_id,
        owner_user_id=user.id,
        topic_id=topic.id,
        title=payload.title,
        description=payload.description,
        icon=payload.icon or "🧠",
        language=language.value,
        visibility=payload.visibility,
        status=CustomQuizStatus.DRAFT,
        default_mode=payload.default_mode,
        default_difficulty=payload.default_difficulty,
    )
    db.add(quiz)
    await db.flush()

    for index, question in enumerate(payload.questions):
        await _insert_question(db, quiz, question, position=index, ai_drafted=False)
    await _sync_counters(db, quiz)

    await _track(db, "custom_quiz_created", user.id, {"quiz_id": str(quiz.id)})
    return await serialize_detail(db, quiz, user)


async def update_quiz(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    payload: UpdateCustomQuizRequest,
) -> CustomQuizDetailOut:
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)

    if payload.title is not None:
        quiz.title = payload.title
    if payload.description is not None:
        # An empty string is a deliberate clear; absent means "leave it".
        quiz.description = payload.description or None
    if payload.icon is not None:
        quiz.icon = payload.icon.strip() or "🧠"
    if payload.visibility is not None:
        quiz.visibility = payload.visibility
    if payload.default_mode is not None:
        if payload.default_mode not in _SELECTABLE_MODES:
            raise _err("mode_unavailable", "That mode is no longer available.")
        quiz.default_mode = payload.default_mode
    if payload.default_difficulty is not None:
        quiz.default_difficulty = payload.default_difficulty

    # The topic is what every results screen, match card and share text reads
    # its name from, so a rename has to reach it or the quiz gets two names.
    topic = await db.scalar(select(Topic).where(Topic.id == quiz.topic_id))
    if topic is not None:
        topic.name = quiz.title
        topic.description = quiz.description
        topic.icon = quiz.icon

    await db.flush()
    return await serialize_detail(db, quiz, user)


def _refuse_if_hidden(quiz: CustomQuiz) -> None:
    if quiz.status is CustomQuizStatus.HIDDEN:
        raise _err(
            "quiz_under_review",
            "This quiz is locked while it is reviewed.",
            status.HTTP_403_FORBIDDEN,
        )


async def delete_quiz(db: AsyncSession, user: User, quiz_id: UUID) -> None:
    """Hard delete — allowed only while nobody has played it.

    Deleting the quiz cascades to its topic, and the topic cascades to every
    session and score anyone ever posted on it. For a quiz with plays that
    would silently rewrite other players' history — their lifetime totals are
    aggregates that no longer match the rows behind them. So a played quiz is
    archived instead, and the client is told which action it should have used.
    """
    quiz = await load_owned(db, user, quiz_id)
    played = await db.scalar(
        select(QuizSession.id).where(QuizSession.topic_id == quiz.topic_id).limit(1)
    )
    if played is not None or quiz.play_count > 0:
        raise _err(
            "quiz_has_plays",
            "People have played this quiz — archive it instead.",
            status.HTTP_409_CONFLICT,
        )
    topic = await db.scalar(select(Topic).where(Topic.id == quiz.topic_id))
    await db.delete(quiz)
    if topic is not None:
        await db.delete(topic)
    await db.flush()
    await _track(db, "custom_quiz_deleted", user.id, {"quiz_id": str(quiz_id)})


async def _set_question_status(
    db: AsyncSession,
    quiz: CustomQuiz,
    *,
    to_status: QuestionStatus,
    from_status: QuestionStatus,
) -> None:
    rows = (
        await db.execute(
            select(Question).where(
                Question.topic_id == quiz.topic_id,
                Question.status == from_status,
            )
        )
    ).scalars().all()
    for question in rows:
        question.status = to_status
    await db.flush()


async def publish(db: AsyncSession, user: User, quiz_id: UUID) -> CustomQuizDetailOut:
    _require_enabled()
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)
    await _sync_counters(db, quiz)

    blockers = await _publish_blockers(db, quiz, user)
    if blockers:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "code": blockers[0],
                "message": _BLOCKER_COPY.get(blockers[0], "This quiz is not ready yet."),
                "blockers": blockers,
                "min_questions": _settings().custom_quiz_min_questions,
                "max_questions": max_questions_for(user),
            },
        )

    await _set_question_status(db, quiz, to_status=_LIVE_STATUS, from_status=_DRAFT_STATUS)
    if not quiz.code:
        quiz.code = await _unique_quiz_code(db)
    quiz.status = CustomQuizStatus.PUBLISHED
    quiz.published_at = quiz.published_at or _now()
    quiz.archived_at = None

    topic = await db.scalar(select(Topic).where(Topic.id == quiz.topic_id))
    if topic is not None:
        topic.is_active = True
    await _sync_counters(db, quiz)

    await _track(
        db,
        "custom_quiz_published",
        user.id,
        {
            "quiz_id": str(quiz.id),
            "question_count": quiz.question_count,
            "visibility": quiz.visibility.value,
        },
    )
    return await serialize_detail(db, quiz, user)


_BLOCKER_COPY = {
    "too_few_questions": "Add a few more questions before publishing.",
    "question_limit_exceeded": "This quiz has more questions than your plan allows.",
    "quiz_limit_reached": "You have used all your published quiz slots.",
}


async def unpublish(db: AsyncSession, user: User, quiz_id: UUID) -> CustomQuizDetailOut:
    """Back to draft. Existing results and in-flight matches are unaffected.

    Questions go to PENDING, which the dealer skips, so no new run can start —
    but `matches` resolves its frozen question ids without consulting status,
    so a challenge already sent still plays out.
    """
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)
    if quiz.status is CustomQuizStatus.DRAFT:
        return await serialize_detail(db, quiz, user)

    await _set_question_status(db, quiz, to_status=_DRAFT_STATUS, from_status=_LIVE_STATUS)
    quiz.status = CustomQuizStatus.DRAFT
    quiz.archived_at = None
    await _sync_counters(db, quiz)
    return await serialize_detail(db, quiz, user)


async def archive(db: AsyncSession, user: User, quiz_id: UUID) -> CustomQuizDetailOut:
    """Retire a quiz that has been played. History survives; new runs stop."""
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)
    await _set_question_status(db, quiz, to_status=_DRAFT_STATUS, from_status=_LIVE_STATUS)
    quiz.status = CustomQuizStatus.ARCHIVED
    quiz.archived_at = _now()
    await _sync_counters(db, quiz)
    await _track(db, "custom_quiz_archived", user.id, {"quiz_id": str(quiz.id)})
    return await serialize_detail(db, quiz, user)


async def restore(db: AsyncSession, user: User, quiz_id: UUID) -> CustomQuizDetailOut:
    """Bring an archived quiz back as a draft, ready to publish again."""
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)
    if quiz.status is not CustomQuizStatus.ARCHIVED:
        return await serialize_detail(db, quiz, user)
    quiz.status = CustomQuizStatus.DRAFT
    quiz.archived_at = None
    await db.flush()
    return await serialize_detail(db, quiz, user)


# --- Questions --------------------------------------------------------------


async def _assert_not_duplicate(
    db: AsyncSession,
    quiz: CustomQuiz,
    payload: CustomQuizQuestionIn,
    *,
    exclude_question_id: Optional[UUID] = None,
) -> str:
    digest = question_content_hash(quiz.id, payload.prompt, payload.options, quiz.language)
    stmt = select(Question.id).where(Question.content_hash == digest)
    if exclude_question_id is not None:
        stmt = stmt.where(Question.id != exclude_question_id)
    if await db.scalar(stmt.limit(1)) is not None:
        raise _err(
            "duplicate_question",
            "This quiz already has that question.",
            status.HTTP_409_CONFLICT,
        )
    return digest


async def _insert_question(
    db: AsyncSession,
    quiz: CustomQuiz,
    payload: CustomQuizQuestionIn,
    *,
    position: int,
    ai_drafted: bool,
) -> Question:
    digest = await _assert_not_duplicate(db, quiz, payload)
    language = normalize_language(quiz.language)
    question = Question(
        id=uuid4(),
        topic_id=quiz.topic_id,
        prompt=payload.prompt,
        # The play screen always shows an explanation panel. A blank one reads
        # as a loading failure, so an author who skipped it gets the answer
        # restated rather than an empty box.
        explanation=payload.explanation or f"Correct answer: {payload.options[payload.correct_option_index]}",
        language=language.value,
        source="player",
        difficulty=_DIFFICULTY_VALUE[payload.difficulty],
        difficulty_label=payload.difficulty,
        correct_option_index=payload.correct_option_index,
        # Hand-written questions never go through the AI validator, so the
        # score is not a judgement — it just has to sit above any threshold a
        # future reader might apply to the bank.
        quality_score=100,
        status=(
            _LIVE_STATUS if quiz.status is CustomQuizStatus.PUBLISHED else _DRAFT_STATUS
        ),
        content_hash=digest,
        # Deliberately NULL. The near-duplicate index is how the AI pipeline
        # stops itself repeating; an author writing four questions about the
        # same film is not making a mistake.
        embedding_fingerprint=None,
        generation_meta=_meta_for(
            position=position,
            ai_drafted=ai_drafted,
            author_id=quiz.owner_user_id,
        ),
    )
    db.add(question)
    await db.flush()
    for index, text in enumerate(payload.options):
        db.add(QuestionOption(question_id=question.id, position=index, text=text))
    await db.flush()
    return question


async def add_question(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    payload: CustomQuizQuestionIn,
) -> CustomQuizDetailOut:
    _require_enabled()
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)

    ceiling = max_questions_for(user)
    if quiz.question_count >= ceiling:
        raise _err(
            "question_limit_exceeded",
            f"A quiz can hold {ceiling} questions.",
            status.HTTP_403_FORBIDDEN,
        )

    existing = await _questions_of(db, quiz)
    next_position = (max((question_position(q) for q in existing), default=-1)) + 1
    await _insert_question(db, quiz, payload, position=next_position, ai_drafted=False)
    await _sync_counters(db, quiz)
    return await serialize_detail(db, quiz, user)


async def _load_question(db: AsyncSession, quiz: CustomQuiz, question_id: UUID) -> Question:
    question = await db.scalar(
        select(Question)
        .options(selectinload(Question.options))
        .where(Question.id == question_id, Question.topic_id == quiz.topic_id)
    )
    if question is None or question.status is QuestionStatus.RETIRED:
        raise _err("question_not_found", "Question not found.", status.HTTP_404_NOT_FOUND)
    return question


async def update_question(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    question_id: UUID,
    payload: CustomQuizQuestionIn,
) -> CustomQuizDetailOut:
    _require_enabled()
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)
    question = await _load_question(db, quiz, question_id)

    digest = await _assert_not_duplicate(db, quiz, payload, exclude_question_id=question.id)
    question.prompt = payload.prompt
    question.explanation = (
        payload.explanation or f"Correct answer: {payload.options[payload.correct_option_index]}"
    )
    question.correct_option_index = payload.correct_option_index
    question.difficulty = _DIFFICULTY_VALUE[payload.difficulty]
    question.difficulty_label = payload.difficulty
    question.content_hash = digest

    by_position = {opt.position: opt for opt in question.options}
    for index, text in enumerate(payload.options):
        existing = by_position.get(index)
        if existing is None:
            db.add(QuestionOption(question_id=question.id, position=index, text=text))
        else:
            existing.text = text
    await db.flush()
    return await serialize_detail(db, quiz, user)


async def delete_question(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    question_id: UUID,
) -> CustomQuizDetailOut:
    """Remove a question. Retired rather than deleted once it has been dealt.

    ``answers.question_id`` and ``scores`` cascade from ``questions``, and
    ``matches.question_ids`` holds raw ids with no FK behind them. Deleting a
    question somebody has already been asked would therefore erase their answer
    and break any match still holding it. RETIRED is invisible to the dealer,
    which is the only property the author actually wants.
    """
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)
    question = await _load_question(db, quiz, question_id)

    if question.times_served > 0:
        question.status = QuestionStatus.RETIRED
    else:
        await db.delete(question)
    await db.flush()
    await _sync_counters(db, quiz)

    # Deleting below the publish floor takes the quiz back to draft. Leaving it
    # published would leave it listed as playable while every challenge on it
    # 409s, and the author would have no way to see why.
    if (
        quiz.status is CustomQuizStatus.PUBLISHED
        and quiz.question_count < _settings().custom_quiz_min_questions
    ):
        await _set_question_status(db, quiz, to_status=_DRAFT_STATUS, from_status=_LIVE_STATUS)
        quiz.status = CustomQuizStatus.DRAFT
        await db.flush()

    return await serialize_detail(db, quiz, user)


async def reorder_questions(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    question_ids: Sequence[UUID],
) -> CustomQuizDetailOut:
    quiz = await load_owned(db, user, quiz_id)
    _refuse_if_hidden(quiz)
    questions = await _questions_of(db, quiz)
    by_id = {q.id: q for q in questions}

    if set(question_ids) != set(by_id):
        raise _err(
            "reorder_mismatch",
            "Send every question id exactly once.",
            status.HTTP_409_CONFLICT,
        )

    for position, question_id in enumerate(question_ids):
        question = by_id[question_id]
        meta = dict(question.generation_meta or {})
        block = dict(meta.get("custom_quiz") or {})
        block["position"] = position
        meta["custom_quiz"] = block
        # JSONB needs a fresh object to be seen as dirty.
        question.generation_meta = meta
    await db.flush()
    return await serialize_detail(db, quiz, user)


# --- AI drafting ------------------------------------------------------------


#: Marks the ``generation_jobs`` rows this feature writes, so the daily quota
#: counts only its own spend and not a custom-topic generation.
AI_DRAFT_JOB_TYPE = "custom_quiz_ai_draft"


async def _ai_drafts_used_today(db: AsyncSession, user_id: UUID) -> int:
    """Fresh drafting runs this account has spent today (UTC).

    Counted off ``generation_jobs`` rather than analytics events: the analytics
    provider is configurable and can legitimately be a no-op, which would turn
    the free tier's LLM budget into an unmetered one. A generation job is
    always written, and doubles as the audit trail for what the drafting button
    actually costs.
    """
    start = _now().replace(hour=0, minute=0, second=0, microsecond=0)
    rows = (
        await db.execute(
            select(GenerationJob.payload).where(
                GenerationJob.requested_by_user_id == user_id,
                GenerationJob.created_at >= start,
            )
        )
    ).scalars().all()
    return sum(1 for payload in rows if (payload or {}).get("job_type") == AI_DRAFT_JOB_TYPE)


async def ai_draft(
    db: AsyncSession,
    user: User,
    payload: AiDraftRequest,
    *,
    language: Optional[ContentLanguage] = None,
) -> AiDraftResponse:
    """Starter questions for the author to edit. Nothing is saved here.

    This is the difference between a creator most people finish and one most
    people abandon on question three — but it is also a paid LLM call behind a
    button anyone can hold down, so it is quota'd exactly like custom AI topics
    and returns drafts rather than writing rows.
    """
    _require_enabled()
    settings = _settings()

    remaining: Optional[int] = None
    if not user.is_premium:
        used = await _ai_drafts_used_today(db, user.id)
        limit = settings.custom_quiz_ai_draft_daily_limit_free
        if used >= limit:
            raise _err(
                "ai_draft_limit",
                "You have used today's AI drafts. Premium removes the limit.",
                status.HTTP_429_TOO_MANY_REQUESTS,
            )
        remaining = max(0, limit - used - 1)

    resolved = await _resolve_language(db, user, language)
    count = min(payload.count, settings.custom_quiz_ai_draft_max)

    from app.ai.pipeline import sanitize_topic_prompt
    from app.ai.providers import get_llm_provider

    subject = sanitize_topic_prompt(payload.prompt)
    if len(subject) < 3:
        raise _err("prompt_too_short", "Say a little more about the topic.")

    try:
        drafts = await get_llm_provider().generate_questions(
            topic=subject,
            difficulty=payload.difficulty.value,
            count=count,
            style="clear, self-contained quiz questions with one unambiguous answer",
            language=resolved,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("custom_quiz_ai_draft_failed", error=str(exc))
        raise _err(
            "ai_draft_failed",
            "Couldn't draft questions just now. Try again.",
            status.HTTP_503_SERVICE_UNAVAILABLE,
        ) from exc

    questions: list[CustomQuizQuestionIn] = []
    for draft in drafts:
        options = [str(o) for o in (draft.options or [])][:OPTION_COUNT]
        if len(options) != OPTION_COUNT:
            continue
        if not 0 <= int(draft.correct_option) < OPTION_COUNT:
            continue
        try:
            questions.append(
                CustomQuizQuestionIn(
                    prompt=draft.question,
                    options=options,
                    correct_option_index=int(draft.correct_option),
                    explanation=draft.explanation,
                    difficulty=payload.difficulty,
                )
            )
        except ValueError:
            # A draft that fails the author-facing rules (duplicate options,
            # an empty one) is dropped rather than shown — the author cannot
            # be asked to fix something the model got wrong.
            continue

    if not questions:
        raise _err(
            "ai_draft_failed",
            "Couldn't draft usable questions. Try a clearer topic.",
            status.HTTP_503_SERVICE_UNAVAILABLE,
        )

    # The quota's system of record. Written only on a run that produced
    # something, so a provider outage does not spend the player's daily budget.
    db.add(
        GenerationJob(
            id=uuid4(),
            requested_by_user_id=user.id,
            status=GenerationJobStatus.COMPLETED,
            requested_count=count,
            approved_count=len(questions),
            language=resolved.value,
            payload={
                "job_type": AI_DRAFT_JOB_TYPE,
                "subject": subject,
                "difficulty": payload.difficulty.value,
                "language": resolved.value,
            },
        )
    )
    await db.flush()

    await _track(
        db,
        "custom_quiz_ai_drafted",
        user.id,
        {"count": len(questions), "requested": count},
    )
    return AiDraftResponse(questions=questions, remaining_today=remaining)


# --- Listing ----------------------------------------------------------------


async def list_for_user(db: AsyncSession, user: User) -> CustomQuizListResponse:
    mine_rows = list(
        (
            await db.execute(
                select(CustomQuiz)
                .where(CustomQuiz.owner_user_id == user.id)
                .order_by(CustomQuiz.updated_at.desc())
                .limit(100)
            )
        ).scalars().all()
    )

    shared_rows = list(
        (
            await db.execute(
                select(CustomQuiz)
                .join(CustomQuizAccess, CustomQuizAccess.quiz_id == CustomQuiz.id)
                .where(
                    CustomQuizAccess.user_id == user.id,
                    # An archived or hidden quiz drops out of the library
                    # rather than sitting there as a row that refuses to open.
                    CustomQuiz.status == CustomQuizStatus.PUBLISHED,
                )
                .order_by(CustomQuizAccess.created_at.desc())
                .limit(100)
            )
        ).scalars().all()
    )

    everyone = mine_rows + shared_rows
    authors = await _profiles_for(db, [q.owner_user_id for q in everyone])
    bests = await _my_best_scores(db, user.id, [q.topic_id for q in everyone])

    # Computed once for the page rather than re-derived per row: every quiz
    # this player owns shares one slot allowance, and asking the database how
    # many are published is the same answer a hundred times over.
    remaining = await remaining_slots_for(db, user)
    ceiling = max_questions_for(user)
    minimum = _settings().custom_quiz_min_questions

    def blockers_for(quiz: CustomQuiz) -> list[str]:
        blockers: list[str] = []
        if quiz.question_count < minimum:
            blockers.append("too_few_questions")
        if quiz.question_count > ceiling:
            blockers.append("question_limit_exceeded")
        if quiz.status is not CustomQuizStatus.PUBLISHED and remaining is not None:
            if remaining <= 0:
                blockers.append("quiz_limit_reached")
        return blockers

    def row(quiz: CustomQuiz, *, owned: bool) -> CustomQuizOut:
        return serialize(
            quiz,
            user.id,
            author=authors.get(quiz.owner_user_id),
            my_best=bests.get(quiz.topic_id),
            blockers=blockers_for(quiz) if owned else [],
            max_questions=ceiling,
        )

    return CustomQuizListResponse(
        mine=[row(q, owned=True) for q in mine_rows],
        shared=[row(q, owned=False) for q in shared_rows],
        remaining_slots=remaining,
        max_questions=ceiling,
    )


# --- Play -------------------------------------------------------------------


async def start_solo(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    payload: StartCustomQuizRequest,
) -> StartCustomQuizResponse:
    """Start a single-player run, with the same mode choices as any topic."""
    _require_enabled()
    quiz = await load_quiz(db, quiz_id)
    await assert_can_play(db, user, quiz)

    if payload.mode not in _SELECTABLE_MODES:
        raise _err("mode_unavailable", "That mode is no longer available.")

    from app.services import quiz_service

    session = await quiz_service.create_session(
        db,
        user,
        CreateQuizSessionRequest(
            topic_id=quiz.topic_id,
            mode=payload.mode,
            difficulty=payload.difficulty or quiz.default_difficulty,
            question_time_limit_ms=payload.question_time_limit_ms,
            language=normalize_language(quiz.language),
        ),
    )
    await _track(
        db,
        "custom_quiz_started",
        user.id,
        {
            "quiz_id": str(quiz.id),
            "mode": payload.mode.value,
            "is_owner": quiz.owner_user_id == user.id,
        },
    )
    return StartCustomQuizResponse(quiz_id=quiz.id, session=session)


async def challenge(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    payload: ChallengeWithQuizRequest,
):
    """Send a challenge, or open a room, on a quiz.

    The board is drawn from the quiz's own deck, so the count is clamped to
    what the quiz actually holds — asking `matches` for seven questions from a
    five-question quiz is a 409 the player cannot do anything about.
    """
    _require_enabled()
    quiz = await load_quiz(db, quiz_id)
    await assert_can_play(db, user, quiz)

    settings = _settings()
    requested = payload.question_count or min(
        quiz.question_count, settings.match_default_question_count
    )
    # Bounded before it reaches `CreateMatchRequest`, whose validator answers
    # an out-of-range count with a 500 rather than something a player can read.
    # A quiz that is genuinely too short still gets the 409 from `create_match`.
    requested = max(
        settings.match_min_question_count,
        min(requested, settings.match_max_question_count),
    )

    from app.models import MatchFormat
    from app.schemas.multiplayer import CreateMatchRequest
    from app.services import matches

    # `create_match` re-checks access, clamps the count to the deck and grants
    # every seated player standing access to the quiz. That check has to live
    # there rather than only here: `POST /multiplayer/matches` takes a raw
    # topic id and is reachable without ever passing through this function.
    match = await matches.create_match(
        db,
        user,
        CreateMatchRequest(
            topic_id=quiz.topic_id,
            difficulty=quiz.default_difficulty,
            language=normalize_language(quiz.language),
            question_count=requested,
            format=MatchFormat.ROOM if payload.is_room else MatchFormat.DUEL,
            opponent_user_id=payload.opponent_user_id,
            max_players=payload.max_players,
        ),
    )

    await _track(
        db,
        "custom_quiz_challenged",
        user.id,
        {"quiz_id": str(quiz.id), "match_id": str(match.id), "is_room": payload.is_room},
    )
    return match


async def leaderboard(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
) -> CustomQuizLeaderboardResponse:
    """One quiz's own ladder: each player's best run, best first.

    This is the reason a custom quiz gets played twice, and it is deliberately
    per-quiz — never merged into the global boards. See the module docstring.

    Ranking happens in the database. The obvious shape — fetch every score row
    for the topic and deduplicate by player in Python — is fine at ten plays
    and is a hundred thousand rows in memory on the first quiz that goes round
    a school. The window function below reads the same
    ``ix_scores_topic_score`` index and returns exactly one page.
    """
    quiz = await load_quiz(db, quiz_id)
    await assert_can_play(db, user, quiz)

    limit = _settings().custom_quiz_leaderboard_size

    # One row per player: their best run, and the earliest of them on a tie —
    # first to reach a score holds the rank.
    per_player = (
        select(
            Score.user_id.label("user_id"),
            Score.final_score.label("final_score"),
            Score.accuracy.label("accuracy"),
            Score.created_at.label("created_at"),
            func.row_number()
            .over(
                partition_by=Score.user_id,
                order_by=(Score.final_score.desc(), Score.created_at.asc()),
            )
            .label("nth_best"),
        )
        .where(Score.topic_id == quiz.topic_id)
        .subquery()
    )
    best = select(per_player).where(per_player.c.nth_best == 1).subquery()

    rows = list(
        (
            await db.execute(
                select(best)
                .order_by(best.c.final_score.desc(), best.c.created_at.asc())
                .limit(limit)
            )
        ).all()
    )

    total_players = int(
        await db.scalar(
            select(func.count(func.distinct(Score.user_id))).where(
                Score.topic_id == quiz.topic_id
            )
        )
        or 0
    )

    # The viewer's own best, fetched separately so their row can be pinned even
    # when it falls outside the page.
    mine = (
        await db.execute(
            select(Score.final_score, Score.accuracy, Score.created_at)
            .where(Score.user_id == user.id, Score.topic_id == quiz.topic_id)
            .order_by(Score.final_score.desc(), Score.created_at.asc())
            .limit(1)
        )
    ).first()

    my_rank: Optional[int] = None
    if mine is not None:
        # Players strictly ahead. Counting distinct users with *any* higher
        # score is the same set as users whose best is higher, and it is a
        # bounded count over the index rather than a second full ranking.
        ahead = int(
            await db.scalar(
                select(func.count(func.distinct(Score.user_id))).where(
                    Score.topic_id == quiz.topic_id,
                    Score.final_score > mine.final_score,
                )
            )
            or 0
        )
        my_rank = ahead + 1

    profiles = await _profiles_for(db, [r.user_id for r in rows] + [user.id])

    def _entry(
        *,
        rank: int,
        user_id: UUID,
        final_score: int,
        accuracy: float,
        played_at: datetime,
    ) -> CustomQuizLeaderboardEntryOut:
        profile, premium = profiles.get(user_id, (None, False))
        return CustomQuizLeaderboardEntryOut(
            rank=rank,
            user_id=user_id,
            # A profile row cascades with its user, so this only goes missing
            # mid-deletion. Render a placeholder rather than dropping the rank.
            username=profile.username if profile else "player",
            display_name=profile.display_name if profile else None,
            avatar_id=profile.avatar_id if profile else "avatar_01",
            is_premium=premium,
            best_score=int(final_score),
            accuracy=round(float(accuracy), 1),
            played_at=played_at,
            is_me=user_id == user.id,
        )

    entries = [
        _entry(
            rank=index + 1,
            user_id=row.user_id,
            final_score=row.final_score,
            accuracy=row.accuracy,
            played_at=row.created_at,
        )
        for index, row in enumerate(rows)
    ]

    me = next((e for e in entries if e.is_me), None)
    if me is None and mine is not None and my_rank is not None:
        me = _entry(
            rank=my_rank,
            user_id=user.id,
            final_score=mine.final_score,
            accuracy=mine.accuracy,
            played_at=mine.created_at,
        )

    return CustomQuizLeaderboardResponse(
        quiz_id=quiz.id,
        entries=entries,
        me=me,
        total_players=total_players,
    )


# --- Moderation -------------------------------------------------------------


async def report(
    db: AsyncSession,
    user: User,
    quiz_id: UUID,
    payload: ReportQuizRequest,
) -> None:
    """File a report, and auto-hide once enough distinct players have.

    Auto-hide is not a verdict — it is a pause. The quiz stops being playable
    and its author is told why, which is the right default when the alternative
    is abusive content staying live until someone reads a queue.
    """
    quiz = await load_quiz(db, quiz_id)
    if quiz.owner_user_id == user.id:
        raise _err("cannot_report_own", "You cannot report your own quiz.")
    # Only someone who can actually see it may report it — otherwise the
    # endpoint is a way to bury quizzes you were never shown.
    if not await can_play(db, user, quiz):
        raise _err("quiz_not_found", "Quiz not found.", status.HTTP_404_NOT_FOUND)

    already = await db.scalar(
        select(CustomQuizReport.id).where(
            CustomQuizReport.quiz_id == quiz.id,
            CustomQuizReport.user_id == user.id,
        )
    )
    if already is not None:
        return

    db.add(
        CustomQuizReport(
            id=uuid4(),
            quiz_id=quiz.id,
            user_id=user.id,
            reason=payload.reason,
            details=payload.details,
        )
    )
    quiz.report_count += 1
    if (
        quiz.report_count >= _settings().custom_quiz_report_hide_threshold
        and quiz.status is CustomQuizStatus.PUBLISHED
    ):
        quiz.status = CustomQuizStatus.HIDDEN
        quiz.moderation_note = "Hidden pending review after multiple reports."
        await _set_question_status(db, quiz, to_status=_DRAFT_STATUS, from_status=_LIVE_STATUS)
        logger.warning(
            "custom_quiz_auto_hidden",
            quiz_id=str(quiz.id),
            owner_id=str(quiz.owner_user_id),
            reports=quiz.report_count,
        )
    await db.flush()
    await _track(
        db,
        "custom_quiz_reported",
        user.id,
        {"quiz_id": str(quiz.id), "reason": payload.reason},
    )


# --- Hooks called from gameplay ---------------------------------------------


async def xp_allowed_for_run(
    db: AsyncSession,
    *,
    topic: Topic,
    user_id: UUID,
) -> bool:
    """Whether a finished run on `topic` should pay XP.

    Someone else's quiz always pays. Your own pays once per cooldown window —
    without that, an author holds a private XP faucet whose answer key they
    wrote, which is the single most obvious way to farm this feature.
    """
    if topic.created_by_user_id != user_id:
        return True
    hours = _settings().custom_quiz_own_xp_cooldown_hours
    if hours <= 0:
        return True
    cutoff = _now() - timedelta(hours=hours)
    recent = await db.scalar(
        select(Score.id)
        .where(
            Score.user_id == user_id,
            Score.topic_id == topic.id,
            Score.xp_earned > 0,
            Score.created_at >= cutoff,
        )
        .limit(1)
    )
    return recent is None


async def note_finished_run(
    db: AsyncSession,
    *,
    topic: Topic,
    user_id: UUID,
    score: int,
) -> None:
    """Update a quiz's counters after a run on it finishes.

    Called *before* the run's own `Score` row is added, so "has this player
    finished it before?" is a question about history rather than about the row
    we are in the middle of writing.
    """
    quiz = await quiz_for_topic(db, topic.id)
    if quiz is None:
        return

    played_before = await db.scalar(
        select(Score.id)
        .where(Score.user_id == user_id, Score.topic_id == topic.id)
        .limit(1)
    )
    quiz.play_count += 1
    if played_before is None:
        quiz.player_count += 1
    if score > quiz.top_score:
        quiz.top_score = score


async def _track(db: AsyncSession, event: str, user_id: UUID, properties: dict) -> None:
    """Analytics must never be the reason a write fails."""
    try:
        from app.analytics import track_event

        await track_event(db, event, user_id=user_id, properties=properties)
    except Exception:  # noqa: BLE001
        pass
