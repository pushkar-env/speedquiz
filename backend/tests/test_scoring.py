from app.models import GameMode
from app.services import survival
from app.services.scoring import ScoringService


def test_streak_multipliers():
    svc = ScoringService()
    assert float(svc.streak_multiplier(0)) == 1.0
    assert float(svc.streak_multiplier(4)) == 1.0
    assert float(svc.streak_multiplier(5)) == 1.1
    assert float(svc.streak_multiplier(10)) == 1.25
    assert float(svc.streak_multiplier(20)) == 1.5


def test_speed_bonus_scales_with_remaining_time():
    svc = ScoringService()
    assert svc.speed_bonus(15000, 15000) == 50
    assert svc.speed_bonus(7500, 15000) == 25
    assert svc.speed_bonus(0, 15000) == 0


def test_correct_answer_awards_points_with_streak():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=True,
        current_streak=9,
        remaining_ms=7500,
        total_ms=15000,
        mode=GameMode.CASUAL,
    )
    assert result.new_streak == 10
    assert float(result.streak_multiplier) == 1.25
    assert result.base_points == 100
    assert result.speed_bonus == 25
    assert result.points_awarded == int(round((100 + 25) * 1.25))


def test_wrong_answer_resets_streak_casual():
    svc = ScoringService()
    result = svc.score_answer(
        is_correct=False,
        current_streak=8,
        remaining_ms=1000,
        total_ms=15000,
        mode=GameMode.CASUAL,
    )
    assert result.new_streak == 0
    assert result.points_awarded == 0


def test_survival_costs_a_life_on_a_miss():
    svc = ScoringService()
    miss = svc.score_answer(
        is_correct=False,
        current_streak=2,
        remaining_ms=1000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
        lives=3,
    )
    assert miss.lives_delta == -1
    assert miss.new_streak == 0
    assert miss.points_awarded == 0


def test_survival_regains_a_life_on_the_threshold_streak():
    svc = ScoringService()
    restore = svc.score_answer(
        is_correct=True,
        current_streak=survival.REGAIN_BASE_STREAK - 1,
        remaining_ms=10000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
        lives=2,
        lives_regained=0,
    )
    assert restore.new_streak == survival.REGAIN_BASE_STREAK
    assert restore.lives_delta == 1


def test_survival_second_comeback_costs_more():
    """Each life already regained pushes the next threshold further out."""
    svc = ScoringService()
    # The first threshold no longer pays once a life has been regained.
    at_old = svc.score_answer(
        is_correct=True,
        current_streak=survival.REGAIN_BASE_STREAK - 1,
        remaining_ms=10000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
        lives=2,
        lives_regained=1,
    )
    assert at_old.lives_delta == 0

    needed = survival.streak_needed_for_regain(1)
    at_new = svc.score_answer(
        is_correct=True,
        current_streak=needed - 1,
        remaining_ms=10000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
        lives=2,
        lives_regained=1,
    )
    assert at_new.lives_delta == 1


def test_survival_never_regains_past_the_cap():
    svc = ScoringService()
    full = svc.score_answer(
        is_correct=True,
        current_streak=survival.REGAIN_BASE_STREAK - 1,
        remaining_ms=10000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
        lives=survival.MAX_LIVES,
    )
    assert full.lives_delta == 0


def test_survival_last_stand_pays_more_on_the_final_life():
    """The brink is the best place to be — that is the whole hook."""
    svc = ScoringService()
    kwargs = dict(
        is_correct=True,
        current_streak=4,
        remaining_ms=10000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
    )
    safe = svc.score_answer(**kwargs, lives=3)
    brink = svc.score_answer(**kwargs, lives=1)

    assert brink.points_awarded > safe.points_awarded
    assert brink.streak_multiplier == (
        safe.streak_multiplier * survival.LAST_STAND_MULTIPLIER
    )


def test_survival_checkpoint_bonus_every_tenth_correct():
    svc = ScoringService()
    # correct_count is the tally *before* this answer, so 9 makes this the 10th.
    crossing = svc.score_answer(
        is_correct=True,
        current_streak=3,
        remaining_ms=8000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
        lives=3,
        correct_count=9,
    )
    assert crossing.milestone_bonus == survival.CHECKPOINT_POINTS

    between = svc.score_answer(
        is_correct=True,
        current_streak=3,
        remaining_ms=8000,
        total_ms=15000,
        mode=GameMode.SURVIVAL,
        lives=3,
        correct_count=8,
    )
    assert between.milestone_bonus == 0


def test_survival_clock_tightens_with_depth():
    """Without this a strong player could sit on three lives forever."""
    opening = survival.question_time_limit_ms(0)
    deeper = survival.question_time_limit_ms(20)
    assert opening == survival.QUESTION_LIMIT_START_MS
    assert deeper < opening
    assert survival.question_time_limit_ms(500) == survival.QUESTION_LIMIT_FLOOR_MS
