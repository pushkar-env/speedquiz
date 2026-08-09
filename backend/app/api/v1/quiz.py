from uuid import UUID

from fastapi import APIRouter, status

from app.auth.deps import CurrentUser, DbSession
from app.schemas.quiz import (
    AnswerFeedbackOut,
    CreateQuizSessionRequest,
    QuizResultOut,
    QuizSessionOut,
    SubmitAnswerRequest,
)
from app.services import quiz_service

router = APIRouter(prefix="/quiz", tags=["quiz"])


@router.post("/sessions", response_model=QuizSessionOut, status_code=status.HTTP_201_CREATED)
async def create_quiz_session(
    payload: CreateQuizSessionRequest,
    user: CurrentUser,
    db: DbSession,
) -> QuizSessionOut:
    return await quiz_service.create_session(db, user, payload)


@router.get("/sessions/{session_id}", response_model=QuizSessionOut)
async def get_quiz_session(
    session_id: UUID,
    user: CurrentUser,
    db: DbSession,
) -> QuizSessionOut:
    return await quiz_service.get_session(db, user, session_id)


@router.post("/sessions/{session_id}/answer", response_model=AnswerFeedbackOut)
async def answer_quiz_question(
    session_id: UUID,
    payload: SubmitAnswerRequest,
    user: CurrentUser,
    db: DbSession,
) -> AnswerFeedbackOut:
    return await quiz_service.submit_answer(db, user, session_id, payload)


@router.post("/sessions/{session_id}/finish", response_model=QuizResultOut)
async def finish_quiz_session(
    session_id: UUID,
    user: CurrentUser,
    db: DbSession,
) -> QuizResultOut:
    return await quiz_service.finish_session(db, user, session_id)


@router.get("/sessions/{session_id}/result", response_model=QuizResultOut)
async def get_quiz_result(
    session_id: UUID,
    user: CurrentUser,
    db: DbSession,
) -> QuizResultOut:
    return await quiz_service.get_result(db, user, session_id)
