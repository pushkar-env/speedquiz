"""Subscription / entitlement stubs.

Current policy: free users are unlimited unless ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true.

Roadmap (real IAP later)
------------------------
- Soft-gate free users after ~30 unique questions per topic.
- Offer diamonds / premium to continue toward the 1000 unique bank ceiling.
- Server remains source of truth; clients never invent entitlements.
"""

from __future__ import annotations

from typing import Any, Optional

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
        return None  # premium unlimited (toward bank target operationally)
    return settings.free_unique_questions_per_topic


def custom_topics_unlimited(user: Optional[User]) -> bool:
    if user and user.is_premium:
        return True
    return not settings.entitlements_enforce_question_caps


def entitlements_status(user: User) -> dict[str, Any]:
    enforce = bool(settings.entitlements_enforce_question_caps)
    return {
        "is_premium": bool(user.is_premium),
        "enforce_caps": enforce,
        "unique_per_topic_limit": (
            None
            if user.is_premium or not enforce
            else settings.free_unique_questions_per_topic
        ),
        "custom_topics_unlimited": custom_topics_unlimited(user),
        "dev_toggle_allowed": (
            not settings.is_production or settings.entitlements_dev_toggle
        ),
        "premium_product_id": settings.iap_premium_product_id,
    }
