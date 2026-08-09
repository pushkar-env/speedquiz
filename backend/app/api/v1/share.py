from uuid import UUID

from fastapi import APIRouter

from app.auth.deps import DbSession
from app.services.share import SharedResultOut, get_shared_result

router = APIRouter(prefix="/share", tags=["share"])


@router.get("/results/{session_id}", response_model=SharedResultOut)
async def get_public_shared_result(
    session_id: UUID,
    db: DbSession,
) -> SharedResultOut:
    """Public, auth-free share card for deep links. Safe fields only."""
    return await get_shared_result(db, session_id)
