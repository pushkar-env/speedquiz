"""Question teach / report endpoints (outside the gameplay answer path)."""

from uuid import UUID

from fastapi import APIRouter

from app.auth.deps import CurrentUser, DbSession
from app.schemas.questions import QuestionReportRequest, TeachMeRequest, TeachMeResponse
from app.services import questions_extra

router = APIRouter(prefix="/questions", tags=["questions"])


@router.post("/{question_id}/teach", response_model=TeachMeResponse)
async def teach_me(
    question_id: UUID,
    user: CurrentUser,
    db: DbSession,
    payload: TeachMeRequest | None = None,
) -> TeachMeResponse:
    body = payload or TeachMeRequest()
    return await questions_extra.teach_question(
        db,
        user,
        question_id,
        user_option_text=body.user_option_text,
    )


@router.post("/{question_id}/report")
async def report_question(
    question_id: UUID,
    payload: QuestionReportRequest,
    user: CurrentUser,
    db: DbSession,
) -> dict:
    return await questions_extra.report_question(db, user, question_id, payload)
