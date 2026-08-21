"""Load an ingested paper document into the database.

Idempotent by construction. Everything is keyed on identity the pipeline
already computed -- the paper by its `key`, a question by its
`(paper_id, question_number)`, an asset by its checksum -- so re-running an
import updates in place rather than duplicating. That matters because the
normal way to fix a bad question is to correct the source and re-ingest, and an
import that duplicated on every run would make that unusable.

The questions land in the ordinary `questions` table under a hidden `topics`
row that the paper owns. This is the same trick `custom_quizzes` plays, and it
buys practice mode, the three game modes, per-paper leaderboards and anti-cheat
without any of those systems learning what an exam is.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from typing import Iterable, Optional

from sqlalchemy import delete as sa_delete, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.languages import DEFAULT_LANGUAGE, normalize_language
from app.core.logging import get_logger
from app.models import (
    AnswerType,
    DifficultyLabel,
    Exam,
    ExamPaper,
    ExamPaperStatus,
    ExamQuestion,
    ExamSection,
    Question,
    QuestionAsset,
    QuestionAssetLink,
    QuestionOption,
    QuestionStatus,
    SolutionStatus,
    Topic,
    TopicCategory,
)

logger = get_logger(__name__)

#: Papers land unpublished. Publishing is a separate, deliberate step so an
#: import can never put unreviewed questions in front of students.
DEFAULT_STATUS = ExamPaperStatus.IN_REVIEW

#: The category every exam paper's hidden topic hangs off, so the ordinary
#: catalog can filter them out with one predicate.
EXAM_CATEGORY_SLUG = "exam-papers"


@dataclass
class ImportReport:
    paper_key: str
    created: bool = False
    questions_inserted: int = 0
    questions_updated: int = 0
    questions_skipped: int = 0
    assets_inserted: int = 0
    sections: int = 0
    skipped_numbers: list[int] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def summary(self) -> str:
        return (
            f"{self.paper_key}: {'created' if self.created else 'updated'}, "
            f"{self.questions_inserted} new + {self.questions_updated} updated questions, "
            f"{self.questions_skipped} skipped, {self.assets_inserted} new assets"
        )


def _difficulty_label(value: float) -> DifficultyLabel:
    if value < 0.4:
        return DifficultyLabel.EASY
    if value < 0.65:
        return DifficultyLabel.MEDIUM
    if value < 0.85:
        return DifficultyLabel.HARD
    return DifficultyLabel.EXPERT


def _answer_type(raw: str) -> AnswerType:
    try:
        return AnswerType(raw)
    except ValueError:
        return AnswerType.SINGLE


def _solution_status(raw: str) -> SolutionStatus:
    try:
        return SolutionStatus(raw)
    except ValueError:
        return SolutionStatus.WITHHELD


def _flatten_blocks(blocks: Iterable[dict]) -> str:
    return " ".join(
        str(b.get("v", "")) for b in blocks if isinstance(b, dict) and b.get("t") == "text"
    ).strip()


async def _get_or_create_exam(db: AsyncSession, payload: dict) -> Exam:
    slug = payload["exam_slug"]
    exam = await db.scalar(select(Exam).where(Exam.slug == slug))
    if exam is None:
        exam = Exam(
            slug=slug,
            name=payload.get("exam_name") or slug.replace("-", " ").title(),
            authority=payload.get("authority"),
            icon="exam",
            is_active=True,
        )
        db.add(exam)
        await db.flush()
    return exam


async def _get_or_create_category(db: AsyncSession) -> TopicCategory:
    category = await db.scalar(
        select(TopicCategory).where(TopicCategory.slug == EXAM_CATEGORY_SLUG)
    )
    if category is None:
        category = TopicCategory(
            slug=EXAM_CATEGORY_SLUG,
            name="Exam Papers",
            description="Past-year papers, served as practice banks",
            icon="school",
            is_active=False,  # not a browsable category; papers have their own surface
            sort_order=900,
        )
        db.add(category)
        await db.flush()
    return category


async def _get_or_create_topic(db: AsyncSession, paper_payload: dict, language: str) -> Topic:
    """The hidden bank this paper owns.

    `is_custom` keeps the generation watermark from topping it up with invented
    questions, and `is_user_generated` makes gameplay treat it as a finite deck
    -- deal it once, end at the bottom, no global ladder. Both flags already
    mean exactly that; neither needed widening for exam mode.
    """
    slug = f"exam-{paper_payload['key']}"
    topic = await db.scalar(select(Topic).where(Topic.slug == slug))
    if topic is not None:
        return topic

    category = await _get_or_create_category(db)
    topic = Topic(
        category_id=category.id,
        slug=slug,
        name=paper_payload.get("title") or paper_payload["key"],
        description=f"{paper_payload.get('exam_name', '')} {paper_payload.get('year', '')}".strip(),
        icon="school",
        is_custom=True,
        is_user_generated=True,
        is_active=False,
    )
    db.add(topic)
    await db.flush()
    return topic


async def _upsert_assets(db: AsyncSession, assets: dict, urls: dict[str, dict]) -> tuple[dict, int]:
    """Insert any asset we have not seen before; return checksum -> row id."""
    if not assets:
        return {}, 0

    checksums = list(assets)
    existing = {
        row.checksum: row
        for row in (
            await db.execute(select(QuestionAsset).where(QuestionAsset.checksum.in_(checksums)))
        ).scalars()
    }

    inserted = 0
    mapping: dict[str, QuestionAsset] = dict(existing)
    for checksum, meta in assets.items():
        variants = urls.get(checksum)
        if variants is None:
            # No URL means the file was never uploaded; linking it would render
            # as a broken image, which is worse than no figure at all.
            continue
        row = existing.get(checksum)
        if row is None:
            row = QuestionAsset(
                checksum=checksum,
                kind="vector" if meta.get("source") == "vector" else "raster",
                width=int(meta.get("width") or 0),
                height=int(meta.get("height") or 0),
                variants=variants,
                total_bytes=sum(int(v.get("bytes") or 0) for v in variants.values()),
            )
            db.add(row)
            inserted += 1
            mapping[checksum] = row
        else:
            row.variants = variants
    await db.flush()
    return mapping, inserted


async def _replace_options(db: AsyncSession, question: Question, options: list[dict]) -> None:
    """Rewrite a question's options to match the document exactly.

    Deletes by statement rather than through `question.options`. Touching the
    relationship on a freshly flushed instance triggers a lazy load, and a lazy
    load inside an async session raises `MissingGreenlet` rather than doing the
    IO -- so the collection is never read here at all.
    """
    await db.execute(
        sa_delete(QuestionOption).where(QuestionOption.question_id == question.id)
    )
    for position, option in enumerate(options):
        db.add(
            QuestionOption(
                question_id=question.id,
                position=position,
                text=_flatten_blocks(option.get("blocks") or []) or f"Option {position + 1}",
            )
        )
    await db.flush()


async def _link_assets(
    db: AsyncSession,
    question: Question,
    figures: list[dict],
    asset_rows: dict[str, QuestionAsset],
) -> None:
    existing = {
        link.ref: link
        for link in (
            await db.execute(
                select(QuestionAssetLink).where(QuestionAssetLink.question_id == question.id)
            )
        ).scalars()
    }
    wanted_refs = set()
    for position, figure in enumerate(figures):
        checksum = figure.get("checksum")
        ref = figure.get("ref")
        row = asset_rows.get(checksum)
        if row is None or not ref:
            continue
        wanted_refs.add(ref)
        link = existing.get(ref)
        if link is None:
            db.add(
                QuestionAssetLink(
                    question_id=question.id,
                    asset_id=row.id,
                    ref=ref,
                    role=figure.get("role") or "figure",
                    position=position,
                )
            )
        else:
            link.asset_id = row.id
            link.position = position

    for ref, link in existing.items():
        if ref not in wanted_refs:
            await db.delete(link)


async def import_paper(
    db: AsyncSession,
    document: dict,
    *,
    asset_urls: Optional[dict[str, dict]] = None,
    publish: bool = False,
    include_blocked: bool = False,
) -> ImportReport:
    """Load one paper document. Safe to run repeatedly on the same input."""
    paper_payload = document["paper"]
    report = ImportReport(paper_key=paper_payload["key"])
    language = normalize_language(paper_payload.get("language") or DEFAULT_LANGUAGE).value

    exam = await _get_or_create_exam(db, paper_payload)
    topic = await _get_or_create_topic(db, paper_payload, language)

    paper = await db.scalar(
        select(ExamPaper).where(ExamPaper.key == paper_payload["key"])
    )
    if paper is None:
        paper = ExamPaper(exam_id=exam.id, key=paper_payload["key"], title="", year=0)
        # The first paper of an exam is free. A published paper nobody can open
        # is not really published, and the free tier needs one real full-length
        # mock per exam to be worth anything. Later papers default to premium;
        # flip `is_free` by hand to widen that.
        existing_free = await db.scalar(
            select(ExamPaper.id).where(
                ExamPaper.exam_id == exam.id, ExamPaper.is_free.is_(True)
            )
        )
        paper.is_free = existing_free is None
        db.add(paper)
        report.created = True

    held_on: Optional[date] = None
    if paper_payload.get("held_on"):
        try:
            held_on = date.fromisoformat(paper_payload["held_on"])
        except ValueError:
            report.warnings.append(f"unparseable held_on {paper_payload['held_on']!r}")

    paper.exam_id = exam.id
    paper.topic_id = topic.id
    paper.year = int(paper_payload.get("year") or 0)
    paper.session = paper_payload.get("session") or ""
    paper.shift = int(paper_payload.get("shift") or 0)
    paper.paper_code = paper_payload.get("paper_code") or ""
    paper.held_on = held_on
    paper.title = paper_payload.get("title") or _default_title(paper_payload)
    paper.duration_minutes = int(paper_payload.get("duration_minutes") or 180)
    paper.total_marks = float(paper_payload.get("total_marks") or 0)
    paper.language = language
    paper.source_pdf = paper_payload.get("source_pdf")
    paper.source_sha256 = paper_payload.get("source_sha256")
    paper.ingest_meta = document.get("stats") or {}
    if publish:
        paper.status = ExamPaperStatus.PUBLISHED
        paper.published_at = paper.published_at or datetime.now(timezone.utc)
    elif paper.status != ExamPaperStatus.PUBLISHED:
        paper.status = DEFAULT_STATUS
    await db.flush()

    # --- sections ---------------------------------------------------------
    existing_sections = list(
        (
            await db.execute(
                select(ExamSection).where(ExamSection.paper_id == paper.id)
            )
        ).scalars()
    )
    by_position = {section.position: section for section in existing_sections}
    seen_positions = set()
    section_by_name: dict[str, ExamSection] = {}
    for payload in document.get("sections") or []:
        position = int(payload["position"])
        seen_positions.add(position)
        section = by_position.get(position)
        if section is None:
            section = ExamSection(paper_id=paper.id, position=position)
            db.add(section)
        section.name = payload["name"]
        section.subject = payload.get("subject") or payload["name"]
        section.first_question = int(payload["first_question"])
        section.last_question = int(payload["last_question"])
        section.question_count = int(payload.get("question_count") or 0)
        section.answer_type = _answer_type(payload.get("answer_type") or "single")
        section.marking = payload.get("marking") or {}
        section.rules = payload.get("rules") or {}
        section_by_name[section.name] = section
    for position, section in by_position.items():
        if position not in seen_positions:
            await db.delete(section)
    await db.flush()
    report.sections = len(seen_positions)

    # --- assets -----------------------------------------------------------
    asset_rows, report.assets_inserted = await _upsert_assets(
        db, document.get("assets") or {}, asset_urls or {}
    )

    # --- questions --------------------------------------------------------
    existing_links = {
        link.question_number: link
        for link in (
            await db.execute(
                select(ExamQuestion)
                .where(ExamQuestion.paper_id == paper.id)
                .options(selectinload(ExamQuestion.question).selectinload(Question.options))
            )
        ).scalars()
    }

    live_numbers: set[int] = set()
    for payload in document.get("questions") or []:
        number = int(payload["number"])
        blocked = bool((payload.get("review") or {}).get("blocked"))
        if blocked and not include_blocked:
            report.questions_skipped += 1
            report.skipped_numbers.append(number)
            continue

        answer_type = _answer_type(payload.get("answer_type") or "single")
        options = payload.get("options") or []
        stem_blocks = payload.get("stem") or []
        stem_text = payload.get("plain_text") or _flatten_blocks(stem_blocks)

        # An answer we cannot express is a question we cannot score. Refuse it
        # here rather than shipping something that marks every student wrong.
        correct_index: Optional[int] = None
        answer_spec: dict = {}
        if answer_type is AnswerType.NUMERIC:
            spec = payload.get("answer_spec") or {}
            if spec.get("value") is None:
                report.questions_skipped += 1
                report.skipped_numbers.append(number)
                report.warnings.append(f"Q{number}: numeric question with no key value")
                continue
            answer_spec = spec
        else:
            raw = payload.get("answer")
            try:
                correct_index = int(raw) - 1
            except (TypeError, ValueError):
                report.questions_skipped += 1
                report.skipped_numbers.append(number)
                report.warnings.append(f"Q{number}: unusable answer key {raw!r}")
                continue
            if not 0 <= correct_index < len(options):
                report.questions_skipped += 1
                report.skipped_numbers.append(number)
                report.warnings.append(
                    f"Q{number}: key {raw!r} outside {len(options)} options"
                )
                continue
            answer_spec = {"option": correct_index}

        link = existing_links.get(number)
        question = link.question if link else None
        if question is None:
            question = Question(
                topic_id=topic.id,
                prompt=stem_text,
                explanation="",
                language=language,
                content_hash=payload["content_hash"],
            )
            db.add(question)
            report.questions_inserted += 1
        else:
            report.questions_updated += 1

        solution_status = _solution_status(payload.get("solution_status") or "withheld")
        difficulty = float(payload.get("difficulty") or 0.5)

        question.topic_id = topic.id
        question.prompt = stem_text
        # Only a verified solution is worth storing as the explanation shown to
        # students; the rest stay in the ingest artefact for a reviewer.
        question.explanation = (
            payload.get("solution") or ""
        ) if solution_status is SolutionStatus.VERIFIED else ""
        question.solution_status = solution_status
        question.language = language
        question.source = paper_payload.get("source_label") or paper_payload.get("source_pdf")
        question.difficulty = difficulty
        question.difficulty_label = _difficulty_label(difficulty)
        question.answer_type = answer_type
        question.answer_spec = answer_spec
        # NULL for a numeric question, which has no options. Coercing it to 0
        # would silently name option 1 as the answer, which is the exact
        # confusion the nullable column exists to prevent.
        question.correct_option_index = correct_index
        question.content = {"v": 1, "blocks": stem_blocks}
        question.option_content = [option.get("blocks") or [] for option in options]
        question.content_hash = payload["content_hash"]
        question.status = QuestionStatus.ACTIVE if publish else QuestionStatus.PENDING
        question.generation_meta = {
            "source": "exam_ingest",
            "paper_key": paper.key,
            "question_number": number,
            "chapter": payload.get("chapter"),
            "key_concept": payload.get("key_concept"),
            "solution_status": solution_status.value,
            "review": payload.get("review") or {},
        }
        await db.flush()

        await _replace_options(db, question, options)
        await _link_assets(db, question, payload.get("figures") or [], asset_rows)

        section = section_by_name.get(payload.get("section") or "")
        if link is None:
            link = ExamQuestion(paper_id=paper.id, question_number=number, question_id=question.id)
            db.add(link)
        link.question_id = question.id
        link.section_id = section.id if section else None
        link.marks = float(payload.get("marks") or 1)
        link.negative_marks = float(payload.get("negative_marks") or 0)
        link.is_dropped = bool(payload.get("is_dropped"))
        link.answer_key_raw = payload.get("answer_key_raw")
        live_numbers.add(number)
        await db.flush()

    # A question that vanished from the document (a re-ingest that now blocks
    # it) must vanish from the paper too, or the paper keeps serving a version
    # the pipeline has already rejected.
    for number, link in existing_links.items():
        if number not in live_numbers:
            await db.delete(link)

    paper.question_count = len(live_numbers)
    topic.question_count = len(live_numbers)
    topic.name = paper.title
    await db.flush()

    logger.info(
        "exam_paper_imported",
        paper=paper.key,
        inserted=report.questions_inserted,
        updated=report.questions_updated,
        skipped=report.questions_skipped,
    )
    return report


def _default_title(payload: dict) -> str:
    bits = [payload.get("exam_name") or "", str(payload.get("year") or "")]
    if payload.get("session"):
        bits.append(str(payload["session"]).title())
    if payload.get("shift"):
        bits.append(f"Shift {payload['shift']}")
    return " ".join(b for b in bits if b).strip() or payload["key"]
