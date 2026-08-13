"""The match engine: rooms, rounds, scoring and settlement.

What makes a match fair
-----------------------
The question set is drawn **once**, at creation, and frozen onto the match row
as ``question_ids`` plus ``option_orders``. Everyone therefore sees the same
prompts in the same order with the same answer buttons in the same positions.
That is what makes two scores comparable, and it is also what lets an async
opponent play the identical board six hours later — the live and async paths
are the same match, differing only in when each side is served.

The answer key never leaves the server. A round response carries prompts and
options; correctness is resolved against the `questions` row at submit time and
returned only to the player who just answered.

Who advances the round
----------------------
Nobody owns a match. Railway runs several API containers and the two players
are routinely on different ones, so there is no process that can hold a timer
for a game. Instead, advancement is *opportunistic*: any request that touches a
match — an answer landing, a state poll, a realtime tick — asks whether the
round is over, and a short Redis lock plus a compare-and-set on
``current_round_index`` ensures exactly one of them acts on it. This needs no
leader election and degrades to "the next request advances it" if Redis is
down, which is late but never wrong.
"""

from __future__ import annotations

import random
import secrets
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Iterable, Optional, Sequence
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import get_settings
from app.core.languages import ContentLanguage, normalize_language
from app.core.logging import get_logger
from app.models import (
    ACTIVE_PARTICIPANT_STATUSES,
    OPEN_MATCH_STATUSES,
    DifficultyLabel,
    GameMode,
    Match,
    MatchAnswer,
    MatchDelivery,
    MatchFormat,
    MatchKind,
    MatchOutcome,
    MatchParticipant,
    MatchStatus,
    ParticipantStatus,
    PlayerStatistics,
    Question,
    Topic,
    User,
    UserProfile,
)
from app.schemas.multiplayer import (
    CreateMatchRequest,
    MatchAnswerFeedbackOut,
    MatchOptionOut,
    MatchOut,
    MatchParticipantOut,
    MatchResultOut,
    MatchRoundOut,
    OpponentRoundStateOut,
    PlayerBriefOut,
    SubmitMatchAnswerRequest,
)
from app.models import NotificationType
from app.services import anticheat, friends, notifications, ranking, realtime
from app.services.localization import localized_topic_name
from app.services.progression import apply_xp
from app.services.quiz_service import _select_questions, _user_seen_question_ids
from app.services.scoring import scoring_service

logger = get_logger(__name__)

#: Room codes use the friend-code alphabet for the same reason: they get read
#: aloud and typed in by someone across the room.
ROOM_CODE_ALPHABET = "23456789BCDFGHJKMNPQRSTVWXYZ"
ROOM_CODE_LENGTH = 6

#: Matches always score by the casual curve. Speedrun and survival own pacing
#: ramps (a shrinking clock, lives) that assume one player and would make two
#: players' rounds incomparable; the `mode` column stays for when a mode is
#: designed for two.
MATCH_GAME_MODE = GameMode.CASUAL

#: Rewards. Deliberately modest next to a solo run: multiplayer should be worth
#: playing for the match, and a ladder that is also the fastest way to farm XP
#: turns every friendly into a chore.
XP_PER_100_POINTS = 4
XP_WIN_BONUS = 60
XP_DRAW_BONUS = 30
XP_PARTICIPATION = 15
COINS_WIN = 10
COINS_DRAW = 5
COINS_PLAY = 2


def match_deep_link(match_id: UUID) -> str:
    """In-app route a notification about this match opens."""
    return f"/battle/match/{match_id}"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _aware(moment: Optional[datetime]) -> Optional[datetime]:
    """Postgres can hand back naive datetimes through some drivers/paths.

    Comparing a naive to an aware datetime raises, and it would do so inside
    the round clock — the one place a crash costs a live game.
    """
    if moment is None:
        return None
    return moment if moment.tzinfo is not None else moment.replace(tzinfo=timezone.utc)


def _err(code: str, message: str, http_status: int = status.HTTP_400_BAD_REQUEST) -> HTTPException:
    return HTTPException(status_code=http_status, detail={"code": code, "message": message})


# --- Question set -----------------------------------------------------------


def _seeded_option_order(rng: random.Random) -> list[int]:
    order = [0, 1, 2, 3]
    rng.shuffle(order)
    return order


def _normalize_option_order(raw: object) -> list[int]:
    """Keep a strict permutation of 0..3 out of whatever JSONB returns."""
    if not isinstance(raw, list) or len(raw) != 4:
        return [0, 1, 2, 3]
    try:
        order = [int(x) for x in raw]
    except (TypeError, ValueError):
        return [0, 1, 2, 3]
    return order if sorted(order) == [0, 1, 2, 3] else [0, 1, 2, 3]


async def _build_question_set(
    db: AsyncSession,
    *,
    topic_id: UUID,
    difficulty: DifficultyLabel,
    language: ContentLanguage,
    count: int,
    participant_ids: Sequence[UUID],
) -> tuple[list[UUID], list[list[int]], str]:
    """Draw the shared board for a match.

    Questions already seen by *any* known participant are excluded first,
    because a prompt one side has met before and the other has not is a free
    point. That is a strict exclusion rather than a preference, so a thin bank
    can under-deliver — hence the second pass, which drops the fairness filter
    rather than refusing to start a match at all. Both sides being equally
    disadvantaged by a repeat is a much smaller problem than no game.
    """
    seen: set[UUID] = set()
    for user_id in participant_ids:
        seen |= await _user_seen_question_ids(db, user_id=user_id, topic_id=topic_id)

    questions = await _select_questions(
        db,
        topic_id=topic_id,
        difficulty=difficulty,
        exclude_ids=seen,
        limit=count,
        language=language,
    )
    if len(questions) < count:
        questions = await _select_questions(
            db,
            topic_id=topic_id,
            difficulty=difficulty,
            exclude_ids=set(),
            limit=count,
            language=language,
        )
    if len(questions) < count:
        raise _err(
            "bank_too_thin",
            "Not enough questions in this topic yet. Try another topic.",
            status.HTTP_409_CONFLICT,
        )

    # A recorded seed makes the board reproducible for support, and keeps the
    # option shuffle auditable rather than "whatever random did that day".
    seed = secrets.token_hex(8)
    rng = random.Random(seed)
    orders = [_seeded_option_order(rng) for _ in questions]
    return [q.id for q in questions[:count]], orders[:count], seed


async def _unique_room_code(db: AsyncSession) -> str:
    for _ in range(10):
        code = "".join(secrets.choice(ROOM_CODE_ALPHABET) for _ in range(ROOM_CODE_LENGTH))
        taken = await db.scalar(select(Match.id).where(Match.code == code).limit(1))
        if not taken:
            return code
    raise _err("code_unavailable", "Try again in a moment.", status.HTTP_503_SERVICE_UNAVAILABLE)


# --- Serialization ----------------------------------------------------------


def _player_brief(
    profile: UserProfile,
    *,
    is_premium: bool = False,
    rating: Optional[int] = None,
    placements_remaining: int = 0,
) -> PlayerBriefOut:
    tier = ranking.tier_for(rating or 0, placements_remaining=placements_remaining) if rating else None
    return PlayerBriefOut(
        user_id=profile.user_id,
        username=profile.username,
        display_name=profile.display_name,
        avatar_id=profile.avatar_id,
        level=profile.level,
        is_premium=is_premium,
        rating=rating,
        tier=tier.code if tier else None,
        tier_icon=tier.icon if tier else None,
    )


async def _profiles_for(db: AsyncSession, user_ids: Iterable[UUID]) -> dict[UUID, tuple[UserProfile, bool]]:
    ids = list(user_ids)
    if not ids:
        return {}
    rows = await db.execute(
        select(UserProfile, User.is_premium)
        .join(User, User.id == UserProfile.user_id)
        .where(UserProfile.user_id.in_(ids))
    )
    return {profile.user_id: (profile, bool(premium)) for profile, premium in rows.all()}


def round_deadline(match: Match, participant: Optional[MatchParticipant]) -> Optional[datetime]:
    """When the round in play closes for this participant.

    A live match runs one shared clock off the match row. An async match has no
    shared clock — each side's window opens when they are served — so the
    deadline is read from their own participant row.
    """
    if match.status is not MatchStatus.LIVE:
        return None
    started = (
        _aware(match.round_started_at)
        if match.delivery is MatchDelivery.LIVE
        else _aware(participant.round_served_at) if participant else None
    )
    if started is None:
        return None
    return started + timedelta(milliseconds=match.question_time_limit_ms)


async def serialize_match(
    db: AsyncSession,
    match: Match,
    *,
    viewer_id: UUID,
    topic_name: Optional[str] = None,
) -> MatchOut:
    participants = sorted(match.participants, key=lambda p: (p.created_at, str(p.id)))
    profiles = await _profiles_for(db, [p.user_id for p in participants])
    connected = await realtime.connected_user_ids(match.id)

    answered_round = await _participants_answered(db, match.id, match.current_round_index)
    me = next((p for p in participants if p.user_id == viewer_id), None)

    if topic_name is None:
        topic = await db.scalar(select(Topic).where(Topic.id == match.topic_id))
        topic_name = (
            localized_topic_name(topic, normalize_language(match.language)) if topic else "Quiz"
        )

    rows: list[MatchParticipantOut] = []
    for participant in participants:
        profile, is_premium = profiles.get(participant.user_id, (None, False))
        rating_delta = (
            participant.rating_after - participant.rating_before
            if participant.rating_after is not None and participant.rating_before is not None
            else None
        )
        rows.append(
            MatchParticipantOut(
                user_id=participant.user_id,
                player=(
                    _player_brief(profile, is_premium=is_premium)
                    if profile is not None
                    else PlayerBriefOut(user_id=participant.user_id, username="Player")
                ),
                status=participant.status,
                is_host=participant.is_host,
                is_me=participant.user_id == viewer_id,
                is_connected=str(participant.user_id) in connected,
                score=participant.score,
                correct_count=participant.correct_count,
                rounds_answered=participant.rounds_answered,
                best_streak=participant.best_streak,
                answered_current_round=participant.id in answered_round,
                placement=participant.placement,
                outcome=participant.outcome,
                rating_before=participant.rating_before,
                rating_after=participant.rating_after,
                rating_delta=rating_delta,
                xp_earned=participant.xp_earned,
                coins_earned=participant.coins_earned,
            )
        )

    host = next((p for p in participants if p.is_host), None)
    return MatchOut(
        id=match.id,
        code=match.code,
        format=match.format,
        kind=match.kind,
        delivery=match.delivery,
        status=match.status,
        topic_id=match.topic_id,
        topic_name=topic_name,
        difficulty=match.difficulty,
        language=normalize_language(match.language).value,
        question_count=match.question_count,
        question_time_limit_ms=match.question_time_limit_ms,
        max_players=match.max_players,
        current_round_index=match.current_round_index,
        host_user_id=host.user_id if host else match.created_by_user_id,
        participants=rows,
        created_at=_aware(match.created_at),
        started_at=_aware(match.started_at),
        finished_at=_aware(match.finished_at),
        expires_at=_aware(match.expires_at),
        round_deadline_at=round_deadline(match, me),
        server_time=_now(),
        my_rounds_answered=me.rounds_answered if me else 0,
        my_outcome=me.outcome if me else None,
    )


async def _participants_answered(
    db: AsyncSession, match_id: UUID, round_index: int
) -> set[UUID]:
    rows = await db.execute(
        select(MatchAnswer.participant_id).where(
            MatchAnswer.match_id == match_id, MatchAnswer.round_index == round_index
        )
    )
    return {row[0] for row in rows.all()}


# --- Loading ----------------------------------------------------------------


async def load_match(db: AsyncSession, match_id: UUID) -> Match:
    match = await db.scalar(
        select(Match).options(selectinload(Match.participants)).where(Match.id == match_id)
    )
    if match is None:
        raise _err("match_not_found", "Match not found.", status.HTTP_404_NOT_FOUND)
    return match


def participant_of(match: Match, user_id: UUID) -> Optional[MatchParticipant]:
    return next((p for p in match.participants if p.user_id == user_id), None)


def require_participant(match: Match, user_id: UUID) -> MatchParticipant:
    participant = participant_of(match, user_id)
    if participant is None:
        raise _err("not_in_match", "You are not in this match.", status.HTTP_403_FORBIDDEN)
    return participant


# --- Creation ---------------------------------------------------------------


async def create_match(
    db: AsyncSession,
    user: User,
    payload: CreateMatchRequest,
    *,
    kind: MatchKind = MatchKind.FRIENDLY,
    opponent_ids: Sequence[UUID] = (),
) -> Match:
    """Create a duel, a room, or a ranked pairing.

    `opponent_ids` is how the matchmaker seats a ranked pair; a friendly duel
    takes its single opponent from the request body instead.
    """
    settings = get_settings()
    if not settings.multiplayer_enabled:
        raise _err("multiplayer_disabled", "Multiplayer is unavailable.", status.HTTP_503_SERVICE_UNAVAILABLE)

    topic = await db.scalar(
        select(Topic).where(Topic.id == payload.topic_id, Topic.is_active.is_(True))
    )
    if topic is None:
        raise _err("topic_not_found", "Topic not found.", status.HTTP_404_NOT_FOUND)

    profile = user.profile
    language = normalize_language(
        payload.language if payload.language is not None
        else (profile.quiz_language if profile else None)
    )

    invitees = list(opponent_ids)
    if kind is MatchKind.FRIENDLY and payload.opponent_user_id is not None:
        invitees = [payload.opponent_user_id]

    for opponent_id in invitees:
        if opponent_id == user.id:
            raise _err("challenge_self", "You cannot challenge yourself.")
        if kind is MatchKind.FRIENDLY and not await friends.are_friends(db, user.id, opponent_id):
            # Direct challenges are friends-only. Anyone else reaches you
            # through a room code you chose to share, or the ranked queue —
            # both of which you opted into.
            raise _err(
                "not_friends",
                "You can only challenge friends directly.",
                status.HTTP_403_FORBIDDEN,
            )
        if await friends.is_blocked_between(db, user.id, opponent_id):
            raise _err("user_not_found", "Player not found.", status.HTTP_404_NOT_FOUND)

    is_duel = payload.format is MatchFormat.DUEL or kind is MatchKind.RANKED
    max_players = 2 if is_duel else max(2, min(payload.max_players or 4, settings.match_max_players))
    question_count = payload.question_count or settings.match_default_question_count
    question_count = max(
        settings.match_min_question_count, min(question_count, settings.match_max_question_count)
    )

    known_players = [user.id, *invitees]
    question_ids, option_orders, seed = await _build_question_set(
        db,
        topic_id=topic.id,
        difficulty=payload.difficulty,
        language=language,
        count=question_count,
        participant_ids=known_players,
    )

    match = Match(
        id=uuid4(),
        code=None if kind is MatchKind.RANKED else await _unique_room_code(db),
        format=MatchFormat.DUEL if is_duel else MatchFormat.ROOM,
        kind=kind,
        delivery=MatchDelivery.LIVE,
        status=MatchStatus.PENDING,
        created_by_user_id=user.id,
        topic_id=topic.id,
        mode=MATCH_GAME_MODE,
        difficulty=payload.difficulty,
        language=language.value,
        max_players=max_players,
        question_count=question_count,
        question_time_limit_ms=(
            payload.question_time_limit_ms or settings.match_question_time_limit_ms
        ),
        question_ids=[str(q) for q in question_ids],
        option_orders=option_orders,
        seed=seed,
        season_key=ranking.season_key() if kind is MatchKind.RANKED else None,
        expires_at=_now() + timedelta(hours=settings.match_async_expiry_hours),
    )
    db.add(match)
    await db.flush()

    db.add(
        MatchParticipant(
            id=uuid4(),
            match_id=match.id,
            user_id=user.id,
            status=ParticipantStatus.JOINED,
            is_host=True,
            joined_at=_now(),
        )
    )
    for opponent_id in invitees:
        db.add(
            MatchParticipant(
                id=uuid4(),
                match_id=match.id,
                user_id=opponent_id,
                # A ranked pair did not ask for each other, but both opted into
                # the queue, so they are seated rather than invited.
                status=(
                    ParticipantStatus.JOINED
                    if kind is MatchKind.RANKED
                    else ParticipantStatus.INVITED
                ),
                joined_at=_now() if kind is MatchKind.RANKED else None,
            )
        )
    await db.flush()
    await db.refresh(match, ["participants"])

    if kind is MatchKind.RANKED:
        await _begin(db, match)
    else:
        for opponent_id in invitees:
            await notifications.notify(
                db,
                user_id=opponent_id,
                notification_type=NotificationType.MATCH_INVITE,
                actor_user_id=user.id,
                match_id=match.id,
                payload={
                    "topic_name": localized_topic_name(topic, language),
                    "question_count": match.question_count,
                },
                deep_link=match_deep_link(match.id),
                push_params={
                    "actor": (profile.username if profile else "A player"),
                    "topic": localized_topic_name(topic, language),
                },
            )
    return match


async def join_by_code(db: AsyncSession, user: User, code: str) -> Match:
    normalized = "".join(ch for ch in (code or "").upper() if ch.isalnum())
    match = await db.scalar(
        select(Match).options(selectinload(Match.participants)).where(Match.code == normalized)
    )
    if match is None:
        raise _err("match_not_found", "No room with that code.", status.HTTP_404_NOT_FOUND)
    if match.status not in (MatchStatus.PENDING, MatchStatus.LOBBY):
        raise _err("match_closed", "That room has already started.", status.HTTP_409_CONFLICT)

    existing = participant_of(match, user.id)
    if existing is not None:
        if existing.status is ParticipantStatus.DECLINED:
            existing.status = ParticipantStatus.JOINED
            existing.joined_at = _now()
            await db.flush()
        return match

    if await friends.is_blocked_between(db, match.created_by_user_id, user.id):
        raise _err("match_not_found", "No room with that code.", status.HTTP_404_NOT_FOUND)

    seated = sum(
        1 for p in match.participants
        if p.status not in (ParticipantStatus.DECLINED, ParticipantStatus.FORFEITED)
    )
    if seated >= match.max_players:
        raise _err("match_full", "That room is full.", status.HTTP_409_CONFLICT)

    db.add(
        MatchParticipant(
            id=uuid4(),
            match_id=match.id,
            user_id=user.id,
            status=ParticipantStatus.JOINED,
            joined_at=_now(),
        )
    )
    try:
        await db.flush()
    except IntegrityError:
        # Two taps raced the unique (match_id, user_id). Already seated.
        await db.rollback()
        return await load_match(db, match.id)

    await db.refresh(match, ["participants"])
    await _publish_participants(db, match)
    return match


async def respond_to_invite(
    db: AsyncSession, user: User, match_id: UUID, *, accept: bool
) -> Match:
    match = await load_match(db, match_id)
    participant = require_participant(match, user.id)
    if participant.status is not ParticipantStatus.INVITED:
        return match

    if accept:
        participant.status = ParticipantStatus.JOINED
        participant.joined_at = _now()
    else:
        participant.status = ParticipantStatus.DECLINED
        # A declined duel is over; a declined room seat just frees the chair.
        if match.format is MatchFormat.DUEL:
            match.status = MatchStatus.CANCELLED
            match.finished_at = _now()
    await db.flush()
    await _publish_participants(db, match)
    if match.status is MatchStatus.CANCELLED:
        await realtime.publish(match.id, realtime.EVENT_CANCELLED, {"reason": "declined"})
    return match


async def set_ready(db: AsyncSession, user: User, match_id: UUID, *, ready: bool) -> Match:
    match = await load_match(db, match_id)
    participant = require_participant(match, user.id)
    if match.status not in (MatchStatus.PENDING, MatchStatus.LOBBY):
        return match

    participant.status = ParticipantStatus.READY if ready else ParticipantStatus.JOINED
    await db.flush()
    await _publish_participants(db, match)

    seated = [
        p for p in match.participants
        if p.status in (ParticipantStatus.JOINED, ParticipantStatus.READY)
    ]
    everyone_ready = len(seated) >= 2 and all(
        p.status is ParticipantStatus.READY for p in seated
    )
    if everyone_ready:
        await _begin(db, match)
    return match


async def start_match(db: AsyncSession, user: User, match_id: UUID) -> Match:
    """Host override: start with whoever has turned up."""
    match = await load_match(db, match_id)
    participant = require_participant(match, user.id)
    if not participant.is_host:
        raise _err("not_host", "Only the host can start.", status.HTTP_403_FORBIDDEN)
    if match.status not in (MatchStatus.PENDING, MatchStatus.LOBBY):
        raise _err("match_started", "Already started.", status.HTTP_409_CONFLICT)

    seated = [
        p for p in match.participants
        if p.status in (ParticipantStatus.JOINED, ParticipantStatus.READY)
    ]
    if len(seated) < 2:
        raise _err("not_enough_players", "You need at least one opponent.")
    await _begin(db, match)
    return match


async def _begin(db: AsyncSession, match: Match) -> None:
    """Move a lobby into play and open the first round."""
    now = _now()
    settings = get_settings()

    for participant in match.participants:
        if participant.status in (ParticipantStatus.JOINED, ParticipantStatus.READY):
            participant.status = ParticipantStatus.PLAYING
            # Left NULL deliberately: a live match times off the shared clock
            # on the match row, and an async one stamps this when served.
            participant.round_served_at = None
        elif participant.status is ParticipantStatus.INVITED:
            # Never answered the invite. The match starts without them; if they
            # show up later they can still play it out as an async challenge.
            participant.status = ParticipantStatus.INVITED

    match.status = MatchStatus.LIVE
    match.started_at = now
    match.current_round_index = 0
    match.round_started_at = now
    match.expires_at = now + timedelta(hours=settings.match_async_expiry_hours)
    await db.flush()

    await realtime.publish(
        match.id,
        realtime.EVENT_ROUND_START,
        {
            "round_index": 0,
            "total_rounds": match.question_count,
            "deadline_at": (now + timedelta(milliseconds=match.question_time_limit_ms)).isoformat(),
            "server_time": now.isoformat(),
        },
    )


async def convert_to_async(db: AsyncSession, match: Match, *, reason: str) -> None:
    """Degrade a live match whose opponent never connected.

    This is the path that keeps a challenge from evaporating because the friend
    was on the metro. The board is already frozen, so nothing has to change
    except who is waiting for whom: the challenger plays now, and the opponent
    plays the identical questions whenever they open the app.
    """
    if match.delivery is MatchDelivery.ASYNC:
        return
    match.delivery = MatchDelivery.ASYNC
    # Each side now runs its own clock from the moment it is served.
    match.round_started_at = None
    await db.flush()
    await realtime.publish(
        match.id, realtime.EVENT_PARTICIPANT, {"delivery": "async", "reason": reason}
    )
    logger.info("match_converted_to_async", match_id=str(match.id), reason=reason)


# --- Playing ----------------------------------------------------------------


def _round_index_for(match: Match, participant: MatchParticipant) -> int:
    """Which round this player should be answering.

    A live match keeps everyone on the match's shared index. An async match
    lets each side walk their own board, so their progress *is* their index.
    """
    if match.delivery is MatchDelivery.LIVE:
        return match.current_round_index
    return participant.rounds_answered


async def get_round(db: AsyncSession, user: User, match_id: UUID) -> MatchRoundOut:
    """The question this player should see right now.

    Serving is also what starts an async player's clock, which is why this is a
    POST-shaped operation behind a GET-shaped name: re-fetching the same round
    deliberately does *not* restart the timer.
    """
    match = await load_match(db, match_id)
    participant = require_participant(match, user.id)

    if match.status is MatchStatus.PENDING or match.status is MatchStatus.LOBBY:
        raise _err("match_not_started", "The match has not started.", status.HTTP_409_CONFLICT)
    if match.status in (MatchStatus.COMPLETED, MatchStatus.EXPIRED, MatchStatus.CANCELLED):
        raise _err("match_over", "This match is over.", status.HTTP_409_CONFLICT)

    if participant.status is ParticipantStatus.INVITED:
        # Turning up late to a live match that started without them: they get
        # the same board, played asynchronously.
        participant.status = ParticipantStatus.PLAYING
        participant.joined_at = participant.joined_at or _now()
        await convert_to_async(db, match, reason="late_join")

    round_index = _round_index_for(match, participant)
    if round_index >= match.question_count:
        raise _err("match_over", "You have finished this match.", status.HTTP_409_CONFLICT)

    question = await _question_for_round(db, match, round_index)
    order = _normalize_option_order(
        match.option_orders[round_index] if round_index < len(match.option_orders) else None
    )
    by_position = {opt.position: opt.text for opt in question.options}

    now = _now()
    if match.delivery is MatchDelivery.LIVE:
        served = _aware(match.round_started_at) or now
    else:
        # Async has no shared clock, so this round's window opens the first
        # time this player asks for it — not when the previous one was
        # answered. Someone who closes the app mid-match and comes back the
        # next morning must not find they timed out three rounds in their
        # sleep. `round_served_at` is cleared on every answer, so a NULL here
        # means "not yet served" and a refetch after a reconnect finds it set
        # and does not hand back a fresh fifteen seconds.
        if participant.round_served_at is None:
            participant.round_served_at = now
            await db.flush()
        served = _aware(participant.round_served_at) or now

    already = await db.scalar(
        select(MatchAnswer.id).where(
            MatchAnswer.participant_id == participant.id,
            MatchAnswer.round_index == round_index,
        )
    )

    return MatchRoundOut(
        round_index=round_index,
        total_rounds=match.question_count,
        question_id=question.id,
        prompt=question.prompt,
        options=[
            MatchOptionOut(index=i, text=by_position[original])
            for i, original in enumerate(order)
            if original in by_position
        ],
        time_limit_ms=match.question_time_limit_ms,
        deadline_at=served + timedelta(milliseconds=match.question_time_limit_ms),
        served_at=served,
        server_time=now,
        already_answered=bool(already),
    )


async def _question_for_round(db: AsyncSession, match: Match, round_index: int) -> Question:
    try:
        question_id = UUID(str(match.question_ids[round_index]))
    except (IndexError, ValueError, TypeError) as exc:
        raise _err("round_not_found", "Round not found.", status.HTTP_404_NOT_FOUND) from exc

    question = await db.scalar(
        select(Question).options(selectinload(Question.options)).where(Question.id == question_id)
    )
    if question is None:
        raise _err("question_missing", "Question unavailable.", status.HTTP_410_GONE)
    return question


async def submit_answer(
    db: AsyncSession,
    user: User,
    match_id: UUID,
    payload: SubmitMatchAnswerRequest,
) -> MatchAnswerFeedbackOut:
    match = await load_match(db, match_id)
    participant = require_participant(match, user.id)

    if match.status is not MatchStatus.LIVE:
        raise _err("match_not_live", "This match is not in play.", status.HTTP_409_CONFLICT)
    if not await anticheat.check_answer_rate_limit(user.id):
        raise _err("rate_limited", "Slow down.", status.HTTP_429_TOO_MANY_REQUESTS)

    expected_round = _round_index_for(match, participant)
    if payload.round_index != expected_round:
        # Almost always a late answer for a round that already closed. Not an
        # error worth alarming the player about, but not scorable either.
        raise _err("round_closed", "That round has already closed.", status.HTTP_409_CONFLICT)

    question = await _question_for_round(db, match, expected_round)
    order = _normalize_option_order(
        match.option_orders[expected_round] if expected_round < len(match.option_orders) else None
    )
    correct_client_index = order.index(question.correct_option_index) if question.correct_option_index in order else 0

    settings = get_settings()
    served = (
        _aware(match.round_started_at)
        if match.delivery is MatchDelivery.LIVE
        else _aware(participant.round_served_at)
    ) or _now()
    wall_ms = max(0, int((_now() - served).total_seconds() * 1000))
    is_correct = (
        payload.selected_option_index is not None
        and payload.selected_option_index == correct_client_index
    )
    elapsed_ms = anticheat.resolve_answer_elapsed_ms(
        client_elapsed=payload.client_elapsed_ms,
        wall_ms=wall_ms,
        limit_ms=match.question_time_limit_ms,
        grace_ms=settings.match_answer_grace_ms,
        is_correct=is_correct,
    )
    # Past the deadline the answer still records, but as a miss. Refusing it
    # outright would leave the round unanswered and stall the match.
    timed_out = wall_ms > match.question_time_limit_ms + settings.match_answer_grace_ms
    if timed_out:
        is_correct = False

    remaining_ms = max(0, match.question_time_limit_ms - elapsed_ms)
    breakdown = scoring_service.score_answer(
        is_correct=is_correct,
        current_streak=participant.streak,
        remaining_ms=remaining_ms,
        total_ms=match.question_time_limit_ms,
        mode=MATCH_GAME_MODE,
    )
    points = anticheat.clamp_points_awarded(breakdown.points_awarded)

    answer = MatchAnswer(
        id=uuid4(),
        match_id=match.id,
        participant_id=participant.id,
        user_id=user.id,
        round_index=expected_round,
        question_id=question.id,
        selected_option_index=payload.selected_option_index,
        is_correct=is_correct,
        client_elapsed_ms=payload.client_elapsed_ms,
        server_elapsed_ms=elapsed_ms,
        base_points=breakdown.base_points,
        speed_bonus=breakdown.speed_bonus,
        streak_multiplier=Decimal(breakdown.streak_multiplier),
        points_awarded=points,
    )
    db.add(answer)
    try:
        await db.flush()
    except IntegrityError as exc:
        # uq_match_answer_once: a double tap on a flaky connection. The first
        # one counted; report the round as closed rather than scoring twice.
        await db.rollback()
        raise _err(
            "already_answered", "You already answered this round.", status.HTTP_409_CONFLICT
        ) from exc

    participant.score = max(0, participant.score + points)
    participant.streak = breakdown.new_streak
    participant.best_streak = max(participant.best_streak, breakdown.new_streak)
    participant.total_answer_ms += elapsed_ms
    participant.rounds_answered = expected_round + 1
    if is_correct:
        participant.correct_count += 1
    else:
        participant.incorrect_count += 1
    if match.delivery is MatchDelivery.ASYNC:
        # Clear rather than restamp: the next round's clock starts when they
        # ask for it. See the comment in [get_round].
        participant.round_served_at = None
    await db.flush()

    await realtime.publish(
        match.id,
        realtime.EVENT_ROUND_PROGRESS,
        {
            "round_index": expected_round,
            "user_id": str(user.id),
            "answered": True,
            "rounds_answered": participant.rounds_answered,
        },
    )

    closed, finished = await advance_if_due(db, match)

    return MatchAnswerFeedbackOut(
        round_index=expected_round,
        is_correct=is_correct,
        correct_option_index=correct_client_index,
        selected_option_index=payload.selected_option_index,
        points_awarded=points,
        speed_bonus=breakdown.speed_bonus,
        streak=participant.streak,
        score=participant.score,
        explanation=question.explanation,
        round_closed=closed,
        match_finished=finished,
        opponents=await _opponent_states(db, match, expected_round, exclude=user.id, revealed=closed),
        server_time=_now(),
    )


async def _opponent_states(
    db: AsyncSession,
    match: Match,
    round_index: int,
    *,
    exclude: UUID,
    revealed: bool,
) -> list[OpponentRoundStateOut]:
    """What the other players did this round.

    Correctness is withheld until `revealed` — the round has closed for
    everyone. Before that, "they answered" is the whole signal, because
    "they answered correctly" is the answer.
    """
    rows = await db.execute(
        select(MatchAnswer).where(
            MatchAnswer.match_id == match.id, MatchAnswer.round_index == round_index
        )
    )
    by_user = {row.user_id: row for row in rows.scalars().all()}
    out: list[OpponentRoundStateOut] = []
    for participant in match.participants:
        if participant.user_id == exclude or participant.status is ParticipantStatus.DECLINED:
            continue
        answer = by_user.get(participant.user_id)
        out.append(
            OpponentRoundStateOut(
                user_id=participant.user_id,
                answered=answer is not None,
                is_correct=answer.is_correct if (answer and revealed) else None,
                points_awarded=answer.points_awarded if (answer and revealed) else None,
            )
        )
    return out


# --- The round clock --------------------------------------------------------


def _live_players(match: Match) -> list[MatchParticipant]:
    return [p for p in match.participants if p.status in ACTIVE_PARTICIPANT_STATUSES]


async def advance_if_due(db: AsyncSession, match: Match) -> tuple[bool, bool]:
    """Close the current round if it is over. Returns (closed, finished).

    Safe to call from anywhere and as often as you like: the Redis lock makes
    one caller the winner, and the compare-and-set on `current_round_index`
    means even a lock that expired early cannot double-advance.
    """
    if match.status is not MatchStatus.LIVE:
        return (False, False)

    if match.delivery is MatchDelivery.ASYNC:
        # No shared round to close. The match ends when everyone has played out
        # their own board.
        return (False, await _finalize_if_everyone_done(db, match))

    round_index = match.current_round_index
    players = _live_players(match)
    if not players:
        return (False, await _finalize_if_everyone_done(db, match))

    answered = await _participants_answered(db, match.id, round_index)
    everyone_answered = all(p.id in answered for p in players)

    deadline = round_deadline(match, None)
    settings = get_settings()
    expired = deadline is not None and _now() > deadline + timedelta(
        milliseconds=settings.match_answer_grace_ms
    )
    if not everyone_answered and not expired:
        return (False, False)

    if not await realtime.acquire_round_lock(match.id):
        return (False, False)
    try:
        # Re-read under the lock: another replica may have advanced between our
        # check and our claim. Two named columns rather than `db.refresh(match)`
        # — a bare refresh expires the eagerly-loaded `participants`, and the
        # next access to it would attempt a lazy load, which on an AsyncSession
        # raises MissingGreenlet. Here, of all places.
        fresh = (
            await db.execute(
                select(Match.status, Match.current_round_index).where(
                    Match.id == match.id
                )
            )
        ).one_or_none()
        if (
            fresh is None
            or fresh.status is not MatchStatus.LIVE
            or fresh.current_round_index != round_index
        ):
            return (False, False)

        await _close_round(db, match, round_index)
        finished = match.current_round_index >= match.question_count
        if finished:
            await finalize(db, match)
        return (True, finished)
    finally:
        await realtime.release_round_lock(match.id)


async def _close_round(db: AsyncSession, match: Match, round_index: int) -> None:
    """Score the misses, publish the reveal, and open the next round."""
    settings = get_settings()
    now = _now()
    players = _live_players(match)
    answered = await _participants_answered(db, match.id, round_index)

    question = await _question_for_round(db, match, round_index)
    order = _normalize_option_order(
        match.option_orders[round_index] if round_index < len(match.option_orders) else None
    )
    correct_index = order.index(question.correct_option_index) if question.correct_option_index in order else 0

    # Anyone who let the clock run out gets a recorded zero, so the standings
    # and the round history have no holes in them.
    for participant in players:
        if participant.id in answered:
            continue
        db.add(
            MatchAnswer(
                id=uuid4(),
                match_id=match.id,
                participant_id=participant.id,
                user_id=participant.user_id,
                round_index=round_index,
                question_id=question.id,
                selected_option_index=None,
                is_correct=False,
                server_elapsed_ms=match.question_time_limit_ms,
                points_awarded=0,
            )
        )
        participant.streak = 0
        participant.incorrect_count += 1
        participant.rounds_answered = max(participant.rounds_answered, round_index + 1)
        participant.total_answer_ms += match.question_time_limit_ms
    await db.flush()

    results = await db.execute(
        select(MatchAnswer).where(
            MatchAnswer.match_id == match.id, MatchAnswer.round_index == round_index
        )
    )
    await realtime.publish(
        match.id,
        realtime.EVENT_ROUND_END,
        {
            "round_index": round_index,
            "correct_option_index": correct_index,
            "explanation": question.explanation,
            "results": [
                {
                    "user_id": str(row.user_id),
                    "is_correct": row.is_correct,
                    "points_awarded": row.points_awarded,
                    "elapsed_ms": row.server_elapsed_ms,
                }
                for row in results.scalars().all()
            ],
            "scores": {str(p.user_id): p.score for p in match.participants},
            "server_time": now.isoformat(),
        },
    )

    match.current_round_index = round_index + 1
    if match.current_round_index < match.question_count:
        # The next round opens after the reveal pause, so the verdict is
        # readable. Answers arriving before then simply score as instant.
        next_start = now + timedelta(milliseconds=settings.match_round_reveal_ms)
        match.round_started_at = next_start
        await db.flush()
        await realtime.publish(
            match.id,
            realtime.EVENT_ROUND_START,
            {
                "round_index": match.current_round_index,
                "total_rounds": match.question_count,
                "starts_at": next_start.isoformat(),
                "deadline_at": (
                    next_start + timedelta(milliseconds=match.question_time_limit_ms)
                ).isoformat(),
                "server_time": now.isoformat(),
            },
        )
    else:
        match.round_started_at = None
        await db.flush()


async def _finalize_if_everyone_done(db: AsyncSession, match: Match) -> bool:
    players = _live_players(match)
    if not players:
        await finalize(db, match)
        return True
    if all(p.rounds_answered >= match.question_count for p in players):
        await finalize(db, match)
        return True

    # One side has finished and is waiting on the other. Surfacing this as a
    # distinct status is what lets the inbox say "your turn" to the right
    # person rather than showing both a spinner.
    if match.status is MatchStatus.LIVE and any(
        p.rounds_answered >= match.question_count for p in players
    ):
        match.status = MatchStatus.AWAITING_OPPONENT
        await db.flush()
        await _notify_waiting_players(db, match, players)
    return False


async def _notify_waiting_players(
    db: AsyncSession, match: Match, players: Sequence[MatchParticipant]
) -> None:
    """Tell whoever still owes the match a turn.

    This is the notification that makes the async path work at all — without
    it, a challenge sits in an inbox nobody has a reason to open.
    """
    finished = [p for p in players if p.rounds_answered >= match.question_count]
    waiting = [p for p in players if p.rounds_answered < match.question_count]
    if not finished or not waiting:
        return

    profiles = await _profiles_for(db, [p.user_id for p in finished])
    leader = max(finished, key=lambda p: p.score)
    actor_profile = profiles.get(leader.user_id, (None, False))[0]

    for participant in waiting:
        await notifications.notify(
            db,
            user_id=participant.user_id,
            notification_type=NotificationType.MATCH_YOUR_TURN,
            actor_user_id=leader.user_id,
            match_id=match.id,
            payload={"score_to_beat": leader.score},
            deep_link=match_deep_link(match.id),
            push_params={"actor": actor_profile.username if actor_profile else "Your opponent"},
        )


# --- Settlement -------------------------------------------------------------


def _rank_participants(participants: Sequence[MatchParticipant]) -> list[MatchParticipant]:
    """Standings order: score, then speed, then accuracy.

    Total answer time breaks ties because on a seven-question board two players
    drawing on score is common, and "you were quicker" is a result both of them
    accept. Accuracy is the third key for the rare case where the clock is also
    tied.
    """
    return sorted(
        participants,
        key=lambda p: (-p.score, p.total_answer_ms, -p.correct_count),
    )


async def finalize(db: AsyncSession, match: Match) -> None:
    """Settle a finished match exactly once.

    Idempotent by status: a replay — a retried request, a second replica
    noticing the same deadline — returns immediately rather than paying XP
    twice or moving Elo twice.
    """
    if match.status in (MatchStatus.COMPLETED, MatchStatus.EXPIRED, MatchStatus.CANCELLED):
        return

    now = _now()
    scored = [
        p for p in match.participants
        if p.status in ACTIVE_PARTICIPANT_STATUSES or p.status is ParticipantStatus.FINISHED
    ]
    ordered = _rank_participants(scored)

    top_score = ordered[0].score if ordered else 0
    top_time = ordered[0].total_answer_ms if ordered else 0
    winners = [p for p in ordered if p.score == top_score and p.total_answer_ms == top_time]

    for position, participant in enumerate(ordered, start=1):
        participant.placement = position
        participant.status = ParticipantStatus.FINISHED
        participant.finished_at = participant.finished_at or now
        if len(winners) > 1 and participant in winners:
            participant.outcome = MatchOutcome.DRAW
        elif participant is ordered[0]:
            participant.outcome = MatchOutcome.WIN
        else:
            participant.outcome = MatchOutcome.LOSS

    match.status = MatchStatus.COMPLETED
    match.finished_at = now
    match.round_started_at = None
    await db.flush()

    if match.kind is MatchKind.RANKED and len(ordered) == 2 and not match.rating_applied:
        await _apply_ratings(db, match, ordered)

    await _award_progression(db, match, ordered)
    await db.flush()
    await _notify_result(db, match, ordered)

    await realtime.publish(
        match.id,
        realtime.EVENT_FINISHED,
        {
            "standings": [
                {
                    "user_id": str(p.user_id),
                    "placement": p.placement,
                    "score": p.score,
                    "correct_count": p.correct_count,
                    "outcome": p.outcome.value if p.outcome else None,
                    "rating_delta": (
                        p.rating_after - p.rating_before
                        if p.rating_after is not None and p.rating_before is not None
                        else None
                    ),
                    "xp_earned": p.xp_earned,
                }
                for p in ordered
            ],
            "server_time": now.isoformat(),
        },
    )


async def _notify_result(
    db: AsyncSession, match: Match, ordered: Sequence[MatchParticipant]
) -> None:
    """Tell everyone how it ended.

    Skipped for anyone currently connected — they are watching the result
    screen, and a tray notification about a match they can see is noise.
    """
    if len(ordered) < 2:
        return
    connected = await realtime.connected_user_ids(match.id)
    profiles = await _profiles_for(db, [p.user_id for p in ordered])

    for participant in ordered:
        if str(participant.user_id) in connected:
            continue
        opponent = next((p for p in ordered if p.user_id != participant.user_id), None)
        opponent_profile = (
            profiles.get(opponent.user_id, (None, False))[0] if opponent else None
        )
        outcome = participant.outcome.value if participant.outcome else "draw"
        await notifications.notify(
            db,
            user_id=participant.user_id,
            notification_type=NotificationType.MATCH_RESULT,
            actor_user_id=opponent.user_id if opponent else None,
            match_id=match.id,
            payload={
                "outcome": outcome,
                "score": participant.score,
                "opponent_score": opponent.score if opponent else 0,
                "placement": participant.placement,
            },
            deep_link=match_deep_link(match.id),
            push_params={
                "actor": opponent_profile.username if opponent_profile else "your opponent",
                "result": {"win": "You won", "loss": "You lost", "draw": "A draw"}.get(
                    outcome, "Result"
                ),
            },
        )


async def _apply_ratings(
    db: AsyncSession, match: Match, ordered: Sequence[MatchParticipant]
) -> None:
    first, second = ordered[0], ordered[1]
    key = match.season_key or ranking.season_key()

    rating_a = await ranking.get_or_create_rating(db, first.user_id, key=key)
    rating_b = await ranking.get_or_create_rating(db, second.user_id, key=key)

    first.rating_before = rating_a.rating
    second.rating_before = rating_b.rating

    delta_a = ranking.rating_delta(
        rating=rating_a.rating,
        opponent_rating=rating_b.rating,
        outcome=first.outcome or MatchOutcome.DRAW,
        placements_remaining=rating_a.placements_remaining,
    )
    delta_b = ranking.rating_delta(
        rating=rating_b.rating,
        opponent_rating=rating_a.rating,
        outcome=second.outcome or MatchOutcome.DRAW,
        placements_remaining=rating_b.placements_remaining,
    )

    ranking.apply_result(rating_a, delta=delta_a, outcome=first.outcome or MatchOutcome.DRAW)
    ranking.apply_result(rating_b, delta=delta_b, outcome=second.outcome or MatchOutcome.DRAW)

    first.rating_after = rating_a.rating
    second.rating_after = rating_b.rating
    match.rating_applied = True
    await db.flush()


async def _award_progression(
    db: AsyncSession, match: Match, ordered: Sequence[MatchParticipant]
) -> None:
    """XP, coins and lifetime record for everyone who played."""
    user_ids = [p.user_id for p in ordered]
    if not user_ids:
        return

    profiles = {
        p.user_id: p
        for p in (
            await db.execute(select(UserProfile).where(UserProfile.user_id.in_(user_ids)))
        ).scalars().all()
    }
    stats = {
        s.user_id: s
        for s in (
            await db.execute(
                select(PlayerStatistics).where(PlayerStatistics.user_id.in_(user_ids))
            )
        ).scalars().all()
    }

    for participant in ordered:
        xp = XP_PARTICIPATION + (participant.score * XP_PER_100_POINTS) // 100
        coins = COINS_PLAY
        if participant.outcome is MatchOutcome.WIN:
            xp += XP_WIN_BONUS
            coins += COINS_WIN
        elif participant.outcome is MatchOutcome.DRAW:
            xp += XP_DRAW_BONUS
            coins += COINS_DRAW

        participant.xp_earned = xp
        participant.coins_earned = coins

        profile = profiles.get(participant.user_id)
        if profile is not None:
            profile.level, profile.xp = apply_xp(profile.level, profile.xp, xp)
            profile.coins = max(0, profile.coins + coins)

        record = stats.get(participant.user_id)
        if record is not None:
            record.multiplayer_played += 1
            if participant.outcome is MatchOutcome.WIN:
                record.multiplayer_wins += 1
            elif participant.outcome is MatchOutcome.LOSS:
                record.multiplayer_losses += 1
            else:
                record.multiplayer_draws += 1


# --- Leaving and expiry -----------------------------------------------------


async def leave_match(db: AsyncSession, user: User, match_id: UUID) -> Match:
    """Walk out. Keeps whatever was scored so far.

    Forfeiting rather than deleting the row: the opponent played a real game
    and is owed a real result, and in a ranked duel a rage-quit that erased the
    match would be a free escape from a loss.
    """
    match = await load_match(db, match_id)
    participant = require_participant(match, user.id)

    if match.status in (MatchStatus.COMPLETED, MatchStatus.EXPIRED, MatchStatus.CANCELLED):
        return match

    if match.status in (MatchStatus.PENDING, MatchStatus.LOBBY):
        participant.status = ParticipantStatus.DECLINED
        if match.format is MatchFormat.DUEL or participant.is_host:
            match.status = MatchStatus.CANCELLED
            match.finished_at = _now()
    else:
        participant.status = ParticipantStatus.FORFEITED
        participant.finished_at = _now()

    await db.flush()
    await _publish_participants(db, match)

    if match.status is MatchStatus.CANCELLED:
        await realtime.publish(match.id, realtime.EVENT_CANCELLED, {"reason": "host_left"})
    else:
        remaining = _live_players(match)
        if len(remaining) <= 1:
            await finalize(db, match)
    return match


async def expire_stale(db: AsyncSession, *, limit: int = 100) -> int:
    """Close out matches nobody is coming back to. Returns how many.

    Run from the background worker. Two cases: a lobby nobody joined, which is
    simply cancelled, and an async challenge whose opponent never played, which
    is settled on the scores that exist so the player who *did* turn up gets
    their result rather than an entry that sits in the list forever.
    """
    now = _now()
    settings = get_settings()

    stale = (
        await db.execute(
            select(Match)
            .options(selectinload(Match.participants))
            .where(Match.status.in_(tuple(OPEN_MATCH_STATUSES)), Match.expires_at < now)
            .limit(limit)
        )
    ).scalars().all()

    closed = 0
    for match in stale:
        played = [p for p in match.participants if p.rounds_answered > 0]
        if not played:
            match.status = MatchStatus.EXPIRED
            match.finished_at = now
            await realtime.publish(match.id, realtime.EVENT_CANCELLED, {"reason": "expired"})
        else:
            for participant in match.participants:
                if participant.rounds_answered < match.question_count:
                    participant.status = ParticipantStatus.FORFEITED
            await finalize(db, match)
        closed += 1

    # Live lobbies that never filled: separate sweep, much shorter fuse.
    lobby_cutoff = now - timedelta(seconds=settings.match_lobby_timeout_seconds)
    idle = (
        await db.execute(
            select(Match)
            .options(selectinload(Match.participants))
            .where(
                Match.status.in_((MatchStatus.PENDING, MatchStatus.LOBBY)),
                Match.created_at < lobby_cutoff,
            )
            .limit(limit)
        )
    ).scalars().all()
    for match in idle:
        if match.kind is MatchKind.RANKED:
            match.status = MatchStatus.CANCELLED
            match.finished_at = now
            closed += 1
            continue
        # A friendly challenge nobody answered becomes an async challenge
        # rather than dying: the invite is still sitting in their inbox.
        match.status = MatchStatus.AWAITING_OPPONENT
        await convert_to_async(db, match, reason="lobby_timeout")
        closed += 1

    await db.flush()
    return closed


async def _publish_participants(db: AsyncSession, match: Match) -> None:
    await db.refresh(match, ["participants"])
    await realtime.publish(
        match.id,
        realtime.EVENT_PARTICIPANT,
        {
            "participants": [
                {
                    "user_id": str(p.user_id),
                    "status": p.status.value,
                    "score": p.score,
                    "rounds_answered": p.rounds_answered,
                    "is_host": p.is_host,
                }
                for p in match.participants
            ]
        },
    )


# --- Reads ------------------------------------------------------------------


async def get_state(db: AsyncSession, user: User, match_id: UUID) -> MatchOut:
    match = await load_match(db, match_id)
    require_participant(match, user.id)
    # Polling is also a clock tick: a match whose deadline passed while nobody
    # was connected advances the moment somebody looks at it.
    await advance_if_due(db, match)
    return await serialize_match(db, match, viewer_id=user.id)


async def get_result(db: AsyncSession, user: User, match_id: UUID) -> MatchResultOut:
    match = await load_match(db, match_id)
    me = require_participant(match, user.id)
    state = await serialize_match(db, match, viewer_id=user.id)
    standings = sorted(
        state.participants, key=lambda p: (p.placement is None, p.placement or 0)
    )
    return MatchResultOut(
        match=state,
        standings=standings,
        my_outcome=me.outcome,
        my_placement=me.placement,
        rating_delta=(
            me.rating_after - me.rating_before
            if me.rating_after is not None and me.rating_before is not None
            else None
        ),
        xp_earned=me.xp_earned,
        coins_earned=me.coins_earned,
    )


async def list_for_user(
    db: AsyncSession, user: User, *, limit: int = 20
) -> tuple[list[MatchOut], list[MatchOut]]:
    """Split this player's matches into "needs you" and "finished"."""
    rows = (
        await db.execute(
            select(Match)
            .options(selectinload(Match.participants))
            .join(MatchParticipant, MatchParticipant.match_id == Match.id)
            .where(MatchParticipant.user_id == user.id)
            .order_by(Match.created_at.desc())
            .limit(limit * 2)
        )
    ).scalars().unique().all()

    active: list[MatchOut] = []
    recent: list[MatchOut] = []
    for match in rows:
        state = await serialize_match(db, match, viewer_id=user.id)
        if match.status in OPEN_MATCH_STATUSES:
            active.append(state)
        elif len(recent) < limit:
            recent.append(state)
    return active[:limit], recent


async def count_open_challenges(db: AsyncSession, user_id: UUID) -> int:
    return int(
        await db.scalar(
            select(func.count())
            .select_from(MatchParticipant)
            .join(Match, Match.id == MatchParticipant.match_id)
            .where(
                MatchParticipant.user_id == user_id,
                Match.status.in_(tuple(OPEN_MATCH_STATUSES)),
            )
        )
        or 0
    )
