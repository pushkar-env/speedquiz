"""Ranked rating: Elo, tiers, and seasons.

Only rated 1v1 duels reach this module. Friend challenges and rooms are
deliberately unrated — the point of challenging a friend is that it costs
nothing, and a ladder attached to it would suppress exactly the behaviour the
social features exist to create.

Why Elo rather than Glicko or TrueSkill
---------------------------------------
Elo's weakness is that it does not model rating *uncertainty*, so a new player
takes many games to reach their real bracket. That weakness is addressed here
by a larger K during placements, which is most of what Glicko's rating
deviation buys for a two-player symmetric game — at a fraction of the state and
with a number players can reason about. If team modes ever ship, revisit this.

Seasons are a key (`YYYY-MM`), not a table
------------------------------------------
Rollover is then the first ranked match of a month creating a fresh row seeded
from the previous one. There is no scheduled job that can fail to run, no
window where the ladder is missing, and a player who skips three months simply
gets a new row when they come back.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Optional
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models import MatchOutcome, PlayerRating


@dataclass(frozen=True)
class Tier:
    """A visible rank band. Ordered, contiguous, and open at the top."""

    code: str
    name: str
    min_rating: int
    #: Icon key the client maps to an asset. Kept server-side so a tier can be
    #: renamed or re-cut without shipping an app update.
    icon: str


#: Cut points chosen so a new player at 1000 starts in the middle of Silver:
#: promotion is reachable in a good session and demotion is survivable, which
#: is what stops a ladder feeling either static or punishing.
TIERS: tuple[Tier, ...] = (
    Tier("bronze", "Bronze", 0, "tier_bronze"),
    Tier("silver", "Silver", 900, "tier_silver"),
    Tier("gold", "Gold", 1100, "tier_gold"),
    Tier("platinum", "Platinum", 1300, "tier_platinum"),
    Tier("diamond", "Diamond", 1500, "tier_diamond"),
    Tier("master", "Master", 1750, "tier_master"),
    Tier("legend", "Legend", 2000, "tier_legend"),
)

#: Shown instead of a tier until placements are done, so a provisional rating
#: is never mistaken for an earned one.
UNRANKED_TIER = Tier("unranked", "Unranked", 0, "tier_unranked")


def tier_for(rating: int, *, placements_remaining: int = 0) -> Tier:
    if placements_remaining > 0:
        return UNRANKED_TIER
    current = TIERS[0]
    for tier in TIERS:
        if rating >= tier.min_rating:
            current = tier
    return current


def next_tier(rating: int) -> Optional[Tier]:
    """The band above `rating`, or None at the top. Drives the progress bar."""
    for tier in TIERS:
        if tier.min_rating > rating:
            return tier
    return None


def season_key(moment: Optional[date] = None) -> str:
    """Current season identifier, e.g. `2026-08`.

    UTC rather than local time: a season that ends at a different instant for
    each player makes the final ladder unresolvable.
    """
    today = moment or datetime.now(timezone.utc).date()
    return f"{today.year:04d}-{today.month:02d}"


def expected_score(rating: int, opponent_rating: int) -> float:
    """Elo expectation — the probability `rating` beats `opponent_rating`."""
    return 1.0 / (1.0 + 10.0 ** ((opponent_rating - rating) / 400.0))


def _outcome_value(outcome: MatchOutcome) -> float:
    return {
        MatchOutcome.WIN: 1.0,
        MatchOutcome.DRAW: 0.5,
        MatchOutcome.LOSS: 0.0,
    }[outcome]


def k_factor(placements_remaining: int) -> int:
    settings = get_settings()
    if placements_remaining > 0:
        return settings.ranked_placement_k_factor
    return settings.ranked_k_factor


def rating_delta(
    *,
    rating: int,
    opponent_rating: int,
    outcome: MatchOutcome,
    placements_remaining: int = 0,
) -> int:
    """Points this result is worth: rounded to nearest, but never to zero.

    The never-to-zero floor matters at the extremes. A heavy favourite who wins
    is owed a fraction of a point, and rounding that down means a player at the
    top of the ladder can win all evening and watch their rating never move —
    which reads as the game being broken rather than as the maths being right.
    """
    expected = expected_score(rating, opponent_rating)
    raw = k_factor(placements_remaining) * (_outcome_value(outcome) - expected)
    if raw == 0:
        return 0

    rounded = int(raw + (0.5 if raw > 0 else -0.5))
    if rounded != 0:
        return rounded
    return 1 if raw > 0 else -1


def carry_over_rating(previous_rating: int) -> int:
    """Seed a new season from the last one: pull toward the mean, keep order.

    A full reset throws away everything the ladder learned and puts a Legend
    back among beginners for a week. No reset makes a new season meaningless.
    Regression to the mean keeps the ordering while making the top reachable
    again, which is the point of having seasons at all.
    """
    settings = get_settings()
    start = settings.ranked_starting_rating
    factor = max(0.0, min(1.0, settings.ranked_season_carryover))
    return int(round(start + (previous_rating - start) * factor))


async def get_or_create_rating(
    db: AsyncSession,
    user_id: UUID,
    *,
    key: Optional[str] = None,
) -> PlayerRating:
    """This player's rating row for the season, seeded from the last one.

    The seed lookup deliberately takes the most recent *any* season rather than
    strictly last month's, so a player returning after a gap keeps their
    standing instead of restarting from scratch.
    """
    settings = get_settings()
    key = key or season_key()

    existing = await db.scalar(
        select(PlayerRating).where(
            PlayerRating.user_id == user_id, PlayerRating.season_key == key
        )
    )
    if existing is not None:
        return existing

    previous = await db.scalar(
        select(PlayerRating)
        .where(PlayerRating.user_id == user_id, PlayerRating.season_key != key)
        .order_by(PlayerRating.season_key.desc())
        .limit(1)
    )
    seed = (
        carry_over_rating(previous.rating)
        if previous is not None
        else settings.ranked_starting_rating
    )
    row = PlayerRating(
        id=uuid4(),
        user_id=user_id,
        season_key=key,
        rating=seed,
        peak_rating=seed,
        placements_remaining=settings.ranked_placement_matches,
    )
    db.add(row)
    await db.flush()
    return row


def apply_result(rating_row: PlayerRating, *, delta: int, outcome: MatchOutcome) -> None:
    """Fold one finished duel into a rating row. Caller owns the transaction."""
    rating_row.rating = max(0, rating_row.rating + delta)
    rating_row.peak_rating = max(rating_row.peak_rating, rating_row.rating)
    rating_row.matches_played += 1
    rating_row.placements_remaining = max(0, rating_row.placements_remaining - 1)
    rating_row.last_match_at = datetime.now(timezone.utc)

    if outcome is MatchOutcome.WIN:
        rating_row.wins += 1
        rating_row.win_streak += 1
        rating_row.best_win_streak = max(rating_row.best_win_streak, rating_row.win_streak)
    elif outcome is MatchOutcome.LOSS:
        rating_row.losses += 1
        rating_row.win_streak = 0
    else:
        rating_row.draws += 1
        rating_row.win_streak = 0
