"""Premium cosmetics — the avatar ids and flair that Premium unlocks.

The client draws avatars from its own catalog (gradient + glyph), and the
server only ever stores the id string. That split is fine for rendering, but a
cosmetic that is *sold* has to be enforced somewhere the user cannot edit —
otherwise a hand-rolled `PATCH /users/me {"avatar_id": "avatar_p01"}` gets the
premium set for free.

So the ids live here too. The client catalog stays the source of truth for how
an avatar *looks*; this module is the source of truth for who may wear it.
"""

from __future__ import annotations

from typing import Optional

from app.models import User

#: Available to everyone. Mirrors AvatarCatalog.presets on the client.
FREE_AVATAR_IDS = frozenset(f"avatar_{i:02d}" for i in range(1, 13))

#: Premium-only. Mirrors AvatarCatalog.premiumPresets on the client.
PREMIUM_AVATAR_IDS = frozenset(f"avatar_p{i:02d}" for i in range(1, 7))

ALL_AVATAR_IDS = FREE_AVATAR_IDS | PREMIUM_AVATAR_IDS

#: What the client seeds a brand-new profile with.
DEFAULT_AVATAR_ID = "avatar_01"


def is_premium_avatar(avatar_id: Optional[str]) -> bool:
    return (avatar_id or "").strip() in PREMIUM_AVATAR_IDS


def is_known_avatar(avatar_id: Optional[str]) -> bool:
    return (avatar_id or "").strip() in ALL_AVATAR_IDS


def can_use_avatar(user: Optional[User], avatar_id: Optional[str]) -> bool:
    if not is_premium_avatar(avatar_id):
        return True
    return bool(user and user.is_premium)


def profile_flair(user: Optional[User]) -> dict[str, bool]:
    """Non-avatar cosmetics keyed off the same entitlement."""
    premium = bool(user and user.is_premium)
    return {
        # Animated gradient ring around the profile avatar.
        "animated_ring": premium,
        # Gold badge next to the name on leaderboards and shared results.
        "premium_badge": premium,
    }
