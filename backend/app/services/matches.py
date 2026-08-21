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

import hashlib
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
from app.services import anticheat, friends, match_rules, notifications, ranking, realtime
from app.services.localization import localized_topic_name
from app.services.progression import apply_xp
from app.services.quiz_service import _select_questions, _user_seen_question_ids

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

#: Statuses in which a player may still be served a round and score an answer.
#:
#: AWAITING_OPPONENT belongs here: it means one side has finished and the other
#: has not. Treating it as closed is what made the second player of an async
#: match unable to answer anything they were shown.
IN_PLAY_MATCH_STATUSES = frozenset({MatchStatus.LIVE, MatchStatus.AWAITING_OPPONENT})

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


async def _grant_custom_quiz_access(
    db: AsyncSession,
    match: Match,
    user_ids: Sequence[UUID],
) -> None:
    """Let everyone seated in a match open the custom quiz behind it.

    Sharing a room code, or challenging a friend, *is* the author granting
    access — a player who has answered a quiz's questions and then cannot open
    it to replay it or see its ladder has been shown a door with no handle.
    No-op for a curated topic, which needs no permission at all.
    """
    from app.services import custom_quizzes as custom_quiz_service

    topic = await db.scalar(select(Topic).where(Topic.id == match.topic_id))
    if topic is None or not topic.is_user_generated:
        return
    quiz = await custom_quiz_service.quiz_for_topic(db, topic.id)
    if quiz is None:
        return
    for user_id in user_ids:
        await custom_quiz_service.grant_access(db, quiz, user_id, source="invite")


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
    if match.status not in IN_PLAY_MATCH_STATUSES:
        return None
    started = (
        _aware(match.round_started_at)
        if match.delivery is MatchDelivery.LIVE
        else _aware(participant.round_served_at) if participant else None
    )
    if started is None:
        return None
    return started + timedelta(milliseconds=match.question_time_limit_ms)


def _has_finished(match: Match, participant: MatchParticipant) -> bool:
    return participant.rounds_answered >= match.question_count


def _score_visible_to(
    match: Match,
    participant: MatchParticipant,
    viewer: Optional[MatchParticipant],
) -> bool:
    """May [viewer] see [participant]'s score right now?

    Yes during play — a live battle is meant to be a race you can see, and the
    catch-up bonus is only fair if you know you are behind. Yes once the match
    is over, which is the point of a result.

    No in exactly one window: the viewer has played their last question and the
    opponent has not. What is on the opponent's row then is a *running* total
    with one question still to land, and showing it announces the result of a
    match that is not decided — the finished player watches a number they
    already beat, then sees it jump past them. Whoever is still playing keeps
    seeing everything, because they are the one in the race.
    """
    if match.status not in IN_PLAY_MATCH_STATUSES:
        return True
    if viewer is None or participant.user_id == viewer.user_id:
        return True
    return not (_has_finished(match, viewer) and not _has_finished(match, participant))


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
                score=(
                    participant.score
                    if _score_visible_to(match, participant, me)
                    else None
                ),
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


async def _round_has_correct_answer(
    db: AsyncSession, match_id: UUID, round_index: int
) -> bool:
    """Whether anyone has already got this round right.

    Drives the first-correct bonus. Asked before the incoming answer is
    written, so the player being scored never counts as beating themselves.
    """
    return bool(
        await db.scalar(
            select(MatchAnswer.id)
            .where(
                MatchAnswer.match_id == match_id,
                MatchAnswer.round_index == round_index,
                MatchAnswer.is_correct.is_(True),
            )
            .limit(1)
        )
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


async def _participants_missed_every_round(
    db: AsyncSession, match_id: UUID, rounds: Sequence[int]
) -> set[UUID]:
    """Participants who let the clock run out on *every* one of `rounds`.

    A miss is a recorded one — the NULL-selection row [_close_round] writes for
    whoever did not answer in time. Reading those back rather than keeping a
    counter somewhere means the signal is the same thing the scoreboard is
    built from: it cannot drift from it, and it survives a restart, a failover
    or a sweep that stopped running.

    A round with no row at all does *not* count as a miss. A seat that was not
    in play for it has no row, and reading that gap as a miss would forfeit a
    player for having arrived late.
    """
    wanted = set(rounds)
    if not wanted:
        return set()
    rows = await db.execute(
        select(MatchAnswer.participant_id, MatchAnswer.round_index).where(
            MatchAnswer.match_id == match_id,
            MatchAnswer.round_index.in_(tuple(wanted)),
            MatchAnswer.selected_option_index.is_(None),
        )
    )
    missed: dict[UUID, set[int]] = {}
    for participant_id, round_index in rows.all():
        missed.setdefault(participant_id, set()).add(round_index)
    return {seat for seat, seen in missed.items() if seen >= wanted}


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


def _duel_lock_key(a: UUID, b: UUID) -> int:
    """A stable advisory-lock key for an unordered pair of players.

    Order independent on purpose: A challenging B and B challenging A have to
    contend for the *same* lock, because that simultaneous pair is the entire
    race being closed.
    """
    low, high = sorted((a, b), key=lambda value: value.int)
    digest = hashlib.blake2b(f"{low}:{high}".encode(), digest_size=8).digest()
    # Postgres advisory locks are keyed by a bigint, hence the signed 8 bytes.
    return int.from_bytes(digest, "big", signed=True)


async def _open_duel_between(db: AsyncSession, a: UUID, b: UUID) -> Optional[Match]:
    """The friendly duel these two already have open, if any."""
    seats = {
        player: select(MatchParticipant.match_id).where(
            MatchParticipant.user_id == player,
            MatchParticipant.status != ParticipantStatus.DECLINED,
        )
        for player in (a, b)
    }
    return await db.scalar(
        select(Match)
        .options(selectinload(Match.participants))
        .where(
            Match.kind == MatchKind.FRIENDLY,
            Match.format == MatchFormat.DUEL,
            # Only a match that has not started. A live game is not something to
            # fold a new challenge into, and a finished one is history.
            Match.status.in_((MatchStatus.PENDING, MatchStatus.LOBBY)),
            Match.id.in_(seats[a]),
            Match.id.in_(seats[b]),
        )
        .order_by(Match.created_at.desc())
        .limit(1)
    )


async def _fold_into_open_duel(
    db: AsyncSession, user: User, opponent_id: UUID
) -> Optional[Match]:
    """Treat a challenge as accepting the one already waiting from that player.

    Both players tapping REMATCH in the same second used to create two matches.
    Each then sat in the lobby they had just made, holding an unanswered invite
    to the other's, and neither lobby could start — the pair had to work out
    what had happened and back out of one.

    Reading the second challenge as an *acceptance* of the first is what both
    players meant by it: they asked for the same thing, against each other, at
    the same moment. So it collapses to a single lobby with both already
    seated, and whoever was a fraction of a second slower simply finds
    themselves in the game they asked for.

    Folding regardless of topic is deliberate. The invariant worth having is
    "two players never have two duels open at once" — the alternative, matching
    on topic too, leaves the mutual-challenge-on-different-topics case in
    exactly the broken state this exists to prevent. The cost is that the
    slower player can land on the topic the faster one picked, which the lobby
    names plainly and which they can leave.

    The advisory lock is what makes this safe rather than merely likely:
    without it two simultaneous requests both look, both find nothing, and both
    create. It is transaction scoped, so the commit that writes the match
    releases it either way.
    """
    await db.execute(
        select(func.pg_advisory_xact_lock(_duel_lock_key(user.id, opponent_id)))
    )

    existing = await _open_duel_between(db, user.id, opponent_id)
    if existing is None:
        return None

    seat = participant_of(existing, user.id)
    if seat is None:  # pragma: no cover - the pair query guarantees a seat
        return None
    if seat.status is ParticipantStatus.INVITED:
        seat.status = ParticipantStatus.JOINED
        seat.joined_at = _now()
        await db.flush()
        await _publish_participants(db, existing)
    logger.info(
        "duel_challenge_folded",
        match_id=str(existing.id),
        user_id=str(user.id),
        opponent_id=str(opponent_id),
    )
    return existing


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

    # A player-authored quiz is not public content. Being active is enough for
    # a curated topic but says nothing here, so the check goes through the
    # quiz's own ACL — otherwise anyone who learned a topic id could open a
    # match on someone's private quiz and read its questions off the board.
    custom_quiz = None
    if topic.is_user_generated:
        from app.services import custom_quizzes as custom_quiz_service

        custom_quiz = await custom_quiz_service.quiz_for_topic(db, topic.id)
        if custom_quiz is None:
            raise _err("topic_not_found", "Topic not found.", status.HTTP_404_NOT_FOUND)
        await custom_quiz_service.assert_can_play(db, user, custom_quiz)

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

    # Checked before the question set is drawn: a fold returns a match that
    # already has a board, so building one here would be work thrown away — and
    # `_build_question_set` is the expensive half of creating a match.
    #
    # Ranked is exempt. Its pairs come from the matchmaker rather than from two
    # people choosing each other, so there is no mutual challenge to collapse.
    if kind is MatchKind.FRIENDLY and is_duel and len(invitees) == 1:
        folded = await _fold_into_open_duel(db, user, invitees[0])
        if folded is not None:
            return folded

    max_players = 2 if is_duel else max(2, min(payload.max_players or 4, settings.match_max_players))
    question_count = payload.question_count or settings.match_default_question_count
    question_count = max(
        settings.match_min_question_count, min(question_count, settings.match_max_question_count)
    )
    if custom_quiz is not None:
        # The deck is exactly as long as the author made it. Asking for seven
        # questions from a five-question quiz is a `bank_too_thin` 409 the
        # player can do nothing about, so the request is clamped to what exists.
        if custom_quiz.question_count < settings.match_min_question_count:
            raise _err(
                "quiz_too_short_to_challenge",
                f"A challenge needs at least {settings.match_min_question_count} questions.",
                status.HTTP_409_CONFLICT,
            )
        question_count = min(question_count, custom_quiz.question_count)

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
    await _grant_custom_quiz_access(db, match, [p.user_id for p in match.participants])

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
    await _grant_custom_quiz_access(db, match, [user.id])
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
    """Host override: start with everyone who is actually ready.

    "Ready" is the whole point, and it used to be ignored: the check was for
    two *seated* players, which includes anyone who has merely joined. So a
    host could tap Start Now and drop an opponent who had not readied — and
    might not even be looking at their phone — into a live round with a clock
    already running. In a duel that is the entire match decided by one player's
    impatience.

    Anyone seated but not ready is put back to INVITED rather than dragged in.
    That is the same state as someone who never answered the invite, and it
    means they can still play the identical board asynchronously instead of
    losing a match they never started.
    """
    match = await load_match(db, match_id)
    participant = require_participant(match, user.id)
    if not participant.is_host:
        raise _err("not_host", "Only the host can start.", status.HTTP_403_FORBIDDEN)
    if match.status not in (MatchStatus.PENDING, MatchStatus.LOBBY):
        raise _err("match_started", "Already started.", status.HTTP_409_CONFLICT)

    ready = [p for p in match.participants if p.status is ParticipantStatus.READY]
    if len(ready) < 2:
        raise _err(
            "players_not_ready",
            "Everyone needs to be ready before you can start.",
        )

    for seat in match.participants:
        if seat.status is ParticipantStatus.JOINED:
            seat.status = ParticipantStatus.INVITED

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
    await realtime.clear_abandoned(match.id)

    await realtime.publish(
        match.id,
        realtime.EVENT_ROUND_START,
        {
            "round_index": 0,
            "total_rounds": match.question_count,
            "starts_at": now.isoformat(),
            "deadline_at": (now + timedelta(milliseconds=match.question_time_limit_ms)).isoformat(),
            "server_time": now.isoformat(),
            "question": await _round_payload(db, match, 0),
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
    if match.status not in IN_PLAY_MATCH_STATUSES:
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
        is_final_round=round_index == match.question_count - 1,
    )


async def _round_payload(
    db: AsyncSession, match: Match, round_index: int
) -> Optional[dict]:
    """The prompt and buttons for a round, for embedding in a `round.start`.

    Carrying the question on the event is what removes the visible gap at the
    top of every round: the client used to learn a round had started and *then*
    spend a round trip asking what the question was, so on a slow connection the
    clock was already running against a blank screen.

    Contains no answer key — same shape [get_round] serves, minus the per-player
    clock. Correctness still only exists in a submit response and a round-end
    event, both of which are produced after the round closes for the recipient.
    """
    if round_index >= match.question_count:
        return None
    try:
        question = await _question_for_round(db, match, round_index)
    except HTTPException:
        # A question pulled from under a live match. The client falls back to
        # fetching the round over HTTP, which produces a real error if it is
        # genuinely gone.
        return None

    order = _normalize_option_order(
        match.option_orders[round_index] if round_index < len(match.option_orders) else None
    )
    by_position = {opt.position: opt.text for opt in question.options}
    return {
        "question_id": str(question.id),
        "prompt": question.prompt,
        "options": [
            {"index": i, "text": by_position[original]}
            for i, original in enumerate(order)
            if original in by_position
        ],
        "time_limit_ms": match.question_time_limit_ms,
        # Drives the double-points banner. Sent with the round rather than
        # inferred client-side from an index, so a board of a different length
        # cannot get it wrong.
        "is_final_round": round_index == match.question_count - 1,
    }


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

    # AWAITING_OPPONENT is a playable status, not a closed one: it means the
    # *other* side has finished and this player still owes the match a board.
    # Accepting only LIVE meant the second player of an async match could be
    # served every question and have every answer rejected — so they never
    # finished, and the match settled on the first player's score alone.
    if match.status not in (MatchStatus.LIVE, MatchStatus.AWAITING_OPPONENT):
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

    # Read before this answer is written: "first correct" means nobody had got
    # it right when this one arrived.
    is_first_correct = is_correct and not await _round_has_correct_answer(
        db, match.id, expected_round
    )
    best_opponent = max(
        (p.score for p in match.participants if p.user_id != user.id), default=0
    )
    breakdown = match_rules.score_answer(
        is_correct=is_correct,
        current_streak=participant.streak,
        remaining_ms=remaining_ms,
        total_ms=match.question_time_limit_ms,
        is_first_correct=is_first_correct,
        is_final_round=expected_round == match.question_count - 1,
        points_behind=max(0, best_opponent - participant.score),
    )
    points = match_rules.clamp_points(breakdown.points)

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
        streak_multiplier=Decimal(str(breakdown.combo_multiplier)),
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

    # Somebody is here. Whatever the presence hash believes, a scored answer is
    # proof the match is not abandoned.
    await realtime.clear_abandoned(match.id)
    progress = {
        "round_index": expected_round,
        "user_id": str(user.id),
        "answered": True,
        "rounds_answered": participant.rounds_answered,
    }
    # The scores map is broadcast to the whole match channel, so it cannot be
    # filtered per recipient — and once someone has finished, the only player
    # still answering is the one whose running total must stay hidden from
    # them. Omitting it entirely for the rest of the match is the honest fix:
    # the client keeps whatever it last had, and `serialize_match` hands each
    # side the scores it is allowed to see on the next refresh.
    if not any(_has_finished(match, p) for p in match.participants):
        progress["scores"] = {str(p.user_id): p.score for p in match.participants}
    await realtime.publish(match.id, realtime.EVENT_ROUND_PROGRESS, progress)

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
        combo_multiplier=breakdown.combo_multiplier,
        combo_label=breakdown.combo_label,
        first_bonus=breakdown.first_bonus,
        is_final_round=breakdown.is_final_round,
        catchup_applied=breakdown.catchup_multiplier > 1.0,
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

    Closing a round is also where a player who vanished mid-match is noticed
    and forfeited — see [_forfeit_departed_players]. That check rides here
    rather than in the sweep on purpose: the opponent who is still playing is
    already calling this on every answer and every poll, so they get their
    result without waiting for a worker tick.
    """
    if match.status not in IN_PLAY_MATCH_STATUSES:
        return (False, False)

    if match.delivery is MatchDelivery.ASYNC:
        # No shared round to close. The match ends when everyone has played out
        # their own board.
        return (False, await _finalize_if_everyone_done(db, match))

    if match.status is not MatchStatus.LIVE:
        # A live-delivery match parked on AWAITING_OPPONENT has no shared clock
        # left to run; only the async settle above applies.
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
        # `everyone_answered` means nobody let this round run out, so nobody can
        # have let a whole window of them run out either — worth checking, so
        # the ordinary round close where both players are present pays nothing
        # for this.
        if not finished and not everyone_answered:
            if await _forfeit_departed_players(db, match):
                # Settled on the same terms a tapped Leave settles on: a duel
                # has nobody left to play against, a room keeps going until one
                # player remains.
                finished = (
                    match.format is MatchFormat.DUEL or len(_live_players(match)) <= 1
                )
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
                # Sent with the reveal, a whole reveal-pause before the clock
                # starts, so the next prompt is already on the device when it
                # does.
                "question": await _round_payload(db, match, match.current_round_index),
            },
        )
    else:
        match.round_started_at = None
        await db.flush()


async def _forfeit_departed_players(db: AsyncSession, match: Match) -> bool:
    """Forfeit anyone who left without telling us. Returns whether any did.

    A player who kills the app, swipes it away or drives into a tunnel never
    reaches [leave_match], so their seat stays PLAYING and every remaining
    round waits out its full clock for an answer that is not coming. On a
    seven-question board that is over a minute of dead air for the player who
    *is* there — the one answering in two seconds and then staring at a timer.

    Two signals, and **both** are required:

    * They are holding no live connection to the match.
    * They have let every one of the last `match_abandon_rounds` rounds run out.

    Either alone is a false positive waiting to happen. Presence is invisible to
    a player whose network blocks WebSockets but who is answering perfectly well
    over HTTP; silence is ordinary for someone connected and thinking, or
    reading a reveal. Only together do they mean nobody is on the other end.

    Deliberately not applied when *everyone* qualifies. A room with nobody left
    in it is not a match everybody lost — it is the abandoned-match case that
    [sweep_live_matches] settles on the scores it has, and forfeiting both sides
    of a duel neither player was around for would hand out two losses and the
    Elo to match.
    """
    settings = get_settings()
    window = settings.match_abandon_rounds
    # `current_round_index` doubles as the count of rounds that have closed.
    if window <= 0 or match.current_round_index < window:
        return False

    players = _live_players(match)
    if len(players) < 2:
        # Nobody is being kept waiting by anybody. One seat left is a match
        # already on its way to settlement, and forfeiting it would leave the
        # standings with no player in them who finished.
        return False

    missed = await _participants_missed_every_round(
        db,
        match.id,
        range(match.current_round_index - window, match.current_round_index),
    )
    if not missed:
        return False

    connected = await realtime.connected_user_ids(match.id)
    departed = [
        p for p in players if p.id in missed and str(p.user_id) not in connected
    ]
    if not departed or len(departed) == len(players):
        return False

    now = _now()
    for participant in departed:
        # The same status a tapped Leave writes, so everything downstream is
        # already built: [_rank_participants] sorts them last whatever the
        # score, [finalize] hands them the loss and the rating that goes with
        # it, and the result screen reads FORFEITED to tell the winner they won
        # because the other player walked.
        participant.status = ParticipantStatus.FORFEITED
        participant.finished_at = now
        logger.info(
            "match_participant_abandoned",
            match_id=str(match.id),
            user_id=str(participant.user_id),
            consecutive_misses=window,
        )
    await db.flush()
    await _publish_participants(db, match)
    return True


async def _finalize_if_everyone_done(db: AsyncSession, match: Match) -> bool:
    players = _live_players(match)

    # A duel whose challenged player has not opened the match yet. They are not
    # in `players` — an invite is not an active seat — but in a duel they *are*
    # the entire opposition, and settling without them hands the challenger a
    # win for getting to their phone first. The expiry sweep releases it after
    # the async deadline, so this waits for a day rather than forever.
    #
    # Scoped to duels deliberately. In a room the players who turned up should
    # not be held hostage by an invitee who never did.
    awaiting_challenged_player = match.format is MatchFormat.DUEL and any(
        p.status is ParticipantStatus.INVITED for p in match.participants
    )

    everyone_played = bool(players) and all(
        p.rounds_answered >= match.question_count for p in players
    )
    if not awaiting_challenged_player and (not players or everyone_played):
        await finalize(db, match)
        return True

    # One side has finished and is waiting on the other. Surfacing this as a
    # distinct status is what lets the inbox say "your turn" to the right
    # person rather than showing both a spinner.
    if match.status is MatchStatus.LIVE and any(
        p.rounds_answered >= match.question_count for p in players
    ):
        match.status = MatchStatus.AWAITING_OPPONENT
        # And it has to become async, or the match deadlocks.
        #
        # Live delivery resolves *every* player's round from the shared
        # `match.current_round_index`, and nothing advances that index once the
        # status is no longer LIVE — `advance_if_due` returns early. So the
        # player who still owes rounds was served the same question forever and
        # every answer came back `already_answered`: unwinnable, unleavable,
        # and only released by the 48-hour expiry sweep.
        #
        # There is no shared clock left to run here by definition — one side
        # has already finished — so async is not a degradation, it is what this
        # state already is.
        await convert_to_async(db, match, reason="opponent_finished")
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
    """Standings order: forfeits last, then score, then speed, then accuracy.

    Total answer time breaks ties because on a seven-question board two players
    drawing on score is common, and "you were quicker" is a result both of them
    accept. Accuracy is the third key for the rare case where the clock is also
    tied.

    Walking out sorts below every player who stayed, *whatever the score was*.
    Ranking a quitter on points would mean abandoning while ahead still won the
    match — which is precisely the move the button would otherwise teach.
    """
    return sorted(
        participants,
        key=lambda p: (
            p.status is ParticipantStatus.FORFEITED,
            -p.score,
            p.total_answer_ms,
            -p.correct_count,
        ),
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
    # A forfeit is settled, not skipped. Leaving quitters out of the standings
    # is how walking out of a ranked duel used to cost nothing at all: with one
    # player left there was no pair to move Elo between, and the row kept a
    # NULL outcome, so the match was missing from the record on both counts.
    scored = [
        p for p in match.participants
        if p.status in ACTIVE_PARTICIPANT_STATUSES
        or p.status in (ParticipantStatus.FINISHED, ParticipantStatus.FORFEITED)
    ]
    ordered = _rank_participants(scored)

    # The win is contested only between the players who saw it out. A quitter
    # cannot draw into first place by having matched the leader's score at the
    # moment they left — which two players on nil after one round otherwise do.
    contenders = [p for p in ordered if p.status is not ParticipantStatus.FORFEITED]
    top_score = contenders[0].score if contenders else 0
    top_time = contenders[0].total_answer_ms if contenders else 0
    winners = [
        p for p in contenders if p.score == top_score and p.total_answer_ms == top_time
    ]

    for position, participant in enumerate(ordered, start=1):
        forfeited = participant.status is ParticipantStatus.FORFEITED
        participant.placement = position
        if not forfeited:
            # FORFEITED survives settlement deliberately. It is the only record
            # that this player walked out rather than played to the end, and the
            # result screen reads it to tell the winner *why* they won.
            participant.status = ParticipantStatus.FINISHED
        participant.finished_at = participant.finished_at or now
        if forfeited:
            participant.outcome = MatchOutcome.LOSS
        elif len(winners) > 1 and participant in winners:
            participant.outcome = MatchOutcome.DRAW
        elif participant in winners:
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
    """Abandon a match in progress, or back out of one that has not started.

    Two different acts behind one door, told apart by status:

    * **Before the first question** — a lobby or an unanswered invite — nothing
      has happened yet, so the seat is simply given up. A duel dies with it;
      a room seat just frees the chair.
    * **Mid-match** — the player forfeits. Their score stands on the scoreboard
      but ranks below everyone who stayed (see [_rank_participants]), so the
      opponent wins by abandonment whether they were ahead or behind, and the
      quitter takes the recorded loss and the Elo that goes with it.

    Forfeiting rather than deleting the row: the opponent played a real game
    and is owed a real result, and in a ranked duel a rage-quit that erased the
    match would be a free escape from a loss.

    A duel settles the moment one side walks — there is nobody left to play
    against, so making the winner wait out the clock would be theatre. A room
    keeps going until only one player remains.
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
    elif participant.rounds_answered >= match.question_count:
        # Nothing left to abandon. This player has answered every question and
        # is only waiting to see the other side's board — FINISHED is not set
        # until settlement, so their seat still reads PLAYING and the branch
        # below would forfeit a completed game for closing the screen. It cost
        # them their place in the standings before; now that a forfeit is
        # ranked and rated, it would cost them the match and the Elo with it.
        return match
    else:
        participant.status = ParticipantStatus.FORFEITED
        participant.finished_at = _now()

    await db.flush()
    await _publish_participants(db, match)

    if match.status is MatchStatus.CANCELLED:
        await realtime.publish(match.id, realtime.EVENT_CANCELLED, {"reason": "host_left"})
    elif participant.status is ParticipantStatus.FORFEITED:
        # Gated on the leaver having actually forfeited, which only happens once
        # the match is in progress. Settling on "one player left" alone also
        # fired for a *lobby* emptying out, which completed a room nobody had
        # played a question of and handed its last occupant a win over nobody.
        if match.format is MatchFormat.DUEL or len(_live_players(match)) <= 1:
            await finalize(db, match)
    return match


async def heal_parked_matches(db: AsyncSession, *, limit: int = 100) -> int:
    """Release matches parked on AWAITING_OPPONENT with a live delivery.

    That combination is a deadlock: live delivery resolves every player's round
    from the shared `match.current_round_index`, and nothing advances it once
    the status is no longer LIVE. The player who still owes rounds is served
    one question forever and every answer comes back `already_answered`.

    [_finalize_if_everyone_done] no longer creates the state, but rows written
    before that fix are still sitting in the database, and a player cannot get
    out of one by playing, leaving, or waiting for anything short of the
    48-hour expiry. So this repairs them in place rather than making the fix
    conditional on nobody having hit the bug yet.

    Cheap by construction: the combination is rare, and once the backlog is
    drained this selects nothing on every tick forever.
    """
    parked = (
        await db.execute(
            select(Match)
            .options(selectinload(Match.participants))
            .where(
                Match.status == MatchStatus.AWAITING_OPPONENT,
                Match.delivery == MatchDelivery.LIVE,
            )
            .limit(limit)
        )
    ).scalars().all()

    for match in parked:
        logger.info("match_unparked", match_id=str(match.id))
        await convert_to_async(db, match, reason="parked_deadlock")
    if parked:
        await db.flush()
    return len(parked)


async def sweep_live_matches(db: AsyncSession, *, limit: int = 200) -> int:
    """Run the clock for live matches nobody is currently driving.

    Round advancement is opportunistic — it rides on whatever request happens
    to touch a match. That covers every case except the one that matters here:
    *both* players gone. Nothing then arrives to notice the deadline, so the
    match sat LIVE until the 48-hour async expiry, which is what left a
    finished-looking game listed as still in play long after someone walked out.

    Two things happen per sweep, in order:

    1. **The clock advances.** A round whose deadline has passed closes,
       recording zeros for whoever did not answer. Left alone this plays an
       abandoned match out to its last question and settles it honestly.
    2. **A dead room is settled early.** When a round closes with nobody
       connected and nobody having answered it, that counts once against
       `match_abandon_rounds`; on reaching the limit the match is finalized on
       the scores it has, so the player who did turn up gets their result in
       under a minute instead of waiting out the whole board.

    The sibling case — *one* player gone while the other plays on — needs no
    help from here. [advance_if_due] forfeits the absentee as the round closes,
    and the player still tapping answers is calling it far more often than this
    sweep runs.

    Returns how many matches were touched.
    """
    # First, unwedge anything already deadlocked — a stuck match has no clock
    # to run until it has been handed back to its players.
    touched_parked = await heal_parked_matches(db)

    settings = get_settings()
    now = _now()
    # A coarse pre-filter only. The real deadline is per-match — every match
    # carries its own `question_time_limit_ms` — and comparing against it in SQL
    # would mean an interval expression over a column for no benefit, since
    # [advance_if_due] re-checks the exact deadline anyway and returns without
    # doing anything when the round is still open. Erring early costs a cheap
    # read; erring late would cost a stalled match.
    cutoff = now - timedelta(milliseconds=settings.match_answer_grace_ms)

    stale = (
        await db.execute(
            select(Match)
            .options(selectinload(Match.participants))
            .where(
                Match.status == MatchStatus.LIVE,
                Match.delivery == MatchDelivery.LIVE,
                Match.round_started_at.is_not(None),
                Match.round_started_at < cutoff,
            )
            .limit(limit)
        )
    ).scalars().all()

    touched = 0
    for match in stale:
        round_index = match.current_round_index
        answered = await _participants_answered(db, match.id, round_index)
        connected = await realtime.connected_user_ids(match.id)

        closed, finished = await advance_if_due(db, match)
        if not closed:
            continue
        touched += 1

        if finished:
            await realtime.clear_abandoned(match.id)
            continue

        if connected or answered:
            # Someone is still playing, even if only over HTTP.
            await realtime.clear_abandoned(match.id)
            continue

        if await realtime.note_abandoned_round(match.id) >= settings.match_abandon_rounds:
            logger.info("match_abandoned", match_id=str(match.id), round_index=round_index)
            await finalize(db, match)
            await realtime.clear_abandoned(match.id)

    await db.flush()
    return touched + touched_parked


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


#: How far back a player's match history goes.
#:
#: Ten is a deliberate ceiling rather than a page size: anything older is not
#: paged to, it simply is not shown. A history screen that grows without bound
#: turns into a scroll nobody reads, and every row costs a `serialize_match`
#: with its own profile and presence lookups.
#:
#: The rows stay in the database. Head-to-head records on the friends screen
#: are counted from them, and deleting a match to tidy a list would silently
#: rewrite the standings between two players.
MATCH_HISTORY_LIMIT = 10


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
            .limit(limit + MATCH_HISTORY_LIMIT)
        )
    ).scalars().unique().all()

    active: list[MatchOut] = []
    recent: list[MatchOut] = []
    for match in rows:
        if match.status in OPEN_MATCH_STATUSES:
            if len(active) >= limit:
                continue
            active.append(await serialize_match(db, match, viewer_id=user.id))
        elif len(recent) < MATCH_HISTORY_LIMIT:
            recent.append(await serialize_match(db, match, viewer_id=user.id))
    return active, recent


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
