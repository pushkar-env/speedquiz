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
from app.core.logging import configure_logging, get_logger
from app.core.redis import close_redis, init_redis, redis_ping
from app.services.generation_jobs import process_inventory_maintenance, process_queued_jobs

logger = get_logger(__name__)
_running = True


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

        logger.info(
            "worker_heartbeat",
            redis=ok,
            jobs_processed=processed,
            topups_enqueued=enqueued,
        )
        await asyncio.sleep(5 if (processed or enqueued) else 10)

    await close_redis()
    logger.info("worker_stopped")


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
