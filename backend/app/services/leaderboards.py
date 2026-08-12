"""Leaderboards — Redis hot path + Postgres durable store."""

from __future__ import annotations

from datetime import date
from typing import Optional
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import get_logger
from app.core.redis import get_redis
from app.models import LeaderboardEntry, User, UserProfile
from app.schemas.leaderboards import (
    LeaderboardEntryOut,
    LeaderboardMeOut,
    LeaderboardResponse,
)
from app.services.leaderboard_keys import daily_period_key, redis_key, weekly_period_key

logger = get_logger(__name__)

async def record_score(
    db: AsyncSession,
    *,
    user_id: UUID,
    score: int,
    weekly: bool = True,
    daily_date: Optional[date] = None,
) -> None:
    """Keep best score per user on weekly and/or daily boards."""
    if weekly:
        await _record_one(db, user_id=user_id, score=score, scope="weekly", period_key=weekly_period_key())
    if daily_date is not None:
        await _record_one(
            db,
            user_id=user_id,
            score=score,
            scope="daily",
            period_key=daily_period_key(daily_date),
        )


async def _record_one(
    db: AsyncSession,
    *,
    user_id: UUID,
    score: int,
    scope: str,
    period_key: str,
) -> None:
    score = int(score)
    member = str(user_id)

    # Redis best-score update
    try:
        r = await get_redis()
        key = redis_key(scope, period_key)
        existing = await r.zscore(key, member)
        if existing is None or score > float(existing):
            await r.zadd(key, {member: score})
    except Exception as exc:
        logger.warning("leaderboard_redis_write_failed", error=str(exc), scope=scope)

    # Postgres upsert (best score)
    row = await db.scalar(
        select(LeaderboardEntry).where(
            LeaderboardEntry.scope == scope,
            LeaderboardEntry.period_key == period_key,
            LeaderboardEntry.user_id == user_id,
            LeaderboardEntry.topic_id.is_(None),
        )
    )
    if row is None:
        db.add(
            LeaderboardEntry(
                id=uuid4(),
                scope=scope,
                period_key=period_key,
                user_id=user_id,
                topic_id=None,
                mode=None,
                score=score,
                rank=0,
            )
        )
    elif score > row.score:
        row.score = score
    await db.flush()


async def get_board(
    db: AsyncSession,
    *,
    scope: str,
    period_key: str,
    limit: int,
    me_user_id: UUID,
) -> LeaderboardResponse:
    limit = max(1, min(limit, 100))
    items: list[LeaderboardEntryOut] = []
    me = LeaderboardMeOut()

    redis_pairs: list[tuple[str, float]] = []
    try:
        r = await get_redis()
        key = redis_key(scope, period_key)
        raw = await r.zrevrange(key, 0, limit - 1, withscores=True)
        redis_pairs = [(uid, float(score)) for uid, score in raw]
        my_score = await r.zscore(key, str(me_user_id))
        if my_score is not None:
            rank0 = await r.zrevrank(key, str(me_user_id))
            me = LeaderboardMeOut(
                rank=(int(rank0) + 1) if rank0 is not None else None,
                score=int(my_score),
            )
    except Exception as exc:
        logger.warning("leaderboard_redis_read_failed", error=str(exc), scope=scope)

    if not redis_pairs:
        # Postgres fallback
        rows = (
            await db.execute(
                select(LeaderboardEntry)
                .where(
                    LeaderboardEntry.scope == scope,
                    LeaderboardEntry.period_key == period_key,
                    LeaderboardEntry.topic_id.is_(None),
                )
                .order_by(LeaderboardEntry.score.desc())
                .limit(limit)
            )
        ).scalars().all()
        redis_pairs = [(str(row.user_id), float(row.score)) for row in rows]
        mine = await db.scalar(
            select(LeaderboardEntry).where(
                LeaderboardEntry.scope == scope,
                LeaderboardEntry.period_key == period_key,
                LeaderboardEntry.user_id == me_user_id,
                LeaderboardEntry.topic_id.is_(None),
            )
        )
        if mine:
            from sqlalchemy import func

            better_count = await db.scalar(
                select(func.count())
                .select_from(LeaderboardEntry)
                .where(
                    LeaderboardEntry.scope == scope,
                    LeaderboardEntry.period_key == period_key,
                    LeaderboardEntry.topic_id.is_(None),
                    LeaderboardEntry.score > mine.score,
                )
            )
            me = LeaderboardMeOut(
                rank=int(better_count or 0) + 1,
                score=mine.score,
            )

    user_ids: list[UUID] = []
    for uid, _ in redis_pairs:
        try:
            user_ids.append(UUID(uid))
        except (ValueError, TypeError):
            continue

    # One join for the whole page: username and avatar to render the row,
    # is_premium for the subscriber badge.
    profiles: dict[UUID, tuple[str, str, bool]] = {}
    if user_ids:
        rows = await db.execute(
            select(
                UserProfile.user_id,
                UserProfile.username,
                UserProfile.avatar_id,
                User.is_premium,
            )
            .join(User, User.id == UserProfile.user_id)
            .where(UserProfile.user_id.in_(user_ids))
        )
        profiles = {
            row.user_id: (row.username, row.avatar_id, bool(row.is_premium))
            for row in rows.all()
        }

    for idx, (uid, score) in enumerate(redis_pairs):
        try:
            user_uuid = UUID(uid)
        except (ValueError, TypeError):
            continue
        username, avatar_id, is_premium = profiles.get(
            user_uuid, ("Player", "avatar_01", False)
        )
        items.append(
            LeaderboardEntryOut(
                rank=idx + 1,
                user_id=user_uuid,
                username=username,
                avatar_id=avatar_id,
                is_premium=is_premium,
                score=int(score),
                is_me=user_uuid == me_user_id,
            )
        )

    if me.username is None and me.score is not None:
        profile = await db.scalar(
            select(UserProfile).where(UserProfile.user_id == me_user_id)
        )
        me = LeaderboardMeOut(
            rank=me.rank,
            score=me.score,
            username=profile.username if profile else "You",
        )
    elif me.score is not None and me.username is None:
        profile = await db.scalar(
            select(UserProfile).where(UserProfile.user_id == me_user_id)
        )
        me.username = profile.username if profile else "You"

    # Refresh ranks on top rows (best-effort)
    for entry in items:
        row = await db.scalar(
            select(LeaderboardEntry).where(
                LeaderboardEntry.scope == scope,
                LeaderboardEntry.period_key == period_key,
                LeaderboardEntry.user_id == entry.user_id,
                LeaderboardEntry.topic_id.is_(None),
            )
        )
        if row is not None:
            row.rank = entry.rank

    return LeaderboardResponse(
        scope=scope,
        period_key=period_key,
        items=items,
        me=me,
        total=len(items),
    )
