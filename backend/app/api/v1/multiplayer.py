"""Matches, the ranked queue, and the realtime socket."""

from __future__ import annotations

import asyncio
import contextlib
from datetime import timedelta
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect, status
from sqlalchemy import func, select

from app.auth.deps import CurrentUser, DbSession
from app.core.config import get_settings
from app.core.database import session_scope
from app.core.languages import normalize_language
from app.core.logging import get_logger
from app.models import MatchParticipant, MatchStatus, PlayerRating, User, UserProfile
from app.schemas.multiplayer import (
    CreateMatchRequest,
    JoinMatchRequest,
    MatchAnswerFeedbackOut,
    MatchListResponse,
    MatchOut,
    MatchResultOut,
    MatchRoundOut,
    PlayerBriefOut,
    QueueJoinRequest,
    QueueTicketResponse,
    RankedLeaderboardEntryOut,
    RankedLeaderboardResponse,
    RankedProfileOut,
    RealtimeTicketResponse,
    SubmitMatchAnswerRequest,
)
from app.services import matches, matchmaking, ranking, realtime

logger = get_logger(__name__)

router = APIRouter(prefix="/multiplayer", tags=["multiplayer"])


# --- Matches ----------------------------------------------------------------


@router.post("/matches", response_model=MatchOut, status_code=status.HTTP_201_CREATED)
async def create_match(
    payload: CreateMatchRequest,
    user: CurrentUser,
    db: DbSession,
) -> MatchOut:
    match = await matches.create_match(db, user, payload)
    return await matches.serialize_match(db, match, viewer_id=user.id)


@router.get("/matches", response_model=MatchListResponse)
async def list_matches(user: CurrentUser, db: DbSession) -> MatchListResponse:
    active, recent = await matches.list_for_user(db, user)
    return MatchListResponse(active=active, recent=recent)


@router.post("/matches/join", response_model=MatchOut)
async def join_match(
    payload: JoinMatchRequest,
    user: CurrentUser,
    db: DbSession,
) -> MatchOut:
    match = await matches.join_by_code(db, user, payload.code)
    return await matches.serialize_match(db, match, viewer_id=user.id)


@router.get("/matches/{match_id}", response_model=MatchOut)
async def get_match(match_id: UUID, user: CurrentUser, db: DbSession) -> MatchOut:
    return await matches.get_state(db, user, match_id)


@router.post("/matches/{match_id}/accept", response_model=MatchOut)
async def accept_match(match_id: UUID, user: CurrentUser, db: DbSession) -> MatchOut:
    match = await matches.respond_to_invite(db, user, match_id, accept=True)
    return await matches.serialize_match(db, match, viewer_id=user.id)


@router.post("/matches/{match_id}/decline", response_model=MatchOut)
async def decline_match(match_id: UUID, user: CurrentUser, db: DbSession) -> MatchOut:
    match = await matches.respond_to_invite(db, user, match_id, accept=False)
    return await matches.serialize_match(db, match, viewer_id=user.id)


@router.post("/matches/{match_id}/ready", response_model=MatchOut)
async def set_ready(
    match_id: UUID,
    user: CurrentUser,
    db: DbSession,
    ready: bool = Query(default=True),
) -> MatchOut:
    match = await matches.set_ready(db, user, match_id, ready=ready)
    return await matches.serialize_match(db, match, viewer_id=user.id)


@router.post("/matches/{match_id}/start", response_model=MatchOut)
async def start_match(match_id: UUID, user: CurrentUser, db: DbSession) -> MatchOut:
    match = await matches.start_match(db, user, match_id)
    return await matches.serialize_match(db, match, viewer_id=user.id)


@router.get("/matches/{match_id}/round", response_model=MatchRoundOut)
async def get_round(match_id: UUID, user: CurrentUser, db: DbSession) -> MatchRoundOut:
    return await matches.get_round(db, user, match_id)


@router.post("/matches/{match_id}/answer", response_model=MatchAnswerFeedbackOut)
async def submit_answer(
    match_id: UUID,
    payload: SubmitMatchAnswerRequest,
    user: CurrentUser,
    db: DbSession,
) -> MatchAnswerFeedbackOut:
    return await matches.submit_answer(db, user, match_id, payload)


@router.post("/matches/{match_id}/leave", response_model=MatchOut)
async def leave_match(match_id: UUID, user: CurrentUser, db: DbSession) -> MatchOut:
    match = await matches.leave_match(db, user, match_id)
    return await matches.serialize_match(db, match, viewer_id=user.id)


@router.get("/matches/{match_id}/result", response_model=MatchResultOut)
async def get_result(match_id: UUID, user: CurrentUser, db: DbSession) -> MatchResultOut:
    return await matches.get_result(db, user, match_id)


# --- Ranked -----------------------------------------------------------------


@router.get("/ranked/me", response_model=RankedProfileOut)
async def my_rank(user: CurrentUser, db: DbSession) -> RankedProfileOut:
    row = await ranking.get_or_create_rating(db, user.id)
    tier = ranking.tier_for(row.rating, placements_remaining=row.placements_remaining)
    upcoming = ranking.next_tier(row.rating)

    better = int(
        await db.scalar(
            select(func.count())
            .select_from(PlayerRating)
            .where(
                PlayerRating.season_key == row.season_key,
                PlayerRating.rating > row.rating,
                PlayerRating.placements_remaining == 0,
            )
        )
        or 0
    )
    return RankedProfileOut(
        season_key=row.season_key,
        rating=row.rating,
        peak_rating=row.peak_rating,
        tier=tier.code,
        tier_name=tier.name,
        tier_icon=tier.icon,
        next_tier=upcoming.code if upcoming else None,
        next_tier_at=upcoming.min_rating if upcoming else None,
        placements_remaining=row.placements_remaining,
        matches_played=row.matches_played,
        wins=row.wins,
        losses=row.losses,
        draws=row.draws,
        win_streak=row.win_streak,
        rank=(better + 1) if row.placements_remaining == 0 else None,
    )


@router.get("/ranked/leaderboard", response_model=RankedLeaderboardResponse)
async def ranked_leaderboard(
    user: CurrentUser,
    db: DbSession,
    limit: int = Query(default=50, ge=1, le=100),
) -> RankedLeaderboardResponse:
    key = ranking.season_key()
    rows = (
        await db.execute(
            select(PlayerRating, UserProfile, User.is_premium)
            .join(UserProfile, UserProfile.user_id == PlayerRating.user_id)
            .join(User, User.id == PlayerRating.user_id)
            .where(
                PlayerRating.season_key == key,
                # Provisional ratings are noise on a ladder — they move by 48 a
                # game and would fill the top on a lucky streak.
                PlayerRating.placements_remaining == 0,
            )
            .order_by(PlayerRating.rating.desc(), PlayerRating.wins.desc())
            .limit(limit)
        )
    ).all()

    items: list[RankedLeaderboardEntryOut] = []
    me: Optional[RankedLeaderboardEntryOut] = None
    for index, (rating_row, profile, is_premium) in enumerate(rows, start=1):
        tier = ranking.tier_for(rating_row.rating)
        entry = RankedLeaderboardEntryOut(
            rank=index,
            player=PlayerBriefOut(
                user_id=profile.user_id,
                username=profile.username,
                display_name=profile.display_name,
                avatar_id=profile.avatar_id,
                level=profile.level,
                is_premium=bool(is_premium),
                rating=rating_row.rating,
                tier=tier.code,
                tier_icon=tier.icon,
            ),
            rating=rating_row.rating,
            wins=rating_row.wins,
            losses=rating_row.losses,
            is_me=profile.user_id == user.id,
        )
        items.append(entry)
        if entry.is_me:
            me = entry

    return RankedLeaderboardResponse(season_key=key, items=items, me=me)


@router.post("/ranked/queue", response_model=QueueTicketResponse)
async def join_queue(
    payload: QueueJoinRequest,
    user: CurrentUser,
    db: DbSession,
) -> QueueTicketResponse:
    return await matchmaking.join_queue(
        db,
        user,
        language=normalize_language(payload.language) if payload.language else None,
    )


@router.get("/ranked/queue", response_model=QueueTicketResponse)
async def poll_queue(user: CurrentUser, db: DbSession) -> QueueTicketResponse:
    return await matchmaking.poll_queue(db, user)


@router.delete("/ranked/queue", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def leave_queue(user: CurrentUser) -> None:
    await matchmaking.leave_queue(user)


# --- Realtime ---------------------------------------------------------------


@router.post("/realtime/ticket", response_model=RealtimeTicketResponse)
async def realtime_ticket(user: CurrentUser) -> RealtimeTicketResponse:
    settings = get_settings()
    ticket = await realtime.issue_ticket(user.id)
    return RealtimeTicketResponse(
        ticket=ticket,
        url=f"{settings.api_prefix}/multiplayer/realtime/ws",
        expires_in_seconds=settings.realtime_ticket_ttl_seconds,
    )


class _Writer:
    """Serializes every send on one socket.

    Two tasks write to a live socket — the event pump and the heartbeat reply —
    and Starlette's `send` is not safe to call concurrently: interleaved frames
    surface as an ASGI protocol error that kills the connection mid-round. The
    lock is what makes "the pump owns the socket" true regardless of who is
    replying to a ping.
    """

    def __init__(self, websocket: WebSocket) -> None:
        self._websocket = websocket
        self._lock = asyncio.Lock()

    async def send(self, payload: dict) -> None:
        async with self._lock:
            await self._websocket.send_json(payload)


@router.websocket("/realtime/ws")
async def realtime_socket(
    websocket: WebSocket,
    ticket: str = Query(...),
    match_id: Optional[UUID] = Query(default=None),
    last_event_id: Optional[str] = Query(default=None),
) -> None:
    """Live feed for one match, or for this player's own inbox.

    Authenticated by a single-use ticket rather than a bearer token, because a
    WebSocket URL's query string is written into proxy logs and Cloudflare
    analytics and an access token there outlives the connection by an hour.

    Omitting `match_id` subscribes to the player's own channel instead: friend
    requests, challenges and results, delivered while the app is open. That is
    one connection held by the shell for the whole session, which is why it is
    the same endpoint rather than a second one — a client that can hold one
    socket can hold this one.

    The socket is read-only for game state. Answers go over HTTP, so the
    transaction that scores them is the same one every other write uses and a
    dropped socket can never lose a submitted answer.
    """
    user_id = await realtime.redeem_ticket(ticket)
    if user_id is None:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="invalid_ticket")
        return

    if match_id is not None:
        async with session_scope() as db:
            seat = await db.scalar(
                select(MatchParticipant.id).where(
                    MatchParticipant.match_id == match_id,
                    MatchParticipant.user_id == user_id,
                )
            )
        if seat is None:
            await websocket.close(
                code=status.WS_1008_POLICY_VIOLATION, reason="not_a_participant"
            )
            return
        channel = realtime.stream_key(match_id)
    else:
        channel = realtime.user_stream_key(user_id)

    await websocket.accept()
    writer = _Writer(websocket)
    if match_id is not None:
        await realtime.touch_presence(match_id, user_id)
    await realtime.mark_online(user_id)

    # Replay anything missed while disconnected, before joining the live feed.
    # Without this a reconnect loses whatever landed during the gap, which on a
    # mobile network is routinely a whole round.
    cursor = last_event_id or "$"
    if last_event_id:
        for event in await realtime.history(channel, after_id=last_event_id):
            await writer.send(event.to_json())
            cursor = event.id

    subscriber = await realtime.hub.subscribe(channel, last_id=cursor)
    pump = asyncio.create_task(_pump(writer, subscriber), name="realtime-pump")
    reader = asyncio.create_task(
        _reader(writer, websocket, match_id, user_id), name="realtime-reader"
    )
    # Only a match has a clock to drive.
    ticker = (
        asyncio.create_task(_tick(match_id, user_id), name="realtime-tick")
        if match_id is not None
        else None
    )
    tasks = [t for t in (pump, reader, ticker) if t is not None]

    try:
        # Whichever of the two finishes first ends the connection. Supervising
        # the pump and not only the read loop is the point: a pump that died
        # left the old code with a socket the client still believed was healthy,
        # so it kept its polling fallback switched off and simply stopped
        # updating. The ticker is deliberately not supervised — it is a clock,
        # and it retries its own failures.
        await asyncio.wait({pump, reader}, return_when=asyncio.FIRST_COMPLETED)
    except Exception as exc:  # noqa: BLE001
        logger.info("realtime_socket_closed", error=str(exc))
    finally:
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        await realtime.hub.unsubscribe(subscriber)
        if match_id is not None:
            await realtime.clear_presence(match_id, user_id)
        with contextlib.suppress(Exception):
            await websocket.close()


async def _pump(writer: _Writer, subscriber: realtime.Subscriber) -> None:
    """Forward events to this socket until it dies.

    A None on the queue means the hub gave up on this subscriber: returning
    closes the socket, and the client reconnects with its cursor and replays
    the gap over `last_event_id`.
    """
    while True:
        event = await subscriber.queue.get()
        if event is None:
            return
        await writer.send(event.to_json())


async def _reader(
    writer: _Writer,
    websocket: WebSocket,
    match_id: Optional[UUID],
    user_id: UUID,
) -> None:
    """Consume client heartbeats, and notice when they stop.

    The read is bounded by a timeout rather than left to block forever. A phone
    that loses signal or is killed from the task switcher leaves a half-open
    TCP connection that no amount of waiting resolves, and every one of those
    holds a presence key saying the player is still here — which is exactly how
    a match ends up waiting on someone who left.
    """
    settings = get_settings()
    # Two missed heartbeats plus slack: prompt enough that an abandoned match
    # closes while the opponent is still looking at it, loose enough that a
    # tunnel or a backgrounded app does not get reaped mid-round.
    idle_timeout = max(30.0, settings.realtime_heartbeat_seconds * 2.5)

    try:
        while True:
            try:
                message = await asyncio.wait_for(
                    websocket.receive_json(), timeout=idle_timeout
                )
            except asyncio.TimeoutError:
                logger.info("realtime_socket_idle_timeout", user_id=str(user_id))
                return
            if isinstance(message, dict) and message.get("type") == "ping":
                if match_id is not None:
                    await realtime.touch_presence(match_id, user_id)
                await realtime.mark_online(user_id)
                await writer.send({"type": "pong"})
    except WebSocketDisconnect:
        return
    except Exception as exc:  # noqa: BLE001
        logger.debug("realtime_reader_closed", error=str(exc))
        return


async def _tick(match_id: UUID, user_id: UUID) -> None:
    """Drive the round clock while at least one player is connected.

    Nothing else would: a round whose deadline passes with both players idle
    has no request to ride on. The advance itself is idempotent and lock
    guarded, so every connected client running this is harmless.

    It sleeps *to the deadline* rather than polling on a fixed interval. A
    half-second poll would be two queries a second per connected socket — a
    hundred players is two hundred queries a second to learn nothing — whereas
    waking when there is actually something to decide costs about one query per
    round per client.
    """
    settings = get_settings()
    grace = timedelta(milliseconds=settings.match_answer_grace_ms)

    while True:
        delay = 5.0
        try:
            async with session_scope() as db:
                match = await matches.load_match(db, match_id)
                if match.status in (
                    MatchStatus.COMPLETED,
                    MatchStatus.EXPIRED,
                    MatchStatus.CANCELLED,
                ):
                    return
                if match.status is not MatchStatus.LIVE:
                    # A lobby has no clock; check back rarely.
                    delay = 5.0
                else:
                    deadline = matches.round_deadline(match, None)
                    if deadline is None:
                        delay = 1.0
                    else:
                        remaining = (deadline + grace - matches._now()).total_seconds()
                        if remaining <= 0:
                            await matches.advance_if_due(db, match)
                            # A closed round opens the next one after the reveal
                            # pause; look again once that has elapsed.
                            delay = max(0.25, settings.match_round_reveal_ms / 1000)
                        else:
                            delay = min(remaining + 0.25, 30.0)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            logger.debug("realtime_tick_failed", error=str(exc), user_id=str(user_id))
            delay = 3.0
        await asyncio.sleep(delay)
