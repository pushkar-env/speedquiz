"""Exam mode: the catalog, and the lifecycle of a mock-test attempt.

The write path is the thing that has to survive scale here. A three-hour paper
with ninety questions, a candidate who revisits half of them, and a naive
PATCH-per-tap is hundreds of writes per attempt. So the client owns the answer
sheet for the duration of the test and the server is a checkpoint: deltas
arrive in batches every twenty or thirty seconds, and each batch is one bulk
upsert keyed on `(attempt_id, exam_question_id)`. Retries are free because that
is idempotent, and a tunnel costs nothing because the sheet is on the device.

The clock is server-anchored and client-rendered. `server_deadline_at` is
stamped once at start; every sync returns the authoritative remainder and the
client reconciles. Client-reported elapsed time never reaches the scoring path.
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.logging import get_logger
from app.models import (
    AttemptMode,
    AttemptStatus,
    Exam,
    ExamPaper,
    ExamPaperStatus,
    ExamQuestion,
    ExamSection,
    MockTestAttempt,
    MockTestResponse,
    Question,
    QuestionAsset,
    QuestionAssetLink,
    ResponseState,
    SolutionStatus,
    User,
)
from app.schemas.exams import (
    AssetOut,
    AttemptOut,
    AttemptResultOut,
    ExamOut,
    PaperManifestOut,
    PaperQuestionOut,
    PaperSummaryOut,
    QuestionResultOut,
    ResponseIn,
    SectionOut,
)
from app.services import exam_scoring

logger = get_logger(__name__)

#: Grace on the deadline, to cover a sync that was in flight when the clock ran
#: out. Shorter than any question is worth answering, long enough that a slow
#: network does not cost a candidate their last answer.
SUBMIT_GRACE = timedelta(seconds=30)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _aware(value: datetime) -> datetime:
    """Postgres hands back naive datetimes on some drivers; normalise."""
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def _err(code: str, message: str, http_status: int = status.HTTP_400_BAD_REQUEST) -> HTTPException:
    return HTTPException(status_code=http_status, detail={"code": code, "message": message})


# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------


async def list_exams(db: AsyncSession) -> list[ExamOut]:
    counts = dict(
        (row[0], row[1])
        for row in (
            await db.execute(
                select(ExamPaper.exam_id, func.count(ExamPaper.id))
                .where(ExamPaper.status == ExamPaperStatus.PUBLISHED)
                .group_by(ExamPaper.exam_id)
            )
        ).all()
    )
    exams = (
        await db.execute(
            select(Exam).where(Exam.is_active.is_(True)).order_by(Exam.sort_order, Exam.name)
        )
    ).scalars().all()
    return [
        ExamOut(
            id=exam.id, slug=exam.slug, name=exam.name,
            authority=exam.authority, icon=exam.icon,
            paper_count=counts.get(exam.id, 0),
        )
        for exam in exams
    ]


def _paper_summary(paper: ExamPaper, *, locked: bool) -> PaperSummaryOut:
    return PaperSummaryOut(
        id=paper.id, key=paper.key, title=paper.title, year=paper.year,
        session=paper.session, shift=paper.shift, held_on=paper.held_on,
        duration_minutes=paper.duration_minutes, total_marks=paper.total_marks,
        question_count=paper.question_count, is_free=paper.is_free,
        is_locked=locked, attempt_count=paper.attempt_count,
    )


def _is_locked(paper: ExamPaper, user: Optional[User]) -> bool:
    if paper.is_free:
        return False
    return not (user and user.is_premium)


async def list_papers(db: AsyncSession, user: User, exam_slug: str) -> list[PaperSummaryOut]:
    exam = await db.scalar(select(Exam).where(Exam.slug == exam_slug))
    if exam is None:
        raise _err("exam_not_found", "No such exam.", status.HTTP_404_NOT_FOUND)

    papers = (
        await db.execute(
            select(ExamPaper)
            .where(
                ExamPaper.exam_id == exam.id,
                ExamPaper.status == ExamPaperStatus.PUBLISHED,
            )
            .order_by(ExamPaper.year.desc(), ExamPaper.session, ExamPaper.shift)
        )
    ).scalars().all()
    if not papers:
        return []

    # One query for the caller's history across every paper on the page,
    # rather than one per row.
    history = (
        await db.execute(
            select(
                MockTestAttempt.paper_id,
                func.max(MockTestAttempt.score),
                func.max(MockTestAttempt.created_at),
            )
            .where(
                MockTestAttempt.user_id == user.id,
                MockTestAttempt.paper_id.in_([p.id for p in papers]),
            )
            .group_by(MockTestAttempt.paper_id)
        )
    ).all()
    best = {row[0]: row[1] for row in history}

    live = {
        row.paper_id: row
        for row in (
            await db.execute(
                select(MockTestAttempt).where(
                    MockTestAttempt.user_id == user.id,
                    MockTestAttempt.paper_id.in_([p.id for p in papers]),
                    MockTestAttempt.status == AttemptStatus.IN_PROGRESS,
                )
            )
        ).scalars()
    }

    out: list[PaperSummaryOut] = []
    for paper in papers:
        summary = _paper_summary(paper, locked=_is_locked(paper, user))
        summary.best_score = best.get(paper.id)
        attempt = live.get(paper.id)
        if attempt:
            summary.last_attempt_id = attempt.id
            summary.last_attempt_status = attempt.status.value
        out.append(summary)
    return out


async def _load_paper(db: AsyncSession, paper_id: UUID) -> ExamPaper:
    paper = await db.scalar(
        select(ExamPaper)
        .where(ExamPaper.id == paper_id)
        .options(selectinload(ExamPaper.sections))
    )
    if paper is None or paper.status != ExamPaperStatus.PUBLISHED:
        raise _err("paper_not_found", "No such paper.", status.HTTP_404_NOT_FOUND)
    return paper


async def get_manifest(db: AsyncSession, user: User, paper_id: UUID) -> PaperManifestOut:
    """The whole paper, minus the answers.

    Identical for every user, which is what lets it be cached at the edge and
    downloaded once before the clock starts.
    """
    paper = await _load_paper(db, paper_id)
    if _is_locked(paper, user):
        raise _err("premium_required", "This paper needs Premium.", status.HTTP_402_PAYMENT_REQUIRED)

    exam = await db.get(Exam, paper.exam_id)
    links = (
        await db.execute(
            select(ExamQuestion)
            .where(ExamQuestion.paper_id == paper.id)
            .options(
                selectinload(ExamQuestion.question).selectinload(Question.options),
            )
            .order_by(ExamQuestion.question_number)
        )
    ).scalars().all()

    question_ids = [link.question_id for link in links]
    asset_links = (
        await db.execute(
            select(QuestionAssetLink)
            .where(QuestionAssetLink.question_id.in_(question_ids))
            .options(selectinload(QuestionAssetLink.asset))
        )
    ).scalars().all() if question_ids else []

    by_question: dict[UUID, dict[str, str]] = {}
    assets: dict[str, QuestionAsset] = {}
    for link in asset_links:
        if link.asset is None:
            continue
        by_question.setdefault(link.question_id, {})[link.ref] = link.asset.checksum
        assets[link.asset.checksum] = link.asset

    questions: list[PaperQuestionOut] = []
    for link in links:
        question = link.question
        if question is None:
            continue
        content = question.content or {}
        questions.append(
            PaperQuestionOut(
                id=link.id,
                number=link.question_number,
                section_id=link.section_id,
                answer_type=question.answer_type.value,
                marks=link.marks,
                negative_marks=link.negative_marks,
                stem=content.get("blocks") or [{"t": "text", "v": question.prompt}],
                options=question.option_content or [],
                option_text=[option.text for option in question.options],
                unit=(question.answer_spec or {}).get("unit"),
                figures=by_question.get(question.id, {}),
            )
        )

    asset_out = [
        AssetOut(
            checksum=asset.checksum, width=asset.width, height=asset.height,
            alt_text=asset.alt_text, variants=asset.variants or {},
        )
        for asset in assets.values()
    ]

    # A cheap, stable content fingerprint. The payload only changes when the
    # paper is re-imported, so this is a real cache key rather than a token.
    digest = hashlib.sha256(
        f"{paper.key}:{paper.updated_at}:{len(questions)}:{len(asset_out)}".encode()
    ).hexdigest()[:32]

    return PaperManifestOut(
        paper=_paper_summary(paper, locked=False),
        exam=ExamOut(
            id=exam.id, slug=exam.slug, name=exam.name,
            authority=exam.authority, icon=exam.icon,
        ),
        sections=[
            SectionOut(
                id=s.id, name=s.name, subject=s.subject, position=s.position,
                first_question=s.first_question, last_question=s.last_question,
                question_count=s.question_count, answer_type=s.answer_type.value,
                marking=s.marking or {}, rules=s.rules or {},
            )
            for s in sorted(paper.sections, key=lambda s: s.position)
        ],
        questions=questions,
        assets=asset_out,
        total_asset_bytes=sum(a.total_bytes for a in assets.values()),
        etag=digest,
    )


# ---------------------------------------------------------------------------
# Attempts
# ---------------------------------------------------------------------------


def _remaining_ms(attempt: MockTestAttempt, now: Optional[datetime] = None) -> int:
    now = now or _now()
    delta = _aware(attempt.server_deadline_at) - now
    return max(0, int(delta.total_seconds() * 1000))


def _attempt_out(attempt: MockTestAttempt, responses: list[MockTestResponse]) -> AttemptOut:
    now = _now()
    return AttemptOut(
        id=attempt.id,
        paper_id=attempt.paper_id,
        mode=attempt.mode.value,
        status=attempt.status.value,
        started_at=_aware(attempt.started_at),
        server_deadline_at=_aware(attempt.server_deadline_at),
        remaining_ms=_remaining_ms(attempt, now),
        server_now=now,
        submitted_at=_aware(attempt.submitted_at) if attempt.submitted_at else None,
        responses=[
            {
                "exam_question_id": str(r.exam_question_id),
                "state": r.state.value,
                "selected": r.selected or [],
                "numeric_value": r.numeric_value,
                "numeric_raw": r.numeric_raw,
                "time_spent_ms": r.time_spent_ms,
                "visit_count": r.visit_count,
                "client_revision": r.client_revision,
            }
            for r in responses
        ],
    )


async def start_attempt(
    db: AsyncSession, user: User, paper_id: UUID, *, mode: str, section_id: Optional[UUID]
) -> AttemptOut:
    paper = await _load_paper(db, paper_id)
    if _is_locked(paper, user):
        raise _err("premium_required", "This paper needs Premium.", status.HTTP_402_PAYMENT_REQUIRED)

    # Resume rather than start a second clock. Two live attempts on one paper
    # would let a candidate reroll a bad start, and the first one's timer keeps
    # running regardless.
    existing = await db.scalar(
        select(MockTestAttempt).where(
            MockTestAttempt.user_id == user.id,
            MockTestAttempt.paper_id == paper.id,
            MockTestAttempt.status == AttemptStatus.IN_PROGRESS,
        )
    )
    if existing is not None:
        if _remaining_ms(existing) > 0:
            return await get_attempt(db, user, existing.id)
        await _finalize(db, existing, auto=True)
        await db.flush()

    duration = paper.duration_minutes
    if mode == "sectional" and section_id:
        section = await db.get(ExamSection, section_id)
        if section is None or section.paper_id != paper.id:
            raise _err("section_not_found", "No such section on this paper.", status.HTTP_404_NOT_FOUND)
        duration = section.time_limit_minutes or max(
            1, round(paper.duration_minutes * section.question_count / max(1, paper.question_count))
        )

    now = _now()
    attempt = MockTestAttempt(
        user_id=user.id,
        paper_id=paper.id,
        mode=AttemptMode(mode),
        section_id=section_id if mode == "sectional" else None,
        status=AttemptStatus.IN_PROGRESS,
        started_at=now,
        server_deadline_at=now + timedelta(minutes=duration),
        max_score=paper.total_marks,
    )
    db.add(attempt)
    paper.attempt_count += 1
    await db.flush()

    logger.info("mock_attempt_started", attempt=str(attempt.id), paper=paper.key, mode=mode)
    return _attempt_out(attempt, [])


async def _load_attempt(db: AsyncSession, user: User, attempt_id: UUID) -> MockTestAttempt:
    attempt = await db.get(MockTestAttempt, attempt_id)
    if attempt is None or attempt.user_id != user.id:
        raise _err("attempt_not_found", "No such attempt.", status.HTTP_404_NOT_FOUND)
    return attempt


async def _responses_for(db: AsyncSession, attempt_id: UUID) -> list[MockTestResponse]:
    return list(
        (
            await db.execute(
                select(MockTestResponse).where(MockTestResponse.attempt_id == attempt_id)
            )
        ).scalars()
    )


async def get_attempt(db: AsyncSession, user: User, attempt_id: UUID) -> AttemptOut:
    attempt = await _load_attempt(db, user, attempt_id)
    # Lazy auto-submit: an attempt whose app was killed at 2h58m still scores,
    # the next time anyone looks at it.
    if attempt.status == AttemptStatus.IN_PROGRESS and _remaining_ms(attempt) <= 0:
        await _finalize(db, attempt, auto=True)
        await db.flush()
    return _attempt_out(attempt, await _responses_for(db, attempt_id))


async def sync_responses(
    db: AsyncSession, user: User, attempt_id: UUID, responses: list[ResponseIn]
) -> dict:
    """Apply a delta batch. One statement, idempotent, last-write-wins."""
    attempt = await _load_attempt(db, user, attempt_id)
    now = _now()

    if attempt.status != AttemptStatus.IN_PROGRESS:
        return {
            "accepted": 0, "rejected": len(responses),
            "remaining_ms": 0, "server_now": now, "status": attempt.status.value,
        }

    # Past the deadline the sheet is closed, but the sync still succeeds so the
    # client can learn the attempt is over instead of retrying into an error.
    if _aware(attempt.server_deadline_at) + SUBMIT_GRACE < now:
        await _finalize(db, attempt, auto=True)
        await db.flush()
        return {
            "accepted": 0, "rejected": len(responses),
            "remaining_ms": 0, "server_now": now, "status": attempt.status.value,
        }

    if not responses:
        return {
            "accepted": 0, "rejected": 0,
            "remaining_ms": _remaining_ms(attempt, now),
            "server_now": now, "status": attempt.status.value,
        }

    valid_ids = {
        row
        for row in (
            await db.execute(
                select(ExamQuestion.id).where(
                    ExamQuestion.paper_id == attempt.paper_id,
                    ExamQuestion.id.in_([r.exam_question_id for r in responses]),
                )
            )
        ).scalars()
    }

    rows = []
    rejected = 0
    for item in responses:
        if item.exam_question_id not in valid_ids:
            rejected += 1
            continue
        try:
            state = ResponseState(item.state)
        except ValueError:
            state = ResponseState.NOT_VISITED
        rows.append({
            "attempt_id": attempt.id,
            "exam_question_id": item.exam_question_id,
            "state": state,
            "selected": [int(i) for i in item.selected][:8],
            "numeric_value": item.numeric_value,
            "numeric_raw": item.numeric_raw,
            "time_spent_ms": max(0, item.time_spent_ms),
            "visit_count": max(0, item.visit_count),
            "client_revision": max(0, item.client_revision),
            "first_seen_at": now,
            "last_updated_at": now,
        })

    if rows:
        statement = pg_insert(MockTestResponse).values(rows)
        # Last-write-wins on the client's monotonic revision. A retry that
        # arrives late carries an older revision and is ignored, so a flaky
        # network cannot resurrect an answer the candidate already changed.
        statement = statement.on_conflict_do_update(
            index_elements=[
                MockTestResponse.attempt_id, MockTestResponse.exam_question_id
            ],
            set_={
                "state": statement.excluded.state,
                "selected": statement.excluded.selected,
                "numeric_value": statement.excluded.numeric_value,
                "numeric_raw": statement.excluded.numeric_raw,
                "time_spent_ms": statement.excluded.time_spent_ms,
                "visit_count": statement.excluded.visit_count,
                "client_revision": statement.excluded.client_revision,
                "last_updated_at": statement.excluded.last_updated_at,
            },
            where=MockTestResponse.client_revision <= statement.excluded.client_revision,
        )
        await db.execute(statement)

        highest = max(r["client_revision"] for r in rows)
        attempt.last_sync_revision = max(attempt.last_sync_revision, highest)

    await db.flush()
    return {
        "accepted": len(rows), "rejected": rejected,
        "remaining_ms": _remaining_ms(attempt, now),
        "server_now": now, "status": attempt.status.value,
    }


async def _finalize(db: AsyncSession, attempt: MockTestAttempt, *, auto: bool) -> None:
    """Score the attempt and freeze it. Safe to call more than once."""
    if attempt.status in {AttemptStatus.SUBMITTED, AttemptStatus.AUTO_SUBMITTED}:
        return

    links = (
        await db.execute(
            select(ExamQuestion)
            .where(ExamQuestion.paper_id == attempt.paper_id)
            .options(selectinload(ExamQuestion.question))
            .order_by(ExamQuestion.question_number)
        )
    ).scalars().all()
    sections = (
        await db.execute(select(ExamSection).where(ExamSection.paper_id == attempt.paper_id))
    ).scalars().all()
    responses = await _responses_for(db, attempt.id)

    section_map = {
        str(s.id): {"name": s.name, "marking": s.marking or {}, "rules": s.rules or {}}
        for s in sections
    }
    question_payload = []
    for link in links:
        question = link.question
        question_payload.append({
            "id": str(link.id),
            "section_id": str(link.section_id) if link.section_id else None,
            "answer_type": question.answer_type.value if question else "single",
            "answer_spec": (question.answer_spec or {}) if question else {},
            "accepted_answers": link.accepted_answers or [],
            "is_dropped": link.is_dropped,
            "marks": link.marks,
            "negative_marks": link.negative_marks,
        })
    response_payload = {
        str(r.exam_question_id): {
            "selected": r.selected or [],
            "numeric_value": r.numeric_value,
        }
        for r in responses
    }

    result = exam_scoring.score_attempt(
        questions=question_payload,
        responses=response_payload,
        sections=section_map,
    )

    graded = {item.exam_question_id: item for item in result.per_question}
    for response in responses:
        item = graded.get(str(response.exam_question_id))
        if item is None:
            continue
        response.is_correct = item.is_correct
        response.marks_awarded = item.marks
        response.counted = item.counted

    attempt.score = result.score
    attempt.max_score = result.max_score
    attempt.correct_count = result.correct
    attempt.incorrect_count = result.incorrect
    attempt.unattempted_count = result.unattempted
    attempt.section_scores = {
        key: summary.as_dict() for key, summary in result.per_section.items()
    }
    attempt.total_time_ms = sum(r.time_spent_ms for r in responses)
    attempt.status = AttemptStatus.AUTO_SUBMITTED if auto else AttemptStatus.SUBMITTED
    attempt.submitted_at = _now()

    logger.info(
        "mock_attempt_finalized",
        attempt=str(attempt.id), score=attempt.score, auto=auto,
    )


async def submit_attempt(db: AsyncSession, user: User, attempt_id: UUID) -> AttemptResultOut:
    attempt = await _load_attempt(db, user, attempt_id)
    await _finalize(db, attempt, auto=False)
    await db.flush()
    return await get_result(db, user, attempt_id)


async def get_result(db: AsyncSession, user: User, attempt_id: UUID) -> AttemptResultOut:
    attempt = await _load_attempt(db, user, attempt_id)
    if attempt.status == AttemptStatus.IN_PROGRESS:
        raise _err("attempt_in_progress", "Submit the attempt first.", status.HTTP_409_CONFLICT)

    links = {
        link.id: link
        for link in (
            await db.execute(
                select(ExamQuestion)
                .where(ExamQuestion.paper_id == attempt.paper_id)
                .options(selectinload(ExamQuestion.question))
            )
        ).scalars()
    }
    responses = {r.exam_question_id: r for r in await _responses_for(db, attempt.id)}

    questions: list[QuestionResultOut] = []
    chapters: dict[str, dict] = {}
    for link in sorted(links.values(), key=lambda link: link.question_number):
        question = link.question
        response = responses.get(link.id)
        meta = (question.generation_meta or {}) if question else {}
        chapter = meta.get("chapter") or "Unclassified"

        spec = (question.answer_spec or {}) if question else {}
        # A solution that did not pass verification is withheld -- the reason
        # it exists is that a wrong method with a right answer teaches the
        # wrong thing.
        solution = ""
        if question and question.solution_status is SolutionStatus.VERIFIED:
            solution = question.explanation or ""

        questions.append(
            QuestionResultOut(
                exam_question_id=link.id,
                number=link.question_number,
                section_id=link.section_id,
                is_correct=response.is_correct if response else None,
                marks_awarded=float(response.marks_awarded or 0) if response else 0.0,
                counted=response.counted if response else True,
                time_spent_ms=response.time_spent_ms if response else 0,
                correct_option_index=spec.get("option"),
                correct_value=spec.get("value"),
                selected=(response.selected or []) if response else [],
                numeric_value=response.numeric_value if response else None,
                solution=solution,
                chapter=chapter,
            )
        )

        bucket = chapters.setdefault(chapter, {"correct": 0, "total": 0, "marks": 0.0})
        bucket["total"] += 1
        if response and response.is_correct:
            bucket["correct"] += 1
        if response and response.marks_awarded:
            bucket["marks"] += float(response.marks_awarded)

    # Percentile against everyone who has finished this paper. Cheap enough as
    # a query at this size; a Redis sorted set is the move once a paper carries
    # a large number of attempts.
    total_attempts = await db.scalar(
        select(func.count(MockTestAttempt.id)).where(
            MockTestAttempt.paper_id == attempt.paper_id,
            MockTestAttempt.status.in_(
                [AttemptStatus.SUBMITTED, AttemptStatus.AUTO_SUBMITTED]
            ),
        )
    ) or 0
    percentile = None
    rank = None
    if total_attempts > 1:
        below = await db.scalar(
            select(func.count(MockTestAttempt.id)).where(
                MockTestAttempt.paper_id == attempt.paper_id,
                MockTestAttempt.status.in_(
                    [AttemptStatus.SUBMITTED, AttemptStatus.AUTO_SUBMITTED]
                ),
                MockTestAttempt.score < attempt.score,
            )
        ) or 0
        percentile = round(100.0 * below / total_attempts, 2)
        rank = total_attempts - below
        attempt.percentile = percentile

    return AttemptResultOut(
        attempt=_attempt_out(attempt, list(responses.values())),
        score=attempt.score,
        max_score=attempt.max_score,
        correct=attempt.correct_count,
        incorrect=attempt.incorrect_count,
        unattempted=attempt.unattempted_count,
        percentile=percentile,
        rank=rank,
        total_attempts=total_attempts,
        sections=attempt.section_scores or {},
        questions=questions,
        chapters=chapters,
    )
