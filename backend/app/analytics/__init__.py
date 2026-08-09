"""Analytics abstraction — Phase 6a Postgres events."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Optional
from uuid import UUID, uuid4

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.logging import get_logger

logger = get_logger(__name__)


class AnalyticsProvider(ABC):
    @abstractmethod
    async def track(
        self,
        db: AsyncSession,
        event: str,
        *,
        user_id: Optional[UUID] = None,
        properties: dict[str, Any] | None = None,
    ) -> None:
        raise NotImplementedError


class NullAnalyticsProvider(AnalyticsProvider):
    async def track(
        self,
        db: AsyncSession,
        event: str,
        *,
        user_id: Optional[UUID] = None,
        properties: dict[str, Any] | None = None,
    ) -> None:
        return None


class PostgresAnalyticsProvider(AnalyticsProvider):
    async def track(
        self,
        db: AsyncSession,
        event: str,
        *,
        user_id: Optional[UUID] = None,
        properties: dict[str, Any] | None = None,
    ) -> None:
        from app.models import AnalyticsEvent

        db.add(
            AnalyticsEvent(
                id=uuid4(),
                user_id=user_id,
                event=event[:128],
                properties=properties or {},
            )
        )
        await db.flush()


_provider: AnalyticsProvider | None = None


def get_analytics() -> AnalyticsProvider:
    global _provider
    if _provider is None:
        backend = (get_settings().analytics_provider or "postgres").lower()
        if backend == "null":
            _provider = NullAnalyticsProvider()
        else:
            _provider = PostgresAnalyticsProvider()
    return _provider


async def track_event(
    db: AsyncSession,
    event: str,
    *,
    user_id: Optional[UUID] = None,
    properties: dict[str, Any] | None = None,
) -> None:
    """Best-effort analytics write — callers should still wrap in try/except."""
    try:
        await get_analytics().track(db, event, user_id=user_id, properties=properties)
    except Exception as exc:
        logger.warning("analytics_track_failed", event=event, error=str(exc))
