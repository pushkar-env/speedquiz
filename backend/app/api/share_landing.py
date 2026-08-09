"""Public HTML share landing pages (no auth)."""

from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.auth.deps import DbSession
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
