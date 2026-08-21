"""Public HTML share landing pages (no auth)."""

from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.auth.deps import DbSession
from app.services import custom_quizzes
from app.services.share import get_shared_result
from fastapi import HTTPException

router = APIRouter(tags=["share-landing"])

_TEMPLATES = Jinja2Templates(directory=str(Path(__file__).resolve().parents[1] / "templates"))


@router.get("/r/{session_id}", response_class=HTMLResponse)
async def share_result_landing(
    session_id: UUID,
    request: Request,
    db: DbSession,
) -> HTMLResponse:
    try:
        result = await get_shared_result(db, session_id)
    except HTTPException:
        return _TEMPLATES.TemplateResponse(
            request,
            "share_result_404.html",
            {},
            status_code=404,
        )
    return _TEMPLATES.TemplateResponse(
        request,
        "share_result.html",
        {"result": result},
    )


@router.get("/q/{code}", response_class=HTMLResponse)
async def quiz_invite_landing(
    code: str,
    request: Request,
    db: DbSession,
) -> HTMLResponse:
    """Public landing for a custom-quiz share code.

    Exists for the half of the audience that does not have the app yet: an
    HTTPS link renders in every chat client, survives being forwarded, and can
    say what the quiz *is* before asking anyone to install anything. A device
    that already has SpeedQuiz never sees it — the App Link takes it straight
    into the app.

    Shows title, author and size only. Never the questions, and never a quiz
    the author kept private — see `custom_quizzes.public_preview`.
    """
    preview = await custom_quizzes.public_preview(db, code)
    if preview is None:
        return _TEMPLATES.TemplateResponse(
            request,
            "quiz_invite_404.html",
            {},
            status_code=404,
        )
    return _TEMPLATES.TemplateResponse(request, "quiz_invite.html", {"quiz": preview})
