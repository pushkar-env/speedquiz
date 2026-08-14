"""Shared SQL predicates for the question bank.

One definition of "playable", imported by every path that reads the bank.
There are five such paths — the session dealer, the daily challenge builder,
matchmaking's depth check, inventory counting and the custom-topic cache probe
— and a freshness rule that only some of them apply is worse than no rule at
all: the dealer would skip an expired question while inventory still counted it
as stock, so the topic would look full and never top up.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import or_

from app.models import Question, QuestionStatus


def not_expired(moment: Optional[datetime] = None):
    """True for questions that have not passed their ``expires_at``.

    A NULL ``expires_at`` is permanent — that is every row written before
    freshness existed, and every question about a settled subject since.
    """
    now = moment or datetime.now(timezone.utc)
    return or_(Question.expires_at.is_(None), Question.expires_at > now)


def playable(*, language: Optional[str] = None, moment: Optional[datetime] = None) -> list:
    """The full "can be dealt right now" predicate list, ready to splat into
    a ``.where()``.

    Callers already scope by topic; language is optional because inventory
    counts both per-language and in total.
    """
    clauses = [Question.status == QuestionStatus.ACTIVE, not_expired(moment)]
    if language is not None:
        clauses.append(Question.language == language)
    return clauses
