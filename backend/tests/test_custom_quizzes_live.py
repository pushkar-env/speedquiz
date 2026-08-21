"""End-to-end custom-quiz flow against a real Postgres. Skipped by default.

Why this exists
---------------
The rest of the suite is DB-free, which is a good trade for logic but leaves
one class of bug completely uncovered: anything that only exists once a real
SQLAlchemy session is talking to a real database. A shipped release build hit
exactly that — every mutation flushes a change to the quiz row, and
``TimestampMixin.updated_at`` carries an ``onupdate`` of ``func.now()``, so
SQLAlchemy expires the attribute and reads it back on next access. Under
asyncio that read must be awaited; the synchronous `serialize` touched it and
raised `MissingGreenlet`, which FastAPI turned into a 500 on "add question".

No amount of mocking finds that. Running the real functions against a real
database does, in about a second.

Running it
----------
Point it at a **scratch** database and nothing else::

    CUSTOM_QUIZ_LIVE_DB_URL=postgresql+asyncpg://user:pass@localhost/scratch \\
        pytest tests/test_custom_quizzes_live.py

Deliberately gated on its own variable rather than ``DATABASE_URL``: that one
resolves to whatever ``.env`` is in scope, which on this repo is production.
A test that writes must never be one environment variable away from doing it
somewhere real.

Everything runs inside a transaction that is rolled back, and the database
needs the schema at head plus at least one active user.
"""

from __future__ import annotations

import os
from uuid import uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import selectinload

from app.models import CustomQuiz, CustomQuizVisibility, GameMode, QuizSession, User
from app.schemas.custom_quizzes import (
    ChallengeWithQuizRequest,
    CreateCustomQuizRequest,
    CustomQuizQuestionIn,
    ReportQuizRequest,
    StartCustomQuizRequest,
    UpdateCustomQuizRequest,
)
from app.services import custom_quizzes as cq
from app.services import quiz_service

LIVE_DB_URL = os.environ.get("CUSTOM_QUIZ_LIVE_DB_URL", "").strip()

pytestmark = pytest.mark.skipif(
    not LIVE_DB_URL,
    reason="set CUSTOM_QUIZ_LIVE_DB_URL to a scratch database to run the live flow",
)


def _question(prompt: str, correct: int = 0) -> CustomQuizQuestionIn:
    stem = prompt[:12]
    return CustomQuizQuestionIn(
        prompt=prompt,
        options=[f"{stem} A", f"{stem} B", f"{stem} C", f"{stem} D"],
        correct_option_index=correct,
    )


@pytest.fixture
async def db():
    """A session on the scratch database, always rolled back."""
    engine = create_async_engine(LIVE_DB_URL)
    session = AsyncSession(engine)
    try:
        yield session
    finally:
        await session.rollback()
        await session.close()
        await engine.dispose()


@pytest.fixture
async def author(db: AsyncSession) -> User:
    user = await db.scalar(
        select(User)
        # Loaded the way `get_current_user` does. With a lazy `profile` the
        # failure would be the fixture's rather than the code's.
        .options(selectinload(User.profile), selectinload(User.statistics))
        .where(User.is_active.is_(True))
        .limit(1)
    )
    if user is None:
        pytest.skip("the scratch database has no active users")
    return user


async def _published_quiz(db: AsyncSession, author: User) -> CustomQuiz:
    detail = await cq.create_quiz(
        db,
        author,
        CreateCustomQuizRequest(
            title=f"live-{uuid4().hex[:6]}",
            visibility=CustomQuizVisibility.LINK,
        ),
    )
    for i in range(3):
        await cq.add_question(db, author, detail.id, _question(f"Live probe {i}"))
    await cq.publish(db, author, detail.id)
    quiz = await db.scalar(select(CustomQuiz).where(CustomQuiz.id == detail.id))
    assert quiz is not None
    return quiz


async def test_adding_a_question_survives_the_flush_that_expires_updated_at(
    db: AsyncSession, author: User
):
    """The exact regression. `create_quiz` passed and `add_question` did not,
    because with no starter questions the counter goes 0 -> 0, SQLAlchemy emits
    no UPDATE, and nothing is expired."""
    detail = await cq.create_quiz(
        db, author, CreateCustomQuizRequest(title=f"live-{uuid4().hex[:6]}")
    )
    after = await cq.add_question(db, author, detail.id, _question("Does this 500?"))
    assert after.question_count == 1
    assert after.questions[0].prompt == "Does this 500?"
    assert after.questions[0].correct_option_index == 0


async def test_the_full_authoring_lifecycle(db: AsyncSession, author: User):
    quiz = await _published_quiz(db, author)
    assert quiz.code, "publishing mints a share code"

    detail = await cq.serialize_detail(db, quiz, author)
    assert detail.question_count == 3
    assert detail.publish_blockers == []

    # Editing, reordering and removing all round-trip.
    first = detail.questions[0]
    edited = await cq.update_question(
        db, author, quiz.id, first.id, _question("Edited prompt", correct=2)
    )
    assert edited.questions[0].correct_option_index == 2

    ids = [q.id for q in edited.questions]
    reordered = await cq.reorder_questions(db, author, quiz.id, list(reversed(ids)))
    assert [q.id for q in reordered.questions] == list(reversed(ids))

    renamed = await cq.update_quiz(
        db, author, quiz.id, UpdateCustomQuizRequest(title="Renamed live quiz")
    )
    assert renamed.title == "Renamed live quiz"

    # Below the publish floor the quiz drops back to draft rather than staying
    # listed as playable while every challenge on it 409s.
    trimmed = await cq.delete_question(db, author, quiz.id, reordered.questions[-1].id)
    assert trimmed.question_count == 2
    assert trimmed.status.value == "draft"


@pytest.mark.parametrize("mode", [GameMode.CASUAL, GameMode.SPEEDRUN, GameMode.SURVIVAL])
async def test_every_mode_starts_on_a_custom_quiz(
    db: AsyncSession, author: User, mode: GameMode
):
    quiz = await _published_quiz(db, author)
    run = await cq.start_solo(db, author, quiz.id, StartCustomQuizRequest(mode=mode))
    assert run.session.mode is mode
    assert run.session.current_question is not None


async def test_a_custom_run_is_a_finite_deck_and_stays_off_the_global_ladder(
    db: AsyncSession, author: User
):
    quiz = await _published_quiz(db, author)
    run = await cq.start_solo(
        db, author, quiz.id, StartCustomQuizRequest(mode=GameMode.CASUAL)
    )
    session = await db.scalar(select(QuizSession).where(QuizSession.id == run.session.id))
    assert session is not None
    assert session.config.get("finite_deck") is True

    await quiz_service._finalize_session(db, author, session)
    result = await quiz_service.get_result(db, author, session.id)
    assert result.is_custom_quiz is True

    # The quiz's own counters moved; the global board was never told.
    refreshed = await db.scalar(select(CustomQuiz).where(CustomQuiz.id == quiz.id))
    assert refreshed.play_count == 1
    assert refreshed.player_count == 1


async def test_the_quiz_leaderboard_reports_the_run(db: AsyncSession, author: User):
    quiz = await _published_quiz(db, author)
    empty = await cq.leaderboard(db, author, quiz.id)
    assert empty.entries == [] and empty.total_players == 0

    run = await cq.start_solo(
        db, author, quiz.id, StartCustomQuizRequest(mode=GameMode.CASUAL)
    )
    session = await db.scalar(select(QuizSession).where(QuizSession.id == run.session.id))
    await quiz_service._finalize_session(db, author, session)

    board = await cq.leaderboard(db, author, quiz.id)
    assert board.total_players == 1
    assert board.entries[0].is_me is True
    assert board.entries[0].rank == 1


async def test_sharing_grants_standing_access(db: AsyncSession, author: User):
    other = await db.scalar(
        select(User)
        .options(selectinload(User.profile), selectinload(User.statistics))
        .where(User.is_active.is_(True), User.id != author.id)
        .limit(1)
    )
    if other is None:
        pytest.skip("needs a second active user")

    quiz = await _published_quiz(db, author)

    # Before redeeming, a link-visible quiz is not open to a stranger.
    assert await cq.can_play(db, other, quiz) is False

    opened = await cq.resolve_code(db, other, quiz.code)
    assert opened.id == quiz.id
    assert await cq.can_play(db, other, quiz) is True

    # And the public landing page can describe it without leaking questions.
    preview = await cq.public_preview(db, quiz.code)
    assert preview is not None
    assert preview.question_count == 3
    assert not hasattr(preview, "questions")


async def test_a_report_is_recorded_once_per_player(db: AsyncSession, author: User):
    other = await db.scalar(
        select(User)
        .options(selectinload(User.profile), selectinload(User.statistics))
        .where(User.is_active.is_(True), User.id != author.id)
        .limit(1)
    )
    if other is None:
        pytest.skip("needs a second active user")

    quiz = await _published_quiz(db, author)
    await cq.grant_access(db, quiz, other.id, source="code")
    await cq.report(db, other, quiz.id, ReportQuizRequest(reason="spam"))
    assert quiz.report_count == 1

    # A second tap from the same player is a no-op, or the auto-hide threshold
    # would count taps rather than people.
    await cq.report(db, other, quiz.id, ReportQuizRequest(reason="spam"))
    assert quiz.report_count == 1


async def test_a_room_can_be_opened_on_a_custom_quiz(db: AsyncSession, author: User):
    quiz = await _published_quiz(db, author)
    match = await cq.challenge(
        db, author, quiz.id, ChallengeWithQuizRequest(is_room=True)
    )
    assert match.topic_id == quiz.topic_id
    # Clamped to the deck: the quiz holds three, the default board wants seven.
    assert match.question_count == 3
    assert match.code
