"""The social graph: friend requests, blocks, discovery.

Two rules run through every function here and are worth stating once.

**A block is stronger than a friendship.** If either side has blocked the
other, they cannot see each other in search, cannot request, cannot invite, and
any existing friendship is dissolved. Every read path filters on this, not just
the write paths, because the failure mode of getting it wrong is that someone a
player deliberately walked away from turns up in their game.

**Crossed requests become a friendship.** If A requests B while B's request to
A is already pending, the second request accepts the first rather than
erroring. Anything else asks two people who have both said yes to work out
which of them should press a different button.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Iterable, Optional
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import and_, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    Friendship,
    FriendshipStatus,
    Match,
    MatchFormat,
    MatchOutcome,
    MatchParticipant,
    MatchStatus,
    User,
    UserBlock,
    UserProfile,
)
from app.services.usernames import find_by_friend_code, username_skeleton

#: Ceiling on one player's friend list. High enough that nobody real hits it,
#: low enough that a scripted account cannot make the friends query expensive
#: for everyone else.
MAX_FRIENDS = 500
#: Outstanding requests one player may have in flight. This is the actual
#: anti-spam lever — blocking is a response, and a response is too late.
MAX_PENDING_SENT = 50
SEARCH_RESULT_LIMIT = 20


def _err(code: str, message: str, http_status: int = status.HTTP_400_BAD_REQUEST) -> HTTPException:
    return HTTPException(status_code=http_status, detail={"code": code, "message": message})


# --- Blocks -----------------------------------------------------------------


async def blocked_user_ids(db: AsyncSession, user_id: UUID) -> set[UUID]:
    """Everyone this player cannot interact with, in either direction.

    Symmetric on purpose: a player who blocked someone should not see them, and
    a player who *was* blocked should not be able to tell — an account that
    vanishes from search is far less inflammatory than one that returns an
    explicit "you are blocked".
    """
    rows = await db.execute(
        select(UserBlock.blocker_id, UserBlock.blocked_id).where(
            or_(UserBlock.blocker_id == user_id, UserBlock.blocked_id == user_id)
        )
    )
    out: set[UUID] = set()
    for blocker_id, blocked_id in rows.all():
        out.add(blocked_id if blocker_id == user_id else blocker_id)
    return out


async def is_blocked_between(db: AsyncSession, a: UUID, b: UUID) -> bool:
    return bool(
        await db.scalar(
            select(UserBlock.id)
            .where(
                or_(
                    and_(UserBlock.blocker_id == a, UserBlock.blocked_id == b),
                    and_(UserBlock.blocker_id == b, UserBlock.blocked_id == a),
                )
            )
            .limit(1)
        )
    )


async def block_user(db: AsyncSession, user_id: UUID, target_id: UUID) -> None:
    """Block someone, dissolving any friendship or pending request first.

    The friendship is cancelled rather than deleted so the pair's history stays
    auditable, and cancelling frees the partial-unique slot — otherwise
    unblocking later would leave them permanently unable to become friends.
    """
    if user_id == target_id:
        raise _err("block_self", "You cannot block yourself.")

    edge = await _find_edge(db, user_id, target_id)
    if edge is not None and edge.status in (
        FriendshipStatus.PENDING,
        FriendshipStatus.ACCEPTED,
    ):
        edge.status = FriendshipStatus.CANCELLED
        edge.responded_at = datetime.now(timezone.utc)

    existing = await db.scalar(
        select(UserBlock).where(
            UserBlock.blocker_id == user_id, UserBlock.blocked_id == target_id
        )
    )
    if existing is None:
        db.add(UserBlock(id=uuid4(), blocker_id=user_id, blocked_id=target_id))
    await db.flush()


async def unblock_user(db: AsyncSession, user_id: UUID, target_id: UUID) -> None:
    row = await db.scalar(
        select(UserBlock).where(
            UserBlock.blocker_id == user_id, UserBlock.blocked_id == target_id
        )
    )
    if row is not None:
        await db.delete(row)
        await db.flush()


# --- Friendship edges -------------------------------------------------------


async def _find_edge(db: AsyncSession, a: UUID, b: UUID) -> Optional[Friendship]:
    """The most recent friendship row between two players, either direction."""
    return await db.scalar(
        select(Friendship)
        .where(
            or_(
                and_(Friendship.requester_id == a, Friendship.addressee_id == b),
                and_(Friendship.requester_id == b, Friendship.addressee_id == a),
            )
        )
        .order_by(Friendship.created_at.desc())
        .limit(1)
    )


async def are_friends(db: AsyncSession, a: UUID, b: UUID) -> bool:
    edge = await _find_edge(db, a, b)
    return edge is not None and edge.status is FriendshipStatus.ACCEPTED


async def friend_ids(db: AsyncSession, user_id: UUID) -> list[UUID]:
    rows = await db.execute(
        select(Friendship.requester_id, Friendship.addressee_id).where(
            Friendship.status == FriendshipStatus.ACCEPTED,
            or_(Friendship.requester_id == user_id, Friendship.addressee_id == user_id),
        )
    )
    return [
        addressee if requester == user_id else requester
        for requester, addressee in rows.all()
    ]


async def send_request(db: AsyncSession, requester_id: UUID, addressee_id: UUID) -> Friendship:
    if requester_id == addressee_id:
        raise _err("friend_self", "You cannot add yourself.")

    target = await db.scalar(
        select(User.id).where(User.id == addressee_id, User.is_active.is_(True))
    )
    if not target:
        raise _err("user_not_found", "Player not found.", status.HTTP_404_NOT_FOUND)

    if await is_blocked_between(db, requester_id, addressee_id):
        # Deliberately the same error a missing account gives. Confirming that
        # a block exists tells the blocked party exactly who blocked them.
        raise _err("user_not_found", "Player not found.", status.HTTP_404_NOT_FOUND)

    existing = await _find_edge(db, requester_id, addressee_id)
    if existing is not None:
        if existing.status is FriendshipStatus.ACCEPTED:
            raise _err("already_friends", "You are already friends.", status.HTTP_409_CONFLICT)
        if existing.status is FriendshipStatus.PENDING:
            if existing.addressee_id == requester_id:
                # They asked first — this is an acceptance, not a new request.
                return await respond_to_request(db, requester_id, existing.id, accept=True)
            raise _err("request_pending", "Request already sent.", status.HTTP_409_CONFLICT)

    await _assert_capacity(db, requester_id)

    edge = Friendship(
        id=uuid4(),
        requester_id=requester_id,
        addressee_id=addressee_id,
        status=FriendshipStatus.PENDING,
    )
    db.add(edge)
    try:
        await db.flush()
    except IntegrityError as exc:
        # Two requests raced into the partial-unique pair slot. The other one
        # won; report it the same way a sequential duplicate would be.
        await db.rollback()
        raise _err(
            "request_pending", "Request already sent.", status.HTTP_409_CONFLICT
        ) from exc
    return edge


async def _assert_capacity(db: AsyncSession, user_id: UUID) -> None:
    accepted = await db.scalar(
        select(func.count())
        .select_from(Friendship)
        .where(
            Friendship.status == FriendshipStatus.ACCEPTED,
            or_(Friendship.requester_id == user_id, Friendship.addressee_id == user_id),
        )
    )
    if int(accepted or 0) >= MAX_FRIENDS:
        raise _err("friends_full", "Your friend list is full.", status.HTTP_409_CONFLICT)

    pending = await db.scalar(
        select(func.count())
        .select_from(Friendship)
        .where(
            Friendship.requester_id == user_id,
            Friendship.status == FriendshipStatus.PENDING,
        )
    )
    if int(pending or 0) >= MAX_PENDING_SENT:
        raise _err(
            "too_many_requests",
            "You have too many pending requests.",
            status.HTTP_429_TOO_MANY_REQUESTS,
        )


async def respond_to_request(
    db: AsyncSession,
    user_id: UUID,
    friendship_id: UUID,
    *,
    accept: bool,
) -> Friendship:
    edge = await db.scalar(select(Friendship).where(Friendship.id == friendship_id))
    if edge is None or edge.addressee_id != user_id:
        raise _err("request_not_found", "Request not found.", status.HTTP_404_NOT_FOUND)
    if edge.status is not FriendshipStatus.PENDING:
        raise _err("request_closed", "That request is no longer open.", status.HTTP_409_CONFLICT)
    if accept and await is_blocked_between(db, edge.requester_id, edge.addressee_id):
        raise _err("user_not_found", "Player not found.", status.HTTP_404_NOT_FOUND)

    if accept:
        await _assert_capacity(db, user_id)
    edge.status = FriendshipStatus.ACCEPTED if accept else FriendshipStatus.DECLINED
    edge.responded_at = datetime.now(timezone.utc)
    await db.flush()
    return edge


async def cancel_request(db: AsyncSession, user_id: UUID, friendship_id: UUID) -> None:
    edge = await db.scalar(select(Friendship).where(Friendship.id == friendship_id))
    if edge is None or edge.requester_id != user_id:
        raise _err("request_not_found", "Request not found.", status.HTTP_404_NOT_FOUND)
    if edge.status is not FriendshipStatus.PENDING:
        raise _err("request_closed", "That request is no longer open.", status.HTTP_409_CONFLICT)
    edge.status = FriendshipStatus.CANCELLED
    edge.responded_at = datetime.now(timezone.utc)
    await db.flush()


async def unfriend(db: AsyncSession, user_id: UUID, other_id: UUID) -> None:
    edge = await _find_edge(db, user_id, other_id)
    if edge is None or edge.status is not FriendshipStatus.ACCEPTED:
        raise _err("not_friends", "You are not friends.", status.HTTP_404_NOT_FOUND)
    edge.status = FriendshipStatus.CANCELLED
    edge.responded_at = datetime.now(timezone.utc)
    await db.flush()


# --- Discovery --------------------------------------------------------------


async def search_players(
    db: AsyncSession,
    user_id: UUID,
    query: str,
    *,
    limit: int = SEARCH_RESULT_LIMIT,
) -> list[UserProfile]:
    """Find players by username or friend code.

    A friend code is matched exactly; a username is matched as a prefix on the
    folded skeleton, so searching `ravi` finds `R4vi` — the same folding that
    stops impersonation also makes search forgiving of how a name was styled.
    """
    term = (query or "").strip()
    if len(term) < 2:
        return []

    excluded = await blocked_user_ids(db, user_id)
    excluded.add(user_id)

    by_code = await find_by_friend_code(db, term)
    if by_code is not None and by_code.user_id not in excluded:
        return [by_code]

    skeleton = username_skeleton(term)
    if not skeleton:
        return []

    stmt = (
        select(UserProfile)
        .join(User, User.id == UserProfile.user_id)
        .where(
            User.is_active.is_(True),
            UserProfile.username_skeleton.like(f"{skeleton}%"),
        )
        # Exact matches first, then shortest — so `ravi` outranks `ravikumar`.
        .order_by(
            (UserProfile.username_skeleton == skeleton).desc(),
            func.length(UserProfile.username_skeleton),
        )
        .limit(limit)
    )
    if excluded:
        stmt = stmt.where(UserProfile.user_id.notin_(excluded))
    return list((await db.execute(stmt)).scalars().all())


# --- Head-to-head -----------------------------------------------------------


async def head_to_head(
    db: AsyncSession,
    user_id: UUID,
    opponent_ids: Iterable[UUID],
) -> dict[UUID, dict[str, int]]:
    """This player's duel record against each of `opponent_ids`.

    One grouped query for the whole friend list rather than one per row: the
    friends screen renders "3-1 to you" on every tile, and doing that per-friend
    is how a list screen turns into fifty round trips.
    """
    ids = [i for i in opponent_ids]
    if not ids:
        return {}

    mine = MatchParticipant.__table__.alias("mine")
    theirs = MatchParticipant.__table__.alias("theirs")

    rows = await db.execute(
        select(theirs.c.user_id, mine.c.outcome, func.count())
        .select_from(
            mine.join(theirs, and_(theirs.c.match_id == mine.c.match_id,
                                   theirs.c.user_id != mine.c.user_id))
            .join(Match, Match.id == mine.c.match_id)
        )
        .where(
            mine.c.user_id == user_id,
            theirs.c.user_id.in_(ids),
            Match.status == MatchStatus.COMPLETED,
            Match.format == MatchFormat.DUEL,
        )
        .group_by(theirs.c.user_id, mine.c.outcome)
    )

    out: dict[UUID, dict[str, int]] = {
        opponent_id: {"wins": 0, "losses": 0, "draws": 0} for opponent_id in ids
    }
    for opponent_id, outcome, count in rows.all():
        bucket = out.setdefault(opponent_id, {"wins": 0, "losses": 0, "draws": 0})
        if outcome == MatchOutcome.WIN or outcome == MatchOutcome.WIN.value:
            bucket["wins"] += int(count)
        elif outcome == MatchOutcome.LOSS or outcome == MatchOutcome.LOSS.value:
            bucket["losses"] += int(count)
        elif outcome is not None:
            bucket["draws"] += int(count)
    return out
