"""Player-authored quizzes: identity, validation, access, and the anti-farm rules.

DB-free like the rest of the suite. Everything here is either pure logic or
runs against `FakeSession` with an explicit resolver, which is enough to cover
the parts that are genuinely easy to get wrong: the per-quiz content hash, the
option validator, who may open a quiz, and the three rules that keep a quiz
somebody wrote the answers to off the global ladder.
"""

from __future__ import annotations

import ast
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from app.models import (
    CustomQuiz,
    CustomQuizReport,
    CustomQuizStatus,
    CustomQuizVisibility,
    DifficultyLabel,
    GameMode,
    Question,
    Score,
    Topic,
)
from app.schemas.custom_quizzes import CustomQuizQuestionIn, ReportQuizRequest
from app.services import custom_quizzes as cq
from app.services.quiz_service import DIFFICULTY_RANGES, SELECTABLE_MODES
from tests.fakes import FakeSession, predicate_resolver

NOW = datetime(2026, 8, 21, 12, 0, tzinfo=timezone.utc)


def _quiz(**overrides) -> CustomQuiz:
    defaults = dict(
        id=uuid4(),
        owner_user_id=uuid4(),
        topic_id=uuid4(),
        title="Bollywood 2000s",
        icon="🎬",
        language="en",
        visibility=CustomQuizVisibility.LINK,
        status=CustomQuizStatus.PUBLISHED,
        code="BCD234",
        question_count=8,
        default_mode=GameMode.CASUAL,
        default_difficulty=DifficultyLabel.MEDIUM,
        play_count=0,
        player_count=0,
        top_score=0,
        report_count=0,
    )
    defaults.update(overrides)
    return CustomQuiz(**defaults)


def _user(**overrides):
    return SimpleNamespace(
        id=overrides.pop("id", uuid4()),
        is_premium=overrides.pop("is_premium", False),
        profile=overrides.pop("profile", None),
        **overrides,
    )


def _question_payload(**overrides) -> dict:
    payload = {
        "prompt": "Which film won Best Picture in 2004?",
        "options": ["Lagaan", "Devdas", "Black", "Swades"],
        "correct_option_index": 2,
    }
    payload.update(overrides)
    return payload


# --- Question identity ------------------------------------------------------


def test_the_same_question_in_two_quizzes_is_not_a_duplicate():
    """The whole reason the hash is salted with the quiz id.

    `questions.content_hash` is globally unique. Without the salt, whoever
    typed "What is the capital of France?" first would block every other
    player from ever putting it in their own quiz.
    """
    from app.core.languages import ContentLanguage

    prompt = "What is the capital of France?"
    options = ["Paris", "Lyon", "Nice", "Marseille"]
    mine = cq.question_content_hash(uuid4(), prompt, options, ContentLanguage.ENGLISH)
    theirs = cq.question_content_hash(uuid4(), prompt, options, ContentLanguage.ENGLISH)
    assert mine != theirs


def test_the_same_question_twice_in_one_quiz_is_a_duplicate():
    from app.core.languages import ContentLanguage

    quiz_id = uuid4()
    options = ["Paris", "Lyon", "Nice", "Marseille"]
    first = cq.question_content_hash(quiz_id, "Capital of France?", options, ContentLanguage.ENGLISH)
    # Case and padding are not a new question.
    again = cq.question_content_hash(
        quiz_id, "  capital of FRANCE?  ", [o.upper() for o in options], ContentLanguage.ENGLISH
    )
    assert first == again


def test_the_hash_separates_languages():
    from app.core.languages import ContentLanguage

    quiz_id = uuid4()
    options = ["A", "B", "C", "D"]
    assert cq.question_content_hash(
        quiz_id, "NATO?", options, ContentLanguage.ENGLISH
    ) != cq.question_content_hash(quiz_id, "NATO?", options, ContentLanguage.HINDI)


# --- Authoring validation ---------------------------------------------------


def test_options_must_all_differ():
    """A quiz with two right answers is a broken quiz, and the author cannot
    see the problem from the editor once the options are shuffled at play."""
    with pytest.raises(ValidationError):
        CustomQuizQuestionIn(**_question_payload(options=["Paris", "paris", "Nice", "Lyon"]))


def test_options_cannot_be_blank():
    with pytest.raises(ValidationError):
        CustomQuizQuestionIn(**_question_payload(options=["Paris", "   ", "Nice", "Lyon"]))


def test_exactly_four_options():
    """The play screen is a 2x2 grid and `SubmitAnswerRequest` bounds the index
    at 3, so a five-option question would be unanswerable."""
    with pytest.raises(ValidationError):
        CustomQuizQuestionIn(**_question_payload(options=["A", "B", "C"]))
    with pytest.raises(ValidationError):
        CustomQuizQuestionIn(**_question_payload(options=["A", "B", "C", "D", "E"]))


def test_correct_index_must_point_at_an_option():
    with pytest.raises(ValidationError):
        CustomQuizQuestionIn(**_question_payload(correct_option_index=4))


def test_pasted_text_is_tidied_rather_than_rejected():
    """A prompt pasted out of a browser arrives with a zero-width space and a
    line break in it. Both are fixable, so they get fixed."""
    payload = CustomQuizQuestionIn(
        **_question_payload(
            prompt="Who​ wrote\n\n   Midnight's Children?﻿",
            options=["Rushdie ", " Roy", "Seth​", "Ghosh"],
        )
    )
    assert payload.prompt == "Who wrote Midnight's Children?"
    assert payload.options == ["Rushdie", "Roy", "Seth", "Ghosh"]


def test_bidi_override_is_stripped_from_a_prompt():
    """A right-to-left override renders the rest of the line backwards, which
    is a way to make a question say something other than what it stores."""
    payload = CustomQuizQuestionIn(**_question_payload(prompt="Capital‮ of France?"))
    assert "‮" not in payload.prompt


def test_an_explanation_of_only_whitespace_becomes_none():
    payload = CustomQuizQuestionIn(**_question_payload(explanation="   "))
    assert payload.explanation is None


# --- Difficulty --------------------------------------------------------------


def test_every_difficulty_label_lands_inside_the_band_the_dealer_searches():
    """Load-bearing. `_select_questions` filters on the numeric `difficulty`
    against `DIFFICULTY_RANGES`, but an author picks a *label*. If a label's
    stored value fell outside its own band, the first pass would return nothing
    and the quiz would only ever be dealt by the widening fallback.
    """
    for label, value in cq._DIFFICULTY_VALUE.items():
        low, high = DIFFICULTY_RANGES[label]
        assert low <= value <= high, (label, value)


def test_every_difficulty_label_has_a_value():
    assert set(cq._DIFFICULTY_VALUE) == set(DifficultyLabel)


def test_default_mode_choices_match_what_the_game_actually_offers():
    """`_SELECTABLE_MODES` is duplicated here to dodge an import cycle, so it
    has to be pinned to the real one or an author could nominate a mode the
    session endpoint then refuses."""
    assert cq._SELECTABLE_MODES == SELECTABLE_MODES


# --- Share codes ------------------------------------------------------------


def test_a_code_pasted_out_of_a_chat_app_still_resolves():
    assert cq.normalize_code(" bcd-234 ") == "BCD234"
    assert cq.normalize_code("bcd234​") == "BCD234"


def test_the_code_alphabet_cannot_be_misread():
    """No vowels, so a code cannot spell anything; no 0/O or 1/I, so it cannot
    be mistyped off a screenshot."""
    assert not set("AEIOU01") & set(cq.QUIZ_CODE_ALPHABET)


def test_a_short_or_junk_code_is_rejected_rather_than_padded():
    assert cq.normalize_code("!!!") == ""
    assert len(cq.normalize_code("BCD234BCD234")) == cq.QUIZ_CODE_LENGTH


# --- Access -----------------------------------------------------------------


def _access_session(*, friends_edge=None, blocks=None, access_rows=()):
    """A session answering just the queries `can_play` makes."""
    from app.models import CustomQuizAccess, Friendship, UserBlock

    rows = list(access_rows) + list(friends_edge or []) + list(blocks or [])
    return FakeSession(
        rows,
        resolver=predicate_resolver(
            {
                CustomQuizAccess: lambda r: True,
                Friendship: lambda r: True,
                UserBlock: lambda r: True,
            }
        ),
    )


@pytest.mark.asyncio
async def test_the_author_can_always_open_their_own_draft():
    owner = _user()
    quiz = _quiz(owner_user_id=owner.id, status=CustomQuizStatus.DRAFT)
    assert await cq.can_play(_access_session(), owner, quiz) is True


@pytest.mark.asyncio
async def test_a_stranger_cannot_open_a_private_quiz():
    quiz = _quiz(visibility=CustomQuizVisibility.PRIVATE)
    assert await cq.can_play(_access_session(), _user(), quiz) is False


@pytest.mark.asyncio
async def test_a_link_quiz_needs_a_grant_not_just_publication():
    """`link` means "anyone holding the code", not "anyone at all". The grant
    row is what redeeming the code writes."""
    quiz = _quiz(visibility=CustomQuizVisibility.LINK)
    assert await cq.can_play(_access_session(), _user(), quiz) is False


@pytest.mark.asyncio
async def test_a_redeemed_code_is_remembered_so_it_is_needed_once():
    from app.models import CustomQuizAccess

    quiz = _quiz(visibility=CustomQuizVisibility.LINK)
    player = _user()
    grant = CustomQuizAccess(id=uuid4(), quiz_id=quiz.id, user_id=player.id, source="code")
    assert await cq.can_play(_access_session(access_rows=[grant]), player, quiz) is True


@pytest.mark.asyncio
async def test_a_draft_is_invisible_to_everyone_but_its_author():
    quiz = _quiz(status=CustomQuizStatus.DRAFT)
    with pytest.raises(HTTPException) as excinfo:
        await cq.assert_can_play(_access_session(), _user(), quiz)
    assert excinfo.value.status_code == 404


@pytest.mark.asyncio
async def test_a_stranger_learns_nothing_from_an_archived_quiz():
    """404, not 410. A distinguishable answer turns a guessable id into an
    enumeration oracle."""
    with pytest.raises(HTTPException) as excinfo:
        await cq.assert_can_play(
            _access_session(), _user(), _quiz(status=CustomQuizStatus.ARCHIVED)
        )
    assert excinfo.value.status_code == 404


@pytest.mark.asyncio
async def test_someone_who_played_it_is_told_it_was_taken_down():
    from app.models import CustomQuizAccess

    quiz = _quiz(status=CustomQuizStatus.ARCHIVED)
    player = _user()
    grant = CustomQuizAccess(id=uuid4(), quiz_id=quiz.id, user_id=player.id, source="code")
    with pytest.raises(HTTPException) as excinfo:
        await cq.assert_can_play(_access_session(access_rows=[grant]), player, quiz)
    assert excinfo.value.status_code == 410
    assert excinfo.value.detail["code"] == "quiz_archived"


@pytest.mark.asyncio
async def test_the_author_is_told_to_restore_rather_than_handed_an_empty_bank():
    """Archiving parks the questions at PENDING, which the dealer skips. Without
    this the author's own replay would 409 with "no questions are ready for this
    topic" — true, unhelpful, and not what they need to do about it."""
    owner = _user()
    quiz = _quiz(owner_user_id=owner.id, status=CustomQuizStatus.ARCHIVED)
    with pytest.raises(HTTPException) as excinfo:
        await cq.assert_can_play(_access_session(), owner, quiz)
    assert excinfo.value.detail["code"] == "quiz_archived_owner"


@pytest.mark.asyncio
async def test_an_author_cannot_play_their_own_draft():
    """Same reason: a draft's questions are PENDING, so there is nothing to
    deal. "Publish it first" is the actionable version of that."""
    owner = _user()
    quiz = _quiz(owner_user_id=owner.id, status=CustomQuizStatus.DRAFT)
    with pytest.raises(HTTPException) as excinfo:
        await cq.assert_can_play(_access_session(), owner, quiz)
    assert excinfo.value.detail["code"] == "quiz_not_published"


@pytest.mark.asyncio
async def test_a_hidden_quiz_is_closed_even_to_its_author():
    owner = _user()
    quiz = _quiz(owner_user_id=owner.id, status=CustomQuizStatus.HIDDEN)
    with pytest.raises(HTTPException) as excinfo:
        await cq.assert_can_play(_access_session(), owner, quiz)
    assert excinfo.value.status_code == 403


@pytest.mark.asyncio
async def test_an_empty_quiz_cannot_be_started():
    owner = _user()
    quiz = _quiz(owner_user_id=owner.id, question_count=0)
    with pytest.raises(HTTPException) as excinfo:
        await cq.assert_can_play(_access_session(), owner, quiz)
    assert excinfo.value.status_code == 409


@pytest.mark.asyncio
async def test_a_grant_is_never_written_for_the_author():
    """A self-row would put your own quizzes in your "shared with me" list."""
    owner = _user()
    quiz = _quiz(owner_user_id=owner.id)
    db = _access_session()
    await cq.grant_access(db, quiz, owner.id)
    assert db.added == []


# --- Anti-farm --------------------------------------------------------------


@pytest.mark.asyncio
async def test_someone_elses_quiz_always_pays_xp():
    topic = Topic(id=uuid4(), slug="cq", name="Q", created_by_user_id=uuid4())
    db = FakeSession(resolver=predicate_resolver({Score: lambda r: True}))
    assert await cq.xp_allowed_for_run(db, topic=topic, user_id=uuid4()) is True


@pytest.mark.asyncio
async def test_your_own_quiz_stops_paying_xp_inside_the_cooldown():
    """Without this an author holds a private, infinitely repeatable XP faucet
    whose answer key they wrote."""
    author_id = uuid4()
    topic = Topic(id=uuid4(), slug="cq", name="Q", created_by_user_id=author_id)
    recent = Score(
        id=uuid4(),
        user_id=author_id,
        session_id=uuid4(),
        topic_id=topic.id,
        final_score=500,
        accuracy=100.0,
        best_streak=5,
        questions_answered=5,
        xp_earned=50,
    )
    db = FakeSession([recent], resolver=predicate_resolver({Score: lambda r: True}))
    assert await cq.xp_allowed_for_run(db, topic=topic, user_id=author_id) is False


@pytest.mark.asyncio
async def test_your_own_quiz_pays_again_once_nothing_recent_is_found():
    author_id = uuid4()
    topic = Topic(id=uuid4(), slug="cq", name="Q", created_by_user_id=author_id)
    db = FakeSession(resolver=predicate_resolver({Score: lambda r: False}))
    assert await cq.xp_allowed_for_run(db, topic=topic, user_id=author_id) is True


def test_a_custom_run_never_reaches_the_weekly_leaderboard():
    """Source-level, because the alternative is standing up the whole finalize
    path. The guard is the single thing stopping a five-question quiz you wrote
    the answers to from being the cheapest route to the top of the ladder."""
    source = (
        Path(__file__).resolve().parents[1] / "app" / "services" / "quiz_service.py"
    ).read_text(encoding="utf-8")
    tree = ast.parse(source)
    finalize = next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "_finalize_session"
    )
    body = ast.get_source_segment(source, finalize) or ""
    assert "if is_custom_quiz:\n            raise _SkipLeaderboard" in body
    assert "record_score" in body


def test_the_finite_deck_flag_is_read_everywhere_it_has_to_be():
    """The flag is what stops an endless mode reshuffling a ten-question quiz
    forever, and what exempts it from the unique-question cap. Both readers
    matter; losing either is a silent behaviour change."""
    source = (
        Path(__file__).resolve().parents[1] / "app" / "services" / "quiz_service.py"
    ).read_text(encoding="utf-8")
    assert source.count('"finite_deck"') >= 3
    assert 'config["finite_deck"] = True' in source


# --- Order and scale --------------------------------------------------------


def test_questions_sort_by_the_authors_arrangement():
    """A hand-written quiz is dealt in the order it was written — the only
    thing about the running order the author had any say over."""
    questions = [
        Question(
            id=uuid4(),
            topic_id=uuid4(),
            prompt=f"Q{position}",
            explanation="",
            correct_option_index=0,
            content_hash=str(uuid4()),
            generation_meta={"custom_quiz": {"position": position}},
        )
        for position in (2, 0, 1)
    ]
    questions.sort(key=cq.question_position)
    assert [q.prompt for q in questions] == ["Q0", "Q1", "Q2"]


def test_a_question_with_no_position_metadata_sorts_first_rather_than_crashing():
    """Rows written before the editor existed, or by a future code path that
    forgets the key. Neither is worth a 500 on the dealing path."""
    stray = Question(
        id=uuid4(),
        topic_id=uuid4(),
        prompt="Q?",
        explanation="",
        correct_option_index=0,
        content_hash=str(uuid4()),
        generation_meta={},
    )
    assert cq.question_position(stray) == 0
    stray.generation_meta = {"custom_quiz": {"position": "not a number"}}
    assert cq.question_position(stray) == 0


def test_the_dealer_sorts_a_finite_deck_by_that_position():
    source = (
        Path(__file__).resolve().parents[1] / "app" / "services" / "quiz_service.py"
    ).read_text(encoding="utf-8")
    assert "questions.sort(key=question_position)" in source


def test_the_quiz_leaderboard_never_scans_the_whole_topic():
    """The shape that does not survive the first quiz to go round a school:
    fetch every score row for the topic and deduplicate by player in Python.
    Ranking has to happen in the database, and the page has to be bounded."""
    source = (
        Path(__file__).resolve().parents[1]
        / "app"
        / "services"
        / "custom_quizzes.py"
    ).read_text(encoding="utf-8")
    tree = ast.parse(source)
    board = next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "leaderboard"
    )
    body = ast.get_source_segment(source, board) or ""
    assert "row_number()" in body, "ranking left in Python"
    assert ".limit(limit)" in body, "the page is unbounded"


# --- Moderation -------------------------------------------------------------


@pytest.mark.asyncio
async def test_reports_from_enough_distinct_players_hide_a_quiz():
    from app.models import CustomQuizAccess, Friendship, Question as Q, UserBlock

    quiz = _quiz()
    reporter = _user()
    grant = CustomQuizAccess(id=uuid4(), quiz_id=quiz.id, user_id=reporter.id, source="code")
    # One short of the threshold already on the row, so this report crosses it.
    quiz.report_count = cq._settings().custom_quiz_report_hide_threshold - 1

    db = FakeSession(
        [quiz, grant],
        resolver=predicate_resolver(
            {
                CustomQuiz: lambda r: True,
                CustomQuizAccess: lambda r: True,
                CustomQuizReport: lambda r: False,  # not reported by this user yet
                Friendship: lambda r: True,
                UserBlock: lambda r: False,
                Q: lambda r: False,
            }
        ),
    )
    await cq.report(db, reporter, quiz.id, ReportQuizRequest(reason="offensive"))

    assert quiz.status is CustomQuizStatus.HIDDEN
    assert quiz.moderation_note
    assert any(isinstance(row, CustomQuizReport) for row in db.added)


@pytest.mark.asyncio
async def test_you_cannot_report_your_own_quiz():
    owner = _user()
    quiz = _quiz(owner_user_id=owner.id)
    db = FakeSession([quiz], resolver=predicate_resolver({CustomQuiz: lambda r: True}))
    with pytest.raises(HTTPException) as excinfo:
        await cq.report(db, owner, quiz.id, ReportQuizRequest(reason="spam"))
    assert excinfo.value.detail["code"] == "cannot_report_own"


def test_report_reasons_are_a_closed_set():
    with pytest.raises(ValidationError):
        ReportQuizRequest(reason="because_i_lost")


# --- Counters ---------------------------------------------------------------


@pytest.mark.asyncio
async def test_a_first_finish_counts_a_new_player_and_a_repeat_does_not():
    quiz = _quiz()
    topic = Topic(id=quiz.topic_id, slug="cq", name="Q", created_by_user_id=quiz.owner_user_id)

    fresh = FakeSession(
        [quiz],
        resolver=predicate_resolver({CustomQuiz: lambda r: True, Score: lambda r: False}),
    )
    await cq.note_finished_run(fresh, topic=topic, user_id=uuid4(), score=900)
    assert (quiz.play_count, quiz.player_count, quiz.top_score) == (1, 1, 900)

    prior = Score(
        id=uuid4(),
        user_id=uuid4(),
        session_id=uuid4(),
        topic_id=topic.id,
        final_score=100,
        accuracy=50.0,
        best_streak=1,
        questions_answered=4,
    )
    repeat = FakeSession(
        [quiz, prior],
        resolver=predicate_resolver({CustomQuiz: lambda r: True, Score: lambda r: True}),
    )
    await cq.note_finished_run(repeat, topic=topic, user_id=uuid4(), score=400)
    assert (quiz.play_count, quiz.player_count) == (2, 1)
    # A worse run never lowers the headline.
    assert quiz.top_score == 900


# --- Limits -----------------------------------------------------------------


def test_premium_lifts_the_per_quiz_question_ceiling():
    settings = cq._settings()
    assert cq.max_questions_for(_user(is_premium=False)) == settings.custom_quiz_free_max_questions
    assert cq.max_questions_for(_user(is_premium=True)) == settings.custom_quiz_max_questions


def test_the_free_question_ceiling_still_clears_the_publish_floor():
    """Otherwise a free account could never publish anything at all."""
    settings = cq._settings()
    assert settings.custom_quiz_free_max_questions >= settings.custom_quiz_min_questions


def test_a_publishable_quiz_is_always_long_enough_to_challenge_with():
    """Publishing is the promise that the quiz works. If the publish floor sat
    below the match floor, a published quiz could still refuse every challenge
    sent on it."""
    settings = cq._settings()
    assert settings.custom_quiz_min_questions >= settings.match_min_question_count


# --- Migration ---------------------------------------------------------------

_MIGRATION = (
    Path(__file__).resolve().parents[1] / "alembic" / "versions" / "0010_custom_quizzes.py"
)


def test_the_migration_creates_every_table_the_models_declare():
    source = _MIGRATION.read_text(encoding="utf-8")
    for table in ("custom_quizzes", "custom_quiz_access", "custom_quiz_reports"):
        assert f'"{table}"' in source, table
    assert '"is_user_generated"' in source


def test_the_migration_indexes_the_per_quiz_leaderboard_read():
    """Every custom quiz has its own ladder, and that read is "best scores for
    one topic". On the plain single-column topic index it means fetching every
    score row for the quiz and sorting them."""
    source = _MIGRATION.read_text(encoding="utf-8")
    assert "ix_scores_topic_score" in source
    assert "final_score DESC" in source


def test_the_migration_chains_onto_the_current_head():
    source = _MIGRATION.read_text(encoding="utf-8")
    assert 'down_revision: Union[str, None] = "0009_news_topics"' in source


def test_serialize_cannot_run_a_query_of_its_own():
    """The list path renders up to a hundred rows through `serialize`. A
    convenient default that fetched the author, the best score or the publish
    blockers would be three round trips per row the moment somebody opens the
    studio — so the function is synchronous and takes all three."""
    import inspect

    assert not inspect.iscoroutinefunction(cq.serialize)
    parameters = inspect.signature(cq.serialize).parameters
    assert "db" not in parameters
    for required in ("author", "my_best", "blockers"):
        assert parameters[required].default is inspect.Parameter.empty, required
