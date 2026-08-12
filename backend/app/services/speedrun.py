"""Speedrun rules — the clock is the game.

Every other mode counts questions. Speedrun counts seconds: a run opens with a
short bank of time that drains continuously, correct answers buy time back, and
mistakes burn it. The player is never playing for "one more question", they are
playing to stay alive, which is what makes the mode compulsive.

Two escalators guarantee a run ends. The per-question limit tightens the deeper
you get, and the time a correct answer refunds decays with depth. Together they
push even a perfect player clock-negative eventually, so a leaderboard entry
measures how long someone held on rather than how long they were willing to sit
there.

Everything here is pure and server-authoritative. The client mirrors a couple of
these numbers for display only (see `mobile/lib/features/quiz/domain/
speedrun_rules.dart`); if the two ever drift, play stays correct and the HUD
reconciles on the next answer.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from app.core.config import get_settings

# --- The clock -------------------------------------------------------------

#: Time in the bank when a run starts. Deliberately below the old 60s budget:
#: the run should feel short from the first question and be *extended* by good
#: play rather than handed over up front.
START_CLOCK_MS = 45_000

#: Hard ceiling on banked time. Without it a strong opening streak snowballs
#: into a run that no longer has any tension in it.
CLOCK_CAP_MS = 60_000

#: The verdict flash after each answer. The clock keeps running through it, so
#: it is charged like any other time. Mirrored client-side as the flash
#: duration so both sides agree on what the player just watched drain.
FEEDBACK_BURN_MS = 800

#: What a wrong answer costs off the clock. Roughly one question's worth of
#: banked time — enough that two mistakes in a row visibly threaten the run.
WRONG_PENALTY_MS = 3_000


# --- Question pacing -------------------------------------------------------

QUESTION_LIMIT_START_MS = 10_000
QUESTION_LIMIT_FLOOR_MS = 4_000
#: Every STEP_EVERY questions the limit drops by STEP_MS, down to the floor.
QUESTION_LIMIT_STEP_MS = 750
QUESTION_LIMIT_STEP_EVERY = 4


# --- Time refunds ----------------------------------------------------------

TIME_BONUS_MIN_MS = 1_200
TIME_BONUS_MAX_MS = 3_500
#: >1 biases the refund hard toward fast answers: dawdling to a correct answer
#: pays close to the minimum, snap answers pay close to the maximum.
TIME_BONUS_CURVE = 1.5
#: Refunds shrink as the run gets deep — the second escalator.
BONUS_DECAY_PER_ANSWER = 0.015
BONUS_DECAY_FLOOR = 0.40


# --- Points ----------------------------------------------------------------

WRONG_PENALTY_POINTS = 50
#: Speed pays far better here than in other modes (which cap at 50).
SPEED_BONUS_MAX_POINTS = 150
SPEED_BONUS_CURVE = 1.5

#: Steeper and taller than the shared tiers — a hot streak is the whole point.
STREAK_TIERS: tuple[tuple[int, str], ...] = (
    (0, "1.0"),
    (3, "1.25"),
    (5, "1.5"),
    (8, "2.0"),
    (12, "2.5"),
    (16, "3.0"),
)

#: Streak at which the run enters OVERDRIVE (HUD goes hot, multiplier >= 1.5).
OVERDRIVE_STREAK = 5

#: Every Nth answer of a streak pays a lump bonus that grows with the streak.
MILESTONE_EVERY = 5
MILESTONE_POINTS = 100
MILESTONE_POINTS_CAP = 500


def question_time_limit_ms(depth: int) -> int:
    """Per-question limit at `depth` (0-based question index in the run)."""
    steps = max(0, depth) // QUESTION_LIMIT_STEP_EVERY
    limit = QUESTION_LIMIT_START_MS - steps * QUESTION_LIMIT_STEP_MS
    return max(QUESTION_LIMIT_FLOOR_MS, limit)


def _speed_ratio(remaining_ms: int, limit_ms: int) -> float:
    if limit_ms <= 0:
        return 0.0
    return min(max(remaining_ms / limit_ms, 0.0), 1.0)


def time_bonus_ms(*, remaining_ms: int, limit_ms: int, depth: int) -> int:
    """Clock a correct answer buys back, by speed and run depth."""
    ratio = _speed_ratio(remaining_ms, limit_ms)
    span = TIME_BONUS_MAX_MS - TIME_BONUS_MIN_MS
    raw = TIME_BONUS_MIN_MS + span * (ratio**TIME_BONUS_CURVE)
    decay = max(BONUS_DECAY_FLOOR, 1.0 - BONUS_DECAY_PER_ANSWER * max(0, depth))
    return int(round(raw * decay))


def speed_tier(remaining_ms: int, limit_ms: int) -> str:
    """Label the client turns into the verdict flash ("BLITZ", "FAST", …)."""
    ratio = _speed_ratio(remaining_ms, limit_ms)
    if ratio >= 0.75:
        return "blitz"
    if ratio >= 0.5:
        return "fast"
    if ratio >= 0.25:
        return "clean"
    return "clutch"


def streak_multiplier(streak: int) -> Decimal:
    multiplier = Decimal("1.0")
    for threshold, value in STREAK_TIERS:
        if streak >= threshold:
            multiplier = Decimal(value)
    return multiplier


def speed_bonus_points(remaining_ms: int, limit_ms: int) -> int:
    ratio = _speed_ratio(remaining_ms, limit_ms)
    return int(round((ratio**SPEED_BONUS_CURVE) * SPEED_BONUS_MAX_POINTS))


def milestone_bonus(streak: int) -> int:
    """Lump bonus when a streak crosses a multiple of MILESTONE_EVERY."""
    if streak <= 0 or streak % MILESTONE_EVERY != 0:
        return 0
    return min(MILESTONE_POINTS * (streak // MILESTONE_EVERY), MILESTONE_POINTS_CAP)


def is_overdrive(streak: int) -> bool:
    return streak >= OVERDRIVE_STREAK


def max_points_per_answer() -> int:
    """Ceiling one speedrun answer can legitimately pay — feeds anti-cheat."""
    base = get_settings().score_base_points
    top = float(Decimal(STREAK_TIERS[-1][1]))
    return int(round((base + SPEED_BONUS_MAX_POINTS) * top)) + MILESTONE_POINTS_CAP


@dataclass(frozen=True)
class ClockOutcome:
    remaining_ms: int
    #: Signed change the answer itself made — refund when right, penalty when
    #: wrong. This is the number the HUD flashes over the clock.
    delta_ms: int
    #: What the question and its verdict flash took off the clock.
    burned_ms: int
    #: Clock hit zero: the run is over.
    exhausted: bool


def apply_clock(
    *,
    clock_ms: int,
    elapsed_ms: int,
    limit_ms: int,
    is_correct: bool,
    depth: int,
) -> ClockOutcome:
    """Advance the run clock for one answer.

    Time spent on the question is charged first. If that alone empties the bank
    the player ran out mid-question — the answer earns nothing and the run is
    over, however it was marked. Otherwise the refund (or penalty) lands, the
    verdict flash is charged, and the result is clamped into [0, cap].
    """
    spent = max(0, min(elapsed_ms, limit_ms))
    if clock_ms - spent <= 0:
        return ClockOutcome(
            remaining_ms=0,
            delta_ms=0,
            burned_ms=max(0, clock_ms),
            exhausted=True,
        )

    if is_correct:
        delta = time_bonus_ms(
            remaining_ms=max(0, limit_ms - elapsed_ms),
            limit_ms=limit_ms,
            depth=depth,
        )
    else:
        delta = -WRONG_PENALTY_MS

    burned = spent + FEEDBACK_BURN_MS
    remaining = min(CLOCK_CAP_MS, max(0, clock_ms - burned + delta))
    return ClockOutcome(
        remaining_ms=remaining,
        delta_ms=delta,
        burned_ms=burned,
        exhausted=remaining <= 0,
    )
