"""Achievement evaluation — pure stats, never on the answer hot path beyond finish."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Achievement, Topic, UserAchievement, UserProfile
from app.services.progression import apply_xp


@dataclass
class AchievementContext:
    quizzes_completed: int
    correct_answers: int
    best_streak: int
    level: int
    daily_streak: int
    topic_mastery_by_slug: dict[str, float]
    min_answer_ms: Optional[int]
    perfect_run: bool
    daily_completed: bool = False  # Phase 5b


@dataclass
class UnlockedAchievement:
    id: UUID
    code: str
    name: str
    description: str
    icon: str
    category: str
    xp_reward: int
    coins_reward: int


def criteria_met(
    criteria: dict[str, Any],
    ctx: AchievementContext,
    *,
    current_level: Optional[int] = None,
) -> bool:
    ctype = str(criteria.get("type", ""))
    value = criteria.get("value")

    if ctype == "quizzes_completed":
        return ctx.quizzes_completed >= int(value)
    if ctype == "correct_answers":
        return ctx.correct_answers >= int(value)
    if ctype == "best_streak":
        return ctx.best_streak >= int(value)
    if ctype == "level":
        level = current_level if current_level is not None else ctx.level
        return level >= int(value)
    if ctype == "daily_streak":
        return ctx.daily_streak >= int(value)
    if ctype == "fast_answer_ms":
        if ctx.min_answer_ms is None:
            return False
        return ctx.min_answer_ms <= int(value)
    if ctype == "perfect_run":
        return ctx.perfect_run and int(value) <= 1
    if ctype == "daily_completed":
        # Deferred to Phase 5b — never unlock early
        return False
    if ctype == "topic_mastery":
        slug = str(criteria.get("topic", ""))
        percent = ctx.topic_mastery_by_slug.get(slug, 0.0)
        return percent >= float(value)
    return False


# Back-compat alias for tests / callers
_criteria_met = criteria_met


async def _mastery_by_slug(db: AsyncSession, topic_mastery: dict) -> dict[str, float]:
    if not topic_mastery:
        return {}
    topic_ids: list[UUID] = []
    for key in topic_mastery.keys():
        try:
            topic_ids.append(UUID(str(key)))
        except (ValueError, TypeError):
            continue
    if not topic_ids:
        return {}
    rows = await db.execute(select(Topic.id, Topic.slug).where(Topic.id.in_(topic_ids)))
    id_to_slug = {row.id: row.slug for row in rows.all()}
    out: dict[str, float] = {}
    for key, payload in topic_mastery.items():
        try:
            tid = UUID(str(key))
        except (ValueError, TypeError):
            continue
        slug = id_to_slug.get(tid)
        if not slug:
            continue
        percent = float((payload or {}).get("percent", 0) or 0)
        out[slug] = percent
    return out


async def evaluate_and_unlock(
    db: AsyncSession,
    *,
    user_id: UUID,
    profile: UserProfile,
    ctx: AchievementContext,
) -> list[UnlockedAchievement]:
    achievements = (
        await db.execute(
            select(Achievement)
            .where(Achievement.is_active.is_(True))
            .order_by(Achievement.sort_order.asc())
        )
    ).scalars().all()
    if not achievements:
        return []

    unlocked_ids = set(
        (
            await db.execute(
                select(UserAchievement.achievement_id).where(UserAchievement.user_id == user_id)
            )
        )
        .scalars()
        .all()
    )

    newly: list[UnlockedAchievement] = []
    for ach in achievements:
        if ach.id in unlocked_ids:
            continue
        criteria = ach.criteria or {}
        if not criteria_met(criteria, ctx, current_level=profile.level):
            continue
        db.add(
            UserAchievement(
                user_id=user_id,
                achievement_id=ach.id,
                meta={"criteria": criteria},
            )
        )
        unlocked_ids.add(ach.id)
        if ach.xp_reward:
            profile.level, profile.xp = apply_xp(profile.level, profile.xp, ach.xp_reward)
        if ach.coins_reward:
            profile.coins = int(profile.coins or 0) + int(ach.coins_reward)
        newly.append(
            UnlockedAchievement(
                id=ach.id,
                code=ach.code,
                name=ach.name,
                description=ach.description,
                icon=ach.icon,
                category=ach.category,
                xp_reward=ach.xp_reward,
                coins_reward=ach.coins_reward,
            )
        )
    return newly


async def build_context_from_profile_stats(
    db: AsyncSession,
    *,
    profile: UserProfile,
    quizzes_completed: int,
    correct_answers: int,
    best_streak: int,
    topic_mastery: dict,
    min_answer_ms: Optional[int],
    perfect_run: bool,
) -> AchievementContext:
    return AchievementContext(
        quizzes_completed=quizzes_completed,
        correct_answers=correct_answers,
        best_streak=best_streak,
        level=profile.level,
        daily_streak=profile.daily_streak,
        topic_mastery_by_slug=await _mastery_by_slug(db, topic_mastery or {}),
        min_answer_ms=min_answer_ms,
        perfect_run=perfect_run,
    )
