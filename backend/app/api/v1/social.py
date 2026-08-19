"""Friends, usernames, notifications and devices."""

from __future__ import annotations

from typing import Optional
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import func, select

from app.auth.deps import CurrentUser, DbSession
from app.core.languages import normalize_language
from app.models import (
    Friendship,
    FriendshipStatus,
    Match,
    MatchParticipant,
    MatchStatus,
    NotificationType,
    OPEN_MATCH_STATUSES,
    User,
    UserProfile,
)
from app.schemas.multiplayer import (
    ChangeUsernameRequest,
    FriendListResponse,
    FriendOut,
    FriendRequestListResponse,
    FriendRequestOut,
    HeadToHeadOut,
    NotificationListResponse,
    NotificationOut,
    NotificationPrefsRequest,
    PlayerBriefOut,
    PlayerSearchResponse,
    RegisterDeviceRequest,
    SendFriendRequestRequest,
    UsernameAvailabilityResponse,
    UsernameStatusResponse,
)
from app.services import friends, notifications, realtime, usernames

router = APIRouter(tags=["social"])


async def _brief(db, user_ids: list[UUID]) -> dict[UUID, PlayerBriefOut]:
    if not user_ids:
        return {}
    rows = await db.execute(
        select(UserProfile, User.is_premium)
        .join(User, User.id == UserProfile.user_id)
        .where(UserProfile.user_id.in_(user_ids))
    )
    return {
        profile.user_id: PlayerBriefOut(
            user_id=profile.user_id,
            username=profile.username,
            display_name=profile.display_name,
            avatar_id=profile.avatar_id,
            level=profile.level,
            is_premium=bool(premium),
        )
        for profile, premium in rows.all()
    }


# --- Usernames --------------------------------------------------------------


@router.get("/username", response_model=UsernameStatusResponse)
async def get_username_status(user: CurrentUser, db: DbSession) -> UsernameStatusResponse:
    profile = user.profile
    return UsernameStatusResponse(
        username=profile.username,
        friend_code=await usernames.ensure_friend_code(db, profile),
        change_available_at=usernames.can_change_username_at(profile),
    )


@router.get("/username/available", response_model=UsernameAvailabilityResponse)
async def check_username(
    user: CurrentUser,
    db: DbSession,
    username: str = Query(min_length=1, max_length=32),
) -> UsernameAvailabilityResponse:
    """Live availability for the edit field.

    Validation failures come back as `available: false` with a reason rather
    than as a 422, because the caller is a field the player is still typing in
    and an error status would light up the generic failure handling.
    """
    try:
        candidate = usernames.validate_username(username)
    except HTTPException as exc:
        detail = exc.detail if isinstance(exc.detail, dict) else {}
        return UsernameAvailabilityResponse(
            username=username,
            available=False,
            reason=str(detail.get("code", "username_invalid")),
        )

    available = await usernames.is_username_available(
        db, candidate, exclude_user_id=user.id
    )
    suggestions: list[str] = []
    if not available:
        for suffix in ("_1", "_x", str(user.profile.level or 1), "_hq"):
            candidate_suffixed = f"{candidate[:16]}{suffix}"
            try:
                usernames.validate_username(candidate_suffixed)
            except HTTPException:
                continue
            if await usernames.is_username_available(
                db, candidate_suffixed, exclude_user_id=user.id
            ):
                suggestions.append(candidate_suffixed)
            if len(suggestions) >= 3:
                break

    return UsernameAvailabilityResponse(
        username=candidate,
        available=available,
        reason=None if available else "username_taken",
        suggestions=suggestions,
    )


@router.put("/username", response_model=UsernameStatusResponse)
async def change_username(
    payload: ChangeUsernameRequest,
    user: CurrentUser,
    db: DbSession,
) -> UsernameStatusResponse:
    profile = user.profile
    await usernames.claim_username(db, profile, payload.username)
    await db.flush()
    return UsernameStatusResponse(
        username=profile.username,
        friend_code=await usernames.ensure_friend_code(db, profile),
        change_available_at=usernames.can_change_username_at(profile),
    )


# --- Discovery --------------------------------------------------------------


@router.get("/players/search", response_model=PlayerSearchResponse)
async def search_players(
    user: CurrentUser,
    db: DbSession,
    q: str = Query(min_length=2, max_length=32),
) -> PlayerSearchResponse:
    profiles = await friends.search_players(db, user.id, q)
    ids = [p.user_id for p in profiles]
    briefs = await _brief(db, ids)

    edges = (
        await db.execute(
            select(Friendship).where(
                Friendship.status.in_(
                    (FriendshipStatus.PENDING, FriendshipStatus.ACCEPTED)
                ),
                Friendship.requester_id.in_([*ids, user.id]),
                Friendship.addressee_id.in_([*ids, user.id]),
            )
        )
    ).scalars().all()

    relationships: dict[UUID, str] = {}
    for edge in edges:
        other = (
            edge.addressee_id if edge.requester_id == user.id else edge.requester_id
        )
        if user.id not in (edge.requester_id, edge.addressee_id):
            continue
        if edge.status is FriendshipStatus.ACCEPTED:
            relationships[other] = "friends"
        elif edge.requester_id == user.id:
            relationships[other] = "request_sent"
        else:
            relationships[other] = "request_received"

    return PlayerSearchResponse(
        items=[briefs[i] for i in ids if i in briefs],
        relationships=relationships,
    )


# --- Friends ----------------------------------------------------------------


@router.get("/friends", response_model=FriendListResponse)
async def list_friends(user: CurrentUser, db: DbSession) -> FriendListResponse:
    edges = (
        await db.execute(
            select(Friendship).where(
                Friendship.status == FriendshipStatus.ACCEPTED,
                (Friendship.requester_id == user.id)
                | (Friendship.addressee_id == user.id),
            )
        )
    ).scalars().all()

    friend_ids = [
        e.addressee_id if e.requester_id == user.id else e.requester_id for e in edges
    ]
    briefs = await _brief(db, friend_ids)
    records = await friends.head_to_head(db, user.id, friend_ids)

    open_matches = await _open_matches_with(db, user.id, friend_ids)
    online = await realtime.online_among(friend_ids)

    items: list[FriendOut] = []
    for edge in edges:
        other = edge.addressee_id if edge.requester_id == user.id else edge.requester_id
        brief = briefs.get(other)
        if brief is None:
            continue
        record = records.get(other, {})
        items.append(
            FriendOut(
                friendship_id=edge.id,
                player=brief,
                friends_since=edge.responded_at or edge.created_at,
                head_to_head=HeadToHeadOut(**record) if record else HeadToHeadOut(),
                is_online=str(other) in online,
                open_match_id=open_matches.get(other),
            )
        )

    items.sort(key=lambda f: f.player.username.lower())
    return FriendListResponse(items=items, total=len(items))


async def _open_matches_with(db, user_id: UUID, friend_ids: list[UUID]) -> dict[UUID, UUID]:
    """Any unfinished match between this player and each friend.

    One grouped query for the whole list rather than one per row — the friends
    screen renders a "continue" affordance on every tile, and doing that
    per-friend is how a list turns into fifty round trips.
    """
    if not friend_ids:
        return {}
    mine = MatchParticipant.__table__.alias("mine")
    theirs = MatchParticipant.__table__.alias("theirs")
    rows = await db.execute(
        select(theirs.c.user_id, Match.id)
        .select_from(
            mine.join(
                theirs,
                (theirs.c.match_id == mine.c.match_id)
                & (theirs.c.user_id != mine.c.user_id),
            ).join(Match, Match.id == mine.c.match_id)
        )
        .where(
            mine.c.user_id == user_id,
            theirs.c.user_id.in_(friend_ids),
            Match.status.in_(tuple(OPEN_MATCH_STATUSES)),
        )
        .order_by(Match.created_at.desc())
    )
    # Newest wins if a pair somehow has two open matches.
    out: dict[UUID, UUID] = {}
    for opponent_id, match_id in rows.all():
        out.setdefault(opponent_id, match_id)
    return out


@router.get("/friends/requests", response_model=FriendRequestListResponse)
async def list_requests(user: CurrentUser, db: DbSession) -> FriendRequestListResponse:
    edges = (
        await db.execute(
            select(Friendship).where(
                Friendship.status == FriendshipStatus.PENDING,
                (Friendship.requester_id == user.id)
                | (Friendship.addressee_id == user.id),
            )
        )
    ).scalars().all()

    other_ids = [
        e.addressee_id if e.requester_id == user.id else e.requester_id for e in edges
    ]
    briefs = await _brief(db, other_ids)

    incoming: list[FriendRequestOut] = []
    outgoing: list[FriendRequestOut] = []
    for edge in edges:
        is_incoming = edge.addressee_id == user.id
        other = edge.requester_id if is_incoming else edge.addressee_id
        brief = briefs.get(other)
        if brief is None:
            continue
        entry = FriendRequestOut(
            id=edge.id,
            player=brief,
            direction="incoming" if is_incoming else "outgoing",
            created_at=edge.created_at,
        )
        (incoming if is_incoming else outgoing).append(entry)

    return FriendRequestListResponse(incoming=incoming, outgoing=outgoing)


@router.post("/friends/requests", status_code=status.HTTP_201_CREATED)
async def send_friend_request(
    payload: SendFriendRequestRequest,
    user: CurrentUser,
    db: DbSession,
) -> dict:
    target_id = await _resolve_target(db, payload)
    edge = await friends.send_request(db, user.id, target_id)

    if edge.status is FriendshipStatus.ACCEPTED:
        # Crossed requests: they had already asked, so this accepted theirs.
        await notifications.notify(
            db,
            user_id=edge.requester_id,
            notification_type=NotificationType.FRIEND_ACCEPTED,
            actor_user_id=user.id,
            deep_link="/battle/friends",
            push_params={"actor": user.profile.username},
        )
    else:
        await notifications.notify(
            db,
            user_id=target_id,
            notification_type=NotificationType.FRIEND_REQUEST,
            actor_user_id=user.id,
            # The edge id, so the recipient can accept from the banner or the
            # inbox row without first loading the requests screen to find out
            # what this request is called.
            payload={"request_id": str(edge.id)},
            # The tab, not just the screen. `/battle/friends` opens on the
            # friends list, and a brand-new request lives one tab over — so
            # tapping the notification landed on a screen that looked like
            # nothing had arrived.
            deep_link="/battle/friends?tab=requests",
            push_params={"actor": user.profile.username},
        )
    return {"id": str(edge.id), "status": edge.status.value}


async def _resolve_target(db, payload: SendFriendRequestRequest) -> UUID:
    if payload.user_id is not None:
        return payload.user_id
    if payload.friend_code:
        profile = await usernames.find_by_friend_code(db, payload.friend_code)
        if profile is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "user_not_found", "message": "No player with that code."},
            )
        return profile.user_id
    if payload.username:
        skeleton = usernames.username_skeleton(payload.username)
        found = await db.scalar(
            select(UserProfile.user_id).where(UserProfile.username_skeleton == skeleton)
        )
        if found is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "user_not_found", "message": "Player not found."},
            )
        return found
    raise HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail={"code": "target_required", "message": "Provide a player to add."},
    )


@router.post("/friends/requests/{request_id}/accept")
async def accept_request(request_id: UUID, user: CurrentUser, db: DbSession) -> dict:
    edge = await friends.respond_to_request(db, user.id, request_id, accept=True)
    await notifications.resolve_request(db, user_id=user.id, request_id=request_id)
    await notifications.notify(
        db,
        user_id=edge.requester_id,
        notification_type=NotificationType.FRIEND_ACCEPTED,
        actor_user_id=user.id,
        deep_link="/battle/friends",
        push_params={"actor": user.profile.username},
    )
    return {"status": edge.status.value}


@router.post("/friends/requests/{request_id}/decline")
async def decline_request(request_id: UUID, user: CurrentUser, db: DbSession) -> dict:
    edge = await friends.respond_to_request(db, user.id, request_id, accept=False)
    await notifications.resolve_request(db, user_id=user.id, request_id=request_id)
    # Deliberately silent. Telling someone they were declined turns a private
    # non-answer into a rejection notice.
    return {"status": edge.status.value}


@router.delete("/friends/requests/{request_id}", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def cancel_request(request_id: UUID, user: CurrentUser, db: DbSession) -> None:
    await friends.cancel_request(db, user.id, request_id)


@router.delete("/friends/{friend_user_id}", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def unfriend(friend_user_id: UUID, user: CurrentUser, db: DbSession) -> None:
    await friends.unfriend(db, user.id, friend_user_id)


@router.post("/blocks/{target_user_id}", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def block(target_user_id: UUID, user: CurrentUser, db: DbSession) -> None:
    await friends.block_user(db, user.id, target_user_id)


@router.delete("/blocks/{target_user_id}", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def unblock(target_user_id: UUID, user: CurrentUser, db: DbSession) -> None:
    await friends.unblock_user(db, user.id, target_user_id)


@router.get("/blocks", response_model=list[PlayerBriefOut])
async def list_blocks(user: CurrentUser, db: DbSession) -> list[PlayerBriefOut]:
    from app.models import UserBlock

    rows = (
        await db.execute(
            select(UserBlock.blocked_id).where(UserBlock.blocker_id == user.id)
        )
    ).all()
    ids = [row[0] for row in rows]
    briefs = await _brief(db, ids)
    return [briefs[i] for i in ids if i in briefs]


# --- Notifications and devices ---------------------------------------------


@router.get("/notifications", response_model=NotificationListResponse)
async def list_notifications(
    user: CurrentUser,
    db: DbSession,
    limit: int = Query(default=40, ge=1, le=100),
) -> NotificationListResponse:
    rows, unread = await notifications.list_for_user(db, user.id, limit=limit)
    actor_ids = [r.actor_user_id for r in rows if r.actor_user_id]
    briefs = await _brief(db, actor_ids)
    return NotificationListResponse(
        items=[
            NotificationOut(
                id=row.id,
                type=row.type,
                actor=briefs.get(row.actor_user_id) if row.actor_user_id else None,
                match_id=row.match_id,
                payload=row.payload or {},
                deep_link=row.deep_link,
                read_at=row.read_at,
                created_at=row.created_at,
            )
            for row in rows
        ],
        unread_count=unread,
    )


@router.post("/notifications/read")
async def mark_notifications_read(
    user: CurrentUser,
    db: DbSession,
    notification_id: Optional[UUID] = None,
) -> dict:
    updated = await notifications.mark_read(
        db, user.id, notification_ids=[notification_id] if notification_id else None
    )
    return {"updated": updated}


@router.delete("/notifications")
async def clear_notifications(user: CurrentUser, db: DbSession) -> dict:
    """Empty the inbox.

    Deliberately not `204`: the client shows how many were cleared, and a
    body is also what lets it tell "nothing to clear" apart from a request
    that never reached the server.
    """
    cleared = await notifications.clear_all(db, user.id)
    return {"cleared": cleared}


@router.put("/notifications/preferences")
async def set_notification_prefs(
    payload: NotificationPrefsRequest,
    user: CurrentUser,
    db: DbSession,
) -> dict:
    return await notifications.set_preferences(db, user.profile, payload.prefs)


@router.post("/devices", status_code=status.HTTP_201_CREATED)
async def register_device(
    payload: RegisterDeviceRequest,
    user: CurrentUser,
    db: DbSession,
) -> dict:
    language = normalize_language(
        payload.language if payload.language is not None
        else (user.profile.app_language if user.profile else None)
    )
    device = await notifications.register_device(
        db,
        user_id=user.id,
        token=payload.token,
        platform=payload.platform,
        app_version=payload.app_version,
        language=language,
        utc_offset_minutes=payload.utc_offset_minutes,
    )
    return {"id": str(device.id)}


@router.delete("/devices", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def unregister_device(
    user: CurrentUser,
    db: DbSession,
    token: str = Query(min_length=8),
) -> None:
    await notifications.unregister_device(db, user_id=user.id, token=token)


@router.get("/social/summary")
async def social_summary(user: CurrentUser, db: DbSession) -> dict:
    """Badge counts for the bottom bar, in one call.

    The shell polls this; making it three separate endpoints would triple the
    request rate for a number that fits in a dot.
    """
    pending = int(
        await db.scalar(
            select(func.count())
            .select_from(Friendship)
            .where(
                Friendship.addressee_id == user.id,
                Friendship.status == FriendshipStatus.PENDING,
            )
        )
        or 0
    )
    _, unread = await notifications.list_for_user(db, user.id, limit=1)
    your_turn = int(
        await db.scalar(
            select(func.count())
            .select_from(MatchParticipant)
            .join(Match, Match.id == MatchParticipant.match_id)
            .where(
                MatchParticipant.user_id == user.id,
                Match.status.in_(
                    (MatchStatus.PENDING, MatchStatus.AWAITING_OPPONENT, MatchStatus.LIVE)
                ),
            )
        )
        or 0
    )
    return {
        "friend_requests": pending,
        "unread_notifications": unread,
        "matches_awaiting_you": your_turn,
        "online_friend_ids": sorted(
            await realtime.online_among(await friends.friend_ids(db, user.id))
        ),
    }
