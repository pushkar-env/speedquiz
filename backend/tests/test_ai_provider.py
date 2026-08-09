import pytest

from app.ai.providers import MockLLMProvider


@pytest.mark.asyncio
async def test_mock_provider_generates_and_validates():
    provider = MockLLMProvider()
    drafts = await provider.generate_questions(topic="Astronomy", difficulty="hard", count=3)
    assert len(drafts) == 3
    results = await provider.validate_questions(drafts)
    assert all(r.approved for r in results)
    assert all(r.quality_score >= 70 for r in results)


@pytest.mark.asyncio
async def test_mock_provider_rejects_duplicate_options():
    provider = MockLLMProvider()
    drafts = await provider.generate_questions(topic="X", difficulty="easy", count=1)
    drafts[0].options = ["A", "A", "B", "C"]
    results = await provider.validate_questions(drafts)
    assert results[0].approved is False
    assert "duplicate_options" in results[0].reasons
