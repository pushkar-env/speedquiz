"""Scoring rules that apply only to a two-player match.

Why a match does not score like a solo run
------------------------------------------
The casual curve in [app.services.scoring] rewards knowing the answer and
knowing it quickly. That is the whole game when you are playing alone. Against
an opponent it is not enough, for two reasons that show up immediately in a
seven-question duel:

* **Nothing rewards being first.** Two players who both answer correctly in
  under three seconds score within a few points of each other, so a round where
  one of them was visibly quicker settles almost level. The margin that decides
  the match ends up being whoever got a question the other did not know, which
  is the least interesting way for a duel to end.
* **A two-question gap ends the match with rounds left to play.** Once the
  scoreline is out of reach the trailing player is answering for nothing, and
  the leading player is too. Both stop caring at the same moment.

So four rules stack on top of the shared base and speed curve:

1. **Combo.** Consecutive correct answers escalate to double. Streaks already
   existed but topped out at 1.25x after ten in a row — unreachable on a seven
   question board, which is to say it did not exist.
2. **First correct.** A flat bonus to whoever gets there first. Flat rather
   than multiplied so it reads as one clean number on the verdict, and small
   enough that it decides close rounds rather than the match.
3. **Final round doubles.** The board's last question is worth twice as much,
   which keeps a match alive to the end without inventing a separate mode.
4. **Catch-up.** The trailing player earns up to 1.3x, scaled by how far behind
   they are. Deliberately modest: enough that a deficit is recoverable by
   playing well, not so much that being behind is an advantage.

Every one of these is computed here, server side, from values the client cannot
influence beyond the elapsed time it reports — which is itself clamped before
it reaches this module.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.core.config import get_settings
from app.services.scoring import scoring_service

#: Consecutive correct answers -> multiplier, highest threshold first.
#:
#: Tuned for a seven-question board: reachable by the fourth question, so a good
#: run is rewarded inside a match rather than across a session.
COMBO_TIERS: tuple[tuple[int, float], ...] = ((4, 2.0), (3, 1.5), (2, 1.25))

#: Paid to the first player to answer a round correctly.
FIRST_CORRECT_BONUS = 15

#: The last question of the board is worth double.
FINAL_ROUND_MULTIPLIER = 2.0

#: Ceiling on the trailing player's multiplier, and the deficit at which it is
#: reached. Roughly two clean questions behind.
CATCHUP_MAX_MULTIPLIER = 1.3
CATCHUP_FULL_DEFICIT_POINTS = 300


def combo_multiplier(streak: int) -> float:
    """Multiplier for a run of `streak` correct answers, this one included."""
    for threshold, multiplier in COMBO_TIERS:
        if streak >= threshold:
            return multiplier
    return 1.0


def combo_label(streak: int) -> str:
    """Short name for the combo tier, for the client to celebrate.

    Returned as a code rather than prose: the client draws the word from its own
    string table, so a match reads in whatever language the app is set to.
    """
    if streak >= 4:
        return "unstoppable"
    if streak >= 3:
        return "onfire"
    if streak >= 2:
        return "combo"
    return ""


def catchup_multiplier(points_behind: int) -> float:
    """How much extra the trailing player earns, 1.0 to [CATCHUP_MAX_MULTIPLIER].

    Linear in the deficit rather than stepped, so there is no scoreline at which
    a player is better off dropping a question to cross a threshold.
    """
    if points_behind <= 0:
        return 1.0
    ratio = min(points_behind / CATCHUP_FULL_DEFICIT_POINTS, 1.0)
    return 1.0 + (CATCHUP_MAX_MULTIPLIER - 1.0) * ratio


@dataclass(frozen=True)
class MatchScore:
    """One scored answer, with every component the HUD wants to show."""

    points: int
    base_points: int
    speed_bonus: int
    combo_multiplier: float
    combo_label: str
    first_bonus: int
    catchup_multiplier: float
    is_final_round: bool
    new_streak: int


def score_answer(
    *,
    is_correct: bool,
    current_streak: int,
    remaining_ms: int,
    total_ms: int,
    is_first_correct: bool,
    is_final_round: bool,
    points_behind: int,
) -> MatchScore:
    """Score one answer in a match.

    A wrong answer is worth nothing and breaks the combo. It costs no points:
    the punishment for missing is the combo reset and the round the opponent
    just banked, and a negative score in a head-to-head reads as a bug.
    """
    if not is_correct:
        return MatchScore(
            points=0,
            base_points=0,
            speed_bonus=0,
            combo_multiplier=1.0,
            combo_label="",
            first_bonus=0,
            catchup_multiplier=1.0,
            is_final_round=is_final_round,
            new_streak=0,
        )

    settings = get_settings()
    new_streak = current_streak + 1
    base = settings.score_base_points
    speed = scoring_service.speed_bonus(remaining_ms, total_ms)
    combo = combo_multiplier(new_streak)
    catchup = catchup_multiplier(points_behind)

    scaled = (base + speed) * combo * catchup
    if is_final_round:
        scaled *= FINAL_ROUND_MULTIPLIER

    # Added after the multipliers, not before: being first is worth the same
    # fifteen points whether it happens on round one or inside a double-scoring
    # final, which is what makes it legible on the verdict card.
    first_bonus = FIRST_CORRECT_BONUS if is_first_correct else 0

    return MatchScore(
        points=int(round(scaled)) + first_bonus,
        base_points=base,
        speed_bonus=speed,
        combo_multiplier=combo,
        combo_label=combo_label(new_streak),
        first_bonus=first_bonus,
        catchup_multiplier=catchup,
        is_final_round=is_final_round,
        new_streak=new_streak,
    )


def max_points_per_answer() -> int:
    """The most a single legitimate answer can be worth.

    Derived from the constants above rather than written down, so raising a
    multiplier cannot silently start clamping honest answers — which is how a
    scoring change turns into "the combo stopped paying out" a week later.
    """
    settings = get_settings()
    best = (
        (settings.score_base_points + settings.score_speed_bonus_max)
        * max(m for _, m in COMBO_TIERS)
        * CATCHUP_MAX_MULTIPLIER
        * FINAL_ROUND_MULTIPLIER
    )
    return int(round(best)) + FIRST_CORRECT_BONUS


def clamp_points(points: int) -> int:
    """Floor at zero, ceiling at what the rules can actually produce."""
    return max(0, min(points, max_points_per_answer()))
