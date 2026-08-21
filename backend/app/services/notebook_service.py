"""The mistake notebook.

Every question a student gets wrong lands here automatically, deduped per
question and grouped by chapter. It is the single most-used surface in serious
exam-prep apps for a simple reason: after a mock test, the score tells you how
you did and the notebook tells you what to do next.

Entries are written at submission (see `exam_service._finalize`) rather than
derived on read, and they are keyed on (user, question) — the same question
failed in three papers is one thing to revise, not three.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.logging import get_logger
from app.models import (
    ExamPaper,
    ExamQuestion,
    NotebookEntry,
    NotebookStatus,
    Question,
    QuestionAsset,
    QuestionAssetLink,
    SolutionStatus,
    User,
)

logger = get_logger(__name__)


def _now() -> datetime:
    return datetime.now(timezone.utc)


async def record_mistakes(
    db: AsyncSession,
    *,
    user_id: UUID,
    wrong: list[dict],
) -> int:
    """Upsert notebook entries for the questions failed in one attempt.

    `wrong` carries one dict per failed question with keys: question_id,
    exam_question_id, chapter, subject, selected, numeric_value.

    A question already in the notebook has its counter bumped rather than a
    second row created, and a `reviewed` entry reopens — getting it wrong again
    means the review did not take.
    """
    if not wrong:
        return 0

    now = _now()
    rows = [
        {
            "user_id": user_id,
            "question_id": item["question_id"],
            "exam_question_id": item.get("exam_question_id"),
            "chapter": (item.get("chapter") or "Unclassified")[:120],
            "subject": (item.get("subject") or "")[:80],
            "status": NotebookStatus.OPEN,
            "wrong_count": 1,
            "first_wrong_at": now,
            "last_wrong_at": now,
            "last_selected": item.get("selected") or [],
            "last_numeric": item.get("numeric_value"),
        }
        for item in wrong
    ]

    statement = pg_insert(NotebookEntry).values(rows)
    statement = statement.on_conflict_do_update(
        constraint="uq_notebook_user_question",
        set_={
            "wrong_count": NotebookEntry.wrong_count + 1,
            "last_wrong_at": statement.excluded.last_wrong_at,
            "last_selected": statement.excluded.last_selected,
            "last_numeric": statement.excluded.last_numeric,
            "exam_question_id": statement.excluded.exam_question_id,
            "chapter": statement.excluded.chapter,
            "subject": statement.excluded.subject,
            # Wrong again means the earlier review did not stick.
            "status": NotebookStatus.OPEN,
            "reviewed_at": None,
        },
    )
    await db.execute(statement)
    return len(rows)


async def mark_recovered(
    db: AsyncSession, *, user_id: UUID, question_ids: list[UUID]
) -> int:
    """Flip entries to `recovered` for questions just answered correctly.

    Only entries currently open move: a question the student had already read
    up on and marked reviewed stays reviewed, because getting it right
    afterwards is the expected outcome rather than news.
    """
    if not question_ids:
        return 0

    entries = (
        await db.execute(
            select(NotebookEntry).where(
                NotebookEntry.user_id == user_id,
                NotebookEntry.question_id.in_(question_ids),
                NotebookEntry.status == NotebookStatus.OPEN,
            )
        )
    ).scalars().all()
    for entry in entries:
        entry.status = NotebookStatus.RECOVERED
    return len(entries)


async def list_entries(
    db: AsyncSession,
    user: User,
    *,
    status_filter: Optional[str] = None,
    chapter: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
) -> dict:
    """The notebook, newest mistake first."""
    conditions = [NotebookEntry.user_id == user.id]
    if status_filter and status_filter != "all":
        try:
            conditions.append(NotebookEntry.status == NotebookStatus(status_filter))
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail={"code": "bad_status", "message": "Unknown status filter."},
            ) from None
    if chapter:
        conditions.append(NotebookEntry.chapter == chapter)

    total = await db.scalar(
        select(func.count(NotebookEntry.id)).where(*conditions)
    ) or 0

    entries = (
        await db.execute(
            select(NotebookEntry)
            .where(*conditions)
            .order_by(NotebookEntry.last_wrong_at.desc())
            .limit(min(limit, 100))
            .offset(max(0, offset))
        )
    ).scalars().all()

    question_ids = [entry.question_id for entry in entries]
    questions: dict[UUID, Question] = {}
    if question_ids:
        questions = {
            q.id: q
            for q in (
                await db.execute(
                    select(Question)
                    .where(Question.id.in_(question_ids))
                    .options(selectinload(Question.options))
                )
            ).scalars()
        }

    # Figures, so a diagram question is revisable rather than a wall of text.
    asset_links = (
        await db.execute(
            select(QuestionAssetLink)
            .where(QuestionAssetLink.question_id.in_(question_ids))
            .options(selectinload(QuestionAssetLink.asset))
        )
    ).scalars().all() if question_ids else []
    figures: dict[UUID, dict[str, str]] = {}
    assets: dict[str, QuestionAsset] = {}
    for link in asset_links:
        if link.asset is None:
            continue
        figures.setdefault(link.question_id, {})[link.ref] = link.asset.checksum
        assets[link.asset.checksum] = link.asset

    # Which paper each mistake came from.
    exam_question_ids = [e.exam_question_id for e in entries if e.exam_question_id]
    paper_titles: dict[UUID, str] = {}
    if exam_question_ids:
        rows = (
            await db.execute(
                select(ExamQuestion.id, ExamQuestion.question_number, ExamPaper.title)
                .join(ExamPaper, ExamPaper.id == ExamQuestion.paper_id)
                .where(ExamQuestion.id.in_(exam_question_ids))
            )
        ).all()
        paper_titles = {row[0]: f"{row[2]} · Q{row[1]}" for row in rows}

    items = []
    for entry in entries:
        question = questions.get(entry.question_id)
        if question is None:
            continue
        content = question.content or {}
        solution = (
            question.explanation or ""
            if question.solution_status is SolutionStatus.VERIFIED
            else ""
        )
        items.append({
            "id": str(entry.id),
            "question_id": str(entry.question_id),
            "chapter": entry.chapter or "Unclassified",
            "subject": entry.subject,
            "status": entry.status.value,
            "wrong_count": entry.wrong_count,
            "last_wrong_at": entry.last_wrong_at,
            "source": paper_titles.get(entry.exam_question_id) if entry.exam_question_id else None,
            "answer_type": question.answer_type.value,
            "stem": content.get("blocks") or [{"t": "text", "v": question.prompt}],
            "options": question.option_content or [],
            "option_text": [option.text for option in question.options],
            "figures": figures.get(entry.question_id, {}),
            "correct_option_index": (question.answer_spec or {}).get("option"),
            "correct_value": (question.answer_spec or {}).get("value"),
            "your_selected": entry.last_selected or [],
            "your_numeric": entry.last_numeric,
            "solution": solution,
        })

    # Chapter counts across the whole notebook, not just this page — the
    # filter chips have to show the real totals.
    chapter_rows = (
        await db.execute(
            select(NotebookEntry.chapter, func.count(NotebookEntry.id))
            .where(
                NotebookEntry.user_id == user.id,
                NotebookEntry.status == NotebookStatus.OPEN,
            )
            .group_by(NotebookEntry.chapter)
            .order_by(func.count(NotebookEntry.id).desc())
        )
    ).all()

    open_count = await db.scalar(
        select(func.count(NotebookEntry.id)).where(
            NotebookEntry.user_id == user.id,
            NotebookEntry.status == NotebookStatus.OPEN,
        )
    ) or 0

    return {
        "total": total,
        "open_count": open_count,
        "items": items,
        "assets": [
            {
                "checksum": a.checksum,
                "width": a.width,
                "height": a.height,
                "alt_text": a.alt_text,
                "variants": a.variants or {},
            }
            for a in assets.values()
        ],
        "chapters": [{"name": name or "Unclassified", "count": count} for name, count in chapter_rows],
    }


async def set_status(
    db: AsyncSession, user: User, entry_id: UUID, new_status: str
) -> dict:
    entry = await db.get(NotebookEntry, entry_id)
    if entry is None or entry.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "entry_not_found", "message": "No such notebook entry."},
        )
    try:
        parsed = NotebookStatus(new_status)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "bad_status", "message": "Unknown status."},
        ) from None

    entry.status = parsed
    entry.reviewed_at = _now() if parsed is NotebookStatus.REVIEWED else None
    await db.flush()
    return {"id": str(entry.id), "status": entry.status.value}


async def delete_entry(db: AsyncSession, user: User, entry_id: UUID) -> None:
    entry = await db.get(NotebookEntry, entry_id)
    if entry is None or entry.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "entry_not_found", "message": "No such notebook entry."},
        )
    await db.delete(entry)
