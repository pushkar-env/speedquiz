from fastapi import APIRouter

from app.auth.deps import CurrentUser, DbSession
from app.schemas.daily import DailyChallengeOut
from app.schemas.quiz import QuizSessionOut
from app.services import daily_challenge as daily_service

router = APIRouter(prefix="/daily-challenge", tags=["daily"])


@router.get("", response_model=DailyChallengeOut)
async def get_daily_challenge(user: CurrentUser, db: DbSession) -> DailyChallengeOut:
    return await daily_service.get_daily_for_user(db, user)


@router.post("/start", response_model=QuizSessionOut)
async def start_daily_challenge(user: CurrentUser, db: DbSession) -> QuizSessionOut:
    return await daily_service.start_daily(db, user)
