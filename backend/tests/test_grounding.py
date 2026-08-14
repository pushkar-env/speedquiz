"""Grounded generation: the citation gate, and the grounded prompt round trip."""

import json
from datetime import datetime, timezone

import pytest

from app.ai.openai_provider import OpenAILLMProvider
from app.ai.pipeline import citation_reasons, schema_validate
from app.ai.providers import (
    ContextSnippet,
    GeneratedQuestionDraft,
    MockLLMProvider,
    RetrievedContext,
)
from app.core.freshness import Volatility
from app.core.languages import ContentLanguage

AUG12 = datetime(2026, 8, 12, tzinfo=timezone.utc)
AUG10 = datetime(2026, 8, 10, tzinfo=timezone.utc)


def make_context() -> RetrievedContext:
    return RetrievedContext(
        snippets=[
            ContextSnippet(
                id="S1",
                title="Parliament passes the budget",
                summary="The bill cleared both houses on Tuesday.",
                url="https://example.com/a",
                source="example.com",
                published_at=AUG10,
            ),
            ContextSnippet(
                id="S2",
                title="Rover reaches the crater",
                summary="It landed on Tuesday.",
                url="https://example.com/b",
                source="example.com",
                published_at=AUG12,
            ),
        ],
        query="india news",
    )


def draft(**overrides) -> GeneratedQuestionDraft:
    base = dict(
        question="Which body passed the budget on 11 August 2026?",
        options=["Parliament", "Supreme Court", "RBI", "Election Commission"],
        correct_option=0,
        explanation="Both houses cleared the bill on 11 August 2026.",
    )
    base.update(overrides)
    return GeneratedQuestionDraft(**base)


# --- the citation gate -------------------------------------------------------


def test_ungrounded_generation_is_not_asked_to_cite():
    """Settled subjects have nothing to cite; the gate must not touch them."""
    assert citation_reasons(draft(), None) == []
    assert citation_reasons(draft(), RetrievedContext()) == []


def test_grounded_draft_citing_a_real_source_passes():
    assert citation_reasons(draft(source_ids=["S1"]), make_context()) == []
    assert citation_reasons(draft(source_ids=["S1", "S2"]), make_context()) == []


def test_grounded_draft_with_no_citation_is_rejected():
    assert citation_reasons(draft(source_ids=[]), make_context()) == ["uncited"]
    assert citation_reasons(draft(source_ids=["  "]), make_context()) == ["uncited"]


def test_grounded_draft_citing_an_invented_source_is_rejected():
    """A fabricated label is a stronger signal than none: the model invented a
    source to satisfy the format, which is exactly the failure this gate is
    here to catch."""
    assert citation_reasons(draft(source_ids=["S9"]), make_context()) == ["unknown_source"]
    assert citation_reasons(draft(source_ids=["S1", "S9"]), make_context()) == [
        "unknown_source"
    ]


def test_pipeline_rejects_an_uncited_draft_that_is_otherwise_perfect():
    """The composition the pipeline actually evaluates: a well-formed question
    with no grounding still fails."""
    good = draft(source_ids=[])
    assert schema_validate(good) == []
    assert schema_validate(good) + citation_reasons(good, make_context()) == ["uncited"]


# --- context shape -----------------------------------------------------------


def test_empty_context_is_falsy_so_callers_can_branch_on_it():
    assert not RetrievedContext()
    assert make_context()


def test_newest_published_at_drives_the_ttl_anchor():
    assert make_context().newest_published_at == AUG12


def test_newest_published_at_is_none_when_nothing_is_dated():
    context = RetrievedContext(
        snippets=[ContextSnippet(id="S1", title="t", summary="s", url="u", source="x")]
    )
    assert context.newest_published_at is None


def test_rendered_snippets_carry_their_date_and_source():
    rendered = make_context().render()
    assert "[S1]" in rendered and "[S2]" in rendered
    assert "2026-08-10" in rendered
    assert "example.com" in rendered
    assert "Parliament passes the budget" in rendered


# --- mock provider -----------------------------------------------------------


@pytest.mark.asyncio
async def test_mock_provider_cites_the_grounding_it_was_given():
    """The offline provider exercises the gate too — a gate only ever run
    against the real API is a gate nobody tests."""
    context = make_context()
    drafts = await MockLLMProvider(batch_salt="t").generate_questions(
        topic="India news", difficulty="medium", count=4, context=context
    )
    assert all(d.source_ids for d in drafts)
    assert all(citation_reasons(d, context) == [] for d in drafts)
    assert all(d.valid_as_of == AUG12 for d in drafts)


@pytest.mark.asyncio
async def test_mock_provider_cites_nothing_when_ungrounded():
    drafts = await MockLLMProvider(batch_salt="t").generate_questions(
        topic="Mughals", difficulty="medium", count=2
    )
    assert all(d.source_ids == [] for d in drafts)
    assert all(d.valid_as_of is None for d in drafts)


# --- grounded prompt round trip ----------------------------------------------


class _CapturingProvider(OpenAILLMProvider):
    """Captures the prompt and replays a canned completion."""

    def __init__(self, response: dict):
        super().__init__(api_key="test-key")
        self._response = response
        self.system = ""
        self.user = ""
        self.temperature = None

    async def _chat(self, *, model, system, user, temperature=0.4):
        self.system, self.user, self.temperature = system, user, temperature
        return json.dumps(self._response)


GROUNDED_RESPONSE = {
    "questions": [
        {
            "question": "Which body passed the budget on 11 August 2026?",
            "options": ["Parliament", "Supreme Court", "RBI", "Election Commission"],
            "correct_option": 0,
            "explanation": "Both houses cleared the bill.",
            "difficulty": 0.5,
            "source_ids": ["S1"],
            "volatility": "static",
            "as_of_date": "2026-08-10",
        }
    ]
}


@pytest.mark.asyncio
async def test_grounded_prompt_carries_sources_and_rules():
    provider = _CapturingProvider(GROUNDED_RESPONSE)
    await provider.generate_questions(
        topic="India news", difficulty="medium", count=5, context=make_context()
    )
    assert "SOURCES" in provider.user
    assert "[S1]" in provider.user and "[S2]" in provider.user
    assert "GROUNDING RULES" in provider.system
    assert "source_ids" in provider.system
    # Invention is the failure mode that matters, so grounded batches run cool.
    assert provider.temperature == 0.4


@pytest.mark.asyncio
async def test_ungrounded_prompt_has_no_grounding_rules_and_runs_hot():
    provider = _CapturingProvider(GROUNDED_RESPONSE)
    await provider.generate_questions(topic="Mughals", difficulty="medium", count=5)
    assert "SOURCES" not in provider.user
    assert "GROUNDING RULES" not in provider.system
    assert provider.temperature == 0.7


@pytest.mark.asyncio
async def test_grounded_freshness_fields_are_parsed_back():
    provider = _CapturingProvider(GROUNDED_RESPONSE)
    drafts = await provider.generate_questions(
        topic="India news", difficulty="medium", count=1, context=make_context()
    )
    assert drafts[0].source_ids == ["S1"]
    assert drafts[0].volatility is Volatility.STATIC
    assert drafts[0].valid_as_of == AUG10


@pytest.mark.asyncio
async def test_unlabelled_grounded_questions_default_to_perishable():
    """A grounded batch is current-affairs content. Anything the model does not
    explicitly call durable has to expire."""
    response = {"questions": [dict(GROUNDED_RESPONSE["questions"][0])]}
    response["questions"][0].pop("volatility")
    provider = _CapturingProvider(response)
    drafts = await provider.generate_questions(
        topic="India news", difficulty="medium", count=1, context=make_context()
    )
    assert drafts[0].volatility is Volatility.FAST


@pytest.mark.asyncio
async def test_ungrounded_generation_never_marks_a_question_perishable():
    """An ungrounded model volunteering `volatility: fast` is guessing, and
    acting on it would expire a perfectly permanent question about the Mughals."""
    response = {"questions": [dict(GROUNDED_RESPONSE["questions"][0])]}
    response["questions"][0]["volatility"] = "fast"
    provider = _CapturingProvider(response)
    drafts = await provider.generate_questions(topic="Mughals", difficulty="medium", count=1)
    assert drafts[0].volatility is Volatility.STATIC
    assert drafts[0].valid_as_of is None


@pytest.mark.asyncio
async def test_hindi_generation_is_told_to_translate_english_sources():
    """The Hindi corpus is a third the size of the English one, so a Hindi run
    is routinely grounded on English headlines."""
    provider = _CapturingProvider(GROUNDED_RESPONSE)
    await provider.generate_questions(
        topic="भारत समाचार",
        difficulty="medium",
        count=3,
        language=ContentLanguage.HINDI,
        context=make_context(),
    )
    assert "English" in provider.user
    assert "हिन्दी" in provider.user
