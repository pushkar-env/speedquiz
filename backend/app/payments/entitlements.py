"""Subscription / entitlement stubs.

Current policy: free users are unlimited for unique questions and custom topics
(aside from the existing daily custom-topic soft limit).

Roadmap (Phase 6+ monetization)
--------------------------------
- Soft-gate free users after ~30 unique questions per topic.
- Offer diamonds / premium to continue toward the 1000 unique bank ceiling.
- Server remains source of truth; clients never invent entitlements.
"""

from __future__ import annotations

from typing import Optional

from app.core.config import get_settings
from app.models import User

settings = get_settings()


def unique_question_allowance(user: Optional[User]) -> Optional[int]:
    """Max unique questions a user may consume per topic before a paywall.

    Returns None for unlimited (default free experience today).
    """
    if not settings.entitlements_enforce_question_caps:
        return None
    if user is None:
        return settings.free_unique_questions_per_topic
    if user.is_premium:
        return settings.topic_bank_target_unique
    return settings.free_unique_questions_per_topic


def custom_topics_unlimited(user: Optional[User]) -> bool:
    if user and user.is_premium:
        return True
    return not settings.entitlements_enforce_question_caps
