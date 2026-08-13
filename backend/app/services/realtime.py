"""The realtime channel behind live matches.

Fan-out across replicas
-----------------------
Railway runs more than one API container, and the two players in a duel are
routinely connected to different ones. Match events therefore go through Redis
rather than process memory.

The primitive is a **Redis Stream per match**, not pub/sub. Pub/sub delivers to
whoever happens to be listening at that instant, which on a mobile network is
the wrong guarantee: a player crossing from wifi to cellular is disconnected for
two seconds and must not lose the round that started while they were gone. A
stream is a log with ids, so a reconnecting client resumes from its last id and
replays what it missed.

One reader per process, not per socket
--------------------------------------
The obvious implementation — every WebSocket handler running its own
``XREAD BLOCK`` — burns a Redis connection per connected player. Against a
50-connection pool that ceiling is reached at 50 concurrent players, which is
not a multiplayer feature. Instead a single [RealtimeHub] task per process holds
one connection, reads every active match stream in one multi-key ``XREAD``, and
hands events to local subscribers through asyncio queues. Redis connection use
is then O(processes), not O(players).
"""

from __future__ import annotations

import asyncio
import json
import secrets
import time
from dataclasses import dataclass, field
from typing import Any, Optional
from uuid import UUID

from app.core.config import get_settings
from app.core.logging import get_logger
from app.core.redis import get_redis

logger = get_logger(__name__)

#: Stream holding one match's event log.
STREAM_PREFIX = "mp:events:"
#: Hash of participant -> last heartbeat, for the live presence dots.
PRESENCE_PREFIX = "mp:presence:"
#: Guards round advancement so two replicas cannot advance the same round.
ROUND_LOCK_PREFIX = "mp:lock:round:"
#: Single-use WebSocket tickets.
TICKET_PREFIX = "mp:ws:ticket:"

#: Sent when a client connects with no cursor, or one too old to resume from.
EVENT_SNAPSHOT = "match.state"
EVENT_PARTICIPANT = "participant.update"
EVENT_COUNTDOWN = "match.countdown"
EVENT_ROUND_START = "round.start"
EVENT_ROUND_PROGRESS = "round.progress"
EVENT_ROUND_END = "round.end"
EVENT_FINISHED = "match.finished"
EVENT_CANCELLED = "match.cancelled"
EVENT_CHAT = "match.reaction"


def stream_key(match_id: UUID | str) -> str:
    return f"{STREAM_PREFIX}{match_id}"


def presence_key(match_id: UUID | str) -> str:
    return f"{PRESENCE_PREFIX}{match_id}"


def _id_tuple(event_id: str) -> tuple[int, int]:
    """Parse a stream id into comparable parts.

    Redis ids look like ``1690000000000-0``. Comparing them as strings works
    only while every millisecond timestamp has the same number of digits, which
    is true today and silently stops being true later; parsing costs nothing
    and removes the trap.
    """
    try:
        ms, seq = event_id.split("-", 1)
        return int(ms), int(seq)
    except (ValueError, AttributeError):
        return (0, 0)


@dataclass
class RealtimeEvent:
    id: str
    type: str
    data: dict[str, Any]

    def to_json(self) -> dict[str, Any]:
        return {"id": self.id, "type": self.type, "data": self.data}


@dataclass
class Subscriber:
    match_id: str
    queue: "asyncio.Queue[RealtimeEvent]" = field(
        # Bounded: a client whose socket has stalled must not be able to grow
        # the server's memory without limit. Overflow drops the subscriber,
        # which reconnects and resumes from its cursor.
        default_factory=lambda: asyncio.Queue(maxsize=256)
    )
    last_id: str = "0-0"
    dropped: bool = False


async def publish(
    match_id: UUID | str,
    event_type: str,
    data: dict[str, Any],
) -> Optional[str]:
    """Append an event to a match's log. Returns the stream id, or None.

    Never raises. A realtime event is an optimisation over refetching state —
    if Redis is unavailable the match must still be playable over plain HTTP,
    so a publish failure is logged and swallowed rather than failing the request
    that triggered it.
    """
    settings = get_settings()
    try:
        redis = await get_redis()
        key = stream_key(match_id)
        event_id = await redis.xadd(
            key,
            {"type": event_type, "data": json.dumps(data, default=str)},
            maxlen=settings.realtime_stream_maxlen,
            approximate=True,
        )
        await redis.expire(key, settings.realtime_stream_ttl_seconds)
        return event_id
    except Exception as exc:  # noqa: BLE001 — realtime is best-effort by design
        logger.warning("realtime_publish_failed", error=str(exc), event=event_type)
        return None


async def history(
    match_id: UUID | str,
    *,
    after_id: str = "0-0",
    limit: int = 200,
) -> list[RealtimeEvent]:
    """Events after `after_id`, for a client resuming a dropped connection."""
    try:
        redis = await get_redis()
        exclusive = f"({after_id}" if after_id and after_id != "0-0" else "-"
        rows = await redis.xrange(stream_key(match_id), min=exclusive, max="+", count=limit)
        return [_decode(event_id, fields) for event_id, fields in rows]
    except Exception as exc:  # noqa: BLE001
        logger.warning("realtime_history_failed", error=str(exc))
        return []


def _decode(event_id: str, fields: dict[str, str]) -> RealtimeEvent:
    raw = fields.get("data") or "{}"
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        data = {}
    return RealtimeEvent(id=event_id, type=fields.get("type", "unknown"), data=data)


class RealtimeHub:
    """One Redis reader per process, fanning out to local subscribers.

    Started lazily by the first subscriber and stopped when the last one
    leaves, so a process that never serves a live match never opens the extra
    connection.
    """

    def __init__(self) -> None:
        self._subscribers: dict[str, set[Subscriber]] = {}
        self._cursors: dict[str, str] = {}
        self._task: Optional[asyncio.Task] = None
        self._wake = asyncio.Event()
        self._lock = asyncio.Lock()

    async def subscribe(self, match_id: UUID | str, *, last_id: str = "$") -> Subscriber:
        """Join a match's event feed.

        ``last_id="$"`` means "only what happens from now"; a real id resumes.
        The caller is expected to have fetched a state snapshot over HTTP, so
        the default deliberately does not replay the whole match.
        """
        key = str(match_id)
        subscriber = Subscriber(match_id=key, last_id="0-0" if last_id == "$" else last_id)

        async with self._lock:
            fresh = key not in self._subscribers
            self._subscribers.setdefault(key, set()).add(subscriber)
            if fresh:
                # New stream for this process: start reading from the newest
                # entry, since anything older is the subscriber's to replay.
                self._cursors[key] = await self._latest_id(key) if last_id == "$" else last_id
            self._ensure_running()

        self._wake.set()
        return subscriber

    async def unsubscribe(self, subscriber: Subscriber) -> None:
        async with self._lock:
            peers = self._subscribers.get(subscriber.match_id)
            if peers is None:
                return
            peers.discard(subscriber)
            if not peers:
                self._subscribers.pop(subscriber.match_id, None)
                self._cursors.pop(subscriber.match_id, None)
            if not self._subscribers and self._task is not None:
                self._task.cancel()
                self._task = None
        self._wake.set()

    def _ensure_running(self) -> None:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._run(), name="realtime-hub")

    @staticmethod
    async def _latest_id(match_id: str) -> str:
        try:
            redis = await get_redis()
            rows = await redis.xrevrange(stream_key(match_id), count=1)
            return rows[0][0] if rows else "0-0"
        except Exception:  # noqa: BLE001
            return "0-0"

    async def _run(self) -> None:
        """Read every subscribed stream in one call, forever."""
        while True:
            try:
                async with self._lock:
                    streams = {stream_key(m): c for m, c in self._cursors.items()}
                if not streams:
                    self._wake.clear()
                    # Nothing to read. Wake on the next subscribe rather than
                    # spinning; the timeout is a safety net, not the mechanism.
                    try:
                        await asyncio.wait_for(self._wake.wait(), timeout=30)
                    except asyncio.TimeoutError:
                        pass
                    continue

                redis = await get_redis()
                # A short block, so a subscribe or unsubscribe is picked up
                # within a second rather than waiting out a long read.
                response = await redis.xread(streams, count=100, block=1000)
                for raw_key, entries in response or []:
                    match_id = raw_key.removeprefix(STREAM_PREFIX)
                    for event_id, fields in entries:
                        # The last subscriber may have left while this read was
                        # in flight; do not resurrect a cursor for a stream
                        # nobody is listening to any more.
                        if match_id not in self._cursors:
                            continue
                        self._cursors[match_id] = event_id
                        await self._dispatch(match_id, _decode(event_id, fields))
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                logger.warning("realtime_hub_read_failed", error=str(exc))
                # Back off rather than hammering a Redis that is refusing us.
                await asyncio.sleep(1.0)

    async def _dispatch(self, match_id: str, event: RealtimeEvent) -> None:
        for subscriber in list(self._subscribers.get(match_id, ())):
            # Replay protection: a resuming client sets its cursor behind the
            # hub's, and catches up over HTTP. Anything it has already seen is
            # dropped here rather than being rendered twice.
            if _id_tuple(event.id) <= _id_tuple(subscriber.last_id):
                continue
            try:
                subscriber.queue.put_nowait(event)
                subscriber.last_id = event.id
            except asyncio.QueueFull:
                subscriber.dropped = True
                logger.info("realtime_subscriber_dropped", match_id=match_id)


#: Process-wide hub. Created on import; its reader task only starts once
#: something actually subscribes.
hub = RealtimeHub()


# --- Presence ---------------------------------------------------------------


async def touch_presence(match_id: UUID | str, user_id: UUID | str) -> None:
    """Record that a player is currently connected to a match."""
    settings = get_settings()
    try:
        redis = await get_redis()
        key = presence_key(match_id)
        # Wall clock, not the event loop's monotonic clock: this value is read
        # by other processes, and a loop clock is only meaningful inside the
        # process that produced it.
        await redis.hset(key, str(user_id), str(int(time.time())))
        await redis.expire(key, settings.realtime_stream_ttl_seconds)
    except Exception as exc:  # noqa: BLE001
        logger.debug("realtime_presence_write_failed", error=str(exc))


async def clear_presence(match_id: UUID | str, user_id: UUID | str) -> None:
    try:
        redis = await get_redis()
        await redis.hdel(presence_key(match_id), str(user_id))
    except Exception as exc:  # noqa: BLE001
        logger.debug("realtime_presence_clear_failed", error=str(exc))


async def connected_user_ids(match_id: UUID | str) -> set[str]:
    try:
        redis = await get_redis()
        return set(await redis.hkeys(presence_key(match_id)))
    except Exception:  # noqa: BLE001
        return set()


#: Global "app is open" presence, refreshed by the WebSocket heartbeat. Keyed
#: per user rather than per match so the friends list can light up a dot
#: without knowing which match, if any, someone is in.
ONLINE_PREFIX = "mp:online:"
#: Comfortably longer than the heartbeat, so one dropped ping does not make a
#: connected player flicker offline.
ONLINE_TTL_SECONDS = 90


async def mark_online(user_id: UUID | str) -> None:
    try:
        redis = await get_redis()
        await redis.set(f"{ONLINE_PREFIX}{user_id}", "1", ex=ONLINE_TTL_SECONDS)
    except Exception as exc:  # noqa: BLE001
        logger.debug("realtime_online_write_failed", error=str(exc))


async def clear_online(user_id: UUID | str) -> None:
    try:
        redis = await get_redis()
        await redis.delete(f"{ONLINE_PREFIX}{user_id}")
    except Exception:  # noqa: BLE001
        pass


async def online_among(user_ids: list[UUID] | list[str]) -> set[str]:
    """Which of these players currently has the app open.

    One MGET for the whole friend list — a key-per-user existence check would
    be one round trip per friend, on a screen that renders on every open.
    """
    ids = [str(u) for u in user_ids]
    if not ids:
        return set()
    try:
        redis = await get_redis()
        values = await redis.mget([f"{ONLINE_PREFIX}{i}" for i in ids])
        return {ids[idx] for idx, value in enumerate(values) if value}
    except Exception:  # noqa: BLE001
        return set()


# --- Round advancement lock -------------------------------------------------


async def acquire_round_lock(match_id: UUID | str, *, ttl_ms: int = 3000) -> bool:
    """Claim the right to advance this match's round.

    Any replica may notice that a round is over — the last answer arrives on
    one, the deadline passes on another. This makes exactly one of them act.
    Fails *closed*: if Redis is unreachable nobody advances via this path, and
    the deadline sweep in the match service picks it up instead. Advancing
    twice would serve two rounds at once, which is worse than advancing late.
    """
    try:
        redis = await get_redis()
        return bool(
            await redis.set(
                f"{ROUND_LOCK_PREFIX}{match_id}", "1", nx=True, px=ttl_ms
            )
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("realtime_round_lock_failed", error=str(exc))
        return False


async def release_round_lock(match_id: UUID | str) -> None:
    try:
        redis = await get_redis()
        await redis.delete(f"{ROUND_LOCK_PREFIX}{match_id}")
    except Exception:  # noqa: BLE001
        pass


# --- WebSocket tickets ------------------------------------------------------


async def issue_ticket(user_id: UUID) -> str:
    """Mint a single-use ticket to open a WebSocket with.

    A WebSocket URL cannot carry an Authorization header from every client, and
    putting the access token in the query string writes it into proxy logs,
    Cloudflare analytics and browser history. A ticket is a bearer credential
    too, but it lives for a minute, works once, and grants nothing but a socket.
    """
    settings = get_settings()
    ticket = secrets.token_urlsafe(32)
    redis = await get_redis()
    await redis.set(
        f"{TICKET_PREFIX}{ticket}",
        str(user_id),
        ex=settings.realtime_ticket_ttl_seconds,
    )
    return ticket


async def redeem_ticket(ticket: str) -> Optional[UUID]:
    """Consume a ticket, returning the user it was issued to.

    Uses GETDEL so a leaked ticket cannot be replayed: whoever redeems it first
    wins, and the legitimate client's failure is a reconnect rather than a
    silently shared session.
    """
    if not ticket:
        return None
    try:
        redis = await get_redis()
        raw = await redis.getdel(f"{TICKET_PREFIX}{ticket}")
        return UUID(raw) if raw else None
    except (ValueError, TypeError):
        return None
    except Exception as exc:  # noqa: BLE001
        logger.warning("realtime_ticket_redeem_failed", error=str(exc))
        return None
