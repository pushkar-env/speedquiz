"""Background worker — generation jobs + thin-topic inventory scans."""

from __future__ import annotations

import asyncio
import signal
import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
_repo_backend = _here.parent / "backend"
if _repo_backend.is_dir() and str(_repo_backend) not in sys.path:
    sys.path.insert(0, str(_repo_backend))
elif str(_here.parent) not in sys.path:
    sys.path.insert(0, str(_here.parent))

from app.core.config import get_settings
from app.core.database import session_scope
from app.core.logging import configure_logging, get_logger
from app.core.redis import close_redis, init_redis, redis_ping
from app.payments.maintenance import expire_lapsed_subscriptions
from app.services.generation_jobs import process_inventory_maintenance, process_queued_jobs
from app.services.matches import expire_stale

logger = get_logger(__name__)
_running = True

#: Idle ticks are ~10s, so this reconciles subscriptions roughly hourly. It is
#: a backstop for dropped store notifications, not the primary path, so it does
#: not need to be prompt — it needs to be certain.
_SUBSCRIPTION_SWEEP_TICKS = 360

#: ~2 minutes. Abandoned matches need closing promptly, not urgently: an async
#: challenge has a 48-hour fuse, but a live lobby nobody joined should turn
#: into a playable async challenge while the challenger is still in the app.
_MATCH_SWEEP_TICKS = 12


def _handle_signal(*_: object) -> None:
    global _running
    _running = False


async def run() -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    await init_redis()
    logger.info("worker_started", env=settings.app_env)
    ticks = 0

    while _running:
        # redis_ping never raises; a Redis outage degrades the heartbeat
        # instead of killing the loop and putting the container into a
        # restart cycle it cannot recover from on its own.
        ok = await redis_ping()
        try:
            processed = await process_queued_jobs()
        except Exception as exc:  # noqa: BLE001
            logger.exception("worker_tick_failed", error=str(exc))
            processed = 0

        # Every ~6 idle ticks, scan thin topics and enqueue chunk top-ups.
        ticks += 1
        enqueued = 0
        if ticks % 6 == 0 or processed:
            try:
                enqueued = await process_inventory_maintenance()
            except Exception as exc:  # noqa: BLE001
                logger.exception("inventory_scan_failed", error=str(exc))

        expired = 0
        if ticks % _SUBSCRIPTION_SWEEP_TICKS == 0:
            try:
                expired = await expire_lapsed_subscriptions()
            except Exception as exc:  # noqa: BLE001 — never kill the loop
                logger.exception("subscription_sweep_failed", error=str(exc))

        matches_closed = 0
        if ticks % _MATCH_SWEEP_TICKS == 0:
            try:
                async with session_scope() as db:
                    matches_closed = await expire_stale(db)
            except Exception as exc:  # noqa: BLE001 — never kill the loop
                logger.exception("match_sweep_failed", error=str(exc))

        logger.info(
            "worker_heartbeat",
            redis=ok,
            jobs_processed=processed,
            topups_enqueued=enqueued,
            subscriptions_expired=expired,
            matches_closed=matches_closed,
        )
        await asyncio.sleep(5 if (processed or enqueued) else 10)

    await close_redis()
    logger.info("worker_stopped")


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
