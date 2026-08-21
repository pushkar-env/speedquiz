"""A client-side token-per-minute budget.

Vision calls are token-heavy -- a high-detail crop costs more than the prompt
around it -- so a handful of concurrent requests will breach a 30k TPM tier
within seconds. Retrying into a limit you are still breaching just burns the
retry budget, which is how a run ends up losing 20 of 75 questions.

So requests reserve their estimated cost before going out, and wait when the
rolling window is full. `Retry-After` from a 429 still takes precedence: the
server knows the real state and this is only an estimate.
"""

from __future__ import annotations

import asyncio
import time
from collections import deque


def estimate_image_tokens(png_bytes: int) -> int:
    """Rough token cost of an image at `detail: high`.

    High-detail images are tiled into 512px squares at roughly 170 tokens each
    plus an 85-token base. Deriving the tile count needs the dimensions, which
    the caller does not always have handy, so this approximates from the
    encoded size -- consistently on the generous side, because under-estimating
    is what causes the 429 this class exists to avoid.
    """
    return max(300, min(3000, 85 + png_bytes // 90))


class TokenBucket:
    """Sliding-window limiter over a rolling 60 seconds."""

    def __init__(self, tokens_per_minute: int) -> None:
        self.limit = max(1000, tokens_per_minute)
        self._events: deque[tuple[float, int]] = deque()
        self._lock = asyncio.Lock()
        #: Set by a 429 handler; every waiter holds off until it passes.
        self._blocked_until = 0.0

    def _spent(self, now: float) -> int:
        while self._events and now - self._events[0][0] > 60.0:
            self._events.popleft()
        return sum(count for _timestamp, count in self._events)

    async def acquire(self, tokens: int) -> None:
        # A single request larger than the whole budget would wait forever;
        # let it through and let the server be the judge.
        tokens = min(tokens, self.limit)
        while True:
            async with self._lock:
                now = time.monotonic()
                if now >= self._blocked_until and self._spent(now) + tokens <= self.limit:
                    self._events.append((now, tokens))
                    return
                if self._events:
                    oldest = self._events[0][0]
                    wait = max(self._blocked_until - now, 60.0 - (now - oldest), 0.05)
                else:
                    wait = max(self._blocked_until - now, 0.05)
            await asyncio.sleep(min(wait, 30.0))

    async def penalize(self, seconds: float) -> None:
        """Called on a 429: hold every waiter for `seconds`."""
        async with self._lock:
            self._blocked_until = max(self._blocked_until, time.monotonic() + seconds)

    def record_actual(self, estimated: int, actual: int) -> None:
        """Reconcile an estimate against the usage the API reported.

        Without this the window drifts optimistic on image-heavy calls and the
        limiter slowly stops limiting.
        """
        if actual <= estimated or not self._events:
            return
        timestamp, count = self._events[-1]
        self._events[-1] = (timestamp, count + (actual - estimated))
