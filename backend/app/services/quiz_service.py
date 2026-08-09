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
from app.services import achievements as achievements_service
from app.services.progression import apply_xp, update_daily_streak
from app.services.scoring import scoring_service

DIFFICULTY_RANGES: dict[DifficultyLabel, tuple[float, float]] = {
    DifficultyLabel.EASY: (0.0, 0.4),
    DifficultyLabel.MEDIUM: (0.35, 0.65),
    DifficultyLabel.HARD: (0.6, 0.85),
    DifficultyLabel.EXPERT: (0.8, 1.0),
}

MODE_DEFAULTS: dict[GameMode, dict] = {
    GameMode.CASUAL: {"question_time_limit_ms": 15000, "lives": None, "score": 0, "time_budget_ms": None},
    GameMode.SPEEDRUN: {"question_time_limit_ms": 10000, "lives": None, "score": 0, "time_budget_ms": 60000},
    GameMode.SURVIVAL: {"question_time_limit_ms": 15000, "lives": 3, "score": 0, "time_budget_ms": None},
    GameMode.NEGATIVE: {"question_time_limit_ms": 15000, "lives": None, "score": 1000, "time_budget_ms": None},
    GameMode.SUDDEN_DEATH: {"question_time_limit_ms": 12000, "lives": None, "score": 0, "time_budget_ms": None},
    GameMode.DAILY: {"question_time_limit_ms": 15000, "lives": None, "score": 0, "time_budget_ms": None},
}

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


async def _select_questions(
    db: AsyncSession,
    *,
    topic_id: UUID,
    difficulty: DifficultyLabel,
    exclude_ids: set[UUID],
    limit: int,
    prefer_unseen_for_user: Optional[UUID] = None,
) -> list[Question]:
    """Pick playable questions — prefer never-seen-by-user, then unused-in-session."""
    low, high = DIFFICULTY_RANGES[difficulty]
    seen_by_user: set[UUID] = set()
    if prefer_unseen_for_user:
        seen_by_user = await _user_seen_question_ids(
            db, user_id=prefer_unseen_for_user, topic_id=topic_id
        )

    async def _fetch(*, skip_seen: bool, difficulty_bound: bool) -> list[Question]:
        stmt = (
            select(Question)
            .options(selectinload(Question.options))
            .where(
                Question.topic_id == topic_id,
                Question.status == QuestionStatus.ACTIVE,
            )
            .order_by(func.random())
            .limit(limit * 3)
        )
        if difficulty_bound:
            stmt = stmt.where(Question.difficulty >= low, Question.difficulty <= high)
        banned = set(exclude_ids)
        if skip_seen:
            banned |= seen_by_user
        if banned:
            stmt = stmt.where(Question.id.notin_(banned))
        return list((await db.execute(stmt)).scalars().all())

    rows = await _fetch(skip_seen=True, difficulty_bound=True)
    if len(rows) < limit:
        for q in await _fetch(skip_seen=True, difficulty_bound=False):
            if q.id not in {r.id for r in rows}:
                rows.append(q)
    if len(rows) < limit:
        for q in await _fetch(skip_seen=False, difficulty_bound=True):
            if q.id not in {r.id for r in rows}:
                rows.append(q)
    if len(rows) < limit:
        for q in await _fetch(skip_seen=False, difficulty_bound=False):
            if q.id not in {r.id for r in rows}:
                rows.append(q)

    random.shuffle(rows)
    return rows[:limit]


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
        time_limit_ms=session.question_time_limit_ms,
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


async def _append_questions(
    db: AsyncSession,
    session: QuizSession,
    *,
    start_index: int,
    count: int,
) -> list[QuizQuestion]:
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
    )
    if not questions and not existing_ids:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="No playable questions available for this topic yet",
        )

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
    topic = await _load_topic(db, payload.topic_id)
    defaults = MODE_DEFAULTS[payload.mode]
    question_time = payload.question_time_limit_ms or defaults["question_time_limit_ms"]

    session = QuizSession(
        id=uuid4(),
        user_id=user.id,
        topic_id=topic.id,
        mode=payload.mode,
        difficulty=payload.difficulty,
        status=QuizSessionStatus.ACTIVE,
        score=defaults["score"],
        lives=defaults["lives"],
        time_budget_ms=defaults["time_budget_ms"],
        time_remaining_ms=defaults["time_budget_ms"],
        question_time_limit_ms=question_time,
        current_question_index=0,
        started_at=_now(),
        config={"version": 1},
    )
    db.add(session)
    await db.flush()

    # Grow thin banks before dealing the first hand (unique runway).
    from app.services.bank_inventory import ensure_minimum_bank

    await ensure_minimum_bank(
        db,
        topic,
        difficulty=payload.difficulty,
        user=user,
    )

    created = await _append_questions(
        db, session, start_index=0, count=_session_batch_size()
    )
    if not created:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="No playable questions available for this topic yet",
        )

    first = created[0]
    # served_at is set lazily on answer (or get_session) so feedback time isn't penalized
    await db.flush()

    question = await db.scalar(
        select(Question)
        .options(selectinload(Question.options))
        .where(Question.id == first.question_id)
    )
    assert question is not None

    return QuizSessionOut(
        id=session.id,
        topic_id=topic.id,
        topic_name=topic.name,
        mode=session.mode,
        difficulty=session.difficulty,
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
        topic_name=topic.name,
        mode=session.mode,
        difficulty=session.difficulty,
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
    if session.mode == GameMode.SUDDEN_DEATH and not is_correct:
        return True
    if session.mode == GameMode.SURVIVAL and (session.lives or 0) <= 0:
        return True
    if session.mode == GameMode.NEGATIVE and session.score <= 0:
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
    session = await _get_session_for_user(db, session_id, user.id)
    if session.status != QuizSessionStatus.ACTIVE:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Session is not active")

    qq = await db.scalar(
        select(QuizQuestion).where(
            QuizQuestion.id == payload.quiz_question_id,
            QuizQuestion.session_id == session.id,
        )
    )
    if not qq:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Question not in session")
    if qq.sequence_index != session.current_question_index:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Not the current question")

    existing = await db.scalar(
        select(Answer.id).where(
            Answer.session_id == session.id,
            Answer.quiz_question_id == qq.id,
        )
    )
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Answer already submitted")

    question = await db.scalar(
        select(Question)
        .options(selectinload(Question.options))
        .where(Question.id == qq.question_id)
    )
    assert question is not None

    served_at = qq.served_at
    now = _now()
    option_order = _normalize_option_order(qq.option_order)
    # Persist normalized order if JSONB had drifted
    qq.option_order = option_order

    limit = session.question_time_limit_ms
    client_elapsed = payload.client_elapsed_ms

    # Bind serve time to the client's question clock (not to when we prepared the
    # next question during the previous answer — that burned feedback reading time).
    if served_at is None:
        if client_elapsed is not None:
            clamped = max(0, min(int(client_elapsed), limit + ANSWER_GRACE_MS))
            qq.served_at = now - timedelta(milliseconds=clamped)
            elapsed = clamped
        else:
            qq.served_at = now
            elapsed = 0
    else:
        wall = max(0, int((now - served_at).total_seconds() * 1000))
        if client_elapsed is not None:
            # Prefer client elapsed for fairness; wall is only a sanity ceiling.
            elapsed = max(0, min(int(client_elapsed), limit + ANSWER_GRACE_MS))
            # If client claims far more time than wall, clamp to wall (+skew).
            elapsed = min(elapsed, wall + 2000)
        else:
            elapsed = wall

    selected_original: Optional[int] = None
    if payload.selected_option_index is not None:
        if payload.selected_option_index < 0 or payload.selected_option_index >= len(option_order):
            raise HTTPException(status_code=400, detail="Invalid option index")
        selected_original = option_order[payload.selected_option_index]

    # A real tap always counts — never silently convert a selection into a timeout.
    # (Previously served_at was stamped when preparing next_question, so reading
    # "Why?" / Teach Me made the server think the next question had already expired.)
    if selected_original is not None:
        timed_out = False
        is_correct = int(selected_original) == int(question.correct_option_index)
    else:
        timed_out = bool(payload.timed_out) or elapsed >= limit
        is_correct = False

    remaining = 0 if timed_out or elapsed >= limit else max(0, limit - elapsed)

    if session.mode == GameMode.SPEEDRUN and session.time_remaining_ms is not None:
        spent = min(elapsed, limit)
        session.time_remaining_ms = max(0, session.time_remaining_ms - spent)

    breakdown = scoring_service.score_answer(
        is_correct=is_correct,
        current_streak=session.streak,
        remaining_ms=remaining,
        total_ms=limit,
        mode=session.mode,
    )

    session.score += breakdown.points_awarded
    session.streak = breakdown.new_streak
    session.best_streak = max(session.best_streak, session.streak)
    if breakdown.lives_delta and session.lives is not None:
        session.lives = max(0, session.lives + breakdown.lives_delta)

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
        points_awarded=breakdown.points_awarded,
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
            # Refill session buffer from bank; kick async bank growth if thin.
            from app.services.bank_inventory import count_active_questions, enqueue_bank_topup

            topic = await _load_topic(db, session.topic_id)
            active = await count_active_questions(db, topic.id)
            # Keep a runway of unique items ahead of the player without racing to 1000 in one go.
            if active < max(get_settings().topic_bank_low_watermark * 2, 80):
                await enqueue_bank_topup(
                    db,
                    topic,
                    difficulty=session.difficulty,
                    reason="session_consume",
                    user=user,
                    force=True,
                )

            appended = await _append_questions(
                db,
                session,
                start_index=session.current_question_index,
                count=_session_batch_size(),
            )
            next_qq = appended[0] if appended else None
            if next_qq is None:
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
                else:
                    # True exhaustion of unused bank items for this session — reuse least-served.
                    reused = await _select_questions(
                        db,
                        topic_id=session.topic_id,
                        difficulty=session.difficulty,
                        exclude_ids=set(),
                        limit=8,
                        prefer_unseen_for_user=session.user_id,
                    )
                    if reused:
                        # Prefer questions not already in this session when possible
                        unused = [q for q in reused if q.id not in used_ids]
                        pick = (unused or reused)[0]
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
        points_awarded=breakdown.points_awarded,
        score=session.score,
        streak=session.streak,
        best_streak=session.best_streak,
        lives=session.lives,
        time_remaining_ms=session.time_remaining_ms,
        session_status=session.status,
        run_ended=run_ended or session.status == QuizSessionStatus.COMPLETED,
        next_question=next_question,
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


async def _finalize_session(db: AsyncSession, user: User, session: QuizSession) -> None:
    if session.status == QuizSessionStatus.COMPLETED:
        return

    session.status = QuizSessionStatus.COMPLETED
    session.finished_at = _now()
    answered = session.correct_count + session.incorrect_count
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
    share_text = (
        f"🧠 QUIZVERSE\n\n{topic.name} — {session.difficulty.value.upper()}\n\n"
        f"Score: {session.score:,}\nAccuracy: {accuracy:.0f}%\n"
        f"Best Streak: {session.best_streak}\n\nCan you beat me?"
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
        "topic_name": topic.name,
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
            share_payload={"text": share_text},
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
        )
        newly_unlocked = await achievements_service.evaluate_and_unlock(
            db,
            user_id=user.id,
            profile=profile,
            ctx=ctx,
        )

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

    return QuizResultOut(
        session_id=session.id,
        topic_name=summary.get("topic_name", topic.name),
        mode=session.mode,
        difficulty=session.difficulty,
        final_score=score.final_score if score else session.score,
        accuracy=float(summary.get("accuracy", 0)),
        best_streak=score.best_streak if score else session.best_streak,
        questions_answered=score.questions_answered if score else session.correct_count + session.incorrect_count,
        correct_count=int(summary.get("correct_count", session.correct_count)),
        incorrect_count=int(summary.get("incorrect_count", session.incorrect_count)),
        average_answer_ms=int(summary.get("average_answer_ms", 0)),
        xp_earned=score.xp_earned if score else int(summary.get("xp_earned", 0)),
        is_personal_best=bool(comparisons.get("is_personal_best", False)),
        previous_best=int(comparisons.get("previous_best", 0)),
        share_text=str(share.get("text", "")),
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
