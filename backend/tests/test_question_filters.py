"""The shared playability predicate and the columns behind it (no DB)."""

from datetime import datetime, timezone

from sqlalchemy import select

from app.models import Question, QuestionStatus
from app.services.question_filters import not_expired, playable

NOW = datetime(2026, 8, 13, 12, 0, tzinfo=timezone.utc)


def _sql(clause) -> str:
    return str(select(Question.id).where(clause).compile())


def test_permanent_questions_are_playable():
    """NULL expires_at is every row written before freshness existed, plus
    every question about a settled subject since. The predicate has to let all
    of them through or the sweep would empty the entire bank."""
    sql = _sql(not_expired(NOW))
    assert "expires_at IS NULL" in sql
    assert "OR" in sql


def test_the_predicate_compares_against_the_supplied_moment():
    """One timestamp per selection, not one per phase — otherwise a question
    can expire between the unseen pass and the recycled pass, which is an
    intermittent gap nobody can reproduce."""
    compiled = select(Question.id).where(not_expired(NOW)).compile()
    assert NOW in compiled.params.values()


def test_playable_bundles_status_and_expiry():
    clauses = playable(moment=NOW)
    assert len(clauses) == 2
    sql = _sql(clauses[0]) + _sql(clauses[1])
    assert "status" in sql and "expires_at" in sql


def test_playable_adds_language_only_when_asked():
    assert len(playable(moment=NOW)) == 2
    assert len(playable(language="hi", moment=NOW)) == 3
    assert "language" in _sql(playable(language="hi", moment=NOW)[2])


# --- the columns -------------------------------------------------------------


def test_question_carries_the_freshness_columns():
    columns = Question.__table__.c
    assert columns["expires_at"].nullable is True
    assert columns["valid_as_of"].nullable is True
    # Legacy rows and settled subjects both mean "permanent", so the default
    # has to be the non-expiring one.
    assert columns["volatility"].nullable is False
    assert columns["volatility"].server_default.arg == "static"


def test_the_expiry_index_is_partial():
    """Only the perishable minority belongs in it — a bank of permanent
    questions should carry no index-maintenance cost for a feature it never
    uses."""
    index = next(i for i in Question.__table__.indexes if i.name == "ix_questions_expiring")
    where = index.dialect_options["postgresql"]["where"]
    assert "expires_at IS NOT NULL" in str(where)


def test_retired_is_the_status_the_sweep_moves_questions_to():
    """Retiring rather than deleting: times_served / times_correct on an
    expired question are still the only record of how it performed."""
    assert QuestionStatus.RETIRED.value == "retired"
    assert QuestionStatus.RETIRED is not QuestionStatus.ACTIVE
