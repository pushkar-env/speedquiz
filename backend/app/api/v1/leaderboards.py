from typing import Literal

from fastapi import APIRouter, Query

from app.auth.deps import CurrentUser, DbSession
from app.schemas.leaderboards import LeaderboardResponse
from app.services import leaderboards as lb_service

router = APIRouter(prefix="/leaderboards", tags=["leaderboards"])


@router.get("", response_model=LeaderboardResponse)
async def get_leaderboard(
    user: CurrentUser,
    db: DbSession,
    scope: Literal["weekly", "daily"] = Query(default="weekly"),
    limit: int = Query(default=50, ge=1, le=100),
) -> LeaderboardResponse:
    if scope == "weekly":
        period_key = lb_service.weekly_period_key()
    else:
        period_key = lb_service.daily_period_key()
    return await lb_service.get_board(
        db,
        scope=scope,
        period_key=period_key,
        limit=limit,
        me_user_id=user.id,
    )
