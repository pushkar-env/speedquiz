"""Usernames and friend codes — the two things a stranger can find you by.

Until multiplayer, a username was a label: generated (`player_9f2ab41c`), shown
on a leaderboard, never typed by anyone. Once other players search by it and
challenge by it, it becomes an identity, and identities need rules:

* **Case-insensitive uniqueness.** `Ravi` and `ravi` must not both exist, or
  "add ravi" is ambiguous and impersonation is a rename away.
* **A confusable check on top of that.** Case folding alone still lets `Ravi`
  register again as `R4vi`. Uniqueness is therefore enforced on a *skeleton* —
  lowercased, digits folded to the letters they imitate, separators dropped —
  stored in its own column with a unique index. That index is what actually
  guarantees the property; this module owns the friendly error that fires
  before it does, and is the only place allowed to write the pair.
* **A rename cooldown.** A friend list is worthless if the name on it changes
  weekly. The first change is free, because the generated name is not a choice.

Friend codes exist so a username never has to be dictated over a noisy call.
The alphabet has no vowels (a code cannot spell a word) and no 0/O or 1/I/L
(a code cannot be misread), which is worth more than the four extra bits a
fuller alphabet would buy.
"""

from __future__ import annotations

import re
import secrets
import unicodedata
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models import UserProfile

USERNAME_MIN_LENGTH = 3
USERNAME_MAX_LENGTH = 20

#: Must start with a letter so a username can never be mistaken for an id, a
#: friend code, or a number in a URL.
_USERNAME_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_]{2,19}$")

#: Days before a chosen username can be changed again. The first change from
#: the generated name does not count — see [can_change_username_at].
USERNAME_CHANGE_COOLDOWN_DAYS = 30

#: Prefix of every auto-generated username. Nobody may claim this space, or
#: they could squat the name a future guest would be assigned.
GENERATED_USERNAME_PREFIX = "player_"

FRIEND_CODE_LENGTH = 8
#: No vowels, so a code can never accidentally spell a word. No 0/O/1/I/L,
#: so it can never be misread aloud or from a screenshot. That leaves 28
#: symbols; over 8 places that is ~38 bits, which is far more than a friend
#: code needs and small enough to read out in one breath.
FRIEND_CODE_ALPHABET = "23456789BCDFGHJKMNPQRSTVWXYZ"

#: Names that must never belong to a player, because seeing them next to a
#: message would imply the message came from us.
RESERVED_USERNAMES = frozenset(
    {
        "speedquiz",
        "admin",
        "administrator",
        "root",
        "system",
        "support",
        "help",
        "helpdesk",
        "moderator",
        "mod",
        "staff",
        "team",
        "official",
        "security",
        "billing",
        "payments",
        "noreply",
        "no_reply",
        "anonymous",
        "guest",
        "null",
        "undefined",
        "me",
        "you",
        "everyone",
        "here",
    }
)

#: Substring matches against the folded skeleton, so `sh1t_lord` is caught by
#: `shit`. Deliberately short and unambiguous: a long list of near-words costs
#: real players their names, and the report/block path exists for the rest.
#: Extend per deployment with ``USERNAME_BLOCKED_TERMS`` rather than editing
#: this tuple.
_BLOCKED_TERMS: tuple[str, ...] = (
    "fuck",
    "shit",
    "cunt",
    "nigger",
    "nigga",
    "faggot",
    "rape",
    "rapist",
    "paedo",
    "pedophile",
    "chutiya",
    "madarchod",
    "behenchod",
    "bhosdi",
    "randi",
)

#: Digits that stand in for letters when someone is dodging a filter.
#:
#: Kept to exactly the digit set so this can be expressed as a Postgres
#: ``translate()`` in migration 0006, which backfills the same skeleton for
#: rows that predate the column. If the two ever disagree, old and new accounts
#: stop being comparable — so change both or neither.
_LEET_FROM = "01345789"
_LEET_TO = "oieastbg"
_CONFUSABLE_FOLD = str.maketrans(_LEET_FROM, _LEET_TO)


def normalize_username(raw: str) -> str:
    """Trim and NFKC-normalize, without changing case.

    NFKC first: it collapses the fullwidth and mathematical letter variants
    that would otherwise sail past both the pattern check and the uniqueness
    index while rendering identically to an ordinary name.
    """
    return unicodedata.normalize("NFKC", (raw or "").strip())


def username_skeleton(name: str) -> str:
    """The form two usernames are compared as when judging impersonation.

    Lowercased, leet-folded, and stripped of separators, so `R4vi`, `ravi` and
    `r_a_v_i` all reduce to `ravi`. Used for availability and for the blocklist;
    *not* used as the stored value, which keeps the player's own spelling.
    """
    folded = unicodedata.normalize("NFKD", name.lower()).translate(_CONFUSABLE_FOLD)
    return re.sub(r"[^a-z0-9]", "", folded)


def _blocked_terms() -> tuple[str, ...]:
    extra = getattr(get_settings(), "username_blocked_terms", "") or ""
    custom = tuple(t.strip().lower() for t in extra.split(",") if t.strip())
    return _BLOCKED_TERMS + custom


def validate_username(raw: str) -> str:
    """Return the storable username, or raise 422 with a specific reason.

    Raises rather than returning a result object because every caller — claim,
    availability check, registration — wants the same HTTP shape, and the
    client renders the message from ``detail.code`` rather than the prose.
    """
    name = normalize_username(raw)

    if len(name) < USERNAME_MIN_LENGTH or len(name) > USERNAME_MAX_LENGTH:
        _reject(
            "username_length",
            f"Username must be {USERNAME_MIN_LENGTH}-{USERNAME_MAX_LENGTH} characters.",
        )
    if not _USERNAME_PATTERN.match(name):
        _reject(
            "username_charset",
            "Use letters, numbers and underscores, starting with a letter.",
        )
    if "__" in name:
        _reject("username_charset", "Underscores cannot be doubled.")
    if name.endswith("_"):
        _reject("username_charset", "Username cannot end with an underscore.")

    skeleton = username_skeleton(name)
    if not skeleton:
        _reject("username_charset", "Username needs at least one letter or number.")
    if name.lower().startswith(GENERATED_USERNAME_PREFIX):
        _reject("username_reserved", "That name is reserved.")
    if skeleton in RESERVED_USERNAMES or name.lower() in RESERVED_USERNAMES:
        _reject("username_reserved", "That name is reserved.")
    for term in _blocked_terms():
        if term in skeleton:
            _reject("username_blocked", "Please choose a different name.")

    return name


def _reject(code: str, message: str) -> None:
    raise HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        detail={"code": code, "message": message},
    )


async def is_username_available(
    db: AsyncSession,
    username: str,
    *,
    exclude_user_id: Optional[UUID] = None,
) -> bool:
    """True when nothing confusable with `username` is already taken.

    One indexed lookup, because the confusable form is a stored column rather
    than something recomputed per row. An earlier draft scanned candidates and
    folded them in Python; that was both slower and wrong — a name like `4li`
    folds to `ali`, so any prefilter keyed on the letters actually present in
    the string misses exactly the collisions worth catching.
    """
    skeleton = username_skeleton(username)
    if not skeleton:
        return False

    stmt = select(UserProfile.user_id).where(UserProfile.username_skeleton == skeleton)
    if exclude_user_id is not None:
        stmt = stmt.where(UserProfile.user_id != exclude_user_id)
    return await db.scalar(stmt.limit(1)) is None


def can_change_username_at(profile: UserProfile) -> Optional[datetime]:
    """When this player may next change their name, or None if right now.

    A player still carrying the generated name has never made a choice, so
    their first change is always allowed — charging a 30-day cooldown for
    escaping `player_9f2ab41c` would punish exactly the people the feature is
    meant to serve.
    """
    if profile.username_changed_at is None:
        return None
    unlock = profile.username_changed_at + timedelta(days=USERNAME_CHANGE_COOLDOWN_DAYS)
    now = datetime.now(timezone.utc)
    if unlock.tzinfo is None:
        unlock = unlock.replace(tzinfo=timezone.utc)
    return None if unlock <= now else unlock


async def claim_username(
    db: AsyncSession,
    profile: UserProfile,
    raw: str,
) -> str:
    """Validate, check the cooldown, and write the new username.

    Does not commit — the caller's request-scoped session owns that. The
    database still has the final say on uniqueness: two players can pass
    [is_username_available] in the same instant, and the loser gets a 409 from
    the unique index rather than a silently duplicated handle.
    """
    name = validate_username(raw)

    if username_skeleton(name) == (profile.username_skeleton or ""):
        # Respelling your own name (ravi -> Ravi, ra_vi -> ravi) is free and
        # does not consume the cooldown: to everyone else it is the same
        # identity, which is precisely what sharing a skeleton means.
        set_username(profile, name)
        return name

    unlock_at = can_change_username_at(profile)
    if unlock_at is not None:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={
                "code": "username_cooldown",
                "message": "You can change your username again later.",
                "available_at": unlock_at.isoformat(),
            },
        )

    if not await is_username_available(db, name, exclude_user_id=profile.user_id):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"code": "username_taken", "message": "That name is already taken."},
        )

    set_username(profile, name)
    profile.username_changed_at = datetime.now(timezone.utc)
    return name


def profile_username_fields(name: str) -> dict[str, str]:
    """Identity columns for a brand-new ``UserProfile``.

    Spelled as constructor kwargs because a profile is created in four places
    (guest, email register, guest upgrade, Google) and every one of them has to
    set both columns — see [set_username] for why.
    """
    return {"username": name, "username_skeleton": username_skeleton(name)}


def set_username(profile: UserProfile, name: str) -> None:
    """Write a username and its skeleton together.

    The two columns are one fact stored twice, and the skeleton carries a
    unique index — writing `username` alone leaves the row claiming an identity
    the index still thinks belongs to the old name. Every path that assigns a
    username, including guest and Google account creation, goes through here.
    """
    profile.username = name
    profile.username_skeleton = username_skeleton(name)


def generate_friend_code() -> str:
    return "".join(secrets.choice(FRIEND_CODE_ALPHABET) for _ in range(FRIEND_CODE_LENGTH))


def normalize_friend_code(raw: str) -> str:
    """Uppercase and strip the separators a human adds when retyping a code.

    Deliberately does *not* guess at look-alikes. The alphabet already excludes
    every ambiguous glyph, so a character outside it means the code was
    mistyped — and mapping, say, a typed `O` onto some in-alphabet neighbour
    would silently resolve one player's mistake into a different player's real
    code. Returning something that fails to match is the honest answer.
    """
    return re.sub(r"[^A-Za-z0-9]", "", (raw or "")).upper()


def is_valid_friend_code(code: str) -> bool:
    return len(code) == FRIEND_CODE_LENGTH and all(c in FRIEND_CODE_ALPHABET for c in code)


async def ensure_friend_code(db: AsyncSession, profile: UserProfile) -> str:
    """Return this player's invite code, minting one on first use.

    Lazy rather than backfilled by the migration: a code is worthless until its
    owner opens the app, and that read is a perfectly good place to make one.
    """
    if profile.friend_code:
        return profile.friend_code

    for _ in range(8):
        code = generate_friend_code()
        taken = await db.scalar(
            select(UserProfile.user_id).where(UserProfile.friend_code == code).limit(1)
        )
        if not taken:
            profile.friend_code = code
            await db.flush()
            return code

    # 8 collisions against a 39-bit space means something is very wrong.
    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail={"code": "friend_code_unavailable", "message": "Try again in a moment."},
    )


async def find_by_friend_code(db: AsyncSession, raw: str) -> Optional[UserProfile]:
    code = normalize_friend_code(raw)
    if not is_valid_friend_code(code):
        return None
    return await db.scalar(select(UserProfile).where(UserProfile.friend_code == code))
