from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

from app.auth.deps import CurrentUser, DbSession
from app.models import Topic, TopicCategory
from app.schemas.profile import (
    ProfileOut,
    ProfileStatsOut,
    TopicListResponse,
    TopicOut,
    UpdateProfileRequest,
)

router = APIRouter(tags=["catalog"])


@router.get("/topics", response_model=TopicListResponse)
async def list_topics(
    db: DbSession,
    category: str | None = Query(default=None),
    trending: bool | None = Query(default=None),
    q: str | None = Query(default=None, max_length=100),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> TopicListResponse:
    stmt = (
        select(Topic)
        .options(selectinload(Topic.category))
        .where(Topic.is_active.is_(True), Topic.is_custom.is_(False))
    )
    if category:
        stmt = stmt.join(TopicCategory).where(TopicCategory.slug == category)
    if trending is not None:
        stmt = stmt.where(Topic.is_trending.is_(trending))
    if q:
        like = f"%{q.lower()}%"
        stmt = stmt.where(func.lower(Topic.name).like(like))

    total = await db.scalar(select(func.count()).select_from(stmt.subquery()))
    result = await db.execute(
        stmt.order_by(Topic.popularity_score.desc(), Topic.name.asc()).limit(limit).offset(offset)
    )
    topics = result.scalars().all()
    return TopicListResponse(items=[TopicOut.model_validate(t) for t in topics], total=total or 0)


@router.get("/topics/{topic_id}", response_model=TopicOut)
async def get_topic(topic_id: UUID, db: DbSession) -> TopicOut:
    result = await db.execute(
        select(Topic).options(selectinload(Topic.category)).where(Topic.id == topic_id)
    )
    topic = result.scalar_one_or_none()
    if not topic:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Topic not found")
    return TopicOut.model_validate(topic)


@router.get("/users/me", response_model=ProfileOut)
async def get_my_profile(user: CurrentUser) -> ProfileOut:
    profile = user.profile
    stats = user.statistics
    return ProfileOut(
        user_id=user.id,
        username=profile.username,
        display_name=profile.display_name,
        avatar_id=profile.avatar_id,
        level=profile.level,
        xp=profile.xp,
        coins=profile.coins,
        current_streak=profile.current_streak,
        best_streak=profile.best_streak,
        daily_streak=profile.daily_streak,
        favorite_topic_ids=profile.favorite_topic_ids or [],
        onboarding_completed=profile.onboarding_completed,
        theme_preference=profile.theme_preference,
        is_premium=user.is_premium,
        statistics=ProfileStatsOut(
            total_quizzes=stats.total_quizzes,
            total_questions=stats.total_questions,
            total_correct=stats.total_correct,
            total_incorrect=stats.total_incorrect,
            accuracy=stats.accuracy,
            best_score=stats.best_score,
            best_streak=stats.best_streak,
            average_answer_ms=stats.average_answer_ms,
            topic_mastery=stats.topic_mastery or {},
            skill_ratings=stats.skill_ratings or {},
        ),
    )


@router.patch("/users/me", response_model=ProfileOut)
async def update_my_profile(
    payload: UpdateProfileRequest,
    user: CurrentUser,
    db: DbSession,
) -> ProfileOut:
    profile = user.profile
    if payload.display_name is not None:
        profile.display_name = payload.display_name
    if payload.avatar_id is not None:
        profile.avatar_id = payload.avatar_id
    if payload.theme_preference is not None:
        profile.theme_preference = payload.theme_preference
    if payload.favorite_topic_ids is not None:
        profile.favorite_topic_ids = [str(t) for t in payload.favorite_topic_ids]
    if payload.onboarding_completed is not None:
        profile.onboarding_completed = payload.onboarding_completed
    await db.flush()
    return await get_my_profile(user)
