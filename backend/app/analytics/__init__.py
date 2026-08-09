"""Analytics abstraction — Phase 6."""

from abc import ABC, abstractmethod
from typing import Any


class AnalyticsProvider(ABC):
    @abstractmethod
    async def track(self, event: str, properties: dict[str, Any] | None = None) -> None:
        raise NotImplementedError


class NullAnalyticsProvider(AnalyticsProvider):
    async def track(self, event: str, properties: dict[str, Any] | None = None) -> None:
        return None
