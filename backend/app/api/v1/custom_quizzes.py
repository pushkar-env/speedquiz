"""Player-authored quizzes: author, share, play, challenge.

Route shape follows the two audiences. Everything under ``/{quiz_id}`` that
mutates is author-only and 404s for anyone else; the play, leaderboard, code
and report routes are for whoever the author shared with. The split lives in
the service (`load_owned` vs `assert_can_play`) so it cannot drift between an
endpoint and its handler.
"""

from uuid import UUID

from fastapi import APIRouter, status

from app.auth.deps import CurrentUser, DbSession
from app.schemas.custom_quizzes import (
    AiDraftRequest,
    AiDraftResponse,
    ChallengeWithQuizRequest,
    CreateCustomQuizRequest,
    CustomQuizDetailOut,
    CustomQuizLeaderboardResponse,
    CustomQuizListResponse,
    CustomQuizOut,
    CustomQuizQuestionIn,
    ReorderQuestionsRequest,
    ReportQuizRequest,
    StartCustomQuizRequest,
    StartCustomQuizResponse,
    UpdateCustomQuizRequest,
)
from app.schemas.multiplayer import MatchOut
from app.services import custom_quizzes as service
from app.services import matches as matches_service

router = APIRouter(prefix="/custom-quizzes", tags=["custom-quizzes"])


# --- Library ----------------------------------------------------------------


@router.get("", response_model=CustomQuizListResponse)
async def list_my_quizzes(user: CurrentUser, db: DbSession) -> CustomQuizListResponse:
    """Everything this player wrote, plus everything shared with them."""
    return await service.list_for_user(db, user)


@router.post("", response_model=CustomQuizDetailOut, status_code=status.HTTP_201_CREATED)
async def create_quiz(
    payload: CreateCustomQuizRequest,
    user: CurrentUser,
    db: DbSession,
) -> CustomQuizDetailOut:
    return await service.create_quiz(db, user, payload)


@router.post("/ai-draft", response_model=AiDraftResponse)
async def ai_draft(
    payload: AiDraftRequest,
    user: CurrentUser,
    db: DbSession,
) -> AiDraftResponse:
    """Draft questions for the author to edit. Saves nothing on its own."""
    return await service.ai_draft(db, user, payload)


@router.get("/code/{code}", response_model=CustomQuizOut)
async def open_by_code(code: str, user: CurrentUser, db: DbSession) -> CustomQuizOut:
    """Redeem a share code. Also grants standing access, so it is needed once."""
    quiz = await service.resolve_code(db, user, code)
    return await service.serialize_one(db, quiz, user)


@router.get("/{quiz_id}", response_model=CustomQuizDetailOut)
async def get_quiz(quiz_id: UUID, user: CurrentUser, db: DbSession) -> CustomQuizDetailOut:
    """The quiz and its questions.

    Answer keys are in this payload, so it is gated on being able to play *and*
    only ever returned in full to the author — see `serialize_detail`.
    """
    quiz = await service.load_quiz(db, quiz_id)
    if quiz.owner_user_id != user.id:
        await service.assert_can_play(db, user, quiz)
        # A player gets the shell, never the questions: the detail payload
        # carries `correct_option_index` for the editor.
        base = await service.serialize_one(db, quiz, user)
        return CustomQuizDetailOut(**base.model_dump(), questions=[])
    return await service.serialize_detail(db, quiz, user)


@router.patch("/{quiz_id}", response_model=CustomQuizDetailOut)
async def update_quiz(
    quiz_id: UUID,
    payload: UpdateCustomQuizRequest,
    user: CurrentUser,
    db: DbSession,
) -> CustomQuizDetailOut:
    return await service.update_quiz(db, user, quiz_id, payload)


@router.delete("/{quiz_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_quiz(quiz_id: UUID, user: CurrentUser, db: DbSession) -> None:
    """Permanent. 409s once anyone has played it — archive that one instead."""
    await service.delete_quiz(db, user, quiz_id)


# --- Lifecycle --------------------------------------------------------------


@router.post("/{quiz_id}/publish", response_model=CustomQuizDetailOut)
async def publish_quiz(quiz_id: UUID, user: CurrentUser, db: DbSession) -> CustomQuizDetailOut:
    return await service.publish(db, user, quiz_id)


@router.post("/{quiz_id}/unpublish", response_model=CustomQuizDetailOut)
async def unpublish_quiz(quiz_id: UUID, user: CurrentUser, db: DbSession) -> CustomQuizDetailOut:
    return await service.unpublish(db, user, quiz_id)


@router.post("/{quiz_id}/archive", response_model=CustomQuizDetailOut)
async def archive_quiz(quiz_id: UUID, user: CurrentUser, db: DbSession) -> CustomQuizDetailOut:
    return await service.archive(db, user, quiz_id)


@router.post("/{quiz_id}/restore", response_model=CustomQuizDetailOut)
async def restore_quiz(quiz_id: UUID, user: CurrentUser, db: DbSession) -> CustomQuizDetailOut:
    return await service.restore(db, user, quiz_id)


# --- Questions --------------------------------------------------------------


@router.post(
    "/{quiz_id}/questions",
    response_model=CustomQuizDetailOut,
    status_code=status.HTTP_201_CREATED,
)
async def add_question(
    quiz_id: UUID,
    payload: CustomQuizQuestionIn,
    user: CurrentUser,
    db: DbSession,
) -> CustomQuizDetailOut:
    return await service.add_question(db, user, quiz_id, payload)


@router.put("/{quiz_id}/questions/{question_id}", response_model=CustomQuizDetailOut)
async def update_question(
    quiz_id: UUID,
    question_id: UUID,
    payload: CustomQuizQuestionIn,
    user: CurrentUser,
    db: DbSession,
) -> CustomQuizDetailOut:
    return await service.update_question(db, user, quiz_id, question_id, payload)


@router.delete("/{quiz_id}/questions/{question_id}", response_model=CustomQuizDetailOut)
async def delete_question(
    quiz_id: UUID,
    question_id: UUID,
    user: CurrentUser,
    db: DbSession,
) -> CustomQuizDetailOut:
    return await service.delete_question(db, user, quiz_id, question_id)


@router.post("/{quiz_id}/questions/reorder", response_model=CustomQuizDetailOut)
async def reorder_questions(
    quiz_id: UUID,
    payload: ReorderQuestionsRequest,
    user: CurrentUser,
    db: DbSession,
) -> CustomQuizDetailOut:
    return await service.reorder_questions(db, user, quiz_id, payload.question_ids)


# --- Play -------------------------------------------------------------------


@router.post(
    "/{quiz_id}/start",
    response_model=StartCustomQuizResponse,
    status_code=status.HTTP_201_CREATED,
)
async def start_quiz(
    quiz_id: UUID,
    payload: StartCustomQuizRequest,
    user: CurrentUser,
    db: DbSession,
) -> StartCustomQuizResponse:
    return await service.start_solo(db, user, quiz_id, payload)


@router.post(
    "/{quiz_id}/challenge",
    response_model=MatchOut,
    status_code=status.HTTP_201_CREATED,
)
async def challenge_with_quiz(
    quiz_id: UUID,
    payload: ChallengeWithQuizRequest,
    user: CurrentUser,
    db: DbSession,
) -> MatchOut:
    match = await service.challenge(db, user, quiz_id, payload)
    return await matches_service.serialize_match(db, match, viewer_id=user.id)


@router.get("/{quiz_id}/leaderboard", response_model=CustomQuizLeaderboardResponse)
async def quiz_leaderboard(
    quiz_id: UUID,
    user: CurrentUser,
    db: DbSession,
) -> CustomQuizLeaderboardResponse:
    return await service.leaderboard(db, user, quiz_id)


@router.post("/{quiz_id}/report", status_code=status.HTTP_204_NO_CONTENT)
async def report_quiz(
    quiz_id: UUID,
    payload: ReportQuizRequest,
    user: CurrentUser,
    db: DbSession,
) -> None:
    await service.report(db, user, quiz_id, payload)
