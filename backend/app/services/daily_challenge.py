"""Daily challenge — fixed question set per UTC day (no LLM)."""

from __future__ import annotations

import random
from datetime import date, datetime, timedelta, timezone
from typing import Optional
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.languages import DEFAULT_LANGUAGE
from app.models import (
    DailyChallenge,
    DifficultyLabel,
    GameMode,
    Question,
    QuestionStatus,
    QuizQuestion,
    QuizSession,
    QuizSessionStatus,
    Score,
    Topic,
    User,
)
from app.schemas.daily import DailyChallengeOut
from app.schemas.quiz import QuizSessionOut
from app.services.daily_constants import DAILY_MIN_COUNT, DAILY_TARGET_COUNT, seed_for_date
from app.services.question_filters import not_expired
from app.services.quiz_service import (
    MODE_DEFAULTS,
    _now,
    _playable_from_quiz_question,
    _shuffle_option_order,
)


def utc_today() -> date:
    return datetime.now(timezone.utc).date()


async def ensure_today(db: AsyncSession, *, challenge_date: Optional[date] = None) -> DailyChallenge:
    day = challenge_date or utc_today()
    existing = await db.scalar(
        select(DailyChallenge).where(DailyChallenge.challenge_date == day)
    )
    if existing:
        return existing

    topics = list(
        (
            await db.execute(
                select(Topic)
                .where(Topic.is_active.is_(True), Topic.is_custom.is_(False))
                .order_by(Topic.slug.asc())
            )
        )
        .scalars()
        .all()
    )
    if not topics:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="No topics available for daily challenge",
        )

    rng = random.Random(seed_for_date(day))
    difficulty = DifficultyLabel.MEDIUM
    low, high = (0.35, 0.65)

    # The daily challenge is one shared set of questions feeding one shared
    # leaderboard, so it is pinned to the default language rather than split
    # per language — a per-language daily would need a per-language board to
    # stay a fair comparison.
    daily_language = DEFAULT_LANGUAGE.value

    # A daily challenge is one pinned set feeding one shared leaderboard, so a
    # question must still be true at the *end* of the day, not merely at the
    # moment the set is built. Picking one that expires at noon would either
    # shrink the quiz mid-day or start serving a stale fact — both of which
    # make the day's scores incomparable.
    day_end = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc) + timedelta(days=1)

    async def _candidates(topic_id, *, difficulty_bound: bool) -> list:
        stmt = select(Question.id).where(
            Question.topic_id == topic_id,
            Question.status == QuestionStatus.ACTIVE,
            Question.language == daily_language,
            not_expired(day_end),
        )
        if difficulty_bound:
            stmt = stmt.where(Question.difficulty >= low, Question.difficulty <= high)
        return list((await db.execute(stmt)).scalars().all())

    # Walk the topic ring from the day's slot and take the first topic that can
    # actually fill a challenge.
    #
    # Previously this committed to `topics[day_of_year % len]` and 409'd if that
    # one came up short, which was survivable while every topic was a permanent
    # bank. Rolling news topics are in this rotation now and are legitimately
    # empty on a day the corpus was thin — without the walk, one quiet Tuesday
    # in the sport feed would take out the daily challenge for everybody.
    start = day.timetuple().tm_yday % len(topics)
    topic = None
    candidates: list = []
    for offset in range(len(topics)):
        contender = topics[(start + offset) % len(topics)]
        found = await _candidates(contender.id, difficulty_bound=True)
        if len(found) < DAILY_MIN_COUNT:
            found = await _candidates(contender.id, difficulty_bound=False)
        if len(found) >= DAILY_MIN_COUNT:
            topic, candidates = contender, found
            break

    if topic is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Not enough questions for today's daily challenge",
        )

    rng.shuffle(candidates)
    picked = [str(qid) for qid in candidates[:DAILY_TARGET_COUNT]]

    challenge = DailyChallenge(
        id=uuid4(),
        challenge_date=day,
        topic_id=topic.id,
        title=f"{topic.name} Daily",
        difficulty=difficulty,
        question_ids=picked,
        is_active=True,
    )
    try:
        async with db.begin_nested():
            db.add(challenge)
            await db.flush()
    except IntegrityError:
        existing = await db.scalar(
            select(DailyChallenge).where(DailyChallenge.challenge_date == day)
        )
        if existing:
            return existing
        raise
    return challenge


async def _user_sessions_for_challenge(
    db: AsyncSession,
    *,
    user_id: UUID,
    challenge_id: UUID,
) -> list[QuizSession]:
    rows = await db.execute(
        select(QuizSession)
        .where(
            QuizSession.user_id == user_id,
            QuizSession.daily_challenge_id == challenge_id,
        )
        .order_by(QuizSession.created_at.desc())
    )
    return list(rows.scalars().all())


async def get_daily_for_user(db: AsyncSession, user: User) -> DailyChallengeOut:
    challenge = await ensure_today(db)
    topic = await db.scalar(select(Topic).where(Topic.id == challenge.topic_id))
    sessions = await _user_sessions_for_challenge(db, user_id=user.id, challenge_id=challenge.id)

    completed = next((s for s in sessions if s.status == QuizSessionStatus.COMPLETED), None)
    active = next((s for s in sessions if s.status == QuizSessionStatus.ACTIVE), None)

    best_score: Optional[int] = None
    if completed:
        score = await db.scalar(select(Score.final_score).where(Score.session_id == completed.id))
        best_score = int(score) if score is not None else completed.score

    if completed:
        status_label = "completed"
        session_id = completed.id
    elif active:
        status_label = "in_progress"
        session_id = active.id
    else:
        status_label = "available"
        session_id = None

    return DailyChallengeOut(
        id=challenge.id,
        challenge_date=challenge.challenge_date,
        title=challenge.title,
        topic_id=challenge.topic_id,
        topic_name=topic.name if topic else "Topic",
        topic_icon=topic.icon if topic else "📅",
        difficulty=challenge.difficulty,
        question_count=len(challenge.question_ids or []),
        status=status_label,
        best_score=best_score,
        session_id=session_id,
    )


async def start_daily(db: AsyncSession, user: User) -> QuizSessionOut:
    challenge = await ensure_today(db)
    sessions = await _user_sessions_for_challenge(db, user_id=user.id, challenge_id=challenge.id)

    completed = next((s for s in sessions if s.status == QuizSessionStatus.COMPLETED), None)
    if completed:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Daily challenge already completed today",
        )

    active = next((s for s in sessions if s.status == QuizSessionStatus.ACTIVE), None)
    if active:
        from app.services import quiz_service

        return await quiz_service.get_session(db, user, active.id)

    topic = await db.scalar(select(Topic).where(Topic.id == challenge.topic_id))
    if not topic:
        raise HTTPException(status_code=404, detail="Daily topic missing")

    question_ids: list[UUID] = []
    for raw in challenge.question_ids or []:
        try:
            question_ids.append(UUID(str(raw)))
        except (ValueError, TypeError):
            continue
    if len(question_ids) < DAILY_MIN_COUNT:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Daily challenge is misconfigured",
        )

    # Deliberately *not* filtered by expiry. `ensure_today` already required
    # every pinned question to outlive the day; re-checking here would let a
    # question vanish between two players' runs and quietly make their scores
    # incomparable. The pinned set is immutable for the day it belongs to.
    questions = list(
        (
            await db.execute(
                select(Question)
                .options(selectinload(Question.options))
                .where(Question.id.in_(question_ids), Question.status == QuestionStatus.ACTIVE)
            )
        )
        .scalars()
        .all()
    )
    by_id = {q.id: q for q in questions}
    ordered = [by_id[qid] for qid in question_ids if qid in by_id]
    if len(ordered) < DAILY_MIN_COUNT:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Daily challenge questions unavailable",
        )

    defaults = MODE_DEFAULTS[GameMode.DAILY]
    session = QuizSession(
        id=uuid4(),
        user_id=user.id,
        topic_id=topic.id,
        mode=GameMode.DAILY,
        difficulty=challenge.difficulty,
        language=DEFAULT_LANGUAGE.value,
        status=QuizSessionStatus.ACTIVE,
        score=defaults["score"],
        lives=defaults["lives"],
        time_budget_ms=defaults["time_budget_ms"],
        time_remaining_ms=defaults["time_budget_ms"],
        question_time_limit_ms=defaults["question_time_limit_ms"],
        current_question_index=0,
        started_at=_now(),
        config={"version": 1, "daily": True, "question_count": len(ordered)},
        is_daily_challenge=True,
        daily_challenge_id=challenge.id,
    )
    db.add(session)
    await db.flush()

    first_qq: Optional[QuizQuestion] = None
    for idx, question in enumerate(ordered):
        qq = QuizQuestion(
            id=uuid4(),
            session_id=session.id,
            question_id=question.id,
            sequence_index=idx,
            option_order=_shuffle_option_order(),
        )
        db.add(qq)
        question.times_served += 1
        if idx == 0:
            first_qq = qq
    await db.flush()
    assert first_qq is not None

    try:
        from app.analytics import track_event

        await track_event(
            db,
            "daily_started",
            user_id=user.id,
            properties={
                "session_id": str(session.id),
                "challenge_id": str(challenge.id),
                "topic_id": str(topic.id),
            },
        )
        await track_event(
            db,
            "quiz_started",
            user_id=user.id,
            properties={
                "session_id": str(session.id),
                "topic_id": str(topic.id),
                "mode": "daily",
                "difficulty": session.difficulty.value,
                "adaptive": False,
                "daily": True,
            },
        )
    except Exception:
        pass

    return QuizSessionOut(
        id=session.id,
        topic_id=topic.id,
        topic_name=topic.name,
        mode=session.mode,
        difficulty=session.difficulty,
        language=DEFAULT_LANGUAGE.value,
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
        current_question=_playable_from_quiz_question(session, first_qq, ordered[0]),
    )
