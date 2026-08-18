"""Multiplayer: usernames, friends, match settlement, Elo and delivery.

DB-free, like the rest of the suite. Everything here is either pure logic or
operates on unsaved model instances, which is enough to cover the parts that
are genuinely easy to get wrong: the confusable-username fold, the standings
tiebreak, the Elo floor, and quiet hours across a UTC offset.
"""

from __future__ import annotations

import ast
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.models import (
    DevicePlatform,
    DeviceToken,
    Match,
    MatchDelivery,
    MatchFormat,
    MatchOutcome,
    MatchParticipant,
    MatchStatus,
    NotificationType,
    ParticipantStatus,
    Question,
    QuestionOption,
    UserProfile,
)
from tests.fakes import FakeSession

from app.services import (
    match_rules,
    matches,
    matchmaking,
    notifications,
    ranking,
    realtime,
    usernames,
)


# --- Usernames --------------------------------------------------------------


@pytest.mark.parametrize(
    "name",
    ["ravi", "Ravi_K", "player1x", "abc", "a" * 20, "Quiz_Master_99"],
)
def test_valid_usernames_are_accepted(name):
    assert usernames.validate_username(name) == name


@pytest.mark.parametrize(
    ("name", "code"),
    [
        ("ab", "username_length"),
        ("a" * 21, "username_length"),
        ("1ravi", "username_charset"),  # must start with a letter
        ("ravi-kumar", "username_charset"),
        ("ravi kumar", "username_charset"),
        ("ravi__k", "username_charset"),  # doubled underscore
        ("ravi_", "username_charset"),  # trailing underscore
        ("admin", "username_reserved"),
        ("SpeedQuiz", "username_reserved"),
        ("player_abc", "username_reserved"),  # the generated-name space
    ],
)
def test_invalid_usernames_are_rejected_with_a_reason(name, code):
    with pytest.raises(HTTPException) as excinfo:
        usernames.validate_username(name)
    assert excinfo.value.detail["code"] == code


def test_blocklist_matches_through_leetspeak():
    """`sh1t` folds to `shit`, which is the entire point of the skeleton."""
    with pytest.raises(HTTPException) as excinfo:
        usernames.validate_username("sh1tlord")
    assert excinfo.value.detail["code"] == "username_blocked"


def test_skeleton_collapses_case_separators_and_digits():
    assert usernames.username_skeleton("Ravi") == "ravi"
    assert usernames.username_skeleton("r_a_v_i") == "ravi"
    assert usernames.username_skeleton("R4vi") == "ravi"
    assert usernames.username_skeleton("RAV1") == "ravi"


def test_skeleton_distinguishes_genuinely_different_names():
    assert usernames.username_skeleton("ravi") != usernames.username_skeleton("ravik")


def test_normalize_username_folds_unicode_lookalikes():
    """Fullwidth Latin renders like ASCII and must not be a second identity."""
    assert usernames.normalize_username("Ｒａｖｉ") == "Ravi"


def test_friend_code_alphabet_excludes_confusable_glyphs():
    for banned in "01OILAEU":
        assert banned not in usernames.FRIEND_CODE_ALPHABET


def test_generated_friend_codes_are_valid():
    for _ in range(50):
        code = usernames.generate_friend_code()
        assert usernames.is_valid_friend_code(code)


def test_friend_code_normalizer_strips_separators_but_does_not_guess():
    assert usernames.normalize_friend_code(" bc23-fg78 ") == "BC23FG78"
    # `O` is not in the alphabet. Mapping it onto a neighbour would resolve one
    # player's typo into a different player's real code, so it stays invalid.
    assert not usernames.is_valid_friend_code(usernames.normalize_friend_code("BO23FG78"))


def test_first_username_change_is_free():
    profile = UserProfile(username="player_abc", username_skeleton="playerabc")
    assert usernames.can_change_username_at(profile) is None


def test_second_username_change_is_on_cooldown():
    profile = UserProfile(
        username="ravi",
        username_skeleton="ravi",
        username_changed_at=datetime.now(timezone.utc) - timedelta(days=2),
    )
    assert usernames.can_change_username_at(profile) is not None


def test_cooldown_expires():
    profile = UserProfile(
        username="ravi",
        username_skeleton="ravi",
        username_changed_at=datetime.now(timezone.utc)
        - timedelta(days=usernames.USERNAME_CHANGE_COOLDOWN_DAYS + 1),
    )
    assert usernames.can_change_username_at(profile) is None


def test_profile_username_fields_sets_both_columns():
    """The skeleton column carries the unique index; writing one without the
    other leaves the row claiming an identity the index disagrees with."""
    fields = usernames.profile_username_fields("Ravi_K")
    assert fields == {"username": "Ravi_K", "username_skeleton": "ravik"}


# --- Elo --------------------------------------------------------------------


def test_expected_score_is_symmetric():
    assert ranking.expected_score(1200, 1000) + ranking.expected_score(1000, 1200) == pytest.approx(1.0)


def test_equal_ratings_expect_a_coin_flip():
    assert ranking.expected_score(1000, 1000) == pytest.approx(0.5)


def test_beating_a_stronger_player_pays_more():
    underdog = ranking.rating_delta(
        rating=1000, opponent_rating=1400, outcome=MatchOutcome.WIN
    )
    favourite = ranking.rating_delta(
        rating=1400, opponent_rating=1000, outcome=MatchOutcome.WIN
    )
    assert underdog > favourite > 0


def test_a_win_never_rounds_to_zero():
    """A heavy favourite is owed a fraction of a point. Rounding it away reads
    as the ladder being broken."""
    delta = ranking.rating_delta(
        rating=2400, opponent_rating=200, outcome=MatchOutcome.WIN
    )
    assert delta >= 1


def test_a_loss_never_rounds_to_zero():
    delta = ranking.rating_delta(
        rating=200, opponent_rating=2400, outcome=MatchOutcome.LOSS
    )
    assert delta <= -1


def test_placements_move_rating_harder():
    settled = ranking.rating_delta(
        rating=1000, opponent_rating=1000, outcome=MatchOutcome.WIN
    )
    provisional = ranking.rating_delta(
        rating=1000,
        opponent_rating=1000,
        outcome=MatchOutcome.WIN,
        placements_remaining=3,
    )
    assert provisional > settled


def test_a_draw_between_equals_moves_nothing():
    assert (
        ranking.rating_delta(rating=1000, opponent_rating=1000, outcome=MatchOutcome.DRAW)
        == 0
    )


def test_tiers_are_ordered_and_contiguous():
    thresholds = [t.min_rating for t in ranking.TIERS]
    assert thresholds == sorted(thresholds)
    assert thresholds[0] == 0


def test_placements_hide_the_tier():
    assert ranking.tier_for(1500, placements_remaining=2) is ranking.UNRANKED_TIER
    assert ranking.tier_for(1500, placements_remaining=0).code == "diamond"


def test_season_carryover_regresses_toward_the_mean_without_reordering():
    from app.core.config import get_settings

    start = get_settings().ranked_starting_rating
    high = ranking.carry_over_rating(2000)
    low = ranking.carry_over_rating(600)
    assert high > start > low  # ordering survives
    assert high < 2000 and low > 600  # but both moved toward the middle


def test_season_key_is_year_month():
    assert re.fullmatch(r"\d{4}-\d{2}", ranking.season_key())


def test_apply_result_tracks_streaks_and_peak():
    from app.models import PlayerRating

    row = PlayerRating(
        id=uuid4(), user_id=uuid4(), season_key="2026-08", rating=1000,
        peak_rating=1000, placements_remaining=2, matches_played=0,
        wins=0, losses=0, draws=0, win_streak=0, best_win_streak=0,
    )
    ranking.apply_result(row, delta=30, outcome=MatchOutcome.WIN)
    ranking.apply_result(row, delta=25, outcome=MatchOutcome.WIN)
    assert row.rating == 1055
    assert row.peak_rating == 1055
    assert row.win_streak == 2 and row.best_win_streak == 2
    assert row.placements_remaining == 0
    assert row.matches_played == 2

    ranking.apply_result(row, delta=-40, outcome=MatchOutcome.LOSS)
    assert row.win_streak == 0
    assert row.peak_rating == 1055  # peak survives a loss
    assert row.rating == 1015


def test_rating_never_goes_negative():
    from app.models import PlayerRating

    row = PlayerRating(
        id=uuid4(), user_id=uuid4(), season_key="2026-08", rating=10,
        peak_rating=10, placements_remaining=0, matches_played=0,
        wins=0, losses=0, draws=0, win_streak=0, best_win_streak=0,
    )
    ranking.apply_result(row, delta=-500, outcome=MatchOutcome.LOSS)
    assert row.rating == 0


# --- Standings --------------------------------------------------------------


def _participant(score: int, ms: int, correct: int = 0) -> MatchParticipant:
    return MatchParticipant(
        id=uuid4(),
        match_id=uuid4(),
        user_id=uuid4(),
        score=score,
        total_answer_ms=ms,
        correct_count=correct,
    )


def test_higher_score_wins():
    a, b = _participant(500, 9000), _participant(300, 1000)
    assert matches._rank_participants([b, a])[0] is a


def test_speed_breaks_a_tied_score():
    """Common on a seven-question board, and "you were quicker" is a result
    both players accept."""
    quick, slow = _participant(400, 4000), _participant(400, 9000)
    assert matches._rank_participants([slow, quick])[0] is quick


def test_accuracy_breaks_a_tied_score_and_clock():
    accurate = _participant(400, 5000, correct=5)
    lucky = _participant(400, 5000, correct=3)
    assert matches._rank_participants([lucky, accurate])[0] is accurate


# --- Option ordering --------------------------------------------------------


class _StubQuestionDb:
    """Returns one question for any select. Enough for [_round_payload]."""

    def __init__(self, question) -> None:
        self._question = question

    async def scalar(self, _statement):
        return self._question


def _question_with_options() -> Question:
    question = Question(
        id=uuid4(),
        prompt="Which planet is closest to the sun?",
        explanation="Mercury, at 58 million km.",
        correct_option_index=2,
    )
    question.options = [
        QuestionOption(id=uuid4(), position=i, text=text)
        for i, text in enumerate(["Venus", "Earth", "Mercury", "Mars"])
    ]
    return question


async def test_round_start_payload_carries_the_question_but_never_the_answer():
    """The prompt rides on the event so a round opens without a round trip.
    That is only safe while the payload stays free of anything that identifies
    the right button — this is the test that keeps it that way."""
    question = _question_with_options()
    match = Match(
        id=uuid4(),
        question_count=3,
        question_time_limit_ms=15000,
        question_ids=[str(question.id), str(uuid4()), str(uuid4())],
        option_orders=[[2, 0, 3, 1], [0, 1, 2, 3], [0, 1, 2, 3]],
    )

    payload = await matches._round_payload(_StubQuestionDb(question), match, 0)

    assert payload["prompt"] == question.prompt
    assert [o["text"] for o in payload["options"]] == [
        "Mercury",
        "Venus",
        "Mars",
        "Earth",
    ]
    # An explicit allowlist, not a subset check: a new key has to be added here
    # deliberately, which is the moment to ask whether it leaks the answer.
    assert set(payload) == {
        "question_id",
        "prompt",
        "options",
        "time_limit_ms",
        "is_final_round",
    }
    assert all(set(o) == {"index", "text"} for o in payload["options"])
    serialized = json.dumps(payload)
    assert "correct" not in serialized
    assert question.explanation not in serialized


async def test_round_start_payload_stops_at_the_end_of_the_board():
    """The last round's reveal has no next question to attach."""
    match = Match(id=uuid4(), question_count=1, question_ids=[str(uuid4())], option_orders=[[0, 1, 2, 3]])
    assert await matches._round_payload(_StubQuestionDb(None), match, 1) is None


async def test_round_start_payload_degrades_instead_of_breaking_a_live_match():
    """A question pulled from under a running match returns nothing, and the
    client falls back to fetching the round. Raising here would kill the round
    advance for both players."""
    match = Match(
        id=uuid4(),
        question_count=2,
        question_ids=[str(uuid4()), str(uuid4())],
        option_orders=[[0, 1, 2, 3], [0, 1, 2, 3]],
    )
    assert await matches._round_payload(_StubQuestionDb(None), match, 0) is None


# --- Settlement guards ------------------------------------------------------


class _SettlementDb:
    """Records whether the match was flushed; no rows, no queries."""

    def __init__(self) -> None:
        self.flushed = 0

    async def flush(self) -> None:
        self.flushed += 1


def _seat(status: ParticipantStatus, rounds_answered: int = 0) -> MatchParticipant:
    return MatchParticipant(
        id=uuid4(),
        match_id=uuid4(),
        user_id=uuid4(),
        status=status,
        rounds_answered=rounds_answered,
        score=0,
        total_answer_ms=0,
        correct_count=0,
    )


def _duel(*seats: MatchParticipant, question_count: int = 3) -> Match:
    match = Match(
        id=uuid4(),
        format=MatchFormat.DUEL,
        status=MatchStatus.LIVE,
        delivery=MatchDelivery.ASYNC,
        question_count=question_count,
    )
    match.participants = list(seats)
    return match


async def test_a_duel_does_not_settle_while_the_challenged_player_owes_a_board(
    monkeypatch,
):
    """The reported bug: one player finishes and is declared the winner while
    the friend they challenged has not had their turn."""
    settled: list[Match] = []
    monkeypatch.setattr(
        matches, "finalize", lambda db, match: _record(settled, match)
    )
    monkeypatch.setattr(matches, "_notify_waiting_players", _noop)

    match = _duel(
        _seat(ParticipantStatus.PLAYING, rounds_answered=3),
        _seat(ParticipantStatus.INVITED),
    )
    finished = await matches._finalize_if_everyone_done(_SettlementDb(), match)

    assert finished is False
    assert settled == []
    assert match.status is MatchStatus.AWAITING_OPPONENT, "the inbox needs to say whose turn it is"


async def test_a_duel_settles_once_both_sides_have_played(monkeypatch):
    settled: list[Match] = []
    monkeypatch.setattr(
        matches, "finalize", lambda db, match: _record(settled, match)
    )

    match = _duel(
        _seat(ParticipantStatus.PLAYING, rounds_answered=3),
        _seat(ParticipantStatus.PLAYING, rounds_answered=3),
    )
    assert await matches._finalize_if_everyone_done(_SettlementDb(), match) is True
    assert settled == [match]


async def test_a_room_is_not_held_hostage_by_someone_who_never_turned_up(
    monkeypatch,
):
    """The opposite failure to the one above. In a duel the invitee is the whole
    opposition; in a room they are one empty chair, and the people who did play
    are owed their result."""
    settled: list[Match] = []
    monkeypatch.setattr(
        matches, "finalize", lambda db, match: _record(settled, match)
    )

    match = _duel(
        _seat(ParticipantStatus.PLAYING, rounds_answered=3),
        _seat(ParticipantStatus.PLAYING, rounds_answered=3),
        _seat(ParticipantStatus.INVITED),
    )
    match.format = MatchFormat.ROOM

    assert await matches._finalize_if_everyone_done(_SettlementDb(), match) is True
    assert settled == [match]


async def _record(sink: list, match: Match) -> None:
    sink.append(match)


async def _noop(*_args, **_kwargs) -> None:
    return None


async def test_parking_on_awaiting_opponent_hands_the_slow_player_their_own_board(
    monkeypatch,
):
    """The deadlock behind "the match will not move".

    A *live-delivery* match parked on AWAITING_OPPONENT keeps resolving every
    player's round from the shared `match.current_round_index` — and nothing
    advances that index any more, because `advance_if_due` returns early once
    the status is no longer LIVE. So the player who still owes rounds is served
    the same question forever, and every answer comes back `already_answered`.
    Neither leaving nor waiting resolves it; only the 48-hour expiry does.

    Parking has to hand that player their own board, which is exactly what
    async delivery means.
    """
    monkeypatch.setattr(matches, "_notify_waiting_players", _noop)
    monkeypatch.setattr(realtime, "publish", _noop)

    slow = _seat(ParticipantStatus.PLAYING, rounds_answered=1)
    match = _duel(
        _seat(ParticipantStatus.PLAYING, rounds_answered=3),
        slow,
        question_count=3,
    )
    match.delivery = MatchDelivery.LIVE
    match.current_round_index = 2

    await matches._finalize_if_everyone_done(_SettlementDb(), match)

    assert match.status is MatchStatus.AWAITING_OPPONENT
    assert match.delivery is MatchDelivery.ASYNC, (
        "a parked match has no shared clock left to run"
    )
    assert matches._round_index_for(match, slow) == 1, (
        "the slow player resumes at their own progress, not the frozen index"
    )


class _ParkedDb:
    """Answers one `select(Match)` with `rows`, then records the flush."""

    def __init__(self, rows: list) -> None:
        self._rows = rows
        self.flushed = 0

    async def execute(self, _statement):
        return _ScalarResult(self._rows)

    async def flush(self) -> None:
        self.flushed += 1


class _ScalarResult:
    def __init__(self, rows: list) -> None:
        self._rows = rows

    def scalars(self):
        return self

    def all(self) -> list:
        return list(self._rows)


async def test_the_sweep_releases_matches_already_wedged_in_the_database(
    monkeypatch,
):
    """The forward fix does not help a row written before it. A player cannot
    escape this state by playing, leaving, or waiting for anything short of the
    48-hour expiry, so the sweep repairs it in place."""
    monkeypatch.setattr(realtime, "publish", _noop)

    wedged = _duel(
        _seat(ParticipantStatus.PLAYING, rounds_answered=3),
        _seat(ParticipantStatus.PLAYING, rounds_answered=1),
        question_count=3,
    )
    wedged.status = MatchStatus.AWAITING_OPPONENT
    wedged.delivery = MatchDelivery.LIVE
    wedged.round_started_at = datetime(2026, 8, 1, tzinfo=timezone.utc)

    healed = await matches.heal_parked_matches(_ParkedDb([wedged]))

    assert healed == 1
    assert wedged.delivery is MatchDelivery.ASYNC
    # Cleared with the delivery: each side runs its own clock from now on, and
    # a stale shared start would time them out retroactively.
    assert wedged.round_started_at is None


async def test_healing_is_a_no_op_once_the_backlog_is_drained():
    """It runs on every sweep tick forever, so selecting nothing has to cost
    nothing and touch nothing."""
    db = _ParkedDb([])
    assert await matches.heal_parked_matches(db) == 0
    assert db.flushed == 0


def test_a_running_score_is_hidden_from_the_player_who_already_finished():
    """The reported leak: you play your last question, and the opponent's row
    shows a total that still has a question left to land. You watch a number
    you have already beaten, then see it jump past you."""
    me = _seat(ParticipantStatus.PLAYING, rounds_answered=3)
    them = _seat(ParticipantStatus.PLAYING, rounds_answered=2)
    match = _duel(me, them, question_count=3)

    assert matches._score_visible_to(match, them, me) is False
    # Symmetrically: whoever is still playing is in the race and sees it all.
    assert matches._score_visible_to(match, me, them) is True
    # And your own number is always yours.
    assert matches._score_visible_to(match, me, me) is True


def test_scores_stay_visible_while_both_players_are_still_going():
    """A live battle is meant to be a race you can watch, and the catch-up
    bonus is only fair if you can see that you are behind."""
    me = _seat(ParticipantStatus.PLAYING, rounds_answered=2)
    them = _seat(ParticipantStatus.PLAYING, rounds_answered=1)
    match = _duel(me, them, question_count=3)

    assert matches._score_visible_to(match, them, me) is True


def test_the_result_reveals_everything():
    me = _seat(ParticipantStatus.FINISHED, rounds_answered=3)
    them = _seat(ParticipantStatus.FINISHED, rounds_answered=3)
    match = _duel(me, them, question_count=3)
    match.status = MatchStatus.COMPLETED

    assert matches._score_visible_to(match, them, me) is True


def test_awaiting_opponent_is_a_playable_status():
    """It means the *other* side has finished, not that the match has. Treating
    it as closed left the second player of an async match able to be served
    every question and to answer none of them."""
    assert MatchStatus.AWAITING_OPPONENT in matches.IN_PLAY_MATCH_STATUSES
    assert MatchStatus.LIVE in matches.IN_PLAY_MATCH_STATUSES
    assert MatchStatus.COMPLETED not in matches.IN_PLAY_MATCH_STATUSES
    assert MatchStatus.CANCELLED not in matches.IN_PLAY_MATCH_STATUSES
    assert MatchStatus.PENDING not in matches.IN_PLAY_MATCH_STATUSES


# --- Match scoring rules ----------------------------------------------------


def _score(**overrides):
    kwargs = {
        "is_correct": True,
        "current_streak": 0,
        "remaining_ms": 0,
        "total_ms": 15000,
        "is_first_correct": False,
        "is_final_round": False,
        "points_behind": 0,
    }
    kwargs.update(overrides)
    return match_rules.score_answer(**kwargs)


def test_a_wrong_answer_costs_nothing_and_breaks_the_combo():
    """A negative score in a head-to-head reads as a bug. The punishment for
    missing is the broken run and the round the opponent just banked."""
    result = _score(is_correct=False, current_streak=3)
    assert result.points == 0
    assert result.new_streak == 0
    assert result.combo_multiplier == 1.0


@pytest.mark.parametrize(
    ("streak_before", "expected"),
    [(0, 1.0), (1, 1.25), (2, 1.5), (3, 2.0), (6, 2.0)],
)
def test_combo_escalates_and_then_holds(streak_before, expected):
    """Reachable inside a seven-question board — the old streak tiers topped
    out at ten in a row, which no duel is long enough to reach."""
    assert _score(current_streak=streak_before).combo_multiplier == expected


def test_combo_doubles_a_clean_run():
    solo = _score(current_streak=0).points
    fourth = _score(current_streak=3).points
    assert fourth == solo * 2


def test_first_correct_pays_a_flat_bonus():
    alone = _score().points
    first = _score(is_first_correct=True).points
    assert first - alone == match_rules.FIRST_CORRECT_BONUS


def test_the_first_bonus_is_not_multiplied_by_the_final_round():
    """Flat so it reads as one number on the verdict, whenever it lands."""
    final_plain = _score(is_final_round=True).points
    final_first = _score(is_final_round=True, is_first_correct=True).points
    assert final_first - final_plain == match_rules.FIRST_CORRECT_BONUS


def test_the_last_question_is_worth_double():
    assert _score(is_final_round=True).points == _score().points * 2


def test_catch_up_scales_with_the_deficit_and_stops():
    level = _score(points_behind=0).points
    close = _score(points_behind=100).points
    far = _score(points_behind=match_rules.CATCHUP_FULL_DEFICIT_POINTS).points
    hopeless = _score(points_behind=5000).points

    assert level < close < far
    assert hopeless == far, "the bonus is capped, not unbounded"
    assert far == pytest.approx(level * match_rules.CATCHUP_MAX_MULTIPLIER, rel=0.01)


def test_being_ahead_earns_no_catch_up():
    assert _score(points_behind=-400).points == _score(points_behind=0).points


def test_the_leader_is_never_out_scored_by_the_catch_up_alone():
    """A comeback has to be earned by answering better, not by being behind.
    Two players answer identically, one of them trailing: the trailing player
    must not out-earn the leader by more than the modest catch-up margin."""
    leader = _score(remaining_ms=12000).points
    trailing = _score(remaining_ms=12000, points_behind=5000).points
    assert trailing < leader * 1.5


def test_the_ceiling_covers_what_the_rules_can_actually_pay():
    """Derived from the constants, so raising a multiplier cannot silently
    start clamping honest answers."""
    best = _score(
        current_streak=10,
        remaining_ms=15000,
        total_ms=15000,
        is_first_correct=True,
        is_final_round=True,
        points_behind=9999,
    )
    assert best.points <= match_rules.max_points_per_answer()
    assert match_rules.clamp_points(best.points) == best.points


def test_clamping_floors_at_zero():
    assert match_rules.clamp_points(-50) == 0


def test_combo_label_is_a_code_not_prose():
    """The client draws the word from its own string table, so a match reads in
    whatever language the app is set to."""
    assert match_rules.combo_label(1) == ""
    assert match_rules.combo_label(2) == "combo"
    assert match_rules.combo_label(4) == "unstoppable"
    for streak in range(0, 8):
        assert match_rules.combo_label(streak).isascii()


def test_option_order_normalizer_rejects_anything_but_a_permutation():
    assert matches._normalize_option_order([3, 1, 0, 2]) == [3, 1, 0, 2]
    for bad in ([0, 1, 2], [0, 1, 2, 2], "3102", None, [0, 1, 2, 9], {"a": 1}):
        assert matches._normalize_option_order(bad) == [0, 1, 2, 3]


def test_seeded_option_orders_are_reproducible():
    """The board is frozen at creation and replayed for an async opponent
    hours later; the same seed must produce the same buttons."""
    import random

    first = [matches._seeded_option_order(random.Random("seed-a")) for _ in range(3)]
    second = [matches._seeded_option_order(random.Random("seed-a")) for _ in range(3)]
    assert first == second


# --- Matchmaking ------------------------------------------------------------


def test_search_band_widens_with_time_and_then_stops():
    assert matchmaking.band_for(0) < matchmaking.band_for(10) < matchmaking.band_for(60)
    assert matchmaking.band_for(100_000) == matchmaking.band_for(200_000)


def test_queues_are_separated_by_language():
    from app.core.languages import ContentLanguage

    assert matchmaking.queue_key(ContentLanguage.ENGLISH) != matchmaking.queue_key(
        ContentLanguage.HINDI
    )


# --- Realtime ---------------------------------------------------------------


def test_stream_ids_compare_numerically_not_lexically():
    """`999...-0` sorts after `1000...-0` as a string and before it as an id.
    Getting this wrong replays or drops events on every reconnect."""
    earlier = realtime._id_tuple("999999999999-0")
    later = realtime._id_tuple("1000000000000-0")
    assert earlier < later


def test_stream_id_sequence_breaks_ties_within_a_millisecond():
    assert realtime._id_tuple("1690000000000-1") > realtime._id_tuple("1690000000000-0")


def test_malformed_stream_ids_sort_first_rather_than_raising():
    assert realtime._id_tuple("nonsense") == (0, 0)


def test_match_and_user_channels_cannot_collide():
    """The hub keys subscribers by stream name, so a match id that happened to
    read as a user id must not land both feeds on one channel."""
    shared = uuid4()
    assert realtime.stream_key(shared) != realtime.user_stream_key(shared)


class _FakePresenceRedis:
    """Just enough Redis for the presence hash."""

    def __init__(self, rows: dict[str, str]) -> None:
        self._rows = rows

    async def hgetall(self, _key: str) -> dict[str, str]:
        return dict(self._rows)


@pytest.mark.asyncio
async def test_presence_ignores_a_heartbeat_that_stopped(monkeypatch):
    """A phone swiped away never runs the clean-disconnect path, so its entry
    lingers until the hash's two-hour TTL. Reading the hash without checking
    the age reported that player as connected for the rest of the session —
    which lit the opponent's dot and hid an abandoned match from the sweep."""
    now = int(datetime.now(timezone.utc).timestamp())
    here, gone = str(uuid4()), str(uuid4())
    fake = _FakePresenceRedis(
        {
            here: str(now - 5),
            gone: str(now - realtime.ONLINE_TTL_SECONDS - 60),
        }
    )
    monkeypatch.setattr(realtime, "get_redis", lambda: _immediately(fake))

    assert await realtime.connected_user_ids(uuid4()) == {here}


@pytest.mark.asyncio
async def test_presence_survives_a_corrupt_entry(monkeypatch):
    fake = _FakePresenceRedis({str(uuid4()): "not-a-timestamp"})
    monkeypatch.setattr(realtime, "get_redis", lambda: _immediately(fake))
    assert await realtime.connected_user_ids(uuid4()) == set()


async def _immediately(value):
    return value


# --- Notifications ----------------------------------------------------------


def _device(offset_minutes: int) -> DeviceToken:
    return DeviceToken(
        id=uuid4(),
        user_id=uuid4(),
        token="t",
        platform=DevicePlatform.ANDROID,
        language="en",
        utc_offset_minutes=offset_minutes,
    )


def test_quiet_hours_follow_the_device_offset_not_the_server():
    """18:30 UTC is midnight in India and lunchtime in London. A server-side
    hour would silence the wrong one."""
    at = datetime(2026, 8, 13, 18, 30, tzinfo=timezone.utc)
    india = _device(330)   # UTC+5:30 -> 00:00 local
    london = _device(60)   # UTC+1    -> 19:30 local
    assert notifications.in_quiet_hours(india, at) is True
    assert notifications.in_quiet_hours(london, at) is False


def test_quiet_hours_window_wraps_midnight():
    device = _device(0)
    assert notifications.in_quiet_hours(device, datetime(2026, 8, 13, 23, 0, tzinfo=timezone.utc))
    assert notifications.in_quiet_hours(device, datetime(2026, 8, 13, 3, 0, tzinfo=timezone.utc))
    assert not notifications.in_quiet_hours(device, datetime(2026, 8, 13, 12, 0, tzinfo=timezone.utc))


def test_your_turn_is_exempt_from_quiet_hours():
    """The round clock is running; silence costs the player the game."""
    assert NotificationType.MATCH_YOUR_TURN in notifications._QUIET_HOURS_EXEMPT
    assert NotificationType.MATCH_RESULT not in notifications._QUIET_HOURS_EXEMPT


def test_a_challenge_is_exempt_from_quiet_hours():
    """Someone is sitting in a lobby waiting for the answer. Holding the invite
    until morning is holding them there."""
    assert NotificationType.MATCH_INVITE in notifications._QUIET_HOURS_EXEMPT


def test_a_friend_request_still_waits_for_morning():
    """Nothing is blocked on it, so it is not worth a 3am buzz."""
    assert NotificationType.FRIEND_REQUEST not in notifications._QUIET_HOURS_EXEMPT


def test_absent_preference_means_opted_in():
    profile = UserProfile(username="a", username_skeleton="a", notification_prefs={})
    assert notifications.wants(profile, NotificationType.MATCH_INVITE)


def test_explicit_opt_out_is_respected():
    profile = UserProfile(
        username="a", username_skeleton="a", notification_prefs={"match_invite": False}
    )
    assert not notifications.wants(profile, NotificationType.MATCH_INVITE)
    assert notifications.wants(profile, NotificationType.MATCH_RESULT)


def test_every_notification_type_has_push_copy_in_every_language():
    for notification_type in NotificationType:
        table = notifications._COPY[notification_type]
        assert set(table) >= {"en", "hi"}, notification_type
        for language, (title, body) in table.items():
            assert title.strip() and body.strip(), (notification_type, language)


@pytest.mark.asyncio
async def test_the_live_event_names_the_actor_but_the_stored_row_does_not(monkeypatch):
    """A banner has one frame to say who this is and no second request to find
    out, so the realtime event carries the name. The stored row must not: the
    inbox resolves its actor by id at read time, which is what keeps history
    correct after someone renames themselves."""
    published: list[dict] = []

    async def _capture(user_id, event, data):
        published.append(data)

    async def _skip_push(*args, **kwargs):
        return False

    monkeypatch.setattr(realtime, "publish_to_user", _capture)
    monkeypatch.setattr(notifications, "_push", _skip_push)

    row = await notifications.notify(
        FakeSession(),
        user_id=uuid4(),
        notification_type=NotificationType.MATCH_INVITE,
        actor_user_id=uuid4(),
        payload={"topic_name": "Science"},
        push_params={"actor": "ravi", "topic": "Science"},
    )

    assert published[0]["payload"] == {"topic_name": "Science", "actor": "ravi"}
    assert row.payload == {"topic_name": "Science"}


@pytest.mark.asyncio
async def test_an_event_with_no_push_copy_still_publishes(monkeypatch):
    """`push_params` is optional, and a caller that omits it must not lose the
    realtime delivery along with the name."""
    published: list[dict] = []

    async def _capture(user_id, event, data):
        published.append(data)

    async def _skip_push(*args, **kwargs):
        return False

    monkeypatch.setattr(realtime, "publish_to_user", _capture)
    monkeypatch.setattr(notifications, "_push", _skip_push)

    await notifications.notify(
        FakeSession(),
        user_id=uuid4(),
        notification_type=NotificationType.FRIEND_ACCEPTED,
    )

    assert published[0]["payload"] == {}


def test_push_copy_interpolates_and_survives_a_missing_parameter():
    from app.core.languages import ContentLanguage

    title, body = notifications.render_push(
        NotificationType.MATCH_INVITE, ContentLanguage.ENGLISH, {"actor": "ravi", "topic": "Science"}
    )
    assert "ravi" in body and "Science" in body
    # A caller that forgets a parameter gets placeholder text, not a KeyError
    # in the middle of creating someone's match.
    _, fallback = notifications.render_push(
        NotificationType.MATCH_INVITE, ContentLanguage.ENGLISH, {}
    )
    assert fallback


# --- Migration / model drift ------------------------------------------------


_MIGRATION = Path(__file__).resolve().parents[1] / "alembic" / "versions" / "0006_multiplayer.py"


def _migration_tables() -> dict[str, set[str]]:
    """Table -> column names, read out of the migration's create_table calls.

    Parsed rather than executed because the suite has no database. It is a
    structural check, not a proof the DDL runs — but model/migration drift is
    the failure this catches, and it is the one that ships silently.
    """
    tree = ast.parse(_MIGRATION.read_text(encoding="utf-8"))
    tables: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if not (isinstance(func, ast.Attribute) and func.attr == "create_table"):
            continue
        if not node.args or not isinstance(node.args[0], ast.Constant):
            continue
        name = node.args[0].value
        columns: set[str] = set()
        for arg in node.args[1:]:
            if not isinstance(arg, ast.Call):
                continue
            inner = arg.func
            attr = inner.attr if isinstance(inner, ast.Attribute) else getattr(inner, "id", "")
            if attr != "Column" or not arg.args:
                continue
            if isinstance(arg.args[0], ast.Constant):
                columns.add(arg.args[0].value)
            elif isinstance(arg.args[0], ast.Call):
                # _language_column("language") and friends.
                helper = arg.args[0]
                if helper.args and isinstance(helper.args[0], ast.Constant):
                    columns.add(helper.args[0].value)
        # Helper-built columns passed directly, e.g. _language_column("language").
        for arg in node.args[1:]:
            if (
                isinstance(arg, ast.Call)
                and isinstance(arg.func, ast.Name)
                and arg.func.id.startswith("_")
                and arg.args
                and isinstance(arg.args[0], ast.Constant)
            ):
                columns.add(arg.args[0].value)
        tables[name] = columns
    return tables


NEW_TABLES = (
    "friendships",
    "user_blocks",
    "matches",
    "match_participants",
    "match_answers",
    "player_ratings",
    "device_tokens",
    "notifications",
)


@pytest.mark.parametrize("table_name", NEW_TABLES)
def test_migration_creates_every_model_column(table_name):
    from app.models import Base

    model_columns = {c.name for c in Base.metadata.tables[table_name].columns}
    migration_columns = _migration_tables().get(table_name, set())
    missing = model_columns - migration_columns
    assert not missing, f"{table_name} missing from migration 0006: {sorted(missing)}"


@pytest.mark.parametrize("table_name", NEW_TABLES)
def test_migration_creates_no_column_the_model_lacks(table_name):
    from app.models import Base

    model_columns = {c.name for c in Base.metadata.tables[table_name].columns}
    migration_columns = _migration_tables().get(table_name, set())
    extra = migration_columns - model_columns
    assert not extra, f"{table_name} has columns no model declares: {sorted(extra)}"


def test_added_profile_columns_are_in_the_migration():
    source = _MIGRATION.read_text(encoding="utf-8")
    for column in (
        "username_changed_at",
        "friend_code",
        "username_skeleton",
        "notification_prefs",
    ):
        assert f'"{column}"' in source, column


def test_skeleton_sql_matches_the_python_implementation():
    """The migration backfills skeletons with a Postgres `translate()`. If its
    character map drifts from `_CONFUSABLE_FOLD`, accounts created before and
    after 0006 stop being comparable — and the unique index makes that
    a corruption, not a cosmetic difference."""
    source = _MIGRATION.read_text(encoding="utf-8")
    assert f"'{usernames._LEET_FROM}', '{usernames._LEET_TO}'" in source
