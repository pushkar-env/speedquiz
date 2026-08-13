"""The ranked queue.

There is no background matchmaker process. Pairing happens on the request that
joins the queue and on every poll after it, each time with a slightly wider
rating band. That is deliberate: a separate matchmaker is another thing to
deploy, monitor and restart, and it buys nothing here — someone is always
polling, because a player waiting for a match is by definition looking at the
screen.

Ranked picks the topic, not the players
---------------------------------------
Letting each side nominate a topic and then choosing one of them hands half of
every match to whoever's favourite won. The queue therefore draws a topic
itself, from those with a deep enough bank in the shared language. Neither
player chose it, which is the only arrangement that is fair to both.

Language is part of the queue key
---------------------------------
A Hindi player cannot be seated at an English board — the questions *are* the
match. Matching across languages is not a degraded experience, it is an
unplayable one, so the queues are simply separate.
"""

from __future__ import annotations

import json
import time
from typing import Optional
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.languages import ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.core.redis import get_redis
from app.models import (
    DifficultyLabel,
    MatchFormat,
    MatchKind,
    Question,
    QuestionStatus,
    Topic,
    User,
)
from app.schemas.multiplayer import CreateMatchRequest, QueueTicketResponse
from app.services import matches, ranking

logger = get_logger(__name__)

QUEUE_PREFIX = "mp:queue:ranked:"
META_PREFIX = "mp:queue:meta:"
STATE_PREFIX = "mp:queue:state:"
QUEUE_LOCK = "mp:queue:lock"

#: How long a resolved ticket stays readable, so a client that polls once more
#: after being matched still learns the match id instead of a bare "not found".
STATE_TTL_SECONDS = 300


def queue_key(language: ContentLanguage) -> str:
    return f"{QUEUE_PREFIX}{language.value}"


def _meta_key(user_id: UUID) -> str:
    return f"{META_PREFIX}{user_id}"


def _state_key(user_id: UUID) -> str:
    return f"{STATE_PREFIX}{user_id}"


def band_for(waited_seconds: int) -> int:
    """Rating window at this point in the search.

    Starts tight so the first matches are good ones, and widens with time
    because a fair match nobody gets is worse than a slightly lopsided one they
    actually play.
    """
    settings = get_settings()
    grown = settings.matchmaking_initial_band + int(
        waited_seconds * settings.matchmaking_band_growth_per_second
    )
    return min(grown, settings.matchmaking_max_band)


async def _pick_topic(db: AsyncSession, language: ContentLanguage) -> Optional[Topic]:
    """A topic with enough playable questions in this language.

    The floor is four times a match's length: drawing seven questions from a
    bank of eight would hand both players the same near-exhausted set every
    time they queued.
    """
    settings = get_settings()
    minimum = settings.match_default_question_count * 4

    deep_enough = (
        select(Question.topic_id)
        .where(
            Question.language == language.value,
            Question.status == QuestionStatus.ACTIVE,
        )
        .group_by(Question.topic_id)
        .having(func.count() >= minimum)
        .subquery()
    )
    return await db.scalar(
        select(Topic)
        .join(deep_enough, deep_enough.c.topic_id == Topic.id)
        .where(Topic.is_active.is_(True))
        .order_by(func.random())
        .limit(1)
    )


async def join_queue(
    db: AsyncSession,
    user: User,
    *,
    language: Optional[ContentLanguage] = None,
) -> QueueTicketResponse:
    settings = get_settings()
    if not settings.multiplayer_enabled:
        return QueueTicketResponse(state="cancelled")

    resolved = normalize_language(
        language if language is not None
        else (user.profile.quiz_language if user.profile else None)
    )
    rating_row = await ranking.get_or_create_rating(db, user.id)

    redis = await get_redis()
    await redis.zadd(queue_key(resolved), {str(user.id): rating_row.rating})
    await redis.set(
        _meta_key(user.id),
        json.dumps(
            {
                "joined_at": time.time(),
                "language": resolved.value,
                "rating": rating_row.rating,
            }
        ),
        ex=settings.matchmaking_timeout_seconds * 4,
    )
    await redis.delete(_state_key(user.id))
    return await poll_queue(db, user)


async def leave_queue(user: User) -> None:
    redis = await get_redis()
    for language in ContentLanguage:
        await redis.zrem(queue_key(language), str(user.id))
    await redis.delete(_meta_key(user.id))
    await redis.delete(_state_key(user.id))


async def poll_queue(db: AsyncSession, user: User) -> QueueTicketResponse:
    """Advance this player's search by one step.

    Returns immediately if someone else already paired them — the other side of
    a pairing learns about it here rather than by being told, which keeps the
    whole protocol to one endpoint.
    """
    settings = get_settings()
    redis = await get_redis()

    resolved_state = await redis.get(_state_key(user.id))
    if resolved_state:
        try:
            return QueueTicketResponse(state="matched", match_id=UUID(resolved_state))
        except (ValueError, TypeError):
            pass

    raw_meta = await redis.get(_meta_key(user.id))
    if not raw_meta:
        return QueueTicketResponse(state="cancelled")

    try:
        meta = json.loads(raw_meta)
        joined_at = float(meta["joined_at"])
        language = normalize_language(meta.get("language"))
        rating = int(meta.get("rating", settings.ranked_starting_rating))
    except (ValueError, TypeError, KeyError):
        await leave_queue(user)
        return QueueTicketResponse(state="cancelled")

    waited = max(0, int(time.time() - joined_at))
    band = band_for(waited)

    match_id = await _try_pair(db, user, language=language, rating=rating, band=band)
    if match_id is not None:
        return QueueTicketResponse(
            state="matched", match_id=match_id, waited_seconds=waited, band=band
        )

    if waited >= settings.matchmaking_timeout_seconds:
        await leave_queue(user)
        return QueueTicketResponse(state="timeout", waited_seconds=waited, band=band)

    searching = await redis.zcard(queue_key(language))
    return QueueTicketResponse(
        state="searching",
        waited_seconds=waited,
        band=band,
        players_searching=int(searching or 0),
    )


async def _try_pair(
    db: AsyncSession,
    user: User,
    *,
    language: ContentLanguage,
    rating: int,
    band: int,
) -> Optional[UUID]:
    """Find an opponent inside `band` and seat both players.

    The lock is what makes this safe with several API replicas polling at once:
    without it two processes can hand the same opponent to two different
    players, and one of them ends up in a match the other never joins.
    """
    redis = await get_redis()
    key = queue_key(language)

    # Short TTL: if a replica dies holding this, matchmaking must recover in
    # seconds, and the worst case of an early expiry is a duplicate pairing
    # attempt that the ZREM below still resolves to one winner.
    locked = await redis.set(QUEUE_LOCK, str(user.id), nx=True, px=3000)
    if not locked:
        return None

    try:
        candidates = await redis.zrangebyscore(
            key, rating - band, rating + band, withscores=True
        )
        opponent_id: Optional[UUID] = None
        best_gap: Optional[int] = None
        for member, score in candidates:
            if member == str(user.id):
                continue
            gap = abs(int(score) - rating)
            if best_gap is None or gap < best_gap:
                try:
                    opponent_id = UUID(member)
                    best_gap = gap
                except (ValueError, TypeError):
                    continue

        if opponent_id is None:
            return None

        # Claim both seats before doing anything slow. A ZREM that returns 0
        # means someone else already took that player.
        removed_me = await redis.zrem(key, str(user.id))
        removed_them = await redis.zrem(key, str(opponent_id))
        if not removed_me or not removed_them:
            # Lost a race. Put back whichever seat we did claim, so the player
            # keeps their place rather than silently falling out of the queue.
            if removed_me:
                await redis.zadd(key, {str(user.id): rating})
            if removed_them:
                await redis.zadd(key, {str(opponent_id): rating})
            return None

        topic = await _pick_topic(db, language)
        if topic is None:
            await redis.zadd(key, {str(user.id): rating})
            await redis.zadd(key, {str(opponent_id): rating})
            logger.warning("matchmaking_no_topic", language=language.value)
            return None

        match = await matches.create_match(
            db,
            user,
            CreateMatchRequest(
                topic_id=topic.id,
                difficulty=DifficultyLabel.MEDIUM,
                language=language,
                format=MatchFormat.DUEL,
            ),
            kind=MatchKind.RANKED,
            opponent_ids=[opponent_id],
        )

        settings = get_settings()
        for participant_id in (user.id, opponent_id):
            await redis.set(
                _state_key(participant_id), str(match.id), ex=STATE_TTL_SECONDS
            )
            await redis.delete(_meta_key(participant_id))
        logger.info(
            "ranked_pair_created",
            match_id=str(match.id),
            rating_gap=best_gap,
            band=band,
            timeout=settings.matchmaking_timeout_seconds,
        )
        return match.id
    except Exception as exc:  # noqa: BLE001 — a failed pairing must not 500 the poll
        logger.warning("matchmaking_pair_failed", error=str(exc))
        return None
    finally:
        await redis.delete(QUEUE_LOCK)


async def queue_size(language: ContentLanguage) -> int:
    try:
        redis = await get_redis()
        return int(await redis.zcard(queue_key(language)) or 0)
    except Exception:  # noqa: BLE001
        return 0
