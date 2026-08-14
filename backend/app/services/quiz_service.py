"""Quiz session gameplay — server-authoritative, no LLM on the play path."""

from __future__ import annotations

import random
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models import (
    Answer,
    DifficultyLabel,
    GameMode,
    PlayerStatistics,
    Question,
    QuestionStatus,
    QuizQuestion,
    QuizResult,
    QuizSession,
    QuizSessionStatus,
    Score,
    Streak,
    Topic,
    User,
    UserProfile,
)
from app.schemas.achievements import AchievementUnlockedOut
from app.schemas.quiz import (
    AnswerFeedbackOut,
    CreateQuizSessionRequest,
    PlayableQuestionOut,
    QuizOptionOut,
    QuizResultOut,
    QuizSessionOut,
    SubmitAnswerRequest,
)
from app.core.config import get_settings
from app.core.languages import (
    DEFAULT_LANGUAGE,
    ContentLanguage,
    normalize_language,
    profile_for,
)
from app.payments.entitlements import unique_question_allowance
from app.services import achievements as achievements_service
from app.services import speedrun, survival
from app.services.adaptive import (
    nudge_label,
    parse_difficulty_label,
    suggested_label_from_ratings,
    update_topic_rating,
)
from app.services.anticheat import (
    check_answer_rate_limit,
    clamp_points_awarded,
    resolve_answer_elapsed_ms,
)
from app.services.localization import localized_topic_name
from app.services.progression import apply_xp, update_daily_streak
from app.services.question_filters import not_expired
from app.services.scoring import scoring_service
from app.services.share import build_share_payload

DIFFICULTY_RANGES: dict[DifficultyLabel, tuple[float, float]] = {
    DifficultyLabel.EASY: (0.0, 0.4),
    DifficultyLabel.MEDIUM: (0.35, 0.65),
    DifficultyLabel.HARD: (0.6, 0.85),
    DifficultyLabel.EXPERT: (0.8, 1.0),
}

MODE_DEFAULTS: dict[GameMode, dict] = {
    GameMode.CASUAL: {"question_time_limit_ms": 15000, "lives": None, "score": 0, "time_budget_ms": None},
    # Speedrun's per-question limit is only the *opening* value — it tightens
    # as the run goes deeper. See app.services.speedrun.
    GameMode.SPEEDRUN: {
        "question_time_limit_ms": speedrun.QUESTION_LIMIT_START_MS,
        "lives": None,
        "score": 0,
        "time_budget_ms": speedrun.START_CLOCK_MS,
    },
    # Survival's limit also tightens with depth. See app.services.survival.
    GameMode.SURVIVAL: {
        "question_time_limit_ms": survival.QUESTION_LIMIT_START_MS,
        "lives": survival.START_LIVES,
        "score": 0,
        "time_budget_ms": None,
    },
    GameMode.DAILY: {"question_time_limit_ms": 15000, "lives": None, "score": 0, "time_budget_ms": None},
}

#: Modes the app no longer offers.
#:
#: Negative was casual with the sign flipped, and sudden death ended most runs
#: on question three — neither gave a reason to play twice. Survival absorbed
#: what was interesting about both: real stakes that escalate.
#:
#: The enum *labels* deliberately stay in the database. `quiz_sessions.mode`
#: and `scores.mode` reference them on historical rows, and dropping a value
#: from a Postgres enum would orphan every run anyone already played.
RETIRED_MODES: frozenset[GameMode] = frozenset(
    {GameMode.NEGATIVE, GameMode.SUDDEN_DEATH}
)

#: Modes a player may start. Daily is excluded because it is created by the
#: daily-challenge flow, not chosen in setup.
SELECTABLE_MODES: frozenset[GameMode] = frozenset(
    {GameMode.CASUAL, GameMode.SPEEDRUN, GameMode.SURVIVAL}
)


def _defaults_for(mode: GameMode) -> dict:
    """Session defaults, falling back to casual for a retired mode.

    A run created just before a deploy that retires its mode must still be
    finishable rather than 500ing on a missing key.
    """
    return MODE_DEFAULTS.get(mode, MODE_DEFAULTS[GameMode.CASUAL])

INITIAL_BATCH = 20
ANSWER_GRACE_MS = 1500


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _session_batch_size() -> int:
    from app.core.config import get_settings

    return max(5, get_settings().topic_bank_session_batch)


def _shuffle_option_order() -> list[int]:
    order = [0, 1, 2, 3]
    random.shuffle(order)
    return order


def _normalize_option_order(raw: object) -> list[int]:
    """JSONB may surface odd types — keep a strict permutation of 0..3."""
    if not isinstance(raw, list) or len(raw) != 4:
        return [0, 1, 2, 3]
    try:
        order = [int(x) for x in raw]
    except (TypeError, ValueError):
        return [0, 1, 2, 3]
    if sorted(order) != [0, 1, 2, 3]:
        return [0, 1, 2, 3]
    return order


def _client_correct_index(option_order: list[int], correct_original: int) -> int:
    try:
        return option_order.index(int(correct_original))
    except ValueError:
        return 0


def session_language(session: QuizSession) -> ContentLanguage:
    """Content language of a run, tolerant of rows written before languages."""
    return normalize_language(session.language)


def _empty_bank_error(language: ContentLanguage) -> HTTPException:
    """409 for "this topic has nothing playable in the chosen language".

    Structured rather than a bare string: the client shows a localized message
    and offers to switch language, which it cannot do off prose. The generic
    "topic is still filling" copy would be actively misleading here — the topic
    may be fully stocked, just not in *this* language.
    """
    profile = profile_for(language)
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail={
            "code": "content_language_unavailable",
            "message": (
                f"No {profile.english_name} questions are ready for this topic yet"
            ),
            "language": profile.code,
        },
    )


async def _load_topic(db: AsyncSession, topic_id: UUID) -> Topic:
    topic = await db.scalar(select(Topic).where(Topic.id == topic_id, Topic.is_active.is_(True)))
    if not topic:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Topic not found")
    return topic


async def _user_seen_question_ids(
    db: AsyncSession,
    *,
    user_id: UUID,
    topic_id: UUID,
) -> set[UUID]:
    rows = await db.execute(
        select(Answer.question_id)
        .join(QuizSession, QuizSession.id == Answer.session_id)
        .where(QuizSession.user_id == user_id, QuizSession.topic_id == topic_id)
    )
    return set(rows.scalars().all())


async def _raise_if_unique_cap(
    db: AsyncSession,
    user: User,
    topic_id: UUID,
    *,
    session: Optional[QuizSession] = None,
) -> None:
    """When caps are enforced, block dealing once unique-seen >= allowance."""
    if session is not None and (
        session.is_daily_challenge or session.mode == GameMode.DAILY
    ):
        return
    allowance = unique_question_allowance(user)
    if allowance is None:
        return
    seen = await _user_seen_question_ids(db, user_id=user.id, topic_id=topic_id)
    if len(seen) >= allowance:
        try:
            from app.analytics import track_event

            await track_event(
                db,
                "entitlement_blocked",
                user_id=user.id,
                properties={
                    "topic_id": str(topic_id),
                    "limit": allowance,
                    "seen": len(seen),
                },
            )
        except Exception:
            pass
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "code": "entitlement_unique_cap",
                "message": "Free unique-question limit reached for this topic",
                "limit": allowance,
                "seen": len(seen),
            },
        )


async def _select_questions(
    db: AsyncSession,
    *,
    topic_id: UUID,
    difficulty: DifficultyLabel,
    exclude_ids: set[UUID],
    limit: int,
    prefer_unseen_for_user: Optional[UUID] = None,
    unique_only: bool = False,
    language: ContentLanguage = DEFAULT_LANGUAGE,
) -> list[Question]:
    """Pick playable questions — prefer never-seen-by-user, then unused-in-session.

    Language is a hard filter at every phase, including the "any difficulty"
    widening pass. Widening across difficulty makes a run easier or harder;
    widening across language would make it unreadable.
    """
    language_code = normalize_language(language).value
    low, high = DIFFICULTY_RANGES[difficulty]
    # One timestamp for every phase of the selection. Recomputing per fetch
    # could let a question expire between the unseen pass and the recycled
    # pass, which would be a confusing intermittent gap rather than a bug
    # anyone could reproduce.
    now = _now()
    seen_by_user: set[UUID] = set()
    if prefer_unseen_for_user:
        seen_by_user = await _user_seen_question_ids(
            db, user_id=prefer_unseen_for_user, topic_id=topic_id
        )

    unseen_rows: list[Question] = []
    recycled_rows: list[Question] = []

    async def _fetch(*, skip_seen: bool, difficulty_bound: bool, current_collected: set[UUID]) -> list[Question]:
        stmt = (
            select(Question)
            .options(selectinload(Question.options))
            .where(
                Question.topic_id == topic_id,
                Question.status == QuestionStatus.ACTIVE,
                Question.language == language_code,
                not_expired(now),
            )
        )
        if difficulty_bound:
            stmt = stmt.where(Question.difficulty >= low, Question.difficulty <= high)
        banned = set(exclude_ids) | current_collected
        if skip_seen:
            banned |= seen_by_user
        if banned:
            stmt = stmt.where(Question.id.notin_(banned))

        if skip_seen:
            stmt = stmt.order_by(func.random())
        else:
            stmt = stmt.order_by(Question.times_served.asc(), func.random())

        stmt = stmt.limit(limit * 3)
        return list((await db.execute(stmt)).scalars().all())

    # Phase 1: Unseen questions in exact difficulty range
    for q in await _fetch(skip_seen=True, difficulty_bound=True, current_collected=set()):
        if q.id not in {r.id for r in unseen_rows}:
            unseen_rows.append(q)

    # Phase 2: Unseen questions in any difficulty range for this topic
    if len(unseen_rows) < limit:
        collected = {r.id for r in unseen_rows}
        for q in await _fetch(skip_seen=True, difficulty_bound=False, current_collected=collected):
            if q.id not in collected:
                unseen_rows.append(q)

    random.shuffle(unseen_rows)

    # Phase 3: Recycled questions (if unseen items were fewer than limit)
    if not unique_only and len(unseen_rows) < limit:
        needed = limit - len(unseen_rows)
        collected = {r.id for r in unseen_rows}
        # Recycled in exact difficulty
        for q in await _fetch(skip_seen=False, difficulty_bound=True, current_collected=collected):
            if q.id not in collected and q.id not in {r.id for r in recycled_rows}:
                recycled_rows.append(q)

        # Recycled in any difficulty
        if len(recycled_rows) < needed:
            collected |= {r.id for r in recycled_rows}
            for q in await _fetch(skip_seen=False, difficulty_bound=False, current_collected=collected):
                if q.id not in collected:
                    recycled_rows.append(q)

        random.shuffle(recycled_rows)

    return (unseen_rows + recycled_rows)[:limit]



def answer_context_query(session_id: UUID, quiz_question_id: UUID):
    """Everything `submit_answer` needs about a question, in one round trip.

    The quiz question, its bank question, that question's options, and whether
    an answer already exists — previously four sequential queries. Each one is
    charged at the full client-to-server latency from the player's point of
    view, because the verdict cannot render until the whole chain finishes.

    The join to `answers` **must** stay an outer join: an inner join would
    return no row for a question nobody has answered yet, turning every first
    answer into a 404.
    """
    return (
        select(QuizQuestion, Question, Answer.id)
        .join(Question, Question.id == QuizQuestion.question_id)
        .outerjoin(
            Answer,
            (Answer.quiz_question_id == QuizQuestion.id)
            & (Answer.session_id == QuizQuestion.session_id),
        )
        .options(selectinload(Question.options))
        .where(
            QuizQuestion.id == quiz_question_id,
            QuizQuestion.session_id == session_id,
        )
    )


def _question_time_limit_ms(session: QuizSession, sequence_index: int) -> int:
    """Time allowed for one question.

    Fixed per session except in speedrun and survival, where it ratchets down
    with depth so a long run gets genuinely harder rather than merely longer.
    """
    if session.mode == GameMode.SPEEDRUN:
        return speedrun.question_time_limit_ms(sequence_index)
    if session.mode == GameMode.SURVIVAL:
        return survival.question_time_limit_ms(sequence_index)
    return session.question_time_limit_ms


def _playable_from_quiz_question(
    session: QuizSession,
    qq: QuizQuestion,
    question: Question,
) -> PlayableQuestionOut:
    by_pos = {opt.position: opt.text for opt in question.options}
    option_order = _normalize_option_order(qq.option_order)
    options = [
        QuizOptionOut(index=i, text=by_pos[original])
        for i, original in enumerate(option_order)
        if original in by_pos
    ]
    return PlayableQuestionOut(
        quiz_question_id=qq.id,
        question_id=question.id,
        sequence_index=qq.sequence_index,
        prompt=question.prompt,
        options=options,
        time_limit_ms=_question_time_limit_ms(session, qq.sequence_index),
        # Client starts its own timer when the question is shown — do not leak a
        # premature server served_at (feedback reading time must not burn the clock).
        served_at=qq.served_at or _now(),
    )


async def _get_session_for_user(
    db: AsyncSession,
    session_id: UUID,
    user_id: UUID,
) -> QuizSession:
    session = await db.scalar(
        select(QuizSession).where(QuizSession.id == session_id, QuizSession.user_id == user_id)
    )
    if not session:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Session not found")
    return session


async def _maybe_nudge_adaptive_difficulty(db: AsyncSession, session: QuizSession) -> None:
    """Casual + adaptive only: shift difficulty band from last up to 5 answers."""
    cfg = dict(session.config or {})
    if not cfg.get("adaptive"):
        return
    if session.mode != GameMode.CASUAL:
        return

    rows = (
        await db.execute(
            select(Answer.is_correct)
            .where(Answer.session_id == session.id)
            .order_by(Answer.answered_at.desc())
            .limit(5)
        )
    ).scalars().all()
    if not rows:
        return

    recent_correct = sum(1 for ok in rows if ok)
    recent_total = len(rows)
    current = parse_difficulty_label(
        cfg.get("adaptive_label"),
        default=session.difficulty,
    )
    new_label = nudge_label(
        current,
        recent_correct=recent_correct,
        recent_total=recent_total,
    )
    if new_label != current:
        session.difficulty = new_label
        cfg["adaptive_label"] = new_label.value
        session.config = cfg


async def _append_questions(
    db: AsyncSession,
    session: QuizSession,
    *,
    start_index: int,
    count: int,
    user: Optional[User] = None,
) -> list[QuizQuestion]:
    await _maybe_nudge_adaptive_difficulty(db, session)
    if user is not None:
        try:
            await _raise_if_unique_cap(db, user, session.topic_id, session=session)
        except HTTPException:
            return []

    allowance = unique_question_allowance(user) if user else None
    unique_only = allowance is not None and not (
        session.is_daily_challenge or session.mode == GameMode.DAILY
    )

    existing_ids = set(
        (
            await db.execute(
                select(QuizQuestion.question_id).where(QuizQuestion.session_id == session.id)
            )
        ).scalars().all()
    )
    questions = await _select_questions(
        db,
        topic_id=session.topic_id,
        difficulty=session.difficulty,
        exclude_ids=existing_ids,
        limit=count,
        prefer_unseen_for_user=session.user_id,
        unique_only=unique_only,
        language=session_language(session),
    )
    if not questions and not existing_ids:
        raise _empty_bank_error(session_language(session))

    created: list[QuizQuestion] = []
    for offset, question in enumerate(questions):
        qq = QuizQuestion(
            id=uuid4(),
            session_id=session.id,
            question_id=question.id,
            sequence_index=start_index + offset,
            option_order=_shuffle_option_order(),
        )
        db.add(qq)
        created.append(qq)
        question.times_served += 1
    await db.flush()
    return created


async def create_session(
    db: AsyncSession,
    user: User,
    payload: CreateQuizSessionRequest,
) -> QuizSessionOut:
    if payload.mode == GameMode.DAILY:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Use /daily-challenge/start for the daily challenge",
        )
    if payload.adaptive and payload.mode == GameMode.DAILY:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Adaptive mode is not available for daily challenge",
        )
    if payload.mode not in SELECTABLE_MODES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Mode '{payload.mode.value}' is no longer available",
        )

    topic = await _load_topic(db, payload.topic_id)
    await _raise_if_unique_cap(db, user, topic.id)

    profile = user.profile or await db.scalar(
        select(UserProfile).where(UserProfile.user_id == user.id)
    )
    # Explicit request wins; otherwise fall back to the language this player
    # last played in, so a client that omits the field (or an older build)
    # still gets the run they expect.
    language = normalize_language(
        payload.language if payload.language is not None else (profile.quiz_language if profile else None)
    )
    if profile is not None:
        profile.quiz_language = language.value

    defaults = _defaults_for(payload.mode)
    # Speedrun and survival own their pacing curves — a client-supplied limit
    # would break the ramp that makes every run finite.
    question_time = defaults["question_time_limit_ms"]
    if (
        payload.mode not in (GameMode.SPEEDRUN, GameMode.SURVIVAL)
        and payload.question_time_limit_ms
    ):
        question_time = payload.question_time_limit_ms

    stats = user.statistics or await db.scalar(
        select(PlayerStatistics).where(PlayerStatistics.user_id == user.id)
    )
    difficulty = payload.difficulty
    config: dict = {"version": 1}
    if payload.adaptive:
        difficulty = suggested_label_from_ratings(
            stats.skill_ratings if stats else {},
            str(topic.id),
        )
        config["adaptive"] = True
        config["adaptive_label"] = difficulty.value

    session = QuizSession(
        id=uuid4(),
        user_id=user.id,
        topic_id=topic.id,
        mode=payload.mode,
        difficulty=difficulty,
        language=language.value,
        status=QuizSessionStatus.ACTIVE,
        score=defaults["score"],
        lives=defaults["lives"],
        time_budget_ms=defaults["time_budget_ms"],
        time_remaining_ms=defaults["time_budget_ms"],
        question_time_limit_ms=question_time,
        current_question_index=0,
        started_at=_now(),
        config=config,
    )
    db.add(session)
    await db.flush()

    # Grow thin banks before dealing the first hand (unique runway).
    from app.services.bank_inventory import ensure_minimum_bank

    await ensure_minimum_bank(
        db,
        topic,
        difficulty=difficulty,
        user=user,
        language=language,
    )

    created = await _append_questions(
        db, session, start_index=0, count=_session_batch_size(), user=user
    )
    if not created:
        raise _empty_bank_error(language)

    first = created[0]
    # served_at is set lazily on answer (or get_session) so feedback time isn't penalized
    await db.flush()

    question = await db.scalar(
        select(Question)
        .options(selectinload(Question.options))
        .where(Question.id == first.question_id)
    )
    assert question is not None

    try:
        from app.analytics import track_event

        await track_event(
            db,
            "quiz_started",
            user_id=user.id,
            properties={
                "session_id": str(session.id),
                "topic_id": str(topic.id),
                "mode": session.mode.value,
                "difficulty": session.difficulty.value,
                "language": language.value,
                "adaptive": bool(payload.adaptive),
            },
        )
    except Exception:
        pass

    return QuizSessionOut(
        id=session.id,
        topic_id=topic.id,
        # The topic name follows the *content* language, not the app language:
        # it labels the questions the player is about to read.
        topic_name=localized_topic_name(topic, language),
        mode=session.mode,
        difficulty=session.difficulty,
        language=language.value,
        status=session.status,
        score=session.score,
        streak=session.streak,
        best_streak=session.best_streak,
        lives=session.lives,
        time_budget_ms=session.time_budget_ms,
        time_remaining_ms=session.time_remaining_ms,
        question_time_limit_ms=session.question_time_limit_ms,
        current_question_index=session.current_question_index,
        correct_count=session.correct_count,
        incorrect_count=session.incorrect_count,
        question_number=1,
        current_question=_playable_from_quiz_question(session, first, question),
    )


async def get_session(
    db: AsyncSession,
    user: User,
    session_id: UUID,
) -> QuizSessionOut:
    session = await _get_session_for_user(db, session_id, user.id)
    topic = await _load_topic(db, session.topic_id)
    current: Optional[PlayableQuestionOut] = None
    if session.status == QuizSessionStatus.ACTIVE:
        qq = await db.scalar(
            select(QuizQuestion).where(
                QuizQuestion.session_id == session.id,
                QuizQuestion.sequence_index == session.current_question_index,
            )
        )
        if qq:
            if qq.served_at is None:
                qq.served_at = _now()
                await db.flush()
            question = await db.scalar(
                select(Question)
                .options(selectinload(Question.options))
                .where(Question.id == qq.question_id)
            )
            if question:
                current = _playable_from_quiz_question(session, qq, question)

    return QuizSessionOut(
        id=session.id,
        topic_id=topic.id,
        topic_name=localized_topic_name(topic, session_language(session)),
        mode=session.mode,
        difficulty=session.difficulty,
        language=session_language(session).value,
        status=session.status,
        score=session.score,
        streak=session.streak,
        best_streak=session.best_streak,
        lives=session.lives,
        time_budget_ms=session.time_budget_ms,
        time_remaining_ms=session.time_remaining_ms,
        question_time_limit_ms=session.question_time_limit_ms,
        current_question_index=session.current_question_index,
        correct_count=session.correct_count,
        incorrect_count=session.incorrect_count,
        question_number=session.current_question_index + 1,
        current_question=current,
    )


def _should_end_run(session: QuizSession, is_correct: bool) -> bool:
    if session.mode == GameMode.SURVIVAL and (session.lives or 0) <= 0:
        return True
    if session.mode == GameMode.SPEEDRUN and (session.time_remaining_ms or 0) <= 0:
        return True
    return False


async def submit_answer(
    db: AsyncSession,
    user: User,
    session_id: UUID,
    payload: SubmitAnswerRequest,
) -> AnswerFeedbackOut:
    if not await check_answer_rate_limit(user.id):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many answers — slow down",
        )

    session = await _get_session_for_user(db, session_id, user.id)
    if session.status != QuizSessionStatus.ACTIVE:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Session is not active")

    row = (
        await db.execute(answer_context_query(session.id, payload.quiz_question_id))
    ).first()

    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Question not in session")

    qq, question, existing_answer_id = row
    if qq.sequence_index != session.current_question_index:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Not the current question")
    if existing_answer_id is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Answer already submitted")

    served_at = qq.served_at
    now = _now()
    option_order = _normalize_option_order(qq.option_order)
    # Persist normalized order if JSONB had drifted
    qq.option_order = option_order

    limit = _question_time_limit_ms(session, qq.sequence_index)
    client_elapsed = payload.client_elapsed_ms

    selected_original: Optional[int] = None
    if payload.selected_option_index is not None:
        if payload.selected_option_index < 0 or payload.selected_option_index >= len(option_order):
            raise HTTPException(status_code=400, detail="Invalid option index")
        selected_original = option_order[payload.selected_option_index]

    # Tentative correctness for timing resolve (before timeout logic)
    tentative_correct = (
        selected_original is not None
        and int(selected_original) == int(question.correct_option_index)
    )

    # Bind serve time to the client's question clock (not to when we prepared the
    # next question during the previous answer — that burned feedback reading time).
    if served_at is None:
        if client_elapsed is not None:
            clamped = max(0, min(int(client_elapsed), limit + ANSWER_GRACE_MS))
            qq.served_at = now - timedelta(milliseconds=clamped)
            elapsed = clamped
            wall = clamped
        else:
            qq.served_at = now
            elapsed = 0
            wall = 0
    else:
        wall = max(0, int((now - served_at).total_seconds() * 1000))
        elapsed = resolve_answer_elapsed_ms(
            client_elapsed=client_elapsed,
            wall_ms=wall,
            limit_ms=limit,
            grace_ms=ANSWER_GRACE_MS,
            is_correct=tentative_correct,
        )

    # A real tap always counts — never silently convert a selection into a timeout.
    if selected_original is not None:
        timed_out = False
        is_correct = tentative_correct
    else:
        timed_out = bool(payload.timed_out) or elapsed >= limit
        is_correct = False

    remaining = 0 if timed_out or elapsed >= limit else max(0, limit - elapsed)

    clock: Optional[speedrun.ClockOutcome] = None
    if session.mode == GameMode.SPEEDRUN and session.time_remaining_ms is not None:
        clock = speedrun.apply_clock(
            clock_ms=session.time_remaining_ms,
            elapsed_ms=elapsed,
            limit_ms=limit,
            is_correct=is_correct,
            depth=qq.sequence_index,
        )
        session.time_remaining_ms = clock.remaining_ms

    # How many lives this run has already clawed back. Each one makes the next
    # comeback more expensive, so it has to be remembered across answers.
    lives_regained = int((session.config or {}).get("lives_regained", 0))

    breakdown = scoring_service.score_answer(
        is_correct=is_correct,
        current_streak=session.streak,
        remaining_ms=remaining,
        total_ms=limit,
        mode=session.mode,
        lives=session.lives or 0,
        lives_regained=lives_regained,
        correct_count=session.correct_count,
    )
    points = clamp_points_awarded(breakdown.points_awarded)

    session.score += points
    session.streak = breakdown.new_streak
    session.best_streak = max(session.best_streak, session.streak)
    if breakdown.lives_delta and session.lives is not None:
        session.lives = max(
            0,
            min(survival.MAX_LIVES, session.lives + breakdown.lives_delta),
        )
        if breakdown.lives_delta > 0:
            # JSONB columns need a new object to be seen as dirty.
            session.config = {
                **(session.config or {}),
                "lives_regained": lives_regained + breakdown.lives_delta,
            }

    if is_correct:
        session.correct_count += 1
        question.times_correct += 1
    else:
        session.incorrect_count += 1
        question.times_incorrect += 1

    answer = Answer(
        session_id=session.id,
        quiz_question_id=qq.id,
        question_id=question.id,
        selected_option_index=payload.selected_option_index if not timed_out else None,
        is_correct=is_correct,
        client_elapsed_ms=payload.client_elapsed_ms,
        server_elapsed_ms=elapsed,
        base_points=breakdown.base_points,
        speed_bonus=breakdown.speed_bonus,
        streak_multiplier=breakdown.streak_multiplier,
        points_awarded=points,
        answered_at=_now(),
    )
    db.add(answer)

    run_ended = _should_end_run(session, is_correct)
    next_question: Optional[PlayableQuestionOut] = None

    if run_ended:
        await _finalize_session(db, user, session)
    else:
        session.current_question_index += 1
        next_qq = await db.scalar(
            select(QuizQuestion).where(
                QuizQuestion.session_id == session.id,
                QuizQuestion.sequence_index == session.current_question_index,
            )
        )
        if next_qq is None:
            # Daily challenges are a fixed hand — never endless-append.
            if session.mode == GameMode.DAILY or session.is_daily_challenge:
                await _finalize_session(db, user, session)
                run_ended = True
            else:
                # Refill session buffer from bank; kick async bank growth if thin.
                from app.services.bank_inventory import count_active_questions, enqueue_bank_topup

                topic = await _load_topic(db, session.topic_id)
                language = session_language(session)
                active = await count_active_questions(db, topic.id, language=language)
                # Keep a runway of unique items ahead of the player without racing to 1000 in one go.
                if active < max(get_settings().topic_bank_low_watermark * 2, 80):
                    await enqueue_bank_topup(
                        db,
                        topic,
                        difficulty=session.difficulty,
                        reason="session_consume",
                        user=user,
                        force=True,
                        language=language,
                    )

                appended = await _append_questions(
                    db,
                    session,
                    start_index=session.current_question_index,
                    count=_session_batch_size(),
                    user=user,
                )
                next_qq = appended[0] if appended else None
                # When unique caps apply, empty append means paywall — do not reshuffle past seen.
                allowance = unique_question_allowance(user)
                unique_only = allowance is not None and not (
                    session.is_daily_challenge or session.mode == GameMode.DAILY
                )
                if next_qq is None and not unique_only:
                    # Never reshuffle in-session questions while unused bank items exist.
                    used_ids = set(
                        (
                            await db.execute(
                                select(QuizQuestion.question_id).where(
                                    QuizQuestion.session_id == session.id
                                )
                            )
                        ).scalars().all()
                    )
                    fresh = await _select_questions(
                        db,
                        topic_id=session.topic_id,
                        difficulty=session.difficulty,
                        exclude_ids=used_ids,
                        limit=8,
                        prefer_unseen_for_user=session.user_id,
                        unique_only=False,
                        language=session_language(session),
                    )
                    if fresh:
                        pick = fresh[0]
                        next_qq = QuizQuestion(
                            id=uuid4(),
                            session_id=session.id,
                            question_id=pick.id,
                            sequence_index=session.current_question_index,
                            option_order=_shuffle_option_order(),
                        )
                        db.add(next_qq)
                        await db.flush()

        if next_qq is None and not run_ended:
            await _finalize_session(db, user, session)
            run_ended = True

        if next_qq and not run_ended:
            # Do NOT stamp served_at here — client may still be reading feedback.
            next_q = await db.scalar(
                select(Question)
                .options(selectinload(Question.options))
                .where(Question.id == next_qq.question_id)
            )
            if next_q:
                next_question = _playable_from_quiz_question(session, next_qq, next_q)

    await db.flush()

    correct_text = next(
        (o.text for o in question.options if o.position == question.correct_option_index),
        "",
    )
    client_correct_index = _client_correct_index(option_order, question.correct_option_index)

    return AnswerFeedbackOut(
        is_correct=is_correct,
        selected_option_index=payload.selected_option_index if not timed_out else None,
        correct_option_index=client_correct_index,
        correct_option_text=correct_text,
        explanation=question.explanation,
        base_points=breakdown.base_points,
        speed_bonus=breakdown.speed_bonus,
        streak_multiplier=float(breakdown.streak_multiplier),
        points_awarded=points,
        score=session.score,
        streak=session.streak,
        best_streak=session.best_streak,
        lives=session.lives,
        time_remaining_ms=session.time_remaining_ms,
        session_status=session.status,
        run_ended=run_ended or session.status == QuizSessionStatus.COMPLETED,
        next_question=next_question,
        milestone_bonus=breakdown.milestone_bonus,
        time_delta_ms=clock.delta_ms if clock else None,
        time_burned_ms=clock.burned_ms if clock else None,
        overdrive=(
            session.mode == GameMode.SPEEDRUN
            and speedrun.is_overdrive(session.streak)
        ),
        speed_tier=(
            speedrun.speed_tier(remaining, limit)
            if clock and is_correct
            else None
        ),
    )


async def finish_session(
    db: AsyncSession,
    user: User,
    session_id: UUID,
) -> QuizResultOut:
    session = await _get_session_for_user(db, session_id, user.id)
    if session.status == QuizSessionStatus.COMPLETED:
        return await get_result(db, user, session_id)
    if session.status != QuizSessionStatus.ACTIVE:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Session cannot be finished")
    await _finalize_session(db, user, session)
    await db.flush()
    return await get_result(db, user, session_id)


def _run_duration_ms(session: QuizSession) -> int:
    """Wall time the run lasted. Cosmetic — never let it break a finalize."""
    try:
        started, finished = session.started_at, session.finished_at
        if not started or not finished:
            return 0
        return max(0, int((finished - started).total_seconds() * 1000))
    except (TypeError, ValueError, OverflowError):
        return 0


async def _finalize_session(db: AsyncSession, user: User, session: QuizSession) -> None:
    if session.status == QuizSessionStatus.COMPLETED:
        return

    session.status = QuizSessionStatus.COMPLETED
    session.finished_at = _now()
    answered = session.correct_count + session.incorrect_count
    duration_ms = _run_duration_ms(session)
    accuracy = round(100.0 * session.correct_count / answered, 2) if answered else 0.0
    xp = max(10, session.score // 10) if session.score > 0 else (5 if answered else 0)

    avg_ms = await db.scalar(
        select(func.coalesce(func.avg(Answer.server_elapsed_ms), 0)).where(
            Answer.session_id == session.id
        )
    )
    average_answer_ms = int(avg_ms or 0)
    min_ms = await db.scalar(
        select(func.min(Answer.server_elapsed_ms)).where(
            Answer.session_id == session.id,
            Answer.server_elapsed_ms.is_not(None),
        )
    )
    min_answer_ms = int(min_ms) if min_ms is not None else None

    previous_best = await db.scalar(
        select(func.coalesce(func.max(Score.final_score), 0)).where(
            Score.user_id == user.id,
            Score.topic_id == session.topic_id,
            Score.mode == session.mode,
        )
    )
    previous_best_i = int(previous_best or 0)
    is_pb = session.score > previous_best_i

    score_row = Score(
        user_id=user.id,
        session_id=session.id,
        topic_id=session.topic_id,
        mode=session.mode,
        difficulty=session.difficulty,
        final_score=session.score,
        accuracy=accuracy,
        best_streak=session.best_streak,
        questions_answered=answered,
        xp_earned=xp,
        is_personal_best=is_pb,
    )
    db.add(score_row)

    topic = await _load_topic(db, session.topic_id)
    language = session_language(session)
    share_payload = build_share_payload(
        session_id=session.id,
        topic_name=localized_topic_name(topic, language),
        difficulty=session.difficulty.value,
        mode=session.mode.value,
        score=session.score,
        accuracy=accuracy,
        best_streak=session.best_streak,
        questions_answered=answered,
        language=language,
    )
    summary = {
        "final_score": session.score,
        "accuracy": accuracy,
        "best_streak": session.best_streak,
        "questions_answered": answered,
        "correct_count": session.correct_count,
        "incorrect_count": session.incorrect_count,
        "average_answer_ms": average_answer_ms,
        "xp_earned": xp,
        "topic_name": localized_topic_name(topic, language),
        "language": language.value,
        "duration_ms": duration_ms,
    }
    comparisons = {
        "previous_best": previous_best_i,
        "is_personal_best": is_pb,
        "delta_vs_best": session.score - previous_best_i,
    }
    db.add(
        QuizResult(
            session_id=session.id,
            user_id=user.id,
            summary=summary,
            share_payload=share_payload,
            comparisons=comparisons,
        )
    )

    stats = user.statistics or await db.scalar(
        select(PlayerStatistics).where(PlayerStatistics.user_id == user.id)
    )
    profile = user.profile or await db.scalar(
        select(UserProfile).where(UserProfile.user_id == user.id)
    )
    if stats:
        stats.total_quizzes += 1
        stats.total_questions += answered
        stats.total_correct += session.correct_count
        stats.total_incorrect += session.incorrect_count
        stats.total_score += max(session.score, 0)
        stats.best_score = max(stats.best_score, session.score)
        stats.best_streak = max(stats.best_streak, session.best_streak)
        if answered:
            # rolling-ish average
            prev_total = max(stats.total_questions - answered, 0)
            if prev_total <= 0:
                stats.average_answer_ms = average_answer_ms
            else:
                stats.average_answer_ms = int(
                    ((stats.average_answer_ms * prev_total) + (average_answer_ms * answered))
                    / (prev_total + answered)
                )
        mastery = dict(stats.topic_mastery or {})
        key = str(session.topic_id)
        prev = mastery.get(key, {"correct": 0, "total": 0, "percent": 0})
        correct = int(prev.get("correct", 0)) + session.correct_count
        total = int(prev.get("total", 0)) + answered
        mastery[key] = {
            "correct": correct,
            "total": total,
            "percent": round(100.0 * correct / total, 1) if total else 0,
            "name": topic.name,
        }
        stats.topic_mastery = mastery
        if answered > 0:
            stats.skill_ratings = update_topic_rating(
                stats.skill_ratings,
                topic_id=str(session.topic_id),
                accuracy_percent=accuracy,
                session_label=session.difficulty,
            )

    newly_unlocked = []
    if profile:
        today = _now().date()
        new_daily, played_on = update_daily_streak(
            daily_streak=profile.daily_streak,
            last_played_date=profile.last_played_date,
            today=today,
        )
        profile.daily_streak = new_daily
        profile.current_streak = new_daily
        profile.last_played_date = played_on
        profile.best_streak = max(profile.best_streak, session.best_streak)
        profile.level, profile.xp = apply_xp(profile.level, profile.xp, xp)

        streak_row = await db.scalar(
            select(Streak).where(Streak.user_id == user.id, Streak.streak_type == "daily")
        )
        if streak_row is None:
            streak_row = Streak(
                user_id=user.id,
                streak_type="daily",
                current_count=new_daily,
                best_count=new_daily,
                last_increment_date=played_on,
            )
            db.add(streak_row)
        else:
            streak_row.current_count = new_daily
            streak_row.best_count = max(streak_row.best_count, new_daily)
            streak_row.last_increment_date = played_on

        perfect_run = answered >= 10 and session.incorrect_count == 0 and session.correct_count == answered
        ctx = await achievements_service.build_context_from_profile_stats(
            db,
            profile=profile,
            quizzes_completed=(stats.total_quizzes if stats else 1),
            correct_answers=(stats.total_correct if stats else session.correct_count),
            best_streak=max(
                (stats.best_streak if stats else 0),
                profile.best_streak,
                session.best_streak,
            ),
            topic_mastery=(stats.topic_mastery if stats else {}) or {},
            min_answer_ms=min_answer_ms,
            perfect_run=perfect_run,
            daily_completed=bool(session.is_daily_challenge),
        )
        newly_unlocked = await achievements_service.evaluate_and_unlock(
            db,
            user_id=user.id,
            profile=profile,
            ctx=ctx,
        )

    # Leaderboards: weekly for all runs; daily board for daily challenge
    try:
        from app.services import leaderboards as lb_service

        daily_date = None
        if session.is_daily_challenge or session.mode == GameMode.DAILY:
            daily_date = _now().date()
        await lb_service.record_score(
            db,
            user_id=user.id,
            score=session.score,
            weekly=True,
            daily_date=daily_date,
        )
    except Exception:
        # Leaderboard must never block session finalize
        pass

    try:
        from app.analytics import track_event

        cfg = dict(session.config or {})
        await track_event(
            db,
            "quiz_finished",
            user_id=user.id,
            properties={
                "session_id": str(session.id),
                "topic_id": str(session.topic_id),
                "mode": session.mode.value,
                "difficulty": session.difficulty.value,
                "language": language.value,
                "adaptive": bool(cfg.get("adaptive")),
                "score": session.score,
                "accuracy": accuracy,
                "questions_answered": answered,
            },
        )
        if newly_unlocked:
            await track_event(
                db,
                "achievement_unlocked",
                user_id=user.id,
                properties={
                    "codes": [a.code for a in newly_unlocked],
                    "session_id": str(session.id),
                },
            )
    except Exception:
        pass

    # Persist unlocks on the result summary for later get_result calls
    quiz_result = await db.scalar(select(QuizResult).where(QuizResult.session_id == session.id))
    if quiz_result is not None:
        summary_blob = dict(quiz_result.summary or {})
        summary_blob["new_achievements"] = [
            {
                "id": str(a.id),
                "code": a.code,
                "name": a.name,
                "description": a.description,
                "icon": a.icon,
                "category": a.category,
                "xp_reward": a.xp_reward,
                "coins_reward": a.coins_reward,
            }
            for a in newly_unlocked
        ]
        if profile:
            summary_blob["level"] = profile.level
            summary_blob["xp"] = profile.xp
            summary_blob["coins"] = profile.coins
            summary_blob["daily_streak"] = profile.daily_streak
            summary_blob["current_streak"] = profile.current_streak
        quiz_result.summary = summary_blob


async def get_result(
    db: AsyncSession,
    user: User,
    session_id: UUID,
) -> QuizResultOut:
    session = await _get_session_for_user(db, session_id, user.id)
    if session.status != QuizSessionStatus.COMPLETED:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Session not finished")

    result = await db.scalar(select(QuizResult).where(QuizResult.session_id == session.id))
    score = await db.scalar(select(Score).where(Score.session_id == session.id))
    topic = await _load_topic(db, session.topic_id)
    summary = (result.summary if result else {}) or {}
    comparisons = (result.comparisons if result else {}) or {}
    share = (result.share_payload if result else {}) or {}
    profile = user.profile or await db.scalar(
        select(UserProfile).where(UserProfile.user_id == user.id)
    )

    raw_unlocks = summary.get("new_achievements") or []
    new_achievements: list[AchievementUnlockedOut] = []
    for item in raw_unlocks:
        try:
            new_achievements.append(AchievementUnlockedOut.model_validate(item))
        except Exception:
            continue

    language = session_language(session)
    return QuizResultOut(
        session_id=session.id,
        topic_name=summary.get("topic_name", localized_topic_name(topic, language)),
        mode=session.mode,
        difficulty=session.difficulty,
        language=language.value,
        final_score=score.final_score if score else session.score,
        accuracy=float(summary.get("accuracy", 0)),
        best_streak=score.best_streak if score else session.best_streak,
        questions_answered=score.questions_answered if score else session.correct_count + session.incorrect_count,
        correct_count=int(summary.get("correct_count", session.correct_count)),
        incorrect_count=int(summary.get("incorrect_count", session.incorrect_count)),
        average_answer_ms=int(summary.get("average_answer_ms", 0)),
        duration_ms=int(summary.get("duration_ms", 0) or 0),
        xp_earned=score.xp_earned if score else int(summary.get("xp_earned", 0)),
        is_personal_best=bool(comparisons.get("is_personal_best", False)),
        previous_best=int(comparisons.get("previous_best", 0)),
        share_text=str(share.get("text", "")),
        share_payload=dict(share) if isinstance(share, dict) else {},
        comparisons=comparisons,
        new_achievements=new_achievements,
        level=int(summary["level"]) if "level" in summary else (profile.level if profile else None),
        xp=int(summary["xp"]) if "xp" in summary else (profile.xp if profile else None),
        coins=int(summary["coins"]) if "coins" in summary else (profile.coins if profile else None),
        daily_streak=int(summary["daily_streak"])
        if "daily_streak" in summary
        else (profile.daily_streak if profile else None),
        current_streak=int(summary["current_streak"])
        if "current_streak" in summary
        else (profile.current_streak if profile else None),
    )
