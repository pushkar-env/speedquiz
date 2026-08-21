"""Exam mode endpoints: browse papers, run a mock test, read the result."""

from uuid import UUID

from fastapi import APIRouter, Response, status

from app.auth.deps import CurrentUser, DbSession
from app.schemas.exams import (
    AttemptOut,
    AttemptResultOut,
    ExamOut,
    PaperManifestOut,
    PaperSummaryOut,
    StartAttemptRequest,
    SyncResponsesOut,
    SyncResponsesRequest,
)
from app.services import exam_service

router = APIRouter(prefix="/exams", tags=["exams"])


@router.get("", response_model=list[ExamOut])
async def list_exams(user: CurrentUser, db: DbSession) -> list[ExamOut]:
    return await exam_service.list_exams(db)


@router.get("/{exam_slug}/papers", response_model=list[PaperSummaryOut])
async def list_papers(exam_slug: str, user: CurrentUser, db: DbSession) -> list[PaperSummaryOut]:
    return await exam_service.list_papers(db, user, exam_slug)


@router.get("/papers/{paper_id}/manifest", response_model=PaperManifestOut)
async def get_manifest(
    paper_id: UUID, user: CurrentUser, db: DbSession, response: Response
) -> PaperManifestOut:
    """Everything needed to run the paper, downloaded before the clock starts.

    The payload carries no answers and is byte-identical for every user, so it
    is safe to cache hard. That is what keeps a spike on one popular paper from
    reaching the database at all.
    """
    manifest = await exam_service.get_manifest(db, user, paper_id)
    response.headers["ETag"] = f'"{manifest.etag}"'
    response.headers["Cache-Control"] = "private, max-age=3600"
    return manifest


@router.post(
    "/papers/{paper_id}/attempts",
    response_model=AttemptOut,
    status_code=status.HTTP_201_CREATED,
)
async def start_attempt(
    paper_id: UUID, payload: StartAttemptRequest, user: CurrentUser, db: DbSession
) -> AttemptOut:
    return await exam_service.start_attempt(
        db, user, paper_id, mode=payload.mode, section_id=payload.section_id
    )


@router.get("/attempts/{attempt_id}", response_model=AttemptOut)
async def get_attempt(attempt_id: UUID, user: CurrentUser, db: DbSession) -> AttemptOut:
    return await exam_service.get_attempt(db, user, attempt_id)


@router.put("/attempts/{attempt_id}/responses", response_model=SyncResponsesOut)
async def sync_responses(
    attempt_id: UUID, payload: SyncResponsesRequest, user: CurrentUser, db: DbSession
) -> SyncResponsesOut:
    """Apply a delta batch of answers.

    Idempotent, so the client can retry freely: each row is upserted on
    `(attempt, question)` and only overwrites state carrying an older revision.
    """
    result = await exam_service.sync_responses(db, user, attempt_id, payload.responses)
    return SyncResponsesOut(**result)


@router.post("/attempts/{attempt_id}/submit", response_model=AttemptResultOut)
async def submit_attempt(
    attempt_id: UUID, user: CurrentUser, db: DbSession
) -> AttemptResultOut:
    return await exam_service.submit_attempt(db, user, attempt_id)


@router.get("/attempts/{attempt_id}/result", response_model=AttemptResultOut)
async def get_result(attempt_id: UUID, user: CurrentUser, db: DbSession) -> AttemptResultOut:
    return await exam_service.get_result(db, user, attempt_id)
