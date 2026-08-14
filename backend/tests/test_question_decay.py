"""Rules that stop a generated question rotting.

Both rules here exist because asking the model nicely did not work. The
generation prompt already spells out "not 'who is the current champion' but
'who won the title on 12 August 2026'", and the first production batch came
back 27% time-relative, 26% date-anchored, and 71% labelled as still-true-in-
a-year. These are the deterministic backstops.
"""

import pytest

from app.ai.pipeline import time_anchor_reasons
from app.ai.providers import GeneratedQuestionDraft
from app.core.freshness import Temporality, Volatility, clamp_volatility


def draft(question: str) -> GeneratedQuestionDraft:
    return GeneratedQuestionDraft(
        question=question,
        options=["a", "b", "c", "d"],
        correct_option=0,
        explanation="because.",
    )


# --- time-relative phrasing --------------------------------------------------


@pytest.mark.parametrize(
    "question",
    [
        # Every one of these is real output from the first production batch.
        "What did the Karnataka Cabinet approve recently?",
        "Which club is reportedly facing challenges after a recent defeat?",
        "What recent accusation did the UAE make against Iran?",
        "What tragic event occurred in Colombia recently?",
        "What is the currently reported toll?",
        "What did the minister just announce?",
        "हाल ही में कर्नाटक मंत्रिमंडल ने क्या मंजूरी दी?",
    ],
)
def test_time_relative_questions_are_rejected_on_news_batches(question):
    assert time_anchor_reasons(draft(question), Temporality.CURRENT) == [
        "time_relative_phrasing"
    ]


@pytest.mark.parametrize(
    "question",
    [
        # The shape the prompt asks for, and which the good outputs achieved.
        "What was the outcome of the Ghatkopar landslip on 14 August 2026?",
        "What has been the trend in India's edible oil imports as of July 2026?",
        "Who won the Europa League qualifying match on 12 August 2026?",
    ],
)
def test_date_anchored_questions_pass(question):
    assert time_anchor_reasons(draft(question), Temporality.CURRENT) == []


def test_settled_subjects_are_not_policed():
    """On a static topic "recently" is loose writing, not a decay risk — and
    rejecting it would throw away good questions about the Mughals."""
    assert time_anchor_reasons(draft("Which dynasty recently..."), Temporality.STATIC) == []


def test_evolving_topics_are_policed_too():
    assert time_anchor_reasons(draft("Who is currently top?"), Temporality.EVOLVING) == [
        "time_relative_phrasing"
    ]


def test_the_word_must_stand_alone():
    """`recent` inside a longer word is not the failure being caught."""
    assert time_anchor_reasons(draft("What is unprecedented about it?"), Temporality.CURRENT) == []


# --- volatility clamping -----------------------------------------------------


def test_news_facts_may_not_claim_a_year_of_shelf_life():
    """SLOW means "still right in a year". For a fact lifted from this week's
    headlines that is almost never true, and 71% of the first batch claimed it."""
    assert clamp_volatility(Volatility.SLOW, Temporality.CURRENT) is Volatility.FAST


def test_a_permanent_fact_from_a_news_story_stays_permanent():
    """News genuinely yields durable facts — "on 14 August 2026 the toll rose
    to eight" is still true in ten years. The vague middle is the danger, not
    the confident label."""
    assert clamp_volatility(Volatility.STATIC, Temporality.CURRENT) is Volatility.STATIC


def test_fast_is_left_alone():
    assert clamp_volatility(Volatility.FAST, Temporality.CURRENT) is Volatility.FAST


@pytest.mark.parametrize("temporality", [Temporality.STATIC, Temporality.EVOLVING])
def test_slower_topics_keep_their_year(temporality):
    """A league table is legitimately slow-moving; only CURRENT is capped."""
    assert clamp_volatility(Volatility.SLOW, temporality) is Volatility.SLOW
