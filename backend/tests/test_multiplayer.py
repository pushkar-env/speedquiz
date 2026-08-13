"""Multiplayer: usernames, friends, match settlement, Elo and delivery.

DB-free, like the rest of the suite. Everything here is either pure logic or
operates on unsaved model instances, which is enough to cover the parts that
are genuinely easy to get wrong: the confusable-username fold, the standings
tiebreak, the Elo floor, and quiet hours across a UTC offset.
"""

from __future__ import annotations

import ast
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.models import (
    DevicePlatform,
    DeviceToken,
    MatchOutcome,
    MatchParticipant,
    NotificationType,
    UserProfile,
)
from app.services import matches, matchmaking, notifications, ranking, realtime, usernames


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
