"""Daily challenge constants + deterministic seeding (no I/O)."""

from __future__ import annotations

import hashlib
from datetime import date

DAILY_TARGET_COUNT = 10
DAILY_MIN_COUNT = 5


def seed_for_date(d: date) -> int:
    digest = hashlib.sha256(d.isoformat().encode()).hexdigest()
    return int(digest[:16], 16)
