"""Survival rules — how long can you hold on with three lives.

The old survival mode was three lives, minus one per mistake, plus one every
ten correct. That is a rule set, not a hook: nothing changed as the run went
on, so a strong player never felt threatened and a weak one died early with no
way back. Both ended up bored.

Four mechanics fix that, and they interlock:

* **The clock tightens.** The per-question limit steps down as you go deeper,
  to a hard floor. This is what guarantees a run ends — without it a good
  player could sit at three lives indefinitely.
* **Lives come back, but each one costs more.** A streak earns a life; the next
  one needs a longer streak. Comebacks are real but not farmable.
* **Last stand.** On your final life every answer pays a large multiplier. The
  most dangerous moment in the run is also the most rewarding, which is what
  turns "I should stop" into "one more".
* **Checkpoints.** Every tenth correct answer pays a lump bonus that grows with
  depth, so a long run has visible milestones to aim at.

Everything here is pure and server-authoritative. The client mirrors a few of
these numbers for display only (see `mobile/lib/features/quiz/domain/
survival_rules.dart`); if the two drift, play stays correct and the HUD
reconciles on the next answer.
"""

from __future__ import annotations

from decimal import Decimal

# --- Lives -----------------------------------------------------------------

#: Lives a run opens with, and the ceiling a comeback can restore to. Capping
#: at the starting value stops a strong player banking lives into immortality.
START_LIVES = 3
MAX_LIVES = 3

#: Streak needed to earn the first life back.
REGAIN_BASE_STREAK = 7
#: Each life already regained adds this much to the next one's requirement, so
#: comebacks get progressively harder within a single run.
REGAIN_STEP = 4


# --- Question pacing -------------------------------------------------------

#: Slightly under the 15s casual limit — survival should feel brisker from the
#: first question, then keep tightening.
QUESTION_LIMIT_START_MS = 14_000
#: The floor is the real difficulty wall. Below ~6s, reading the question is
#: the bottleneck rather than knowing the answer, which stops being fair.
QUESTION_LIMIT_FLOOR_MS = 6_000
QUESTION_LIMIT_STEP_MS = 800
QUESTION_LIMIT_STEP_EVERY = 5


# --- Points ----------------------------------------------------------------

#: Multiplier applied on the final life. Deliberately large: the whole design
#: points at making the brink the best place to be.
LAST_STAND_MULTIPLIER = Decimal("1.5")
#: Lives remaining at or below this trigger last stand.
LAST_STAND_LIVES = 1

#: Steeper than the shared casual tiers, flatter than speedrun's.
STREAK_TIERS: tuple[tuple[int, str], ...] = (
    (0, "1.0"),
    (4, "1.2"),
    (8, "1.5"),
    (14, "2.0"),
    (20, "2.5"),
)

#: Every Nth correct answer in the run (not the streak) pays a checkpoint
#: bonus, so even a player who keeps breaking their streak has something to
#: chase.
CHECKPOINT_EVERY = 10
CHECKPOINT_POINTS = 150
CHECKPOINT_POINTS_CAP = 750

#: Speed still pays, but less than speedrun — survival rewards accuracy first.
SPEED_BONUS_MAX_POINTS = 60


def question_time_limit_ms(depth: int) -> int:
    """Per-question limit at `depth` (0-based question index in the run)."""
    steps = max(0, depth) // QUESTION_LIMIT_STEP_EVERY
    limit = QUESTION_LIMIT_START_MS - steps * QUESTION_LIMIT_STEP_MS
    return max(QUESTION_LIMIT_FLOOR_MS, limit)


def streak_needed_for_regain(lives_regained: int) -> int:
    """Streak that earns the next life, given how many are already regained."""
    return REGAIN_BASE_STREAK + max(0, lives_regained) * REGAIN_STEP


def should_regain_life(*, streak: int, lives: int, lives_regained: int) -> bool:
    """Does this answer earn a life back?

    Fires exactly on the threshold rather than on every multiple, so a long
    streak grants one life per threshold crossed and not a life per answer.
    """
    if lives >= MAX_LIVES:
        return False
    return streak > 0 and streak == streak_needed_for_regain(lives_regained)


def is_last_stand(lives: int | None) -> bool:
    return lives is not None and 0 < lives <= LAST_STAND_LIVES


def streak_multiplier(streak: int) -> Decimal:
    multiplier = Decimal("1.0")
    for threshold, value in STREAK_TIERS:
        if streak >= threshold:
            multiplier = Decimal(value)
    return multiplier


def checkpoint_bonus(correct_count: int) -> int:
    """Lump bonus for crossing a checkpoint, growing with run depth.

    `correct_count` is the number of correct answers *including* this one.
    Returns 0 when this answer did not cross a checkpoint.
    """
    if correct_count <= 0 or correct_count % CHECKPOINT_EVERY != 0:
        return 0
    tier = correct_count // CHECKPOINT_EVERY
    return min(CHECKPOINT_POINTS * tier, CHECKPOINT_POINTS_CAP)


def speed_bonus_points(remaining_ms: int, limit_ms: int) -> int:
    if limit_ms <= 0 or remaining_ms <= 0:
        return 0
    ratio = min(max(remaining_ms / limit_ms, 0.0), 1.0)
    return int(round(ratio * SPEED_BONUS_MAX_POINTS))
