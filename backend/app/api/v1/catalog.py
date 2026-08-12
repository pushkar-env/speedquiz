from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import String, func, select
from sqlalchemy.orm import selectinload

from app.auth.deps import CurrentUser, DbSession
from app.core.languages import ContentLanguage, normalize_language
from app.models import Topic, TopicCategory
from app.payments.cosmetics import can_use_avatar, is_known_avatar, profile_flair
from app.schemas.profile import (
    ProfileOut,
    ProfileStatsOut,
    TopicListResponse,
    TopicOut,
    UpdateProfileRequest,
)
from app.services.bank_inventory import count_active_by_language
from app.services.localization import (
    localized_category_name,
    localized_topic_description,
    localized_topic_name,
)

router = APIRouter(tags=["catalog"])


def _serialize_topic(
    topic: Topic,
    language: ContentLanguage,
    counts: dict[str, int],
) -> TopicOut:
    """One topic, named in the requested language, with its per-language stock.

    Names follow the *app* language here — this is the browsing catalog, which
    is chrome. Whether a topic can actually be played in a given language is a
    separate question, answered by `question_counts`.
    """
    payload = TopicOut.model_validate(topic)
    return payload.model_copy(
        update={
            "name": localized_topic_name(topic, language),
            "description": localized_topic_description(topic, language),
            "question_counts": counts,
            "category": (
                payload.category.model_copy(
                    update={"name": localized_category_name(topic.category, language)}
                )
                if payload.category is not None and topic.category is not None
                else payload.category
            ),
        }
    )


@router.get("/topics", response_model=TopicListResponse)
async def list_topics(
    db: DbSession,
    category: str | None = Query(default=None),
    trending: bool | None = Query(default=None),
    q: str | None = Query(default=None, max_length=100),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    language: str | None = Query(
        default=None,
        description="App language for display names (en, hi). Unknown tags fall back to en.",
    ),
) -> TopicListResponse:
    resolved = normalize_language(language)
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
        # Search spans the English source and every translation, so typing
        # "विज्ञान" and typing "science" both find the same topic.
        like = f"%{q.lower()}%"
        stmt = stmt.where(
            func.lower(Topic.name).like(like)
            | func.lower(func.cast(Topic.name_i18n, String)).like(like)
        )

    total = await db.scalar(select(func.count()).select_from(stmt.subquery()))
    result = await db.execute(
        stmt.order_by(Topic.popularity_score.desc(), Topic.name.asc()).limit(limit).offset(offset)
    )
    topics = list(result.scalars().all())
    counts = await count_active_by_language(db, [t.id for t in topics])
    return TopicListResponse(
        items=[_serialize_topic(t, resolved, counts.get(t.id, {})) for t in topics],
        total=total or 0,
        language=resolved.value,
    )


@router.get("/topics/{topic_id}", response_model=TopicOut)
async def get_topic(
    topic_id: UUID,
    db: DbSession,
    language: str | None = Query(default=None),
) -> TopicOut:
    result = await db.execute(
        select(Topic).options(selectinload(Topic.category)).where(Topic.id == topic_id)
    )
    topic = result.scalar_one_or_none()
    if not topic:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Topic not found")
    counts = await count_active_by_language(db, [topic.id])
    return _serialize_topic(topic, normalize_language(language), counts.get(topic.id, {}))


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
        app_language=normalize_language(profile.app_language).value,
        quiz_language=normalize_language(profile.quiz_language).value,
        is_premium=user.is_premium,
        flair=profile_flair(user),
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
        if not is_known_avatar(payload.avatar_id):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Unknown avatar_id",
            )
        # Hiding a locked avatar in the picker is presentation; this is the
        # part that actually stops someone PATCHing their way into the
        # premium set.
        if not can_use_avatar(user, payload.avatar_id):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail={
                    "code": "entitlement_premium_avatar",
                    "message": "That avatar is part of Premium",
                },
            )
        profile.avatar_id = payload.avatar_id
    if payload.theme_preference is not None:
        profile.theme_preference = payload.theme_preference
    if payload.favorite_topic_ids is not None:
        profile.favorite_topic_ids = [str(t) for t in payload.favorite_topic_ids]
    if payload.onboarding_completed is not None:
        profile.onboarding_completed = payload.onboarding_completed
    if payload.app_language is not None:
        profile.app_language = normalize_language(payload.app_language).value
    if payload.quiz_language is not None:
        profile.quiz_language = normalize_language(payload.quiz_language).value
    await db.flush()
    return await get_my_profile(user)
