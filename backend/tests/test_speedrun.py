"""Speedrun rules: the clock loop, the two escalators, and the score curve."""

import pytest

from app.models import GameMode
from app.services import speedrun
from app.services.anticheat import max_points_per_answer
from app.services.scoring import ScoringService


# --- Question pacing -------------------------------------------------------


def test_question_limit_tightens_with_depth():
    assert speedrun.question_time_limit_ms(0) == 10_000
    assert speedrun.question_time_limit_ms(3) == 10_000
    assert speedrun.question_time_limit_ms(4) == 9_250
    assert speedrun.question_time_limit_ms(8) == 8_500


def test_question_limit_never_drops_below_floor():
    assert speedrun.question_time_limit_ms(200) == speedrun.QUESTION_LIMIT_FLOOR_MS
    assert speedrun.question_time_limit_ms(-5) == 10_000


# --- Time refunds ----------------------------------------------------------


def test_faster_answers_buy_more_time():
    instant = speedrun.time_bonus_ms(remaining_ms=10_000, limit_ms=10_000, depth=0)
    middling = speedrun.time_bonus_ms(remaining_ms=5_000, limit_ms=10_000, depth=0)
    crawling = speedrun.time_bonus_ms(remaining_ms=200, limit_ms=10_000, depth=0)

    assert instant == speedrun.TIME_BONUS_MAX_MS
    assert crawling >= speedrun.TIME_BONUS_MIN_MS
    assert instant > middling > crawling


def test_refunds_decay_with_depth_but_hold_a_floor():
    shallow = speedrun.time_bonus_ms(remaining_ms=10_000, limit_ms=10_000, depth=0)
    deep = speedrun.time_bonus_ms(remaining_ms=10_000, limit_ms=10_000, depth=30)
    abyssal = speedrun.time_bonus_ms(remaining_ms=10_000, limit_ms=10_000, depth=500)

    assert deep < shallow
    assert abyssal == round(
        speedrun.TIME_BONUS_MAX_MS * speedrun.BONUS_DECAY_FLOOR
    )


def test_a_perfect_deep_run_still_goes_clock_negative():
    """Both escalators together must eventually kill a flawless player."""
    depth = 60
    limit = speedrun.question_time_limit_ms(depth)
    # Answering in a third of a floor-length question is near-superhuman.
    elapsed = limit // 3
    outcome = speedrun.apply_clock(
        clock_ms=30_000,
        elapsed_ms=elapsed,
        limit_ms=limit,
        is_correct=True,
        depth=depth,
    )
    assert outcome.delta_ms < outcome.burned_ms
    assert outcome.remaining_ms < 30_000


# --- The clock -------------------------------------------------------------


def test_correct_answer_buys_time_back():
    outcome = speedrun.apply_clock(
        clock_ms=20_000,
        elapsed_ms=1_500,
        limit_ms=10_000,
        is_correct=True,
        depth=0,
    )
    assert outcome.delta_ms > 0
    assert outcome.burned_ms == 1_500 + speedrun.FEEDBACK_BURN_MS
    assert outcome.remaining_ms == 20_000 - outcome.burned_ms + outcome.delta_ms
    assert not outcome.exhausted


def test_wrong_answer_burns_the_clock():
    outcome = speedrun.apply_clock(
        clock_ms=20_000,
        elapsed_ms=1_500,
        limit_ms=10_000,
        is_correct=False,
        depth=0,
    )
    assert outcome.delta_ms == -speedrun.WRONG_PENALTY_MS
    assert outcome.remaining_ms < 20_000 - outcome.burned_ms


def test_wrong_answer_can_end_a_run_on_a_thin_clock():
    outcome = speedrun.apply_clock(
        clock_ms=3_000,
        elapsed_ms=800,
        limit_ms=10_000,
        is_correct=False,
        depth=0,
    )
    assert outcome.remaining_ms == 0
    assert outcome.exhausted


def test_running_out_mid_question_earns_no_refund():
    outcome = speedrun.apply_clock(
        clock_ms=1_200,
        elapsed_ms=4_000,
        limit_ms=10_000,
        is_correct=True,
        depth=0,
    )
    assert outcome.remaining_ms == 0
    assert outcome.delta_ms == 0
    assert outcome.exhausted


def test_elapsed_beyond_the_limit_is_not_double_charged():
    outcome = speedrun.apply_clock(
        clock_ms=40_000,
        elapsed_ms=99_000,
        limit_ms=10_000,
        is_correct=False,
        depth=0,
    )
    assert outcome.burned_ms == 10_000 + speedrun.FEEDBACK_BURN_MS


def test_banked_time_is_capped():
    outcome = speedrun.apply_clock(
        clock_ms=speedrun.CLOCK_CAP_MS,
        elapsed_ms=100,
        limit_ms=10_000,
        is_correct=True,
        depth=0,
    )
    assert outcome.remaining_ms == speedrun.CLOCK_CAP_MS


# --- Scoring ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("streak", "expected"),
    [(0, 1.0), (2, 1.0), (3, 1.25), (5, 1.5), (8, 2.0), (12, 2.5), (16, 3.0), (99, 3.0)],
)
def test_streak_multiplier_tiers(streak, expected):
    assert float(speedrun.streak_multiplier(streak)) == expected


def test_overdrive_starts_at_five():
    assert not speedrun.is_overdrive(4)
    assert speedrun.is_overdrive(5)


def test_milestone_bonus_grows_then_caps():
    assert speedrun.milestone_bonus(4) == 0
    assert speedrun.milestone_bonus(5) == 100
    assert speedrun.milestone_bonus(10) == 200
    assert speedrun.milestone_bonus(100) == speedrun.MILESTONE_POINTS_CAP


def test_speed_bonus_rewards_speed_far_more_than_other_modes():
    svc = ScoringService()
    assert speedrun.speed_bonus_points(10_000, 10_000) == 150
    # The curve bites: half the clock left pays well under half the maximum.
    assert speedrun.speed_bonus_points(5_000, 10_000) < 75
    assert svc.speed_bonus(5_000, 10_000) == 25  # shared curve, unchanged


def test_speedrun_correct_answer_stacks_speed_streak_and_milestone():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=True,
        current_streak=4,
        remaining_ms=10_000,
        total_ms=10_000,
        mode=GameMode.SPEEDRUN,
    )
    assert result.new_streak == 5
    assert float(result.streak_multiplier) == 1.5
    assert result.speed_bonus == 150
    assert result.milestone_bonus == 100
    assert result.points_awarded == int(round((100 + 150) * 1.5)) + 100


def test_speedrun_wrong_answer_costs_points_and_the_streak():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=False,
        current_streak=11,
        remaining_ms=5_000,
        total_ms=10_000,
        mode=GameMode.SPEEDRUN,
    )
    assert result.new_streak == 0
    assert result.points_awarded == -speedrun.WRONG_PENALTY_POINTS


def test_anticheat_ceiling_admits_a_top_overdrive_answer():
    svc = ScoringService()
    best = svc.score_answer(
        is_correct=True,
        current_streak=19,
        remaining_ms=10_000,
        total_ms=10_000,
        mode=GameMode.SPEEDRUN,
    )
    assert best.points_awarded <= max_points_per_answer()


def test_speed_tier_labels():
    assert speedrun.speed_tier(10_000, 10_000) == "blitz"
    assert speedrun.speed_tier(6_000, 10_000) == "fast"
    assert speedrun.speed_tier(3_000, 10_000) == "clean"
    assert speedrun.speed_tier(500, 10_000) == "clutch"
