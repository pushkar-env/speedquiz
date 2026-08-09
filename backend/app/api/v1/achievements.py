from fastapi import APIRouter
from sqlalchemy import select

from app.auth.deps import CurrentUser, DbSession
from app.models import Achievement, UserAchievement
from app.schemas.achievements import AchievementListResponse, AchievementOut

router = APIRouter(prefix="/achievements", tags=["achievements"])


@router.get("", response_model=AchievementListResponse)
async def list_achievements(user: CurrentUser, db: DbSession) -> AchievementListResponse:
    achievements = (
        await db.execute(
            select(Achievement)
            .where(Achievement.is_active.is_(True))
            .order_by(Achievement.sort_order.asc(), Achievement.code.asc())
        )
    ).scalars().all()

    unlocks = (
        await db.execute(
            select(UserAchievement).where(UserAchievement.user_id == user.id)
        )
    ).scalars().all()
    unlock_by_id = {u.achievement_id: u for u in unlocks}

    items: list[AchievementOut] = []
    for ach in achievements:
        unlock = unlock_by_id.get(ach.id)
        items.append(
            AchievementOut(
                id=ach.id,
                code=ach.code,
                name=ach.name,
                description=ach.description,
                icon=ach.icon,
                category=ach.category,
                xp_reward=ach.xp_reward,
                coins_reward=ach.coins_reward,
                sort_order=ach.sort_order,
                unlocked=unlock is not None,
                unlocked_at=unlock.unlocked_at if unlock else None,
            )
        )

    unlocked_count = sum(1 for i in items if i.unlocked)
    return AchievementListResponse(
        items=items,
        unlocked_count=unlocked_count,
        total=len(items),
    )
